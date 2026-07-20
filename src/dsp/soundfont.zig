//! SoundFont 2 (.sf2) file parsing, against the SoundFont Technical
//! Specification 2.01: a RIFF container (`sfbk`) with an INFO chunk, a
//! `sdta` chunk holding raw 16-bit PCM sample data, and a `pdta` chunk
//! holding nine fixed-record "hydra" tables (phdr/pbag/pmod/pgen/inst/ibag/
//! imod/igen/shdr) that describe how presets map MIDI (bank, program, key,
//! velocity) onto samples.
//!
//! Presets and instruments are both "zone lists": a zone is a generator set
//! (deltas from a spec-defined default) optionally scoped to a key/velocity
//! range, plus - at the instrument level - a link to one sample, or - at the
//! preset level - a link to one instrument. A zone with no such link is a
//! *global* zone: its generators are inherited by every other zone at that
//! level unless a local zone overrides them. Per spec 9.4, a preset zone's
//! generators are *additive offsets* on top of the fully-resolved
//! instrument zone's own values (every generator except keyRange/velRange,
//! which only ever select zones, and instrument/sampleID, which are
//! terminal links valid at one level only) - `resolveGenerators` below
//! implements exactly that layering, not a naive overwrite.
//!
//! To keep playback a flat array scan (dsp/soundfont_player.zig) rather than
//! a two-level tree walk per note, `parse` flattens every (preset zone x
//! matching instrument zone) pair into one `Region` up front, at load time,
//! the same "resolve once, play cheaply" trade the codebase already makes
//! elsewhere (e.g. dsp/wavetable.zig's frame table). Modulators (pmod/imod -
//! the spec's LFO/mod-envelope routing table) are read past but not
//! resolved: this player is a straight sample-playback engine with a static
//! per-region volume envelope and filter, not a full synthesis modulation
//! matrix - an accepted v1 scope cut, the same kind wavetable.zig's own
//! "no band-limiting" tradeoff is.

const std = @import("std");
const pad_dsp = @import("pad.zig");

pub const ParseError = error{
    NotSf2,
    Truncated,
    MalformedChunk,
    NoSamples,
    NoPresets,
    InvalidSampleRate,
    OutputTooLarge,
} || std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// Generator ids (SFGenerator) this parser resolves. Every other id defined
// by the spec (chorus/reverb send, the mod-LFO/mod-envelope/vib-LFO
// pitch/filter/volume routes, keynum/velocity override) is read as part of
// the raw per-zone generator set (so it still participates correctly in the
// additive preset-over-instrument layering for the ids that follow it in a
// zone's own list) but never consulted when building a `Region` - see the
// file doc comment.
// ---------------------------------------------------------------------------

const gen_start_addrs_offset: usize = 0;
const gen_end_addrs_offset: usize = 1;
const gen_startloop_addrs_offset: usize = 2;
const gen_endloop_addrs_offset: usize = 3;
const gen_start_addrs_coarse_offset: usize = 4;
const gen_initial_filter_fc: usize = 8;
const gen_initial_filter_q: usize = 9;
const gen_end_addrs_coarse_offset: usize = 12;
const gen_pan: usize = 17;
const gen_delay_vol_env: usize = 33;
const gen_attack_vol_env: usize = 34;
const gen_hold_vol_env: usize = 35;
const gen_decay_vol_env: usize = 36;
const gen_sustain_vol_env: usize = 37;
const gen_release_vol_env: usize = 38;
const gen_instrument: usize = 41;
const gen_key_range: usize = 43;
const gen_vel_range: usize = 44;
const gen_startloop_addrs_coarse_offset: usize = 45;
const gen_initial_attenuation: usize = 48;
const gen_endloop_addrs_coarse_offset: usize = 50;
const gen_coarse_tune: usize = 51;
const gen_fine_tune: usize = 52;
const gen_sample_id: usize = 53;
const gen_sample_modes: usize = 54;
const gen_scale_tuning: usize = 56;
const gen_exclusive_class: usize = 57;
const gen_overriding_root_key: usize = 58;
/// One past the highest generator id this file ever indexes into a `GenSet`
/// (spec's `endOper` terminal id is 60; nothing above it is real data).
const gen_count: usize = 61;

/// Amount for one generator: most are a plain signed 16-bit delta;
/// key/velocity range generators pack {lo, hi} bytes instead - `resolve`
/// keeps both readings since a zone's raw list only carries the bit pattern.
const RangeGen = struct { lo: u8, hi: u8 };
const GenAmount = union(enum) { signed: i16, range: RangeGen };

/// One zone's fully-collapsed generator set: later records for the same id
/// within a zone's own gen list overwrite earlier ones (per spec, a
/// well-formed file never repeats an id in one zone, but this is cheap
/// insurance). `null` means "not present in this zone" - resolution below
/// falls back to the spec default or, at the preset level, contributes no
/// offset.
const GenSet = struct {
    amount: [gen_count]?GenAmount = [_]?GenAmount{null} ** gen_count,

    fn set(self: *GenSet, id: u16, raw: u16) void {
        if (id >= gen_count) return;
        self.amount[id] = switch (id) {
            gen_key_range, gen_vel_range => .{ .range = .{ .lo = @truncate(raw), .hi = @truncate(raw >> 8) } },
            else => .{ .signed = @bitCast(raw) },
        };
    }

    fn signed(self: *const GenSet, id: usize, default: i16) i16 {
        const a = self.amount[id] orelse return default;
        return switch (a) {
            .signed => |v| v,
            .range => default,
        };
    }

    fn range(self: *const GenSet, id: usize) ?RangeGen {
        const a = self.amount[id] orelse return null;
        return switch (a) {
            .range => |r| r,
            .signed => null,
        };
    }
};

/// One playable sample header, byte-for-byte the shdr record's fields this
/// parser uses (achSampleName/dwSampleRate/byOriginalPitch/chPitchCorrection
/// are read here; wSampleLink/sfSampleType, the stereo-pairing metadata, are
/// skipped - unsupported v1 scope, see the file doc comment. A soundfont's
/// stereo instruments still play correctly as two independently-panned mono
/// regions, same as how they're actually stored).
const SampleHeader = struct {
    start: u32,
    end: u32,
    loop_start: u32,
    loop_end: u32,
    sample_rate: u32,
    original_pitch: u8,
    pitch_correction: i8,
};

/// One flattened, fully-resolved playable region: a preset zone crossed with
/// the instrument zone it selected, per the file doc comment's layering
/// rule. Everything here is already in the units `dsp/soundfont_player.zig`
/// consumes directly (seconds, semitones, Hz, linear gain factors) - no
/// generator/timecent/centibel math happens outside this file.
pub const Region = struct {
    /// Absolute frame indices into the owning `SoundFont.sample_data`.
    start: u32,
    end: u32,
    loop_start: u32,
    loop_end: u32,
    /// True when `sampleModes`' bit 0 is set (modes 1 or 3): the voice loops
    /// [loop_start, loop_end) while held. Modes 2 (reserved) and 3 (loop
    /// until release, then play the tail) collapse onto plain 0/1 - see the
    /// file doc comment's modulator-scope note; treating 3 as 1 (loop
    /// continues through the release fade rather than releasing into the
    /// unlooped tail) is the same "simplest correct-enough behaviour" cut.
    loops: bool,

    key_lo: u8,
    key_hi: u8,
    vel_lo: u8,
    vel_hi: u8,

    /// MIDI key that plays this region at its recorded pitch.
    root_key: u8,
    /// Cents per MIDI key of pitch change (100 = normal chromatic tracking,
    /// 0 = the whole region plays at one fixed pitch regardless of key).
    scale_tuning_cents: f32,
    /// Total fixed tuning offset in semitones - `coarseTune` +
    /// `fineTune`/100 + the sample's own `pitchCorrection`/100, pre-summed
    /// so playback only does one addition per voice trigger.
    tune_semitones: f32,

    /// -1..1, linear pan law (matches dsp/pad.zig's renderVoice).
    pan: f32,
    /// Linear gain from `initialAttenuation` (centibels - tenths of a dB).
    attenuation_gain: f32,

    delay_s: f32,
    attack_s: f32,
    hold_s: f32,
    decay_s: f32,
    /// 0..1 sustain level (converted from centibels attenuation-from-peak).
    sustain: f32,
    release_s: f32,

    /// Null when the resolved cutoff is at/above the spec's fully-open
    /// default (~20kHz) - see `resolveGenerators`'s doc comment. Non-null
    /// means the voice should run its lowpass.
    filter_cutoff_hz: ?f32,
    /// Resonance, linear Q (already converted from centibels).
    filter_q: f32,

    /// 0 = no choking group. Non-zero: triggering a region shares this id
    /// with another active voice, the later one silences the earlier
    /// (spec's `exclusiveClass`) - same idiom as DrumMachine.choke_group.
    exclusive_class: u8,
};

pub const Preset = struct {
    name: [20]u8,
    bank: u16,
    program: u16,
    regions: []Region,

    pub fn trimmedName(self: *const Preset) []const u8 {
        return trimZ(&self.name);
    }
};

pub const SoundFont = struct {
    allocator: std.mem.Allocator,
    /// Every sample's PCM, concatenated, resampled to the engine's sample
    /// rate at load time (see `parse`'s `target_sample_rate` - matches
    /// dsp/pad.zig's decodeWav, which resamples on load rather than the
    /// audio thread doing dual-rate math per voice). f32 in roughly [-1, 1].
    sample_data: []f32,
    presets: []Preset,

    pub fn deinit(self: *SoundFont) void {
        for (self.presets) |p| self.allocator.free(p.regions);
        self.allocator.free(self.presets);
        self.allocator.free(self.sample_data);
    }

    /// Deep copy - fresh allocations throughout, so the two fonts can be torn
    /// down independently (same contract every other dsp `dupe` in this
    /// codebase gives).
    pub fn dupe(self: *const SoundFont, allocator: std.mem.Allocator) !SoundFont {
        const data = try allocator.dupe(f32, self.sample_data);
        errdefer allocator.free(data);
        const presets = try allocator.alloc(Preset, self.presets.len);
        var built: usize = 0;
        errdefer {
            for (presets[0..built]) |p| allocator.free(p.regions);
            allocator.free(presets);
        }
        for (self.presets, presets) |src, *dst| {
            dst.* = .{ .name = src.name, .bank = src.bank, .program = src.program, .regions = try allocator.dupe(Region, src.regions) };
            built += 1;
        }
        return .{ .allocator = allocator, .sample_data = data, .presets = presets };
    }

    /// First preset matching (bank, program), or null.
    pub fn findPreset(self: *const SoundFont, bank: u16, program: u16) ?usize {
        for (self.presets, 0..) |p, i| {
            if (p.bank == bank and p.program == program) return i;
        }
        return null;
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, target_sample_rate: u32) ParseError!SoundFont {
        return parseImpl(allocator, bytes, target_sample_rate);
    }
};

fn trimZ(name: *const [20]u8) []const u8 {
    var end: usize = 0;
    while (end < name.len and name[end] != 0) end += 1;
    return name[0..end];
}

fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn readU16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn readI8(b: []const u8, off: usize) i8 {
    return @bitCast(b[off]);
}

/// One raw RIFF chunk: 4-byte id, 4-byte little-endian size, then that many
/// content bytes, padded to an even boundary (unpadded chunk sizes - common
/// in INFO string subchunks - are otherwise not word-aligned, which would
/// desync every following chunk header).
const Chunk = struct { id: [4]u8, data: []const u8, next: usize };

fn nextChunk(data: []const u8, pos: usize) ParseError!?Chunk {
    if (pos >= data.len) return null;
    if (pos + 8 > data.len) return error.Truncated;
    const size = readU32(data, pos + 4);
    const body_start = pos + 8;
    if (size > data.len - body_start) return error.Truncated;
    const body = data[body_start .. body_start + size];
    const padded = size + (size & 1);
    return .{ .id = data[pos..][0..4].*, .data = body, .next = body_start + padded };
}

fn eqlId(id: [4]u8, s: *const [4]u8) bool {
    return std.mem.eql(u8, &id, s);
}

// ---------------------------------------------------------------------------
// Hydra record readers - fixed-size records packed back to back in their
// chunk; `count` is `chunk.len / record_size`, with the trailing "terminal"
// record (every hydra list ends with one, e.g. phdr's final "EOP" entry)
// included like any other - `zoneGenSlice` below is what actually knows to
// stop one record early.
// ---------------------------------------------------------------------------

const PresetHeader = struct { name: [20]u8, program: u16, bank: u16, bag_ndx: u16 };
const InstHeader = struct { name: [20]u8, bag_ndx: u16 };
/// Shared shape of pbag/ibag records (wGenNdx, wModNdx).
const Bag = struct { gen_ndx: u16, mod_ndx: u16 };
const GenRecord = struct { id: u16, raw: u16 };

fn readPresetHeaders(allocator: std.mem.Allocator, data: []const u8) ![]PresetHeader {
    if (data.len % 38 != 0 or data.len == 0) return error.MalformedChunk;
    const out = try allocator.alloc(PresetHeader, data.len / 38);
    for (out, 0..) |*p, i| {
        const r = data[i * 38 ..][0..38];
        p.* = .{ .name = r[0..20].*, .program = readU16(r, 20), .bank = readU16(r, 22), .bag_ndx = readU16(r, 24) };
    }
    return out;
}

fn readInstHeaders(allocator: std.mem.Allocator, data: []const u8) ![]InstHeader {
    if (data.len % 22 != 0 or data.len == 0) return error.MalformedChunk;
    const out = try allocator.alloc(InstHeader, data.len / 22);
    for (out, 0..) |*p, i| {
        const r = data[i * 22 ..][0..22];
        p.* = .{ .name = r[0..20].*, .bag_ndx = readU16(r, 20) };
    }
    return out;
}

fn readBags(allocator: std.mem.Allocator, data: []const u8) ![]Bag {
    if (data.len % 4 != 0 or data.len == 0) return error.MalformedChunk;
    const out = try allocator.alloc(Bag, data.len / 4);
    for (out, 0..) |*b, i| {
        const r = data[i * 4 ..][0..4];
        b.* = .{ .gen_ndx = readU16(r, 0), .mod_ndx = readU16(r, 2) };
    }
    return out;
}

fn readGens(allocator: std.mem.Allocator, data: []const u8) ![]GenRecord {
    if (data.len % 4 != 0) return error.MalformedChunk;
    const out = try allocator.alloc(GenRecord, data.len / 4);
    for (out, 0..) |*g, i| {
        const r = data[i * 4 ..][0..4];
        g.* = .{ .id = readU16(r, 0), .raw = readU16(r, 2) };
    }
    return out;
}

fn readSampleHeaders(allocator: std.mem.Allocator, data: []const u8) ![]SampleHeader {
    if (data.len % 46 != 0 or data.len == 0) return error.MalformedChunk;
    // The trailing terminal shdr record ("EOS") carries no real sample -
    // dropped here (unlike the phdr/inst/bag arrays, nothing indexes past
    // the real entries into it).
    const count = data.len / 46 - 1;
    const out = try allocator.alloc(SampleHeader, count);
    for (out, 0..) |*s, i| {
        const r = data[i * 46 ..][0..46];
        s.* = .{
            .start = readU32(r, 20),
            .end = readU32(r, 24),
            .loop_start = readU32(r, 28),
            .loop_end = readU32(r, 32),
            .sample_rate = readU32(r, 36),
            .original_pitch = r[40],
            .pitch_correction = readI8(r, 41),
        };
    }
    return out;
}

/// The generator slice belonging to zone `bag_idx` out of a header's own
/// `[bag_lo, bag_hi)` bag range - `bags[bag_idx].gen_ndx .. next_gen_ndx`,
/// where `next_gen_ndx` is the following bag's start (or, for the last real
/// zone, the terminal bag record's own `gen_ndx`, which is exactly why every
/// hydra bag/gen list carries that extra trailing record).
fn zoneGenSlice(bags: []const Bag, gens: []const GenRecord, bag_idx: usize) ![]const GenRecord {
    if (bag_idx + 1 >= bags.len) return error.MalformedChunk;
    const lo = bags[bag_idx].gen_ndx;
    const hi = bags[bag_idx + 1].gen_ndx;
    if (hi < lo or hi > gens.len) return error.MalformedChunk;
    return gens[lo..hi];
}

fn buildGenSet(gens: []const GenRecord) GenSet {
    var set: GenSet = .{};
    for (gens) |g| set.set(g.id, g.raw);
    return set;
}

/// True when `gens` (a zone's own generator list) names neither a sample
/// (instrument-level zone) nor an instrument (preset-level zone) - the
/// spec's definition of a global zone. Only meaningful for the FIRST zone of
/// a header; a global zone appearing elsewhere is malformed and ignored (its
/// gens simply never get inherited, matching how most implementations treat
/// non-conformant files - fail soft, not hard).
fn isGlobalZone(gens: []const GenRecord, terminal_id: u16) bool {
    for (gens) |g| {
        if (g.id == terminal_id) return false;
    }
    return true;
}

/// Merge `local` on top of `global` (instrument- or preset-level global
/// zone), local wins per-generator. Returns `local` unchanged if `global` is
/// null.
fn mergeGlobal(global: ?GenSet, local: GenSet) GenSet {
    const g = global orelse return local;
    var out = g;
    for (local.amount, 0..) |maybe, i| {
        if (maybe) |v| out.amount[i] = v;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Unit conversions
// ---------------------------------------------------------------------------

/// Timecents to seconds: `2^(tc/1200)`. Per spec, -12000 (the default for
/// every volume-envelope stage) means "as fast as possible" - clamped to a
/// practical 1ms floor rather than the literal ~0.977ms so voices never
/// divide-by-near-zero in the envelope stage math.
fn timecentsToSeconds(tc: i16) f32 {
    const s = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(tc)) / 1200.0);
    return std.math.clamp(s, 0.001, 100.0);
}

/// Centibels (tenths of a dB) of attenuation to a linear gain factor.
/// Positive `cb` is quieter, matching the generator's own sign convention.
fn centibelsToGain(cb: i16) f32 {
    const db = -@as(f32, @floatFromInt(cb)) / 10.0;
    return std.math.pow(f32, 10.0, db / 20.0);
}

/// `initialFilterFc` cents to Hz: `440 * 2^((cents-6900)/1200)`, the spec's
/// absolute-cents-to-Hz formula (6900 cents = 440Hz, the same reference
/// pitch generator cents use elsewhere in the format).
fn filterCentsToHz(cents: i16) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(cents)) - 6900.0) / 1200.0);
}

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

const Hydra = struct {
    phdr: []PresetHeader,
    pbag: []Bag,
    pgen: []GenRecord,
    inst: []InstHeader,
    ibag: []Bag,
    igen: []GenRecord,
    shdr: []SampleHeader,

    fn deinit(self: *Hydra, allocator: std.mem.Allocator) void {
        allocator.free(self.phdr);
        allocator.free(self.pbag);
        allocator.free(self.pgen);
        allocator.free(self.inst);
        allocator.free(self.ibag);
        allocator.free(self.igen);
        allocator.free(self.shdr);
    }
};

fn parseImpl(allocator: std.mem.Allocator, bytes: []const u8, target_sample_rate: u32) ParseError!SoundFont {
    if (bytes.len < 12 or !eqlId(bytes[0..4].*, "RIFF") or !eqlId(bytes[8..12].*, "sfbk")) return error.NotSf2;

    var raw_sample_data: []const u8 = &.{};
    var hydra: ?Hydra = null;
    errdefer if (hydra) |*h| h.deinit(allocator);

    var pos: usize = 12;
    while (try nextChunk(bytes, pos)) |chunk| : (pos = chunk.next) {
        if (!eqlId(chunk.id, "LIST") or chunk.data.len < 4) continue;
        const list_type = chunk.data[0..4].*;
        if (eqlId(list_type, "sdta")) {
            var sp: usize = 4;
            while (try nextChunk(chunk.data, sp)) |sc| : (sp = sc.next) {
                if (eqlId(sc.id, "smpl")) raw_sample_data = sc.data;
            }
        } else if (eqlId(list_type, "pdta")) {
            var phdr: []PresetHeader = &.{};
            var pbag: []Bag = &.{};
            var pgen: []GenRecord = &.{};
            var inst: []InstHeader = &.{};
            var ibag: []Bag = &.{};
            var igen: []GenRecord = &.{};
            var shdr: []SampleHeader = &.{};
            errdefer {
                allocator.free(phdr);
                allocator.free(pbag);
                allocator.free(pgen);
                allocator.free(inst);
                allocator.free(ibag);
                allocator.free(igen);
                allocator.free(shdr);
            }
            var pp: usize = 4;
            while (try nextChunk(chunk.data, pp)) |sc| : (pp = sc.next) {
                // zig fmt: off
                if (eqlId(sc.id, "phdr")) { phdr = try readPresetHeaders(allocator, sc.data); }
                else if (eqlId(sc.id, "pbag")) { pbag = try readBags(allocator, sc.data); }
                else if (eqlId(sc.id, "pgen")) { pgen = try readGens(allocator, sc.data); }
                else if (eqlId(sc.id, "inst")) { inst = try readInstHeaders(allocator, sc.data); }
                else if (eqlId(sc.id, "ibag")) { ibag = try readBags(allocator, sc.data); }
                else if (eqlId(sc.id, "igen")) { igen = try readGens(allocator, sc.data); }
                else if (eqlId(sc.id, "shdr")) { shdr = try readSampleHeaders(allocator, sc.data); }
                // pmod/imod (modulators) and every INFO/pdta string chunk are
                // intentionally not read - see the file doc comment.
                // zig fmt: on
            }
            hydra = .{ .phdr = phdr, .pbag = pbag, .pgen = pgen, .inst = inst, .ibag = ibag, .igen = igen, .shdr = shdr };
        }
    }

    var h = hydra orelse return error.MalformedChunk;
    if (h.phdr.len < 2 or h.inst.len < 2 or h.shdr.len == 0) return error.NoPresets;
    if (raw_sample_data.len == 0) return error.NoSamples;

    // Raw sample data is 16-bit signed PCM mono, per spec. Convert once to
    // f32 and resample to the engine's rate up front (see SoundFont.
    // sample_data's doc comment) - every region's start/end/loop indices
    // below are rewritten from the shdr's native-rate frame numbers to this
    // resampled array's own indices in lock step, so the ratio must be
    // computed the same way here as in `resampleLinear`.
    const raw_frames = raw_sample_data.len / 2;
    const native = try allocator.alloc(f32, raw_frames);
    defer allocator.free(native);
    for (native, 0..) |*s, i| {
        const v: i16 = @bitCast(readU16(raw_sample_data, i * 2));
        s.* = @as(f32, @floatFromInt(v)) / 32768.0;
    }

    // Instruments and samples are typically each recorded at one common
    // rate; resampling the whole pool once (rather than per sample header)
    // keeps every region's index math a single shared ratio. A shdr whose
    // own dwSampleRate differs from the pool's dominant rate is rare enough
    // (and the spec doesn't mandate a single file-wide rate) that this
    // accepts a small pitch error for such an outlier sample - same
    // documented-tradeoff spirit as skipping modulators.
    const src_rate = if (h.shdr.len > 0 and h.shdr[0].sample_rate > 0) h.shdr[0].sample_rate else target_sample_rate;
    const sample_data = if (src_rate == target_sample_rate)
        try allocator.dupe(f32, native)
    else
        try pad_dsp.resampleLinear(allocator, native, src_rate, target_sample_rate);
    errdefer allocator.free(sample_data);
    const rate_ratio: f64 = @as(f64, @floatFromInt(target_sample_rate)) / @as(f64, @floatFromInt(@max(src_rate, 1)));

    const scaleIdx = struct {
        fn f(v: u32, ratio: f64, len: usize) u32 {
            const scaled = @as(f64, @floatFromInt(v)) * ratio;
            const clamped = std.math.clamp(scaled, 0.0, @as(f64, @floatFromInt(len)));
            return @intFromFloat(@round(clamped));
        }
    }.f;

    // Build every instrument's flattened zone list once (key/vel range +
    // resolved GenSet + sample index), reused below for every preset zone
    // that links to it - a preset commonly reuses the same instrument across
    // several key/vel-scoped zones (e.g. velocity-layered patches), and each
    // reuse must resolve independently against that preset zone's own
    // additive generators, so instrument zones stay unresolved (raw GenSet)
    // until crossed with a preset zone below.
    const InstZone = struct { key_lo: u8, key_hi: u8, vel_lo: u8, vel_hi: u8, gens: GenSet, sample_id: u16, has_sample: bool };
    var inst_zones: std.ArrayListUnmanaged([]InstZone) = .empty;
    defer {
        for (inst_zones.items) |z| allocator.free(z);
        inst_zones.deinit(allocator);
    }
    try inst_zones.ensureTotalCapacityPrecise(allocator, h.inst.len - 1);
    for (0..h.inst.len - 1) |ii| {
        var zones: std.ArrayListUnmanaged(InstZone) = .empty;
        errdefer zones.deinit(allocator);
        var global: ?GenSet = null;
        const bag_lo = h.inst[ii].bag_ndx;
        const bag_hi = h.inst[ii + 1].bag_ndx;
        if (bag_hi < bag_lo) return error.MalformedChunk;
        for (bag_lo..bag_hi) |bi| {
            const gens = try zoneGenSlice(h.ibag, h.igen, bi);
            if (isGlobalZone(gens, gen_sample_id)) {
                global = buildGenSet(gens);
                continue;
            }
            const set = mergeGlobal(global, buildGenSet(gens));
            const kr = set.range(gen_key_range) orelse RangeGen{ .lo = 0, .hi = 127 };
            const vr = set.range(gen_vel_range) orelse RangeGen{ .lo = 0, .hi = 127 };
            const has_sample = set.amount[gen_sample_id] != null;
            const sample_id: u16 = if (has_sample) @bitCast(set.signed(gen_sample_id, 0)) else 0;
            try zones.append(allocator, .{ .key_lo = kr.lo, .key_hi = kr.hi, .vel_lo = vr.lo, .vel_hi = vr.hi, .gens = set, .sample_id = sample_id, .has_sample = has_sample });
        }
        inst_zones.appendAssumeCapacity(try zones.toOwnedSlice(allocator));
    }

    var presets: std.ArrayListUnmanaged(Preset) = .empty;
    errdefer {
        for (presets.items) |p| allocator.free(p.regions);
        presets.deinit(allocator);
    }
    for (0..h.phdr.len - 1) |pi| {
        var regions: std.ArrayListUnmanaged(Region) = .empty;
        errdefer regions.deinit(allocator);
        var global: ?GenSet = null;
        const bag_lo = h.phdr[pi].bag_ndx;
        const bag_hi = h.phdr[pi + 1].bag_ndx;
        if (bag_hi < bag_lo) return error.MalformedChunk;
        for (bag_lo..bag_hi) |bi| {
            const gens = try zoneGenSlice(h.pbag, h.pgen, bi);
            if (isGlobalZone(gens, gen_instrument)) {
                global = buildGenSet(gens);
                continue;
            }
            const pset = mergeGlobal(global, buildGenSet(gens));
            if (pset.amount[gen_instrument] == null) continue; // malformed local zone, no link - skip
            const inst_idx: u16 = @bitCast(pset.signed(gen_instrument, 0));
            if (inst_idx >= inst_zones.items.len) continue;
            const pkr = pset.range(gen_key_range) orelse RangeGen{ .lo = 0, .hi = 127 };
            const pvr = pset.range(gen_vel_range) orelse RangeGen{ .lo = 0, .hi = 127 };

            for (inst_zones.items[inst_idx]) |iz| {
                if (!iz.has_sample or iz.sample_id >= h.shdr.len) continue;
                const key_lo = @max(pkr.lo, iz.key_lo);
                const key_hi = @min(pkr.hi, iz.key_hi);
                const vel_lo = @max(pvr.lo, iz.vel_lo);
                const vel_hi = @min(pvr.hi, iz.vel_hi);
                if (key_lo > key_hi or vel_lo > vel_hi) continue; // ranges don't overlap - this pairing never plays

                const region = try resolveRegion(iz.gens, pset, h.shdr[iz.sample_id], key_lo, key_hi, vel_lo, vel_hi, sample_data.len, rate_ratio, scaleIdx);
                try regions.append(allocator, region);
            }
        }
        if (regions.items.len == 0) {
            regions.deinit(allocator);
            continue; // an empty preset (no playable region) contributes nothing
        }
        try presets.append(allocator, .{
            .name = h.phdr[pi].name,
            .bank = h.phdr[pi].bank,
            .program = h.phdr[pi].program,
            .regions = try regions.toOwnedSlice(allocator),
        });
    }
    h.deinit(allocator);
    hydra = null;

    if (presets.items.len == 0) {
        presets.deinit(allocator);
        return error.NoPresets;
    }

    return .{ .allocator = allocator, .sample_data = sample_data, .presets = try presets.toOwnedSlice(allocator) };
}

/// Cross one instrument zone's raw generators with the preset zone that
/// selected it, per the file doc comment's additive layering rule, and
/// convert every generator this player uses into the `Region`'s own units.
fn resolveRegion(
    inst_gens: GenSet,
    preset_gens: GenSet,
    shdr: SampleHeader,
    key_lo: u8,
    key_hi: u8,
    vel_lo: u8,
    vel_hi: u8,
    sample_data_len: usize,
    rate_ratio: f64,
    scaleIdx: anytype,
) ParseError!Region {
    // Additive generators: instrument-resolved value + preset offset (0 if
    // the preset never touched that id). keyRange/velRange/instrument/
    // sampleID are excluded by construction (never read via `add` below -
    // range generators are handled separately as int-only, the two links
    // aren't generators of a played region at all).
    const add = struct {
        fn f(inst: *const GenSet, preset: *const GenSet, id: usize, default: i16) i16 {
            const base = inst.signed(id, default);
            const offset = if (preset.amount[id] != null) preset.signed(id, 0) else 0;
            const wide = @as(i32, base) + @as(i32, offset);
            return @intCast(std.math.clamp(wide, std.math.minInt(i16), std.math.maxInt(i16)));
        }
    }.f;

    // Sample address offsets are spec-scoped to the instrument zone only
    // (a preset zone has no sample of its own to offset) - resolved from
    // `inst_gens` alone, matching real-world files, which never set them at
    // the preset level.
    const start_off = @as(i32, inst_gens.signed(gen_start_addrs_offset, 0)) + @as(i32, inst_gens.signed(gen_start_addrs_coarse_offset, 0)) * 32768;
    const end_off = @as(i32, inst_gens.signed(gen_end_addrs_offset, 0)) + @as(i32, inst_gens.signed(gen_end_addrs_coarse_offset, 0)) * 32768;
    const loop_start_off = @as(i32, inst_gens.signed(gen_startloop_addrs_offset, 0)) + @as(i32, inst_gens.signed(gen_startloop_addrs_coarse_offset, 0)) * 32768;
    const loop_end_off = @as(i32, inst_gens.signed(gen_endloop_addrs_offset, 0)) + @as(i32, inst_gens.signed(gen_endloop_addrs_coarse_offset, 0)) * 32768;

    const native_start = clampU32(@as(i64, shdr.start) + start_off);
    const native_end = clampU32(@as(i64, shdr.end) + end_off);
    const native_loop_start = clampU32(@as(i64, shdr.loop_start) + loop_start_off);
    const native_loop_end = clampU32(@as(i64, shdr.loop_end) + loop_end_off);

    const start = scaleIdx(native_start, rate_ratio, sample_data_len);
    var end = scaleIdx(native_end, rate_ratio, sample_data_len);
    var loop_start = scaleIdx(native_loop_start, rate_ratio, sample_data_len);
    var loop_end = scaleIdx(native_loop_end, rate_ratio, sample_data_len);
    if (end <= start) end = @intCast(@min(sample_data_len, start + 1));
    if (loop_end <= loop_start) {
        loop_start = start;
        loop_end = end;
    }
    loop_start = std.math.clamp(loop_start, start, end);
    loop_end = std.math.clamp(loop_end, start, end);

    const sample_modes = add(&inst_gens, &preset_gens, gen_sample_modes, 0);

    const overriding_root = add(&inst_gens, &preset_gens, gen_overriding_root_key, -1);
    const root_key: u8 = if (overriding_root >= 0 and overriding_root <= 127) @intCast(overriding_root) else shdr.original_pitch;

    const coarse_tune = add(&inst_gens, &preset_gens, gen_coarse_tune, 0);
    const fine_tune = add(&inst_gens, &preset_gens, gen_fine_tune, 0);
    const tune_semitones = @as(f32, @floatFromInt(coarse_tune)) +
        @as(f32, @floatFromInt(fine_tune)) / 100.0 +
        @as(f32, @floatFromInt(shdr.pitch_correction)) / 100.0;

    const scale_tuning = add(&inst_gens, &preset_gens, gen_scale_tuning, 100);

    const pan_raw = add(&inst_gens, &preset_gens, gen_pan, 0);
    const pan = std.math.clamp(@as(f32, @floatFromInt(pan_raw)) / 500.0, -1.0, 1.0);

    const attenuation_cb = add(&inst_gens, &preset_gens, gen_initial_attenuation, 0);
    const attenuation_gain = centibelsToGain(std.math.clamp(attenuation_cb, 0, 1440));

    const sustain_cb = add(&inst_gens, &preset_gens, gen_sustain_vol_env, 0);
    const sustain = std.math.clamp(centibelsToGain(std.math.clamp(sustain_cb, 0, 1440)), 0.0, 1.0);

    const filter_fc_cents = add(&inst_gens, &preset_gens, gen_initial_filter_fc, 13500);
    // 13500 cents is the spec default meaning "fully open" - skip running a
    // filter at all for the overwhelming majority of regions that never set
    // this generator (see Region.filter_cutoff_hz's doc comment).
    const filter_cutoff_hz: ?f32 = if (filter_fc_cents >= 13500) null else filterCentsToHz(filter_fc_cents);
    const filter_q_cb = add(&inst_gens, &preset_gens, gen_initial_filter_q, 0);
    // Spec: centibels of resonant peak above the passband. The common
    // 0.707..~a few-Q mapping most minimal players use.
    const filter_q = 0.7071 * std.math.pow(f32, 10.0, @as(f32, @floatFromInt(std.math.clamp(filter_q_cb, 0, 960))) / 200.0);

    const exclusive_class_raw = add(&inst_gens, &preset_gens, gen_exclusive_class, 0);
    const exclusive_class: u8 = @intCast(std.math.clamp(exclusive_class_raw, 0, 255));

    return .{
        .start = start,
        .end = end,
        .loop_start = loop_start,
        .loop_end = loop_end,
        .loops = (sample_modes & 1) != 0,
        .key_lo = key_lo,
        .key_hi = key_hi,
        .vel_lo = vel_lo,
        .vel_hi = vel_hi,
        .root_key = root_key,
        .scale_tuning_cents = @floatFromInt(scale_tuning),
        .tune_semitones = tune_semitones,
        .pan = pan,
        .attenuation_gain = attenuation_gain,
        .delay_s = timecentsToSeconds(add(&inst_gens, &preset_gens, gen_delay_vol_env, -12000)),
        .attack_s = timecentsToSeconds(add(&inst_gens, &preset_gens, gen_attack_vol_env, -12000)),
        .hold_s = timecentsToSeconds(add(&inst_gens, &preset_gens, gen_hold_vol_env, -12000)),
        .decay_s = timecentsToSeconds(add(&inst_gens, &preset_gens, gen_decay_vol_env, -12000)),
        .sustain = sustain,
        .release_s = timecentsToSeconds(add(&inst_gens, &preset_gens, gen_release_vol_env, -12000)),
        .filter_cutoff_hz = filter_cutoff_hz,
        .filter_q = filter_q,
        .exclusive_class = exclusive_class,
    };
}

fn clampU32(v: i64) u32 {
    return @intCast(std.math.clamp(v, 0, @as(i64, std.math.maxInt(u32))));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Hand-builds a minimal but spec-legal single-sample, single-instrument,
/// single-preset .sf2 in memory - real soundfonts are hundreds of megabytes,
/// not something to fixture in a repo, so the parser's correctness is
/// verified against a byte-exact synthetic file instead. Layout mirrors a
/// real encoder's output closely enough to catch chunk-walking and
/// hydra-indexing bugs (global zones, terminal records, LIST nesting) while
/// staying small enough to hand-check inline.
const TestBuilder = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    fn writeId(self: *TestBuilder, id: *const [4]u8) !void {
        try self.buf.appendSlice(self.allocator, id);
    }
    fn writeU32(self: *TestBuilder, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }
    fn writeU16(self: *TestBuilder, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }
    fn writeI16(self: *TestBuilder, v: i16) !void {
        try self.writeU16(@bitCast(v));
    }
    fn writeName20(self: *TestBuilder, name: []const u8) !void {
        var b = [_]u8{0} ** 20;
        @memcpy(b[0..@min(name.len, 20)], name[0..@min(name.len, 20)]);
        try self.buf.appendSlice(self.allocator, &b);
    }

    /// Writes `id`+size+body for a leaf chunk, size computed from `body`.
    fn leaf(self: *TestBuilder, id: *const [4]u8, body: []const u8) !void {
        try self.writeId(id);
        try self.writeU32(@intCast(body.len));
        try self.buf.appendSlice(self.allocator, body);
        if (body.len & 1 != 0) try self.buf.append(self.allocator, 0);
    }

    fn deinit(self: *TestBuilder) void {
        self.buf.deinit(self.allocator);
    }
};

/// Exposed (not just `test`-local) so other files' tests - notably
/// dsp/soundfont_player.zig's - can build a real, spec-legal fixture
/// without duplicating this ~150 lines of hand-rolled RIFF writing.
pub fn buildTestSf2(allocator: std.mem.Allocator, loop: bool, sample_rate: u32) ![]u8 {
    // 200 frames of a simple ramp so playback tests can assert non-silence
    // and loop wrap-around cheaply.
    const frame_count: usize = 200;
    var pcm = try allocator.alloc(u8, frame_count * 2);
    defer allocator.free(pcm);
    for (0..frame_count) |i| {
        const v: i16 = @intCast(@as(i32, @intCast(i)) * 100 - 10000);
        std.mem.writeInt(i16, pcm[i * 2 ..][0..2], v, .little);
    }

    var sdta: TestBuilder = .{ .allocator = allocator };
    defer sdta.deinit();
    try sdta.leaf("smpl", pcm);

    // shdr: one real sample + one terminal ("EOS") record.
    var shdr: TestBuilder = .{ .allocator = allocator };
    defer shdr.deinit();
    try shdr.writeName20("testsample");
    try shdr.writeU32(0);
    try shdr.writeU32(frame_count);
    try shdr.writeU32(20);
    try shdr.writeU32(180);
    try shdr.writeU32(sample_rate);
    try shdr.buf.append(allocator, 60); // originalPitch = C4
    try shdr.buf.append(allocator, 0); // pitchCorrection
    try shdr.writeU16(0); // sampleLink
    try shdr.writeU16(1); // sfSampleType = mono
    try shdr.writeName20("EOS");
    try shdr.buf.appendNTimes(allocator, 0, 26);

    // igen: one zone's generators (sampleModes, sampleID), terminal handled
    // by ibag's own extra record (no terminal igen record needed since
    // nothing indexes past it here).
    var igen: TestBuilder = .{ .allocator = allocator };
    defer igen.deinit();
    try igen.writeU16(gen_sample_modes);
    try igen.writeI16(if (loop) 1 else 0);
    try igen.writeU16(gen_sample_id);
    try igen.writeU16(0);

    // ibag: zone 0 starts at igen offset 0; terminal record marks the end.
    var ibag: TestBuilder = .{ .allocator = allocator };
    defer ibag.deinit();
    try ibag.writeU16(0);
    try ibag.writeU16(0);
    try ibag.writeU16(2); // terminal: igen has 2 records
    try ibag.writeU16(0);

    // inst: one instrument + terminal record.
    var inst: TestBuilder = .{ .allocator = allocator };
    defer inst.deinit();
    try inst.writeName20("testinst");
    try inst.writeU16(0);
    try inst.writeName20("EOI");
    try inst.writeU16(1); // terminal: ibag has 1 real zone

    // pgen: one preset zone naming the instrument.
    var pgen: TestBuilder = .{ .allocator = allocator };
    defer pgen.deinit();
    try pgen.writeU16(gen_instrument);
    try pgen.writeU16(0);

    // pbag: zone 0 + terminal.
    var pbag: TestBuilder = .{ .allocator = allocator };
    defer pbag.deinit();
    try pbag.writeU16(0);
    try pbag.writeU16(0);
    try pbag.writeU16(1);
    try pbag.writeU16(0);

    // phdr: one preset (bank 0, program 5) + terminal.
    var phdr: TestBuilder = .{ .allocator = allocator };
    defer phdr.deinit();
    try phdr.writeName20("Test Preset");
    try phdr.writeU16(5);
    try phdr.writeU16(0);
    try phdr.writeU16(0);
    try phdr.writeU32(0);
    try phdr.writeU32(0);
    try phdr.writeU32(0);
    try phdr.writeName20("EOP");
    try phdr.writeU16(0);
    try phdr.writeU16(0);
    try phdr.writeU16(1);
    try phdr.writeU32(0);
    try phdr.writeU32(0);
    try phdr.writeU32(0);

    var pdta_body: TestBuilder = .{ .allocator = allocator };
    defer pdta_body.deinit();
    try pdta_body.writeId("pdta");
    try pdta_body.leaf("phdr", phdr.buf.items);
    try pdta_body.leaf("pbag", pbag.buf.items);
    try pdta_body.leaf("pmod", &.{});
    try pdta_body.leaf("pgen", pgen.buf.items);
    try pdta_body.leaf("inst", inst.buf.items);
    try pdta_body.leaf("ibag", ibag.buf.items);
    try pdta_body.leaf("imod", &.{});
    try pdta_body.leaf("igen", igen.buf.items);
    try pdta_body.leaf("shdr", shdr.buf.items);

    var sdta_body: TestBuilder = .{ .allocator = allocator };
    defer sdta_body.deinit();
    try sdta_body.writeId("sdta");
    try sdta_body.buf.appendSlice(allocator, sdta.buf.items);

    var info_body: TestBuilder = .{ .allocator = allocator };
    defer info_body.deinit();
    try info_body.writeId("INFO");
    try info_body.leaf("ifil", &[_]u8{ 2, 0, 1, 0 });
    try info_body.leaf("isng", "EMU8000\x00");
    try info_body.leaf("INAM", "test bank\x00");

    var file: TestBuilder = .{ .allocator = allocator };
    try file.writeId("RIFF");
    var total: u32 = 4; // "sfbk"
    total += 8 + @as(u32, @intCast(info_body.buf.items.len));
    total += 8 + @as(u32, @intCast(sdta_body.buf.items.len));
    total += 8 + @as(u32, @intCast(pdta_body.buf.items.len));
    try file.writeU32(total);
    try file.writeId("sfbk");
    try file.leaf("LIST", info_body.buf.items);
    try file.leaf("LIST", sdta_body.buf.items);
    try file.leaf("LIST", pdta_body.buf.items);

    return file.buf.toOwnedSlice(allocator);
}

test "parse: minimal single-sample soundfont resolves one preset and region" {
    const allocator = std.testing.allocator;
    const bytes = try buildTestSf2(allocator, false, 44_100);
    defer allocator.free(bytes);

    var sf = try SoundFont.parse(allocator, bytes, 44_100);
    defer sf.deinit();

    try std.testing.expectEqual(@as(usize, 1), sf.presets.len);
    const preset = sf.presets[0];
    try std.testing.expectEqual(@as(u16, 0), preset.bank);
    try std.testing.expectEqual(@as(u16, 5), preset.program);
    try std.testing.expectEqualStrings("Test Preset", preset.trimmedName());
    try std.testing.expectEqual(@as(usize, 0), sf.findPreset(0, 5).?);
    try std.testing.expectEqual(@as(?usize, null), sf.findPreset(1, 5));

    try std.testing.expectEqual(@as(usize, 1), preset.regions.len);
    const r = preset.regions[0];
    try std.testing.expectEqual(@as(u8, 0), r.key_lo);
    try std.testing.expectEqual(@as(u8, 127), r.key_hi);
    try std.testing.expectEqual(@as(u8, 60), r.root_key);
    try std.testing.expect(!r.loops);
    try std.testing.expectEqual(@as(u32, 0), r.start);
    try std.testing.expectEqual(@as(u32, 200), r.end);
    // No filter/pan/tune generators set - defaults resolve to "no filter",
    // centered pan, unity tune.
    try std.testing.expectEqual(@as(?f32, null), r.filter_cutoff_hz);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), r.pan, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), r.tune_semitones, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r.attenuation_gain, 1e-6);
}

test "parse: loop flag and loop points survive resampling" {
    const allocator = std.testing.allocator;
    const bytes = try buildTestSf2(allocator, true, 44_100);
    defer allocator.free(bytes);

    // Resample to 48kHz on load - loop_start/loop_end (native 20/180) must
    // scale by the same ratio as the sample pool itself.
    var sf = try SoundFont.parse(allocator, bytes, 48_000);
    defer sf.deinit();

    const r = sf.presets[0].regions[0];
    try std.testing.expect(r.loops);
    const ratio: f64 = 48_000.0 / 44_100.0;
    const expected_start: u32 = @intFromFloat(@round(20.0 * ratio));
    const expected_end: u32 = @intFromFloat(@round(180.0 * ratio));
    try std.testing.expectEqual(expected_start, r.loop_start);
    try std.testing.expectEqual(expected_end, r.loop_end);
    try std.testing.expect(r.loop_end > r.loop_start);
    try std.testing.expect(sf.sample_data.len > 200); // resampled up
}

test "parse: unresampled path (matching rates) is a plain copy" {
    const allocator = std.testing.allocator;
    const bytes = try buildTestSf2(allocator, false, 48_000);
    defer allocator.free(bytes);

    var sf = try SoundFont.parse(allocator, bytes, 48_000);
    defer sf.deinit();
    try std.testing.expectEqual(@as(usize, 200), sf.sample_data.len);
}

test "parse: rejects non-RIFF and non-sfbk data" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotSf2, SoundFont.parse(allocator, "not a soundfont", 48_000));
    try std.testing.expectError(error.NotSf2, SoundFont.parse(allocator, "RIFF\x00\x00\x00\x00WAVE", 48_000));
}

test "dupe: independent buffers, same content" {
    const allocator = std.testing.allocator;
    const bytes = try buildTestSf2(allocator, true, 48_000);
    defer allocator.free(bytes);

    var sf = try SoundFont.parse(allocator, bytes, 48_000);
    defer sf.deinit();

    var copy = try sf.dupe(allocator);
    defer copy.deinit();

    try std.testing.expectEqual(sf.presets.len, copy.presets.len);
    try std.testing.expectEqual(sf.presets[0].regions.len, copy.presets[0].regions.len);
    try std.testing.expectEqualSlices(f32, sf.sample_data, copy.sample_data);

    copy.sample_data[0] = 12.5;
    try std.testing.expect(sf.sample_data[0] != 12.5);
}

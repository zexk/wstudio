//! Dumps everything needed to judge the factory synth presets as a set:
//! what each one is, what it actually sounds like, and which other preset it
//! is closest to.
//!
//! The drum kits could be judged by reading `variants` - 12 entries, a dozen
//! numbers each. The synth presets can't: ~100 patches with ~150 fields, where
//! the fields that matter differ per patch (a pad is defined by its envelope,
//! a bass by its filter). So this measures instead of listing:
//!
//!   1. Every preset is rendered through real `PolySynth` at three probes -
//!      low/soft, middle, high/hard - and reduced to features you can sort a
//!      table by: where its energy sits, how fast it starts and stops, how
//!      wide, how noisy and how much it moves while held. One probe is not
//!      enough: at a single note a bass and an electric piano measure alike,
//!      and it is the response across register and velocity that separates
//!      them.
//!   2. Every preset is compared to every other one, using patch fields
//!      (reflected, so nothing needs listing here) and those features.
//!      Two presets can be near-identical patches that sound different, or
//!      different patches that sound the same; both are worth knowing, so
//!      both distances are reported.
//!
//! The pair report at the end is the actual answer to "which of these are
//! redundant": for the closest pairs it prints which patch fields differ and
//! by how much, which is what tells you whether one can fold into the other
//! as a variation or whether they are genuinely two sounds.
//!
//! Usage: `zig build presetscan [-- --note 48 --pairs 30 --category bass
//!                                --same-category]`
//! `--note` moves the middle probe; the other two follow an octave and a third
//! either side of it.
//! Nothing is asserted and the exit code is always 0 - this reports, it does
//! not judge. The judging is the point of reading it.

const std = @import("std");
const ws = @import("wstudio");

const Sample = ws.types.Sample;
const PolySynth = ws.dsp.synth.PolySynth;
const Patch = PolySynth.Patch;
const presets = ws.dsp.synth_presets.presets;

const sample_rate: u32 = 48_000;
const block_frames: usize = 256;
/// Note held this long, then released and left to ring. Long enough that a
/// 0.9 s pad attack finishes inside the hold, short enough that 100 presets
/// full library still renders in a couple of seconds.
const hold_s: f32 = 1.5;
const tail_s: f32 = 2.0;
/// Spectrum window, taken from the middle of the hold so it sees the sustain
/// rather than the attack transient.
const fft_size: usize = 8192;
/// Shorter window, hopped across the hold, for the motion features. A patch's
/// LFO/arp/beating identity lives in how the spectrum changes while it is
/// held, which a single snapshot cannot see.
const motion_fft_size: usize = 2048;
const motion_frames: usize = 12;
/// Crossover for the low-band correlation: the accepted line under which a
/// mix is kept mono for punch and club/mono compatibility.
const low_width_hz: f32 = 120.0;

/// Band edges in Hz. Three bands lump a 3.3-octave middle together, which is
/// where most of the library's timbral difference actually sits.
const band_edges = [_]f32{ 100, 250, 600, 1500, 4000 };
const band_count = band_edges.len + 1;

/// Note and velocity of each render. Spans register and velocity at once
/// rather than orthogonally: for a similarity scan, two patches that respond
/// differently to either axis diverge just as well on the diagonal, at a third
/// of the renders.
const Probe = struct { semi: i8, vel: f32 };
const probes = [_]Probe{
    .{ .semi = -16, .vel = 0.45 },
    .{ .semi = 0, .vel = 0.8 },
    .{ .semi = 16, .vel = 1.0 },
};

const Features = struct {
    peak: f32 = 0,
    rms: f32 = 0,
    /// Peak over RMS. High means transient (a pluck), low means sustained.
    crest: f32 = 0,
    /// Time from note-on to 90% of peak.
    attack_ms: f32 = 0,
    /// RMS over the last 200 ms of the hold, relative to the loudest 200 ms.
    /// ~1 means it sustains, ~0 means it decayed away while still held.
    sustain: f32 = 0,
    /// Time from note-off until the tail drops 40 dB below the hold's RMS.
    release_ms: f32 = 0,
    centroid_hz: f32 = 0,
    /// Geometric over arithmetic mean of the spectrum: ~0 is a clean tone,
    /// toward 1 is noise.
    flatness: f32 = 0,
    /// Share of spectral energy in each `band_edges` band.
    bands: [band_count]f32 = @splat(0),
    /// 1 - |correlation(L, R)|. 0 is mono, 1 is fully decorrelated.
    width: f32 = 0,
    /// The same correlation measured below `low_width_hz`. Width up here is
    /// a choice; width in the sub is a defect - it cancels on a mono club
    /// system and costs level. The sub oscillator is summed centre, so
    /// anything this reports comes from spread oscillators or a stereo FX
    /// unit smearing the low end.
    low_width: f32 = 0,
    /// Spread of the centroid across the hold, in octaves: a filter sweep, a
    /// wobble or a vowel scan reads high, a static tone reads 0.
    centroid_mod: f32 = 0,
    /// Spread of the frame RMS over its mean across the hold: tremolo, gating
    /// and arp motion read high.
    amp_mod: f32 = 0,
    /// Mean sample value over the hold, against the RMS. Offset costs
    /// headroom, and any patch that ends with a non-zero level clicks when
    /// the voice is cut.
    dc: f32 = 0,
};

const Row = struct {
    name: []const u8,
    category: []const u8,
    tags: []const []const u8,
    patch: Patch,
    f: [probes.len]Features,
    /// dB between a soft and a hard hit at the same note, and how far the
    /// tone moves with it. A patch that answers the keyboard with neither is
    /// the same sound however it is played.
    vel_db: f32 = 0,
    vel_tone: f32 = 0,
    mod_rows: usize,
    fx_count: usize,
    arp: bool,
    /// Filled in by the pair pass.
    near_patch: usize = 0,
    near_patch_d: f32 = 0,
    near_audio: usize = 0,
    near_audio_d: f32 = 0,
};

// ---------------------------------------------------------------------------
// Rendering

/// Renders through a whole Rack, not a bare PolySynth. A patch's `fx_*`
/// fields are not synth parameters at all - nothing in the DSP layer reads
/// them - they are instructions for building the rack's insert chain, which
/// `applySynthPatch` does. Rendering the synth alone therefore measured every
/// preset dry, and a preset whose identity IS its chain (a tape-degraded pad,
/// a reverb-tail rumble, anything driven) measured as its bare oscillators.
fn render(allocator: std.mem.Allocator, preset: ws.dsp.synth_presets.Preset, note: u7, vel: f32) ![]Sample {
    var rack = ws.Rack{
        .instrument = .{ .poly_synth = try PolySynth.init(allocator, sample_rate) },
        .label = "presetscan",
    };
    defer rack.deinit(allocator);
    var displaced = try ws.persist.applySynthPreset(allocator, &rack, preset, sample_rate);
    displaced.deinit(allocator);
    const synth = &rack.instrument.poly_synth;

    const srf: f32 = @floatFromInt(sample_rate);
    const hold_frames: usize = @intFromFloat(hold_s * srf);
    const total_frames: usize = @intFromFloat((hold_s + tail_s) * srf);
    const buf = try allocator.alloc(Sample, total_frames * 2);
    @memset(buf, 0);

    synth.noteOn(note, vel);
    var done: usize = 0;
    while (done < total_frames) {
        var n: usize = @min(block_frames, total_frames - done);
        // Never straddle the note-off: it lands on a block boundary.
        if (done < hold_frames) n = @min(n, hold_frames - done);
        const chunk = buf[done * 2 ..][0 .. n * 2];
        synth.processBlock(chunk);
        for (rack.fx.units.items) |unit| unit.device().process(chunk);
        done += n;
        if (done == hold_frames) synth.noteOff(note);
    }
    return buf;
}

fn rmsOf(buf: []const Sample) f32 {
    if (buf.len == 0) return 0;
    var sum: f64 = 0;
    for (buf) |s| sum += @as(f64, s) * @as(f64, s);
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(buf.len))));
}

fn analyze(allocator: std.mem.Allocator, buf: []const Sample) !Features {
    const srf: f32 = @floatFromInt(sample_rate);
    const hold_frames: usize = @intFromFloat(hold_s * srf);
    const frames = buf.len / 2;
    var f: Features = .{};
    var peak_frame: usize = 0;

    for (0..frames) |i| {
        const peak = @max(@abs(buf[i * 2]), @abs(buf[i * 2 + 1]));
        if (peak > f.peak) {
            f.peak = peak;
            peak_frame = i;
        }
    }
    f.rms = rmsOf(buf);
    f.crest = if (f.rms > 1e-9) f.peak / f.rms else 0;
    if (f.peak < 1e-6) return f; // silent patch: the rest would be noise

    {
        var sum: f64 = 0;
        for (0..hold_frames) |i| sum += @as(f64, buf[i * 2]) + buf[i * 2 + 1];
        const mean = sum / @as(f64, @floatFromInt(hold_frames * 2));
        f.dc = if (f.rms > 1e-9) @floatCast(@abs(mean) / f.rms) else 0;
    }

    // Attack: first frame reaching 90% of peak.
    for (0..frames) |i| {
        if (@max(@abs(buf[i * 2]), @abs(buf[i * 2 + 1])) >= f.peak * 0.9) {
            f.attack_ms = @as(f32, @floatFromInt(i)) / srf * 1000.0;
            break;
        }
    }

    // Sustain: last 200 ms of the hold against the loudest 200 ms window.
    const win: usize = @intFromFloat(0.2 * srf);
    var loudest: f32 = 0;
    var w: usize = 0;
    while (w + win <= hold_frames) : (w += win) {
        loudest = @max(loudest, rmsOf(buf[w * 2 ..][0 .. win * 2]));
    }
    const tail_of_hold = rmsOf(buf[(hold_frames - win) * 2 ..][0 .. win * 2]);
    f.sustain = if (loudest > 1e-9) tail_of_hold / loudest else 0;

    // Release: how long after note-off until 40 dB below the hold.
    const floor = loudest * 0.01;
    f.release_ms = @as(f32, @floatFromInt(frames - hold_frames)) / srf * 1000.0;
    var t = hold_frames;
    while (t + win <= frames) : (t += win) {
        if (rmsOf(buf[t * 2 ..][0 .. win * 2]) < floor) {
            f.release_ms = @as(f32, @floatFromInt(t - hold_frames)) / srf * 1000.0;
            break;
        }
    }

    // Stereo width from the L/R correlation over the hold, full band and
    // again below the crossover where mono is not a style choice.
    var sxy: f64 = 0;
    var sxx: f64 = 0;
    var syy: f64 = 0;
    var lxy: f64 = 0;
    var lxx: f64 = 0;
    var lyy: f64 = 0;
    // One-pole lowpass per channel, so the second correlation sees the sub.
    const lp_a: f64 = @exp(-2.0 * std.math.pi * @as(f64, low_width_hz) / @as(f64, srf));
    var lp_l: f64 = 0;
    var lp_r: f64 = 0;
    for (0..hold_frames) |i| {
        const l: f64 = buf[i * 2];
        const r: f64 = buf[i * 2 + 1];
        sxy += l * r;
        sxx += l * l;
        syy += r * r;
        lp_l = (1.0 - lp_a) * l + lp_a * lp_l;
        lp_r = (1.0 - lp_a) * r + lp_a * lp_r;
        lxy += lp_l * lp_r;
        lxx += lp_l * lp_l;
        lyy += lp_r * lp_r;
    }
    const denom = @sqrt(sxx * syy);
    f.width = if (denom > 1e-12) 1.0 - @abs(@as(f32, @floatCast(sxy / denom))) else 0;
    const low_denom = @sqrt(lxx * lyy);
    f.low_width = if (low_denom > 1e-12) 1.0 - @abs(@as(f32, @floatCast(lxy / low_denom))) else 0;

    // Center spectrum on loudest frame. Mid-hold is silent for plucks, which
    // would collapse distinct transient sounds to the same zero vector.
    const start = @min(peak_frame -| fft_size / 2, hold_frames - fft_size);
    const held = try spectrumAt(allocator, buf, start, fft_size);
    f.centroid_hz = held.centroid_hz;
    f.flatness = held.flatness;
    f.bands = held.bands;

    // Motion: how far the spectrum and the level wander over the hold. Frames
    // start after the onset so the attack transient does not read as movement,
    // but never later than mid-hold: a gated pad or an arp peaks near the END
    // of the hold, and anchoring to the peak left no room for frames at all,
    // so the patches whose whole identity is movement measured as static.
    const motion_start = @max(win, @min(peak_frame, hold_frames / 2));
    const span = hold_frames -| (motion_start + motion_fft_size);
    const hop = span / motion_frames;
    if (hop > 0) {
        var oct: [motion_frames]f32 = undefined;
        var lvl: [motion_frames]f32 = undefined;
        var n: usize = 0;
        for (0..motion_frames) |i| {
            const at = motion_start + i * hop;
            const s = try spectrumAt(allocator, buf, at, motion_fft_size);
            const level = rmsOf(buf[at * 2 ..][0 .. motion_fft_size * 2]);
            // A frame that has decayed into the noise floor has no meaningful
            // centroid; counting it would read decay as modulation.
            if (s.centroid_hz < 1.0 or level < f.peak * 0.01) continue;
            oct[n] = @log2(s.centroid_hz);
            lvl[n] = level;
            n += 1;
        }
        if (n > 1) {
            f.centroid_mod = stdDev(oct[0..n]);
            const mean_lvl = blk: {
                var sum: f32 = 0;
                for (lvl[0..n]) |x| sum += x;
                break :blk sum / @as(f32, @floatFromInt(n));
            };
            f.amp_mod = if (mean_lvl > 1e-9) stdDev(lvl[0..n]) / mean_lvl else 0;
        }
    }
    return f;
}

fn stdDev(xs: []const f32) f32 {
    var sum: f64 = 0;
    for (xs) |x| sum += x;
    const mean = sum / @as(f64, @floatFromInt(xs.len));
    var acc: f64 = 0;
    for (xs) |x| {
        const d = @as(f64, x) - mean;
        acc += d * d;
    }
    return @floatCast(@sqrt(acc / @as(f64, @floatFromInt(xs.len))));
}

const Spectrum = struct {
    centroid_hz: f32 = 0,
    flatness: f32 = 0,
    bands: [band_count]f32 = @splat(0),
};

fn spectrumAt(allocator: std.mem.Allocator, buf: []const Sample, start: usize, comptime size: usize) !Spectrum {
    const frames = buf.len / 2;
    const real = try allocator.alloc(f32, size);
    defer allocator.free(real);
    const imag = try allocator.alloc(f32, size);
    defer allocator.free(imag);
    @memset(imag, 0);
    for (0..size) |i| {
        const idx = start + i;
        const mono = if (idx < frames) (buf[idx * 2] + buf[idx * 2 + 1]) * 0.5 else 0;
        const phase = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, size);
        real[i] = mono * 0.5 * (1.0 - @cos(phase));
    }
    ws.dsp.fft.fft(size, real, imag);

    var out: Spectrum = .{};
    var mag_sum: f64 = 0;
    var weighted: f64 = 0;
    var log_sum: f64 = 0;
    var bands: [band_count]f64 = @splat(0);
    const bin_hz = @as(f32, @floatFromInt(sample_rate)) / @as(f32, size);
    for (0..size / 2) |i| {
        const mag = @sqrt(real[i] * real[i] + imag[i] * imag[i]);
        const hz = @as(f32, @floatFromInt(i)) * bin_hz;
        mag_sum += mag;
        weighted += @as(f64, mag) * hz;
        log_sum += @log(@as(f64, mag) + 1e-12);
        var b: usize = 0;
        while (b < band_edges.len and hz >= band_edges[b]) : (b += 1) {}
        bands[b] += mag;
    }
    if (mag_sum > 1e-12) {
        out.centroid_hz = @floatCast(weighted / mag_sum);
        const geo = @exp(log_sum / @as(f64, size / 2));
        const arith = mag_sum / @as(f64, size / 2);
        out.flatness = @floatCast(geo / arith);
        for (&out.bands, bands) |*dst, b| dst.* = @floatCast(b / mag_sum);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Patch comparison
//
// Reflected rather than listed: a hand-written field list would be 150 lines
// that go stale the first time someone adds a knob. Only scalar fields take
// part - arrays (mod_matrix, LFO shapes), pointers and the synth's runtime
// state carry no patch identity, and `mod_matrix` gets counted separately.

fn isScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .int, .bool, .@"enum" => true,
        .optional => |o| isScalar(o.child),
        else => false,
    };
}

/// A field's value as a float, for distance and for printing. Optionals read
/// as their payload, or as `fallback` when null (null means "inherit", so it
/// should not read as a big jump from whatever it inherits).
fn scalarValue(comptime T: type, v: T, fallback: f32) f32 {
    return switch (@typeInfo(T)) {
        .float => @floatCast(v),
        .int => @floatFromInt(v),
        .bool => if (v) 1.0 else 0.0,
        .@"enum" => @floatFromInt(@intFromEnum(v)),
        .optional => |o| if (v) |inner| scalarValue(o.child, inner, fallback) else fallback,
        else => unreachable,
    };
}

const scalar_fields = blk: {
    @setEvalBranchQuota(50_000);
    var names: []const []const u8 = &.{};
    for (@typeInfo(Patch).@"struct".fields) |fld| {
        if (isScalar(fld.type)) names = names ++ [_][]const u8{fld.name};
    }
    break :blk names;
};

/// Per-field spread across the whole preset set, so distance is in units of
/// "how much this field varies at all" rather than raw Hz vs seconds. Standard
/// deviation, not min-to-max: one preset with a 20 kHz filter2 cutoff would
/// otherwise squash every ordinary difference in that field to nothing.
const Scales = [scalar_fields.len]f32;

fn fieldValue(comptime name: []const u8, p: Patch) f32 {
    const T = @FieldType(Patch, name);
    return scalarValue(T, @field(p, name), 0);
}

fn computeScales(rows: []const Row) Scales {
    @setEvalBranchQuota(50_000);
    var out: Scales = undefined;
    const n: f64 = @floatFromInt(rows.len);
    inline for (scalar_fields, 0..) |name, i| {
        var sum: f64 = 0;
        for (rows) |r| sum += fieldValue(name, r.patch);
        const mean = sum / n;
        var acc: f64 = 0;
        for (rows) |r| {
            const d = fieldValue(name, r.patch) - mean;
            acc += d * d;
        }
        const sd = @sqrt(acc / n);
        out[i] = if (sd > 1e-9) @floatCast(sd) else 1.0;
    }
    return out;
}

fn patchDistance(a: Patch, b: Patch, scales: Scales) f32 {
    @setEvalBranchQuota(50_000);
    var sum: f32 = 0;
    inline for (scalar_fields, 0..) |name, i| {
        const d = (fieldValue(name, a) - fieldValue(name, b)) / scales[i];
        sum += d * d;
    }
    return @sqrt(sum / @as(f32, scalar_fields.len));
}

const probe_dims = 7 + band_count;
/// Every probe's features end to end, plus width once. Width barely moves
/// between probes, so repeating it per probe would weight unison spread three
/// times as heavily as anything else.
const audio_dims = probes.len * probe_dims + 1;

fn featureVector(fs: [probes.len]Features) [audio_dims]f32 {
    var out: [audio_dims]f32 = undefined;
    for (fs, 0..) |f, p| {
        // Log where the scale is multiplicative, so 20 ms vs 40 ms counts as
        // much as 200 ms vs 400 ms.
        var v: [probe_dims]f32 = .{
            @log10(f.centroid_hz + 20.0),
            f.flatness,
            @log10(f.attack_ms + 1.0),
            @log10(f.release_ms + 1.0),
            f.sustain,
            f.centroid_mod,
            f.amp_mod,
        } ++ @as([band_count]f32, @splat(0));
        @memcpy(v[7..], &f.bands);
        @memcpy(out[p * probe_dims ..][0..probe_dims], &v);
    }
    out[audio_dims - 1] = fs[probes.len / 2].width;
    return out;
}

fn audioDistance(a: [probes.len]Features, b: [probes.len]Features, scales: [audio_dims]f32) f32 {
    const va = featureVector(a);
    const vb = featureVector(b);
    var sum: f32 = 0;
    for (va, vb, scales) |x, y, s| {
        const d = (x - y) / s;
        sum += d * d;
    }
    return @sqrt(sum / @as(f32, audio_dims));
}

// ---------------------------------------------------------------------------

/// Legacy `fx_*` carriers still count, but the library declares its chain
/// generically now, so the preset's own list is the bulk of it.
fn countFx(p: Patch) usize {
    @setEvalBranchQuota(50_000);
    var n: usize = 0;
    inline for (@typeInfo(Patch).@"struct".fields) |fld| {
        if (fld.type == bool and std.mem.startsWith(u8, fld.name, "fx_") and
            std.mem.endsWith(u8, fld.name, "_on"))
        {
            if (@field(p, fld.name)) n += 1;
        }
    }
    return n;
}

fn countModRows(p: Patch) usize {
    var n: usize = 0;
    for (p.mod_matrix) |row| {
        if (row.depth != 0) n += 1;
    }
    return n;
}

/// The fields where two patches differ, worst first: the "why are these two
/// different" answer for a close pair.
fn printDiff(w: anytype, a: Patch, b: Patch, scales: Scales, limit: usize) !void {
    @setEvalBranchQuota(50_000);
    const Item = struct { name: []const u8, a: f32, b: f32, d: f32 };
    var items: [scalar_fields.len]Item = undefined;
    var n: usize = 0;
    inline for (scalar_fields, 0..) |name, i| {
        const va = fieldValue(name, a);
        const vb = fieldValue(name, b);
        if (va != vb) {
            items[n] = .{ .name = name, .a = va, .b = vb, .d = @abs(va - vb) / scales[i] };
            n += 1;
        }
    }
    std.mem.sort(Item, items[0..n], {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return x.d > y.d;
        }
    }.lt);
    for (items[0..@min(n, limit)]) |it| {
        try w.print("      {s: <22} {d: >10.3} | {d: >10.3}\n", .{ it.name, it.a, it.b });
    }
    if (n > limit) try w.print("      ... and {d} more fields\n", .{n - limit});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var note: u7 = 52; // middle probe; the outer two sit +/- 16 semitones
    var pair_count: usize = 25;
    var only_category: ?[]const u8 = null;
    var same_category_only = false;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--note")) {
            note = std.fmt.parseInt(u7, args.next() orelse "52", 10) catch 52;
        } else if (std.mem.eql(u8, arg, "--pairs")) {
            pair_count = std.fmt.parseInt(usize, args.next() orelse "25", 10) catch 25;
        } else if (std.mem.eql(u8, arg, "--category")) {
            only_category = args.next();
        } else if (std.mem.eql(u8, arg, "--same-category")) {
            same_category_only = true;
        }
    }

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(allocator);

    for (presets) |p| {
        if (only_category) |c| {
            if (!std.mem.eql(u8, c, p.category)) continue;
        }
        var features: [probes.len]Features = undefined;
        for (probes, 0..) |probe, i| {
            const at: u7 = @intCast(std.math.clamp(@as(i16, note) + probe.semi, 0, 127));
            const buf = try render(allocator, p, at, probe.vel);
            defer allocator.free(buf);
            features[i] = try analyze(allocator, buf);
        }
        // A fourth render, same note as the middle probe but played softly,
        // so velocity response is read on its own axis instead of being
        // tangled up with register.
        const soft = blk: {
            const buf = try render(allocator, p, note, 0.25);
            defer allocator.free(buf);
            break :blk try analyze(allocator, buf);
        };
        const mid = features[probes.len / 2];
        const vel_db: f32 = if (soft.rms > 1e-9 and mid.rms > 1e-9)
            20.0 * @log10(mid.rms / soft.rms)
        else
            0;
        const vel_tone: f32 = if (soft.centroid_hz > 1.0 and mid.centroid_hz > 1.0)
            @abs(@log2(mid.centroid_hz / soft.centroid_hz))
        else
            0;
        try rows.append(allocator, .{
            .name = p.name,
            .vel_db = vel_db,
            .vel_tone = vel_tone,
            .category = p.category,
            .tags = p.tags,
            .patch = p.patch,
            .f = features,
            .mod_rows = countModRows(p.patch),
            .fx_count = countFx(p.patch) + p.fx.len,
            .arp = p.patch.arp_on,
        });
    }

    if (rows.items.len == 0) {
        try w.print("No presets matched category '{s}'.\n", .{only_category.?});
        try w.flush();
        return;
    }

    const scales = computeScales(rows.items);

    // Feature spread, so the audio distance weights each feature by how much
    // it actually varies across the set (same idea as `scales`).
    var spread: [audio_dims]f32 = @splat(1.0);
    {
        var mean: [audio_dims]f32 = @splat(0);
        var acc: [audio_dims]f32 = @splat(0);
        const n: f32 = @floatFromInt(rows.items.len);
        for (rows.items) |r| {
            const v = featureVector(r.f);
            for (v, 0..) |x, i| mean[i] += x / n;
        }
        for (rows.items) |r| {
            const v = featureVector(r.f);
            for (v, 0..) |x, i| acc[i] += (x - mean[i]) * (x - mean[i]);
        }
        for (0..audio_dims) |i| {
            const sd = @sqrt(acc[i] / n);
            spread[i] = if (sd > 1e-6) sd else 1.0;
        }
    }

    // ponytail: O(n^2) over this library is cheap. If the
    // preset count ever reaches thousands, bucket by category first.
    for (rows.items, 0..) |*r, i| {
        r.near_patch_d = std.math.floatMax(f32);
        r.near_audio_d = std.math.floatMax(f32);
        for (rows.items, 0..) |o, j| {
            if (i == j) continue;
            const pd = patchDistance(r.patch, o.patch, scales);
            if (pd < r.near_patch_d) {
                r.near_patch_d = pd;
                r.near_patch = j;
            }
            const ad = audioDistance(r.f, o.f, spread);
            if (ad < r.near_audio_d) {
                r.near_audio_d = ad;
                r.near_audio = j;
            }
        }
    }

    try w.print("# {d} presets, {d} Hz, rendered at notes", .{ rows.items.len, sample_rate });
    for (probes) |p| try w.print(" {d}@vel{d:.2}", .{ @as(i16, note) + p.semi, p.vel });
    try w.print("\n# The measured columns are the middle probe; the distances use all of them.\n", .{});
    try w.print("# b1..b{d} are the share of spectral energy below {d:.0} Hz, then each band\n", .{ band_count, band_edges[0] });
    try w.print("# up to {d:.0} Hz, and above. cmod/amod are how far the centroid (octaves)\n", .{band_edges[band_edges.len - 1]});
    try w.print("# and the level wander while the note is held: 0 is a static sound.\n", .{});
    try w.print("# nearest_* are the closest other preset by patch fields and by measured sound.\n\n", .{});
    try w.print("name\tcategory\ttags\tpeak\trms\tcrest\tattack_ms\tsustain\trelease_ms\tcentroid\tflatness", .{});
    for (0..band_count) |i| try w.print("\tb{d}", .{i + 1});
    try w.print("\twidth\tlow_w\tcmod\tamod\tdc\tvel_db\tvel_tone\tmods\tfx\tarp\tnearest_patch\tpatch_d\tnearest_audio\taudio_d\n", .{});
    for (rows.items) |r| {
        const f = r.f[probes.len / 2];
        try w.print("{s}\t{s}\t", .{ r.name, r.category });
        for (r.tags, 0..) |t, i| {
            if (i > 0) try w.print(",", .{});
            try w.print("{s}", .{t});
        }
        try w.print("\t{d:.3}\t{d:.4}\t{d:.1}\t{d:.0}\t{d:.2}\t{d:.0}\t{d:.0}\t{d:.3}", .{
            f.peak,    f.rms,        f.crest,       f.attack_ms,
            f.sustain, f.release_ms, f.centroid_hz, f.flatness,
        });
        for (f.bands) |b| try w.print("\t{d:.2}", .{b});
        try w.print("\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.3}\t{d:.1}\t{d:.2}\t{d}\t{d}\t{s}\t{s}\t{d:.3}\t{s}\t{d:.3}\n", .{
            f.width,                       f.low_width,                   f.centroid_mod,
            f.amp_mod,                     f.dc,                          r.vel_db,
            r.vel_tone,                    r.mod_rows,                    r.fx_count,
            if (r.arp) "yes" else "no",    rows.items[r.near_patch].name, r.near_patch_d,
            rows.items[r.near_audio].name, r.near_audio_d,
        });
    }

    // Closest pairs, each listed once, with what actually differs.
    const Pair = struct { a: usize, b: usize, patch_d: f32, audio_d: f32 };
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    defer pairs.deinit(allocator);
    for (rows.items, 0..) |ra, i| {
        for (rows.items[i + 1 ..], i + 1..) |rb, j| {
            if (same_category_only and !std.mem.eql(u8, ra.category, rb.category)) continue;
            try pairs.append(allocator, .{
                .a = i,
                .b = j,
                .patch_d = patchDistance(ra.patch, rb.patch, scales),
                .audio_d = audioDistance(ra.f, rb.f, spread),
            });
        }
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, x: Pair, y: Pair) bool {
            return x.audio_d < y.audio_d;
        }
    }.lt);

    try w.print("\n\n# The {d} closest pairs by measured sound{s}. A pair that is close on\n", .{
        pair_count,
        if (same_category_only) ", within a category" else "",
    });
    try w.print("# BOTH distances is the same preset twice; close on audio but far on\n", .{});
    try w.print("# patch means two ways to build one sound, which is worth keeping.\n", .{});
    for (pairs.items[0..@min(pairs.items.len, pair_count)]) |p| {
        const ra = rows.items[p.a];
        const rb = rows.items[p.b];
        try w.print("\n  {s} ({s}) <-> {s} ({s})   audio_d={d:.3}  patch_d={d:.3}\n", .{
            ra.name, ra.category, rb.name, rb.category, p.audio_d, p.patch_d,
        });
        try printDiff(w, ra.patch, rb.patch, scales, 8);
    }

    // Category coverage, so a gap shows up as a thin row rather than by
    // reading 100 names.
    try w.print("\n\n# Coverage by category: count, and the mean of each feature.\n", .{});
    // `crowding` is the mean distance from each preset in the category to its
    // nearest neighbour anywhere: a low number is a category where the presets
    // sit on top of each other, which is where the next cut belongs.
    try w.print("category\tn\tcentroid\tattack_ms\trelease_ms\tsustain\tlow\thigh\tcmod\tcrowding\n", .{});
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (rows.items) |r| {
        if (seen.contains(r.category)) continue;
        try seen.put(allocator, r.category, {});
        var n: usize = 0;
        var acc: Features = .{};
        var crowding: f32 = 0;
        for (rows.items) |o| {
            if (!std.mem.eql(u8, o.category, r.category)) continue;
            const f = o.f[probes.len / 2];
            n += 1;
            acc.centroid_hz += f.centroid_hz;
            acc.attack_ms += f.attack_ms;
            acc.release_ms += f.release_ms;
            acc.sustain += f.sustain;
            acc.bands[0] += f.bands[0];
            acc.bands[band_count - 1] += f.bands[band_count - 1];
            acc.centroid_mod += f.centroid_mod;
            crowding += o.near_audio_d;
        }
        const d: f32 = @floatFromInt(n);
        try w.print("{s}\t{d}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.3}\n", .{
            r.category,           n,
            acc.centroid_hz / d,  acc.attack_ms / d,
            acc.release_ms / d,   acc.sustain / d,
            acc.bands[0] / d,     acc.bands[band_count - 1] / d,
            acc.centroid_mod / d, crowding / d,
        });
    }

    try w.flush();
}

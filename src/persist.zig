//! Project save / load.
//!
//! Serialises the live Session to a JSON file (*.wsj).  The snapshot types are
//! pure data — no pointers, no atomics, no heap slices matching the live structs.
//!
//! Round-trip guarantees:
//!   - All 38 PolySynth params + piano-roll notes + loop length
//!   - Drum step-count + per-pad bitmask patterns + per-pad sampler params
//!   - Per-track gain / pan / mute / solo + project tempo
//!   - FX: compressor, delay, reverb, EQ
//!   - Rack labels

const std = @import("std");
const Session = @import("session.zig").Session;
const Project = @import("project.zig").Project;
const ws_arrangement = @import("arrangement.zig");
const Rack = @import("rack.zig").Rack;
const engine_mod = @import("audio/engine.zig");
const Engine = engine_mod.Engine;
const synth_mod = @import("dsp/synth.zig");
const PolySynth = synth_mod.PolySynth;
const pattern_mod = @import("dsp/pattern.zig");
const PatternPlayer = pattern_mod.PatternPlayer;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const Pad = @import("dsp/drum_sampler.zig").Pad;
const Sampler = @import("dsp/sampler.zig").Sampler;
const Compressor = @import("dsp/compressor.zig").Compressor;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const eq_mod = @import("dsp/eq.zig");
const GraphicEq = eq_mod.GraphicEq;
const dsp = @import("dsp/device.zig");

/// v2 adds the arrangement (song timeline) and `song_mode`. v1 files omit both
/// and deserialize to an empty arrangement in pattern mode — the prior behaviour.
/// v3 adds drum pattern variants (`DrumSnap.variants` + active index) and the
/// variant label on drum clips. v2 files omit them and load as a single
/// variant built from the legacy `pattern`/`step_count` fields, which v3 keeps
/// writing (mirroring the active variant) so files stay hand-editable.
/// v4 adds per-step drum velocity (the `vel_lo`/`vel_hi` bitplanes on variants
/// and drum clips), per-machine swing, and the time signature numerator
/// (`beats_per_bar`). Older files omit them and load with every step at full
/// velocity, swing 50 (straight), and 4/4 — the prior behaviour.
pub const file_version: u32 = 4;

// ---------------------------------------------------------------------------
// Snapshot types — plain data, JSON-serialisable
// ---------------------------------------------------------------------------

pub const NoteSnap = struct {
    pitch: u8,
    start_beat: f64,
    duration_beat: f64,
    velocity: f32 = 0.85,
};

pub const SynthSnap = struct {
    // OSC A
    waveform: synth_mod.Waveform = .saw,
    pulse_width: f32 = 0.5,
    detune_cents: f32 = 0.0,
    unison: u8 = 1,
    unison_detune: f32 = 15.0,
    unison_spread: f32 = 0.0,
    // OSC B
    osc_b_on: bool = false,
    osc_b_waveform: synth_mod.Waveform = .saw,
    osc_b_pulse_width: f32 = 0.5,
    osc_b_semi: f32 = 0.0,
    osc_b_detune_cents: f32 = 0.0,
    osc_b_level: f32 = 1.0,
    osc_b_unison: u8 = 1,
    osc_b_unison_detune: f32 = 15.0,
    // Amp envelope
    attack_s: f32 = 0.005,
    decay_s: f32 = 0.08,
    sustain: f32 = 0.7,
    release_s: f32 = 0.25,
    // Filter
    filter_type: synth_mod.FilterType = .lp,
    filter_cutoff: f32 = 18_000.0,
    filter_res: f32 = 0.0,
    fenv_amount: f32 = 0.0,
    // Filter envelope
    fenv_attack_s: f32 = 0.005,
    fenv_decay_s: f32 = 0.5,
    fenv_sustain: f32 = 0.0,
    fenv_release_s: f32 = 0.3,
    // LFO
    lfo_shape: synth_mod.LfoShape = .sine,
    lfo_rate_hz: f32 = 1.0,
    lfo_depth: f32 = 0.0,
    lfo_target: synth_mod.LfoTarget = .none,
    // Voice
    voice_mode: synth_mod.VoiceMode = .poly,
    glide_s: f32 = 0.0,
    // Sub
    sub_level: f32 = 0.0,
    sub_shape: synth_mod.SubShape = .sine,
    // Noise
    noise_level: f32 = 0.0,
    noise_color: f32 = 1.0,
    // Mod
    mod_mode: synth_mod.ModMode = .none,
    mod_amount: f32 = 0.0,
    // Output
    gain: f32 = 0.35,
    // Pattern player
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
};

/// Per-pad sampler params. Defaults mirror `dsp.Pad` so projects saved before
/// the sampler existed (no `pads` array) deserialize to the original behaviour.
pub const PadSnap = struct {
    gain: f32 = 1.0,
    pan: f32 = 0.0,
    pitch_semitones: f32 = 0.0,
    start_norm: f32 = 0.0,
    end_norm: f32 = 1.0,
    reverse: bool = false,
    attack_s: f32 = 0.001,
    decay_s: f32 = 0.0,
    sustain: f32 = 1.0,
    release_s: f32 = 0.005,
};

/// One drum pattern variant. Mirrors `DrumMachine.Variant`.
pub const VariantSnap = struct {
    step_count: u8 = 16,
    pattern: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
    /// v4: per-step velocity bitplanes. Zero (or absent) = full velocity.
    vel_lo: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
    vel_hi: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
};

pub const DrumSnap = struct {
    /// Legacy live-pattern fields: always the active variant's data, so v2
    /// readers (and hand edits) see a coherent single pattern.
    step_count: u8 = 16,
    pattern: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
    pads: [DrumMachine.max_pads]PadSnap = [_]PadSnap{.{}} ** DrumMachine.max_pads,
    /// v3: the whole variant bank. Empty in v2 files — the machine then gets a
    /// single variant from the legacy fields above.
    variants: []const VariantSnap = &.{},
    /// v3: index of the active variant within `variants`.
    variant: u8 = 0,
    /// v4: swing percent (50 = straight … 75 = hardest shuffle).
    swing: f32 = 50.0,
};

pub const CompSnap = struct {
    threshold_db: f32 = -18.0,
    ratio: f32 = 4.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
    makeup_db: f32 = 0.0,
};

pub const DelaySnap = struct {
    time_s: f32 = 0.375,
    feedback: f32 = 0.35,
    mix: f32 = 0.25,
};

pub const ReverbSnap = struct {
    mix: f32 = 0.3,
    room: f32 = 0.84,
    damp: f32 = 0.25,
};

pub const EqSnap = struct {
    band_gains: [eq_mod.num_eq_bands]f32 = [_]f32{0.0} ** eq_mod.num_eq_bands,
    bypass: bool = false,
};

pub const FxSnap = struct {
    comp: ?CompSnap = null,
    delay: ?DelaySnap = null,
    reverb: ?ReverbSnap = null,
    eq: ?EqSnap = null,
};

pub const InstrumentKind = enum { empty, poly_synth, sampler, drum_machine };

/// A single-clip sampler: the pad's params, its root note, and the piano-roll
/// pattern. The clip audio itself is not persisted (same gap as user-loaded
/// drum samples) — the default clip is regenerated on load.
pub const SamplerSnap = struct {
    pad: PadSnap = .{},
    root_note: u8 = 60,
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
};

pub const RackSnap = struct {
    label: []const u8 = "synth",
    kind: InstrumentKind,
    synth: ?SynthSnap = null,
    sampler: ?SamplerSnap = null,
    drum: ?DrumSnap = null,
    fx: FxSnap = .{},
};

pub const TrackSnap = struct {
    name: []const u8,
    gain_db: f32 = 0.0,
    pan: f32 = 0.0,
    muted: bool = false,
    soloed: bool = false,
};

pub const ClipKind = enum { melodic, drum };

/// One placed clip. Melodic clips carry a private note copy + loop length; drum
/// clips carry a step-count and per-pad bitmask. Mirrors `arrangement.Clip`.
pub const ClipSnap = struct {
    start_bar: u32,
    length_bars: u32,
    kind: ClipKind = .melodic,
    // melodic
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    // drum
    drum_pattern: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
    /// v4: per-step velocity bitplanes. Zero (or absent) = full velocity.
    drum_vel_lo: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
    drum_vel_hi: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
    step_count: u8 = 16,
    /// v3: variant letter label (index) the clip was stamped from.
    variant: u8 = 0,
};

/// One track's lane of clips. Lanes are parallel to `racks`/`tracks`.
pub const LaneSnap = struct {
    clips: []const ClipSnap = &.{},
};

pub const Snapshot = struct {
    version: u32 = file_version,
    tempo_bpm: f64 = 120.0,
    /// v4: time signature numerator (the unit is always /4). Older files
    /// omit it and load as 4/4 — the prior behaviour.
    beats_per_bar: u8 = 4,
    sample_rate: u32 = 48_000,
    tracks: []const TrackSnap,
    racks: []const RackSnap,
    /// Song timeline, one lane per track. Empty for v1 files.
    arrangement: []const LaneSnap = &.{},
    /// Whether the loaded project plays the arrangement (true) or live loops.
    song_mode: bool = false,
};

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------

/// Serialise `session` as pretty-printed JSON to `path`. Writes to
/// `<path>.tmp` and renames over the target so a crash mid-write never
/// corrupts an existing project file. Safe to call while the audio thread is
/// running.
pub fn save(
    allocator: std.mem.Allocator,
    session: *const Session,
    io: std.Io,
    path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const tracks = try aa.alloc(TrackSnap, session.project.tracks.items.len);
    for (session.project.tracks.items, tracks) |t, *ts| {
        ts.* = .{ .name = t.name, .gain_db = t.gain_db, .pan = t.pan, .muted = t.muted, .soloed = t.soloed };
    }

    const racks = try aa.alloc(RackSnap, session.racks.items.len);
    for (session.racks.items, racks) |rack, *rs| {
        rs.* = try rackToSnap(aa, rack, session.project.sample_rate);
    }

    const lanes = try aa.alloc(LaneSnap, session.arrangement.lanes.items.len);
    for (session.arrangement.lanes.items, lanes) |*lane, *ls| {
        const clips = try aa.alloc(ClipSnap, lane.clips.items.len);
        for (lane.clips.items, clips) |clip, *c| c.* = try clipToSnap(aa, clip);
        ls.* = .{ .clips = clips };
    }

    const snap: Snapshot = .{
        .tempo_bpm = session.project.tempo_bpm,
        .beats_per_bar = session.project.beats_per_bar,
        .sample_rate = session.project.sample_rate,
        .tracks = tracks,
        .racks = racks,
        .arrangement = lanes,
        .song_mode = session.song_mode,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(aa, snap, .{ .whitespace = .indent_2 });

    const tmp_path = try std.fmt.allocPrint(aa, "{s}.tmp", .{path});
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(json_bytes);
        try fw.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

fn rackToSnap(aa: std.mem.Allocator, rack: *Rack, sample_rate: u32) !RackSnap {
    var rs: RackSnap = .{ .label = rack.label, .kind = undefined };

    switch (rack.instrument) {
        .empty => {
            rs.kind = .empty;
        },
        .poly_synth => |*s| {
            rs.kind = .poly_synth;
            var ss = synthToSnap(s);
            if (rack.pattern_player) |*pp| {
                ss.length_beats = pp.length_beats;
                ss.notes = try notesToSnap(aa, pp);
            }
            rs.synth = ss;
        },
        .sampler => |*s| {
            rs.kind = .sampler;
            var smp: SamplerSnap = .{
                .pad = .{
                    .gain = s.pad.gain, .pan = s.pad.pan, .pitch_semitones = s.pad.pitch_semitones,
                    .start_norm = s.pad.start_norm, .end_norm = s.pad.end_norm, .reverse = s.pad.reverse,
                    .attack_s = s.pad.attack_s, .decay_s = s.pad.decay_s,
                    .sustain = s.pad.sustain, .release_s = s.pad.release_s,
                },
                .root_note = s.root_note,
            };
            if (rack.pattern_player) |*pp| {
                smp.length_beats = pp.length_beats;
                smp.notes = try notesToSnap(aa, pp);
            }
            rs.sampler = smp;
        },
        .drum_machine => |*dm| {
            rs.kind = .drum_machine;
            var ds: DrumSnap = .{
                .step_count = dm.step_count,
                .variant = dm.variant,
                .swing = dm.swing.load(.monotonic),
            };
            for (&ds.pattern, 0..) |*p, i| p.* = dm.pattern[i].load(.acquire);
            const variants = try aa.alloc(VariantSnap, dm.variant_count);
            for (variants, 0..) |*vs, vi| {
                // variantData reads the active slot from the live atomics.
                const v = dm.variantData(@intCast(vi));
                vs.* = .{
                    .step_count = v.step_count, .pattern = v.pattern,
                    .vel_lo = v.vel_lo, .vel_hi = v.vel_hi,
                };
            }
            ds.variants = variants;
            for (&ds.pads, 0..) |*ps, i| {
                if (dm.pads[i]) |*p| ps.* = .{
                    .gain = p.gain, .pan = p.pan, .pitch_semitones = p.pitch_semitones,
                    .start_norm = p.start_norm, .end_norm = p.end_norm, .reverse = p.reverse,
                    .attack_s = p.attack_s, .decay_s = p.decay_s,
                    .sustain = p.sustain, .release_s = p.release_s,
                };
            }
            rs.drum = ds;
        },
    }

    if (rack.fx.comp) |*c| {
        rs.fx.comp = .{ .threshold_db = c.threshold_db, .ratio = c.ratio, .attack_ms = c.attack_ms, .release_ms = c.release_ms, .makeup_db = c.makeup_db };
    }
    if (rack.fx.delay) |*d| {
        const sr_f: f32 = @floatFromInt(sample_rate);
        rs.fx.delay = .{ .time_s = @as(f32, @floatFromInt(d.delay_frames)) / sr_f, .feedback = d.feedback, .mix = d.mix };
    }
    if (rack.fx.reverb) |*r| {
        rs.fx.reverb = .{ .mix = r.mix, .room = r.room, .damp = r.damp };
    }
    if (rack.fx.eq) |*e| {
        var gains: [eq_mod.num_eq_bands]f32 = undefined;
        for (&e.bands, 0..) |*b, i| gains[i] = b.gain_db;
        rs.fx.eq = .{ .band_gains = gains, .bypass = e.bypass };
    }

    return rs;
}

/// Copy a pattern player's notes into freshly allocated NoteSnaps. Notes are
/// read under the lock into a stack buffer, then the lock is released before
/// the allocator runs — avoids leaking the lock on OOM.
fn notesToSnap(aa: std.mem.Allocator, pp: *PatternPlayer) ![]const NoteSnap {
    var tmp: [pattern_mod.max_notes]NoteSnap = undefined;
    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    const count = pp.note_count;
    for (pp.notes[0..@as(usize, count)], tmp[0..@as(usize, count)]) |n, *ns| {
        ns.* = .{ .pitch = n.pitch, .start_beat = n.start_beat, .duration_beat = n.duration_beat, .velocity = n.velocity };
    }
    pp.notes_lock.unlock();
    return aa.dupe(NoteSnap, tmp[0..@as(usize, count)]);
}

/// Serialise one arrangement clip. Melodic clips duplicate their notes into
/// freshly allocated NoteSnaps; drum clips copy the bitmask by value.
fn clipToSnap(aa: std.mem.Allocator, clip: ws_arrangement.Clip) !ClipSnap {
    var c: ClipSnap = .{ .start_bar = clip.start_bar, .length_bars = clip.length_bars };
    switch (clip.content) {
        .melodic => |m| {
            c.kind = .melodic;
            c.length_beats = m.length_beats;
            const ns = try aa.alloc(NoteSnap, m.notes.len);
            for (m.notes, ns) |n, *o| o.* = .{
                .pitch = n.pitch, .start_beat = n.start_beat,
                .duration_beat = n.duration_beat, .velocity = n.velocity,
            };
            c.notes = ns;
        },
        .drum => |d| {
            c.kind = .drum;
            c.drum_pattern = d.pattern;
            c.drum_vel_lo = d.vel_lo;
            c.drum_vel_hi = d.vel_hi;
            c.step_count = d.step_count;
            c.variant = d.variant;
        },
    }
    return c;
}

fn synthToSnap(s: *const PolySynth) SynthSnap {
    return .{
        .waveform = s.waveform,
        .pulse_width = s.pulse_width,
        .detune_cents = s.detune_cents,
        .unison = s.unison,
        .unison_detune = s.unison_detune,
        .unison_spread = s.unison_spread,
        .osc_b_on = s.osc_b_on,
        .osc_b_waveform = s.osc_b_waveform,
        .osc_b_pulse_width = s.osc_b_pulse_width,
        .osc_b_semi = s.osc_b_semi,
        .osc_b_detune_cents = s.osc_b_detune_cents,
        .osc_b_level = s.osc_b_level,
        .osc_b_unison = s.osc_b_unison,
        .osc_b_unison_detune = s.osc_b_unison_detune,
        .attack_s = s.attack_s,
        .decay_s = s.decay_s,
        .sustain = s.sustain,
        .release_s = s.release_s,
        .filter_type = s.filter_type,
        .filter_cutoff = s.filter_cutoff,
        .filter_res = s.filter_res,
        .fenv_amount = s.fenv_amount,
        .fenv_attack_s = s.fenv_attack_s,
        .fenv_decay_s = s.fenv_decay_s,
        .fenv_sustain = s.fenv_sustain,
        .fenv_release_s = s.fenv_release_s,
        .lfo_shape = s.lfo_shape,
        .lfo_rate_hz = s.lfo_rate_hz,
        .lfo_depth = s.lfo_depth,
        .lfo_target = s.lfo_target,
        .voice_mode = s.voice_mode,
        .glide_s = s.glide_s,
        .sub_level = s.sub_level,
        .sub_shape = s.sub_shape,
        .noise_level = s.noise_level,
        .noise_color = s.noise_color,
        .mod_mode = s.mod_mode,
        .mod_amount = s.mod_amount,
        .gain = s.gain,
    };
}

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

/// Parse `path` and build a new Session from it.
/// Must be called before the audio backend starts (the backend captures
/// the engine pointer at init; swapping mid-session is unsafe in v1).
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Session {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(
        Snapshot,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    return buildSession(allocator, &parsed.value);
}

fn buildSession(allocator: std.mem.Allocator, snap: *const Snapshot) !Session {
    // Reject files this build cannot represent; clamp what can be clamped.
    // Racks, tracks, and lanes are parallel arrays everywhere downstream
    // (engine slots, editor indices), so a mismatch is a malformed file.
    if (snap.version > file_version) return error.UnsupportedVersion;
    if (snap.tracks.len != snap.racks.len) return error.MalformedProject;
    if (snap.sample_rate < 8_000 or snap.sample_rate > 384_000) return error.InvalidSampleRate;

    var project = Project.init(allocator);
    errdefer project.deinit();
    project.sample_rate = snap.sample_rate;
    project.tempo_bpm = std.math.clamp(snap.tempo_bpm, 20.0, 400.0);
    project.beats_per_bar = std.math.clamp(snap.beats_per_bar, 1, 16);

    for (snap.tracks) |t| {
        _ = try project.addTrack(.{ .name = t.name, .gain_db = t.gain_db, .pan = t.pan, .muted = t.muted, .soloed = t.soloed });
    }

    const sr = project.sample_rate;

    const engine = try allocator.create(Engine);
    errdefer allocator.destroy(engine);
    engine.* = try Engine.init(allocator, sr);
    errdefer engine.deinit();
    engine.loadProject(&project);

    var racks: std.ArrayListUnmanaged(*Rack) = .empty;
    errdefer {
        for (racks.items) |r| { r.deinit(allocator); allocator.destroy(r); }
        racks.deinit(allocator);
    }

    for (snap.racks) |rs| {
        // Start blank so the errdefer below is always safe (empty has no heap).
        const rack = try allocator.create(Rack);
        rack.* = .{
            .instrument = .empty,
            .label = "",
            .owned_label = false,
        };
        errdefer { rack.deinit(allocator); allocator.destroy(rack); }

        // Duplicate the label; freed by Rack.deinit when owned_label = true.
        rack.label = try allocator.dupe(u8, rs.label);
        rack.owned_label = true;

        switch (rs.kind) {
            .empty => {},
            .poly_synth => {
                rack.instrument = .{ .poly_synth = PolySynth.init(sr) };
                // PatternPlayer holds a pointer into the heap-allocated Rack —
                // must be set AFTER the instrument lands in the rack.
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                if (rs.synth) |ss| {
                    applyToSynth(&rack.instrument.poly_synth, &ss);
                    rack.pattern_player.?.length_beats = ss.length_beats;
                    loadNotes(&rack.pattern_player.?, ss.notes);
                }
            },
            .sampler => {
                rack.instrument = .{ .sampler = try Sampler.init(allocator, sr) };
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                if (rs.sampler) |smp| {
                    const s = &rack.instrument.sampler;
                    applyPadSnap(&s.pad, smp.pad);
                    s.root_note = @intCast(@min(smp.root_note, 127));
                    rack.pattern_player.?.length_beats = smp.length_beats;
                    loadNotes(&rack.pattern_player.?, smp.notes);
                }
            },
            .drum_machine => {
                rack.instrument = .{ .drum_machine = try DrumMachine.init(allocator, sr, &engine.transport) };
                if (rs.drum) |ds| {
                    const dmp = &rack.instrument.drum_machine;
                    if (ds.variants.len > 0) {
                        // v3: restore the bank, masking each slot's stray bits
                        // the same way setStepCount does for the live pattern.
                        const count: u8 = @intCast(@min(ds.variants.len, DrumMachine.max_variants));
                        for (ds.variants[0..count], dmp.variants[0..count]) |vs, *slot| {
                            const sc = std.math.clamp(vs.step_count, 1, DrumMachine.max_steps);
                            slot.step_count = sc;
                            const mask = DrumMachine.stepMask(sc);
                            for (vs.pattern, &slot.pattern) |bits, *p| p.* = bits & mask;
                            for (vs.vel_lo,  &slot.vel_lo)  |bits, *p| p.* = bits & mask;
                            for (vs.vel_hi,  &slot.vel_hi)  |bits, *p| p.* = bits & mask;
                        }
                        dmp.variant_count = count;
                        dmp.variant = @min(ds.variant, count - 1);
                        // The legacy pattern/step_count fields mirror the
                        // active variant; the bank is the source of truth.
                        const active = dmp.variants[dmp.variant];
                        for (active.pattern, active.vel_lo, active.vel_hi, 0..) |bits, lo, hi, pi| {
                            dmp.pattern[pi].store(bits, .monotonic);
                            dmp.vel_lo[pi].store(lo, .monotonic);
                            dmp.vel_hi[pi].store(hi, .monotonic);
                        }
                        dmp.setStepCount(active.step_count);
                    } else {
                        // v2: one variant from the legacy fields. Bits first:
                        // setStepCount masks off any pattern bits the file
                        // left above its own step count.
                        for (ds.pattern, 0..) |bits, pi| {
                            dmp.pattern[pi].store(bits, .monotonic);
                        }
                        dmp.setStepCount(ds.step_count);
                    }
                    dmp.swing.store(
                        std.math.clamp(ds.swing, DrumMachine.swing_min, DrumMachine.swing_max),
                        .monotonic,
                    );
                    for (ds.pads, 0..) |ps, pi| {
                        if (dmp.pads[pi]) |*p| applyPadSnap(p, ps);
                    }
                }
            },
        }

        try applyFx(allocator, rack, rs.fx, sr);
        try racks.append(allocator, rack);
    }

    // One blank lane per track keeps the arrangement parallel to racks/tracks;
    // clips (if any) are placed below once the Session owns the arrangement.
    var arrangement: ws_arrangement.Arrangement = .{};
    errdefer arrangement.deinit(allocator);
    for (racks.items) |_| try arrangement.addLane(allocator);

    var self: Session = .{
        .allocator = allocator,
        .project = project,
        .engine = engine,
        .racks = racks,
        .retired_racks = .empty,
        .arrangement = arrangement,
    };
    for (self.racks.items, 0..) |rack, i| {
        var buf: [6]dsp.Device = undefined;
        self.engine.setTrackChain(@intCast(i), rack.chain(&buf));
    }

    // Restore placed clips, then the song/pattern mode (setSongMode rebuilds the
    // device song buffers from the clips just placed).
    for (snap.arrangement, 0..) |ls, li| {
        const lane = self.arrangement.lane(li) orelse break;
        for (ls.clips) |cs| try lane.place(allocator, try clipFromSnap(allocator, cs));
    }
    self.setSongMode(snap.song_mode);

    return self;
}

/// Rebuild an arrangement clip from its snapshot. Melodic clips copy notes
/// through a stack buffer into a fresh owned allocation; drum clips are inline.
fn clipFromSnap(allocator: std.mem.Allocator, cs: ClipSnap) !ws_arrangement.Clip {
    return switch (cs.kind) {
        .melodic => blk: {
            var tmp: [pattern_mod.max_notes]pattern_mod.Note = undefined;
            const count = @min(cs.notes.len, @as(usize, pattern_mod.max_notes));
            for (cs.notes[0..count], tmp[0..count]) |n, *o| o.* = sanitizeNote(n);
            break :blk try ws_arrangement.Clip.initMelodic(
                allocator, cs.start_bar, cs.length_bars, tmp[0..count], cs.length_beats,
            );
        },
        .drum => ws_arrangement.Clip.initDrum(cs.start_bar, cs.length_bars, .{
            .pattern = cs.drum_pattern,
            .vel_lo = cs.drum_vel_lo,
            .vel_hi = cs.drum_vel_hi,
            .step_count = cs.step_count,
            .variant = @min(cs.variant, DrumMachine.max_variants - 1),
        }),
    };
}

/// Apply a pad snapshot onto a live Pad, clamping every field to the same
/// ranges `adjustParam` enforces. Unclamped values from a hand-edited file
/// would otherwise trip adjustParam's clamp bounds (lower > upper) on the
/// audio thread, or index past buffers in the waveform view.
fn applyPadSnap(p: *Pad, ps: PadSnap) void {
    p.gain            = std.math.clamp(ps.gain, 0.0, 2.0);
    p.pan             = std.math.clamp(ps.pan, -1.0, 1.0);
    p.pitch_semitones = std.math.clamp(ps.pitch_semitones, -24.0, 24.0);
    p.start_norm      = std.math.clamp(ps.start_norm, 0.0, 0.99);
    p.end_norm        = std.math.clamp(ps.end_norm, p.start_norm + 0.01, 1.0);
    p.reverse         = ps.reverse;
    p.attack_s        = std.math.clamp(ps.attack_s, 0.0, 5.0);
    p.decay_s         = std.math.clamp(ps.decay_s, 0.0, 5.0);
    p.sustain         = std.math.clamp(ps.sustain, 0.0, 1.0);
    p.release_s       = std.math.clamp(ps.release_s, 0.001, 5.0);
}

/// A NoteSnap with pitch/velocity/times forced into playable ranges.
fn sanitizeNote(n: NoteSnap) pattern_mod.Note {
    return .{
        .pitch = @intCast(@min(n.pitch, 127)),
        .start_beat = @max(0.0, n.start_beat),
        .duration_beat = @max(0.0, n.duration_beat),
        .velocity = std.math.clamp(n.velocity, 0.0, 1.0),
    };
}

/// Load saved notes into a pattern player (control thread, before audio runs).
fn loadNotes(pp: *PatternPlayer, notes: []const NoteSnap) void {
    const count = @min(notes.len, @as(usize, pattern_mod.max_notes));
    pp.note_count = @intCast(count);
    for (notes[0..count], 0..) |n, j| {
        pp.notes[j] = sanitizeNote(n);
    }
}

fn applyToSynth(s: *PolySynth, ss: *const SynthSnap) void {
    s.waveform = ss.waveform;
    s.pulse_width = ss.pulse_width;
    s.detune_cents = ss.detune_cents;
    s.unison = ss.unison;
    s.unison_detune = ss.unison_detune;
    s.unison_spread = ss.unison_spread;
    s.osc_b_on = ss.osc_b_on;
    s.osc_b_waveform = ss.osc_b_waveform;
    s.osc_b_pulse_width = ss.osc_b_pulse_width;
    s.osc_b_semi = ss.osc_b_semi;
    s.osc_b_detune_cents = ss.osc_b_detune_cents;
    s.osc_b_level = ss.osc_b_level;
    s.osc_b_unison = ss.osc_b_unison;
    s.osc_b_unison_detune = ss.osc_b_unison_detune;
    s.attack_s = ss.attack_s;
    s.decay_s = ss.decay_s;
    s.sustain = ss.sustain;
    s.release_s = ss.release_s;
    s.filter_type = ss.filter_type;
    s.filter_cutoff = ss.filter_cutoff;
    s.filter_res = ss.filter_res;
    s.fenv_amount = ss.fenv_amount;
    s.fenv_attack_s = ss.fenv_attack_s;
    s.fenv_decay_s = ss.fenv_decay_s;
    s.fenv_sustain = ss.fenv_sustain;
    s.fenv_release_s = ss.fenv_release_s;
    s.lfo_shape = ss.lfo_shape;
    s.lfo_rate_hz = ss.lfo_rate_hz;
    s.lfo_depth = ss.lfo_depth;
    s.lfo_target = ss.lfo_target;
    s.voice_mode = ss.voice_mode;
    s.glide_s = ss.glide_s;
    s.sub_level = ss.sub_level;
    s.sub_shape = ss.sub_shape;
    s.noise_level = ss.noise_level;
    s.noise_color = ss.noise_color;
    s.mod_mode = ss.mod_mode;
    s.mod_amount = ss.mod_amount;
    s.gain = ss.gain;
}

fn applyFx(allocator: std.mem.Allocator, rack: *Rack, fx: FxSnap, sr: u32) !void {
    if (fx.comp) |cs| {
        var c = Compressor.init(sr);
        c.threshold_db = cs.threshold_db;
        c.ratio = cs.ratio;
        c.attack_ms = cs.attack_ms;
        c.release_ms = cs.release_ms;
        c.makeup_db = cs.makeup_db;
        rack.fx.comp = c;
    }
    if (fx.delay) |ds| {
        var d = try StereoDelay.init(allocator, sr, 2.0);
        d.setTime(ds.time_s);
        d.feedback = ds.feedback;
        d.mix = ds.mix;
        rack.fx.delay = d;
    }
    if (fx.reverb) |rs| {
        var r = try Reverb.init(allocator, sr);
        r.mix = rs.mix;
        r.room = rs.room;
        r.damp = rs.damp;
        rack.fx.reverb = r;
    }
    if (fx.eq) |es| {
        var eq = GraphicEq.init(sr);
        eq.setAllBands(es.band_gains);
        eq.bypass = es.bypass;
        rack.fx.eq = eq;
    }
}

// ---------------------------------------------------------------------------
// Tests — in-memory round-trip (no file I/O; std.Io not needed)
// ---------------------------------------------------------------------------

test "snapshot types: JSON round-trip preserves synth params, notes, drum pattern, tempo" {
    const testing = std.testing;
    const aa = testing.allocator;

    const drum_pattern: [DrumMachine.max_pads]u32 = blk: {
        var p = [_]u32{0} ** DrumMachine.max_pads;
        p[0] = 1 << 5;
        break :blk p;
    };

    const snap_in: Snapshot = .{
        .tempo_bpm = 140.0,
        .sample_rate = 48_000,
        .tracks = &.{
            .{ .name = "lead", .gain_db = -2.5 },
            .{ .name = "drums" },
        },
        .racks = &.{
            .{
                .label = "supersaw",
                .kind = .poly_synth,
                .synth = .{
                    .gain = 0.77,
                    .filter_cutoff = 3_000.0,
                    .voice_mode = .mono,
                    .notes = &.{
                        .{ .pitch = 69, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 0.9 },
                    },
                    .length_beats = 8.0,
                },
            },
            .{
                .label = "drums",
                .kind = .drum_machine,
                .drum = .{ .step_count = 16, .pattern = drum_pattern },
            },
        },
    };

    const json = try std.json.Stringify.valueAlloc(aa, snap_in, .{ .whitespace = .indent_2 });
    defer aa.free(json);

    var parsed = try std.json.parseFromSlice(Snapshot, aa, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const snap_out = &parsed.value;

    try testing.expectApproxEqAbs(@as(f64, 140.0), snap_out.tempo_bpm, 0.001);
    try testing.expectEqual(@as(usize, 2), snap_out.tracks.len);
    try testing.expectEqualStrings("lead", snap_out.tracks[0].name);
    try testing.expectApproxEqAbs(@as(f32, -2.5), snap_out.tracks[0].gain_db, 1e-4);

    const sr = snap_out.racks[0].synth.?;
    try testing.expectApproxEqAbs(@as(f32, 0.77), sr.gain, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3_000.0), sr.filter_cutoff, 1.0);
    try testing.expectEqual(synth_mod.VoiceMode.mono, sr.voice_mode);
    try testing.expectEqual(@as(usize, 1), sr.notes.len);
    try testing.expectEqual(@as(u8, 69), sr.notes[0].pitch);
    try testing.expectApproxEqAbs(@as(f64, 8.0), sr.length_beats, 1e-9);
    try testing.expectEqualStrings("supersaw", snap_out.racks[0].label);

    const dr = snap_out.racks[1].drum.?;
    try testing.expectEqual(@as(u8, 16), dr.step_count);
    try testing.expectEqual(@as(u32, 1 << 5), dr.pattern[0]);
    try testing.expectEqual(@as(u32, 0), dr.pattern[1]);
}

test "buildSession: constructs valid Session from snapshot" {
    const testing = std.testing;

    const drum_pattern: [DrumMachine.max_pads]u32 = blk: {
        var p = [_]u32{0} ** DrumMachine.max_pads;
        p[0] = 1 << 5;
        break :blk p;
    };

    const snap: Snapshot = .{
        .tempo_bpm = 140.0,
        .sample_rate = 48_000,
        .tracks = &.{
            .{ .name = "lead" },
            .{ .name = "drums" },
        },
        .racks = &.{
            .{
                .label = "supersaw+comp",
                .kind = .poly_synth,
                .synth = .{
                    .gain = 0.77,
                    .filter_cutoff = 3_000.0,
                    .voice_mode = .mono,
                    .notes = &.{
                        .{ .pitch = 69, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 0.9 },
                    },
                    .length_beats = 8.0,
                },
                .fx = .{ .comp = .{ .threshold_db = -24.0, .ratio = 6.0, .attack_ms = 5.0, .release_ms = 60.0, .makeup_db = 3.0 } },
            },
            .{
                .label = "drums",
                .kind = .drum_machine,
                .drum = .{
                    .step_count = 16,
                    .pattern = drum_pattern,
                    .pads = blk: {
                        var ps = [_]PadSnap{.{}} ** DrumMachine.max_pads;
                        ps[0] = .{ .pitch_semitones = 7.0, .reverse = true, .end_norm = 0.5 };
                        break :blk ps;
                    },
                },
            },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectApproxEqAbs(@as(f64, 140.0), session.project.tempo_bpm, 0.001);
    try testing.expectEqual(@as(usize, 2), session.project.tracks.items.len);
    try testing.expectEqual(@as(usize, 2), session.racks.items.len);

    try testing.expectEqualStrings("supersaw+comp", session.racks.items[0].label);
    try testing.expect(session.racks.items[0].owned_label);

    const s = &session.racks.items[0].instrument.poly_synth;
    try testing.expectApproxEqAbs(@as(f32, 0.77), s.gain, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3_000.0), s.filter_cutoff, 1.0);
    try testing.expectEqual(synth_mod.VoiceMode.mono, s.voice_mode);

    const pp = &session.racks.items[0].pattern_player.?;
    try testing.expectEqual(@as(u16, 1), pp.note_count);
    try testing.expectEqual(@as(u7, 69), pp.notes[0].pitch);
    try testing.expectApproxEqAbs(@as(f64, 8.0), pp.length_beats, 1e-9);

    const comp = &session.racks.items[0].fx.comp.?;
    try testing.expectApproxEqAbs(@as(f32, -24.0), comp.threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6.0), comp.ratio, 1e-4);

    const dm = &session.racks.items[1].instrument.drum_machine;
    try testing.expect(dm.stepActive(0, 5));
    try testing.expect(!dm.stepActive(0, 0));
    try testing.expectApproxEqAbs(@as(f32, 7.0), dm.pads[0].?.pitch_semitones, 1e-4);
    try testing.expect(dm.pads[0].?.reverse);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dm.pads[0].?.end_norm, 1e-4);
}

test "buildSession: arrangement clips and song_mode round-trip" {
    const testing = std.testing;

    const drum_pattern: [DrumMachine.max_pads]u32 = blk: {
        var p = [_]u32{0} ** DrumMachine.max_pads;
        p[0] = 1;
        break :blk p;
    };

    const snap: Snapshot = .{
        .tracks = &.{ .{ .name = "keys" }, .{ .name = "drums" } },
        .racks = &.{
            .{ .label = "synth", .kind = .poly_synth, .synth = .{} },
            .{ .label = "drums", .kind = .drum_machine, .drum = .{ .step_count = 16, .pattern = drum_pattern } },
        },
        .song_mode = true,
        .arrangement = &.{
            .{ .clips = &.{
                .{ .start_bar = 2, .length_bars = 1, .kind = .melodic, .length_beats = 4.0, .notes = &.{
                    .{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.5, .velocity = 0.8 },
                } },
            } },
            .{ .clips = &.{
                .{ .start_bar = 0, .length_bars = 1, .kind = .drum, .step_count = 16, .drum_pattern = drum_pattern },
            } },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expect(session.song_mode);

    // Melodic clip restored on lane 0.
    const lane0 = session.arrangement.lane(0).?;
    try testing.expectEqual(@as(usize, 1), lane0.clips.items.len);
    const c0 = lane0.clips.items[0];
    try testing.expectEqual(@as(u32, 2), c0.start_bar);
    try testing.expectEqual(@as(usize, 1), c0.content.melodic.notes.len);
    try testing.expectEqual(@as(u7, 64), c0.content.melodic.notes[0].pitch);

    // Drum clip restored on lane 1.
    const lane1 = session.arrangement.lane(1).?;
    try testing.expectEqual(@as(usize, 1), lane1.clips.items.len);
    try testing.expectEqual(@as(u32, 1), lane1.clips.items[0].content.drum.pattern[0]);

    // song_mode = true means the devices were handed their song buffers.
    try testing.expect(session.racks.items[0].pattern_player.?.song_mode);
    try testing.expectEqual(@as(u16, 1), session.racks.items[0].pattern_player.?.song_note_count);
    try testing.expect(session.racks.items[1].instrument.drum_machine.song_mode);
    try testing.expectEqual(@as(u16, 1), session.racks.items[1].instrument.drum_machine.song_clip_count);
}

test "buildSession: drum variant bank round-trips; v2 files get one variant" {
    const testing = std.testing;

    // v3: two variants, B active, with stray bits above each step count that
    // the loader must mask off.
    const variants = [_]VariantSnap{
        .{ .step_count = 16, .pattern = blk: {
            var p = [_]u32{0} ** DrumMachine.max_pads;
            p[0] = 1 | (1 << 20); // bit 20 is past 16 steps — stray
            break :blk p;
        } },
        .{ .step_count = 32, .pattern = blk: {
            var p = [_]u32{0} ** DrumMachine.max_pads;
            p[1] = 1 << 31;
            break :blk p;
        } },
    };
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .variants = &variants, .variant = 1 },
        }},
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 2), dm.variant_count);
    try testing.expectEqual(@as(u8, 1), dm.variant);
    try testing.expectEqual(@as(u8, 32), dm.step_count);
    try testing.expect(dm.stepActive(1, 31)); // live = variant B
    dm.selectVariant(0);
    try testing.expectEqual(@as(u8, 16), dm.step_count);
    try testing.expect(dm.stepActive(0, 0));
    try testing.expect(!dm.stepActive(0, 20)); // stray bit was masked

    // v2 file shape: no `variants` — a single variant from the legacy fields.
    const legacy: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .step_count = 16, .pattern = blk: {
                var p = [_]u32{0} ** DrumMachine.max_pads;
                p[0] = 1 << 5;
                break :blk p;
            } },
        }},
    };
    var old = try buildSession(testing.allocator, &legacy);
    defer old.deinit();
    const odm = &old.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 1), odm.variant_count);
    try testing.expect(odm.stepActive(0, 5));
}

test "buildSession: time signature lands in project and transport" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .beats_per_bar = 3,
        .tracks = &.{.{ .name = "t" }},
        .racks = &.{.{ .label = "t", .kind = .empty }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectEqual(@as(u8, 3), session.project.beats_per_bar);
    try testing.expectEqual(@as(u8, 3), session.engine.transport.time_signature.beats_per_bar);
}

test "buildSession: per-step velocity and swing round-trip" {
    const testing = std.testing;

    const variants = [_]VariantSnap{.{
        .step_count = 16,
        .pattern = blk: {
            var p = [_]u32{0} ** DrumMachine.max_pads;
            p[0] = 0b11;
            break :blk p;
        },
        // Step 1 at level 3 (25%); a stray plane bit above the step count.
        .vel_lo = blk: {
            var p = [_]u32{0} ** DrumMachine.max_pads;
            p[0] = (1 << 1) | (1 << 20);
            break :blk p;
        },
        .vel_hi = blk: {
            var p = [_]u32{0} ** DrumMachine.max_pads;
            p[0] = 1 << 1;
            break :blk p;
        },
    }};
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .variants = &variants, .swing = 62.0 },
        }},
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u2, 0), dm.stepVel(0, 0));
    try testing.expectEqual(@as(u2, 3), dm.stepVel(0, 1));
    try testing.expectEqual(@as(u2, 0), dm.stepVel(0, 20)); // stray bit masked
    try testing.expectApproxEqAbs(@as(f32, 62.0), dm.swing.load(.monotonic), 1e-6);

    // And back out through save-shaped snapshots.
    const v = dm.variantData(0);
    try testing.expectEqual(@as(u32, 1 << 1), v.vel_lo[0]);
    try testing.expectEqual(@as(u32, 1 << 1), v.vel_hi[0]);
}

test "clip snapshots carry the drum variant label" {
    const testing = std.testing;

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;
    _ = dm.addVariant(); // B active
    try session.stampClip(0, 0);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cs = try clipToSnap(arena.allocator(), session.arrangement.lane(0).?.clips.items[0]);
    try testing.expectEqual(@as(u8, 1), cs.variant);

    var clip = try clipFromSnap(testing.allocator, cs);
    defer clip.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), clip.content.drum.variant);
}

test "buildSession: rejects malformed and future files" {
    const testing = std.testing;

    // Newer file version than this build understands.
    try testing.expectError(error.UnsupportedVersion, buildSession(testing.allocator, &.{
        .version = file_version + 1,
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .kind = .empty }},
    }));

    // Track/rack count mismatch.
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{ .{ .name = "a" }, .{ .name = "b" } },
        .racks = &.{.{ .label = "e", .kind = .empty }},
    }));

    // Nonsense sample rate.
    try testing.expectError(error.InvalidSampleRate, buildSession(testing.allocator, &.{
        .sample_rate = 0,
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .kind = .empty }},
    }));
}

test "buildSession: clamps out-of-range pad and note values" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{
                .pads = blk: {
                    var ps = [_]PadSnap{.{}} ** DrumMachine.max_pads;
                    // end < start and both far out of range.
                    ps[0] = .{ .start_norm = 7.0, .end_norm = -3.0, .gain = 99.0 };
                    break :blk ps;
                },
            },
        }},
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const pad = &session.racks.items[0].instrument.drum_machine.pads[0].?;
    try testing.expect(pad.start_norm < pad.end_norm);
    try testing.expect(pad.gain <= 2.0);
    // The invariant adjustParam relies on: clamp bounds stay ordered.
    session.racks.items[0].instrument.drum_machine.adjustParam(DrumMachine.paramId(0, 0), 1);
    session.racks.items[0].instrument.drum_machine.adjustParam(DrumMachine.paramId(0, 1), -1);
}

test "buildSession: empty and sampler racks round-trip" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{ .{ .name = "blank" }, .{ .name = "keys" } },
        .racks = &.{
            .{ .label = "empty", .kind = .empty },
            .{
                .label = "sampler",
                .kind = .sampler,
                .sampler = .{
                    .pad = .{ .pitch_semitones = 3.0, .gain = 0.8, .reverse = true },
                    .root_note = 48,
                    .notes = &.{
                        .{ .pitch = 64, .start_beat = 0.0, .duration_beat = 0.5, .velocity = 0.7 },
                    },
                    .length_beats = 2.0,
                },
            },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectEqual(std.meta.Tag(@import("rack.zig").Instrument).empty, std.meta.activeTag(session.racks.items[0].instrument));
    try testing.expect(session.racks.items[0].pattern_player == null);

    const smp = &session.racks.items[1].instrument.sampler;
    try testing.expectApproxEqAbs(@as(f32, 3.0), smp.pad.pitch_semitones, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.8), smp.pad.gain, 1e-4);
    try testing.expect(smp.pad.reverse);
    try testing.expectEqual(@as(u7, 48), smp.root_note);

    const pp = &session.racks.items[1].pattern_player.?;
    try testing.expectEqual(@as(u16, 1), pp.note_count);
    try testing.expectEqual(@as(u7, 64), pp.notes[0].pitch);
    try testing.expectApproxEqAbs(@as(f64, 2.0), pp.length_beats, 1e-9);
}

//! Project save / load.
//!
//! Serialises the live Session to a JSON file (*.wsj).  The snapshot types are
//! pure data — no pointers, no atomics, no heap slices matching the live structs.
//!
//! Round-trip guarantees:
//!   - All 38 PolySynth params + piano-roll notes + loop length
//!   - Drum step-count + per-pad bitmask patterns
//!   - Per-track gain / pan / mute / solo + project tempo
//!   - FX: compressor, delay, reverb, EQ
//!   - Rack labels

const std = @import("std");
const Session = @import("session.zig").Session;
const Project = @import("project.zig").Project;
const Rack = @import("rack.zig").Rack;
const engine_mod = @import("audio/engine.zig");
const Engine = engine_mod.Engine;
const synth_mod = @import("dsp/synth.zig");
const PolySynth = synth_mod.PolySynth;
const pattern_mod = @import("dsp/pattern.zig");
const PatternPlayer = pattern_mod.PatternPlayer;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const Compressor = @import("dsp/compressor.zig").Compressor;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const eq_mod = @import("dsp/eq.zig");
const GraphicEq = eq_mod.GraphicEq;
const dsp = @import("dsp/device.zig");

pub const file_version: u32 = 1;

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

pub const DrumSnap = struct {
    step_count: u8 = 16,
    pattern: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
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

pub const InstrumentKind = enum { poly_synth, drum_machine };

pub const RackSnap = struct {
    label: []const u8 = "synth",
    kind: InstrumentKind,
    synth: ?SynthSnap = null,
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

pub const Snapshot = struct {
    version: u32 = file_version,
    tempo_bpm: f64 = 120.0,
    sample_rate: u32 = 48_000,
    tracks: []const TrackSnap,
    racks: []const RackSnap,
};

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------

/// Serialise `session` as pretty-printed JSON to `path`. Creates or truncates.
/// Safe to call while the audio thread is running.
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

    const snap: Snapshot = .{
        .tempo_bpm = session.project.tempo_bpm,
        .sample_rate = session.project.sample_rate,
        .tracks = tracks,
        .racks = racks,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(aa, snap, .{ .whitespace = .indent_2 });

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll(json_bytes);
    try fw.interface.flush();
}

fn rackToSnap(aa: std.mem.Allocator, rack: *const Rack, sample_rate: u32) !RackSnap {
    var rs: RackSnap = .{ .label = rack.label, .kind = undefined };

    switch (rack.instrument) {
        .poly_synth => |*s| {
            rs.kind = .poly_synth;
            var ss = synthToSnap(s);
            if (rack.pattern_player) |*pp| {
                ss.length_beats = pp.length_beats;
                // Copy notes under the lock into a stack buffer, then release
                // before touching the allocator — avoids leaking the lock on OOM.
                var tmp: [pattern_mod.max_notes]NoteSnap = undefined;
                while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
                const count = pp.note_count;
                for (pp.notes[0..@as(usize, count)], tmp[0..@as(usize, count)]) |n, *ns| {
                    ns.* = .{ .pitch = n.pitch, .start_beat = n.start_beat, .duration_beat = n.duration_beat, .velocity = n.velocity };
                }
                pp.notes_lock.unlock();
                ss.notes = try aa.dupe(NoteSnap, tmp[0..@as(usize, count)]);
            }
            rs.synth = ss;
        },
        .drum_machine => |*dm| {
            rs.kind = .drum_machine;
            var ds: DrumSnap = .{ .step_count = dm.step_count };
            for (&ds.pattern, 0..) |*p, i| p.* = dm.pattern[i].load(.acquire);
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
    var project = Project.init(allocator);
    errdefer project.deinit();
    project.sample_rate = snap.sample_rate;
    project.tempo_bpm = snap.tempo_bpm;

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

    var drum_track: u16 = 0;
    for (snap.racks, 0..) |rs, i| {
        // Initialise with a no-op instrument so the errdefer below is safe
        // (PolySynth has no heap; owned_label=false means no free).
        const rack = try allocator.create(Rack);
        rack.* = .{
            .instrument = .{ .poly_synth = PolySynth.init(sr) },
            .label = "",
            .owned_label = false,
        };
        errdefer { rack.deinit(allocator); allocator.destroy(rack); }

        // Duplicate the label; freed by Rack.deinit when owned_label = true.
        rack.label = try allocator.dupe(u8, rs.label);
        rack.owned_label = true;

        switch (rs.kind) {
            .poly_synth => {
                if (rs.synth) |ss| {
                    applyToSynth(&rack.instrument.poly_synth, &ss);
                    // PatternPlayer holds a self-referential pointer into the
                    // heap-allocated Rack — must be set AFTER rack is on the heap.
                    rack.pattern_player = PatternPlayer.init(&rack.instrument.poly_synth, &engine.transport);
                    rack.pattern_player.?.length_beats = ss.length_beats;
                    const count = @min(ss.notes.len, @as(usize, pattern_mod.max_notes));
                    rack.pattern_player.?.note_count = @intCast(count);
                    for (ss.notes[0..count], 0..) |n, j| {
                        rack.pattern_player.?.notes[j] = .{
                            .pitch = @intCast(@min(n.pitch, 127)),
                            .start_beat = n.start_beat,
                            .duration_beat = n.duration_beat,
                            .velocity = n.velocity,
                        };
                    }
                } else {
                    rack.pattern_player = PatternPlayer.init(&rack.instrument.poly_synth, &engine.transport);
                }
            },
            .drum_machine => {
                // Replace the placeholder instrument. PolySynth.deinit is a no-op.
                rack.instrument = .{ .drum_machine = try DrumMachine.init(allocator, sr, &engine.transport) };
                drum_track = @intCast(i);
                if (rs.drum) |ds| {
                    rack.instrument.drum_machine.setStepCount(ds.step_count);
                    for (ds.pattern, 0..) |bits, pi| {
                        rack.instrument.drum_machine.pattern[pi].store(bits, .monotonic);
                    }
                }
            },
        }

        try applyFx(allocator, rack, rs.fx, sr);
        try racks.append(allocator, rack);
    }

    var self: Session = .{
        .allocator = allocator,
        .project = project,
        .engine = engine,
        .racks = racks,
        .drum_track = drum_track,
        .retired_racks = .empty,
    };
    for (self.racks.items, 0..) |rack, i| {
        var buf: [6]dsp.Device = undefined;
        self.engine.setTrackChain(@intCast(i), rack.chain(&buf));
    }

    return self;
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
                .drum = .{ .step_count = 16, .pattern = drum_pattern },
            },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectApproxEqAbs(@as(f64, 140.0), session.project.tempo_bpm, 0.001);
    try testing.expectEqual(@as(usize, 2), session.project.tracks.items.len);
    try testing.expectEqual(@as(usize, 2), session.racks.items.len);
    try testing.expectEqual(@as(u16, 1), session.drum_track);

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

    const dm = &session.racks.items[session.drum_track].instrument.drum_machine;
    try testing.expect(dm.stepActive(0, 5));
    try testing.expect(!dm.stepActive(0, 0));
}

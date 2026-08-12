//! Project save / load.
//!
//! Serialises the live Session into a *.wsj container (see FORMAT.md). The
//! snapshot types are pure data - no pointers, no atomics, no heap slices
//! matching the live structs.
//!
//! Round-trip guarantees:
//!   - All 38 PolySynth params + piano-roll notes + loop length
//!   - Drum pattern notes + timing grid + per-pad sampler params
//!   - Per-track gain / pan / mute / solo + project tempo
//!   - FX: gate, compressor, multiband compressor (incl. OTT style), limiter,
//!     transient shaper, EQ, filter, utility, stereo width, auto-pan/tremolo,
//!     saturator, crusher,
//!     chorus, phaser, flanger, tape, frequency shifter, delay, reverb
//!   - Rack labels
//!   - User-loaded sample audio (drum pads + sampler clips), exported as mono
//!     WAVs into the .wsj's own audio cache section
//!
//! The snapshot itself is written by `persist_bin.zig`; this file only
//! builds and consumes the snapshot structs.

const std = @import("std");
const Session = @import("session.zig").Session;
const wav = @import("core/wav.zig");
const types = @import("core/types.zig");
const theory = @import("theory.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;
const track_color_count = project_mod.track_color_count;
const ws_arrangement = @import("arrangement.zig");
const time_grid = @import("time_grid.zig");
const rack_mod = @import("rack.zig");
const Rack = rack_mod.Rack;
const Fx = rack_mod.Fx;
const engine_mod = @import("audio/engine.zig");
const Engine = engine_mod.Engine;
const Transport = @import("transport.zig").Transport;
const synth_mod = @import("dsp/synth.zig");
const PolySynth = synth_mod.PolySynth;
const wavetable_mod = @import("dsp/wavetable.zig");
const pattern_mod = @import("dsp/pattern.zig");
const PatternPlayer = pattern_mod.PatternPlayer;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const drum_kit = @import("dsp/drum_kit.zig");
const pad_mod = @import("dsp/pad.zig");
const Pad = pad_mod.Pad;
const lfo_mod = @import("dsp/lfo.zig");
const Sampler = @import("dsp/sampler.zig").Sampler;
const Slicer = @import("dsp/slicer.zig").Slicer;
const SoundfontPlayer = @import("dsp/soundfont_player.zig").SoundfontPlayer;
const soundfont_mod = @import("dsp/soundfont.zig");
const Compressor = @import("dsp/compressor.zig").Compressor;
const multiband_comp_mod = @import("dsp/multiband_comp.zig");
const Reverb = @import("dsp/reverb.zig").Reverb;
const eq_mod = @import("dsp/eq.zig");
const Gate = @import("dsp/gate.zig").Gate;
const Saturator = @import("dsp/saturator.zig").Saturator;
const Crusher = @import("dsp/crusher.zig").Crusher;
const Phaser = @import("dsp/phaser.zig").Phaser;
const dsp = @import("dsp/device.zig");
const automation_mod = @import("dsp/automation.zig");
const tuning_mod = @import("dsp/tuning.zig");
const AutomationPoint = automation_mod.AutomationPoint;

const persist_types = @import("persist_types.zig");
const persist_bin = @import("persist_bin.zig");
const persist_save = @import("persist_save.zig");
const persist_load = @import("persist_load.zig");

// Snapshot types, save path, and load path all live in their own files now -
// re-exported here under their original names so every external
// persist.save(...)/persist.load(...)/persist.Snapshot-style caller, and
// every test below, keeps compiling unchanged.
pub const file_version = persist_types.file_version;
pub const AutomationPointSnap = persist_types.AutomationPointSnap;
pub const SynthSnap = persist_types.SynthSnap;
pub const PadSnap = persist_types.PadSnap;
pub const DrumNoteSnap = persist_types.DrumNoteSnap;
pub const VariantSnap = persist_types.VariantSnap;
pub const DrumSnap = persist_types.DrumSnap;
pub const GateSnap = persist_types.GateSnap;
pub const SatSnap = persist_types.SatSnap;
pub const CrushSnap = persist_types.CrushSnap;
pub const PhaserSnap = persist_types.PhaserSnap;
pub const FxKind = persist_types.FxKind;
pub const FxUnitSnap = persist_types.FxUnitSnap;
pub const RackSnap = persist_types.RackSnap;
pub const TrackSnap = persist_types.TrackSnap;
pub const GroupSnap = persist_types.GroupSnap;
pub const Snapshot = persist_types.Snapshot;
pub const save = persist_save.save;
pub const chainToSnap = persist_save.chainToSnap;
pub const clipToSnap = persist_save.clipToSnap;
pub const synthToSnap = persist_save.synthToSnap;
pub const applySnapToDevice = persist_load.applySnapToDevice;
pub const load = persist_load.load;
pub const buildSession = persist_load.buildSession;
pub const clipFromSnap = persist_load.clipFromSnap;
pub const automationFromSnap = persist_load.automationFromSnap;
pub const applyPadSnap = persist_load.applyPadSnap;
pub const sanitizeNote = persist_load.sanitizeNote;
pub const applyToSynth = persist_load.applyToSynth;
pub const applyLfoCustomSnap = persist_load.applyLfoCustomSnap;
pub const applyFxChain = persist_load.applyFxChain;
pub const applySynthPatch = persist_load.applySynthPatch;

// ---------------------------------------------------------------------------
// Tests - in-memory round-trip (no file I/O; std.Io not needed)
// ---------------------------------------------------------------------------

test "snapshot types: encode/decode round-trip preserves synth params, notes, drum pattern, tempo" {
    const testing = std.testing;
    const aa = testing.allocator;

    const drum_notes = [_]DrumNoteSnap{.{ .pad = 0, .step = 5 }};

    const snap_in: Snapshot = .{
        .tempo_bpm = 140.0,
        .tempo_points = &.{.{ .beat = 8, .bpm = 90, .ramp_to_next = true }},
        .meter_denominator = 8,
        .meter_points = &.{.{ .beat = 12, .numerator = 7, .denominator = 8 }},
        .scale = .{ .root = 9, .kind = .minor },
        .sample_rate = 48_000,
        .tracks = &.{
            .{ .name = "lead", .gain_db = -2.5 },
            .{ .name = "drums" },
        },
        .racks = &.{
            .{
                .label = "supersaw",
                .content = .{ .poly_synth = .{
                    .gain = 0.77,
                    .filter_cutoff = 3_000.0,
                    .voice_mode = .mono,
                    .warp_mode = .mirror,
                    .warp_amount = 0.65,
                    .osc_b_warp_mode = .sync,
                    .osc_b_warp_amount = 0.35,
                    .pattern = .{
                        .notes = &.{.{ .pitch = 69, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 0.9 }},
                        .length_beats = 8.0,
                    },
                } },
            },
            .{
                .label = "drums",
                .content = .{ .drum_machine = .{ .variants = &.{.{ .step_count = 16, .notes = &drum_notes }} } },
            },
        },
    };

    var buf: std.Io.Writer.Allocating = .init(aa);
    defer buf.deinit();
    try persist_bin.encode(&buf.writer, snap_in);

    var arena: std.heap.ArenaAllocator = .init(aa);
    defer arena.deinit();
    const decoded = try persist_bin.decode(Snapshot, arena.allocator(), buf.written());
    const snap_out = &decoded;

    try testing.expectApproxEqAbs(@as(f64, 140.0), snap_out.tempo_bpm, 0.001);
    try testing.expectEqual(@as(f64, 8), snap_out.tempo_points[0].beat);
    try testing.expect(snap_out.tempo_points[0].ramp_to_next);
    try testing.expectEqual(@as(u8, 8), snap_out.meter_denominator);
    try testing.expectEqual(@as(u8, 7), snap_out.meter_points[0].numerator);
    try testing.expectEqual(@as(u4, 9), snap_out.scale.?.root);
    try testing.expectEqual(theory.ScaleType.minor, snap_out.scale.?.kind);
    try testing.expectEqual(@as(usize, 2), snap_out.tracks.len);
    try testing.expectEqualStrings("lead", snap_out.tracks[0].name);
    try testing.expectApproxEqAbs(@as(f32, -2.5), snap_out.tracks[0].gain_db, 1e-4);

    const sr = snap_out.racks[0].content.poly_synth;
    try testing.expectApproxEqAbs(@as(f32, 0.77), sr.gain, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3_000.0), sr.filter_cutoff, 1.0);
    try testing.expectEqual(synth_mod.VoiceMode.mono, sr.voice_mode);
    try testing.expectEqual(synth_mod.WarpMode.mirror, sr.warp_mode);
    try testing.expectApproxEqAbs(@as(f32, 0.65), sr.warp_amount, 1e-4);
    try testing.expectEqual(synth_mod.WarpMode.sync, sr.osc_b_warp_mode);
    try testing.expectApproxEqAbs(@as(f32, 0.35), sr.osc_b_warp_amount, 1e-4);
    try testing.expectEqual(@as(usize, 1), sr.pattern.notes.len);
    try testing.expectEqual(@as(u8, 69), sr.pattern.notes[0].pitch);
    try testing.expectApproxEqAbs(@as(f64, 8.0), sr.pattern.length_beats, 1e-9);
    try testing.expectEqualStrings("supersaw", snap_out.racks[0].label);

    const dr = snap_out.racks[1].content.drum_machine;
    try testing.expectEqual(@as(u16, 16), dr.variants[0].step_count);
    try testing.expectEqual(@as(usize, 1), dr.variants[0].notes.len);
    try testing.expectEqual(@as(u8, 0), dr.variants[0].notes[0].pad);
    try testing.expectEqual(@as(u16, 5), dr.variants[0].notes[0].step);
}

test "buildSession: constructs valid Session from snapshot" {
    const testing = std.testing;

    var pads_snap = [_]PadSnap{.{}} ** DrumMachine.max_pads;
    pads_snap[0] = .{ .used = true, .pitch_semitones = 7.0, .reverse = true, .end_norm = 0.5 };

    const snap: Snapshot = .{
        .tempo_bpm = 140.0,
        .tempo_points = &.{.{ .beat = 4, .bpm = 100 }},
        .meter_denominator = 8,
        .meter_points = &.{.{ .beat = 6, .numerator = 5, .denominator = 8 }},
        .sample_rate = 48_000,
        .tracks = &.{
            .{ .name = "lead" },
            .{ .name = "drums" },
        },
        .racks = &.{
            .{
                .label = "supersaw+comp",
                .content = .{ .poly_synth = .{
                    .gain = 0.77,
                    .filter_cutoff = 3_000.0,
                    .voice_mode = .mono,
                    .pattern = .{
                        .notes = &.{.{ .pitch = 69, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 0.9 }},
                        .length_beats = 8.0,
                    },
                } },
            },
            .{
                .label = "drums",
                .content = .{ .drum_machine = .{
                    .variants = &.{.{ .step_count = 16, .notes = &.{.{ .pad = 0, .step = 5 }} }},
                    .pads = &pads_snap,
                } },
            },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectApproxEqAbs(@as(f64, 140.0), session.project.tempo_bpm, 0.001);
    try testing.expectEqual(@as(f64, 4), session.project.tempo_points.items[0].beat);
    try testing.expectEqual(@as(u8, 8), session.engine.transport.time_signature.beat_unit);
    try testing.expectEqual(@as(u8, 5), session.engine.transport.meter_points[0].numerator);
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

    const dm = &session.racks.items[1].instrument.drum_machine;
    try testing.expect(dm.stepActive(0, 5));
    try testing.expect(!dm.stepActive(0, 0));
    try testing.expectApproxEqAbs(@as(f32, 7.0), dm.pads[0].?.pad.pitch_semitones, 1e-4);
    try testing.expect(dm.pads[0].?.pad.reverse);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dm.pads[0].?.pad.end_norm, 1e-4);
}

test "buildSession: a loaded session's armed array is as long as its racks" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{ .{ .name = "lead" }, .{ .name = "bass" }, .{ .name = "drums" } },
        .racks = &.{
            .{ .label = "lead", .content = .empty },
            .{ .label = "bass", .content = .empty },
            .{ .label = "drums", .content = .empty },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    // `armed` is positional and parallel to `racks`. It used to come back
    // empty from a load, which made `toggleArm` a silent no-op on every
    // opened project and panicked the first track insert or delete.
    try testing.expectEqual(session.racks.items.len, session.armed.items.len);
    for (session.armed.items) |a| try testing.expect(!a);

    session.toggleArm(2);
    try testing.expect(session.isArmed(2));

    _ = try session.addTrack("added");
    try testing.expectEqual(session.racks.items.len, session.armed.items.len);
    try testing.expect(session.isArmed(2));

    try session.deleteTrack(0);
    try testing.expectEqual(session.racks.items.len, session.armed.items.len);
    try testing.expect(session.isArmed(1));
}

test "buildSession: v10 fx_chain keeps user order, duplicates, and bypass" {
    const testing = std.testing;

    // Reverb *before* the comp (impossible in the old rack), two saturators,
    // and a bypassed crusher in the middle.
    const snap: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "lead" }},
        .racks = &.{.{ .label = "lead", .content = .empty }},
        .master_fx_chain = &.{
            .{ .content = .{ .reverb = .{ .mix = 0.6, .room = 0.9, .damp = 0.1 } } },
            .{ .content = .{ .sat = .{ .drive_db = 6.0, .out_db = 0.0, .mix = 1.0 } } },
            .{ .bypassed = true, .content = .{ .crush = .{} } },
            .{ .content = .{ .sat = .{ .drive_db = 24.0, .out_db = -3.0, .mix = 0.5 } } },
            .{ .content = .{ .comp = .{} } },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const units = session.master_fx.units.items;
    try testing.expectEqual(@as(usize, 5), units.len);
    try testing.expectApproxEqAbs(@as(f32, 0.6), units[0].payload.reverb.mix, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6.0), units[1].payload.sat.drive_db, 1e-4);
    try testing.expect(units[2].bypassed);
    try testing.expectApproxEqAbs(@as(f32, 24.0), units[3].payload.sat.drive_db, 1e-4);
    // Missing params field (.comp) loads with defaults.
    try testing.expectApproxEqAbs(@as(f32, -18.0), units[4].payload.comp.threshold_db, 1e-4);
    // The bypassed crusher stays in chain() - it fades itself out rather
    // than leaving the device list - so all 5 reach the engine.
    try testing.expectEqual(@as(usize, 5), session.engine.master_chain.slice().len);
}

// zig fmt: off
test "buildSession: a compressor's sidechain_source loads, clamps, and reaches the engine's routing" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "bass" }},
        .racks = &.{.{
            .label = "bass", .content = .empty,
            .fx_chain = &.{
                .{ .content = .{ .comp = .{ .sidechain_source = 3 } } },
            },
        }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectEqual(@as(u16, 3), session.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?.track);
    try testing.expectEqual(@as(u16, 3), session.engine.track_sidechain[0][0].?.track); // no instrument -> comp is slot 0

    // A hand-edited out-of-range value clamps to the last valid track index.
    const snap2: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "bass" }},
        .racks = &.{.{
            .label = "bass", .content = .empty,
            .fx_chain = &.{
                .{ .content = .{ .comp = .{ .sidechain_source = 65_000 } } },
            },
        }},
    };
    var session2 = try buildSession(testing.allocator, &snap2);
    defer session2.deinit();
    try testing.expectEqual(@as(u16, engine_mod.max_tracks - 1), session2.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?.track);
}

test "buildSession: a compressor's sidechain_pad loads, clamps, and combines with sidechain_source" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "bass" }},
        .racks = &.{.{
            .label = "bass", .content = .empty,
            .fx_chain = &.{
                .{ .content = .{ .comp = .{ .sidechain_source = 3, .sidechain_pad = 200 } } },
            },
        }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    const sc = session.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?;
    try testing.expectEqual(@as(u16, 3), sc.track);
    // A hand-edited out-of-range pad clamps to the last valid pad index.
    try testing.expectEqual(@as(u8, DrumMachine.max_pads - 1), sc.pad.?);
}
// zig fmt: on

test "save/load round-trip persists a compressor's sidechain_source" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/sidechain.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const unit = try session.racks.items[0].fx.insert(testing.allocator, 0, .comp, session.project.sample_rate);
    unit.payload.comp.sidechain_source = .{ .track = 7, .pad = 2 };

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const sc = loaded.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?;
    try testing.expectEqual(@as(u16, 7), sc.track);
    try testing.expectEqual(@as(?u8, 2), sc.pad);
}

test "save/load round-trip persists a compressor's group-sourced sidechain (sidechain_is_group)" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/sidechain_group.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const g = try session.addGroup("drums");
    const unit = try session.racks.items[0].fx.insert(testing.allocator, 0, .comp, session.project.sample_rate);
    unit.payload.comp.sidechain_source = .{ .track = g, .pad = null, .is_group = true };

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const sc = loaded.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?;
    try testing.expectEqual(@as(u16, g), sc.track);
    try testing.expect(sc.is_group);
    try testing.expectEqual(@as(?u8, null), sc.pad);
}

test "save/load round-trip persists a track's aux sends (master + group)" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/sends.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const g = try session.addGroup("verb");
    session.setTrackSend(0, 0, .master, -6.0, true);
    session.setTrackSend(0, 1, .{ .group = g }, -12.0, false);
    for (2..project_mod.max_sends_per_track) |slot|
        session.setTrackSend(0, @intCast(slot), .master, -18.0, false);

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const sends = loaded.project.tracks.items[0].sends;
    const send0 = sends[0].?;
    try testing.expectEqual(project_mod.SendTarget.master, send0.target);
    try testing.expectApproxEqAbs(types.dbToGain(-6.0), send0.level, 1e-4);
    try testing.expect(send0.pre_fader);
    const send1 = sends[1].?;
    try testing.expectEqual(g, send1.target.group);
    try testing.expectApproxEqAbs(types.dbToGain(-12.0), send1.level, 1e-4);
    try testing.expect(!send1.pre_fader);
    const last = sends[project_mod.max_sends_per_track - 1].?;
    try testing.expectEqual(project_mod.SendTarget.master, last.target);
    try testing.expectApproxEqAbs(types.dbToGain(-18.0), last.level, 1e-4);
}

test "an old .wsj with no sidechain_is_group/sends fields loads with unchanged prior behavior" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "bass" }},
        .racks = &.{.{
            .label = "bass",
            .content = .empty,
            .fx_chain = &.{
                .{ .content = .{ .comp = .{ .sidechain_source = 3 } } },
            },
        }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    const sc = session.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?;
    try testing.expectEqual(@as(u16, 3), sc.track);
    try testing.expect(!sc.is_group);
    for (session.project.tracks.items[0].sends) |s| try testing.expectEqual(@as(?project_mod.SendSlot, null), s);
}

test "save/load round-trip persists an FX-unit-targeted automation lane (instance_id)" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/fx_automation.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sat_unit = try session.racks.items[0].fx.insert(testing.allocator, 0, .sat, session.project.sample_rate);
    try session.arrangement.lane(0).?.place(
        session.allocator,
        try ws_arrangement.Clip.initMelodic(session.allocator, 0, 32, &.{}, 1.0),
    );
    const clip = session.arrangement.lane(0).?.clipAt(0).?;
    const points = try clip.automation.synthParamPoints(session.allocator, sat_unit.instance_id, 2); // sat mix
    try automation_mod.setPoint(session.allocator, points, 0.0, 0.4);
    try automation_mod.setPoint(session.allocator, points, 4.0, 0.9);
    try testing.expect(automation_mod.setCurve(points.*, 0.0, .hold));

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    // A fresh session's FX chain reallocates instance ids from 1, same order
    // as it was built, so the reloaded unit gets the same id back.
    const loaded_unit = loaded.racks.items[0].fx.units.items[0];
    try testing.expectEqual(sat_unit.instance_id, loaded_unit.instance_id);
    const loaded_clip = loaded.arrangement.lane(0).?.clipAt(0).?;
    const loaded_points = loaded_clip.automation.findSynthParam(loaded_unit.instance_id, 2).?;
    try testing.expectEqual(@as(usize, 2), loaded_points.len);
    try testing.expectApproxEqAbs(@as(f32, 0.4), loaded_points[0].value, 1e-6);
    // Through a real file, not just the snapshot structs: the segment shape
    // is what the encoding has to carry.
    try testing.expectEqual(automation_mod.Curve.hold, loaded_points[0].curve);
    try testing.expectEqual(automation_mod.Curve.linear, loaded_points[1].curve);
}

test "save/load round-trip persists the project temperament onto every synth" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/tuning.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    session.setTuning(tuning_mod.Preset.werckmeister3.tuning(2));

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    try testing.expectEqual(@as(u4, 2), loaded.project.tuning.root);
    try testing.expectApproxEqAbs(
        tuning_mod.Preset.werckmeister3.table()[1],
        loaded.project.tuning.cents[1],
        1e-4,
    );
    // The point of saving it: the reloaded instruments actually play in it.
    // Every chromatic instrument, not just the synths - a sampler left in
    // 12-TET would beat against them.
    for (loaded.racks.items) |rack| {
        switch (rack.instrument) {
            .poly_synth => |*s| try testing.expectEqual(loaded.project.tuning, s.tuning),
            .sampler => |*s| try testing.expectEqual(loaded.project.tuning, s.tuning),
            .soundfont, .acoustic => |*s| try testing.expectEqual(loaded.project.tuning, s.tuning),
            else => {},
        }
    }
}

test "a track added after the temperament was chosen joins it" {
    const testing = std.testing;
    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    session.setTuning(tuning_mod.Preset.pythagorean.tuning(0));

    const idx = try session.insertTrack(@intCast(session.racks.items.len), "late");
    try session.setInstrument(idx, .sampler);
    try testing.expectEqual(
        session.project.tuning,
        session.racks.items[idx].instrument.sampler.tuning,
    );
}

test "load clamps a hand-edited tuning offset instead of rendering silence" {
    const testing = std.testing;
    var snap = persist_types.Snapshot{
        .tracks = &.{.{ .name = "lead" }},
        .racks = &.{.{ .label = "lead", .content = .{ .poly_synth = .{} } }},
    };
    snap.tuning.cents[3] = std.math.nan(f32);
    snap.tuning.cents[4] = 1e9;

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectApproxEqAbs(@as(f32, 0), session.project.tuning.cents[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1200.0), session.project.tuning.cents[4], 1e-6);
}

test "failed save removes temporary project file" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/blocked.wsj", .{&tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(testing.io, wsj_path);

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try testing.expectError(error.IsDir, save(testing.allocator, &session, testing.io, wsj_path));

    var tmp_path_buf: [68]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{wsj_path});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, tmp_path, .{}));
}

// `wstudio.o.default_drum_steps`/`default_slicer_steps`/
// `default_pattern_length_beats` shape a *new* instrument only. A file
// carries its own, so loading one must not inherit whatever the user's
// config happens to say - the load session's defaults are set deliberately
// wrong here to catch that.
test "a loaded project keeps its own pattern shape, not the config defaults" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/shape.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    session.racks.items[0].instrument.drum_machine.setStepCount(48);
    _ = try session.addTrack("keys");
    try session.setInstrument(1, .poly_synth);
    session.racks.items[1].pattern_player.?.length_beats = 12.0;
    _ = try session.addTrack("chops");
    try session.setInstrument(2, .slicer);
    session.racks.items[2].instrument.slicer.setStepCount(24);

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    loaded.defaults = .{ .drum_steps = 8, .slicer_steps = 8, .pattern_length_beats = 1.0, .swing = 70.0 };

    try testing.expectEqual(@as(u16, 48), loaded.racks.items[0].instrument.drum_machine.step_count);
    try testing.expectEqual(@as(f64, 12.0), loaded.racks.items[1].pattern_player.?.length_beats);
    try testing.expectEqual(@as(u8, 24), loaded.racks.items[2].instrument.slicer.step_count);
}

test "save/load round-trip persists a slicer's slices, pattern, and swing" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/slicer.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .slicer);
    {
        const sl = &session.racks.items[0].instrument.slicer;
        sl.sliceInto(4);
        sl.slices[2].gain = 1.5;
        sl.slices[2].pan = -0.3;
        sl.slices[2].reverse = true;
        sl.toggleStep(2, 5);
        sl.setStepVel(2, 5, 90);
        sl.setStepCount(24);
        sl.setSwing(65.0);
    }

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const sl = &loaded.racks.items[0].instrument.slicer;
    try testing.expectEqual(@as(u8, 4), sl.slice_count);
    try testing.expectApproxEqAbs(@as(f32, 1.5), sl.slices[2].gain, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -0.3), sl.slices[2].pan, 1e-4);
    try testing.expect(sl.slices[2].reverse);
    try testing.expectApproxEqAbs(@as(f32, 0.25), sl.slices[1].start_norm, 1e-4);
    try testing.expect(sl.stepActive(2, 5));
    try testing.expectEqual(@as(u8, 90), sl.stepVel(2, 5));
    try testing.expectEqual(@as(u8, 24), sl.step_count);
    try testing.expectApproxEqAbs(@as(f32, 65.0), sl.swing.load(.monotonic), 1e-4);
}

test "save/load round-trip persists pad modes across sampler, drum, and slicer" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/mod.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .sampler);
    _ = try session.addTrack("drum");
    try session.setInstrument(1, .drum_machine);
    _ = try session.addTrack("slice");
    try session.setInstrument(2, .slicer);

    {
        const s = &session.racks.items[0].instrument.sampler;
        s.pad.mod_rate_hz = 5.5;
        s.pad.mod_depth = 0.7;
        s.pad.mod_shape = .square;
        s.pad.mod_dest = .filter;
        s.pad.loop = .ping_pong;
        s.pad.warp_method = .tones;
    }
    {
        const dm = &session.racks.items[1].instrument.drum_machine;
        try dm.loadKitVariant(drum_kit.byName("default").?);
        dm.pads[0].?.pad.mod_rate_hz = 3.25;
        dm.pads[0].?.pad.mod_depth = 0.4;
        dm.pads[0].?.pad.mod_shape = .triangle;
        dm.pads[0].?.pad.mod_dest = .pan;
        dm.pads[0].?.pad.loop = .forward;
        dm.pads[0].?.pad.warp_method = .tones;
    }
    {
        const sl = &session.racks.items[2].instrument.slicer;
        sl.sliceInto(2);
        sl.slices[1].mod_rate_hz = 8.0;
        sl.slices[1].mod_depth = 1.0;
        sl.slices[1].mod_shape = .saw;
        sl.slices[1].mod_dest = .pitch;
        sl.slices[1].loop = .forward;
        sl.slices[1].warp_method = .tones;
    }

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const s = &loaded.racks.items[0].instrument.sampler;
    try testing.expectApproxEqAbs(@as(f32, 5.5), s.pad.mod_rate_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.7), s.pad.mod_depth, 1e-4);
    try testing.expectEqual(lfo_mod.Shape.square, s.pad.mod_shape);
    try testing.expectEqual(pad_mod.ModDest.filter, s.pad.mod_dest);
    try testing.expectEqual(pad_mod.LoopMode.ping_pong, s.pad.loop);
    try testing.expectEqual(pad_mod.WarpMethod.tones, s.pad.warp_method);

    const dm = &loaded.racks.items[1].instrument.drum_machine;
    try testing.expectApproxEqAbs(@as(f32, 3.25), dm.pads[0].?.pad.mod_rate_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.4), dm.pads[0].?.pad.mod_depth, 1e-4);
    try testing.expectEqual(lfo_mod.Shape.triangle, dm.pads[0].?.pad.mod_shape);
    try testing.expectEqual(pad_mod.ModDest.pan, dm.pads[0].?.pad.mod_dest);
    try testing.expectEqual(pad_mod.LoopMode.forward, dm.pads[0].?.pad.loop);
    try testing.expectEqual(pad_mod.WarpMethod.tones, dm.pads[0].?.pad.warp_method);

    const sl = &loaded.racks.items[2].instrument.slicer;
    try testing.expectApproxEqAbs(@as(f32, 8.0), sl.slices[1].mod_rate_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), sl.slices[1].mod_depth, 1e-4);
    try testing.expectEqual(lfo_mod.Shape.saw, sl.slices[1].mod_shape);
    try testing.expectEqual(pad_mod.ModDest.pitch, sl.slices[1].mod_dest);
    try testing.expectEqual(pad_mod.LoopMode.forward, sl.slices[1].loop);
    try testing.expectEqual(pad_mod.WarpMethod.tones, sl.slices[1].warp_method);
}

test "save/load round-trip persists a slicer's variant bank and choke groups" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/slvar.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .slicer);
    {
        const sl = &session.racks.items[0].instrument.slicer;
        sl.sliceInto(4);
        sl.toggleStep(0, 0); // variant A: slice 0 on step 0
        try testing.expect(sl.addVariant()); // B active, copy of A
        sl.toggleStep(0, 0); // B diverges: off
        sl.toggleStep(3, 7);
        sl.setStepVel(3, 7, 60);
        sl.choke_group[0] = 1;
        sl.choke_group[1] = 1;
        sl.choke_group[2] = 0; // proves the array round-trips per-slice, not just uniformly
        sl.setSliceLen(2, 7); // a row that wraps early has to survive the file
    }

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const sl = &loaded.racks.items[0].instrument.slicer;
    try testing.expectEqual(@as(u8, 2), sl.variant_count);
    try testing.expectEqual(@as(u8, 1), sl.variant); // B was active at save
    try testing.expect(!sl.stepActive(0, 0));
    try testing.expect(sl.stepActive(3, 7));
    try testing.expectEqual(@as(u8, 60), sl.stepVel(3, 7));
    sl.selectVariant(0);
    try testing.expect(sl.stepActive(0, 0)); // A intact through the file
    try testing.expect(!sl.stepActive(3, 7));
    try testing.expectEqual(@as(u8, 1), sl.choke_group[0]);
    try testing.expectEqual(@as(u8, 1), sl.choke_group[1]);
    try testing.expectEqual(@as(u8, 0), sl.choke_group[2]);
    try testing.expectEqual(@as(u16, 7), sl.sliceSteps(2, sl.step_count));
    try testing.expectEqual(sl.step_count, sl.sliceSteps(3, sl.step_count));
}

test "save/load round-trip keeps a slicer lane's stamped clips playable in song mode" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/slsong.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .slicer);
    {
        const sl = &session.racks.items[0].instrument.slicer;
        sl.sliceInto(4);
        sl.toggleStep(2, 0);
    }
    try session.stampClip(0, 0);

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const lane = loaded.arrangement.lane(0).?;
    try testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try testing.expect(lane.clips.items[0].content == .drum);

    loaded.setSongMode(true);
    const sl = &loaded.racks.items[0].instrument.slicer;
    try testing.expect(sl.song_mode);
    try testing.expect(sl.song_clip_count == 1);
    try testing.expect(sl.song_clips[0].midi[2][0] != null);
}

test "save/load round-trip restores a slicer's user-loaded sample audio" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/slicer2.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .slicer);
    const distinct_samples = [_]f32{ 0.25, 0.5, 0.75, 1.0, 0.5, 0.25 };
    {
        const sl = &session.racks.items[0].instrument.slicer;
        testing.allocator.free(sl.samples);
        const owned = try testing.allocator.dupe(f32, &distinct_samples);
        sl.samples = owned;
        for (&sl.slices) |*p| p.samples = owned;
        sl.user_sample = true;
        sl.sliceInto(2);
    }

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const sl = &loaded.racks.items[0].instrument.slicer;
    try testing.expectEqual(distinct_samples.len, sl.samples.len);
    for (distinct_samples, sl.samples) |a, b| try testing.expectApproxEqAbs(a, b, 1e-3);
    try testing.expectEqual(@as(u8, 2), sl.slice_count); // saved slicing survives the audio reload
}

test "save/load round-trip persists master FX" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sr = session.project.sample_rate;
    const alloc = testing.allocator;
    // Deliberately un-rack-like order: sat ahead of the gate, comp last.
    (try session.master_fx.insert(alloc, 0, .sat, sr)).payload.sat.drive_db = 18.0;
    (try session.master_fx.insert(alloc, 1, .gate, sr)).payload.gate.threshold_db = -42.0;
    const crush = try session.master_fx.insert(alloc, 2, .crush, sr);
    crush.payload.crush = .{ .bits = 6.0, .downsample = 8.0 };
    crush.setBypassed(true);
    (try session.master_fx.insert(alloc, 3, .chorus, sr)).payload.chorus.rate_hz = 1.5;
    (try session.master_fx.insert(alloc, 4, .phaser, sr)).payload.phaser.feedback = 0.7;
    (try session.master_fx.insert(alloc, 5, .comp, sr)).payload.comp.threshold_db = -9.0;
    session.syncMasterChain();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const units = loaded.master_fx.units.items;
    try testing.expectEqual(@as(usize, 6), units.len);
    try testing.expectApproxEqAbs(@as(f32, 18.0), units[0].payload.sat.drive_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -42.0), units[1].payload.gate.threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6.0), units[2].payload.crush.bits, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 8.0), units[2].payload.crush.downsample, 1e-4);
    try testing.expect(units[2].bypassed);
    try testing.expectApproxEqAbs(@as(f32, 1.5), units[3].payload.chorus.rate_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.7), units[4].payload.phaser.feedback, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -9.0), units[5].payload.comp.threshold_db, 1e-4);
    // The bypassed crusher is still in the live chain; it fades itself out
    // rather than leaving the device list.
    try testing.expectEqual(@as(usize, 6), loaded.engine.master_chain.slice().len);
}

test "save/load round-trip persists a multiband compressor's crossover, style, and per-band params" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sr = session.project.sample_rate;
    const alloc = testing.allocator;

    const mb = try session.master_fx.insert(alloc, 0, .mb_comp, sr);
    // Both above the struct's just-inserted 200/2000 defaults, so a
    // load-order bug that clamps `lo` against a still-default `hi` (see
    // `setXovers`'s doc comment) would corrupt this round-trip.
    mb.payload.mb_comp.setXoverHi(8000.0);
    mb.payload.mb_comp.setXoverLo(2500.0);
    mb.payload.mb_comp.attack_ms = 3.0;
    mb.payload.mb_comp.release_ms = 120.0;
    mb.payload.mb_comp.style = .ott;
    mb.payload.mb_comp.mix = 0.75;
    mb.payload.mb_comp.bands[0] = .{ .threshold_db = -22.0, .ratio = 5.0, .makeup_db = 1.0 };
    mb.payload.mb_comp.bands[1] = .{ .threshold_db = -19.0, .ratio = 6.0, .makeup_db = 2.0 };
    mb.payload.mb_comp.bands[2] = .{ .threshold_db = -15.0, .ratio = 2.5, .makeup_db = 0.5 };
    session.syncMasterChain();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const units = loaded.master_fx.units.items;
    try testing.expectEqual(@as(usize, 1), units.len);
    const m = units[0].payload.mb_comp;
    try testing.expectApproxEqAbs(@as(f32, 2500.0), m.xover_lo_hz, 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 8000.0), m.xover_hi_hz, 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 3.0), m.attack_ms, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 120.0), m.release_ms, 1e-4);
    try testing.expectEqual(multiband_comp_mod.Style.ott, m.style);
    try testing.expectApproxEqAbs(@as(f32, 0.75), m.mix, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -22.0), m.bands[0].threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5.0), m.bands[0].ratio, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), m.bands[0].makeup_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -19.0), m.bands[1].threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6.0), m.bands[1].ratio, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -15.0), m.bands[2].threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2.5), m.bands[2].ratio, 1e-4);
    try testing.expectEqual(@as(usize, 1), loaded.engine.master_chain.slice().len);
}

test "save/load round-trip persists an OTT unit's depth/time/gains and rederives its attack/release" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sr = session.project.sample_rate;
    const alloc = testing.allocator;

    const unit = try session.master_fx.insert(alloc, 0, .ott, sr);
    unit.payload.ott.setDepth(0.6);
    unit.payload.ott.setTime(2.0);
    unit.payload.ott.gain_in_db = 3.0;
    unit.payload.ott.gain_out_db = -4.5;
    session.syncMasterChain();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const units = loaded.master_fx.units.items;
    try testing.expectEqual(@as(usize, 1), units.len);
    const o = units[0].payload.ott;
    try testing.expectApproxEqAbs(@as(f32, 0.6), o.depth(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2.0), o.time, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3.0), o.gain_in_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -4.5), o.gain_out_db, 1e-4);
    // Derived from `time` through setTime on load, not stored in the file.
    try testing.expectApproxEqAbs(unit.payload.ott.mb.attack_ms, o.mb.attack_ms, 1e-4);
    try testing.expectApproxEqAbs(unit.payload.ott.mb.release_ms, o.mb.release_ms, 1e-4);
    try testing.expectEqual(@as(usize, 1), loaded.engine.master_chain.slice().len);
}

test "save/load round-trip persists a frequency shifter's shift and mix" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sr = session.project.sample_rate;
    const alloc = testing.allocator;

    const unit = try session.master_fx.insert(alloc, 0, .freq_shift, sr);
    unit.payload.freq_shift.shift_hz = -350.0;
    unit.payload.freq_shift.mix = 0.65;
    session.syncMasterChain();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const units = loaded.master_fx.units.items;
    try testing.expectEqual(@as(usize, 1), units.len);
    const f = units[0].payload.freq_shift;
    try testing.expectApproxEqAbs(@as(f32, -350.0), f.shift_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.65), f.mix, 1e-4);
    try testing.expectEqual(@as(usize, 1), loaded.engine.master_chain.slice().len);
}

test "buildSession: arrangement clips and song_mode round-trip" {
    const testing = std.testing;

    // One hit on pad 0's step 0, in the sparse note shape a current file
    // writes (the legacy `pattern` bitmask is read-only since v23).
    const drum_notes = [_]DrumNoteSnap{.{ .pad = 0, .step = 0 }};

    const snap: Snapshot = .{
        .tracks = &.{ .{ .name = "keys" }, .{ .name = "drums" } },
        .racks = &.{
            .{ .label = "synth", .content = .{ .poly_synth = .{} } },
            .{ .label = "drums", .content = .{ .drum_machine = .{ .variants = &.{.{ .step_count = 16, .notes = &drum_notes }} } } },
        },
        .song_mode = true,
        .sections = &.{.{ .tick = 128, .name = "verse" }},
        .arrangement = &.{
            .{ .clips = &.{
                .{ .start_tick = 256, .length_ticks = 128, .content = .{ .melodic = .{ .length_beats = 4.0, .notes = &.{
                    .{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.5, .velocity = 0.8 },
                } } } },
            } },
            .{ .clips = &.{
                .{ .start_tick = 0, .length_ticks = 128, .content = .{ .drum = .{ .pattern = .{ .step_count = 16, .notes = &drum_notes } } } },
            } },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expect(session.song_mode);
    try testing.expectEqualStrings("verse", session.project.sections.items[0].name);

    // Melodic clip restored on lane 0.
    const lane0 = session.arrangement.lane(0).?;
    try testing.expectEqual(@as(usize, 1), lane0.clips.items.len);
    const c0 = lane0.clips.items[0];
    try testing.expectEqual(@as(u32, 256), c0.start_tick);
    try testing.expectEqual(@as(usize, 1), c0.content.melodic.notes.len);
    try testing.expectEqual(@as(u7, 64), c0.content.melodic.notes[0].pitch);

    // Drum clip restored on lane 1.
    const lane1 = session.arrangement.lane(1).?;
    try testing.expectEqual(@as(usize, 1), lane1.clips.items.len);
    try testing.expect(lane1.clips.items[0].content.drum.midi[0][0] != null);

    // song_mode = true means the devices were handed their song buffers.
    try testing.expect(session.racks.items[0].pattern_player.?.song_mode);
    try testing.expectEqual(@as(u16, 1), session.racks.items[0].pattern_player.?.song_note_count);
    try testing.expect(session.racks.items[1].instrument.drum_machine.song_mode);
    try testing.expectEqual(@as(u16, 1), session.racks.items[1].instrument.drum_machine.song_clip_count);
}

// zig fmt: off
test "clipToSnap/clipFromSnap round-trip gain/pan automation" {
    const testing = std.testing;
    var clip = ws_arrangement.Clip.initDrum(0, 1, .{
        .midi = try DrumMachine.allocMidi(testing.allocator, 16), .step_count = 16,
    });
    try automation_mod.setPoint(testing.allocator, &clip.automation.gain, 0.0, -6.0);
    try automation_mod.setPoint(testing.allocator, &clip.automation.gain, 2.0, 0.0);
    try automation_mod.setPoint(testing.allocator, &clip.automation.pan, 0.0, -1.0);
    defer clip.deinit(testing.allocator);
    // zig fmt: on

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const snap = try clipToSnap(arena.allocator(), clip);
    try testing.expectEqual(@as(usize, 2), snap.gain_automation.len);
    try testing.expectApproxEqAbs(@as(f32, -6.0), snap.gain_automation[0].value, 1e-6);
    try testing.expectEqual(@as(usize, 1), snap.pan_automation.len);

    var restored = try clipFromSnap(testing.allocator, snap);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.automation.gain.len);
    try testing.expectApproxEqAbs(@as(f64, 0.0), restored.automation.gain[0].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, -6.0), restored.automation.gain[0].value, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), restored.automation.gain[1].value, 1e-6);
    try testing.expectEqual(@as(usize, 1), restored.automation.pan.len);
    try testing.expectApproxEqAbs(@as(f32, -1.0), restored.automation.pan[0].value, 1e-6);
}

test "a point's curve shape survives the round-trip" {
    const testing = std.testing;
    var clip = ws_arrangement.Clip.initDrum(0, 1, .{
        .midi = try DrumMachine.allocMidi(testing.allocator, 16),
        .step_count = 16,
    });
    defer clip.deinit(testing.allocator);
    try automation_mod.setPoint(testing.allocator, &clip.automation.gain, 0.0, -6.0);
    try automation_mod.setPoint(testing.allocator, &clip.automation.gain, 1.0, -3.0);
    try automation_mod.setPoint(testing.allocator, &clip.automation.gain, 2.0, 0.0);
    try testing.expect(automation_mod.setCurve(clip.automation.gain, 0.0, .hold));
    try testing.expect(automation_mod.setCurve(clip.automation.gain, 1.0, .ease));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const snap = try clipToSnap(arena.allocator(), clip);
    try testing.expectEqual(persist_types.AutomationCurveSnap.hold, snap.gain_automation[0].curve);
    try testing.expectEqual(persist_types.AutomationCurveSnap.ease, snap.gain_automation[1].curve);
    try testing.expectEqual(persist_types.AutomationCurveSnap.linear, snap.gain_automation[2].curve);

    var restored = try clipFromSnap(testing.allocator, snap);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(automation_mod.Curve.hold, restored.automation.gain[0].curve);
    try testing.expectEqual(automation_mod.Curve.ease, restored.automation.gain[1].curve);
}

test "automationFromSnap sorts unsorted points and clamps out-of-range values" {
    const testing = std.testing;
    const snaps = [_]AutomationPointSnap{
        .{ .beat = 3.0, .value = 100.0 }, // out of gain range - clamps to 12
        .{ .beat = 1.0, .value = -999.0 }, // clamps to -60
    };
    const pts = try automationFromSnap(testing.allocator, &snaps, -60.0, 12.0);
    defer testing.allocator.free(pts);
    try testing.expectEqual(@as(usize, 2), pts.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), pts[0].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, -60.0), pts[0].value, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 3.0), pts[1].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 12.0), pts[1].value, 1e-6);
}

test "clipFromSnap clamps automation points to the clip span" {
    var clip = try clipFromSnap(std.testing.allocator, .{
        .length_ticks = 32,
        .gain_automation = &.{.{ .beat = 99.0, .value = 0.0 }},
        .synth_param_automation = &.{.{ .param_id = 21, .points = &.{.{ .beat = 99.0, .value = 1000.0 }} }},
    });
    defer clip.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(f64, 1.0), clip.automation.gain[0].beat);
    try std.testing.expectEqual(@as(f64, 1.0), clip.automation.synth_params.items[0].points[0].beat);
}

test "clipFromSnap replaces duplicate synth automation lanes without leaking" {
    var clip = try clipFromSnap(std.testing.allocator, .{
        .synth_param_automation = &.{
            .{ .param_id = 21, .points = &.{.{ .beat = 0.0, .value = 1000.0 }} },
            .{ .param_id = 21, .points = &.{.{ .beat = 0.0, .value = 2000.0 }} },
        },
    });
    defer clip.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), clip.automation.synth_params.items.len);
    try std.testing.expectEqual(@as(f32, 2000.0), clip.automation.synth_params.items[0].points[0].value);
}

test "load sanitizes non-finite project, automation, pad, and note fields" {
    const testing = std.testing;
    const nan32 = std.math.nan(f32);
    const nan64 = std.math.nan(f64);

    const snap: Snapshot = .{
        .tempo_bpm = nan64,
        .tracks = &.{.{ .name = "bad", .gain_db = nan32, .pan = nan32 }},
        .racks = &.{.{ .label = "empty", .content = .empty }},
        .groups = &.{.{ .active = true, .name = "bad", .gain_db = nan32 }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectEqual(@as(f64, 120.0), session.project.tempo_bpm);
    try testing.expectEqual(@as(f32, 0.0), session.project.tracks.items[0].gain_db);
    try testing.expectEqual(@as(f32, 0.0), session.project.tracks.items[0].pan);
    try testing.expectEqual(@as(f32, 0.0), session.groups[0].?.gain_db);

    const points = try automationFromSnap(testing.allocator, &.{.{ .beat = nan64, .value = nan32 }}, -1.0, 1.0);
    defer testing.allocator.free(points);
    try testing.expectEqual(@as(f64, 0.0), points[0].beat);
    try testing.expectEqual(@as(f32, 0.0), points[0].value);

    var pad: Pad = .{ .samples = &.{} };
    applyPadSnap(&pad, .{
        .gain = nan32,
        .pan = nan32,
        .pitch_semitones = nan32,
        .start_norm = nan32,
        .end_norm = nan32,
        .attack_s = nan32,
        .decay_s = nan32,
        .sustain = nan32,
        .release_s = nan32,
    });
    try testing.expectEqual(@as(f32, 1.0), pad.gain);
    try testing.expectEqual(@as(f32, 0.0), pad.pan);
    try testing.expectEqual(@as(f32, 0.0), pad.pitch_semitones);
    try testing.expectEqual(@as(f32, 0.0), pad.start_norm);
    try testing.expectEqual(@as(f32, 1.0), pad.end_norm);
    try testing.expectEqual(@as(f32, 0.001), pad.attack_s);
    try testing.expectEqual(@as(f32, 0.0), pad.decay_s);
    try testing.expectEqual(@as(f32, 1.0), pad.sustain);
    try testing.expectEqual(@as(f32, 0.005), pad.release_s);

    const note = sanitizeNote(.{ .pitch = 60, .start_beat = nan64, .duration_beat = nan64, .velocity = nan32 });
    try testing.expectEqual(@as(f64, 0.0), note.start_beat);
    try testing.expectEqual(@as(f64, 0.0), note.duration_beat);
    try testing.expectEqual(pattern_mod.default_velocity, note.velocity);
    // Default expression is centred, in tune, and uses patch release.
    try testing.expect(note.art.isNeutral());
    // A hand-edited one is pulled back into range rather than reaching a voice.
    const wild = sanitizeNote(.{
        .pitch = 60,
        .start_beat = 0.0,
        .duration_beat = 1.0,
        .pan = -8.0,
        .fine_cents = 400.0,
        .release_scale = 99.0,
    });
    try testing.expectEqual(@as(f32, -1.0), wild.art.pan);
    try testing.expectEqual(@as(f32, 100.0), wild.art.fine_cents);
    try testing.expectEqual(@as(f32, 4.0), wild.art.release_scale);

    var lfo_points: [synth_mod.max_lfo_shape_points]synth_mod.LfoShapePoint = undefined;
    var lfo_count: u8 = 0;
    applyLfoCustomSnap(&lfo_points, &lfo_count, &.{
        .{ .phase = 0.8, .value = nan32 },
        .{ .phase = nan32, .value = 2.0 },
        .{ .phase = 0.2, .value = -2.0 },
    });
    try testing.expectEqual(@as(u8, 3), lfo_count);
    try testing.expectEqual(@as(f32, 0.0), lfo_points[0].phase);
    try testing.expectEqual(@as(f32, 0.2), lfo_points[1].phase);
    try testing.expectEqual(@as(f32, 0.8), lfo_points[2].phase);
    try testing.expectEqual(@as(f32, 0.0), lfo_points[2].value);
}

test "clip load clamps invalid loop, step, and velocity values" {
    const testing = std.testing;
    var melodic = try clipFromSnap(testing.allocator, .{
        .content = .{ .melodic = .{ .length_beats = std.math.nan(f64) } },
    });
    defer melodic.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 1.0), melodic.content.melodic.length_beats);

    // One hit on pad 0's step 0, whose stored velocity is past the 0-127
    // scale and has to clamp on load.
    var drum = try clipFromSnap(testing.allocator, .{
        .content = .{ .drum = .{ .pattern = .{ .step_count = 0, .notes = &.{.{ .pad = 0, .step = 0, .velocity = 127 }} } } },
    });
    defer drum.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 1), drum.content.drum.step_count);
    try testing.expectEqual(DrumMachine.vel_full, drum.content.drum.midi[0][0].?.velocity);
}

// zig fmt: off
test "buildSession: filter cutoff automation clamps an out-of-range hand-edited value" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "keys" }},
        .racks = &.{.{ .label = "synth", .content = .{ .poly_synth = .{} } }},
        .arrangement = &.{
            .{ .clips = &.{
                .{
                    .content = .{ .melodic = .{ .length_beats = 4.0 } },
                    .synth_param_automation = &.{.{ .param_id = 21, .points = &.{.{ .beat = 0.0, .value = 99_999.0 }} }},
                },
            } },
        },
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    const clip = session.arrangement.lane(0).?.clips.items[0];
    try testing.expectApproxEqAbs(@as(f32, 20_000.0), clip.automation.findSynthParam(0, 21).?[0].value, 1e-6);
}
// zig fmt: on

test "buildSession: drum variant bank round-trips; v2 files get one variant" {
    const testing = std.testing;

    // zig fmt: off
    // Two variants, B active, with a note past each step count that the
    // loader must drop.
    const variants = [_]VariantSnap{
        .{ .step_count = 16, .notes = &.{
            .{ .pad = 0, .step = 0 },
            .{ .pad = 0, .step = 20 }, // step 20 is past 16 steps - stray
        } },
        .{ .step_count = 32, .notes = &.{ .{ .pad = 2, .step = 31 } } },
    };
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .content = .{ .drum_machine = .{ .variants = &variants, .variant = 1 } },
        }},
    };
    // zig fmt: on

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 2), dm.variant_count);
    try testing.expectEqual(@as(u8, 1), dm.variant);
    try testing.expectEqual(@as(u16, 32), dm.step_count);
    try testing.expect(dm.stepActive(2, 31)); // live = variant B
    dm.selectVariant(0);
    try testing.expectEqual(@as(u16, 16), dm.step_count);
    try testing.expect(dm.stepActive(0, 0));
    try testing.expect(!dm.stepActive(0, 20)); // stray bit was masked

    // A bank-less drum snap is not a shape this build can write.
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{ .label = "drums", .content = .{ .drum_machine = .{} } }},
    }));
}

fn buildVariantBanksForAllocationTest(allocator: std.mem.Allocator) !void {
    const variants = [_]VariantSnap{ .{}, .{ .step_count = 32 }, .{ .step_count = 64 } };
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{ .label = "drums", .content = .{ .drum_machine = .{ .variants = &variants } } }},
    };
    var session = try buildSession(allocator, &snap);
    session.deinit();
}

test "buildSession cleans partial variant banks after allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildVariantBanksForAllocationTest, .{});
}

test "buildSession: time signature lands in project and transport" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .beats_per_bar = 3,
        .tracks = &.{.{ .name = "t" }},
        .racks = &.{.{ .label = "t", .content = .empty }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectEqual(@as(u8, 3), session.project.beats_per_bar);
    try testing.expectEqual(@as(u8, 3), session.engine.transport.time_signature.beats_per_bar);
}

test "buildSession: a 64-step pattern round-trips bit 63 without truncation" {
    const testing = std.testing;
    const variants = [_]VariantSnap{.{
        .step_count = 64,
        .notes = &.{.{ .pad = 0, .step = 63 }},
    }};
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .content = .{ .drum_machine = .{ .variants = &variants, .variant = 0 } },
        }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u16, 64), dm.step_count);
    try testing.expect(dm.stepActive(0, 63));
}

test "buildSession: groups round-trip name, FX chain, and track membership" {
    const testing = std.testing;

    var groups: [engine_mod.max_groups]GroupSnap = [_]GroupSnap{.{}} ** engine_mod.max_groups;
    groups[2] = .{
        .active = true,
        .name = "drum bus",
        .fx_chain = &.{.{ .content = .{ .comp = .{ .threshold_db = -12.0 } } }},
        .gain_db = -6.0206, // linear 0.5
        .folded = true,
    };
    const snap: Snapshot = .{
        .tracks = &.{
            .{ .name = "kick", .group = 2 },
            .{ .name = "lead" }, // ungrouped
        },
        .racks = &.{
            .{ .label = "kick", .content = .empty },
            .{ .label = "lead", .content = .empty },
        },
        .groups = &groups,
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectEqualStrings("drum bus", session.groups[2].?.name);
    try testing.expectEqual(@as(usize, 1), session.groups[2].?.fx.units.items.len);
    try testing.expect(session.engine.groups[2].active);
    try testing.expectEqual(@as(usize, 1), session.engine.groups[2].chain.slice().len);

    try testing.expectEqual(@as(?u8, 2), session.project.tracks.items[0].group);
    try testing.expectEqual(@as(?u8, null), session.project.tracks.items[1].group);
    try testing.expectEqual(@as(?u8, 2), session.engine.trackAt(0).*.group);

    // Unused slots (0, 1, 3..) stay unloaded - no phantom groups.
    try testing.expect(session.groups[0] == null);
    try testing.expect(!session.engine.groups[0].active);

    // Tracks-view fold state survives the trip (UI-only, engine never sees it).
    try testing.expect(session.groups[2].?.folded);

    // The bus fader restores too. Engine-side it travels as a queued
    // command (same as track gain), so drain one block first.
    try testing.expectApproxEqAbs(@as(f32, -6.0206), session.groups[2].?.gain_db, 1e-4);
    var block: [256]f32 = undefined;
    session.engine.process(&block);
    try testing.expectApproxEqAbs(@as(f32, 0.5), session.engine.groups[2].gain, 1e-4);
}

test "buildSession: a track referencing a slot the file never marked active loads ungrouped" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "t", .group = 5 }}, // groups is empty - slot 5 was never active
        .racks = &.{.{ .label = "t", .content = .empty }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectEqual(@as(?u8, null), session.project.tracks.items[0].group);
}

test "buildSession restores independent mix automation lanes" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "track" }},
        .racks = &.{.{ .label = "track", .content = .empty }},
        .mix_automation = &.{
            .{ .target = .master_gain, .points = &.{.{ .beat = 2, .value = -6 }} },
            .{ .target = .{ .send_level = .{ .track = 0, .slot = 1 } }, .points = &.{.{ .beat = 3, .value = -12, .curve = .hold }} },
        },
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectEqual(@as(usize, 2), session.mix_automation.items.len);
    try testing.expectApproxEqAbs(@as(f32, -6), session.mix_automation.items[0].points[0].value, 1e-6);
    try testing.expectEqual(automation_mod.Curve.hold, session.mix_automation.items[1].points[0].curve);
}

test "choke groups round-trip through DrumSnap" {
    const testing = std.testing;

    var groups = [_]u8{0} ** DrumMachine.max_pads;
    groups[2] = 1;
    groups[3] = 1;
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .content = .{ .drum_machine = .{ .variants = &.{.{}}, .choke_group = &groups } },
        }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 1), dm.choke_group[2]);
    try testing.expectEqual(@as(u8, 1), dm.choke_group[3]);
    try testing.expectEqual(@as(u8, 0), dm.choke_group[0]);
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
    try testing.expectEqual(@as(u8, 1), cs.content.drum.variant);

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
        .racks = &.{.{ .label = "e", .content = .empty }},
    }));

    // Track/rack count mismatch.
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{ .{ .name = "a" }, .{ .name = "b" } },
        .racks = &.{.{ .label = "e", .content = .empty }},
    }));

    // Matched but empty: breaks the at-least-one-track invariant every
    // view relies on.
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{},
        .racks = &.{},
    }));

    // The engine has a fixed track bank. Reject an oversized matched pair
    // before dereferencing its elements or allocating an engine.
    const too_many_tracks: []const TrackSnap = @as(
        [*]const TrackSnap,
        @ptrFromInt(@alignOf(TrackSnap)),
    )[0 .. engine_mod.max_tracks + 1];
    const too_many_racks: []const RackSnap = @as(
        [*]const RackSnap,
        @ptrFromInt(@alignOf(RackSnap)),
    )[0 .. engine_mod.max_tracks + 1];
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = too_many_tracks,
        .racks = too_many_racks,
    }));

    // Nonsense sample rate.
    try testing.expectError(error.InvalidSampleRate, buildSession(testing.allocator, &.{
        .sample_rate = 0,
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .content = .empty }},
    }));

    // Clip spans must be non-empty and fit the u32 bar timeline.
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .content = .empty }},
        .arrangement = &.{.{ .clips = &.{.{ .start_tick = 1, .length_ticks = 0 }} }},
    }));
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .content = .empty }},
        .arrangement = &.{.{ .clips = &.{.{ .start_tick = std.math.maxInt(u32), .length_ticks = 1 }} }},
    }));
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .content = .empty }},
        .arrangement = &.{.{ .clips = &.{.{
            .start_tick = std.math.maxInt(u32) - 1,
            .length_ticks = 2,
        }} }},
    }));
}

test "generic FX snapshot loading ignores non-finite fields" {
    const nan = std.math.nan(f32);

    var gate = Gate.init(48_000);
    const gate_before = gate;
    applySnapToDevice(&gate, GateSnap{ .threshold_db = nan, .attack_ms = nan, .release_ms = nan });
    try std.testing.expectEqual(gate_before.threshold_db, gate.threshold_db);
    try std.testing.expectEqual(gate_before.attack_ms, gate.attack_ms);
    try std.testing.expectEqual(gate_before.release_ms, gate.release_ms);

    var sat: Saturator = .{};
    const sat_before = sat;
    applySnapToDevice(&sat, SatSnap{ .drive_db = nan, .out_db = nan, .mix = nan });
    try std.testing.expectEqual(sat_before.drive_db, sat.drive_db);
    try std.testing.expectEqual(sat_before.out_db, sat.out_db);
    try std.testing.expectEqual(sat_before.mix, sat.mix);

    var crush: Crusher = .{};
    const crush_before = crush;
    applySnapToDevice(&crush, CrushSnap{ .bits = nan, .downsample = nan, .mix = nan });
    try std.testing.expectEqual(crush_before.bits, crush.bits);
    try std.testing.expectEqual(crush_before.downsample, crush.downsample);
    try std.testing.expectEqual(crush_before.mix, crush.mix);

    var phaser = Phaser.init(48_000);
    const phaser_before = phaser;
    applySnapToDevice(&phaser, PhaserSnap{ .rate_hz = nan, .depth = nan, .feedback = nan, .mix = nan });
    try std.testing.expectEqual(phaser_before.rate_hz, phaser.rate_hz);
    try std.testing.expectEqual(phaser_before.depth, phaser.depth);
    try std.testing.expectEqual(phaser_before.feedback, phaser.feedback);
    try std.testing.expectEqual(phaser_before.mix, phaser.mix);
}

test "FX snapshot loading clamps in-range, not just finite" {
    const testing = std.testing;
    var fx: Fx = .{};
    defer fx.deinit(testing.allocator);
    // A hand-edited file's finite-but-absurd values used to land raw. Filter
    // `mode` is the sharp one: the FX editor renders it as `@as(u2, ...)`, so
    // anything past 3 aborted the frontend on the next draw.
    try applyFxChain(testing.allocator, &fx, &.{
        .{ .content = .{ .filter = .{ .mode = 9.0, .cutoff_hz = 1e9, .resonance = -5.0 } } },
        .{ .content = .{ .utility = .{ .gain_db = 500.0 } } },
    }, 48_000, null);

    const filter = &fx.units.items[0].payload.filter;
    try testing.expect(filter.mode >= 0.0 and filter.mode <= 2.0);
    try testing.expect(filter.cutoff_hz <= 20_000.0);
    try testing.expect(filter.resonance >= 0.1);
    try testing.expect(fx.units.items[1].payload.utility.gain_db <= 24.0);
}

test "specialized FX snapshot loading ignores non-finite fields" {
    const testing = std.testing;
    const nan = std.math.nan(f32);
    var fx: Fx = .{};
    defer fx.deinit(testing.allocator);
    try applyFxChain(testing.allocator, &fx, &.{
        .{ .content = .{ .comp = .{ .threshold_db = nan, .ratio = nan, .attack_ms = nan, .release_ms = nan, .makeup_db = nan } } },
        .{ .content = .{ .mb_comp = .{
            .xover_lo_hz = nan,
            .xover_hi_hz = nan,
            .attack_ms = nan,
            .release_ms = nan,
            .mix = nan,
            .low_threshold_db = nan,
            .low_ratio = nan,
            .low_makeup_db = nan,
            .mid_threshold_db = nan,
            .mid_ratio = nan,
            .mid_makeup_db = nan,
            .high_threshold_db = nan,
            .high_ratio = nan,
            .high_makeup_db = nan,
        } } },
        .{ .content = .{ .ott = .{ .depth = nan, .time = nan, .gain_in_db = nan, .gain_out_db = nan } } },
        .{ .content = .{ .delay = .{ .time_s = nan, .feedback = nan, .mix = nan } } },
    }, 48_000, null);

    const comp = &fx.units.items[0].payload.comp;
    try testing.expect(std.math.isFinite(comp.threshold_db));
    try testing.expect(std.math.isFinite(comp.ratio));
    try testing.expect(std.math.isFinite(comp.attack_ms));
    try testing.expect(std.math.isFinite(comp.release_ms));
    try testing.expect(std.math.isFinite(comp.makeup_db));

    const mb = &fx.units.items[1].payload.mb_comp;
    try testing.expect(std.math.isFinite(mb.xover_lo_hz));
    try testing.expect(std.math.isFinite(mb.xover_hi_hz));
    try testing.expect(std.math.isFinite(mb.attack_ms));
    try testing.expect(std.math.isFinite(mb.release_ms));
    try testing.expect(std.math.isFinite(mb.mix));
    for (mb.bands) |band| {
        try testing.expect(std.math.isFinite(band.threshold_db));
        try testing.expect(std.math.isFinite(band.ratio));
        try testing.expect(std.math.isFinite(band.makeup_db));
    }

    const ott = &fx.units.items[2].payload.ott;
    try testing.expect(std.math.isFinite(ott.depth()));
    try testing.expect(std.math.isFinite(ott.time));
    try testing.expect(std.math.isFinite(ott.gain_in_db));
    try testing.expect(std.math.isFinite(ott.gain_out_db));

    const delay = &fx.units.items[3].payload.delay;
    try testing.expect(std.math.isFinite(delay.time_s));
    try testing.expect(std.math.isFinite(delay.feedback));
    try testing.expect(std.math.isFinite(delay.mix));
}

test "buildSession: clamps out-of-range pad and note values" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .content = .{
                .drum_machine = .{
                    .variants = &.{.{}},
                    .pads = blk: {
                        var ps = [_]PadSnap{.{}} ** DrumMachine.max_pads;
                        // end < start and both far out of range.
                        ps[0] = .{ .used = true, .start_norm = 7.0, .end_norm = -3.0, .gain = 99.0 };
                        break :blk &ps;
                    },
                },
            },
        }},
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const pad = &session.racks.items[0].instrument.drum_machine.pads[0].?.pad;
    try testing.expect(pad.start_norm < pad.end_norm);
    try testing.expect(pad.gain <= 2.0);
    // The invariant adjustParam relies on: clamp bounds stay ordered.
    session.racks.items[0].instrument.drum_machine.adjustParam(DrumMachine.paramId(0, 0), 1);
    session.racks.items[0].instrument.drum_machine.adjustParam(DrumMachine.paramId(0, 1), -1);
}

test "buildSession: clamps a zero or negative pattern loop length" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{ .{ .name = "lead" }, .{ .name = "keys" } },
        .racks = &.{
            .{ .label = "synth", .content = .{ .poly_synth = .{ .pattern = .{ .length_beats = 0.0 } } } },
            .{ .label = "sampler", .content = .{ .sampler = .{ .pattern = .{ .length_beats = -8.0 } } } },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    // A hand-edited zero/negative loop length breaks the piano roll's step
    // math (steps - 1 underflow) and the playback wrap - same clamp the
    // clip loader already applies.
    try testing.expectEqual(@as(f64, 1.0), session.racks.items[0].pattern_player.?.length_beats);
    try testing.expectEqual(@as(f64, 1.0), session.racks.items[1].pattern_player.?.length_beats);
}

test "buildSession: track color round-trips and clamps out-of-range values" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{
            .{ .name = "lead", .color = 3 },
            .{ .name = "bass", .color = 255 }, // hand-edited, past the palette
        },
        .racks = &.{ .{ .label = "empty", .content = .empty }, .{ .label = "empty", .content = .empty } },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectEqual(@as(u8, 3), session.project.tracks.items[0].color);
    try testing.expectEqual(@as(u8, 16), session.project.tracks.items[1].color);
}

test "buildSession: empty and sampler racks round-trip" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{ .{ .name = "blank" }, .{ .name = "keys" } },
        .racks = &.{
            .{ .label = "empty", .content = .empty },
            .{
                .label = "sampler",
                .content = .{ .sampler = .{
                    .pad = .{ .pitch_semitones = 3.0, .gain = 0.8, .reverse = true },
                    .root_note = 48,
                    .mono = true,
                    .pattern = .{
                        .notes = &.{.{ .pitch = 64, .start_beat = 0.0, .duration_beat = 0.5, .velocity = 0.7 }},
                        .length_beats = 2.0,
                        .swing = 68.0,
                    },
                } },
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
    try testing.expect(smp.mono);

    const pp = &session.racks.items[1].pattern_player.?;
    try testing.expectEqual(@as(u16, 1), pp.note_count);
    try testing.expectEqual(@as(u7, 64), pp.notes[0].pitch);
    try testing.expectApproxEqAbs(@as(f64, 2.0), pp.length_beats, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 68.0), pp.swing.load(.monotonic), 1e-6);
}

test "buildSession clamps malformed synth params from a hand-edited file" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "lead" }},
        .racks = &.{
            .{
                .label = "synth",
                .content = .{ .poly_synth = .{
                    .unison = 255,
                    .osc_b_unison = 0,
                    .gain = 999.0,
                    .filter_cutoff = -500.0,
                    .attack_s = -1.0,
                    .sustain = 5.0,
                    .warp_amount = -50.0,
                    .osc_b_warp_amount = 50.0,
                    .lfo_rate_hz = 0.0,
                    .pattern = .{ .swing = 999.0 },
                } },
            },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const s = &session.racks.items[0].instrument.poly_synth;
    try testing.expect(s.unison >= 1 and s.unison <= 16);
    try testing.expect(s.osc_b_unison >= 1 and s.osc_b_unison <= 16);
    try testing.expect(s.gain >= 0.01 and s.gain <= 1.0);
    try testing.expect(s.filter_cutoff >= 20.0 and s.filter_cutoff <= 20_000.0);
    try testing.expect(s.attack_s >= 0.001);
    try testing.expect(s.sustain <= 1.0);
    try testing.expectEqual(@as(f32, 0.0), s.warp_amount);
    try testing.expectEqual(@as(f32, 8.0), s.osc_b_warp_amount);
    try testing.expect(s.lfo_rate_hz >= 0.01);

    const pp = &session.racks.items[0].pattern_player.?;
    try testing.expectApproxEqAbs(PatternPlayer.swing_max, pp.swing.load(.monotonic), 1e-6);
}

// 16-bit WAV round-trip quantisation error bound.
const wav_eps: f32 = 1.0 / 32768.0 + 1e-6;

test "save/load round-trip persists user-loaded drum pad samples" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;

    try dm.loadKitVariant(drum_kit.byName("default").?); // fresh machines are blank

    // Emulate :load-sample - user audio on pad 3, with a tweaked param.
    const clip = try testing.allocator.dupe(f32, &[_]f32{ 0.5, -0.5, 0.25, -0.125 });
    dm.setPadSamples(3, clip, "usr");
    dm.pads[3].?.pad.user_sample = true;
    dm.pads[3].?.pad.pitch_semitones = 5.0;

    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ldm = &loaded.racks.items[0].instrument.drum_machine;
    const pad = &ldm.pads[3].?.pad;
    try testing.expect(pad.user_sample);
    try testing.expectEqualStrings("usr", ldm.padName(3));
    try testing.expectEqual(@as(usize, 4), pad.samples.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), pad.samples[0], wav_eps);
    try testing.expectApproxEqAbs(@as(f32, -0.125), pad.samples[3], wav_eps);
    // Params applied by buildSession survive loadPadWav's sample swap.
    try testing.expectApproxEqAbs(@as(f32, 5.0), pad.pitch_semitones, 1e-4);
    // Shipped-kit pads stay shipped: no cache ref, no flag.
    try testing.expect(!ldm.pads[0].?.pad.user_sample);
}

/// Byte offset of a saved project's snapshot section. It equals the header
/// length exactly when the file carries no audio cache at all, so the
/// difference is the size of every blob the save wrote.
fn testCacheBytes(path: []const u8) !u64 {
    const testing = std.testing;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &persist_types.bundle_magic, bytes[0..persist_types.bundle_magic.len]);
    const snap_offset = std.mem.readInt(u64, bytes[persist_types.bundle_magic.len..][0..8], .little);
    return snap_offset - persist_types.bundle_header_len;
}

test "save doesn't accumulate stale audio when a sample moves pads" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;

    const clip = try testing.allocator.dupe(f32, &[_]f32{ 0.5, -0.5 });
    dm.setPadSamples(3, clip, "usr");
    dm.pads[3].?.pad.user_sample = true;
    try save(testing.allocator, &session, testing.io, wsj_path);
    const one_sample_bytes = try testCacheBytes(wsj_path);
    try testing.expect(one_sample_bytes > 0);

    // Same audio, now loaded onto pad 5 instead - pad 3 no longer exports.
    const clip2 = try testing.allocator.dupe(f32, &[_]f32{ 0.5, -0.5 });
    dm.setPadSamples(5, clip2, "usr");
    dm.pads[5].?.pad.user_sample = true;
    dm.pads[3].?.pad.user_sample = false;
    try save(testing.allocator, &session, testing.io, wsj_path);

    // The cache is rewritten whole, so the pad-3 blob is simply not in the
    // new file - one sample's worth of audio, not two.
    try testing.expectEqual(one_sample_bytes, try testCacheBytes(wsj_path));
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ldm = &loaded.racks.items[0].instrument.drum_machine;
    try testing.expect(ldm.pads[5].?.pad.user_sample);
    try testing.expect(ldm.pads[3] == null or !ldm.pads[3].?.pad.user_sample);
}

// The whole point of holding sample audio inside the .wsj: the file is the
// project, so moving it somewhere else can't strand its audio.
test "a project's samples survive the file being moved on its own" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;
    const clip = try testing.allocator.dupe(f32, &[_]f32{ 0.5, -0.5, 0.25, -0.25 });
    dm.setPadSamples(2, clip, "usr");
    dm.pads[2].?.pad.user_sample = true;
    try save(testing.allocator, &session, testing.io, wsj_path);

    var moved_buf: [80]u8 = undefined;
    const moved_dir = try std.fmt.bufPrint(&moved_buf, ".zig-cache/tmp/{s}/elsewhere", .{&tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(testing.io, moved_dir);
    var moved_path_buf: [96]u8 = undefined;
    const moved_path = try std.fmt.bufPrint(&moved_path_buf, "{s}/renamed.wsj", .{moved_dir});
    try std.Io.Dir.cwd().rename(wsj_path, std.Io.Dir.cwd(), moved_path, testing.io);

    var loaded = try load(testing.allocator, testing.io, moved_path);
    defer loaded.deinit();
    const pad = &loaded.racks.items[0].instrument.drum_machine.pads[2].?.pad;
    try testing.expect(pad.user_sample);
    try testing.expectEqual(@as(usize, 4), pad.samples.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), pad.samples[0], wav_eps);
    try testing.expectApproxEqAbs(@as(f32, -0.25), pad.samples[3], wav_eps);
}

test "save/load round-trip regenerates the kit rather than shipping its audio" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;
    try dm.loadKitVariant(drum_kit.byName("boombap").?);
    dm.pads[0].?.pad.pitch_semitones = -2.0;

    try save(testing.allocator, &session, testing.io, wsj_path);
    // Generated audio is never user audio, so none of it reaches the cache.
    try testing.expectEqual(@as(u64, 0), try testCacheBytes(wsj_path));

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ldm = &loaded.racks.items[0].instrument.drum_machine;
    try testing.expectEqualStrings("boombap", ldm.kit);
    try testing.expect(ldm.pads[0].?.pad.samples.len > 0); // regenerated, not silent
    try testing.expectEqualStrings("kick", ldm.padName(0));
    // The file still wins on params.
    try testing.expectApproxEqAbs(@as(f32, -2.0), ldm.pads[0].?.pad.pitch_semitones, 1e-4);

    // A machine left on the blank "init" kit reloads blank.
    try dm.loadKitVariant(drum_kit.byName("init").?);
    try save(testing.allocator, &session, testing.io, wsj_path);
    var blank = try load(testing.allocator, testing.io, wsj_path);
    defer blank.deinit();
    const bdm = &blank.racks.items[0].instrument.drum_machine;
    for (0..8) |p| try testing.expectEqualStrings("empty", bdm.padName(@intCast(p)));
}

test "save/load round-trip persists a pad rename with no sample change" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;
    try dm.loadKitVariant(drum_kit.byName("default").?); // fresh machines are blank

    // A plain :rename - no new sample, still the generated kick sample.
    dm.pads[0].?.rename("808");
    try testing.expectEqualStrings("kick-2", dm.padName(1)); // untouched pad unaffected

    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ldm = &loaded.racks.items[0].instrument.drum_machine;
    try testing.expectEqualStrings("808", ldm.padName(0));
    try testing.expectEqualStrings("kick-2", ldm.padName(1));
    // Still the shipped-kit sample - renaming alone doesn't flag user_sample.
    try testing.expect(!ldm.pads[0].?.pad.user_sample);
}

test "save/load round-trip persists a user-loaded sampler clip" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .sampler);
    const s = &session.racks.items[0].instrument.sampler;

    // Emulate :load-sample - swap the generated clip for user audio.
    testing.allocator.free(s.pad.samples);
    s.pad.samples = try testing.allocator.dupe(f32, &[_]f32{ 0.25, -0.25 });
    s.pad.name = [_]u8{ 'v', 'o', 'x', ' ', ' ', ' ', ' ', ' ' };
    s.pad.user_sample = true;
    s.pad.gain = 0.8;

    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ls = &loaded.racks.items[0].instrument.sampler;
    try testing.expect(ls.pad.user_sample);
    try testing.expectEqualStrings("vox", pad_mod.trimmedName(&ls.pad.name));
    try testing.expectEqual(@as(usize, 2), ls.pad.samples.len);
    try testing.expectApproxEqAbs(@as(f32, 0.25), ls.pad.samples[0], wav_eps);
    try testing.expectApproxEqAbs(@as(f32, 0.8), ls.pad.gain, 1e-4);
}

test "save/load round-trip persists audio sources and regions" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const source_id = try session.project.addAudioSource("recorded", 48_000, 2, &.{ 0.25, -0.25, -0.125, 0.125 });
    try session.arrangement.lane(0).?.place(testing.allocator, ws_arrangement.Clip.initAudio(0, 32, .{
        .source_id = source_id,
        .source_start_frame = 0,
        .source_length_frames = 2,
        .gain_db = -3.0,
        .fade_in_frames = 1,
        .fade_out_frames = 2,
    }));
    try testing.expect(session.arrangement.lane(0).?.clips.items[0].addAudioTake(.{
        .source_id = source_id,
        .source_start_frame = 1,
        .source_length_frames = 1,
        .length_ticks = 16,
    }));
    session.setSongMode(true);
    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.project.audio_sources.items.len);
    try testing.expectEqual(@as(u16, 2), loaded.project.audio_sources.items[0].channel_count);
    try testing.expectApproxEqAbs(@as(f32, 0.25), loaded.project.audio_sources.items[0].samples[0], wav_eps);
    try testing.expectApproxEqAbs(@as(f32, -0.25), loaded.project.audio_sources.items[0].samples[1], wav_eps);
    const region = loaded.arrangement.lane(0).?.clips.items[0].content.audio;
    try testing.expectEqual(source_id, region.source_id);
    try testing.expectEqual(@as(u64, 1), region.source_length_frames);
    try testing.expectApproxEqAbs(@as(f32, -3.0), region.gain_db, 1e-6);
    try testing.expectEqual(@as(u64, 1), region.fade_in_frames);
    try testing.expectEqual(@as(u64, 2), region.fade_out_frames);
    try testing.expectEqual(@as(usize, 2), region.takeCount());
    try testing.expectEqual(@as(u64, 0), region.alternate_takes[0].?.source_start_frame);
    try testing.expectEqual(@as(u64, 2), region.alternate_takes[0].?.source_length_frames);
}

test "save/load round-trip persists a :load-wavetable-imported table, default state caches no audio" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .poly_synth);
    const s = &session.racks.items[0].instrument.poly_synth;

    // A synth that never touches wavetables shouldn't cache any audio.
    try save(testing.allocator, &session, testing.io, wsj_path);
    try testing.expectEqual(@as(u64, 0), try testCacheBytes(wsj_path));

    // Emulate :load-wavetable on OSC B.
    var samples: [wavetable_mod.frame_len * 2]f32 = undefined;
    @memset(samples[0..wavetable_mod.frame_len], -1.0);
    @memset(samples[wavetable_mod.frame_len..], 1.0);
    var wav_buf: [wavetable_mod.frame_len * 2 * 4 + 64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wav_buf);
    try wav.write(&writer, session.project.sample_rate, 1, &samples, .pcm16);
    try s.loadWavetable(.b, writer.buffered());
    s.osc_b_wt_pos = 0.5;

    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ls = &loaded.racks.items[0].instrument.poly_synth;
    try testing.expectEqual(@as(usize, 2), ls.osc_b_wt.frame_count);
    // Wider tolerance than a single WAV round trip's `wav_eps`: this value
    // passes through pcm16 three times (this test's own synthetic WAV, the
    // cache export, then the cache reload), compounding quantization.
    try testing.expectApproxEqAbs(@as(f32, -1.0), ls.osc_b_wt.frames[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ls.osc_b_wt.frames[wavetable_mod.frame_len], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ls.osc_b_wt_pos, 1e-4);
    // OSC A never got a `:load-wavetable` call - still the bundled default,
    // nothing cached for it.
    try testing.expect(!ls.wt_user);
}

test "save/load round-trip persists a loaded soundfont, its cached .sf2, and the selected preset" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .soundfont);
    const sf = &session.racks.items[0].instrument.soundfont;

    const sf2_bytes = try soundfont_mod.buildTestSf2(testing.allocator, true, session.project.sample_rate);
    defer testing.allocator.free(sf2_bytes);
    try sf.loadSf2(sf2_bytes);
    sf.gain = 0.6;
    sf.pan = 0.4;
    sf.transpose_semitones = -5.0;

    try save(testing.allocator, &session, testing.io, wsj_path);
    // The .sf2 goes into the cache byte for byte, not re-encoded.
    const project_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, wsj_path, testing.allocator, .limited(64 * 1024 * 1024));
    defer testing.allocator.free(project_bytes);
    try testing.expect(std.mem.indexOf(u8, project_bytes, sf2_bytes) != null);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ls = &loaded.racks.items[0].instrument.soundfont;
    try testing.expectEqual(@as(usize, 1), ls.presetCount());
    try testing.expectEqualStrings("Test Preset", ls.presetName());
    try testing.expectApproxEqAbs(@as(f32, 0.6), ls.gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.4), ls.pan, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -5.0), ls.transpose_semitones, 1e-6);
}

test "save/load round-trip persists bundled acoustic id without cached audio" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .acoustic);
    try session.racks.items[0].instrument.acoustic.loadBuiltin(testing.io, .harpsichord);
    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    // The kind survives too, not just the bank - acoustic and soundfont are
    // separate instruments that happen to share a snapshot shape.
    const sf = &loaded.racks.items[0].instrument.acoustic;
    try testing.expectEqual(@import("dsp/builtin_library.zig").Id.harpsichord, sf.builtin.?);
    try testing.expectEqualStrings("Italian Harpsichord", sf.presetName());
}

test "buildSession: A/B loop region lands in project and transport" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .loop_enabled = true,
        .loop_start_bar = 2,
        .loop_end_bar = 4,
        .tracks = &.{.{ .name = "t" }},
        .racks = &.{.{ .label = "t", .content = .empty }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expect(session.project.loop_enabled);
    try testing.expectEqual(@as(u32, 2), session.project.loop_start_bar);
    // 120 bpm 4/4 @ 48k → 96_000 frames per bar.
    try testing.expect(session.engine.transport.loop_enabled);
    try testing.expectEqual(@as(u64, 192_000), session.engine.transport.loop_start_frames);
    try testing.expectEqual(@as(u64, 384_000), session.engine.transport.loop_end_frames);

    // An inverted region deserialises disabled.
    var bad = try buildSession(testing.allocator, &.{
        .loop_enabled = true,
        .loop_start_bar = 4,
        .loop_end_bar = 2,
        .tracks = &.{.{ .name = "t" }},
        .racks = &.{.{ .label = "t", .content = .empty }},
    });
    defer bad.deinit();
    try testing.expect(!bad.engine.transport.loop_enabled);
}

test "save/load round-trip persists LFO 2/3, macros, and their matrix sources" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/lfo23.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    session.racks.items[0].instrument = .{ .poly_synth = try PolySynth.init(testing.allocator, session.project.sample_rate) };
    const s = &session.racks.items[0].instrument.poly_synth;
    // zig fmt: off
    s.lfo2_shape = .sh;  s.lfo2_rate_hz = 6.5;
    s.lfo3_shape = .chaos; s.lfo3_rate_hz = 0.25;
    s.macro1 = 0.33; s.macro4 = 0.9;
    s.mod_matrix[0] = .{ .source = .lfo2, .dest = 21,                 .depth = 0.5 };
    s.mod_matrix[1] = .{ .source = .mac1, .dest = PolySynth.dest_amp, .depth = -0.3 };
    // zig fmt: on

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const ls = &loaded.racks.items[0].instrument.poly_synth;
    try testing.expectEqual(synth_mod.LfoShape.sh, ls.lfo2_shape);
    try testing.expectApproxEqAbs(@as(f32, 6.5), ls.lfo2_rate_hz, 1e-6);
    try testing.expectEqual(synth_mod.LfoShape.chaos, ls.lfo3_shape);
    try testing.expectApproxEqAbs(@as(f32, 0.25), ls.lfo3_rate_hz, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.33), ls.macro1, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), ls.macro4, 1e-6);
    try testing.expectEqual(synth_mod.ModSource.lfo2, ls.mod_matrix[0].source);
    try testing.expectEqual(synth_mod.ModSource.mac1, ls.mod_matrix[1].source);
    try testing.expectApproxEqAbs(@as(f32, -0.3), ls.mod_matrix[1].depth, 1e-6);
}

test "save/load round-trip persists a drawn LFO shape's points" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/lfo_custom.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    session.racks.items[0].instrument = .{ .poly_synth = try PolySynth.init(testing.allocator, session.project.sample_rate) };
    const s = &session.racks.items[0].instrument.poly_synth;
    s.lfo_shape = .drawn;
    s.lfo_custom[0][0] = .{ .phase = 0.0, .value = -0.6 };
    s.lfo_custom[0][1] = .{ .phase = 0.4, .value = 0.8 };
    s.lfo_custom[0][2] = .{ .phase = 1.0, .value = -0.6 };
    s.lfo_custom_count[0] = 3;
    s.lfo3_shape = .drawn;
    s.lfo_custom[2][0] = .{ .phase = 0.0, .value = 1.0 };
    s.lfo_custom[2][1] = .{ .phase = 1.0, .value = -1.0 };
    s.lfo_custom_count[2] = 2;

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const ls = &loaded.racks.items[0].instrument.poly_synth;
    try testing.expectEqual(synth_mod.LfoShape.drawn, ls.lfo_shape);
    try testing.expectEqual(@as(u8, 3), ls.lfo_custom_count[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.4), ls.lfo_custom[0][1].phase, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), ls.lfo_custom[0][1].value, 1e-6);
    try testing.expectEqual(synth_mod.LfoShape.drawn, ls.lfo3_shape);
    try testing.expectEqual(@as(u8, 2), ls.lfo_custom_count[2]);
    try testing.expectApproxEqAbs(@as(f32, -1.0), ls.lfo_custom[2][1].value, 1e-6);
    // LFO 2 round-trips its untouched default sine, bends and all.
    try testing.expectEqual(synth_mod.LfoWave.sine, synth_mod.lfoWaveOf(ls.lfo_custom[1][0..ls.lfo_custom_count[1]]));
}

test "a synth preset replaces the whole FX chain and rebinds its mod rows" {
    const testing = std.testing;
    var rack = Rack{
        .instrument = .{ .poly_synth = try PolySynth.init(testing.allocator, 48_000) },
        .label = "test",
    };
    defer rack.deinit(testing.allocator);
    _ = try rack.fx.insert(testing.allocator, 0, .comp, 48_000);

    var first: PolySynth.Patch = .{};
    first.fx_chorus_on = true;
    first.fx_reverb_on = true;
    first.fx_dist_on = true;
    first.mod_matrix[0] = .{ .source = .mac1, .dest = 85, .depth = 0.5 };
    {
        var old = try applySynthPatch(testing.allocator, &rack, first, 48_000);
        old.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 3), rack.fx.units.items.len);
    const sat = rack.fx.find(.sat).?;
    try testing.expectEqual(sat.instance_id, rack.instrument.poly_synth.mod_matrix[0].fx_instance_id);

    var second: PolySynth.Patch = .{};
    second.fx_delay_on = true;
    {
        var old = try applySynthPatch(testing.allocator, &rack, second, 48_000);
        old.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 1), rack.fx.units.items.len);
    try testing.expectEqual(rack_mod.FxKind.delay, rack.fx.units.items[0].kind());

    // The same path a `:synth-preset` runs, against a shipped preset that
    // modulates an FX param (warm-pad's mac3 -> reverb mix). A row left on
    // instance 0 modulates nothing, which is exactly how this broke once.
    const warm = for (@import("dsp/synth_presets.zig").presets) |p| {
        if (std.mem.eql(u8, p.name, "warm-pad")) break p;
    } else return error.PresetMissing;
    {
        var old = try applySynthPatch(testing.allocator, &rack, warm.patch, 48_000);
        old.deinit(testing.allocator);
    }
    const reverb = rack.fx.find(.reverb).?;
    for (rack.instrument.poly_synth.mod_matrix) |row| {
        if (row.dest != 115) continue; // reverb mix
        try testing.expectEqual(reverb.instance_id, row.fx_instance_id);
        break;
    } else return error.PresetRowMissing;
}

test "save/load round-trip persists an EQ band's lowpass/highpass type and slope" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/eq_type.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const unit = try session.racks.items[0].fx.insert(testing.allocator, 0, .eq, session.project.sample_rate);
    unit.payload.eq.setType(0, .highpass, 3);
    unit.payload.eq.setType(1, .lowpass, 2);

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const eq = &loaded.racks.items[0].fx.units.items[0].payload.eq;
    try testing.expectEqual(eq_mod.BandKind.highpass, eq.bands[0].kind);
    try testing.expectEqual(@as(u8, 3), eq.bands[0].slope);
    try testing.expectEqual(eq_mod.BandKind.lowpass, eq.bands[1].kind);
    try testing.expectEqual(@as(u8, 2), eq.bands[1].slope);
    // Untouched bands keep the default peak type.
    try testing.expectEqual(eq_mod.BandKind.peak, eq.bands[2].kind);
}

test "save/load round-trip persists solo/stereo-mode/dynamic-EQ/auto-gain" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/eq_dyn.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const unit = try session.racks.items[0].fx.insert(testing.allocator, 0, .eq, session.project.sample_rate);
    var e = &unit.payload.eq;
    e.setType(0, .tiltshelf, 1);
    e.setType(1, .notch, 2);
    e.setSolo(2, true);
    e.setStereoMode(3, .mid);
    e.setDynEnabled(4, true);
    e.setDynThreshold(4, -18.0);
    e.setDynAmount(4, 7.5);
    e.setAutoGain(true);

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    e = &loaded.racks.items[0].fx.units.items[0].payload.eq;
    try testing.expectEqual(eq_mod.BandKind.tiltshelf, e.bands[0].kind);
    try testing.expectEqual(eq_mod.BandKind.notch, e.bands[1].kind);
    try testing.expectEqual(@as(u8, 2), e.bands[1].slope);
    try testing.expect(e.bands[2].solo);
    try testing.expectEqual(eq_mod.StereoMode.mid, e.bands[3].stereo_mode);
    try testing.expect(e.bands[4].dyn_enabled);
    try testing.expectApproxEqAbs(@as(f32, -18.0), e.bands[4].dyn_threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 7.5), e.bands[4].dyn_amount_db, 1e-4);
    try testing.expect(e.auto_gain);
}

/// Render `blocks` blocks from `session` starting at frame 0 into `out`.
fn renderFromStart(session: *Session, out: []f32, block_frames: usize) void {
    session.engine.transport.seekFrames(0);
    session.engine.transport.play();
    var i: usize = 0;
    while (i + block_frames <= out.len) : (i += block_frames) {
        session.engine.process(out[i..][0..block_frames]);
    }
}

// The property every per-field round-trip test only approximates: a project
// read back off disk has to *sound* like the session that wrote it. Field
// assertions can only check what someone thought to assert, and they say
// nothing about the derived, engine-side state a load has to rebuild -
// chains, sidechain routing, group buses, the song buffers. Rendering both
// and comparing samples covers all of it at once, and it is what actually
// matters about a save file.
//
// Kept cheap on purpose: a handful of shapes, 32 blocks each.
test "a loaded project renders sample-identical to the session that saved it" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/render.wsj", .{&tmp.sub_path});

    const Cases = struct {
        /// A synth pattern through a track FX chain, into a group bus with
        /// its own FX, into a master chain - every routing stage at once.
        fn full(s: *Session) !void {
            try s.setInstrument(0, .poly_synth);
            const pp = &s.racks.items[0].pattern_player.?;
            pp.length_beats = 4.0;
            pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
            pp.addNote(.{
                .pitch = 67,
                .start_beat = 1.5,
                .duration_beat = 0.5,
                .velocity = 0.5,
                // Per-note expression rides the same round trip as velocity:
                // a note that saves centred and in tune has lost it.
                .art = .{ .pan = -0.6, .fine_cents = 25.0, .release_scale = 2.5 },
            });
            _ = try s.racks.items[0].fx.insert(s.allocator, 0, .delay, s.project.sample_rate);
            s.syncTrackChain(0, s.racks.items[0]);
            // Both writes App.setTrackGain/setTrackPan make - the struct the
            // file is built from, and the engine that renders.
            s.project.tracks.items[0].gain_db = -3.0;
            s.project.tracks.items[0].pan = -0.4;
            _ = s.engine.send(.{ .set_track_gain = .{ .track = 0, .gain = types.dbToGain(-3.0) } });
            _ = s.engine.send(.{ .set_track_pan = .{ .track = 0, .pan = -0.4 } });
            const g = try s.addGroup("bus");
            s.assignTrackGroup(0, g);
            s.setGroupGain(g, -4.5);
            _ = try s.groups[g].?.fx.insert(s.allocator, 0, .reverb, s.project.sample_rate);
            s.syncGroupChain(g);
            _ = try s.master_fx.insert(s.allocator, 0, .comp, s.project.sample_rate);
            s.syncMasterChain();
            s.project.tempo_bpm = 137.5;
        }

        /// A drum kit's pads and steps, which load regenerates rather than
        /// reads back (see `DrumSnap.kit`).
        fn drums(s: *Session) !void {
            try s.setInstrument(0, .drum_machine);
            const dm = &s.racks.items[0].instrument.drum_machine;
            try dm.loadKitVariant(drum_kit.byName("default").?);
            dm.toggleStep(0, 0);
            dm.toggleStep(1, 4);
            dm.setStepVel(1, 4, 77);
        }

        /// Song mode: the device song buffers are rebuilt from placed clips
        /// on load, not stored.
        fn song(s: *Session) !void {
            try s.setInstrument(0, .poly_synth);
            const pp = &s.racks.items[0].pattern_player.?;
            pp.length_beats = 4.0;
            pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
            try s.stampClipAtTick(0, 0);
            try s.stampClipAtTick(0, time_grid.barTicks(4, 4) * 2);
            s.setSongMode(true);
        }
    };

    const block_frames = 256;
    const total = 32 * block_frames;
    const live = try testing.allocator.alloc(f32, total);
    defer testing.allocator.free(live);
    const reloaded = try testing.allocator.alloc(f32, total);
    defer testing.allocator.free(reloaded);

    inline for (.{ Cases.full, Cases.drums, Cases.song }) |build| {
        var s = try Session.initDefault(testing.allocator);
        defer s.deinit();
        try build(&s);
        try save(testing.allocator, &s, testing.io, wsj_path);
        var l = try load(testing.allocator, testing.io, wsj_path);
        defer l.deinit();

        renderFromStart(&s, live, block_frames);
        renderFromStart(&l, reloaded, block_frames);

        var peak: f32 = 0;
        for (live) |v| peak = @max(peak, @abs(v));
        // A silent render would pass the comparison for the wrong reason.
        try testing.expect(peak > 1e-4);
        for (live, reloaded) |a, b| try testing.expectApproxEqAbs(a, b, 1e-6);
    }
}

test "a file from another format version is refused, not half-read" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/old.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try save(testing.allocator, &session, testing.io, wsj_path);

    // `version` is the snapshot's first field, so it sits right after the
    // header in a project holding no audio - bump it and the file is from a
    // build this one can't read.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, wsj_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    const offset = std.mem.readInt(u64, bytes[persist_types.bundle_magic.len..][0..8], .little);
    try testing.expectEqual(@as(u8, file_version), bytes[@intCast(offset)]); // one LEB byte while < 128
    bytes[@intCast(offset)] = file_version + 1;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = wsj_path, .data = bytes });

    try testing.expectError(error.UnsupportedVersion, load(testing.allocator, testing.io, wsj_path));
}

test "a truncated project file is refused" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/cut.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try save(testing.allocator, &session, testing.io, wsj_path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, wsj_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = wsj_path, .data = bytes[0 .. bytes.len / 2] });

    try testing.expectError(error.CorruptProjectFile, load(testing.allocator, testing.io, wsj_path));
}

test "save/load round-trip persists a pitch shifter, and its heap buffers survive dupe" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/pitch.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sr = session.project.sample_rate;
    const unit = try session.master_fx.insert(testing.allocator, 0, .pitch_shift, sr);
    unit.payload.pitch_shift.semitones = -7.0;
    unit.payload.pitch_shift.cents = 12.0;
    unit.payload.pitch_shift.formant = 5.0;
    unit.payload.pitch_shift.mix = 0.4;
    session.syncMasterChain();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const p = &loaded.master_fx.units.items[0].payload.pitch_shift;
    try testing.expectApproxEqAbs(@as(f32, -7.0), p.semitones, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 12.0), p.cents, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5.0), p.formant, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.4), p.mix, 1e-4);
    // Loaded from a file, so the buffers are freshly allocated, not aliased from
    // the saved session - the same rule chorus/delay/reverb follow.
    try testing.expect(p.pending[0].ptr != unit.payload.pitch_shift.pending[0].ptr);

    var copy = try loaded.master_fx.units.items[0].payload.dupe(testing.allocator, sr);
    defer copy.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, -7.0), copy.pitch_shift.semitones, 1e-4);
    try testing.expect(copy.pitch_shift.pending[0].ptr != p.pending[0].ptr);
}

test "save/load round-trip persists controllers and learned CCs, dropping targets on tracks that are gone" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/ctrl.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    _ = try session.addTrack("second");

    // Slot 2, not 0 - the saved index has to survive, not the array position.
    session.project.controllers[2] = .{ .shape = .triangle, .beats = 8.0, .depth = 0.75, .phase = 0.25 };
    session.project.controllers[2].?.targets[0] = .{
        .track = 1,
        .param_id = 21,
        .center = 1000.0,
        .lo = 20.0,
        .hi = 20_000.0,
    };
    // A target on a track this project doesn't have must not come back.
    session.project.controllers[2].?.targets[1] = .{
        .track = 40,
        .param_id = 3,
        .center = 0.5,
        .lo = 0.0,
        .hi = 1.0,
    };
    session.project.cc_bindings[0] = .{ .cc = 74, .target = .{
        .track = 1,
        .param_id = 21,
        .center = 1000.0,
        .lo = 20.0,
        .hi = 20_000.0,
    } };
    // ...and neither must a CC binding on one.
    session.project.cc_bindings[1] = .{ .cc = 75, .target = .{
        .track = 40,
        .param_id = 3,
        .center = 0.5,
        .lo = 0.0,
        .hi = 1.0,
    } };
    session.syncModulation();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    try testing.expect(loaded.project.controllers[0] == null);
    const c = loaded.project.controllers[2].?;
    try testing.expectEqual(lfo_mod.Shape.triangle, c.shape);
    try testing.expectApproxEqAbs(@as(f32, 8.0), c.beats, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.75), c.depth, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), c.phase, 1e-4);
    try testing.expectEqual(@as(u16, 1), c.targets[0].?.track);
    try testing.expectEqual(@as(u32, 21), c.targets[0].?.param_id);
    try testing.expectApproxEqAbs(@as(f32, 1000.0), c.targets[0].?.center, 1e-4);
    try testing.expect(c.targets[1] == null);
    const cc = loaded.project.cc_bindings[0].?;
    try testing.expectEqual(@as(u7, 74), cc.cc);
    try testing.expectEqual(@as(u32, 21), cc.target.param_id);
    try testing.expect(loaded.project.cc_bindings[1] == null);
    // The load path pushes both, so the audio thread has them without a
    // further edit.
    try testing.expectEqual(@as(u16, 1), loaded.engine.controllers[2].?.targets[0].?.track);
    try testing.expectEqual(@as(u7, 74), loaded.engine.cc_bindings[0].?.cc);
}

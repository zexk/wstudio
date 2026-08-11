//! Integration tests for the TUI App: input dispatch, per-view editors,
//! undo/redo, commands, and frame rendering. Split out of app.zig so the
//! runtime file stays navigable; pulled in by the `test` block there.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const eq_mod = ws.dsp.eq;
const InstrumentKind = ws.InstrumentKind;
const app_mod = @import("../ui/app.zig");
const tui_mod = @import("tui.zig");
const App = app_mod.App;
const history = @import("../ui/history.zig");
const AppView = app_mod.AppView;
const note_ms = app_mod.note_ms;
const commands = @import("../ui/commands.zig");
const commands_load = @import("../ui/commands_load.zig");
const commands_mixer = @import("../ui/commands_mixer.zig");
const cmd_mod = @import("../ui/cmd.zig");
const drum_ed = @import("../ui/editors/drum.zig");
const step_grid = @import("../ui/editors/step_grid.zig");
const slicer_ed = @import("../ui/editors/slicer.zig");
const automation_mod = ws.dsp.automation;
const automation_ed = @import("../ui/editors/automation.zig");
const style = @import("style.zig");
const piano_ed = @import("../ui/editors/piano.zig");
const sampler_ed = @import("../ui/editors/sampler.zig");
const spectrum_ed = @import("../ui/editors/fx_editor.zig");
const soundfont_ed = @import("../ui/editors/soundfont.zig");
const synth_ed_mod = @import("../ui/editors/synth.zig");
const preset_ed = @import("../ui/editors/preset_picker.zig");
const icons = @import("../ui/icons.zig");
const ansi = @import("../ui/ansi.zig");
const modal_mod = ws.input;

/// Redirects $HOME at `tmp` for tests that build an App with real io (not
/// `std.Io.failing`) and dispatch real commands - otherwise cmd-history/
/// synth-preset persistence would leak writes into the developer's actual
/// `~/.config/wstudio/`.
const redirectHome = @import("../ui/json_store.zig").testRedirectHome;

/// Build a deterministic 3-track app for tests: synth(0), sampler(1), drums(2).
fn testApp() !App {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    errdefer app.deinit();
    try app.session.setInstrument(0, .poly_synth);
    _ = try app.session.addTrack("samp");
    try app.session.setInstrument(1, .sampler);
    _ = try app.session.addTrack("drums");
    try app.session.setInstrument(2, .drum_machine);
    // A fresh drum machine is the blank "init" kit; most tests here poke at
    // real pads (names, params, waveforms), so stock it like a user would.
    try app.session.racks.items[2].instrument.drum_machine.loadKitVariant(ws.dsp.drum_kit.byName("default").?);
    return app;
}

fn installSlicerTestClip(app: *App) !void {
    const sl = app.slicerInst();
    std.testing.allocator.free(sl.samples);
    sl.samples = try std.testing.allocator.alloc(f32, 1024);
    @memset(sl.samples, 0.5);
    for (&sl.slices) |*p| p.samples = sl.samples;
}

test "cursor movement clamps to track range, plus one for the master row" {
    var app = try testApp();
    defer app.deinit();

    // 3 tracks (indices 0-2) + the master row at index 3.
    app.applyAction(.{ .move = .{ .dy = 10 } }, 0);
    try std.testing.expectEqual(@as(usize, 3), app.cursor);
    app.applyAction(.{ .move = .{ .dy = -1 } }, 0);
    try std.testing.expectEqual(@as(usize, 2), app.cursor);
    app.applyAction(.{ .move = .{ .dy = -10 } }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
}

test "/ fuzzy-searches track names; n/N repeat and wrap around" {
    var app = try testApp();
    defer app.deinit();
    // Tracks: 0 "untitled track", 1 "samp", 2 "drums" (+ master row at 3).
    app.cursor = 0;

    for ("/drs") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.cursor); // "drums"

    for ("/smp") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor); // "samp"

    // Only "samp" matches "smp" - n/N both just re-land on it (wraparound
    // with a single hit).
    app.handleKey(.{ .char = 'n' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    app.handleKey(.{ .char = 'N' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor);

    // A pattern matching two tracks ("untitled track" and "samp" both have
    // 'a'; "drums" doesn't) cycles between them, skipping the non-match.
    for ("/a") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor); // "untitled track"
    app.handleKey(.{ .char = 'n' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor); // "samp"
    app.handleKey(.{ .char = 'n' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor); // back to "untitled track"
    app.handleKey(.{ .char = 'N' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor); // reverse: "samp"
}

test "arrangement: / fuzzy-searches lane (track) names; n/N repeat and wrap" {
    var app = try testApp();
    defer app.deinit();
    // Tracks: 0 "untitled track", 1 "samp", 2 "drums" - no master lane here.
    app.view = .arrangement;
    app.cursor = 0;

    for ("/drs") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.cursor); // "drums"
    try std.testing.expectEqual(AppView.arrangement, app.view); // stayed put

    // A pattern matching two lanes ("untitled track" and "samp") cycles
    // between them with n/N, wrapping past "drums".
    for ("/a") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor); // "untitled track"
    app.handleKey(.{ .char = 'n' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor); // "samp"
    app.handleKey(.{ .char = 'N' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor); // back to "untitled track"
}

test "/ search: escape cancels without moving the cursor; no match reports a status" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 0;

    app.handleKey(.{ .char = '/' }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);
    for ("zzz") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);

    for ("/zzz") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor); // no match - stays put
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "no match") != null);
}

test "help view: / search jumps and anchors n/N; ? closes" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.{ .char = '?' }, 0); // open from tracks
    try std.testing.expectEqual(AppView.help, app.view);
    try std.testing.expect(app.help_scroll > 0); // landed on the TRACKS section
    try std.testing.expectEqual(@as(?usize, null), app.help_search_hit);

    for ("/slicer") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    const first_hit = app.help_search_hit orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(first_hit, app.help_scroll); // hit scrolled to window top

    // "slicer" matches several lines: n advances to a different one, N returns.
    app.handleKey(.{ .char = 'n' }, 0);
    const second_hit = app.help_search_hit orelse return error.TestUnexpectedResult;
    try std.testing.expect(second_hit != first_hit);
    app.handleKey(.{ .char = 'N' }, 0);
    try std.testing.expectEqual(@as(?usize, first_hit), app.help_search_hit);

    // ? toggles help closed, back to the view that opened it; reopening
    // starts with a clean hit.
    app.handleKey(.{ .char = '?' }, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    app.handleKey(.{ .char = '?' }, 0);
    try std.testing.expectEqual(@as(?usize, null), app.help_search_hit);
    app.handleKey(.escape, 0);
}

test "/ search reports unavailable in a view with nothing to search" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    app.drum_cursor = .{ 3, 5 };

    for ("/kick") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
    // Typed pattern chars didn't leak into drum-grid navigation.
    try std.testing.expectEqual(@as(u8, 3), app.drum_cursor[0]);
    try std.testing.expectEqual(@as(u8, 5), app.drum_cursor[1]);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "not available") != null);
}

test "default session starts with one blank track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 1), app.session.racks.items.len);
    try std.testing.expectEqual(InstrumentKind.empty, std.meta.activeTag(app.session.racks.items[0].instrument));
}

test "enter on a blank track opens the instrument picker" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.instrument_picker, app.view);
}

test "picker inserts the highlighted instrument and opens its editor" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.enter, 0); // open picker on the blank track
    app.handleKey(.{ .char = 'j' }, 0); // move to Sampler (index 1)
    try std.testing.expectEqual(@as(u8, 1), app.picker_cursor);
    app.handleKey(.enter, 0); // insert
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[0].instrument));
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
}

test "instrument picker / narrows instruments and enter inserts match" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.enter, 0);
    for ("/slice") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("slice", app.activeInstrumentFilter());

    var buf: [app_mod.instrument_picker_items.len]app_mod.InstrumentPickerItem = undefined;
    const items = app.filteredInstrumentPickerItems(&buf);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(ws.InstrumentKind.slicer, items[0].kind);

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expectEqual(ws.InstrumentKind.slicer, std.meta.activeTag(app.session.racks.items[0].instrument));
}

test "instrument picker click during live search submits then inserts clicked match" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.enter, 0);
    for ("/s") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);

    app.clickInstrumentPickerItem(1, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expectEqual(ws.InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[0].instrument));
}

test "instrument picker mouse click during live search exits search mode" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.enter, 0);
    for ("/s") |c| app.handleKey(.{ .char = c }, 0);
    app.handleMouse(.{ .x = 4, .y = app_mod.content_top + 4, .button = .left, .kind = .press }, 80, 24, 0);

    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expectEqual(ws.InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[0].instrument));
}

test "renderBounce sequences notes offline and restores transport" {
    var app = try testApp();
    defer app.deinit();

    // Sequence a note at beat 0 on the synth track; leave the transport stopped.
    app.session.racks.items[0].pattern_player.?.addNote(
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 },
    );
    try std.testing.expect(!app.session.engine.transport.playing);

    var buffer: [4096 * engine_mod.channels]types.Sample = undefined;
    commands_mixer.renderBounce(&app, &buffer, 0);

    var peak: f32 = 0.0;
    for (buffer) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.001);

    try std.testing.expect(!app.session.engine.transport.playing);
    try std.testing.expectEqual(@as(u64, 0), app.session.engine.transport.position_frames);
}

test "renderBounce honors a nonzero start_frame and restores transport position" {
    var app = try testApp();
    defer app.deinit();

    // A note starting after frame 0 should be silent for the leading portion
    // of the buffer if the render starts at frame 0, but audible immediately
    // if the render starts at the note's own frame.
    const fpb = app.session.engine.transport.framesPerBeat();
    app.session.racks.items[0].pattern_player.?.addNote(
        .{ .pitch = 60, .start_beat = 1.0, .duration_beat = 1.0 },
    );
    app.session.engine.transport.position_frames = 12345; // arbitrary pre-bounce position

    const start_frame: u64 = @intFromFloat(fpb * 1.0);
    var buffer: [256 * engine_mod.channels]types.Sample = undefined;
    commands_mixer.renderBounce(&app, &buffer, start_frame);

    var peak: f32 = 0.0;
    for (buffer) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.001); // note sounds immediately from the note's own start

    try std.testing.expectEqual(@as(u64, 12345), app.session.engine.transport.position_frames);
}

test "pattern-mode transport position readout wraps at the content length" {
    var app = try testApp();
    defer app.deinit();

    const fpb: u64 = @intFromFloat(app.session.engine.transport.framesPerBeat());
    const loop_frames: u64 = @intFromFloat(app.contentBeats() * @as(f64, @floatFromInt(fpb)));

    try std.testing.expectEqual(@as(u64, fpb), app.displayPositionFrames(loop_frames + fpb));
    app.session.song_mode = true;
    try std.testing.expectEqual(loop_frames + fpb, app.displayPositionFrames(loop_frames + fpb));

    app.session.engine.transport.tempo_points[0] = .{ .beat = 0, .bpm = 77 };
    app.session.engine.transport.tempo_point_count = 1;
    app.session.engine.transport.meter_points[0] = .{ .beat = 0, .numerator = 7, .denominator = 8 };
    app.session.engine.transport.meter_point_count = 1;
    const display = app.displayTransport(loop_frames + fpb);
    try std.testing.expectEqual(loop_frames + fpb, display.position_frames);
    try std.testing.expectEqual(@as(f64, 77), display.currentTempo());
    try std.testing.expectEqual(@as(u8, 7), display.currentMeter().numerator);
}

test ":humanize jitters the cursor track's pattern and is undoable" {
    var app = try testApp();
    defer app.deinit();

    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 0.5, .velocity = 0.8 });
    const before = pp.notes[0];

    app.cursor = 0;
    for (":humanize 80") |c| app.handleKey(.{ .char = c }, 100);
    app.handleKey(.enter, 100);

    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    const after = pp.notes[0];
    try std.testing.expect(after.start_beat != before.start_beat or after.velocity != before.velocity);

    app.view = .piano_roll;
    app.piano_track = 0;
    _ = piano_ed.handleKey(&app, .{ .char = 'u' }); // undo the humanize
    try std.testing.expectApproxEqAbs(before.start_beat, pp.notes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(before.velocity, pp.notes[0].velocity, 1e-6);
}

test ":swing sets the cursor track's pattern swing, clamped, and reports with no args" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), pp.swing.load(.monotonic), 1e-6);

    app.cursor = 0;
    for (":swing 62") |c| app.handleKey(.{ .char = c }, 100);
    app.handleKey(.enter, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 62.0), pp.swing.load(.monotonic), 1e-6);

    // Out of range clamps rather than erroring.
    for (":swing 999") |c| app.handleKey(.{ .char = c }, 100);
    app.handleKey(.enter, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 75.0), pp.swing.load(.monotonic), 1e-6);

    app.handleKey(.{ .char = 'u' }, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 62.0), pp.swing.load(.monotonic), 1e-6);
    app.handleKey(.{ .char = 'U' }, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 75.0), pp.swing.load(.monotonic), 1e-6);

    // No args reports the current value without changing it.
    for (":swing") |c| app.handleKey(.{ .char = c }, 100);
    app.handleKey(.enter, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 75.0), pp.swing.load(.monotonic), 1e-6);
}

test "drum and slicer swing nudges are undoable" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.view = .drum_grid;
    _ = drum_ed.handleKey(&app, .{ .char = '>' });
    try std.testing.expectApproxEqAbs(@as(f32, 51), app.drumMachine().swing.load(.monotonic), 1e-6);
    history.doUndo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, 50), app.drumMachine().swing.load(.monotonic), 1e-6);
    history.doRedo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, 51), app.drumMachine().swing.load(.monotonic), 1e-6);

    _ = try app.session.addTrack("slice");
    try app.session.setInstrument(3, .slicer);
    app.slicer_track = 3;
    app.view = .slicer_grid;
    _ = slicer_ed.handleKey(&app, .{ .char = '>' });
    try std.testing.expectApproxEqAbs(@as(f32, 51), app.slicerInst().swing.load(.monotonic), 1e-6);
    history.doUndo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, 50), app.slicerInst().swing.load(.monotonic), 1e-6);
    history.doRedo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, 51), app.slicerInst().swing.load(.monotonic), 1e-6);
}

test ":export-midi then :import-midi round-trips the cursor track's pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try redirectHome(&tmp);

    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .poly_synth);
    app.cursor = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.setNotes(&.{
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 1.0 },
        .{ .pitch = 64, .start_beat = 1.5, .duration_beat = 0.5, .velocity = 0.5 },
    }, 4.0);

    var cmd_buf: [96]u8 = undefined;
    const export_cmd = try std.fmt.bufPrint(&cmd_buf, ":export-midi .zig-cache/tmp/{s}/p.mid", .{&tmp.sub_path});
    for (export_cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    pp.clearNotes(); // prove import repopulates it, not a no-op
    var cmd_buf2: [96]u8 = undefined;
    const import_cmd = try std.fmt.bufPrint(&cmd_buf2, ":import-midi .zig-cache/tmp/{s}/p.mid", .{&tmp.sub_path});
    for (import_cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    try std.testing.expectEqual(@as(u16, 2), pp.note_count);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pp.notes[0].start_beat, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[0].duration_beat, 0.01);
    try std.testing.expectEqual(@as(u7, 64), pp.notes[1].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), pp.notes[1].start_beat, 0.01);
}

test "toggle_mute flips project state and reaches the engine" {
    var app = try testApp();
    defer app.deinit();

    app.applyAction(.toggle_mute, 0);
    try std.testing.expect(app.session.project.tracks.items[0].muted);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.engine.trackAt(0).*.muted);
}

test "toggle_solo flips project state and reaches the engine" {
    var app = try testApp();
    defer app.deinit();

    app.applyAction(.toggle_solo, 0);
    try std.testing.expect(app.session.project.tracks.items[0].soloed);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.engine.trackAt(0).*.soloed);
}

test "r toggles record-arm on the cursor track in the tracks view" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();

    app.cursor = 1;
    app.handleKey(.{ .char = 'r' }, 0);
    try std.testing.expect(app.session.isArmed(1));
    try std.testing.expectStringEndsWith(app.status_buf[0..app.status_len], "armed");
    try std.testing.expect(!app.session.isArmed(0));

    app.handleKey(.{ .char = 'r' }, 0);
    try std.testing.expect(!app.session.isArmed(1));
    try std.testing.expectStringEndsWith(app.status_buf[0..app.status_len], "disarmed");
}

test "finishRecording creates one audio source and region from synthetic capture" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();

    const old_clip_count = app.session.arrangement.lane(1).?.clips.items.len;

    // Same contrived-tempo trick `:load`'s own test uses: 1 frame == 1 beat,
    // so the beats-from-length math stays exact.
    app.session.project.tempo_bpm = @as(f64, @floatFromInt(app.session.project.sample_rate)) * 60.0;
    app.session.toggleArm(1);
    app.recording_active_len = 1;
    app.recording_active_buf[0] = 1;
    try app.recording_accum.appendSlice(app.allocator, &[_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 });
    app.arr_cursor_bar = 2;

    app.finishRecording();

    try std.testing.expectEqual(@as(usize, 0), app.recording_active_len);
    try std.testing.expectEqual(@as(usize, 1), app.session.project.audio_sources.items.len);
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.2, 0.3, 0.4, 0.5 }, app.session.project.audio_sources.items[0].samples);

    const lane = app.session.arrangement.lane(1).?;
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try std.testing.expectEqual(@as(u32, 64), lane.clips.items[0].start_tick);
    try std.testing.expectEqual(@as(u32, 160), lane.clips.items[0].length_ticks);
    const region = lane.clips.items[0].content.audio;
    try std.testing.expectEqual(app.session.project.audio_sources.items[0].id, region.source_id);
    try std.testing.expectEqual(@as(u64, 5), region.source_length_frames);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "recorded 1 take(s)");

    history.doUndo(&app);
    try std.testing.expectEqual(old_clip_count, app.session.arrangement.lane(1).?.clips.items.len);

    history.doRedo(&app);
    try std.testing.expectEqual(@as(usize, 1), app.session.arrangement.lane(1).?.clips.items.len);
    try std.testing.expectEqual(region.source_id, app.session.arrangement.lane(1).?.clips.items[0].content.audio.source_id);

    app.recording_active_len = 1;
    app.recording_active_buf[0] = 1;
    app.recording_accum.clearRetainingCapacity();
    try app.recording_accum.appendSlice(app.allocator, &[_]f32{ 0.6, 0.7, 0.8 });
    app.finishRecording();
    try std.testing.expectEqual(@as(usize, 1), app.session.arrangement.lane(1).?.clips.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.session.arrangement.lane(1).?.clips.items[0].content.audio.takeCount());
    const newest_source = app.session.arrangement.lane(1).?.clips.items[0].content.audio.source_id;
    app.view = .arrangement;
    app.cursor = 1;
    app.arr_cursor_bar = 2;
    commands.run(&app, "take next");
    try std.testing.expectEqual(region.source_id, app.session.arrangement.lane(1).?.clips.items[0].content.audio.source_id);
    history.doUndo(&app);
    try std.testing.expectEqual(newest_source, app.session.arrangement.lane(1).?.clips.items[0].content.audio.source_id);
}

test "finishRecording with no captured audio skips the stamp and reports it" {
    var app = try testApp();
    defer app.deinit();

    app.recording_active_len = 1;
    app.recording_active_buf[0] = 1;
    app.finishRecording();

    try std.testing.expectEqual(@as(usize, 0), app.recording_active_len);
    try std.testing.expect(!app.session.racks.items[1].instrument.sampler.pad.user_sample);
    try std.testing.expectEqualStrings("no audio captured", app.status_buf[0..app.status_len]);
}

test ":unmute clears every track's mute in one shot; :unsolo clears solo" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();

    app.applyAction(.toggle_mute, 0);
    app.cursor = 2;
    app.applyAction(.toggle_mute, 0);
    try std.testing.expect(app.session.project.tracks.items[0].muted);
    try std.testing.expect(app.session.project.tracks.items[2].muted);

    commands.run(&app, "unmute");
    try std.testing.expect(!app.session.project.tracks.items[0].muted);
    try std.testing.expect(!app.session.project.tracks.items[2].muted);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(!app.session.engine.trackAt(0).*.muted);
    try std.testing.expect(!app.session.engine.trackAt(2).*.muted);

    app.cursor = 1;
    app.applyAction(.toggle_solo, 0);
    try std.testing.expect(app.session.project.tracks.items[1].soloed);

    commands.run(&app, "unsolo");
    try std.testing.expect(!app.session.project.tracks.items[1].soloed);

    // A no-op run reports rather than silently doing nothing.
    commands.run(&app, "unmute");
    try std.testing.expectEqualStrings("unmute: nothing was muted", app.status_buf[0..app.status_len]);
}

test "notes route to a synth track and queue their own release" {
    var app = try testApp();
    defer app.deinit();

    // cursor 0 is a synth → note plays and schedules a release.
    app.applyAction(.{ .note = .{ .pitch = 60 } }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);

    app.tick(note_ms * std.time.ns_per_ms / 2);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
    app.tick(note_ms * std.time.ns_per_ms + 1);
    try std.testing.expectEqual(@as(usize, 0), app.note_off_len);
}

test "notes on a sampler track schedule a release too" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 1; // sampler
    app.applyAction(.{ .note = .{ .pitch = 67 } }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
}

test "typed :q quits via the modal layer" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.should_quit);
}

test "enter on a drum track opens its pad panel, p opens the step grid" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 2; // drum machine
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expectEqual(@as(u16, 2), app.sampler_target.drum);
    try std.testing.expectEqual(@as(u16, 2), app.drum_track);

    // Opened from the tracks view, so esc goes back there - not to the grid.
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);

    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
    try std.testing.expectEqual(@as(u16, 2), app.drum_track);

    // e from the grid reopens the panel, and esc returns to the grid.
    app.handleKey(.{ .char = 'e' }, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
}

test "slicer grid: slice, step toggle, play triggers the right slice" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    try installSlicerTestClip(&app);

    commands.run(&app, "slice 8");
    try std.testing.expectEqual(@as(u8, 8), app.slicerInst().slice_count);
    for (app.slicerInst().slices[0..8]) |slice| {
        try std.testing.expectEqual(ws.dsp.pad.PlayMode.retrigger, ws.dsp.pad.playMode(&slice));
    }

    app.slicer_cursor = .{ 3, 0 };
    _ = slicer_ed.handleKey(&app, .enter);
    try std.testing.expect(app.slicerInst().stepActive(3, 0));
    // x clears (vim char-delete, drum-grid parity) - never re-toggles on.
    _ = slicer_ed.handleKey(&app, .{ .char = 'x' });
    try std.testing.expect(!app.slicerInst().stepActive(3, 0));
    _ = slicer_ed.handleKey(&app, .{ .char = 'x' });
    try std.testing.expect(!app.slicerInst().stepActive(3, 0));

    // Re-arm it and confirm the sequencer actually fires that slice on play.
    _ = slicer_ed.handleKey(&app, .enter);
    _ = app.session.engine.send(.play);
    var block: [512]types.Sample = undefined;
    app.session.engine.process(&block);
    var peak: f32 = 0.0;
    for (block) |v| peak = @max(peak, @abs(v));
    try std.testing.expect(peak > 0.001);
}

test "bpm-sync warps a slicer for tempo and spends its pitch on the project key" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.cursor = 0;
    try installSlicerTestClip(&app);
    app.session.project.tempo_bpm = 85.0;
    app.session.project.scale = .{ .root = 4, .kind = .minor }; // E minor

    const sl = app.slicerInst();
    sl.sliceInto(4);
    // What `Slicer.loadWav` reads out of "SO_JAM_80_bass_upright_onyx_Gmin"
    // (the parsers themselves are covered in dsp/tempo.zig and dsp/pitch.zig).
    sl.clip_bpm = 80.0;
    sl.clip_root = 7; // G

    commands.run(&app, "bpm-sync");

    for (sl.slices[0..sl.slice_count]) |slice| {
        // Tempo rides the warp: an 80 BPM loop in an 85 BPM project has to
        // play 80/85 as long.
        try std.testing.expectApproxEqAbs(@as(f32, 80.0 / 85.0), slice.stretch_ratio, 1e-4);
        // ...which leaves pitch free for the key. G to E is three semitones
        // down, the short way round.
        try std.testing.expectApproxEqAbs(@as(f32, -3.0), slice.pitch_semitones, 1e-4);
    }
}

test "slicer grid rows start where the mouse hit-test looks for them" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    try installSlicerTestClip(&app);
    commands.run(&app, "slice 8");

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try @import("render.zig").drawSlicerGrid(&app, &w, 40, 100, app.session.engine.uiSnapshot());
    const frame = w.buffered();

    // The clip's waveform belongs to the slice panel now, not over the grid.
    try std.testing.expect(std.mem.indexOf(u8, frame, "\u{2588}") == null);

    // Title, bar ruler, then slice #1 - handleMouse maps a click row back to
    // a slice with that same offset (`slicer_ed.grid_top`), so a drift here
    // silently edits the wrong row.
    var lines = std.mem.splitScalar(u8, frame, '\n');
    var row: usize = 0;
    while (lines.next()) |line| : (row += 1) {
        if (std.mem.indexOf(u8, line, "#1") != null) break;
    }
    try std.testing.expectEqual(slicer_ed.grid_top, row);
}

test "slicer grid: a click past the 256th step lands on it instead of panicking" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    try installSlicerTestClip(&app);
    commands.run(&app, "slice 8");
    app.slicerInst().setStepCount(512);

    // Drawing scrolls the step window onto the cursor, so the leftmost
    // visible column is well past a u8's ceiling - which is exactly what the
    // hit-test used to narrow the step index to.
    app.slicer_cursor = .{ 0, 300 };
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try @import("render.zig").drawSlicerGrid(&app, &w, 40, 100, app.session.engine.uiSnapshot());
    try std.testing.expect(app.slicer_step_scroll > 255);

    // x = gutter + 1 clears the beat separator, landing on the first visible
    // cell; the click has to toggle that step, not a wrapped-around one.
    const first_visible: u16 = @intCast(app.slicer_step_scroll);
    app.handleMouse(.{
        .x = slicer_ed.gutter + 1,
        .y = app_mod.content_top + slicer_ed.grid_top,
        .button = .left,
        .kind = .press,
    }, 100, 40, 0);
    try std.testing.expectEqual(first_visible, app.slicer_cursor[1]);
    try std.testing.expect(app.slicerInst().stepActive(0, first_visible));
}

test "slicer grid: navigation and per-slice param nudges stay within bounds" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(4);

    app.slicer_cursor = .{ 0, 0 };
    _ = slicer_ed.handleKey(&app, .{ .char = 'j' });
    try std.testing.expectEqual(@as(u8, 1), app.slicer_cursor[0]);
    _ = slicer_ed.handleKey(&app, .{ .char = 'J' }); // bank jump, clamped to slice_count-1
    try std.testing.expectEqual(@as(u8, 3), app.slicer_cursor[0]);

    // Boundary/reverse nudges ride the command queue (like every other
    // instrument param), so they land when the engine processes a block.
    const start_before = app.slicerInst().slices[3].start_norm;
    _ = slicer_ed.handleKey(&app, .{ .char = ')' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'r' });
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.slicerInst().slices[3].start_norm > start_before);
    try std.testing.expect(app.slicerInst().slices[3].reverse);
}

test "slicer grid: q/Q chop shortcuts and A switches playback mode" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;

    commands.run(&app, "slice 8");
    for ("qQA") |c| _ = slicer_ed.handleKey(&app, .{ .char = c });
    try std.testing.expectEqual(@as(u8, 0), app.slicerInst().slice_count);
    try std.testing.expect(!app.dirty);

    try installSlicerTestClip(&app);

    _ = slicer_ed.handleKey(&app, .{ .char = 'Q' });
    try std.testing.expectEqual(@as(u8, 8), app.slicerInst().slice_count);
    // A fresh chop is retrigger; A walks the cycle on to one-shot.
    _ = slicer_ed.handleKey(&app, .{ .char = 'A' });
    for (app.slicerInst().slices[0..8]) |slice| {
        try std.testing.expectEqual(ws.dsp.pad.PlayMode.one_shot, ws.dsp.pad.playMode(&slice));
    }
    _ = slicer_ed.handleKey(&app, .{ .char = 'q' });
    try std.testing.expectEqual(@as(u8, 1), app.slicerInst().slice_count);
    try std.testing.expectEqual(ws.dsp.pad.PlayMode.retrigger, ws.dsp.pad.playMode(&app.slicerInst().slices[0]));
}

test "slicer grid: velocity cycle + fine nudge on an active step only" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(2);
    app.slicer_cursor = .{ 0, 0 };

    // No step yet: cv and _ refuse rather than editing a phantom step.
    _ = slicer_ed.handleKey(&app, .{ .char = 'c' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'v' });
    try std.testing.expectEqual(@as(u8, 127), app.slicerInst().stepVel(0, 0));

    _ = slicer_ed.handleKey(&app, .enter);
    _ = slicer_ed.handleKey(&app, .{ .char = 'c' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'v' });
    try std.testing.expectEqual(@as(u8, 95), app.slicerInst().stepVel(0, 0));
    _ = slicer_ed.handleKey(&app, .{ .char = '_' });
    try std.testing.expectEqual(@as(u8, 94), app.slicerInst().stepVel(0, 0));
    _ = slicer_ed.handleKey(&app, .{ .char = '=' });
    try std.testing.expectEqual(@as(u8, 95), app.slicerInst().stepVel(0, 0));
}

test "slicer grid: parameter locks, per-slice loop, and grid zoom" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(2);
    app.slicer_cursor = .{ 0, 4 };

    // Every lock needs a hit under the cursor, same refusal as cv/_.
    for ([_]u8{ '%', '&', 't', ';' }) |k| _ = slicer_ed.handleKey(&app, .{ .char = k });
    _ = slicer_ed.handleKey(&app, .{ .char = 'c' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'r' });
    try std.testing.expectEqual(@as(u8, 100), app.slicerInst().stepProb(0, 4));
    try std.testing.expectEqual(@as(i8, 0), app.slicerInst().stepTune(0, 4));

    _ = slicer_ed.handleKey(&app, .enter);
    _ = slicer_ed.handleKey(&app, .{ .char = '%' });
    _ = slicer_ed.handleKey(&app, .{ .char = '&' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'c' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'r' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'T' });
    _ = slicer_ed.handleKey(&app, .{ .char = '\'' });
    const sl = app.slicerInst();
    try std.testing.expect(sl.stepProb(0, 4) != 100);
    try std.testing.expect(sl.stepCond(0, 4) != .always);
    try std.testing.expect(sl.stepRetrig(0, 4) >= 2);
    try std.testing.expectEqual(@as(i8, 1), sl.stepTune(0, 4));
    try std.testing.expectEqual(@as(i8, 1), sl.stepMicro(0, 4));
    // ! is machine-wide, not per step.
    _ = slicer_ed.handleKey(&app, .{ .char = '!' });
    try std.testing.expect(sl.fill_on.load(.monotonic));

    // $ loops the row over cursor+1 steps; pressed again there it reverts.
    _ = slicer_ed.handleKey(&app, .{ .char = '$' });
    try std.testing.expectEqual(@as(u16, 5), sl.sliceSteps(0, sl.step_count));
    try std.testing.expectEqual(sl.step_count, sl.sliceSteps(1, sl.step_count));
    _ = slicer_ed.handleKey(&app, .{ .char = '$' });
    try std.testing.expectEqual(@as(u16, 0), sl.slice_len[0]);
    _ = slicer_ed.handleKey(&app, .{ .char = '$' });
    // The length is content, so it rides the undo stack like a step does.
    history.doUndo(&app);
    try std.testing.expectEqual(@as(u16, 0), sl.slice_len[0]);
    history.doRedo(&app);
    try std.testing.expectEqual(@as(u16, 5), sl.slice_len[0]);

    // zg halves the grid: same music, twice the steps, and the hit and the
    // row's own loop length both move with it.
    const steps_before = sl.step_count;
    _ = slicer_ed.handleKey(&app, .{ .char = 'z' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'g' });
    try std.testing.expectEqual(@as(u8, 8), sl.steps_per_beat);
    try std.testing.expectEqual(steps_before * 2, sl.step_count);
    const info = app.apiPatternInfo(0);
    try std.testing.expectEqual(@as(?u8, 8), info.steps_per_beat);
    try std.testing.expectEqual(@as(f64, 4.0), info.length_beats);
    try std.testing.expect(sl.stepActive(0, 8));
    try std.testing.expectEqual(@as(u16, 10), sl.sliceSteps(0, sl.step_count));
    _ = slicer_ed.handleKey(&app, .{ .char = 'z' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'G' });
    try std.testing.expectEqual(@as(u8, 4), sl.steps_per_beat);
    try std.testing.expectEqual(steps_before, sl.step_count);
    try std.testing.expect(sl.stepActive(0, 4));
    try std.testing.expectEqual(@as(u16, 5), sl.sliceSteps(0, sl.step_count));

    // Undo unwinds the locks one entry at a time, back to a bare hit.
    while (app.history.undo_stack.items.len > 0) history.doUndo(&app);
    try std.testing.expectEqual(@as(u8, 100), app.slicerInst().stepProb(0, 4));
    try std.testing.expectEqual(@as(i8, 0), app.slicerInst().stepTune(0, 4));
}

test "slicer grid: advancing entry, pattern double, and source-order sequence" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(4);
    app.slicerInst().setStepCount(8);

    app.slicer_cursor = .{ 2, 1 };
    app.modal.count = 3;
    _ = slicer_ed.handleKey(&app, .{ .char = 'n' });
    try std.testing.expect(app.slicerInst().stepActive(2, 1));
    try std.testing.expectEqual(@as(u8, 4), app.slicer_cursor[1]);

    app.slicerInst().setStepVel(2, 1, 63);
    _ = slicer_ed.handleKey(&app, .{ .char = 'E' });
    try std.testing.expectEqual(@as(u8, 16), app.slicerInst().step_count);
    try std.testing.expect(app.slicerInst().stepActive(2, 9));
    try std.testing.expectEqual(@as(u8, 63), app.slicerInst().stepVel(2, 9));

    _ = slicer_ed.handleKey(&app, .{ .char = 'O' });
    for (0..4) |idx| try std.testing.expect(app.slicerInst().stepActive(@intCast(idx), @intCast(idx)));
    try std.testing.expect(!app.slicerInst().stepActive(2, 9));
    _ = slicer_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expect(app.slicerInst().stepActive(2, 9));
}

test "slicer grid: undo restores steps AND chop layout through one stack" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    try installSlicerTestClip(&app);
    commands.run(&app, "slice 4");
    app.slicer_cursor = .{ 1, 3 };
    _ = slicer_ed.handleKey(&app, .enter); // step on
    try std.testing.expect(app.slicerInst().stepActive(1, 3));

    commands.run(&app, "slice 8"); // re-chop over the programmed pattern
    try std.testing.expectEqual(@as(u8, 8), app.slicerInst().slice_count);

    app.slicer_cursor[0] = 7;
    commands.run(&app, "slice 4");
    try std.testing.expectEqual(@as(u8, 3), app.slicer_cursor[0]);
    _ = slicer_ed.handleKey(&app, .{ .char = 'u' });

    _ = slicer_ed.handleKey(&app, .{ .char = 'u' }); // undo the re-chop
    try std.testing.expectEqual(@as(u8, 4), app.slicerInst().slice_count);
    try std.testing.expect(app.slicerInst().stepActive(1, 3));

    _ = slicer_ed.handleKey(&app, .{ .char = 'u' }); // undo the step
    try std.testing.expect(!app.slicerInst().stepActive(1, 3));

    _ = slicer_ed.handleKey(&app, .{ .char = 'U' }); // redo the step
    try std.testing.expect(app.slicerInst().stepActive(1, 3));
}

test "opening a shorter slicer clamps stale slice selection" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    try app.session.setInstrument(1, .slicer);
    app.session.racks.items[0].instrument.slicer.sliceInto(8);
    app.session.racks.items[1].instrument.slicer.sliceInto(2);
    app.slicer_cursor[0] = 7;
    app.cursor = 1;
    app.view = .tracks;

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expectEqual(@as(u8, 1), app.slicer_cursor[0]);

    app.handleKey(.escape, 0);
    app.slicer_cursor[0] = 7;
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.slicer_grid, app.view);
    try std.testing.expectEqual(@as(u8, 1), app.slicer_cursor[0]);
}

test "slicer grid: split shifts programming down, merge folds it back" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(2);
    app.slicerInst().toggleStep(1, 6);

    app.slicer_cursor = .{ 0, 0 };
    _ = slicer_ed.handleKey(&app, .{ .char = 's' });
    try std.testing.expectEqual(@as(u8, 3), app.slicerInst().slice_count);
    try std.testing.expect(app.slicerInst().stepActive(2, 6)); // followed its slice down

    _ = slicer_ed.handleKey(&app, .{ .char = 'm' });
    try std.testing.expectEqual(@as(u8, 2), app.slicerInst().slice_count);
    try std.testing.expect(app.slicerInst().stepActive(1, 6)); // and back up

    // Both are one undo step each.
    _ = slicer_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectEqual(@as(u8, 3), app.slicerInst().slice_count);
}

test "slicer grid: visual-line range yank/paste and dot-repeat" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(2);
    app.slicerInst().toggleStep(0, 0);
    app.slicerInst().toggleStep(1, 1);

    // V + l + y: yank steps 0-1 across all slices (linewise - `v` would
    // bound the selection to the cursor slice).
    app.slicer_cursor = .{ 0, 0 };
    _ = slicer_ed.handleKey(&app, .{ .char = 'V' });
    try std.testing.expectEqual(modal_mod.Mode.visual, app.modal.mode);
    _ = slicer_ed.handleKey(&app, .{ .char = 'l' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'y' });
    try std.testing.expectEqual(modal_mod.Mode.normal, app.modal.mode);

    // p at step 4 reproduces both hits, offset.
    app.slicer_cursor = .{ 0, 4 };
    _ = slicer_ed.handleKey(&app, .{ .char = 'p' });
    try std.testing.expect(app.slicerInst().stepActive(0, 4));
    try std.testing.expect(app.slicerInst().stepActive(1, 5));

    // . repeats the paste at a new cursor.
    app.slicer_cursor = .{ 0, 8 };
    _ = slicer_ed.handleKey(&app, .{ .char = '.' });
    try std.testing.expect(app.slicerInst().stepActive(0, 8));
    try std.testing.expect(app.slicerInst().stepActive(1, 9));
}

test "slicer grid: e opens the sampler editor on the cursor slice and returns" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(4);
    app.slicer_cursor = .{ 2, 0 };

    _ = slicer_ed.handleKey(&app, .{ .char = 'e' });
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expect(app.sampler_target == .slice);

    // h/l nudges route to the addressed slice's params via the queue.
    app.sampler_param = 2; // pitch
    _ = sampler_ed.handleKey(&app, .{ .char = 'l' });
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.slicerInst().slices[2].pitch_semitones > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), app.slicerInst().slices[0].pitch_semitones, 1e-6);

    _ = sampler_ed.handleKey(&app, .escape);
    try std.testing.expectEqual(AppView.slicer_grid, app.view);
}

test "slicer grid: variant bank keys [ ] N D, undoable as one stack" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(4);
    app.slicer_cursor = .{ 0, 0 };
    _ = slicer_ed.handleKey(&app, .enter); // A: slice 0 step 0

    _ = slicer_ed.handleKey(&app, .{ .char = 'N' }); // B = copy, active
    try std.testing.expectEqual(@as(u8, 2), app.slicerInst().variant_count);
    _ = slicer_ed.handleKey(&app, .{ .char = 'x' }); // B diverges: clear the step
    try std.testing.expect(!app.slicerInst().stepActive(0, 0));

    _ = slicer_ed.handleKey(&app, .{ .char = '[' }); // back to A
    try std.testing.expectEqual(@as(u8, 0), app.slicerInst().variant);
    try std.testing.expect(app.slicerInst().stepActive(0, 0));
    _ = slicer_ed.handleKey(&app, .{ .char = ']' }); // forward to B
    try std.testing.expect(!app.slicerInst().stepActive(0, 0));

    _ = slicer_ed.handleKey(&app, .{ .char = 'D' }); // delete B
    try std.testing.expectEqual(@as(u8, 1), app.slicerInst().variant_count);
    _ = slicer_ed.handleKey(&app, .{ .char = 'u' }); // undo restores the bank
    try std.testing.expectEqual(@as(u8, 2), app.slicerInst().variant_count);
}

test "slicer grid: C cycles the cursor slice's choke group" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(2);
    // sliceInto's mono-chop default already puts every slice in group 1.
    app.slicer_cursor = .{ 1, 0 };
    _ = slicer_ed.handleKey(&app, .{ .char = 'C' });
    try std.testing.expectEqual(@as(u8, 2), app.slicerInst().choke_group[1]);
    try std.testing.expectEqual(@as(u8, 1), app.slicerInst().choke_group[0]);
}

test "arrangement: slicer lane stamps a clip and song mode plays it" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    try installSlicerTestClip(&app);
    app.slicerInst().sliceInto(4);
    app.slicerInst().toggleStep(2, 0);

    // enter in the arrangement stamps the live pattern at the cursor bar.
    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    app.handleKey(.enter, 0);
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try std.testing.expect(lane.clips.items[0].content == .drum);

    // Song mode: the clip fires slice 2; audio comes out.
    app.session.setSongMode(true);
    try std.testing.expect(app.slicerInst().song_mode);
    try std.testing.expectEqual(@as(u16, 1), app.slicerInst().song_clip_count);
    _ = app.session.engine.send(.play);
    var block: [512]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.slicerInst().voices[2][0].active);

    // The stamp is undoable as a lane edit.
    app.session.setSongMode(false);
    app.view = .slicer_grid;
    _ = slicer_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectEqual(@as(usize, 0), lane.clips.items.len);
}

test ":chop finds transients in the default clip or reports none" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    try installSlicerTestClip(&app);

    // Whatever the clip turns out to hold, chop must not crash and must leave
    // a valid (>= 1) slicing either way, undoable.
    const before = app.slicerInst().slice_count;
    commands.run(&app, "chop");
    try std.testing.expect(app.slicerInst().slice_count >= 1);
    _ = slicer_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectEqual(before, app.slicerInst().slice_count);

    commands.run(&app, "chop 99");
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "usage") != null);
}

test "drum grid step toggle" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;

    try std.testing.expect(!app.drumMachine().stepActive(0, 0));
    app.drum_cursor = .{ 0, 0 };
    _ = drum_ed.handleKey(&app, .enter);
    try std.testing.expect(app.drumMachine().stepActive(0, 0));
    // The first enter also starts a velocity-stamp session; a second enter
    // drops it (keeping the step active) instead of toggling it back off.
    _ = drum_ed.handleKey(&app, .enter);
    try std.testing.expect(app.drumMachine().stepActive(0, 0));
    try std.testing.expect(!app.drum_stamp);
    // A third enter, with the session already dropped, toggles it off.
    _ = drum_ed.handleKey(&app, .enter);
    try std.testing.expect(!app.drumMachine().stepActive(0, 0));
}

test "drum grid enter activating a step starts a stamp session - j/k velocity" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.drum_cursor = .{ 0, 0 };

    _ = drum_ed.handleKey(&app, .enter); // activate the step and start stamping
    try std.testing.expect(app.drum_stamp);
    try std.testing.expect(app.drumMachine().stepActive(0, 0));
    try std.testing.expectEqual(@as(u8, ws.dsp.DrumMachine.vel_full), app.drumMachine().stepVel(0, 0));

    _ = drum_ed.handleKey(&app, .{ .char = 'j' }); // nudge velocity down
    try std.testing.expectEqual(@as(u8, ws.dsp.DrumMachine.vel_full - 1), app.drumMachine().stepVel(0, 0));
    _ = drum_ed.handleKey(&app, .{ .char = 'j' });
    try std.testing.expectEqual(@as(u8, ws.dsp.DrumMachine.vel_full - 2), app.drumMachine().stepVel(0, 0));
    _ = drum_ed.handleKey(&app, .{ .char = 'k' }); // and back up
    try std.testing.expectEqual(@as(u8, ws.dsp.DrumMachine.vel_full - 1), app.drumMachine().stepVel(0, 0));

    // Escape drops the session without deactivating the step.
    _ = drum_ed.handleKey(&app, .escape);
    try std.testing.expect(!app.drum_stamp);
    try std.testing.expect(app.drumMachine().stepActive(0, 0));
    try std.testing.expectEqual(@as(u8, ws.dsp.DrumMachine.vel_full - 1), app.drumMachine().stepVel(0, 0));
}

test "drum grid enter release drops the stamp session (hold-to-shape)" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.drum_cursor = .{ 0, 0 };

    // A quick tap: press arms the session, key-up drops it immediately -
    // no lingering mode, j afterwards is pad navigation again.
    _ = drum_ed.handleKey(&app, .enter);
    try std.testing.expect(app.drum_stamp);
    _ = drum_ed.handleKey(&app, .enter_release);
    try std.testing.expect(!app.drum_stamp);
    try std.testing.expect(app.drumMachine().stepActive(0, 0));
    _ = drum_ed.handleKey(&app, .{ .char = 'j' });
    try std.testing.expectEqual(@as(u8, ws.dsp.DrumMachine.vel_full), app.drumMachine().stepVel(0, 0));
    try std.testing.expectEqual(@as(u8, 1), app.drum_cursor[0]);

    // A release with no session active is inert.
    _ = drum_ed.handleKey(&app, .enter_release);
    try std.testing.expect(app.drumMachine().stepActive(0, 0));
}

test "drum grid advancing entry and pattern double preserve velocity" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.drumMachine().setStepCount(8);
    app.drum_cursor = .{ 1, 0 };

    app.modal.count = 4;
    _ = drum_ed.handleKey(&app, .{ .char = 'n' });
    try std.testing.expect(app.drumMachine().stepActive(1, 0));
    try std.testing.expectEqual(@as(u8, 4), app.drum_cursor[1]);

    app.drumMachine().setStepVel(1, 0, 95);
    _ = drum_ed.handleKey(&app, .{ .char = 'E' });
    try std.testing.expectEqual(@as(u8, 16), app.drumMachine().step_count);
    try std.testing.expect(app.drumMachine().stepActive(1, 8));
    try std.testing.expectEqual(@as(u8, 95), app.drumMachine().stepVel(1, 8));

    _ = drum_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectEqual(@as(u8, 8), app.drumMachine().step_count);
    try std.testing.expect(!app.drumMachine().stepActive(1, 8));
}

test "z and Z select drum grid subdivisions" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;

    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.drum_grid);
    _ = drum_ed.handleKey(&app, .{ .char = 'z' });
    _ = drum_ed.handleKey(&app, .{ .char = 'G' });
    try std.testing.expectEqual(ws.time_grid.Division.eighth, app.drum_grid);
    _ = drum_ed.handleKey(&app, .{ .char = 'z' });
    _ = drum_ed.handleKey(&app, .{ .char = 'g' });
    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.drum_grid);
    _ = drum_ed.handleKey(&app, .{ .char = 'z' });
    _ = drum_ed.handleKey(&app, .{ .char = 'g' });
    try std.testing.expectEqual(ws.time_grid.Division.thirty_second, app.drum_grid);
}

test "drum grid +/- resize the loop by a beat at the current resolution" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.view = .drum_grid;
    app.drum_cursor = .{ 0, 0 };
    const dm = app.drumMachine();
    const start = dm.step_count;

    app.handleKey(.{ .char = '+' }, 0);
    try std.testing.expectEqual(start + 4, dm.step_count);
    app.handleKey(.{ .char = '-' }, 0);
    try std.testing.expectEqual(start, dm.step_count);

    // A count prefix scales the resize by whole beats too.
    for ("2+") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(start + 8, dm.step_count);

    dm.setStepCount(start);
    app.handleKey(.{ .char = 'z' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    const zoomed = dm.step_count;
    app.handleKey(.{ .char = '+' }, 0);
    try std.testing.expectEqual(zoomed + dm.steps_per_beat, dm.step_count);
}

test "slicer grid +/- resize the loop by a beat at the current resolution" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicer_cursor = .{ 0, 0 };
    const sl = app.slicerInst();
    const start = sl.step_count;

    app.handleKey(.{ .char = '+' }, 0);
    try std.testing.expectEqual(start + 4, sl.step_count);
    app.handleKey(.{ .char = '-' }, 0);
    try std.testing.expectEqual(start, sl.step_count);

    // A count prefix scales the resize by whole beats too.
    for ("2+") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(start + 8, sl.step_count);

    sl.setStepCount(start);
    app.handleKey(.{ .char = 'z' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    const zoomed = sl.step_count;
    app.handleKey(.{ .char = '+' }, 0);
    try std.testing.expectEqual(zoomed + sl.steps_per_beat, sl.step_count);
}

test "drum grid m/M set a pad's own loop length, undoably, and rescale on zoom" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.view = .drum_grid;
    app.drum_cursor = .{ 0, 0 };
    const dm = app.drumMachine();
    const steps = dm.step_count;

    app.handleKey(.{ .char = 'm' }, 0); // down from "follows the pattern"
    try std.testing.expectEqual(steps - 1, dm.padSteps(0, steps));
    try std.testing.expectEqual(steps, dm.padSteps(1, steps)); // other rows untouched
    history.doUndo(&app);
    try std.testing.expectEqual(@as(u16, 0), dm.pad_len[0]);
    history.doRedo(&app);
    try std.testing.expectEqual(steps - 1, dm.pad_len[0]);

    // A grid change preserves musical time, loop length included.
    app.handleKey(.{ .char = 'z' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    try std.testing.expectEqual((steps - 1) * 2, dm.pad_len[0]);
}

test "drum grid Z refuses to coarsen the grid when it would collide two hits" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    const dm = app.drumMachine();

    // Adjacent steps 1 and 2 (sixteenth-note grid) both round onto new
    // step 1 when halving resolution to eighth notes.
    step_grid.setStep(dm, 0, 1, true, ws.dsp.DrumMachine.vel_full);
    step_grid.setStep(dm, 0, 2, true, ws.dsp.DrumMachine.vel_full);
    const before_count = app.history.undo_stack.items.len;

    _ = drum_ed.handleKey(&app, .{ .char = 'z' });
    _ = drum_ed.handleKey(&app, .{ .char = 'G' });

    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.drum_grid);
    try std.testing.expect(dm.stepActive(0, 1));
    try std.testing.expect(dm.stepActive(0, 2));
    try std.testing.expectEqual(before_count, app.history.undo_stack.items.len);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "grid 1/8 would collide");
}

test "drum grid g jumps the step cursor to the pattern start" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.drum_cursor = .{ 0, 5 };

    _ = drum_ed.handleKey(&app, .{ .char = 'g' });
    _ = drum_ed.handleKey(&app, .{ .char = 'g' });
    try std.testing.expectEqual(@as(u8, 0), app.drum_cursor[1]);
    // Pad cursor is untouched by 'g'.
    try std.testing.expectEqual(@as(u8, 0), app.drum_cursor[0]);
}

test "drum grid G jumps the step cursor to the pattern end; C cycles choke group" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.drum_cursor = .{ 0, 0 };

    _ = drum_ed.handleKey(&app, .{ .char = 'g' });
    _ = drum_ed.handleKey(&app, .{ .char = 'G' });
    try std.testing.expectEqual(app.drumMachine().step_count - 1, app.drum_cursor[1]);

    try std.testing.expectEqual(@as(u8, 0), app.drumMachine().choke_group[0]);
    _ = drum_ed.handleKey(&app, .{ .char = 'C' });
    try std.testing.expectEqual(@as(u8, 1), app.drumMachine().choke_group[0]);
}

test ":ghost overlays another melodic track's notes, dimmed, only when on" {
    var app = try testApp();
    defer app.deinit();

    // Track 0 (synth) gets a note; view track 1's (sampler) roll instead.
    app.session.racks.items[0].pattern_player.?.addNote(
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 },
    );
    app.view = .piano_roll;
    app.piano_track = 1;
    app.piano_scroll_pitch = @intCast(@min(@as(u32, 60) + 8, 127));
    // Move the cursor off the ghost note's own cell (pitch 60, step 0) so its
    // reverse-video cursor rendering doesn't mask the ghost glyph underneath.
    app.piano_cursor_pitch = 72;
    app.piano_cursor_step = 4;

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 30 });
    const off_output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, off_output, style.dim ++ "[") == null);

    app.piano_ghost = true;
    var buf2: [32 * 1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try tui_mod.draw(&app, &w2, .{ .cols = 100, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), style.dim ++ "[") != null);
}

test "arrangement view colors a lane and its clips with the track's color" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();
    app.session.racks.items[0].pattern_player.?.addNote(
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 },
    );
    try app.session.stampClip(0, 2); // clip off the cursor lane, unselected
    app.view = .arrangement;
    app.cursor = 1; // select a different lane so track 0's row isn't reverse-video

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 30 });
    // Uncolored (default): the clip cell still wears the generic accent.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), style.acc) != null);

    app.session.project.tracks.items[0].color = 1; // red, index 0 of the palette
    var buf2: [32 * 1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try tui_mod.draw(&app, &w2, .{ .cols = 100, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), style.red) != null);
}

test "piano roll yank/paste moves a pattern across tracks" {
    var app = try testApp();
    defer app.deinit();

    // Track 0 (synth): one note, 8-beat loop. Yank it.
    app.piano_track = 0;
    const src = &app.session.racks.items[0].pattern_player.?;
    src.addNote(.{ .pitch = 72, .start_beat = 1.0, .duration_beat = 0.5 });
    src.length_beats = 8.0;
    _ = piano_ed.handleKey(&app, .{ .char = 'y' }); // y is an operator now; yy yanks the whole pattern
    _ = piano_ed.handleKey(&app, .{ .char = 'y' });

    // Paste replaces track 1's (sampler) pattern wholesale.
    app.piano_track = 1;
    const dst = &app.session.racks.items[1].pattern_player.?;
    dst.addNote(.{ .pitch = 30, .start_beat = 0.0, .duration_beat = 1.0 });
    _ = piano_ed.handleKey(&app, .{ .char = 'P' });
    try std.testing.expectEqual(@as(u16, 1), dst.note_count);
    try std.testing.expectEqual(@as(u7, 72), dst.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), dst.length_beats, 1e-9);
}

test "piano roll lowercase p pastes too (vim's canonical paste key)" {
    var app = try testApp();
    defer app.deinit();

    app.piano_track = 0;
    const src = &app.session.racks.items[0].pattern_player.?;
    src.addNote(.{ .pitch = 72, .start_beat = 0.0, .duration_beat = 0.5 });
    _ = piano_ed.handleKey(&app, .{ .char = 'y' }); // yy yanks the whole pattern
    _ = piano_ed.handleKey(&app, .{ .char = 'y' });

    app.piano_track = 1;
    const dst = &app.session.racks.items[1].pattern_player.?;
    _ = piano_ed.handleKey(&app, .{ .char = 'p' });
    try std.testing.expectEqual(@as(u16, 1), dst.note_count);
    try std.testing.expectEqual(@as(u7, 72), dst.notes[0].pitch);
}

test "drum grid lowercase p pastes the yanked pattern too" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.drum_cursor = .{ 0, 0 };
    _ = drum_ed.handleKey(&app, .enter); // activate pad 0 step 0 before yanking

    _ = drum_ed.handleKey(&app, .{ .char = 'y' }); // yy yanks the whole pattern
    _ = drum_ed.handleKey(&app, .{ .char = 'y' });
    try std.testing.expect(app.drum_clip != null);

    app.drumMachine().clearPad(0);
    try std.testing.expect(!app.drumMachine().stepActive(0, 0));
    _ = drum_ed.handleKey(&app, .{ .char = 'p' });
    try std.testing.expect(app.drumMachine().stepActive(0, 0));
}

test "piano roll visual mode selects a step range for y/d/P" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 8.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 }); // step 0
    pp.addNote(.{ .pitch = 64, .start_beat = 0.25, .duration_beat = 0.25 }); // step 1
    pp.addNote(.{ .pitch = 72, .start_beat = 2.0, .duration_beat = 0.25 }); // step 8, outside the selection

    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'V' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0); // extend the selection to step 3

    app.handleKey(.{ .char = 'y' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 2), app.piano_range_clip.?.count);

    // Paste at step 8: P is a visual-mode action, so re-enter visual first
    // (v establishes the cursor as the paste point; no need to extend it).
    app.piano_cursor_step = 8;
    app.handleKey(.{ .char = 'V' }, 0);
    app.handleKey(.{ .char = 'P' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 5), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 2.0) != null);
    try std.testing.expect(pp.noteAt(64, 2.25) != null);

    // Select the same range again and delete it - only the untouched note remains.
    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'V' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 3), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expect(pp.noteAt(72, 2.0) != null);
}

test "piano roll chord stamp: bare cc is root position, a count prefix inverts" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 4.0;
    app.piano_cursor_pitch = 60;
    app.piano_cursor_step = 0;

    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'c' }, 0);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);
    try std.testing.expect(pp.noteAt(64, 0.0) != null);
    try std.testing.expect(pp.noteAt(67, 0.0) != null);

    // 2cc: root and third an octave up, fifth left where it is.
    app.piano_cursor_step = 4;
    app.handleKey(.{ .char = '2' }, 0);
    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'c' }, 0);
    try std.testing.expect(pp.noteAt(72, 1.0) != null);
    try std.testing.expect(pp.noteAt(76, 1.0) != null);
    try std.testing.expect(pp.noteAt(67, 1.0) != null);
    try std.testing.expect(pp.noteAt(60, 1.0) == null);

    // The count is consumed, so the next bare cc is root position again.
    app.piano_cursor_step = 8;
    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'c' }, 0);
    try std.testing.expect(pp.noteAt(60, 2.0) != null);
    try std.testing.expect(pp.noteAt(72, 2.0) == null);
}

test "piano roll chord quality cycle: co/cO re-stamp in place without orphans" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 4.0;
    app.piano_cursor_pitch = 60;
    app.piano_cursor_step = 0;

    app.handleKey(.{ .char = 'c' }, 0); // C-E-G
    app.handleKey(.{ .char = 'c' }, 0);
    try std.testing.expectEqual(@as(u16, 3), pp.note_count);

    // co -> 6th (C-E-G-A); co again -> 7th (C-E-G-B): each cycle swaps one
    // voice in place, never piling the previous shape's notes up on top.
    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'o' }, 0);
    try std.testing.expect(pp.noteAt(69, 0.0) != null);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);

    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'o' }, 0);
    try std.testing.expect(pp.noteAt(71, 0.0) != null);
    try std.testing.expect(pp.noteAt(69, 0.0) == null);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);

    // co again -> 9th stacks a fifth third; cO walks back out of it.
    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'o' }, 0);
    try std.testing.expect(pp.noteAt(74, 0.0) != null);
    try std.testing.expectEqual(@as(u16, 5), pp.note_count);

    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'O' }, 0);
    try std.testing.expect(pp.noteAt(74, 0.0) == null);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);

    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'O' }, 0);
    try std.testing.expect(pp.noteAt(71, 0.0) == null);
    try std.testing.expect(pp.noteAt(69, 0.0) != null);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);
}

test "piano roll chord shortcuts stamp requested quality and seed cycle" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    app.piano_cursor_pitch = 60;

    for ("c7") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(pp.noteAt(71, 0.0) != null);
    for ("cO") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(pp.noteAt(71, 0.0) == null);
    try std.testing.expect(pp.noteAt(69, 0.0) != null);

    for ("cd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(pp.noteAt(63, 0.0) != null);
    try std.testing.expect(pp.noteAt(66, 0.0) != null);
    try std.testing.expect(pp.noteAt(69, 0.0) == null);
}

test "piano roll chord voicing cycle: cr/cR spread the same chord in place" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 4.0;
    app.piano_cursor_pitch = 60;
    app.piano_cursor_step = 0;

    // C stamps a 7th (C-E-G-B) and seeds the quality cycle from .seventh.
    app.handleKey(.{ .char = 'C' }, 0);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);
    try std.testing.expect(pp.noteAt(71, 0.0) != null);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);

    // The seeded quality: cO walks back to 6th, co returns to 7th.
    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'O' }, 0);
    try std.testing.expect(pp.noteAt(69, 0.0) != null);
    try std.testing.expect(pp.noteAt(71, 0.0) == null);
    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'o' }, 0);
    try std.testing.expect(pp.noteAt(71, 0.0) != null);
    try std.testing.expect(pp.noteAt(69, 0.0) == null);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);

    // cr -> drop2: the 2nd-from-top voice (G4) drops an octave to G3.
    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'r' }, 0);
    try std.testing.expect(pp.noteAt(55, 0.0) != null);
    try std.testing.expect(pp.noteAt(67, 0.0) == null);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);

    // cr -> open: every other voice above the root pushed up an octave.
    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'r' }, 0);
    try std.testing.expect(pp.noteAt(76, 0.0) != null);
    try std.testing.expect(pp.noteAt(83, 0.0) != null);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);

    // cR -> back to drop2, again without leaving the old voicing behind.
    app.handleKey(.{ .char = 'c' }, 0);
    app.handleKey(.{ .char = 'R' }, 0);
    try std.testing.expect(pp.noteAt(55, 0.0) != null);
    try std.testing.expect(pp.noteAt(76, 0.0) == null);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);
}

test "piano roll resizeNoteFromLeft moves the start and keeps the end" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 1.0, .velocity = 0.6 });

    // Step 2 (0.5b) with the end pinned at 2.0b: a 1.5-beat note.
    try std.testing.expect(piano_ed.resizeNoteFromLeft(&app, 60, 4, 2));
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    const note = pp.noteAt(60, 0.5) orelse return error.NoteMissing;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), note.duration_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), note.velocity, 1e-6);
    try std.testing.expectEqual(@as(u16, 2), app.piano_cursor_step);
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);

    // A start at or past the end is refused, as is a no-op or a missing note.
    try std.testing.expect(!piano_ed.resizeNoteFromLeft(&app, 60, 2, 8));
    try std.testing.expect(!piano_ed.resizeNoteFromLeft(&app, 60, 2, 2));
    try std.testing.expect(!piano_ed.resizeNoteFromLeft(&app, 72, 2, 0));
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);

    // Undo puts it back where it was, in one step.
    history.doUndo(&app);
    try std.testing.expect(pp.noteAt(60, 1.0) != null);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.noteAt(60, 1.0).?.duration_beat, 1e-9);
}

test "piano roll setVelocity (GUI lane drag) writes without its own undo entry" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.25, .duration_beat = 0.25, .velocity = 0.5 });

    // The drag's caller owns the undo entry, so the write pushes none of its
    // own - otherwise every frame of a drag would be one more `u`.
    try std.testing.expect(piano_ed.setVelocity(&app, 60, 1, 0.9));
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), pp.noteAt(60, 0.25).?.velocity, 1e-4);
    try std.testing.expectEqual(@as(usize, 0), app.history.undo_stack.items.len);
    // Cursor follows the dragged bar, as the note-canvas drags do.
    try std.testing.expectEqual(@as(u7, 60), app.piano_cursor_pitch);
    try std.testing.expectEqual(@as(u16, 1), app.piano_cursor_step);

    // Clamped to the same 0.05-1 range as `<`/`>`; no note, no write.
    try std.testing.expect(piano_ed.setVelocity(&app, 60, 1, -3));
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), pp.noteAt(60, 0.25).?.velocity, 1e-4);
    try std.testing.expect(!piano_ed.setVelocity(&app, 60, 1, 0.05)); // already there
    try std.testing.expect(!piano_ed.setVelocity(&app, 72, 1, 0.5)); // no note
}

test "piano roll f cycles which per-note field </> edits" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25, .velocity = 0.5 });
    app.piano_cursor_pitch = 60;
    app.piano_cursor_step = 0;

    // Velocity is the default, so `<`/`>` behaves exactly as it always did.
    try std.testing.expectEqual(ws.dsp.pattern.NoteField.velocity, app.piano_note_field);
    app.handleKey(.{ .char = '>' }, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), pp.noteAt(60, 0.0).?.velocity, 1e-4);

    // f moves to pan; the same keys now move pan and leave velocity alone.
    app.handleKey(.{ .char = 'f' }, 0);
    try std.testing.expectEqual(ws.dsp.pattern.NoteField.pan, app.piano_note_field);
    app.handleKey(.{ .char = '>' }, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), pp.noteAt(60, 0.0).?.art.pan, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), pp.noteAt(60, 0.0).?.velocity, 1e-4);

    // A count scales the field's own step, and the field clamps its own range.
    app.handleKey(.{ .char = '9' }, 0);
    app.handleKey(.{ .char = '>' }, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pp.noteAt(60, 0.0).?.art.pan, 1e-4);

    // F walks back; wrapping past the first field lands on the last.
    app.handleKey(.{ .char = 'F' }, 0);
    try std.testing.expectEqual(ws.dsp.pattern.NoteField.velocity, app.piano_note_field);
    app.handleKey(.{ .char = 'F' }, 0);
    try std.testing.expectEqual(ws.dsp.pattern.NoteField.release, app.piano_note_field);

    // `.` repeats the nudge on the field it was recorded with - the last one
    // was pan, so returning to velocity first doesn't redirect it.
    app.handleKey(.{ .char = 'f' }, 0); // back to velocity
    try std.testing.expectEqual(ws.dsp.pattern.NoteField.velocity, app.piano_note_field);
    const before_velocity = pp.noteAt(60, 0.0).?.velocity;
    app.handleKey(.{ .char = '.' }, 0);
    try std.testing.expectApproxEqAbs(before_velocity, pp.noteAt(60, 0.0).?.velocity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pp.noteAt(60, 0.0).?.art.pan, 1e-4);

    // Each nudge is its own undo entry, same as velocity always was: undoing
    // back past the two pan steps leaves the pan the first one set.
    app.handleKey(.{ .char = 'u' }, 0);
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), pp.noteAt(60, 0.0).?.art.pan, 1e-4);
}

test "piano roll :audition previews the pitch under the cursor on every j/k move" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    app.piano_cursor_pitch = 60;

    // Off by default: pitch motion is silent.
    app.handleKey(.{ .char = 'k' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.note_off_len);

    commands.run(&app, "audition");
    try std.testing.expect(app.piano_audition);
    app.handleKey(.{ .char = 'k' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
    try std.testing.expectEqual(app.piano_cursor_pitch, app.note_offs[0].note);

    // Clamped at the MIDI ceiling the cursor doesn't move, so nothing fires.
    app.piano_cursor_pitch = 127;
    app.handleKey(.{ .char = 'k' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);

    commands.run(&app, "audition off");
    app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
}

test "piano roll visual mode: w/b extend the selection by beat, matching normal-mode jumpBar" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 6.0;
    // Straight grid: 4 steps/beat, w/b's granularity (matches the drum grid's).
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 }); // step 0
    pp.addNote(.{ .pitch = 62, .start_beat = 1.0, .duration_beat = 0.25 }); // step 4, w's landing step (included, like v3l's landing step is)
    pp.addNote(.{ .pitch = 64, .start_beat = 2.0, .duration_beat = 0.25 }); // step 8, outside the w-extended range

    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'V' }, 0);
    app.handleKey(.{ .char = 'w' }, 0); // extend one beat forward (0 -> 4)
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 4), app.piano_cursor_step);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expect(pp.noteAt(62, 1.0) == null);
    try std.testing.expect(pp.noteAt(64, 2.0) != null); // untouched, outside the range

    // b moves the extended selection back a beat (from step 12, lands on 8).
    app.piano_cursor_step = 12;
    app.handleKey(.{ .char = 'V' }, 0);
    app.handleKey(.{ .char = 'b' }, 0);
    try std.testing.expectEqual(@as(u16, 8), app.piano_cursor_step);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(pp.noteAt(64, 2.0) == null);
}

test "piano roll normal-mode p pastes the most recent yank: range after visual y, pattern after yy" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 8.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 }); // step 0
    pp.addNote(.{ .pitch = 64, .start_beat = 0.25, .duration_beat = 0.25 }); // step 1

    // Visual range yank, then a plain normal-mode p at the new cursor -
    // no re-entering visual mode required.
    app.piano_cursor_step = 0;
    for ("V3ly") |c| app.handleKey(.{ .char = c }, 0);
    app.piano_cursor_step = 8;
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 2.0) != null);
    try std.testing.expect(pp.noteAt(64, 2.25) != null);

    // yy makes p the whole-pattern replace again.
    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    pp.clearNotes();
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);
    try std.testing.expect(pp.noteAt(64, 2.25) != null);
}

test "piano roll operator+motion: d3l / y3l act on a range without entering visual mode" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 8.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 }); // step 0
    pp.addNote(.{ .pitch = 64, .start_beat = 0.25, .duration_beat = 0.25 }); // step 1
    pp.addNote(.{ .pitch = 72, .start_beat = 2.0, .duration_beat = 0.25 }); // step 8, outside

    app.piano_cursor_step = 0;
    for ("y3l") |c| app.handleKey(.{ .char = c }, 0); // y + motion: yank steps 0-3
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 2), app.piano_range_clip.?.count);
    try std.testing.expectEqual(@as(u16, 3), app.piano_cursor_step); // cursor follows the motion

    app.piano_cursor_step = 0;
    for ("d3l") |c| app.handleKey(.{ .char = c }, 0); // d + motion: delete steps 0-3
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expect(pp.noteAt(64, 0.25) == null);
    try std.testing.expect(pp.noteAt(72, 2.0) != null); // untouched, outside the range
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);

    // Escape mid-operator cancels without acting.
    app.piano_cursor_step = 8;
    const before = pp.note_count;
    app.handleKey(.{ .char = 'd' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(before, pp.note_count);
    try std.testing.expect(pp.noteAt(72, 2.0) != null); // note under the cursor survives

    // yy stays the whole-pattern yank (the cross-track copy vehicle); dd is
    // vim's line-delete where a "line" is the cursor pitch's row - other
    // pitches survive.
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u16, 2), app.piano_clip.?.count); // both remaining notes
    app.piano_cursor_pitch = 60;
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count); // pitch 72 untouched
    try std.testing.expect(pp.noteAt(72, 2.0) != null);
    // dd on an empty row is a no-op: nothing recorded, nothing dirtied.
    const undo_before_noop = app.history.undo_stack.items.len;
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(undo_before_noop, app.history.undo_stack.items.len);
    app.piano_cursor_pitch = 72;
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
}

test "piano roll char/word tiers: x deletes the note under the cursor, w/b jump by beat" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 8.0; // straight grid, 4 steps/beat - w/b's granularity
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.25 }); // beat 2, step 4

    // x: instant single-note delete, no operator arming needed.
    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'x' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);

    // w: jump forward to the next beat boundary (step 4); b: back to beat 0.
    // Matches the drum grid's own w/b granularity (a beat, not a full bar) -
    // see barLenSteps's own note on the earlier bar-sized bug this fixed.
    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'w' }, 0);
    try std.testing.expectEqual(@as(u16, 4), app.piano_cursor_step);
    app.handleKey(.{ .char = 'b' }, 0);
    try std.testing.expectEqual(@as(u16, 0), app.piano_cursor_step);

    // dw: delete exactly the current beat's worth of steps (0-3), leaving
    // the note at beat 2 (step 4) untouched.
    for ("dw") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(pp.noteAt(64, 1.0) != null);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
}

test "T toggles the piano roll grid between straight and triplet" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 4.0;

    try std.testing.expectEqual(@as(u16, 4), app.pianoStepsPerBeat());
    _ = piano_ed.handleKey(&app, .{ .char = 'T' });
    try std.testing.expectEqual(@as(u16, 6), app.pianoStepsPerBeat());
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 6.0), app.piano_note_len, 1e-9);

    // Under the triplet grid, step 6 is a full beat later than step 0.
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;
    _ = piano_ed.handleKey(&app, .enter);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);
    _ = piano_ed.handleKey(&app, .escape); // drop the stamp session enter just started

    app.piano_cursor_step = 6;
    _ = piano_ed.handleKey(&app, .enter);
    try std.testing.expect(pp.noteAt(60, 1.0) != null);
    _ = piano_ed.handleKey(&app, .escape);

    // Toggling back rescales the cursor by its beat position (step 6 @ 6
    // steps/beat = beat 1 = step 4 @ 4 steps/beat), not a raw index copy.
    _ = piano_ed.handleKey(&app, .{ .char = 'T' });
    try std.testing.expectEqual(@as(u16, 4), app.pianoStepsPerBeat());
    try std.testing.expectEqual(@as(u16, 4), app.piano_cursor_step);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), app.piano_note_len, 1e-9);
}

test "piano roll H/L stay one beat on triplet and fine grids" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 4.0;

    _ = piano_ed.handleKey(&app, .{ .char = 'T' });
    _ = piano_ed.handleKey(&app, .{ .char = 'L' });
    try std.testing.expectEqual(@as(u16, 6), app.piano_cursor_step);

    _ = piano_ed.handleKey(&app, .{ .char = 'd' });
    _ = piano_ed.handleKey(&app, .{ .char = 'L' });
    try std.testing.expectEqual(@as(u16, 12), app.piano_cursor_step);

    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    _ = piano_ed.handleKey(&app, .{ .char = 'g' });
    try std.testing.expectEqual(@as(u16, 8), app.pianoStepsPerBeat());
    _ = piano_ed.handleKey(&app, .{ .char = 'H' });
    try std.testing.expectEqual(@as(u16, 8), app.piano_cursor_step);
}

test "piano roll n/N step-enter notes and rests by the default note length" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 4.0;
    app.piano_cursor_pitch = 60;
    app.piano_note_len = 0.5;

    _ = piano_ed.handleKey(&app, .{ .char = 'n' });
    try std.testing.expect(pp.noteAt(60, 0.0) != null);
    try std.testing.expectEqual(@as(u16, 2), app.piano_cursor_step);

    _ = piano_ed.handleKey(&app, .{ .char = 'N' });
    try std.testing.expect(pp.noteAt(60, 0.5) == null);
    try std.testing.expectEqual(@as(u16, 4), app.piano_cursor_step);

    _ = piano_ed.handleKey(&app, .{ .char = 'n' });
    try std.testing.expect(pp.noteAt(60, 1.0) != null);
    try std.testing.expectEqual(@as(u16, 6), app.piano_cursor_step);

    // Enter remains a stationary toggle for precise edits.
    _ = piano_ed.handleKey(&app, .enter);
    try std.testing.expect(pp.noteAt(60, 1.5) != null);
    try std.testing.expectEqual(@as(u16, 6), app.piano_cursor_step);
}

test "z and Z select piano roll subdivisions through 1/128" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 16.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });

    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.piano_division);
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "1/16") != null);

    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    _ = piano_ed.handleKey(&app, .{ .char = 'G' });
    try std.testing.expectEqual(ws.time_grid.Division.eighth, app.piano_division);

    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "PIANO ROLL") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "1/8") != null);

    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    _ = piano_ed.handleKey(&app, .{ .char = 'g' });
    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.piano_division);
    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    _ = piano_ed.handleKey(&app, .{ .char = 'g' });
    try std.testing.expectEqual(ws.time_grid.Division.thirty_second, app.piano_division);
    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    _ = piano_ed.handleKey(&app, .{ .char = 'g' });
    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    _ = piano_ed.handleKey(&app, .{ .char = 'g' });
    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    _ = piano_ed.handleKey(&app, .{ .char = 'g' });
    try std.testing.expectEqual(ws.time_grid.Division.one_twenty_eighth, app.piano_division);
    app.piano_cursor_step = 1;
    _ = piano_ed.handleKey(&app, .enter);
    try std.testing.expect(pp.noteAt(60, 1.0 / 32.0) != null);
}

test "piano roll flags an unlinked scratch pattern in song mode, not pattern mode" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    var buf: [32 * 1024]u8 = undefined;

    // Pattern mode: the live pattern IS what plays - no scratch warning.
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "scratch") == null);

    // Song mode, unlinked to any clip: flagged.
    app.session.setSongMode(true);
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "scratch: not in the song until stamped") != null);

    // Linked to a clip (arrangement's 'e'): no warning even in song mode.
    try app.session.stampClip(0, 0);
    app.view = .arrangement;
    app.handleKey(.{ .char = 'e' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "scratch") == null);
}

test "view switches nudge song mode while stopped, never while playing" {
    var app = try testApp();
    defer app.deinit();

    // Stopped: tab into the arrangement enables song mode.
    try std.testing.expect(!app.session.song_mode);
    app.handleKey(.tab, 0);
    try std.testing.expectEqual(AppView.arrangement, app.view);
    try std.testing.expect(app.session.song_mode);

    // Stopped: tabbing back out of the arrangement reverts to pattern mode,
    // symmetric with tabbing in.
    app.handleKey(.tab, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expect(!app.session.song_mode);

    // Opening a pattern editor from tracks while stopped stays in pattern
    // mode (already off from the tab above).
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expect(!app.session.song_mode);

    // Playing: view switches leave the mode alone (switching to the mixer
    // or an editor mid-song must not yank the playback source).
    app.view = .tracks;
    app.session.setSongMode(true);
    _ = app.session.engine.send(.play);
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block); // publishes playing=true
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expect(app.session.song_mode);

    // Tab back to tracks mid-song, still playing: tracks doubles as the
    // mixer during playback, so this must not yank the mode either.
    app.view = .arrangement;
    app.handleKey(.tab, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expect(app.session.song_mode);

    // The manual override (`T`) works directly from tracks view too.
    app.handleKey(.{ .char = 'T' }, 0);
    try std.testing.expect(!app.session.song_mode);
    app.handleKey(.{ .char = 'T' }, 0);
    try std.testing.expect(app.session.song_mode);
}

test "z and Z select arrangement grid subdivisions" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    try app.session.stampClip(0, 0);

    try std.testing.expectEqual(ws.time_grid.Division.quarter, app.arr_grid);
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "1/4") != null);

    app.handleKey(.{ .char = 'z' }, 0);
    app.handleKey(.{ .char = 'G' }, 0);
    try std.testing.expectEqual(ws.time_grid.Division.quarter, app.arr_grid);

    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "ARRANGEMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "1/4") != null);

    app.handleKey(.{ .char = 'z' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    try std.testing.expectEqual(ws.time_grid.Division.eighth, app.arr_grid);
    app.handleKey(.{ .char = 'z' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.arr_grid);
    app.handleKey(.{ .char = 'z' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    try std.testing.expectEqual(ws.time_grid.Division.thirty_second, app.arr_grid);
}

test "arrangement places moves and cuts clips on the 1/128 grid" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    app.cursor = 0;
    for (0..5) |_| {
        app.handleKey(.{ .char = 'z' }, 0);
        app.handleKey(.{ .char = 'g' }, 0);
    }
    try std.testing.expectEqual(ws.time_grid.Division.one_twenty_eighth, app.arr_grid);

    app.arr_cursor_bar = 1;
    app.handleKey(.enter, 0);
    app.handleKey(.enter_release, 0); // end the hold-to-resize stamp session
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(u32, 1), lane.clips.items[0].start_tick);
    const old_len = lane.clips.items[0].length_ticks;
    app.arr_cursor_bar = 1;
    app.handleKey(.{ .char = '-' }, 0);
    try std.testing.expectEqual(old_len - 1, lane.clips.items[0].length_ticks);
    app.handleKey(.{ .char = '>' }, 0);
    try std.testing.expectEqual(@as(u32, 2), lane.clips.items[0].start_tick);
}

test "arrangement: held enter resizes the fresh clip, release places it" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;

    app.handleKey(.enter, 0);
    try std.testing.expect(app.arr_stamp);
    const lane = app.session.arrangement.lane(0).?;
    const len = lane.clips.items[0].length_ticks;
    // The cursor stays on the clip while enter is held, so l grows it.
    try std.testing.expectEqual(@as(u32, 0), app.arr_cursor_bar);
    app.handleKey(.{ .char = 'l' }, 0);
    try std.testing.expectEqual(len + app.arr_grid.ticks(), lane.clips.items[0].length_ticks);

    // Release drops the session and jumps past the clip for the next stamp.
    app.handleKey(.enter_release, 0);
    try std.testing.expect(!app.arr_stamp);
    try std.testing.expectEqual(lane.clips.items[0].endTick() / app.arr_grid.ticks(), app.arr_cursor_bar);
}

test "automation editor: nudge, `.` repeat, and visual range yank/delete/paste" {
    var app = try testApp();
    defer app.deinit();

    try app.session.stampClip(0, 0); // 1-bar clip at bar 0 on the synth track
    automation_ed.switchTo(&app, 0, 0);
    try std.testing.expectEqual(AppView.automation, app.view);

    // j nudges gain down by one fine step, creating a point at the cursor.
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    const clip = automation_ed.currentClip(&app).?;
    try std.testing.expectEqual(@as(usize, 1), clip.automation.gain.len);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), clip.automation.gain[0].value, 1e-6);

    // `.` at a new cursor position repeats the same nudge there.
    _ = automation_ed.handleKey(&app, .{ .char = 'l' });
    _ = automation_ed.handleKey(&app, .{ .char = '.' });
    try std.testing.expectEqual(@as(usize, 2), clip.automation.gain.len);

    // Visual mode: select the range covering both points and yank it.
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'v' });
    for ("3l") |c| _ = automation_ed.handleKey(&app, .{ .char = c });
    _ = automation_ed.handleKey(&app, .{ .char = 'y' });
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(app.automation_range_clip != null);
    try std.testing.expectEqual(@as(usize, 2), app.automation_range_clip.?.points.len);

    // Select the same range again and delete it - the curve goes bare.
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'v' });
    for ("3l") |c| _ = automation_ed.handleKey(&app, .{ .char = c });
    _ = automation_ed.handleKey(&app, .{ .char = 'd' });
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 0), clip.automation.gain.len);

    // Paste the yanked points back - like piano/arrangement, range-paste only
    // lives inside visual mode (a plain normal-mode `P` is a different,
    // whole-content clipboard that automation doesn't have).
    _ = automation_ed.handleKey(&app, .{ .char = 'v' });
    _ = automation_ed.handleKey(&app, .{ .char = 'P' });
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), clip.automation.gain.len);
}

test "automation editor visual mode: w/b extend the selection by beat, matching normal-mode jumpBar" {
    var app = try testApp();
    defer app.deinit();

    try app.session.stampClip(0, 0);
    automation_ed.switchTo(&app, 0, 0);
    const clip = automation_ed.currentClip(&app).?;
    clip.length_ticks = 256;

    // Points at step 0, step 4 (w's landing step, included like v3l's is),
    // and step 8 (outside the w-extended range).
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    app.automation_cursor_step = 4;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    app.automation_cursor_step = 8;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    try std.testing.expectEqual(@as(usize, 3), clip.automation.gain.len);

    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'v' });
    _ = automation_ed.handleKey(&app, .{ .char = 'w' }); // extend one beat forward (0 -> 4)
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    try std.testing.expectEqual(@as(u32, 4), app.automation_cursor_step);
    _ = automation_ed.handleKey(&app, .{ .char = 'd' });
    try std.testing.expectEqual(@as(usize, 1), clip.automation.gain.len);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), clip.automation.gain[0].beat, 1e-9); // step 8 survives

    // b moves the extended selection back a beat (from step 12, lands on 8).
    app.automation_cursor_step = 12;
    _ = automation_ed.handleKey(&app, .{ .char = 'v' });
    _ = automation_ed.handleKey(&app, .{ .char = 'b' });
    try std.testing.expectEqual(@as(u32, 8), app.automation_cursor_step);
    _ = automation_ed.handleKey(&app, .{ .char = 'd' });
    try std.testing.expectEqual(@as(usize, 0), clip.automation.gain.len);
}

test "automation editor normal-mode P pastes a range yank without re-entering visual mode ('p' is the param picker)" {
    var app = try testApp();
    defer app.deinit();

    try app.session.stampClip(0, 0);
    automation_ed.switchTo(&app, 0, 0);
    const clip = automation_ed.currentClip(&app).?;
    clip.length_ticks = 256;

    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 0
    app.automation_cursor_step = 4;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 4

    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'v' });
    _ = automation_ed.handleKey(&app, .{ .char = 'w' }); // select steps 0-4
    _ = automation_ed.handleKey(&app, .{ .char = 'y' });
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.automation_range_clip.?.points.len);

    app.automation_cursor_step = 12;
    const before = clip.automation.gain.len;
    _ = automation_ed.handleKey(&app, .{ .char = 'P' }); // plain normal-mode paste, no 'v' first
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(before + 2, clip.automation.gain.len);
}

test "automation editor operator+motion: d3l / y3l act on a range without entering visual mode" {
    var app = try testApp();
    defer app.deinit();

    try app.session.stampClip(0, 0); // 1-bar clip at bar 0 on the synth track
    automation_ed.switchTo(&app, 0, 0);
    const clip = automation_ed.currentClip(&app).?;

    // Seed points at steps 0, 1, and 8 (outside the coming d3l/y3l range).
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 0
    app.automation_cursor_step = 1;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 1
    app.automation_cursor_step = 8;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 8
    try std.testing.expectEqual(@as(usize, 3), clip.automation.gain.len);

    app.automation_cursor_step = 0;
    for ("y3l") |c| app.handleKey(.{ .char = c }, 0); // y + motion: yank steps 0-3
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.automation_range_clip.?.points.len);
    try std.testing.expectEqual(@as(u32, 3), app.automation_cursor_step); // cursor follows the motion

    app.automation_cursor_step = 0;
    for ("d3l") |c| app.handleKey(.{ .char = c }, 0); // d + motion: delete steps 0-3
    try std.testing.expectEqual(@as(usize, 1), clip.automation.gain.len); // only step 8 survives

    // Escape mid-operator cancels without acting.
    app.automation_cursor_step = 8;
    const before = clip.automation.gain.len;
    app.handleKey(.{ .char = 'd' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(before, clip.automation.gain.len);

    // dd/yy are the tier above w/b's bar range: the whole curve.
    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.automation_range_clip.?.points.len);
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(usize, 0), clip.automation.gain.len);
}

test "automation editor char/word tiers: x deletes the point under the cursor, w/b jump by beat" {
    var app = try testApp();
    defer app.deinit();

    try app.session.stampClip(0, 0);
    // Extend the clip to 2 bars so there's plenty of beat boundaries to jump to.
    automation_ed.switchTo(&app, 0, 0);
    const clip = automation_ed.currentClip(&app).?;
    clip.length_ticks = 256;

    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 0
    try std.testing.expectEqual(@as(usize, 1), clip.automation.gain.len);

    // x: instant single-point delete, no operator arming needed.
    _ = automation_ed.handleKey(&app, .{ .char = 'x' });
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 0), clip.automation.gain.len);

    // w: jump forward to the next beat boundary (step 4); b: back to beat 0.
    // Matches the drum grid's own w/b granularity (a beat, not a full bar) -
    // see barLenSteps's own note on the earlier bar-sized bug this fixed.
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'w' });
    try std.testing.expectEqual(@as(u32, 4), app.automation_cursor_step);
    _ = automation_ed.handleKey(&app, .{ .char = 'b' });
    try std.testing.expectEqual(@as(u32, 0), app.automation_cursor_step);

    // dw: delete exactly the current beat's worth of points (steps 0-3),
    // leaving a point at beat 2 (step 4) untouched.
    app.automation_cursor_step = 4;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 4
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 0
    try std.testing.expectEqual(@as(usize, 2), clip.automation.gain.len);
    for ("dw") |c| _ = automation_ed.handleKey(&app, .{ .char = c });
    try std.testing.expectEqual(@as(usize, 1), clip.automation.gain.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), clip.automation.gain[0].beat, 1e-9); // step 4 = beat 1
}

test "automation editor: c cycles the segment shape and the curve plays it back" {
    var app = try testApp();
    defer app.deinit();

    try app.session.stampClip(0, 0);
    automation_ed.switchTo(&app, 0, 0);
    const clip = automation_ed.currentClip(&app).?;
    clip.length_ticks = 256;

    // An interpolated step has no shape of its own to set.
    app.automation_cursor_step = 2;
    _ = automation_ed.handleKey(&app, .{ .char = 'c' });
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "no point exactly here") != null);

    // Two points a beat apart, so the segment between them is measurable.
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'k' });
    app.automation_cursor_step = 4;
    for (0..4) |_| _ = automation_ed.handleKey(&app, .{ .char = 'k' });
    try std.testing.expectEqual(@as(usize, 2), clip.automation.gain.len);

    const a = clip.automation.gain[0].value;
    const b = clip.automation.gain[1].value;
    try std.testing.expect(b > a);
    const mid = 0.5; // beat halfway between step 0 and step 4

    // linear: the midpoint sits halfway between the two values.
    try std.testing.expectApproxEqAbs((a + b) / 2.0, automation_mod.interpolate(clip.automation.gain, mid).?, 1e-5);

    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'c' }); // -> hold
    try std.testing.expectEqual(automation_mod.Curve.hold, clip.automation.gain[0].curve);
    try std.testing.expectApproxEqAbs(a, automation_mod.interpolate(clip.automation.gain, mid).?, 1e-5);

    _ = automation_ed.handleKey(&app, .{ .char = 'c' }); // -> ease
    try std.testing.expectEqual(automation_mod.Curve.ease, clip.automation.gain[0].curve);
    // Smoothstep is symmetric, so its midpoint matches linear's; a quarter
    // in is where it visibly lags.
    try std.testing.expect(automation_mod.interpolate(clip.automation.gain, 0.25).? < (a + b) / 2.0);

    _ = automation_ed.handleKey(&app, .{ .char = 'c' }); // -> back to linear
    try std.testing.expectEqual(automation_mod.Curve.linear, clip.automation.gain[0].curve);

    // The shape is undoable with the value edits, at the same whole-lane
    // granularity every other automation edit uses.
    _ = automation_ed.handleKey(&app, .{ .char = 'c' }); // -> hold again
    _ = automation_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectEqual(automation_mod.Curve.linear, clip.automation.gain[0].curve);
}

test "automation editor: tab only cycles gain/pan until the picker adds a synth param" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();

    // Synth track: tab cycles gain <-> pan only - no synth-param lane exists
    // on this clip yet, so there's nothing else to cycle to.
    try app.session.stampClip(0, 0);
    automation_ed.switchTo(&app, 0, 0);
    try std.testing.expectEqual(automation_ed.AutomationFocus.gain, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.pan, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.gain, app.automation_focus);

    // p opens the picker; select filter cutoff (param_id 21) and confirm it
    // switches focus there and creates an (empty) lane.
    _ = automation_ed.handleKey(&app, .{ .char = 'p' });
    try std.testing.expectEqual(AppView.automation_param_picker, app.view);
    var cutoff_idx: u8 = 0;
    for (ws.dsp.synth.PolySynth.automatable_params, 0..) |p, i| {
        // zig fmt: off
        if (p.id == 21) { cutoff_idx = @intCast(i); break; }
        // zig fmt: on
    }
    app.automation_param_cursor = cutoff_idx;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.automation, app.view);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = .{ .param_id = 21 } }, app.automation_focus);

    // Now tab cycles gain -> pan -> cutoff -> gain, and j nudges the cutoff
    // curve, clamped 20..20_000 like the synth's own param.
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    const synth_clip = automation_ed.currentClip(&app).?;
    try std.testing.expectEqual(@as(usize, 1), synth_clip.automation.findSynthParam(0, 21).?.len);
    app.automation_focus = .gain;
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.pan, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = .{ .param_id = 21 } }, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.gain, app.automation_focus);

    // Sampler track: the picker offers Sampler's own automatable_params
    // table: select GAIN (param_id 7) and confirm it behaves exactly
    // like the synth-track case above.
    try app.session.stampClip(1, 0);
    automation_ed.switchTo(&app, 1, 0);
    try std.testing.expectEqual(automation_ed.AutomationFocus.gain, app.automation_focus);
    _ = automation_ed.handleKey(&app, .{ .char = 'p' });
    try std.testing.expectEqual(AppView.automation_param_picker, app.view);
    var gain_idx: u8 = 0;
    for (ws.dsp.Sampler.automatable_params, 0..) |p, i| {
        // zig fmt: off
        if (p.id == 7) { gain_idx = @intCast(i); break; }
        // zig fmt: on
    }
    app.automation_param_cursor = gain_idx;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.automation, app.view);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = .{ .param_id = 7 } }, app.automation_focus);
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    const sampler_clip = automation_ed.currentClip(&app).?;
    try std.testing.expectEqual(@as(usize, 1), sampler_clip.automation.findSynthParam(0, 7).?.len);
    app.automation_focus = .gain;
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.pan, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = .{ .param_id = 7 } }, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.gain, app.automation_focus);

    // Drum track: picker targets current pad and stores its packed pad/param id.
    try app.session.stampClip(2, 0);
    app.drum_cursor[0] = 2;
    automation_ed.switchTo(&app, 2, 0);
    try std.testing.expectEqual(automation_ed.AutomationFocus.gain, app.automation_focus);
    _ = automation_ed.handleKey(&app, .{ .char = 'p' });
    try std.testing.expectEqual(AppView.automation_param_picker, app.view);
    const drum_gain_id = ws.dsp.DrumMachine.paramId(2, 7);
    var drum_gain_idx: u8 = 0;
    for (automation_ed.instrumentAutomatableParams(&app), 0..) |p, i| {
        // zig fmt: off
        if (p.id == drum_gain_id) { drum_gain_idx = @intCast(i); break; }
        // zig fmt: on
    }
    app.automation_param_cursor = drum_gain_idx;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = .{ .param_id = drum_gain_id } }, app.automation_focus);
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    const drum_clip = automation_ed.currentClip(&app).?;
    try std.testing.expectEqual(@as(usize, 1), drum_clip.automation.findSynthParam(0, drum_gain_id).?.len);

    // Switching back to the synth clip while focus is .gain still offers the
    // cutoff lane again via tab (it's already on that clip).
    automation_ed.switchTo(&app, 0, 0);
    _ = automation_ed.handleKey(&app, .tab);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = .{ .param_id = 21 } }, app.automation_focus);
}

test "the automation param picker hides the synth's dead FX params" {
    var app = try testApp();
    defer app.deinit();
    try app.session.stampClip(0, 0);
    automation_ed.switchTo(&app, 0, 0);
    _ = automation_ed.handleKey(&app, .{ .char = 'p' });

    // The table still carries them - they are legal mod-matrix destinations,
    // addressing the rack chain's units - but a lane on one would write a
    // synth field nothing plays, so the picker must not list them.
    var fx_in_table: usize = 0;
    for (ws.dsp.synth.PolySynth.automatable_params) |p| {
        if (p.modDestOnly()) fx_in_table += 1;
    }
    try std.testing.expect(fx_in_table > 0);

    var rows_buf: [automation_ed.max_param_display_rows]automation_ed.ParamDisplayRow = undefined;
    const params = automation_ed.instrumentAutomatableParams(&app);
    const rows = automation_ed.buildParamDisplayRows(params, "", &rows_buf);
    var listed: usize = 0;
    for (rows) |row| switch (row) {
        .param => |i| {
            try std.testing.expect(!params[i].modDestOnly());
            listed += 1;
        },
        .header => |name| try std.testing.expect(!std.mem.startsWith(u8, name, "FX ")),
    };
    try std.testing.expect(listed > 0);
}

test "automation picker targets current slicer row" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(2, .slicer);
    try app.session.stampClip(2, 0);
    app.slicer_cursor[0] = 1;
    automation_ed.switchTo(&app, 2, 0);
    _ = automation_ed.handleKey(&app, .{ .char = 'p' });
    try std.testing.expectEqual(AppView.automation_param_picker, app.view);

    const pan_id = ws.dsp.Slicer.paramId(1, 8);
    var pan_idx: u8 = 0;
    for (automation_ed.instrumentAutomatableParams(&app), 0..) |p, i| {
        // zig fmt: off
        if (p.id == pan_id) { pan_idx = @intCast(i); break; }
        // zig fmt: on
    }
    app.automation_param_cursor = pan_idx;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = .{ .param_id = pan_id } }, app.automation_focus);
}

test "automation param mouse click during live search selects lane and leaves search mode" {
    var app = try testApp();
    defer app.deinit();
    try app.session.stampClip(0, 0);
    automation_ed.switchTo(&app, 0, 0);
    _ = automation_ed.handleKey(&app, .{ .char = 'p' });

    for ("/cutoff") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);
    var cutoff_idx: usize = 0;
    for (ws.dsp.synth.PolySynth.automatable_params, 0..) |p, i| {
        if (p.id == 21) {
            cutoff_idx = i;
            break;
        }
    }
    var rows_buf: [automation_ed.max_param_display_rows]automation_ed.ParamDisplayRow = undefined;
    const rows = automation_ed.buildParamDisplayRows(automation_ed.instrumentAutomatableParams(&app), automation_ed.activeParamFilter(&app), &rows_buf);
    var display_row: usize = 0;
    for (rows, 0..) |row, i| switch (row) {
        .param => |param_idx| if (param_idx == cutoff_idx) {
            display_row = i;
            break;
        },
        .header => {},
    };
    app.handleMouse(.{ .x = 4, .y = @intCast(app_mod.content_top + 2 + display_row), .button = .left, .kind = .press }, 80, 24, 0);

    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(AppView.automation, app.view);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = .{ .param_id = 21 } }, app.automation_focus);
}

test "visual mode escape cancels the selection without editing" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });

    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'v' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(?u16, null), app.piano_visual_anchor);
    // Still in the piano roll (escape cancelled the selection, not the view).
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
}

test "drum grid yank/paste carries pattern, velocity, and length" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    const dm = app.drumMachine();

    for (0..ws.dsp.DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.setStepCount(32);
    dm.toggleStep(0, 7);
    dm.setStepVel(0, 7, 63);
    _ = drum_ed.handleKey(&app, .{ .char = 'y' }); // yy yanks the whole pattern
    _ = drum_ed.handleKey(&app, .{ .char = 'y' });

    // A fresh variant wipes the grid; paste restores the yanked pattern.
    _ = drum_ed.handleKey(&app, .{ .char = 'N' });
    dm.clearPad(0);
    dm.setStepCount(16);
    _ = drum_ed.handleKey(&app, .{ .char = 'P' });
    try std.testing.expect(dm.stepActive(0, 7));
    try std.testing.expectEqual(@as(u8, 63), dm.stepVel(0, 7));
    try std.testing.expectEqual(@as(u8, 32), dm.step_count);
}

test "drum grid visual-line mode selects a step range across pads for y/d/P" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (0..ws.dsp.DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.setStepVel(0, 0, 31);
    dm.toggleStep(1, 2);
    dm.toggleStep(3, 14); // outside both the selection and the paste target below

    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'V' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0); // extend to step 3
    app.handleKey(.{ .char = 'y' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 4), app.drum_range_clip.?.width);

    // Paste at step 8 (all pads): P is a visual-mode action, so re-enter
    // visual first (V establishes the cursor as the paste point).
    app.drum_cursor[1] = 8;
    app.handleKey(.{ .char = 'V' }, 0);
    app.handleKey(.{ .char = 'P' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(dm.stepActive(0, 8));
    try std.testing.expectEqual(@as(u8, 31), dm.stepVel(0, 8));
    try std.testing.expect(dm.stepActive(1, 10));
    // Untouched original steps and the step outside the paste range survive.
    try std.testing.expect(dm.stepActive(0, 0));
    try std.testing.expect(dm.stepActive(3, 14));

    // Select again and clear it.
    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'V' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(!dm.stepActive(0, 0));
    try std.testing.expect(!dm.stepActive(1, 2));
}

test "drum grid blockwise visual bounds the selection to the pad band j/k grows" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (0..ws.dsp.DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.toggleStep(1, 1);
    dm.toggleStep(2, 2); // one pad below the block selected below

    // v on pad 0 + j: a 2-pad x 4-step block. Pad 2 is outside it.
    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expectEqual(@as(?u8, 0), app.drum_visual_pad_anchor);
    app.handleKey(.{ .char = 'j' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(!dm.stepActive(0, 0));
    try std.testing.expect(!dm.stepActive(1, 1));
    try std.testing.expect(dm.stepActive(2, 2)); // untouched: outside the block
    try std.testing.expectEqual(@as(?u8, null), app.drum_visual_pad_anchor);

    // A blockwise yank pastes with its top row on the cursor pad, so the
    // same 2-pad shape lands on pads 4-5 rather than back on 0-1.
    dm.toggleStep(0, 0);
    dm.toggleStep(1, 1);
    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'j' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'y' }, 0);
    app.drum_cursor = .{ 4, 8 };
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expect(dm.stepActive(4, 8));
    try std.testing.expect(dm.stepActive(5, 9));
    try std.testing.expect(!dm.stepActive(6, 10));
}

test "linewise pastes keep their own rows, blockwise pastes follow the cursor row" {
    // A full-height yank must not slide down just because the cursor sits
    // on row 3 - that would turn a whole-grid copy into a transposition.
    const linewise = .{ .row_lo = @as(u8, 0), .row_hi = @as(u8, 15) };
    try std.testing.expectEqual(@as(usize, 0), step_grid.pasteBaseRow(linewise, 3, 16));
    // A 2-row block lands on the cursor row, clamped so it stays in-grid.
    const block = .{ .row_lo = @as(u8, 4), .row_hi = @as(u8, 5) };
    try std.testing.expectEqual(@as(usize, 3), step_grid.pasteBaseRow(block, 3, 16));
    try std.testing.expectEqual(@as(usize, 14), step_grid.pasteBaseRow(block, 15, 16));
}

test "rowRange: a null anchor is every row, an anchored one is the band" {
    const all = step_grid.rowRange(u8, null, 3, 16);
    try std.testing.expectEqual(@as(usize, 0), all.lo);
    try std.testing.expectEqual(@as(usize, 15), all.hi);
    try std.testing.expectEqual(@as(usize, 16), all.height());
    // Order-independent, and clamped to the grid even if the anchor is stale.
    const band = step_grid.rowRange(u8, 7, 2, 16);
    try std.testing.expectEqual(@as(usize, 2), band.lo);
    try std.testing.expectEqual(@as(usize, 7), band.hi);
    const stale = step_grid.rowRange(u8, 99, 2, 16);
    try std.testing.expectEqual(@as(usize, 15), stale.hi);
    // An empty grid can't underflow into a huge range.
    const empty = step_grid.rowRange(u8, null, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.hi);
}

test "drum grid visual mode yank/paste carries a range wider than the old 64-step clipboard cap" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (0..ws.dsp.DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.setStepCount(200);
    dm.toggleStep(0, 0);
    dm.toggleStep(0, 90); // past the old 64-bit clipboard's reach
    dm.setStepVel(0, 90, 50);

    // Select steps 0-99 (100 wide) and yank.
    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'v' }, 0);
    for ("99l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'y' }, 0);
    try std.testing.expectEqual(@as(u16, 100), app.drum_range_clip.?.width);

    // Paste at step 50 - step 90's offset (50) lands at step 140.
    app.drum_cursor[1] = 50;
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'P' }, 0);
    try std.testing.expect(dm.stepActive(0, 50));
    try std.testing.expect(dm.stepActive(0, 140));
    try std.testing.expectEqual(@as(u8, 50), dm.stepVel(0, 140));
}

test "drum grid visual mode: w/b extend the selection by beat, matching normal-mode jumpBar" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (0..ws.dsp.DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.toggleStep(0, 4); // last step of the first 4-step bar `w` should reach
    dm.toggleStep(0, 8); // outside the w-extended range

    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'w' }, 0); // extend one bar forward (0 -> 4)
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    try std.testing.expectEqual(@as(u8, 4), app.drum_cursor[1]);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(!dm.stepActive(0, 0));
    try std.testing.expect(!dm.stepActive(0, 4));
    try std.testing.expect(dm.stepActive(0, 8)); // untouched, outside the range

    // b moves the extended selection back a bar (from step 8, lands on 4).
    app.drum_cursor = .{ 0, 8 };
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'b' }, 0);
    try std.testing.expectEqual(@as(u8, 4), app.drum_cursor[1]);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(!dm.stepActive(0, 8));
}

test "drum grid visual mode: J/K jump a pad bank, matching normal-mode movePad" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;

    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'J' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    try std.testing.expectEqual(@as(u8, 8), app.drum_cursor[0]);
    app.handleKey(.{ .char = 'K' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.drum_cursor[0]);
    app.handleKey(.escape, 0);
}

test "drum grid normal-mode p pastes the most recent yank: range after visual y, pattern after yy" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (0..ws.dsp.DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.setStepVel(0, 0, 31);
    dm.toggleStep(1, 2);

    // Visual range yank, then a plain normal-mode p at the new cursor -
    // no re-entering visual mode required.
    app.drum_cursor = .{ 0, 0 };
    for ("V3ly") |c| app.handleKey(.{ .char = c }, 0);
    app.drum_cursor[1] = 8;
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expect(dm.stepActive(0, 8));
    try std.testing.expectEqual(@as(u8, 31), dm.stepVel(0, 8));
    try std.testing.expect(dm.stepActive(1, 10));

    // yy makes p the whole-pattern replace again.
    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    dm.toggleStep(3, 14); // extra step the pattern paste should wipe
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expect(!dm.stepActive(3, 14));
    try std.testing.expect(dm.stepActive(0, 0));
    try std.testing.expect(dm.stepActive(1, 2));
}

test "drum grid operator+motion: d3l / y3l act on a range without entering visual mode" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (0..ws.dsp.DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.toggleStep(1, 2);
    dm.toggleStep(3, 14); // outside the range below

    app.drum_cursor = .{ 0, 0 };
    for ("y3l") |c| app.handleKey(.{ .char = c }, 0); // y + motion: yank steps 0-3
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 4), app.drum_range_clip.?.width);
    try std.testing.expectEqual(@as(u8, 3), app.drum_cursor[1]); // cursor follows the motion

    app.drum_cursor = .{ 0, 0 };
    for ("d3l") |c| app.handleKey(.{ .char = c }, 0); // d + motion: clear steps 0-3
    try std.testing.expect(!dm.stepActive(0, 0));
    try std.testing.expect(!dm.stepActive(1, 2));
    try std.testing.expect(dm.stepActive(3, 14)); // untouched, outside the range

    // yy stays the whole-pattern yank (the cross-track copy vehicle); dd is
    // vim's line-delete where a "line" is the cursor pad's row - other
    // pads survive.
    dm.toggleStep(2, 5);
    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(app.drum_clip != null);
    app.drum_cursor = .{ 2, 0 };
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(!dm.stepActive(2, 5));
    try std.testing.expect(dm.stepActive(3, 14)); // other pad untouched
    app.drum_cursor = .{ 3, 0 };
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(!dm.stepActive(3, 14));
}

test "drum grid char/word tiers: x clears just this cell, w/b jump by beat" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (0..ws.dsp.DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.setStepCount(32);
    dm.toggleStep(0, 5); // outside the first beat (steps 0-3)
    dm.toggleStep(2, 5);
    dm.toggleStep(2, 2); // inside the first beat
    dm.toggleStep(1, 20); // far away, untouched by anything below

    // x: instant single-cell clear, no operator arming needed.
    app.drum_cursor = .{ 0, 5 };
    app.handleKey(.{ .char = 'x' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(!dm.stepActive(0, 5));
    try std.testing.expect(dm.stepActive(2, 5)); // a different pad's step at the same column survives

    // w: jump forward to the next beat boundary (step 4); b: back to 0.
    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'w' }, 0);
    try std.testing.expectEqual(@as(u8, 4), app.drum_cursor[1]);
    app.handleKey(.{ .char = 'b' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.drum_cursor[1]);

    // dw: clear exactly the current beat (steps 0-3), leaving steps
    // outside it (5, 20) untouched.
    for ("dw") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(!dm.stepActive(2, 2));
    try std.testing.expect(dm.stepActive(2, 5));
    try std.testing.expect(dm.stepActive(1, 20));
}

test "paste with an empty clipboard is a no-op" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;

    const before = app.drumMachine().stepActive(0, 0);
    _ = drum_ed.handleKey(&app, .{ .char = 'P' });
    try std.testing.expectEqual(before, app.drumMachine().stepActive(0, 0));

    app.piano_track = 0;
    _ = piano_ed.handleKey(&app, .{ .char = 'P' });
    try std.testing.expectEqual(@as(u16, 0), app.session.racks.items[0].pattern_player.?.note_count);
}

test "undo/redo round-trips a piano-roll edit" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;

    app.piano_cursor_pitch = 60;
    app.piano_cursor_step = 0;
    _ = piano_ed.handleKey(&app, .enter); // insert
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);

    _ = piano_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
    _ = piano_ed.handleKey(&app, .{ .char = 'U' });
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);

    // ctrl-r is vim's canonical redo key - works the same as 'U'.
    _ = piano_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
    _ = piano_ed.handleKey(&app, .ctrl_r);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
}

test "undo/redo round-trips a drum edit including velocity and variants" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    const dm = app.drumMachine();
    const kick_before = dm.stepActive(0, 2);

    app.drum_cursor = .{ 0, 2 };
    _ = drum_ed.handleKey(&app, .enter); // toggle a step
    _ = drum_ed.handleKey(&app, .{ .char = 'N' }); // new variant (B)
    try std.testing.expectEqual(@as(u8, 2), dm.variant_count);

    _ = drum_ed.handleKey(&app, .{ .char = 'u' }); // undo variant add
    try std.testing.expectEqual(@as(u8, 1), dm.variant_count);
    _ = drum_ed.handleKey(&app, .{ .char = 'u' }); // undo the toggle
    try std.testing.expectEqual(kick_before, dm.stepActive(0, 2));

    _ = drum_ed.handleKey(&app, .{ .char = 'U' }); // redo the toggle
    try std.testing.expectEqual(!kick_before, dm.stepActive(0, 2));
    _ = drum_ed.handleKey(&app, .{ .char = 'U' }); // redo the variant add
    try std.testing.expectEqual(@as(u8, 2), dm.variant_count);
}

test "undo restores clips a stamp evicted" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });

    // Stamp at bar 0, then stamp over it (evicting the original).
    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    app.handleKey(.enter, 0);
    app.handleKey(.enter_release, 0); // end the hold-to-resize stamp session
    pp.notes[0].pitch = 72; // different content for the second stamp
    app.arr_cursor_bar = 0;
    app.handleKey(.enter, 0);
    app.handleKey(.enter_release, 0);
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try std.testing.expectEqual(@as(u7, 72), lane.clips.items[0].content.melodic.notes[0].pitch);

    // Undo the second stamp: the evicted original comes back.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try std.testing.expectEqual(@as(u7, 60), lane.clips.items[0].content.melodic.notes[0].pitch);

    // Undo the first stamp: empty lane. Redo brings it back.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(usize, 0), lane.clips.items.len);
    app.handleKey(.{ .char = 'U' }, 0);
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
}

test "undo of a linked clip edit restores the clip too" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0);

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'e' }, 0); // clip editing mode

    app.piano_cursor_pitch = 64;
    app.piano_cursor_step = 4;
    _ = piano_ed.handleKey(&app, .enter); // insert into the clip
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(usize, 2), lane.clipAt(0).?.content.melodic.notes.len);

    _ = piano_ed.handleKey(&app, .{ .char = 'u' }); // undo the clip edit
    try std.testing.expectEqual(@as(usize, 1), lane.clipAt(0).?.content.melodic.notes.len);
    try std.testing.expect(app.piano_clip_link != null); // still editing the clip

    _ = piano_ed.handleKey(&app, .{ .char = 'U' }); // redo it
    try std.testing.expectEqual(@as(usize, 2), lane.clipAt(0).?.content.melodic.notes.len);
}

test "arrangement e edits a melodic clip in place" {
    var app = try testApp();
    defer app.deinit();

    // Track 0 (synth): one note in the live pattern, stamped at bar 0.
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0);

    // Diverge the live pattern afterwards - the clip keeps its own copy.
    pp.addNote(.{ .pitch = 65, .start_beat = 1.0, .duration_beat = 0.5 });

    // e on the clip: the piano roll opens with the clip's single note loaded.
    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'e' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expect(app.piano_clip_link != null);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);

    // Insert a note; the clip itself gains it.
    app.piano_cursor_pitch = 64;
    app.piano_cursor_step = 4; // beat 1
    _ = piano_ed.handleKey(&app, .enter);
    const clip = app.session.arrangement.lane(0).?.clipAt(0).?;
    try std.testing.expectEqual(@as(usize, 2), clip.content.melodic.notes.len);
    try std.testing.expectEqual(@as(u7, 64), clip.content.melodic.notes[1].pitch);

    // Loop-length changes land in the clip too.
    _ = piano_ed.handleKey(&app, .{ .char = '+' });
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), clip.content.melodic.length_beats, 1e-9);
}

test "clip link drops when the clip vanishes; plain open is unlinked" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0);

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'e' }, 0);
    try std.testing.expect(app.piano_clip_link != null);

    // Clip removed behind the editor's back: the next edit unlinks, no crash.
    _ = app.session.arrangement.lane(0).?.removeAt(app.allocator, 0);
    _ = piano_ed.handleKey(&app, .enter);
    try std.testing.expect(app.piano_clip_link == null);

    // Re-link, then a plain open from the tracks view targets the live
    // pattern again - no link.
    try app.session.stampClip(0, 0);
    app.view = .arrangement;
    app.handleKey(.{ .char = 'e' }, 0);
    try std.testing.expect(app.piano_clip_link != null);
    app.view = .tracks;
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expect(app.piano_clip_link == null);
}

test "arrangement e on a drum clip stays put" {
    var app = try testApp();
    defer app.deinit();
    try app.session.stampClip(2, 0); // drum track's default groove

    app.view = .arrangement;
    app.cursor = 2;
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'e' }, 0);
    try std.testing.expectEqual(AppView.arrangement, app.view);
    try std.testing.expect(app.piano_clip_link == null);
}

test "loop recording splits passes into alternate takes" {
    var app = try testApp();
    defer app.deinit();
    app.session.project.tempo_bpm = @as(f64, @floatFromInt(app.session.project.sample_rate)) * 60.0;
    app.recording_active_len = 1;
    app.recording_active_buf[0] = 1;
    app.recording_loop_start_bar = 2;
    app.recording_loop_end_bar = 4;
    try app.recording_accum.appendNTimes(app.allocator, 0.5, 18);

    app.finishRecording();

    try std.testing.expectEqual(@as(usize, 3), app.session.project.audio_sources.items.len);
    const clip = &app.session.arrangement.lane(1).?.clips.items[0];
    try std.testing.expectEqual(@as(u32, 64), clip.start_tick);
    try std.testing.expectEqual(@as(usize, 3), clip.content.audio.takeCount());
    try std.testing.expectEqual(@as(u64, 2), clip.content.audio.source_length_frames);
    try std.testing.expectEqual(@as(u64, 8), clip.content.audio.alternate_takes[0].?.source_length_frames);
    try std.testing.expectEqual(@as(u64, 8), clip.content.audio.alternate_takes[1].?.source_length_frames);
    history.doUndo(&app);
    try std.testing.expectEqual(@as(usize, 0), app.session.arrangement.lane(1).?.clips.items.len);
}

test "audio region gain and fades edit at arrangement cursor and undo" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    try app.session.arrangement.lane(0).?.place(app.allocator, ws.Clip.initAudio(0, 32, .{
        .source_id = 1,
        .source_start_frame = 0,
        .source_length_frames = 96_000,
    }));

    commands.run(&app, "clip-gain -6");
    commands.run(&app, "clip-fade 0.25 0.5");
    const audio = &app.session.arrangement.lane(0).?.clips.items[0].content.audio;
    try std.testing.expectApproxEqAbs(@as(f32, -6), audio.gain_db, 1e-6);
    try std.testing.expectEqual(@as(u64, 12_000), audio.fade_in_frames);
    try std.testing.expectEqual(@as(u64, 24_000), audio.fade_out_frames);

    history.doUndo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, -6), app.session.arrangement.lane(0).?.clips.items[0].content.audio.gain_db, 1e-6);
    try std.testing.expectEqual(@as(u64, 0), app.session.arrangement.lane(0).?.clips.items[0].content.audio.fade_in_frames);
    history.doUndo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, 0), app.session.arrangement.lane(0).?.clips.items[0].content.audio.gain_db, 1e-6);
}

test "consolidate renders audio region edits into a plain source" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    app.session.project.tempo_bpm = @as(f64, @floatFromInt(app.session.project.sample_rate)) * 60.0;
    app.session.engine.transport.tempo_bpm = app.session.project.tempo_bpm;
    const source_id = try app.session.project.addAudioSource("raw", app.session.project.sample_rate, 1, &.{ 0.1, 0.2 });
    try app.session.arrangement.lane(0).?.place(app.allocator, ws.Clip.initAudio(0, 64, .{
        .source_id = source_id,
        .source_start_frame = 0,
        .source_length_frames = 2,
        .reverse = true,
    }));

    commands.run(&app, "consolidate");
    const audio = app.session.arrangement.lane(0).?.clips.items[0].content.audio;
    const consolidated = app.session.project.audioSource(audio.source_id).?;
    try std.testing.expectEqualSlices(f32, &.{ 0.2, 0.1 }, consolidated.samples);
    try std.testing.expect(!audio.reverse);
    try std.testing.expectEqual(@as(f32, 1), audio.stretch_ratio);
}

test "comp splices a beat range from an alternate audio take" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    app.session.project.tempo_bpm = @as(f64, @floatFromInt(app.session.project.sample_rate)) * 60.0;
    app.session.engine.transport.tempo_bpm = app.session.project.tempo_bpm;
    const active_id = try app.session.project.addAudioSource("active", app.session.project.sample_rate, 1, &.{ 1, 1, 1, 1 });
    const alternate_id = try app.session.project.addAudioSource("alternate", app.session.project.sample_rate, 1, &.{ 2, 2, 2, 2 });
    try app.session.arrangement.lane(0).?.place(app.allocator, ws.Clip.initAudio(0, 64, .{
        .source_id = active_id,
        .source_start_frame = 0,
        .source_length_frames = 4,
        .alternate_takes = .{ .{ .source_id = alternate_id, .source_start_frame = 0, .source_length_frames = 4, .length_ticks = 64 }, null, null, null, null, null, null },
    }));

    commands.run(&app, "comp 2 1 3");
    const audio = app.session.arrangement.lane(0).?.clips.items[0].content.audio;
    const comp = app.session.project.audioSource(audio.source_id).?;
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 2, 1 }, comp.samples);
    history.doUndo(&app);
    try std.testing.expectEqual(active_id, app.session.arrangement.lane(0).?.clips.items[0].content.audio.source_id);
}

test "arrangement g plays from the cursor bar" {
    var app = try testApp();
    defer app.deinit();

    app.view = .arrangement;
    app.arr_cursor_bar = 2;
    app.handleKey(.{ .char = 'g' }, 0);
    app.handleKey(.{ .char = 's' }, 0);

    // Commands land on the audio thread; run one block to apply them.
    var block: [512]ws.types.Sample = undefined;
    app.session.engine.process(&block);
    // 120 bpm 4/4 at 48kHz → 96_000 frames per bar; the seek lands at bar 2
    // and the block advances 256 frames because playback started.
    try std.testing.expect(app.session.engine.transport.playing);
    try std.testing.expectEqual(@as(u64, 48_256), app.session.engine.transport.position_frames);
}

test "commands reject non-finite numbers, malformed signatures, and overflowing seeks" {
    var app = try testApp();
    defer app.deinit();

    const tempo = app.session.project.tempo_bpm;
    commands.run(&app, "bpm nan");
    try std.testing.expectEqual(tempo, app.session.project.tempo_bpm);

    const gain = app.session.project.tracks.items[0].gain_db;
    commands.run(&app, "gain 1 inf");
    try std.testing.expectEqual(gain, app.session.project.tracks.items[0].gain_db);

    const pan = app.session.project.tracks.items[0].pan;
    commands.run(&app, "pan 1 nan");
    try std.testing.expectEqual(pan, app.session.project.tracks.items[0].pan);

    // The send level is the one float this family used to parse without the
    // shared finite check; `nan` came through as a clamped +12dB send.
    commands.run(&app, "track-send 1 1 master nan");
    try std.testing.expect(app.session.project.tracks.items[0].sends[0] == null);

    const signature = app.session.project.beats_per_bar;
    commands.run(&app, "sig 3/4/4");
    try std.testing.expectEqual(signature, app.session.project.beats_per_bar);

    commands.run(&app, "seek 18446744073709551615");
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "too large") != null);

    commands.run(&app, "gain   1 -6");
    try std.testing.expectApproxEqAbs(@as(f32, -6.0), app.session.project.tracks.items[0].gain_db, 1e-6);
}

test "track gain and pan plus group gain round-trip through undo" {
    var app = try testApp();
    defer app.deinit();

    commands.run(&app, "gain 1 -6");
    try std.testing.expectApproxEqAbs(@as(f32, -6), app.session.project.tracks.items[0].gain_db, 1e-6);
    history.doUndo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, 0), app.session.project.tracks.items[0].gain_db, 1e-6);
    history.doRedo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, -6), app.session.project.tracks.items[0].gain_db, 1e-6);

    commands.run(&app, "pan 1 0.5");
    history.doUndo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, 0), app.session.project.tracks.items[0].pan, 1e-6);
    history.doRedo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), app.session.project.tracks.items[0].pan, 1e-6);

    const group = try app.session.addGroup("bus");
    commands.run(&app, "group-gain 1 -9");
    history.doUndo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, 0), app.session.groups[group].?.gain_db, 1e-6);
    history.doRedo(&app);
    try std.testing.expectApproxEqAbs(@as(f32, -9), app.session.groups[group].?.gain_db, 1e-6);
}

test "arrangement 0: jumps to bar 0 with no pending count, but continues a count otherwise (10l)" {
    var app = try testApp();
    defer app.deinit();

    app.view = .arrangement;

    // Bare '0' with no count pending: jump-to-start.
    app.arr_cursor_bar = 5;
    app.handleKey(.{ .char = '0' }, 0);
    try std.testing.expectEqual(@as(u32, 0), app.arr_cursor_bar);

    // '1' then '0' then 'l': should move by 10, not jump to bar 0 and then
    // move by the freshly-reset count of 1.
    app.arr_cursor_bar = 0;
    for ("10l") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u32, 10), app.arr_cursor_bar);
}

test "draw renders drum_grid view without overflowing" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.view = .drum_grid;
    app.session.project.beats_per_bar = 6;
    app.session.project.meter_denominator = 8;
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "DRUMS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "kick") != null);
    var plain_buf: [32 * 1024]u8 = undefined;
    const plain = ansi.stripAnsi(frame, &plain_buf);
    try std.testing.expect(std.mem.indexOf(u8, plain, "bars 2.67") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "          │ 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "│ 2") != null);
}

test "e opens drum-pad sampler editor from drum grid; esc returns" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.view = .drum_grid;
    app.drum_cursor = .{ 2, 0 };
    _ = drum_ed.handleKey(&app, .{ .char = 'e' });
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expect(app.sampler_target == .drum);

    _ = sampler_ed.handleKey(&app, .{ .char = 'j' });
    try std.testing.expectEqual(@as(u8, 1), app.sampler_param);
    _ = sampler_ed.handleKey(&app, .{ .char = '5' });
    try std.testing.expectEqual(@as(u8, 4), app.drum_cursor[0]);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
}

test "sampler editor j/k honor a vim count prefix; g/G jump to first/last param" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 1; // sampler
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expectEqual(@as(u8, 0), app.sampler_param);

    // Rows, not raw ids: the 4th row down from start is stretch (id 12),
    // which draws in the SAMPLE section despite its late id.
    for ("3j") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u8, 12), app.sampler_param);
    for ("2k") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u8, 1), app.sampler_param);

    app.handleKey(.{ .char = 'g' }, 0);
    app.handleKey(.{ .char = 'G' }, 0);
    try std.testing.expectEqual(@as(u8, ws.dsp.Sampler.param_count - 1), app.sampler_param);
    app.handleKey(.{ .char = 'g' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.sampler_param);
}

test "enter on a sampler track opens the standalone sampler editor" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 1; // sampler
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expect(app.sampler_target == .sampler);
    // esc returns to the tracks view (not the drum grid) for a standalone sampler.
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "draw renders drum machine control panel without overflowing" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.sampler_target = .{ .drum = 2 };
    app.drum_cursor = .{ 0, 0 };
    app.view = .sampler_editor;
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 30 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "DRUM MACHINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "PAD BANK 1/8") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "attack") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "j/k: param") != null);
}

test "draw renders slicer control panel without overflowing" {
    var app = try testApp();
    defer app.deinit();

    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.sampler_target = .{ .slice = 0 };
    app.view = .sampler_editor;
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 30 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SLICER") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "No audio loaded for this slicer.") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "SLICE MAP") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "enter: load") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "slice 1/0") == null);

    const sl = app.slicerInst();
    sl.samples = try app.allocator.alloc(f32, 8);
    @memset(sl.samples, 0);
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 30 });
    const unchopped = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, unchopped, "Audio loaded, but no slices exist.") != null);
    try std.testing.expect(std.mem.indexOf(u8, unchopped, "enter: chop view") != null);

    sl.sliceInto(3);
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 30 });
    const loaded = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, loaded, "SLICE MAP 1/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, loaded, "attack") != null);
    try std.testing.expect(std.mem.indexOf(u8, loaded, "j/k: param") != null);
}

test "empty sampler panel ignores hidden keyboard controls" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.sampler_target = .{ .slice = 0 };
    app.view = .sampler_editor;
    app.sampler_param = 2;

    _ = sampler_ed.handleKey(&app, .{ .char = 'j' });
    _ = sampler_ed.handleKey(&app, .{ .char = 'l' });
    _ = sampler_ed.handleKey(&app, .{ .char = 'a' });
    try std.testing.expectEqual(@as(u8, 2), app.sampler_param);
    try std.testing.expect(!app.dirty);

    app.slicerInst().samples = try app.allocator.alloc(f32, 8);
    @memset(app.slicerInst().samples, 0);
    _ = sampler_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expect(!app.dirty);
    _ = sampler_ed.handleKey(&app, .enter);
    try std.testing.expectEqual(AppView.slicer_grid, app.view);
    _ = slicer_ed.handleKey(&app, .enter);
    try std.testing.expect(!app.slicerInst().stepActive(0, 0));
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "no slices") != null);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    var plain_buf: [32 * 1024]u8 = undefined;
    const plain = ansi.stripAnsi(w.buffered(), &plain_buf);
    try std.testing.expect(std.mem.indexOf(u8, plain, "slice 1/0") == null);

    for ("nF$C") |c| _ = slicer_ed.handleKey(&app, .{ .char = c });
    try std.testing.expect(!app.dirty);
    app.slicerInst().sliceInto(1);
    try std.testing.expect(!app.slicerInst().stepActive(0, 0));
    try std.testing.expectEqual(@as(u16, 0), app.slicerInst().slice_len[0]);
    try std.testing.expectEqual(@as(u8, 1), app.slicerInst().choke_group[0]);
}

test "draw renders standalone sampler editor with root row" {
    var app = try testApp();
    defer app.deinit();

    app.sampler_target = .{ .sampler = 1 };
    app.view = .sampler_editor;
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 34 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SAMPLER") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "root") != null);
}

test "sampler/soundfont editors reach the FX chain and piano roll the way the synth editor does" {
    var app = try testApp();
    defer app.deinit();

    // Standalone sampler: s opens this track's chain, p its roll.
    app.sampler_target = .{ .sampler = 1 };
    app.view = .sampler_editor;
    app.handleKey(.{ .char = 's' }, 0);
    try std.testing.expectEqual(AppView.track_spectrum, app.view);
    try std.testing.expectEqual(@as(u16, 1), app.eq_track);

    app.view = .sampler_editor;
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expectEqual(@as(u16, 1), app.piano_track);

    // A drum pad's note editor is the step grid, so p lands there instead
    // of the roll; s still reaches the owning track's chain.
    app.sampler_target = .{ .drum = 2 };
    app.view = .sampler_editor;
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
    try std.testing.expectEqual(@as(u16, 2), app.drum_track);

    app.view = .sampler_editor;
    app.handleKey(.{ .char = 's' }, 0);
    try std.testing.expectEqual(AppView.track_spectrum, app.view);
    try std.testing.expectEqual(@as(u16, 2), app.eq_track);

    // Soundfont editor: the same two keys.
    try app.session.setInstrument(0, .soundfont);
    app.soundfont_track = 0;
    app.view = .soundfont_editor;
    app.handleKey(.{ .char = 's' }, 0);
    try std.testing.expectEqual(AppView.track_spectrum, app.view);
    try std.testing.expectEqual(@as(u16, 0), app.eq_track);

    app.view = .soundfont_editor;
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expectEqual(@as(u16, 0), app.piano_track);
}

test "drum-pad sampler param edit routes to the drum machine" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.sampler_target = .{ .drum = 2 };
    app.drum_cursor = .{ 0, 0 };
    app.sampler_param = 2; // pitch
    sampler_ed.adjustParam(&app, 5);
    var block: [128]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.racks.items[2].instrument.drum_machine.pads[0].?.pad.pitch_semitones > 0.0);
}

test "standalone sampler param edit routes to the sampler" {
    var app = try testApp();
    defer app.deinit();

    app.sampler_target = .{ .sampler = 1 };
    app.sampler_param = 2; // pitch
    sampler_ed.adjustParam(&app, 5);
    var block: [128]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.racks.items[1].instrument.sampler.pad.pitch_semitones > 0.0);
}

test "draw renders tracks view without overflowing" {
    var app = try testApp();
    defer app.deinit();
    defer icons.font_installed = false;

    var buf: [32 * 1024]u8 = undefined;

    // Nerd Font unavailable (the default): ascii mnemonics stand in for the
    // per-track instrument-kind icons, never the PUA glyphs themselves.
    icons.font_installed = false;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    var frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "TRACKS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "synth") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "drums") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, icons.synth) == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, icons.sampler) == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, icons.drum) == null);

    icons.font_installed = true;
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, icons.synth) != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, icons.sampler) != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, icons.drum) != null);
}

test "draw shows a dirty-flag warning icon in the header once edited" {
    var app = try testApp();
    defer app.deinit();
    defer icons.font_installed = false;
    icons.font_installed = true;

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.warn) == null);

    app.applyAction(.toggle_mute, 0);
    try std.testing.expect(app.dirty);
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.warn) != null);

    icons.font_installed = false;
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.warn) == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "*") != null);
}

test "transport indicator shows the unicode glyph without the font, the icon with it, never both" {
    var app = try testApp();
    defer app.deinit();
    var buf: [32 * 1024]u8 = undefined;
    defer icons.font_installed = false;

    icons.font_installed = false;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\u{25A0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.stop) == null);

    icons.font_installed = true;
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\u{25A0}") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.stop) != null);

    _ = app.session.engine.send(.play);
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);

    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\u{25BA}") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.play) != null);

    icons.font_installed = false;
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\u{25BA}") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.play) == null);
}

test "icons.detectFontInstalled reports false when the font isn't in the user's font dir" {
    // testApp()/App.init never call this (it needs a real std.Io, not the
    // std.Io.failing used by the fake IO in tests) - exercise it directly.
    try std.testing.expect(icons.detectFontInstalled(std.testing.io) == false);
}

test "blank track row shows the empty hint" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "enter: instrument") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "?: help") != null);
}

test "picker footers preserve mode, view identity, and live feedback" {
    var app = try testApp();
    defer app.deinit();
    var buf: [32 * 1024]u8 = undefined;

    const cases = [_]struct { view: AppView, label: []const u8 }{
        .{ .view = .instrument_picker, .label = "INSTRUMENT" },
        .{ .view = .fx_picker, .label = "EFFECT" },
        .{ .view = .preset_picker, .label = "PRESETS" },
    };
    for (cases) |case| {
        app.view = case.view;
        app.setStatus("picker feedback", .{});
        var w = std.Io.Writer.fixed(&buf);
        try tui_mod.draw(&app, &w, .{ .cols = 120, .rows = 24 });
        const frame = w.buffered();
        try std.testing.expect(std.mem.indexOf(u8, frame, case.label) != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "picker feedback") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "j/k: move") != null);
    }
}

test "tracks view progressively discloses row and footer actions" {
    var app = try testApp();
    defer app.deinit();
    var buf: [32 * 1024]u8 = undefined;

    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 24 });
    const track_frame = w.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, track_frame, "[enter:edit]"));
    try std.testing.expect(std.mem.indexOf(u8, track_frame, "p: piano  s: fx  m: mute") != null);

    app.setTrackRow(app.track_rows_len);
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 24 });
    const master_frame = w.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, master_frame, "[enter:fx]"));
    try std.testing.expect(std.mem.indexOf(u8, master_frame, "enter/s: fx  -/+: gain") != null);
}

test ":help opens on the current view's section; g jumps to COMMANDS; esc closes" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // Opened from the (default) tracks view: lands on TRACKS, not the top.
    for (":help") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.help, app.view);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "TRACKS") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "BASICS") != null);
    // Long entries are clamped by the renderer instead of relying on the
    // terminal to wrap them into unbudgeted rows.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "then MASTER last") == null);

    // g still jumps all the way back up to the command table.
    app.handleKey(.{ .char = 'g' }, 0);
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "COMMANDS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, ":bpm") != null);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "s key switches to track spectrum view" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    app.handleKey(.{ .char = 's' }, 0);
    try std.testing.expectEqual(AppView.track_spectrum, app.view);
}

test "m key switches to master spectrum view" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    app.handleKey(.{ .char = 'M' }, 0);
    try std.testing.expectEqual(AppView.master_spectrum, app.view);
}

test "spectrum view esc returns to tracks" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    app.handleKey(.{ .char = 's' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "draw renders spectrum view without errors" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.view = .master_spectrum;
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "FX CHAIN") != null);
    // A fresh chain explains both the direct path and how to insert.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "directly from IN to OUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "insert an effect") != null);
}

test "draw renders track_spectrum after pressing s" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.{ .char = 's' }, 0);
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "FX CHAIN") != null);
}

test "spectrum fills FFT buffer and draws with real data" {
    var app = try testApp();
    defer app.deinit();

    // The analyzer belongs to an EQ unit's editor - insert one and focus it.
    _ = try app.session.racks.items[0].fx.insert(
        // zig fmt: off
        app.session.allocator, 0, .eq, app.session.project.sample_rate,
        // zig fmt: on
    );
    app.handleKey(.{ .char = 's' }, 0);
    _ = app.session.engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    var block: [512]types.Sample = undefined;
    for (0..16) |_| app.session.engine.process(&block);

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 120, .rows = 40 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "SPECTRUM") != null);
}

test "track add inserts a blank track right after the cursor's track" {
    var app = try testApp();
    defer app.deinit();

    const initial_tracks = app.session.project.tracks.items.len;
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
    app.doTrackAdd("strings");

    try std.testing.expectEqual(initial_tracks + 1, app.session.project.tracks.items.len);
    try std.testing.expectEqual(initial_tracks + 1, app.session.racks.items.len);
    // Cursor started on track 0, so the new track lands at index 1, not
    // appended after the pre-existing tracks.
    try std.testing.expectEqualStrings("strings", app.session.project.tracks.items[1].name);
    try std.testing.expectEqual(InstrumentKind.empty, std.meta.activeTag(app.session.racks.items[1].instrument));
    try std.testing.expectEqual(@as(usize, 1), app.cursor);

    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(initial_tracks, app.session.project.tracks.items.len);

    app.handleKey(.{ .char = 'U' }, 0);
    try std.testing.expectEqual(initial_tracks + 1, app.session.project.tracks.items.len);
    try std.testing.expectEqualStrings("strings", app.session.project.tracks.items[1].name);
}

test "track delete removes the rack and shifts later tracks down" {
    var app = try testApp();
    defer app.deinit();

    const initial_tracks = app.session.project.tracks.items.len;
    app.doTrackDel(1); // remove the sampler

    try std.testing.expectEqual(initial_tracks - 1, app.session.project.tracks.items.len);
    try std.testing.expectEqual(initial_tracks - 1, app.session.racks.items.len);
    // The drum machine that was at index 2 is now index 1.
    try std.testing.expectEqual(InstrumentKind.drum_machine, std.meta.activeTag(app.session.racks.items[1].instrument));
}

test "structural track changes remap every editor-target field" {
    var app = try testApp();
    defer app.deinit();

    app.synth_track = 0;
    app.drum_track = 2;
    app.sampler_target = .{ .sampler = 1 };
    app.piano_clip_link = .{ .track = 2, .start_bar = 0 };

    // Insert at 1: everything from index 1 up shifts, index 0 stays put.
    app.remapTrackFields(.{ .insert = 1 });
    try std.testing.expectEqual(@as(u16, 0), app.synth_track);
    try std.testing.expectEqual(@as(u16, 3), app.drum_track);
    try std.testing.expectEqual(@as(u16, 2), app.sampler_target.sampler);
    try std.testing.expectEqual(@as(u16, 3), app.piano_clip_link.?.track);

    // A swap exchanges only the two indices it names.
    app.remapTrackFields(.{ .swap = .{ .a = 0, .b = 3 } });
    try std.testing.expectEqual(@as(u16, 3), app.synth_track);
    try std.testing.expectEqual(@as(u16, 0), app.drum_track);
    try std.testing.expectEqual(@as(u16, 0), app.piano_clip_link.?.track);

    app.note_offs[0] = .{ .at_ns = 0, .track = 0, .note = 60 };
    app.note_offs[1] = .{ .at_ns = 0, .track = 2, .note = 64 };
    app.note_off_len = 2;

    // Deleting track 0 bounces the field naming it out of range, drops the
    // clip link and the note-off on it, and shifts every survivor down.
    app.remapTrackFields(.{ .delete = 0 });
    try std.testing.expectEqual(@as(u16, 2), app.synth_track);
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), app.drum_track);
    try std.testing.expectEqual(@as(u16, 1), app.sampler_target.sampler);
    try std.testing.expect(app.piano_clip_link == null);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
    try std.testing.expectEqual(@as(u7, 64), app.note_offs[0].note);
    try std.testing.expectEqual(@as(u16, 1), app.note_offs[0].track);

    // The sentinel names no track, so a later op leaves it where it is
    // rather than shifting (and overflowing) it.
    app.remapTrackFields(.{ .insert = 0 });
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), app.drum_track);
}

test "track delete remaps a surviving track's undo entry instead of wiping history" {
    var app = try testApp();
    defer app.deinit();

    // Capture the drum machine at track 2 (factory pattern), then toggle a
    // step so it diverges from the captured "before" state.
    const before = app.session.racks.items[2].instrument.drum_machine.variantData(0).midi[0][0];
    history.push(&app, history.captureDrum(&app, 2));
    app.session.racks.items[2].instrument.drum_machine.toggleStep(0, 0);
    try std.testing.expect(!std.meta.eql(app.session.racks.items[2].instrument.drum_machine.variantData(
        app.session.racks.items[2].instrument.drum_machine.variant,
    ).midi[0][0], before));

    // Delete track 0 (the synth): track 2's drum machine shifts to index 1,
    // and the undo entry should follow it rather than the history getting
    // wiped or the entry pointing at the wrong (now-track-1) sampler. The
    // delete itself also pushes its own (whole-track) undo entry on top.
    app.doTrackDel(0);
    try std.testing.expectEqual(@as(usize, 2), app.history.undo_stack.items.len);
    try std.testing.expectEqual(@as(u16, 1), app.history.undo_stack.items[0].drum.track);

    // First undo pops the most recent push: the delete itself, restoring
    // track 0. The surviving drum entry should follow the drum machine
    // back to its original index once track 0 reappears.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(u16, 2), app.history.undo_stack.items[0].drum.track);

    // Second undo reverts the drum toggle itself.
    app.handleKey(.{ .char = 'u' }, 0);
    const dm = &app.session.racks.items[2].instrument.drum_machine;
    try std.testing.expect(std.meta.eql(before, dm.variantData(dm.variant).midi[0][0]));
}

test "track delete drops an undo entry that named the deleted track" {
    var app = try testApp();
    defer app.deinit();

    const before = app.session.racks.items[2].instrument.drum_machine.variantData(0).midi[0][0];
    history.push(&app, history.captureDrum(&app, 2));
    app.session.racks.items[2].instrument.drum_machine.toggleStep(0, 0);

    // Delete track 2 itself: the entry it named is gone, not remapped onto
    // a different surviving track - but the delete pushes its own
    // whole-track undo entry, so the stack isn't left empty.
    app.doTrackDel(2);
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "1 undo entries for it cleared") != null);

    // Undo restores track 2 exactly as it was at delete time (including
    // the toggle), independent of the dropped fine-grained entry.
    app.handleKey(.{ .char = 'u' }, 0);
    const dm = &app.session.racks.items[2].instrument.drum_machine;
    try std.testing.expect(!std.meta.eql(dm.variantData(dm.variant).midi[0][0], before));
}

test "track delete remaps a still-open FX nudge batch, including the entry it flushes" {
    var app = try testApp();
    defer app.deinit();

    // Open an FX param-nudge batch on track 2's chain.
    _ = try app.session.racks.items[2].fx.insert(
        // zig fmt: off
        app.session.allocator, 0, .comp, app.session.project.sample_rate,
        // zig fmt: on
    );
    app.eq_track = 2;
    history.noteFxNudge(&app, .track, 0, 0);
    try std.testing.expect(app.pending_fx_nudge != null);

    // Delete track 0 while the batch is still open (`:track-del` is
    // reachable from inside the FX editor without a flush): the chain
    // shifts to index 1 and the batch must follow - including the target
    // embedded in the snapshot it eventually flushes, not just its own.
    app.doTrackDel(0);
    history.flushFxNudge(&app);
    // The delete pushes its own whole-track undo entry first; the flushed
    // FX entry lands on top of it.
    try std.testing.expectEqual(@as(usize, 2), app.history.undo_stack.items.len);
    try std.testing.expectEqual(@as(u16, 1), app.history.undo_stack.items[1].fx.target.track);
}

test ":track-instrument pushes an undo entry that restores the old instrument and notes" {
    var app = try testApp();
    defer app.deinit();

    // Track 0 is poly_synth (see testApp). Give it a note so the swap's
    // "notes kept" claim (melodic-to-melodic) is actually checkable.
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });

    app.cursor = 0;
    for (":track-instrument sampler") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[0].instrument));
    try std.testing.expectEqual(@as(u16, 1), app.session.racks.items[0].pattern_player.?.note_count);
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);

    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(InstrumentKind.poly_synth, std.meta.activeTag(app.session.racks.items[0].instrument));
    try std.testing.expectEqual(@as(u16, 1), app.session.racks.items[0].pattern_player.?.note_count);
    try std.testing.expectEqual(@as(u7, 60), app.session.racks.items[0].pattern_player.?.notes[0].pitch);
    try std.testing.expectEqual(@as(usize, 0), app.history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.history.redo_stack.items.len);

    app.handleKey(.{ .char = 'U' }, 0); // redo
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[0].instrument));
    try std.testing.expectEqual(@as(u16, 1), app.session.racks.items[0].pattern_player.?.note_count);
}

test ":track-instrument undo recovers a clip cleared by an incompatible-mapping swap" {
    var app = try testApp();
    defer app.deinit();

    // Track 0 is poly_synth; stamp a clip so there's arrangement data at
    // stake, not just the live pattern.
    app.session.racks.items[0].pattern_player.?.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    try app.session.stampClip(0, 0);
    try std.testing.expectEqual(@as(usize, 1), app.session.arrangement.lane(0).?.clips.items.len);

    app.cursor = 0;
    for (":track-instrument slicer") |c| app.handleKey(.{ .char = c }, 0); // no compatible mapping
    app.handleKey(.enter, 0);

    try std.testing.expectEqual(InstrumentKind.slicer, std.meta.activeTag(app.session.racks.items[0].instrument));
    try std.testing.expectEqual(@as(usize, 0), app.session.arrangement.lane(0).?.clips.items.len);

    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(InstrumentKind.poly_synth, std.meta.activeTag(app.session.racks.items[0].instrument));
    try std.testing.expectEqual(@as(usize, 1), app.session.arrangement.lane(0).?.clips.items.len);
}

test ":track-instrument <n> <kind> targets track n, leaving the cursor track alone" {
    var app = try testApp();
    defer app.deinit();

    // Cursor sits on track 0 (synth); target track 2 (drum_machine) by
    // number instead - mirrors :rename's "[<n>] <name>" shape.
    app.cursor = 0;
    for (":track-instrument 2 sampler") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    try std.testing.expectEqual(InstrumentKind.poly_synth, std.meta.activeTag(app.session.racks.items[0].instrument));
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[1].instrument));
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
}

test "track delete pushes its own undo entry that fully restores the track" {
    var app = try testApp();
    defer app.deinit();

    // Distinguishing fields on the sampler track so restore can be checked
    // field-by-field, not just "a track reappeared".
    app.session.project.tracks.items[1].gain_db = -6.0;
    app.session.project.tracks.items[1].color = 3;

    app.doTrackDel(1); // the sampler
    try std.testing.expectEqual(@as(usize, 2), app.session.project.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);

    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(usize, 3), app.session.project.tracks.items.len);
    try std.testing.expectEqualStrings("samp", app.session.project.tracks.items[1].name);
    try std.testing.expectEqual(@as(f32, -6.0), app.session.project.tracks.items[1].gain_db);
    try std.testing.expectEqual(@as(u8, 3), app.session.project.tracks.items[1].color);
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[1].instrument));
    try std.testing.expectEqual(@as(usize, 0), app.history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.history.redo_stack.items.len);

    // Redo deletes it again.
    app.handleKey(.{ .char = 'U' }, 0);
    try std.testing.expectEqual(@as(usize, 2), app.session.project.tracks.items.len);
    try std.testing.expectEqual(InstrumentKind.drum_machine, std.meta.activeTag(app.session.racks.items[1].instrument));
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.history.redo_stack.items.len);

    // Undo again brings it right back.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(usize, 3), app.session.project.tracks.items.len);
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[1].instrument));
}

test "track delete undo entries stay correctly ordered across two deletes and two undos" {
    var app = try testApp();
    defer app.deinit();

    // Delete track 0 (synth), then track 0 again (was the sampler, now
    // shifted down to index 0) - two whole-track undo entries stack up.
    app.doTrackDel(0);
    app.doTrackDel(0);
    try std.testing.expectEqual(@as(usize, 1), app.session.project.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.history.undo_stack.items.len);

    // First undo restores the sampler (the most recent delete) at index 0.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(usize, 2), app.session.project.tracks.items.len);
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[0].instrument));

    // Second undo restores the synth back at index 0, pushing the sampler
    // to index 1 - the still-pending track_insert entry for the synth must
    // have followed the sampler's earlier restore (an .insert remap on an
    // insertion-point entry, not a live-track one) to land at the right slot.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(usize, 3), app.session.project.tracks.items.len);
    try std.testing.expectEqual(InstrumentKind.poly_synth, std.meta.activeTag(app.session.racks.items[0].instrument));
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[1].instrument));
    try std.testing.expectEqual(InstrumentKind.drum_machine, std.meta.activeTag(app.session.racks.items[2].instrument));
}

test "track delete undo and redo emit committed Lua track events" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;
    try rt.loadString(
        "events = {}; " ++
            "wstudio.api.create_autocmd('TrackAdd', { callback = function(ev) events[#events + 1] = 'add:' .. ev.track .. ':' .. wstudio.api.track_get(ev.track).kind end }); " ++
            "wstudio.api.create_autocmd('TrackDel', { callback = function(ev) events[#events + 1] = 'del:' .. ev.track end })",
    );

    app.doTrackDel(1);
    app.handleKey(.{ .char = 'u' }, 0);
    app.handleKey(.{ .char = 'U' }, 0);

    try rt.loadString("assert(#events == 3); assert(events[1] == 'del:2'); assert(events[2] == 'add:2:sampler', events[2]); assert(events[3] == 'del:2')");
}

test "track delete shifts slicer_track like every other editor-target index" {
    var app = try testApp();
    defer app.deinit();

    // A slicer at track 3, open in the slicer grid.
    _ = try app.session.addTrack("chop");
    try app.session.setInstrument(3, .slicer);
    app.slicer_track = 3;
    app.view = .slicer_grid;

    // `:track-del 1` is reachable from inside the grid - the slicer shifts
    // to index 2 and the open grid must follow it.
    app.doTrackDel(0);
    try std.testing.expectEqual(@as(u16, 2), app.slicer_track);
    try std.testing.expectEqual(AppView.slicer_grid, app.view);
}

test "track delete re-heals the row cursor when the row list reshapes under an unchanged cursor" {
    var app = try testApp();
    defer app.deinit();

    // Group tracks 0 and 2: rows are [G, t0, t2, t1] (the group row sits at
    // its first member's position, members follow, t1 trails).
    const g = try app.session.addGroup("bus");
    app.session.assignTrackGroup(0, g);
    app.session.assignTrackGroup(2, g);
    app.tracksRowSync();
    app.setTrackRow(3); // the ungrouped t1, on the last row
    try std.testing.expectEqual(@as(usize, 1), app.cursor);

    // Deleting track 0 keeps cursor == 1 (now the old track 2, still in the
    // group) but reshapes the rows to [t0', G, t1'] - without a forced
    // re-heal the row cursor would sit clamped on the master row while
    // `cursor` names a real track.
    app.doTrackDel(0);
    app.tracksRowSync();
    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    try std.testing.expectEqual(@as(usize, 2), app.track_row);
    try std.testing.expectEqual(@as(?u16, 1), app.cursorTrack());
}

test "dd on a group row lands the row cursor on the row that takes its place" {
    var app = try testApp();
    defer app.deinit();

    // Group track 1: rows are [t0, G, t1, t2].
    const g = try app.session.addGroup("bus");
    app.session.assignTrackGroup(1, g);
    app.tracksRowSync();
    app.setTrackRow(1); // the group row; cursor parks on the master sentinel
    try std.testing.expectEqual(@as(usize, 3), app.cursor);

    // dd deletes the group; its former member's row takes its place and the
    // cursor must re-mirror from it instead of staying on the sentinel.
    app.handleKey(.{ .char = 'd' }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(@as(?u8, null), app.session.project.tracks.items[1].group);
    try std.testing.expectEqual(@as(usize, 1), app.track_row);
    try std.testing.expectEqual(@as(usize, 1), app.cursor);
}

test "a on a group row (or a member) adds the new track into that group" {
    var app = try testApp();
    defer app.deinit();

    // Rows are [t0, G, t1, t2].
    const g = try app.session.addGroup("bus");
    app.session.assignTrackGroup(1, g);
    app.tracksRowSync();

    app.setTrackRow(1); // the group's own row
    app.handleKey(.{ .char = 'a' }, 0);
    try std.testing.expectEqual(@as(?u8, g), app.session.project.tracks.items[app.cursor].group);

    // From a member row too - otherwise the only way in is :track-group.
    app.tracksRowSync();
    app.handleKey(.{ .char = 'a' }, 0);
    try std.testing.expectEqual(@as(?u8, g), app.session.project.tracks.items[app.cursor].group);

    // An ungrouped row still adds an ungrouped track.
    app.setTrackRow(0);
    app.handleKey(.{ .char = 'a' }, 0);
    try std.testing.expectEqual(@as(?u8, null), app.session.project.tracks.items[app.cursor].group);
}

test "J/K moves a track across a group folder and keeps its row cursor in sync" {
    var app = try testApp();
    defer app.deinit();
    _ = try app.session.addTrack("t3");
    try app.session.setInstrument(3, .poly_synth);

    const g = try app.session.addGroup("bus");
    app.session.assignTrackGroup(1, g);
    app.session.assignTrackGroup(3, g);
    app.tracksRowSync();
    // Folder order is [t0, G, t1, t3, t2]. Moving t2 up crosses the
    // entire folder, leaving it immediately before the group rather than
    // with a stale row cursor inside the reshaped list.
    app.setTrackRow(4); // t2
    app.handleKey(.{ .char = 'K' }, 0);
    app.tracksRowSync();

    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.track_row);
    try std.testing.expectEqual(@as(?u16, 1), app.cursorTrack());
    try std.testing.expectEqual(@as(u16, 0), app.track_rows_buf[0].track);
    try std.testing.expectEqual(@as(u16, 1), app.track_rows_buf[1].track);
    try std.testing.expectEqual(g, app.track_rows_buf[2].group);
    try std.testing.expectEqual(@as(u16, 2), app.track_rows_buf[3].track);
    try std.testing.expectEqual(@as(u16, 3), app.track_rows_buf[4].track);

    // Moving back down restores both the backing track order and the
    // folder's original display position.
    app.handleKey(.{ .char = 'J' }, 0);
    app.tracksRowSync();
    try std.testing.expectEqual(@as(usize, 2), app.cursor);
    try std.testing.expectEqual(@as(usize, 4), app.track_row);
    try std.testing.expectEqual(@as(?u16, 2), app.cursorTrack());
    try std.testing.expectEqual(@as(u16, 0), app.track_rows_buf[0].track);
    try std.testing.expectEqual(g, app.track_rows_buf[1].group);
    try std.testing.expectEqual(@as(u16, 1), app.track_rows_buf[2].track);
    try std.testing.expectEqual(@as(u16, 3), app.track_rows_buf[3].track);
    try std.testing.expectEqual(@as(u16, 2), app.track_rows_buf[4].track);
}

test "track delete shifts the automation editor's clip link and track with it" {
    var app = try testApp();
    defer app.deinit();

    // Automation editor open on a clip in track 2's lane.
    try app.session.stampClip(2, 0);
    automation_ed.switchTo(&app, 2, 0);
    try std.testing.expectEqual(AppView.automation, app.view);

    // `:track-del 1` is reachable from inside the editor. Track 2's lane
    // shifts to index 1; the link must follow it - a stale link would
    // resolve against the OLD index and silently edit another track's clip.
    app.doTrackDel(0);
    try std.testing.expectEqual(@as(u16, 1), app.automation_clip.?.track);
    try std.testing.expectEqual(@as(u16, 1), app.automation_track);
    try std.testing.expect(automation_ed.currentClip(&app) != null);

    // Deleting the automated track itself drops the link (and the view).
    app.doTrackDel(1);
    try std.testing.expect(app.automation_clip == null);
    try std.testing.expectEqual(AppView.arrangement, app.view);
}

test "track delete/move remap pending qwerty note-offs so held notes still stop" {
    var app = try testApp();
    defer app.deinit();

    // A note sounding on track 2 with its note-off scheduled in the future,
    // plus one on track 0 (the track about to be deleted).
    app.playNote(2, 60, 0);
    app.playNote(0, 40, 0);
    try std.testing.expectEqual(@as(usize, 2), app.note_off_len);

    // Deleting track 0 drops its pending off and shifts track 2's to 1.
    app.doTrackDel(0);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
    try std.testing.expectEqual(@as(u16, 1), app.note_offs[0].track);

    // J/K swap follows the note too.
    app.cursor = 1;
    app.handleKey(.{ .char = 'K' }, 0);
    try std.testing.expectEqual(@as(u16, 0), app.note_offs[0].track);
}

test "session swap resets view, editor targets, and undo history" {
    var app = try testApp();
    defer app.deinit();

    // Editor open on the drum machine at track 2, with session-scoped
    // state an :e reload must not carry over: an undo snapshot of THIS
    // session's content, a pending note-off, a clip link.
    app.view = .drum_grid;
    app.drum_track = 2;
    history.push(&app, history.captureDrum(&app, 2));
    app.playNote(2, 60, 0);
    app.piano_clip_link = .{ .track = 2, .start_bar = 0 };
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);

    // Shared half of the swap run() performs for :e/:new. Frontends only
    // stop and restart their audio/MIDI backends around these two calls.
    app.pending_reload = .blank;
    const prepared = app.preparePendingReload() orelse return error.TestUnexpectedResult;
    app.installPreparedReload(prepared);

    // The old project's undo entries must not apply to the new one, the
    // drum grid must not draw with a stale (here out-of-range) target.
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expectEqual(@as(usize, 0), app.history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.note_off_len);
    try std.testing.expectEqual(@as(u16, 0), app.drum_track);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
    try std.testing.expect(app.piano_clip_link == null);
    try std.testing.expect(app.projectPath() == null);
    try std.testing.expectEqualStrings("new project", app.status_buf[0..app.status_len]);
}

test "track add/delete/move remap the preset picker's target track" {
    var app = try testApp();
    defer app.deinit();

    // Picker open over the drum machine at track 2; the track list can
    // still change under it (`:` commands, Lua api) while it's up.
    preset_ed.open(&app, .drum, 2);

    // Insert at 1 shifts the drum machine to 3.
    app.cursor = 0;
    app.doTrackAdd(null);
    try std.testing.expectEqual(@as(u16, 3), app.preset_picker_track);

    // Deleting track 0 shifts it back down to 2; the picker survives
    // because its target still holds a drum machine.
    app.doTrackDel(0);
    try std.testing.expectEqual(@as(u16, 2), app.preset_picker_track);
    try std.testing.expectEqual(AppView.preset_picker, app.view);

    // Swapping the target with its neighbor follows it too.
    app.cursor = 2;
    app.doTrackMove(-1);
    try std.testing.expectEqual(@as(u16, 1), app.preset_picker_track);
}

test "J/K track swap remaps an undo entry to follow the moved track" {
    var app = try testApp();
    defer app.deinit();

    // Capture and edit the drum machine at track 2.
    const before = app.session.racks.items[2].instrument.drum_machine.variantData(0).midi[0][0];
    history.push(&app, history.captureDrum(&app, 2));
    app.session.racks.items[2].instrument.drum_machine.toggleStep(0, 0);

    app.cursor = 2; // the drum machine
    app.handleKey(.{ .char = 'K' }, 0); // swap up with the sampler at index 1

    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);
    try std.testing.expectEqual(@as(u16, 1), app.history.undo_stack.items[0].drum.track);

    app.handleKey(.{ .char = 'u' }, 0);
    const dm = &app.session.racks.items[1].instrument.drum_machine;
    try std.testing.expect(std.meta.eql(before, dm.variantData(dm.variant).midi[0][0]));
}

test "Y duplicates the selected track and jumps the cursor to the copy" {
    var app = try testApp();
    defer app.deinit();

    const initial_tracks = app.session.project.tracks.items.len;
    app.cursor = 1; // the sampler
    app.handleKey(.{ .char = 'Y' }, 0);

    try std.testing.expectEqual(initial_tracks + 1, app.session.project.tracks.items.len);
    const last = app.session.racks.items.len - 1;
    try std.testing.expectEqual(@as(usize, last), app.cursor);
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[last].instrument));
    try std.testing.expect(app.dirty);
}

test "J/K swap the selected track with its neighbor and follow the cursor" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 1; // the sampler
    app.handleKey(.{ .char = 'J' }, 0); // swap with the drum machine at 2

    try std.testing.expectEqual(@as(usize, 2), app.cursor);
    try std.testing.expectEqual(InstrumentKind.drum_machine, std.meta.activeTag(app.session.racks.items[1].instrument));
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[2].instrument));

    app.handleKey(.{ .char = 'K' }, 0); // swap back up

    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[1].instrument));
    try std.testing.expectEqual(InstrumentKind.drum_machine, std.meta.activeTag(app.session.racks.items[2].instrument));

    // Moving the first track up, or the last track down, is a no-op.
    app.cursor = 0;
    app.handleKey(.{ .char = 'K' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
}

test "[/] cycle the cursor track's color, wrapping through none" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 0;
    // Tracks auto-color themselves on creation now; start from a known
    // baseline ("none") rather than asserting what that auto-assigned
    // color happens to be.
    app.session.project.tracks.items[0].color = 0;

    try std.testing.expectEqual(@as(u8, 0), app.session.project.tracks.items[0].color);
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 1), app.session.project.tracks.items[0].color);
    try std.testing.expect(app.dirty);

    // Cycle all the way around: 16 colors + "none" = 17 states total.
    for (0..16) |_| app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.session.project.tracks.items[0].color);

    // Backward wraps the other way, straight to the last color.
    app.handleKey(.{ .char = '[' }, 0);
    try std.testing.expectEqual(@as(u8, 16), app.session.project.tracks.items[0].color);

    // Invalid state still cycles into the supported range instead of
    // indexing past the color-name table while building the status.
    app.session.project.tracks.items[0].color = 255;
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 1), app.session.project.tracks.items[0].color);

    // The master row has no color to cycle.
    app.cursor = app.session.project.tracks.items.len;
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "n/a") != null);
}

test "tracks visual mode: v/j selects a range and g creates an untitled group" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();
    app.cursor = 0;

    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    app.handleKey(.{ .char = 'j' }, 0); // extend to track 1 - selection is [0,1]

    app.handleKey(.{ .char = 'g' }, 0);

    // Both selected tracks joined the same new group; track 2 didn't.
    const g = app.session.project.tracks.items[0].group.?;
    try std.testing.expectEqual(g, app.session.project.tracks.items[1].group.?);
    try std.testing.expectEqual(@as(?u8, null), app.session.project.tracks.items[2].group);
    try std.testing.expect(app.session.groups[g] != null);
    try std.testing.expectEqualStrings("untitled group", app.session.groups[g].?.name);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
}

test "tracks visual mode: esc cancels; master row can't enter it" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 0;
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(app.tracks_visual_anchor == null);

    app.cursor = app.session.project.tracks.items.len; // master
    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "n/a") != null);
}

test "tracks visual mode supports counts, endpoints, and anchor swap" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 0;

    app.handleKey(.{ .char = 'V' }, 0);
    for ("2j") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(usize, 2), app.track_row);
    try std.testing.expectEqual(@as(?usize, 0), app.tracks_visual_anchor);

    app.handleKey(.{ .char = 'o' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.track_row);
    try std.testing.expectEqual(@as(?usize, 2), app.tracks_visual_anchor);
    app.handleKey(.{ .char = 'G' }, 0);
    try std.testing.expectEqual(app.track_rows_len - 1, app.track_row);
    app.handleKey(.{ .char = '0' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.track_row);
}

test ":group-add/:rename/:group-del/:track-group/:group-fx" {
    var app = try testApp();
    defer app.deinit();

    for (":group-add") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("untitled group", app.session.groups[0].?.name);

    for (":track-group 3 1") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(?u8, 0), app.session.project.tracks.items[2].group);

    // :rename only reaches the group by number while the cursor sits on
    // some row - a fresh, memberless group has none, so a member has to
    // be assigned (just above) before it's addressable at all.
    app.tracksRowSync();
    const group_row = for (app.trackRows(), 0..) |r, i| {
        if (std.meta.activeTag(r) == .group) break i;
    } else unreachable;
    app.setTrackRow(group_row);
    for (":rename 1 drum bus") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("drum bus", app.session.groups[0].?.name);

    for (":group-fx 1") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.group_spectrum, app.view);
    try std.testing.expectEqual(@as(u8, 0), app.eq_group);
    app.handleKey(.escape, 0);

    for (":track-group 3 none") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(?u8, null), app.session.project.tracks.items[2].group);

    for (":group-del 1") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.session.groups[0] == null);
}

test "c toggles the click track" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.{ .char = 'c' }, 0);
    try std.testing.expect(app.session.metronome_enabled);
    app.handleKey(.{ .char = 'c' }, 0);
    try std.testing.expect(!app.session.metronome_enabled);
}

test ":metronome toggles, and on/off set it explicitly" {
    var app = try testApp();
    defer app.deinit();

    for (":metronome") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.session.metronome_enabled);

    for (":metronome off") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(!app.session.metronome_enabled);

    for (":metronome on") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.session.metronome_enabled);
}

test "on/off commands reject invalid values without changing state" {
    var app = try testApp();
    defer app.deinit();

    commands.run(&app, "metronome maybe");
    try std.testing.expect(!app.session.metronome_enabled);
    try std.testing.expectEqualStrings("metronome: expected on or off (omit value to toggle)", app.status_buf[0..app.status_len]);

    commands.run(&app, "punch maybe");
    try std.testing.expect(!app.punch_enabled);
    try std.testing.expectEqualStrings("punch: expected on or off (omit value to toggle)", app.status_buf[0..app.status_len]);

    commands.run(&app, "ghost maybe");
    try std.testing.expect(!app.piano_ghost);
    try std.testing.expectEqualStrings("ghost: expected on or off (omit value to toggle)", app.status_buf[0..app.status_len]);

    commands.run(&app, "audition maybe");
    try std.testing.expect(!app.piano_audition);
    try std.testing.expectEqualStrings("audition: expected on or off (omit value to toggle)", app.status_buf[0..app.status_len]);
}

test ":punch requires A/B bounds and gates recording to their frame range" {
    var app = try testApp();
    defer app.deinit();

    for (":punch on") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(!app.punch_enabled);

    app.session.project.loop_start_bar = 1;
    app.session.project.loop_end_bar = 3;
    app.session.project.loop_enabled = true;
    for (":punch on") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.punch_enabled);

    const fpb = app.session.project.framesPerBar();
    try std.testing.expect(!app.recordingPositionAllowed(fpb - 1));
    try std.testing.expect(app.recordingPositionAllowed(fpb));
    try std.testing.expect(app.recordingPositionAllowed(3 * fpb - 1));
    try std.testing.expect(!app.recordingPositionAllowed(3 * fpb));

    _ = app.session.engine.send(.play);
    _ = app.session.engine.send(.{ .seek_frames = fpb - 128 });
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    const initial_notes = app.session.racks.items[0].pattern_player.?.note_count;
    piano_ed.recordNote(&app, 60, 1);
    try std.testing.expectEqual(initial_notes, app.session.racks.items[0].pattern_player.?.note_count);

    _ = app.session.engine.send(.{ .seek_frames = fpb });
    app.session.engine.process(&block);
    piano_ed.recordNote(&app, 61, 1);
    try std.testing.expectEqual(initial_notes + 1, app.session.racks.items[0].pattern_player.?.note_count);

    _ = app.session.engine.send(.{ .seek_frames = 3 * fpb });
    app.session.engine.process(&block);
    piano_ed.recordNote(&app, 62, 1);
    try std.testing.expectEqual(initial_notes + 1, app.session.racks.items[0].pattern_player.?.note_count);
}

test ":monitor selects persistent input monitoring modes" {
    var app = try testApp();
    defer app.deinit();

    commands.run(&app, "monitor off");
    try std.testing.expectEqual(app_mod.InputMonitor.off, app.input_monitor);
    commands.run(&app, "monitor auto");
    try std.testing.expectEqual(app_mod.InputMonitor.auto, app.input_monitor);
    commands.run(&app, "monitor bogus");
    try std.testing.expectEqual(app_mod.InputMonitor.auto, app.input_monitor);
    try std.testing.expectEqualStrings("monitor: expected off, auto, or on", app.status_buf[0..app.status_len]);
}

test "shared MIDI note routing records only in insert-mode editor views" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    _ = app.session.engine.send(.play);
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);

    const pp = &app.session.racks.items[0].pattern_player.?;
    const before = pp.note_count;
    app.recordMidiNote(72, 64);
    try std.testing.expectEqual(before, pp.note_count);

    app.modal.mode = .insert;
    app.recordMidiNote(72, 64);
    try std.testing.expectEqual(before + 1, pp.note_count);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0 / 127.0), pp.notes[pp.note_count - 1].velocity, 1e-6);
}

test ":signature sets beats per bar and reshapes bar math" {
    var app = try testApp();
    defer app.deinit();

    for (":signature 3") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u8, 3), app.session.project.beats_per_bar);

    // The transport mirrors it once the audio thread drains the command.
    var block: [512]ws.types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expectEqual(@as(u8, 3), app.session.engine.transport.time_signature.beats_per_bar);

    // A 32-step (8-beat) drum pattern now spans 3 bars of 3/4 when stamped
    // (8 beats doesn't divide evenly into 3-beat bars, so it rounds up).
    try app.session.stampClip(2, 0);
    const clip = app.session.arrangement.lane(2).?.clips.items[0];
    try std.testing.expectEqual(@as(u32, 288), clip.length_ticks);

    // Denominator changes propagate too.
    for (":signature 3/8") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u8, 3), app.session.project.beats_per_bar);
    try std.testing.expectEqual(@as(u8, 8), app.session.project.meter_denominator);
    for (":signature 3/7") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u8, 8), app.session.project.meter_denominator);
}

test "tempo and meter point commands update project and transport maps" {
    var app = try testApp();
    defer app.deinit();
    commands.run(&app, "tempo-point 4 60 ramp");
    commands.run(&app, "tempo-point 8 120 step");
    commands.run(&app, "meter-point 8 6/8");
    var block: [512]ws.types.Sample = undefined;
    app.session.engine.process(&block);

    try std.testing.expectEqual(@as(usize, 2), app.session.project.tempo_points.items.len);
    try std.testing.expectEqual(@as(u8, 2), app.session.engine.transport.tempo_point_count);
    try std.testing.expectEqual(@as(u8, 8), app.session.project.meter_points.items[0].denominator);
    try std.testing.expectEqual(@as(u8, 1), app.session.engine.transport.meter_point_count);
    const at_seven = app.session.project.secondsAtBeat(7);
    try std.testing.expectApproxEqAbs(@as(f64, 7), app.session.engine.transport.beatsAtFrames(app.session.project.framesAtBeat(7)), 0.001);
    try std.testing.expect(at_seven > app.session.project.secondsAtBeat(6));
}

test ":track-add command adds a blank track right after the cursor's track" {
    var app = try testApp();
    defer app.deinit();

    const before = app.session.project.tracks.items.len;
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
    for (":track-add mytrack") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(before + 1, app.session.project.tracks.items.len);
    try std.testing.expectEqualStrings("mytrack", app.session.project.tracks.items[1].name);
    try std.testing.expectEqualStrings("samp", app.session.project.tracks.items[2].name);
    try std.testing.expectEqualStrings("drums", app.session.project.tracks.items[3].name);
}

test ":track-del command deletes a track" {
    var app = try testApp();
    defer app.deinit();

    const before = app.session.project.tracks.items.len;
    for (":track-del 1") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(before - 1, app.session.project.tracks.items.len);
}

test ":rename <n> <name> renames a track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":rename 1 renamed") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("renamed", app.session.project.tracks.items[0].name);
}

test ":rename with no track number renames the cursor track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    _ = try app.session.addTrack("second");
    app.cursor = 1;

    for (":rename bass") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("untitled track", app.session.project.tracks.items[0].name);
    try std.testing.expectEqualStrings("bass", app.session.project.tracks.items[1].name);

    // A single bare number is still a missing-<name> error, not a rename
    // to that numeral - the same lone-index usage that already errored.
    for (":rename 3") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("bass", app.session.project.tracks.items[1].name);
}

test ":gain/:pan with no args at all report the cursor track" {
    // Only the fully-argless form falls back to the cursor track - a single
    // token (":gain -6") still means an explicit track number as before,
    // since a bare number is genuinely ambiguous between "which track" and
    // "what value for the cursor track" and guessing wrong would silently
    // touch the wrong track.
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();
    app.session.project.tracks.items[1].gain_db = -6.0;
    app.session.project.tracks.items[1].pan = 0.5;
    app.cursor = 1;

    for (":gain") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "track 2 gain: -6.0dB") != null);

    for (":pan") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "track 2 pan: R50%") != null);

    // An explicit index still targets that track, not the cursor.
    for (":gain 1") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "track 1 gain: 0.0dB") != null);

    // On the master row (no cursor track), the fallback bails out cleanly
    // instead of indexing past the track list.
    app.cursor = app.session.project.tracks.items.len;
    for (":gain") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "usage:") != null);
}

test "enter on synth track opens synth editor" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0); // cursor 0 = synth
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    try std.testing.expectEqual(@as(u16, 0), app.synth_track);
}

test "synth editor esc returns to tracks" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "synth editor jk moves cursor, hl adjusts first parameter" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u8, 2), app.synth_cursor);

    var block: [64]types.Sample = undefined;
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    const synth = &app.session.racks.items[0].instrument.poly_synth;
    try std.testing.expect(synth.detune_cents != 0.0);

    app.synth_cursor = 16;
    try std.testing.expectEqual(@as(u8, 16), app.synth_cursor);

    const old_attack = synth.attack_s;
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    try std.testing.expect(synth.attack_s > old_attack);
}

test "wt.table h/l picks a bundled wavetable, wrapping past both ends" {
    const Bundled = ws.dsp.synth.BundledWavetable;
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    // OSC A's last entry: waveform table, after position.
    for (0..8) |_| app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u8, 251), app.synth_cursor);

    const synth = &app.session.racks.items[0].instrument.poly_synth;
    try std.testing.expectEqual(Bundled.basic, synth.wt_bundled.?);
    const basic_frames = try std.testing.allocator.dupe(f32, synth.wt.frames);
    defer std.testing.allocator.free(basic_frames);

    // No engine.process in between: unlike every queued param nudge, this
    // one is applied on the control thread the moment the key lands.
    app.handleKey(.{ .char = 'l' }, 0);
    try std.testing.expectEqual(Bundled.spectral, synth.wt_bundled.?);
    // The audio changed too, not just the tag naming it.
    try std.testing.expect(!std.mem.eql(f32, basic_frames, synth.wt.frames));

    app.handleKey(.{ .char = 'h' }, 0);
    try std.testing.expectEqual(Bundled.basic, synth.wt_bundled.?);
    try std.testing.expect(std.mem.eql(f32, basic_frames, synth.wt.frames));

    // Wrapping off the first entry lands on the last, the way every other
    // list-valued row steps.
    app.handleKey(.{ .char = 'h' }, 0);
    try std.testing.expectEqual(Bundled.analog, synth.wt_bundled.?);
    app.handleKey(.{ .char = 'l' }, 0);
    try std.testing.expectEqual(Bundled.basic, synth.wt_bundled.?);

    // OSC B and C keep their own slots - stepping A left the others alone.
    try std.testing.expectEqual(Bundled.basic, synth.osc_b_wt_bundled.?);
    try std.testing.expectEqual(Bundled.basic, synth.osc_c_wt_bundled.?);
}

test "f in the tracks view opens the preset picker for the cursor track's instrument" {
    var app = try testApp();
    defer app.deinit();

    // Track 0 is a synth: the picker opens on the rack-level synth presets
    // and escape returns to the tracks view it came from.
    app.handleKey(.{ .char = 'f' }, 0);
    try std.testing.expectEqual(AppView.preset_picker, app.view);
    try std.testing.expectEqual(preset_ed.Kind.synth, app.preset_picker_kind);
    try std.testing.expectEqual(@as(u16, 0), app.preset_picker_track);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);

    // The kind follows the instrument, not whichever editor was last open.
    commands.run(&app, "track-add");
    const drum = app.session.racks.items.len - 1;
    commands.run(&app, "track-instrument drum");
    app.setTrackRow(drum);
    app.cursor = @intCast(drum);
    app.handleKey(.{ .char = 'f' }, 0);
    try std.testing.expectEqual(AppView.preset_picker, app.view);
    try std.testing.expectEqual(preset_ed.Kind.drum, app.preset_picker_kind);
}

test "synth editor search walks every candidate without overrunning its buffer" {
    var app = try testApp();
    defer app.deinit();

    // max_search_candidates was hand-counted and went stale when the mod
    // matrix grew 8 rows to 32, so `/` wrote past the caller's buffer.
    var cbuf: [synth_ed_mod.max_search_candidates]synth_ed_mod.SearchCandidate = undefined;
    const candidates = synth_ed_mod.searchCandidates(&cbuf);
    try std.testing.expect(candidates.len > 200);

    app.handleKey(.enter, 0);
    for ("/cutoff") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u16, 21), app.synth_cursor);
}

test "m points the first free matrix row at the param under the cursor" {
    var app = try testApp();
    defer app.deinit();
    const Synth = ws.dsp.PolySynth;
    var block: [64]types.Sample = undefined;

    app.handleKey(.enter, 0);
    const synth = &app.session.racks.items[0].instrument.poly_synth;

    // Filter cutoff, from the MAIN subview: row 0 takes it as its dest and
    // the cursor lands on that row's source field, ready for h/l.
    app.synth_cursor = 21;
    app.handleKey(.{ .char = 'm' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectEqual(synth_ed_mod.Subview.mod, app.synth_subview);
    try std.testing.expectEqual(Synth.matrixParamId(0, 0), app.synth_cursor);
    try std.testing.expectEqual(@as(u16, 21), synth.mod_matrix[0].dest);
    // Left inert on purpose - a source and a depth are the user's to pick.
    try std.testing.expectEqual(ws.dsp.synth.ModSource.none, synth.mod_matrix[0].source);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), synth.mod_matrix[0].depth, 1e-6);

    // With row 0 in use, the next assign takes row 1 rather than stealing it.
    synth.mod_matrix[0].source = .lfo;
    const other = Synth.mod_dest_ids[0];
    app.synth_cursor = other;
    app.handleKey(.{ .char = 'm' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectEqual(Synth.matrixParamId(1, 0), app.synth_cursor);
    try std.testing.expectEqual(other, synth.mod_matrix[1].dest);

    // The cursor now sits on a matrix field, which is barred as a dest: the
    // press is rejected and nothing moves.
    app.handleKey(.{ .char = 'm' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectEqual(Synth.matrixParamId(1, 0), app.synth_cursor);
    try std.testing.expectEqual(ws.dsp.synth.ModSource.none, synth.mod_matrix[2].source);
    try std.testing.expectEqual(@as(u16, 21), synth.mod_matrix[0].dest);
}

test "matrix destination cycles through fields on existing FX instances" {
    var app = try testApp();
    defer app.deinit();
    var block: [64]types.Sample = undefined;
    const rack = app.session.racks.items[0];
    const sat = try rack.fx.insert(app.allocator, 0, .sat, 48_000);
    const synth = &rack.instrument.poly_synth;
    const row: u8 = 0;
    synth.mod_matrix[row].dest = ws.dsp.PolySynth.mod_dest_ids[ws.dsp.PolySynth.mod_dest_ids.len - 1];

    app.handleKey(.enter, 0);
    app.synth_subview = .mod;
    app.synth_cursor = ws.dsp.PolySynth.matrixParamId(row, 1);
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);

    try std.testing.expectEqual(sat.instance_id, synth.mod_matrix[row].fx_instance_id);
    try std.testing.expectEqual(@as(u16, 0), synth.mod_matrix[row].dest);

    app.handleKey(.{ .char = 'u' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectEqual(@as(u32, 0), synth.mod_matrix[row].fx_instance_id);
    try std.testing.expectEqual(ws.dsp.PolySynth.mod_dest_ids[ws.dsp.PolySynth.mod_dest_ids.len - 1], synth.mod_matrix[row].dest);
}

test "draw renders synth editor without errors" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.synth_editor, app.view);

    // Tall enough that the whole single-column MAIN body fits - see
    // synth_layout.zig's main_sections) fits without scrolling, so this
    // stays a simple "did real content render" smoke test rather than a
    // reflection of exactly where ENV 1 happens to land in the order.
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 140 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SYNTH") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "attack") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "sustain") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "LFO 1") != null);
}

test "synth MOD subview contains matrix without LFO cards" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqual(synth_ed_mod.Subview.mod, app.synth_subview);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 100 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "MATRIX") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "LFO 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "MACRO") == null);
    // secMatrix's own body, not just its title: proves the render fn that
    // ran under the MATRIX header is the matrix one.
    try std.testing.expect(std.mem.indexOf(u8, frame, "CUTOFF") != null);
}

test "synth tabs cycle cursor group and preserve selected field" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    app.handleKey(.tab, 0);
    app.synth_cursor = 29;
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 1), app.synth_lfo_tab);
    try std.testing.expectEqual(@as(u16, 96), app.synth_cursor);
    app.handleKey(.{ .char = '[' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.synth_lfo_tab);
    try std.testing.expectEqual(@as(u16, 29), app.synth_cursor);
    app.handleKey(.{ .char = '[' }, 0);
    try std.testing.expectEqual(@as(u8, 2), app.synth_lfo_tab);
    try std.testing.expectEqual(@as(u16, 98), app.synth_cursor);

    app.synth_subview = .main;
    app.synth_cursor = 17;
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 1), app.synth_env_tab);
    try std.testing.expectEqual(@as(u16, 25), app.synth_cursor);
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 2), app.synth_env_tab);
    try std.testing.expectEqual(@as(u16, 123), app.synth_cursor);

    app.synth_cursor = 21;
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 1), app.synth_filter_tab);
    try std.testing.expectEqual(@as(u16, 47), app.synth_cursor);
    app.handleKey(.{ .char = '[' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.synth_filter_tab);
    try std.testing.expectEqual(@as(u16, 21), app.synth_cursor);

    app.synth_cursor = 2;
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 1), app.synth_osc_tab);
    try std.testing.expectEqual(@as(u16, 10), app.synth_cursor);
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 2), app.synth_osc_tab);
    try std.testing.expectEqual(@as(u16, 54), app.synth_cursor);

    app.synth_cursor = 34;
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u16, 34), app.synth_cursor);
}

test "synth row navigation skips folded tab siblings" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    for (0..9) |_| app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u16, 34), app.synth_cursor);

    // FILTER 1's four rows, then past the folded FILTER 2 to ENV 1.
    app.synth_cursor = 20;
    for (0..4) |_| app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u16, 16), app.synth_cursor);

    // ENV 1's five rows, then straight past the folded ENV 2/ENV 3 to VOICE.
    app.synth_cursor = 16;
    for (0..5) |_| app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u16, 32), app.synth_cursor);

    app.handleKey(.tab, 0);
    try std.testing.expectEqual(@as(u16, 59), app.synth_cursor);
}

test "synth section focus isolates navigation and rendering" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expect(app.synth_section_focus);

    app.handleKey(.{ .char = 'g' }, 0);
    app.handleKey(.{ .char = 'G' }, 0);
    try std.testing.expectEqual(@as(u8, 251), app.synth_cursor);
    app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u8, 251), app.synth_cursor);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 120, .rows = 30 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "FOCUS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "OSC A") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "OSC B") == null);

    app.handleKey(.{ .char = '}' }, 0);
    // The next card is OSC B (id 6, its on/off), at every column count:
    // sections are walked in table order, which is the band-by-band reading
    // order of the grid. This used to be OSC C at 120 columns, back when
    // the walk was column-major and OSC B lived in the other column.
    try std.testing.expectEqual(@as(u8, 6), app.synth_cursor);
    app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expect(!app.synth_section_focus);
}

test "synth editor g/G jump to the first/last parameter" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    app.synth_cursor = 6;

    app.handleKey(.{ .char = 'g' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    try std.testing.expectEqual(@as(u8, 99), app.synth_cursor);
    app.handleKey(.{ .char = 'g' }, 0);
    app.handleKey(.{ .char = 'G' }, 0);
    // Last id of the "main" subview: OUT's "gain" (id 38) - the last
    // section in synth_layout.zig's main_sections declaration order.
    try std.testing.expectEqual(@as(u8, 38), app.synth_cursor);
}

test "synth editor param nudges coalesce into one undo step, u/U round-trips" {
    var app = try testApp();
    defer app.deinit();
    var block: [64]types.Sample = undefined;

    app.handleKey(.enter, 0); // cursor 2 = synth
    app.synth_cursor = 16;
    try std.testing.expectEqual(@as(u8, 16), app.synth_cursor);

    const synth = &app.session.racks.items[0].instrument.poly_synth;
    app.session.engine.process(&block);
    const before = synth.attack_s;

    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    try std.testing.expect(synth.attack_s > before);
    // Three nudges on the same param, no cursor move yet - still one open
    // batch, nothing pushed to the undo stack.
    try std.testing.expectEqual(@as(usize, 0), app.history.undo_stack.items.len);

    // u right after nudging (no intervening flush point) must undo the
    // batch just made, not silently no-op.
    app.handleKey(.{ .char = 'u' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectApproxEqAbs(before, synth.attack_s, 0.0001);

    app.handleKey(.{ .char = 'U' }, 0);
    app.session.engine.process(&block);
    try std.testing.expect(synth.attack_s > before);
}

test "param undo restores the exact value even when a nudge hit the clamp" {
    var app = try testApp();
    defer app.deinit();
    var block: [64]types.Sample = undefined;

    app.handleKey(.enter, 0); // cursor 2 = synth
    app.synth_cursor = 18;
    try std.testing.expectEqual(@as(u8, 18), app.synth_cursor);

    const synth = &app.session.racks.items[0].instrument.poly_synth;
    synth.sustain = 0.99;
    app.session.engine.process(&block);

    // Three up-nudges: the first lands (1.0), the rest clamp. A delta
    // replay would "undo" -3 steps to 0.96; the absolute restore must
    // come back to exactly 0.99.
    for (0..3) |_| app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), synth.sustain, 1e-6);

    app.handleKey(.{ .char = 'u' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99), synth.sustain, 1e-6);

    app.handleKey(.{ .char = 'U' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), synth.sustain, 1e-6);
}

test "param undo round-trips a coalesced toggle batch (any nonzero delta = one flip)" {
    var app = try testApp();
    defer app.deinit();
    var block: [64]types.Sample = undefined;

    app.handleKey(.enter, 0);
    app.synth_cursor = 6;
    try std.testing.expectEqual(@as(u8, 6), app.synth_cursor);

    const synth = &app.session.racks.items[0].instrument.poly_synth;
    app.session.engine.process(&block);
    const before = synth.osc_b_on;

    // Two same-direction presses coalesce to a +2 batch but flip the
    // toggle twice (net zero change). Undo must restore the original
    // state, not replay -2 as a single third flip.
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectEqual(before, synth.osc_b_on);

    app.handleKey(.{ .char = 'u' }, 0);
    app.session.engine.process(&block);
    try std.testing.expectEqual(before, synth.osc_b_on);
}

test "synth editor param nudge flushes as its own step when the cursor moves off the param" {
    var app = try testApp();
    defer app.deinit();
    var block: [64]types.Sample = undefined;

    app.handleKey(.enter, 0);
    app.synth_cursor = 16;
    const synth = &app.session.racks.items[0].instrument.poly_synth;
    app.session.engine.process(&block);
    const attack_before = synth.attack_s;

    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);

    app.handleKey(.{ .char = 'j' }, 0); // move to decay (17), nudge it too
    app.session.engine.process(&block);
    const decay_before = synth.decay_s;
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    try std.testing.expect(synth.decay_s > decay_before);

    // The attack batch was flushed by the id mismatch on the next nudge;
    // the decay nudge is still open (not flushed) - one entry so far.
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);

    app.handleKey(.{ .char = 'g' }, 0); // arms the g prefix
    app.handleKey(.{ .char = 'g' }, 0); // gg flushes the open decay batch
    try std.testing.expectEqual(@as(usize, 2), app.history.undo_stack.items.len);

    app.handleKey(.{ .char = 'u' }, 0); // undo decay nudge
    app.session.engine.process(&block);
    try std.testing.expectApproxEqAbs(decay_before, synth.decay_s, 0.0001);
    app.handleKey(.{ .char = 'u' }, 0); // undo attack batch
    app.session.engine.process(&block);
    try std.testing.expectApproxEqAbs(attack_before, synth.attack_s, 0.0001);
}

test "escape returns from track_spectrum to tracks" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "TRACKS") != null);
}

test "p key opens piano roll for synth track" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.{ .char = 'p' }, 0); // cursor 0 = synth
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expectEqual(@as(u16, 0), app.piano_track);

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 120, .rows = 36 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "PIANO ROLL") != null);

    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;
    app.handleKey(.{ .char = 'n' }, 0);
    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);

    app.handleKey(.{ .char = 'd' }, 0); // d is an operator now; dd deletes the note under the cursor
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "piano roll opens existing patterns at their earliest note" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 72, .start_beat = 2.0, .duration_beat = 0.5, .velocity = 0.7 });
    pp.addNote(.{ .pitch = 67, .start_beat = 1.0, .duration_beat = 0.25, .velocity = 0.9 });

    piano_ed.switchTo(&app, 0);
    try std.testing.expectEqual(@as(u7, 67), app.piano_cursor_pitch);
    try std.testing.expectEqual(@as(u16, 4), app.piano_cursor_step);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "1.2.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "0.25b") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "90%") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "[ ]: resize") != null);
}

test "p key opens piano roll for sampler track" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 1; // sampler
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expectEqual(@as(u16, 1), app.piano_track);
}

test "p on a drum track opens the step grid, not the piano roll" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 2; // drum machine
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
}

test "piano roll insert mode records a take at the playhead while playing" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.{ .char = 'p' }, 0); // open piano roll on the synth track
    try std.testing.expectEqual(AppView.piano_roll, app.view);

    // 120 bpm @ 48k => 24_000 frames/beat; seek to beat 0.75 (step 3).
    _ = app.session.engine.send(.{ .seek_frames = 18_000 });
    _ = app.session.engine.send(.play);
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block); // flushes commands, publishes the snapshot

    app.handleKey(.{ .char = 'i' }, 0);
    try std.testing.expectEqual(ws.input.Mode.insert, app.modal.mode);

    app.handleKey(.{ .char = 'a' }, 0); // middle C (octave 4)
    try std.testing.expectEqual(ws.input.Mode.insert, app.modal.mode); // still recording

    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), pp.notes[0].start_beat, 1e-9);
    // Cursor follows the take so the roll shows where it landed.
    try std.testing.expectEqual(@as(u16, 3), app.piano_cursor_step);
    try std.testing.expectEqual(@as(u7, 60), app.piano_cursor_pitch);

    // Escape drops back to normal without leaving the roll, and roll
    // navigation (not note-play) owns h/j/k/l again.
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    app.handleKey(.{ .char = 'h' }, 0);
    try std.testing.expectEqual(@as(u16, 2), app.piano_cursor_step);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count); // 'h' didn't record another note
}

test "space in piano-roll insert mode arms a count-in instead of recording from beat one" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.{ .char = 'p' }, 0); // open piano roll on the synth track
    app.handleKey(.{ .char = 'i' }, 0);
    try std.testing.expectEqual(ws.input.Mode.insert, app.modal.mode);

    app.handleKey(.{ .char = ' ' }, 0); // space, stopped -> arms the count-in
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    var snap = app.session.engine.uiSnapshot();
    try std.testing.expect(snap.pre_rolling);
    try std.testing.expect(!snap.playing);

    // A second space cancels it rather than stacking another count-in.
    app.handleKey(.{ .char = ' ' }, 0);
    app.session.engine.process(&block);
    snap = app.session.engine.uiSnapshot();
    try std.testing.expect(!snap.pre_rolling);
    try std.testing.expect(!snap.playing);
}

test "space in piano-roll insert mode just stops when already playing (no count-in)" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.{ .char = 'p' }, 0);
    _ = app.session.engine.send(.play);
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block); // flushes + publishes playing=true
    app.handleKey(.{ .char = 'i' }, 0);

    app.handleKey(.{ .char = ' ' }, 0); // already playing -> plain stop
    app.session.engine.process(&block);
    const snap = app.session.engine.uiSnapshot();
    try std.testing.expect(!snap.playing);
    try std.testing.expect(!snap.pre_rolling);
}

test "piano roll insert mode previews without recording while the transport is stopped" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.{ .char = 'p' }, 0);
    app.handleKey(.{ .char = 'i' }, 0);
    try std.testing.expectEqual(ws.input.Mode.insert, app.modal.mode);
    app.handleKey(.{ .char = 'a' }, 0);

    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
}

test "drum grid insert mode records a pad hit at the playhead while playing" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 2; // drum machine
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);

    _ = app.session.engine.send(.play);
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block); // flushes commands, publishes the snapshot

    app.handleKey(.{ .char = 'i' }, 0);
    try std.testing.expectEqual(ws.input.Mode.insert, app.modal.mode);

    app.handleKey(.{ .char = 'a' }, 0); // pitch 60 -> pad 60 % 64 = 60
    try std.testing.expectEqual(ws.input.Mode.insert, app.modal.mode); // still recording

    const dm = &app.session.racks.items[2].instrument.drum_machine;
    const step = dm.currentStep();
    try std.testing.expect(dm.stepActive(60, step));
    // Cursor follows the hit so the grid shows where the take landed.
    try std.testing.expectEqual(@as(u8, 60), app.drum_cursor[0]);
    try std.testing.expectEqual(step, app.drum_cursor[1]);

    // Escape drops back to normal without leaving the grid, and grid
    // navigation (not pad-play) owns h/j/k/l again.
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
}

test "drum grid insert mode previews without recording while the transport is stopped" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 2;
    app.handleKey(.{ .char = 'p' }, 0);
    app.handleKey(.{ .char = 'i' }, 0);
    try std.testing.expectEqual(ws.input.Mode.insert, app.modal.mode);
    app.handleKey(.{ .char = 'a' }, 0);

    // Pitch 60 maps to pad 60 % 64 = 60, which the shipped kit's default
    // groove leaves silent (only pads 0/1/2 have a default pattern) - check
    // the whole pad's row stayed empty rather than a single step, so the
    // test doesn't depend on where a stopped transport's playhead sits.
    const dm = &app.session.racks.items[2].instrument.drum_machine;
    var s: u8 = 0;
    while (s < dm.step_count) : (s += 1) try std.testing.expect(!dm.stepActive(60, s));
}

test "drum grid insert mode doesn't stack a duplicate hit on the same step" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 2;
    app.handleKey(.{ .char = 'p' }, 0);
    _ = app.session.engine.send(.play);
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);

    app.handleKey(.{ .char = 'i' }, 0);
    app.handleKey(.{ .char = 'a' }, 0);
    const dm = &app.session.racks.items[2].instrument.drum_machine;
    const step = dm.currentStep();
    try std.testing.expect(dm.stepActive(60, step));

    // A second hit on the same (pad, step) while the playhead hasn't moved
    // must not toggle it back off.
    app.handleKey(.{ .char = 'a' }, 0);
    try std.testing.expect(dm.stepActive(60, step));
}

test ":q refuses to quit while dirty; :q! discards" {
    var app = try testApp();
    defer app.deinit();

    // A clean session quits.
    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.should_quit);
    app.should_quit = false;

    // A drum edit marks the session dirty; :q now refuses.
    app.drum_track = 2;
    _ = drum_ed.handleKey(&app, .enter);
    try std.testing.expect(app.dirty);
    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(!app.should_quit);

    // :q! force-quits.
    for (":q!") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.should_quit);
}

test "ctrl-c refuses to quit while dirty" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.ctrl_c, 0);
    try std.testing.expect(app.should_quit);

    app.should_quit = false;
    app.applyAction(.toggle_mute, 0);
    app.handleKey(.ctrl_c, 0);
    try std.testing.expect(!app.should_quit);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "unsaved changes");
}

test "saving clears the dirty flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try redirectHome(&tmp);

    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    app.applyAction(.toggle_mute, 0);
    try std.testing.expect(app.dirty);

    var cmd_buf: [96]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":w .zig-cache/tmp/{s}/p.wsj", .{&tmp.sub_path});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(!app.dirty);
}

test "count prefixes multiply editor motions and die with the next key" {
    var app = try testApp();
    defer app.deinit();

    // Piano roll: 3l moves three steps; 2K jumps two octaves.
    app.view = .piano_roll;
    app.piano_track = 0;
    app.session.racks.items[0].pattern_player.?.length_beats = 8.0; // 32 steps
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u16, 3), app.piano_cursor_step);
    for ("2K") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u7, 84), app.piano_cursor_pitch);

    // Drum grid: counts clamp at the pattern edge.
    app.view = .drum_grid;
    app.drum_track = 2;
    for ("4l") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u8, 4), app.drum_cursor[1]);
    for ("99l") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u8, 31), app.drum_cursor[1]); // 32 steps

    // An unused count is discarded by the handled key it preceded ('p'
    // previews, no count) - the following motion moves 1, not 5.
    for ("5p") |c| app.handleKey(.{ .char = c }, 0);
    for ("h") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u8, 30), app.drum_cursor[1]);

    // Arrangement: 3l = three bars.
    app.view = .arrangement;
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u32, 3), app.arr_cursor_bar);
}

test "arrangement clips: yank/paste, count-move, kind guard, undo" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0);

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;

    // Yank, paste at bar 4; the cursor jumps past the pasted clip. yy
    // yanks the whole lane, which here is just this one clip.
    app.handleKey(.{ .char = 'y' }, 0);
    app.handleKey(.{ .char = 'y' }, 0);
    app.arr_cursor_bar = 4;
    app.handleKey(.{ .char = 'P' }, 0);
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(usize, 2), lane.clips.items.len);
    try std.testing.expect(lane.clipAt(128) != null);
    try std.testing.expectEqual(@as(u32, 8), app.arr_cursor_bar);

    // Move the pasted clip right two bars with a count; cursor follows.
    app.arr_cursor_bar = 4;
    for ("2>") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(lane.clipAt(128) == null);
    try std.testing.expect(lane.clipAt(192) != null);
    try std.testing.expectEqual(@as(u32, 6), app.arr_cursor_bar);

    // Kind guard: the melodic clip won't paste onto the drum lane.
    app.cursor = 2;
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'P' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.session.arrangement.lane(2).?.clips.items.len);

    // Undo restores the pre-move layout (entry targets lane 0).
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expect(lane.clipAt(128) != null);
    try std.testing.expectEqual(@as(u32, 128), lane.clipAt(192).?.start_tick);
}

test "arrangement visual mode selects a bar range on the current lane for y/d/P" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0); // 1-bar clip at bar 0
    try app.session.stampClip(0, 1); // 1-bar clip at bar 1
    try app.session.stampClip(0, 5); // outside the selection below

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    for ("4l") |c| app.handleKey(.{ .char = c }, 0);

    app.handleKey(.{ .char = 'y' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.arr_range_clip.?.clips.len);

    const lane = app.session.arrangement.lane(0).?;
    app.arr_cursor_bar = 40;
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'P' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(lane.clipAt(1280) != null);
    try std.testing.expect(lane.clipAt(1408) != null);
    try std.testing.expect(lane.clipAt(640) != null);

    // Select the original range again and delete it.
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'v' }, 0);
    for ("4l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(lane.clipAt(0) == null);
    try std.testing.expect(lane.clipAt(128) == null);
    try std.testing.expect(lane.clipAt(640) != null);
}

test "arrangement V cuts a bar range across every lane and undoes in one step" {
    var app = try testApp();
    defer app.deinit();
    // Tracks 0 (synth) and 1 (sampler) are both melodic, so both can hold
    // a stamped clip; track 2 is the drum machine and stays empty.
    for ([_]usize{ 0, 1 }) |t| {
        const pp = &app.session.racks.items[t].pattern_player.?;
        pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
        try app.session.stampClip(@intCast(t), 0);
        try app.session.stampClip(@intCast(t), 5); // outside the cut below
    }
    const lane0 = app.session.arrangement.lane(0).?;
    const lane1 = app.session.arrangement.lane(1).?;

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'V' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    try std.testing.expectEqual(@as(?usize, null), app.arr_visual_lane_anchor);
    for ("4l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    // Both lanes cut, even though the cursor never left lane 0.
    try std.testing.expect(lane0.clipAt(0) == null);
    try std.testing.expect(lane1.clipAt(0) == null);
    try std.testing.expect(lane0.clipAt(640) != null);
    try std.testing.expect(lane1.clipAt(640) != null);

    // One `u` puts every lane back - a multi-lane edit is one undo step.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expect(app.session.arrangement.lane(0).?.clipAt(0) != null);
    try std.testing.expect(app.session.arrangement.lane(1).?.clipAt(0) != null);

    // And redo takes both away again.
    app.handleKey(.{ .char = 'U' }, 0);
    try std.testing.expect(app.session.arrangement.lane(0).?.clipAt(0) == null);
    try std.testing.expect(app.session.arrangement.lane(1).?.clipAt(0) == null);
}

test "arrangement visual time edits remove, insert, and loop selected time" {
    var app = try testApp();
    defer app.deinit();
    for ([_]usize{ 0, 1 }) |track| {
        const pp = &app.session.racks.items[track].pattern_player.?;
        pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
        try app.session.stampClip(@intCast(track), 0);
        try app.session.stampClip(@intCast(track), 5);
    }
    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    try app.session.project.setSection(640, "outro");

    // Four quarter-note cells equal one musical bar.
    app.handleKey(.{ .char = 'V' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = '=' }, 0);
    try std.testing.expect(app.session.project.loop_enabled);
    try std.testing.expectEqual(@as(u32, 0), app.session.project.loop_start_bar);
    try std.testing.expectEqual(@as(u32, 1), app.session.project.loop_end_bar);

    // Removing that bar shifts bar 5 to bar 4 on every lane.
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'V' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'D' }, 0);
    try std.testing.expect(app.session.arrangement.lane(0).?.clipAt(512) != null);
    try std.testing.expect(app.session.arrangement.lane(1).?.clipAt(512) != null);
    try std.testing.expectEqual(@as(u32, 512), app.session.project.sections.items[0].tick);
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(u32, 640), app.session.project.sections.items[0].tick);

    // Yank first bar, then insert it at bar 5. Existing material moves right.
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'V' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'y' }, 0);
    app.arr_cursor_bar = 20;
    app.handleKey(.{ .char = 'P' }, 0);
    try std.testing.expect(app.session.arrangement.lane(0).?.clipAt(640) != null);
    try std.testing.expect(app.session.arrangement.lane(1).?.clipAt(640) != null);
    try std.testing.expect(app.session.arrangement.lane(0).?.clipAt(768) != null);
    try std.testing.expect(app.session.arrangement.lane(1).?.clipAt(768) != null);
}

test "arrangement sections add, navigate, select, and delete" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    try app.session.project.setSection(0, "intro");
    try app.session.project.setSection(128, "verse");
    try app.session.project.setSection(256, "chorus");
    try app.session.stampClip(0, 0);

    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = '}' }, 0);
    try std.testing.expectEqual(@as(u32, 4), app.arr_cursor_bar);
    app.handleKey(.{ .char = '}' }, 0);
    try std.testing.expectEqual(@as(u32, 8), app.arr_cursor_bar);
    app.handleKey(.{ .char = '{' }, 0);
    try std.testing.expectEqual(@as(u32, 4), app.arr_cursor_bar);
    app.handleKey(.{ .char = 's' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    try std.testing.expectEqual(@as(?usize, null), app.arr_visual_lane_anchor);
    try std.testing.expectEqual(@as(u32, 7), app.arr_cursor_bar);

    _ = app.modal.setMode(.normal);
    app.arr_visual_anchor = null;
    app.arr_cursor_bar = 12;
    for (":section outro") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("outro", app.session.project.sections.items[3].name);
    for (":section-del") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 3), app.session.project.sections.items.len);
}

test "arrangement clip-edge motions skip empty time" {
    var app = try testApp();
    defer app.deinit();
    try app.session.stampClip(0, 2);
    try app.session.stampClip(0, 8);
    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;

    app.handleKey(.{ .char = 'W' }, 0);
    try std.testing.expectEqual(@as(u32, 8), app.arr_cursor_bar);
    app.handleKey(.{ .char = 'W' }, 0);
    try std.testing.expectEqual(@as(u32, 12), app.arr_cursor_bar);
    app.handleKey(.{ .char = 'W' }, 0);
    try std.testing.expectEqual(@as(u32, 32), app.arr_cursor_bar);
    app.handleKey(.{ .char = 'B' }, 0);
    try std.testing.expectEqual(@as(u32, 12), app.arr_cursor_bar);
}

test "arrangement w/b snap to bar lines; G lands on the song end or a counted bar" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    app.cursor = 0;

    // Default 1/4 grid: a cell is a beat, so a 4/4 bar is 4 cells. w from
    // mid-bar snaps forward to the next bar line, b back to the previous.
    app.arr_cursor_bar = 5;
    app.handleKey(.{ .char = 'w' }, 0);
    try std.testing.expectEqual(@as(u32, 8), app.arr_cursor_bar);
    app.handleKey(.{ .char = 'b' }, 0);
    try std.testing.expectEqual(@as(u32, 4), app.arr_cursor_bar);
    for ("2w") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u32, 12), app.arr_cursor_bar);

    // A one-bar clip at bar 2 ends at cell 12, so gG stops on cell 11 - the
    // last cell that still holds song material.
    try app.session.stampClip(0, 2);
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'g' }, 0);
    app.handleKey(.{ .char = 'G' }, 0);
    try std.testing.expectEqual(@as(u32, 11), app.arr_cursor_bar);

    // With a count G was vim's line jump (bar n); as a two-key pair it's
    // a plain "go to end" and the count is just dropped.
    app.handleKey(.{ .char = 'g' }, 0);
    app.handleKey(.{ .char = 'G' }, 0);
    try std.testing.expectEqual(@as(u32, 11), app.arr_cursor_bar);

    // dw cuts through the end of the bar it starts in, not into the next:
    // the clip on bar 3 survives the cut that clears bar 2.
    try app.session.stampClip(0, 3);
    app.arr_cursor_bar = 8;
    for ("dw") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(app.session.arrangement.lane(0).?.clipAt(8 * 32) == null);
    try std.testing.expect(app.session.arrangement.lane(0).?.clipAt(12 * 32) != null);
}

test "arrangement blockwise visual bounds the cut to the lane band j/k grows" {
    var app = try testApp();
    defer app.deinit();
    for ([_]usize{ 0, 1 }) |t| {
        const pp = &app.session.racks.items[t].pattern_player.?;
        pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
        try app.session.stampClip(@intCast(t), 0);
    }
    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;

    // `v` anchors the lane, so the cut stops at lane 0 - the behaviour
    // visual mode always had here, now explicitly the blockwise case.
    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expectEqual(@as(?usize, 0), app.arr_visual_lane_anchor);
    for ("4l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(app.session.arrangement.lane(0).?.clipAt(0) == null);
    try std.testing.expect(app.session.arrangement.lane(1).?.clipAt(0) != null);
    try std.testing.expectEqual(@as(?usize, null), app.arr_visual_lane_anchor);
}

test "arrangement operator+motion: d3l / y3l act on a bar range without entering visual mode" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0); // 1-bar clip at bar 0
    try app.session.stampClip(0, 1); // 1-bar clip at bar 1
    try app.session.stampClip(0, 5); // outside the range below

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    for ("y4l") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.arr_range_clip.?.clips.len);
    try std.testing.expectEqual(@as(u32, 4), app.arr_cursor_bar);

    const lane = app.session.arrangement.lane(0).?;
    app.arr_cursor_bar = 0;
    for ("d4l") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(lane.clipAt(0) == null);
    try std.testing.expect(lane.clipAt(128) == null);
    try std.testing.expect(lane.clipAt(640) != null);

    // x cuts just the grid unit under the cursor - trimming the clip it
    // sits inside of, not deleting the whole thing (see Lane.cutRange).
    // The bar-5 clip survives as a shrunk remainder starting past the cut.
    app.arr_cursor_bar = 20; // tick 640, the head of the bar-5 clip
    app.handleKey(.{ .char = 'x' }, 0);
    try std.testing.expect(lane.clipAt(640) == null);
    const remainder = lane.clipAt(672) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 672), remainder.start_tick);
    try std.testing.expectEqual(@as(u32, 96), remainder.length_ticks);

    // dd/yy are the tier above a bar range: the whole lane, whatever's left
    // on it (clear it first so the fragments above don't confuse the count).
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(usize, 0), lane.clips.items.len);
    try app.session.stampClip(0, 0);
    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.arr_range_clip.?.clips.len); // just bar 0's clip
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(usize, 0), lane.clips.items.len);

    // p/P paste from that same whole-lane yank; cursor jumps past it.
    app.arr_cursor_bar = 40;
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expect(lane.clipAt(1280) != null);
    try std.testing.expectEqual(@as(u32, 44), app.arr_cursor_bar);
}

test "arrangement +/- edge-resize a clip; undo/dot-repeat, min clamp, growth evicts" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0); // 1-bar clip at bar 0
    try app.session.stampClip(0, 3); // a second clip, in the way of growth

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(u32, 128), lane.clipAt(0).?.length_ticks);

    // '+' grows the clip by 3 bars (endBar 0+4=4); count-prefixed like '<'/'>'.
    for ("12+") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u32, 512), lane.clipAt(0).?.length_ticks);
    // Growth now overlaps and evicts the clip stamped at bar 3.
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try std.testing.expect(lane.clipAt(384) != null);

    // '.' repeats the last resize (another +3 bars) at the cursor.
    app.handleKey(.{ .char = '.' }, 0);
    try std.testing.expectEqual(@as(u32, 896), lane.clipAt(0).?.length_ticks);

    // '-' shrinks it back down, clamped to a minimum of 1 bar.
    for ("36-") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u32, 1), lane.clipAt(0).?.length_ticks);

    // Undo restores the length from before the shrink.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(u32, 896), lane.clipAt(0).?.length_ticks);

    // No clip under the cursor: a clean no-op, not a crash.
    app.arr_cursor_bar = 50;
    app.handleKey(.{ .char = '+' }, 0);
}

test "arrangement timeline operations clamp at the u32 boundary" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0);

    app.view = .arrangement;
    app.cursor = 0;
    const lane = app.session.arrangement.lane(0).?;
    const clip = &lane.clips.items[0];
    clip.start_tick = std.math.maxInt(u32) - 255;
    clip.length_ticks = 128;
    app.arr_cursor_bar = clip.start_tick / app.arr_grid.ticks();

    for ("4096>") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(std.math.maxInt(u32), lane.clips.items[0].endTick());

    for ("4096+") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(std.math.maxInt(u32), lane.clips.items[0].endTick());

    app.arr_cursor_bar = std.math.maxInt(u32);
    app.handleKey(.{ .char = 'l' }, 0);
    try std.testing.expectEqual((std.math.maxInt(u32) - 1) / app.arr_grid.ticks(), app.arr_cursor_bar);
}

test "piano roll enter on an empty cell starts a stamp session - j/k pitch, h/l length" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;

    app.handleKey(.enter, 0); // insert C4 @ step 0 and start stamping
    try std.testing.expect(app.piano_stamp);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);

    app.handleKey(.{ .char = 'k' }, 0); // pitch up a semitone (cursor follows)
    try std.testing.expect(pp.noteAt(61, 0.0) != null);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expectEqual(@as(u7, 61), app.piano_cursor_pitch);

    app.handleKey(.{ .char = 'l' }, 0); // lengthen by one step
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), pp.noteAt(61, 0.0).?.duration_beat, 1e-9);

    app.handleKey(.enter, 0); // drop - a second enter commits, doesn't re-toggle
    try std.testing.expect(!app.piano_stamp);
    try std.testing.expect(pp.noteAt(61, 0.0) != null);
    try std.testing.expectEqual(AppView.piano_roll, app.view);

    // With the session dropped, enter on the now-occupied cell toggles it
    // off again like a plain (non-stamping) enter always has.
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 61;
    app.handleKey(.enter, 0);
    try std.testing.expect(pp.noteAt(61, 0.0) == null);
}

test "piano roll enter release drops the stamp session (hold-to-shape)" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;

    // Hold: press arms, j/k shape while held, key-up drops.
    app.handleKey(.enter, 0);
    try std.testing.expect(app.piano_stamp);
    app.handleKey(.{ .char = 'k' }, 0);
    try std.testing.expect(pp.noteAt(61, 0.0) != null);
    app.handleKey(.enter_release, 0);
    try std.testing.expect(!app.piano_stamp);
    try std.testing.expect(pp.noteAt(61, 0.0) != null);

    // A quick tap leaves no lingering mode: j after the release is plain
    // cursor navigation (cursor still sits on pitch 61 from the k above),
    // not a pitch drag of the stamped note.
    app.piano_cursor_step = 4;
    app.handleKey(.enter, 0);
    app.handleKey(.enter_release, 0);
    app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expect(pp.noteAt(61, 1.0) != null);
    try std.testing.expectEqual(@as(u7, 60), app.piano_cursor_pitch);

    // A release with no session active is inert.
    app.handleKey(.enter_release, 0);
    try std.testing.expect(pp.noteAt(61, 1.0) != null);
}

test "macros: q records, @ replays with a count, @@ repeats the last register" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;

    app.handleKey(.{ .char = 'q' }, 0);
    app.handleKey(.{ .char = 'a' }, 0);
    try std.testing.expect(app.macro_recording != null);
    app.handleKey(.{ .char = 'n' }, 0); // step-enter a note, advance one step
    app.handleKey(.{ .char = 'q' }, 0); // stop recording
    try std.testing.expect(app.macro_recording == null);
    try std.testing.expectEqual(@as(u16, 1), app.macro_reg_lens[0]);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);

    // 3@a stamps three more notes, each advancing the cursor a step.
    app.handleKey(.{ .char = '3' }, 0);
    app.handleKey(.{ .char = '@' }, 0);
    app.handleKey(.{ .char = 'a' }, 0);
    try std.testing.expect(pp.noteAt(60, 0.25) != null);
    try std.testing.expect(pp.noteAt(60, 0.5) != null);
    try std.testing.expect(pp.noteAt(60, 0.75) != null);
    try std.testing.expect(pp.noteAt(60, 1.0) == null);

    // @@ replays the same register once more.
    app.handleKey(.{ .char = '@' }, 0);
    app.handleKey(.{ .char = '@' }, 0);
    try std.testing.expect(pp.noteAt(60, 1.0) != null);
}

test "macros: q keeps its close-the-overlay meaning in picker views" {
    var app = try testApp();
    defer app.deinit();
    app.view = .instrument_picker;
    app.handleKey(.{ .char = 'q' }, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expectEqual(app_mod.MacroPending.none, app.macro_pending);
}

test "backtick toggles between the last two workspace contexts" {
    var app = try testApp();
    defer app.deinit();
    app.view = .tracks;

    // No alternate yet: ` stays put.
    app.handleKey(.{ .char = '`' }, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);

    app.cursor = 0;
    app.handleKey(.{ .char = 'p' }, 0); // open the piano roll for track 0
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    app.handleKey(.{ .char = '`' }, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    app.handleKey(.{ .char = '`' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);

    // Overlays never become the alternate: a help excursion in between
    // leaves the tracks<->piano pair intact.
    app.handleKey(.{ .char = '?' }, 0);
    try std.testing.expectEqual(AppView.help, app.view);
    app.handleKey(.escape, 0);
    app.handleKey(.{ .char = '`' }, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "macros: a self-replaying register terminates via the depth cap" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    app.macro_regs[0][0] = .{ .char = '@' };
    app.macro_regs[0][1] = .{ .char = 'a' };
    app.macro_reg_lens[0] = 2;
    app.macro_last_played = 0;
    // Would recurse forever without the cap; reaching this line is the test.
    app.handleKey(.{ .char = '@' }, 0);
    app.handleKey(.{ .char = 'a' }, 0);
}

test "piano roll visual +/- transpose and </> slide the selection" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 64, .start_beat = 0.25, .duration_beat = 0.25 });
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;

    app.handleKey(.{ .char = 'V' }, 0); // linewise: every pitch across the range
    app.handleKey(.{ .char = 'l' }, 0); // select steps 0-1
    app.handleKey(.{ .char = '+' }, 0); // up a semitone, chord shape intact
    try std.testing.expect(pp.noteAt(61, 0.0) != null);
    try std.testing.expect(pp.noteAt(65, 0.25) != null);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    app.handleKey(.{ .char = '1' }, 0); // up an octave: 12+
    app.handleKey(.{ .char = '2' }, 0);
    app.handleKey(.{ .char = '+' }, 0);
    try std.testing.expect(pp.noteAt(73, 0.0) != null);
    try std.testing.expect(pp.noteAt(77, 0.25) != null);
    // Still in visual mode - the shift can keep walking.
    try std.testing.expect(app.modal.mode == .visual);

    app.handleKey(.{ .char = '>' }, 0); // slide one step later
    try std.testing.expect(pp.noteAt(73, 0.25) != null);
    try std.testing.expect(pp.noteAt(77, 0.5) != null);
    try std.testing.expect(pp.noteAt(73, 0.0) == null);
    // Selection followed the notes (was anchor 0 / cursor 1).
    try std.testing.expectEqual(@as(u16, 2), app.piano_cursor_step);
    try std.testing.expectEqual(@as(u16, 1), app.piano_visual_anchor.?);

    // All-or-nothing at the pattern edges: sliding the selection back two
    // steps would push the first note before beat 0, so nothing moves.
    app.handleKey(.{ .char = '2' }, 0);
    app.handleKey(.{ .char = '<' }, 0);
    try std.testing.expect(pp.noteAt(73, 0.25) != null);
    try std.testing.expect(pp.noteAt(77, 0.5) != null);
    app.handleKey(.escape, 0);
}

test "piano roll visual enter edits every selected note" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25, .velocity = 0.5 });
    pp.addNote(.{ .pitch = 64, .start_beat = 0.25, .duration_beat = 0.25, .velocity = 0.5 });

    app.handleKey(.{ .char = 'V' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.piano_visual_edit);
    app.handleKey(.{ .char = 'k' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.{ .char = ']' }, 0);
    app.handleKey(.{ .char = '>' }, 0);

    const a = pp.noteAt(61, 0.25).?;
    const b = pp.noteAt(65, 0.5).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), a.duration_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), b.duration_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), a.velocity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), b.velocity, 1e-6);
    app.handleKey(.escape, 0);
    try std.testing.expect(!app.piano_visual_edit);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
}

test "piano roll visual edit shifts by beat/octave and inverts" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 67, .start_beat = 0.25, .duration_beat = 0.25 });

    app.handleKey(.{ .char = 'V' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.enter, 0);
    // L slides a whole beat, K lifts an octave.
    app.handleKey(.{ .char = 'L' }, 0);
    app.handleKey(.{ .char = 'K' }, 0);
    try std.testing.expect(pp.noteAt(72, 1.0) != null);
    try std.testing.expect(pp.noteAt(79, 1.25) != null);
    // i folds the pair around its own midpoint: the two pitches swap.
    app.handleKey(.{ .char = 'i' }, 0);
    try std.testing.expect(pp.noteAt(79, 1.0) != null);
    try std.testing.expect(pp.noteAt(72, 1.25) != null);
    app.handleKey(.escape, 0);
    app.handleKey(.escape, 0);
}

test "piano roll visual transpose refuses to clamp at the MIDI range edge" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 127, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 120, .start_beat = 0.0, .duration_beat = 0.25 });
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 120;

    app.handleKey(.{ .char = 'V' }, 0);
    app.handleKey(.{ .char = '+' }, 0); // would push 127 past the top
    try std.testing.expect(pp.noteAt(127, 0.0) != null);
    try std.testing.expect(pp.noteAt(120, 0.0) != null);
    try std.testing.expect(pp.noteAt(121, 0.0) == null);
    app.handleKey(.escape, 0);
}

test "piano roll blockwise visual bounds the selection to the pitch band j/k grows" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 8.0;
    // A three-note chord on step 0. Blockwise selection reaches the bottom
    // two voices only - the thing the old all-pitch selection could not do.
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 64, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 67, .start_beat = 0.0, .duration_beat = 0.25 });
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;

    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expectEqual(@as(?u7, 60), app.piano_visual_pitch_anchor);
    for ("4k") |c| app.handleKey(.{ .char = c }, 0); // grow the band to 60-64
    try std.testing.expectEqual(@as(u7, 64), app.piano_cursor_pitch);
    app.handleKey(.{ .char = '+' }, 0); // transpose only the two notes in it
    try std.testing.expect(pp.noteAt(61, 0.0) != null);
    try std.testing.expect(pp.noteAt(65, 0.0) != null);
    try std.testing.expect(pp.noteAt(67, 0.0) != null); // top voice untouched

    // The band rode along with the transpose, so `d` clears the same notes.
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expect(pp.noteAt(67, 0.0) != null);
    try std.testing.expectEqual(@as(?u7, null), app.piano_visual_pitch_anchor);
}

test "piano roll operator+motion stays linewise: d3l ignores the pitch cursor" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 8.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 84, .start_beat = 0.25, .duration_beat = 0.25 });
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;

    // `d` + a motion takes every pitch across the range it covers, so the
    // note two octaves above the cursor goes too - the pre-existing grammar,
    // unchanged by the pitch axis.
    for ("d3l") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
}

test "piano roll visual o bounces between the selection's ends" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    app.piano_cursor_step = 0;

    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    try std.testing.expectEqual(@as(u16, 2), app.piano_cursor_step);
    app.handleKey(.{ .char = 'o' }, 0);
    try std.testing.expectEqual(@as(u16, 0), app.piano_cursor_step);
    try std.testing.expectEqual(@as(u16, 2), app.piano_visual_anchor.?);
    app.handleKey(.{ .char = 'o' }, 0);
    try std.testing.expectEqual(@as(u16, 2), app.piano_cursor_step);
    app.handleKey(.escape, 0);
}

test "piano roll count paste tiles the range yank back-to-back" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    app.piano_cursor_step = 0;

    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'l' }, 0); // steps 0-1 = half a beat
    app.handleKey(.{ .char = 'y' }, 0);

    app.piano_cursor_step = 4; // beat 1.0
    app.handleKey(.{ .char = '3' }, 0);
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expect(pp.noteAt(60, 1.0) != null);
    try std.testing.expect(pp.noteAt(60, 1.5) != null);
    try std.testing.expect(pp.noteAt(60, 2.0) != null);
    try std.testing.expect(pp.noteAt(60, 2.5) == null);
}

test "pendingCmdText renders operator, count, and visual width" {
    var app = try testApp();
    defer app.deinit();
    var buf: [24]u8 = undefined;
    app.view = .piano_roll;

    try std.testing.expectEqualStrings("", app.pendingCmdText(&buf));
    app.modal.count = 12;
    try std.testing.expectEqualStrings("12", app.pendingCmdText(&buf));
    app.piano_op_pending = 'd';
    try std.testing.expectEqualStrings("d12", app.pendingCmdText(&buf));
    app.piano_op_pending = null;
    app.modal.count = 0;

    app.modal.mode = .visual;
    app.piano_visual_anchor = 2;
    app.piano_cursor_step = 6;
    try std.testing.expectEqualStrings("v5", app.pendingCmdText(&buf));
}

test "piano roll M grabs a note; h/l/j/k drag it as one undo step" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;
    app.handleKey(.enter, 0); // insert C4 at step 0

    app.handleKey(.{ .char = 'M' }, 0); // grab
    app.handleKey(.{ .char = 'l' }, 0); // step 1
    app.handleKey(.{ .char = 'k' }, 0); // C#4
    app.handleKey(.escape, 0); // drop - stays in the roll
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(u7, 61), pp.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), pp.notes[0].start_beat, 1e-9);
    try std.testing.expectEqual(@as(u16, 1), app.piano_cursor_step); // cursor followed

    // The whole drag undoes as one step, back to the grab point.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pp.notes[0].start_beat, 1e-9);

    // M on empty space refuses to grab.
    app.piano_cursor_step = 8;
    app.handleKey(.{ .char = 'M' }, 0);
    try std.testing.expect(!app.piano_grab);
}

test "piano roll Y clones a note through the keyboard grab path" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5, .velocity = 0.7 });
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;

    app.handleKey(.{ .char = 'Y' }, 0);
    app.handleKey(.{ .char = 'L' }, 0);
    app.handleKey(.{ .char = 'k' }, 0);
    app.handleKey(.escape, 0);

    try std.testing.expectEqual(@as(u16, 2), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);
    const clone = pp.noteAt(61, 1.0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), clone.duration_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), clone.velocity, 1e-6);

    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);
}

test "piano roll keyboard edits target any cell covered by a note" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 0.5 });
    app.piano_cursor_pitch = 60;
    app.piano_cursor_step = 2;

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 120, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "1.00b") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "  new ") == null);

    app.handleKey(.{ .char = '>' }, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), pp.noteAt(60, 0.0).?.velocity, 1e-6);
    try std.testing.expectEqual(@as(u16, 0), app.piano_cursor_step);

    app.piano_cursor_step = 2;
    app.handleKey(.{ .char = 'Y' }, 0);
    app.handleKey(.{ .char = 'L' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(@as(u16, 2), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 1.0) != null);

    app.piano_cursor_step = 2;
    app.handleKey(.{ .char = 'x' }, 0);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
}

test "piano roll . repeats the last drag on whatever note sits under the new cursor" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;
    app.handleKey(.enter, 0); // C4 @ step 0
    app.handleKey(.escape, 0); // drop the stamp session enter just started
    app.piano_cursor_step = 4;
    app.handleKey(.enter, 0); // C4 @ step 4 (a second note to repeat onto)
    app.handleKey(.escape, 0); // drop this one too before M-grabbing below

    // Drag the first note: step 0 → 1, pitch 60 → 61 (one semitone up).
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;
    app.handleKey(.{ .char = 'M' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.{ .char = 'k' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(@as(u7, 61), pp.noteAt(61, 0.25).?.pitch);

    // Repeat on the second note (cursor still needs to land on it).
    app.piano_cursor_step = 4;
    app.piano_cursor_pitch = 60;
    app.handleKey(.{ .char = '.' }, 0);
    try std.testing.expect(pp.noteAt(60, 1.0) == null); // moved away from step4/pitch60
    try std.testing.expect(pp.noteAt(61, 1.25) != null); // to step5/pitch61 - same (Δstep,Δpitch)

    // Undo unwinds just the repeat, leaving the first drag intact.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expect(pp.noteAt(60, 1.0) != null);
    try std.testing.expect(pp.noteAt(61, 0.25) != null); // first drag untouched
}

test "piano roll . repeats a count-scaled velocity nudge and a resize" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;
    app.handleKey(.enter, 0);
    app.handleKey(.escape, 0); // drop the stamp session enter just started
    app.piano_cursor_step = 4;
    app.piano_cursor_pitch = 60;
    app.handleKey(.enter, 0);
    app.handleKey(.escape, 0);

    app.piano_cursor_step = 0;
    for ("3<") |c| app.handleKey(.{ .char = c }, 0); // -0.3 velocity (default is 0.85)
    try std.testing.expectApproxEqAbs(@as(f32, 0.85 - 0.3), pp.noteAt(60, 0.0).?.velocity, 1e-6);

    app.piano_cursor_step = 4;
    app.handleKey(.{ .char = '.' }, 0); // repeat the same -0.3 on the other note
    try std.testing.expectApproxEqAbs(@as(f32, 0.85 - 0.3), pp.noteAt(60, 1.0).?.velocity, 1e-6);

    app.piano_cursor_step = 0;
    for ("2]") |c| app.handleKey(.{ .char = c }, 0); // +0.5 beats length
    try std.testing.expectApproxEqAbs(@as(f64, 0.25 + 0.5), pp.noteAt(60, 0.0).?.duration_beat, 1e-9);
    app.piano_cursor_step = 4;
    app.handleKey(.{ .char = '.' }, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25 + 0.5), pp.noteAt(60, 1.0).?.duration_beat, 1e-9);
}

test "GUI piano adapters move and resize through editor history" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });

    try std.testing.expect(piano_ed.moveNoteTo(&app, 60, 0, 62, 2));
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expect(pp.noteAt(62, 0.5) != null);

    try std.testing.expect(piano_ed.resizeNoteSteps(&app, 62, 2, 3));
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), pp.noteAt(62, 0.5).?.duration_beat, 1e-9);

    history.doUndo(&app);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), pp.noteAt(62, 0.5).?.duration_beat, 1e-9);
    history.doUndo(&app);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);
}

test "piano/drum/arrangement . repeats a visual range delete/paste at the new cursor" {
    var app = try testApp();
    defer app.deinit();

    // Piano roll: yank isn't repeatable, but delete+paste are.
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 0.25 }); // step 4
    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'l' }, 0); // select steps 0-1
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    app.piano_cursor_step = 4;
    app.handleKey(.{ .char = '.' }, 0); // repeat: delete a 2-step range at step 4
    try std.testing.expect(pp.noteAt(60, 1.0) == null);

    // Drum grid: same idea, across pads.
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (0..ws.dsp.DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.toggleStep(0, 8);
    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'l' }, 0); // select steps 0-1
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(!dm.stepActive(0, 0));
    app.drum_cursor[1] = 8;
    app.handleKey(.{ .char = '.' }, 0); // repeat: clear steps 8-9
    try std.testing.expect(!dm.stepActive(0, 8));

    // Arrangement: current lane only.
    const mel = &app.session.racks.items[0].pattern_player.?;
    mel.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    try app.session.stampClip(0, 0);
    try app.session.stampClip(0, 10);
    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'l' }, 0); // select bars 0-1
    app.handleKey(.{ .char = 'd' }, 0);
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expect(lane.clipAt(0) == null);
    app.arr_cursor_bar = 40;
    app.handleKey(.{ .char = '.' }, 0); // repeat: delete bars 10-11
    try std.testing.expect(lane.clipAt(1280) == null);
}

test "arrangement . repeats the last clip move at the new cursor" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0);
    try app.session.stampClip(0, 5);

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_cursor_bar = 0;
    for ("8>") |c| app.handleKey(.{ .char = c }, 0);
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expect(lane.clipAt(256) != null);
    try std.testing.expect(lane.clipAt(0) == null);

    app.arr_cursor_bar = 20;
    app.handleKey(.{ .char = '.' }, 0); // repeat: move the bar-5 clip by +2 too
    try std.testing.expect(lane.clipAt(896) != null);
    try std.testing.expect(lane.clipAt(640) == null);
}

test "\".\" is a no-op with nothing to repeat, or after switching to a different editor" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    app.handleKey(.{ .char = '.' }, 0); // nothing yet
    try std.testing.expectEqual(app_mod.RepeatOp.none, app.last_edit);

    // A drum-grid edit shouldn't be replayable from the piano roll.
    app.view = .drum_grid;
    app.drum_track = 2;
    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    app.view = .piano_roll;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    const before = pp.note_count;
    app.handleKey(.{ .char = '.' }, 0);
    try std.testing.expectEqual(before, pp.note_count); // no-op, not a stray delete
}

test "A/B loop: ( ) b arm the region and the transport wraps inside it" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;

    // ( at bar 1, ) at bar 2 → loop bars 2–3 (region [1, 3)), armed.
    app.arr_cursor_bar = 4;
    app.handleKey(.{ .char = '(' }, 0);
    app.arr_cursor_bar = 8;
    app.handleKey(.{ .char = ')' }, 0);
    const p = &app.session.project;
    try std.testing.expect(p.loop_enabled);
    try std.testing.expectEqual(@as(u32, 1), p.loop_start_bar);
    try std.testing.expectEqual(@as(u32, 3), p.loop_end_bar);
    try std.testing.expect(app.dirty);

    // The engine picked the region up in frames (120 bpm 4/4 @48k = 96k/bar)
    // and playback wraps at the loop end.
    const engine = app.session.engine;
    _ = engine.send(.{ .seek_frames = 287_000 }); // just before bar 4
    _ = engine.send(.play);
    var block: [512]ws.types.Sample = undefined;
    for (0..8) |_| engine.process(&block); // crosses 288_000
    try std.testing.expect(engine.transport.position_frames < 288_000);
    try std.testing.expect(engine.transport.position_frames >= 96_000);

    // = toggles it off; playback then runs past the old loop end.
    app.handleKey(.{ .char = '=' }, 0);
    try std.testing.expect(!p.loop_enabled);
    _ = engine.send(.{ .seek_frames = 287_744 });
    engine.process(&block);
    engine.process(&block);
    try std.testing.expect(engine.transport.position_frames >= 288_000);
}

test "command prompt: up/down recall history without corrupting the buffer" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // Submit two commands.
    for (":bpm 100") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    for (":bpm 140") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 140.0), app.session.project.tempo_bpm, 0.001);

    // Enter the prompt fresh, then arrow-up twice recalls oldest-first from the end.
    app.handleKey(.{ .char = ':' }, 0);
    app.handleKey(.arrow_up, 0);
    try std.testing.expectEqualStrings("bpm 140", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.arrow_up, 0);
    try std.testing.expectEqualStrings("bpm 100", app.modal.cmd_buf[0..app.modal.cmd_len]);
    // Past the oldest entry, up is a no-op.
    app.handleKey(.arrow_up, 0);
    try std.testing.expectEqualStrings("bpm 100", app.modal.cmd_buf[0..app.modal.cmd_len]);

    // Down steps forward; past the newest it blanks the line.
    app.handleKey(.arrow_down, 0);
    try std.testing.expectEqualStrings("bpm 140", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.arrow_down, 0);
    try std.testing.expectEqual(@as(usize, 0), app.modal.cmd_len);

    // Readline history keys mirror the arrow keys.
    app.handleKey(.ctrl_p, 0);
    try std.testing.expectEqualStrings("bpm 140", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.ctrl_n, 0);
    try std.testing.expectEqual(@as(usize, 0), app.modal.cmd_len);

    // Arrow left/right don't leak 'h'/'l' into the buffer.
    app.handleKey(.arrow_up, 0); // recall "bpm 140"
    app.handleKey(.arrow_left, 0);
    app.handleKey(.arrow_right, 0);
    try std.testing.expectEqualStrings("bpm 140", app.modal.cmd_buf[0..app.modal.cmd_len]);

    app.handleKey(.escape, 0);
}

test "arrow keys act as hjkl outside command mode" {
    var app = try testApp();
    defer app.deinit();

    app.view = .arrangement;
    app.arr_cursor_bar = 5;
    app.handleKey(.arrow_left, 0);
    try std.testing.expectEqual(@as(u32, 4), app.arr_cursor_bar);
    app.handleKey(.arrow_right, 0);
    try std.testing.expectEqual(@as(u32, 5), app.arr_cursor_bar);

    app.view = .tracks;
    app.cursor = 0;
    app.handleKey(.arrow_down, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    app.handleKey(.arrow_up, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
}

test ":e refuses on unsaved changes; :e! forces and stages the reload" {
    var app = try testApp();
    defer app.deinit();

    app.applyAction(.toggle_mute, 0); // dirty
    try std.testing.expect(app.dirty);

    for (":e some/project.wsj") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(App.ReloadRequest.none, app.pending_reload);

    for (":e! some/project.wsj") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(App.ReloadRequest.load, app.pending_reload);
    try std.testing.expectEqualStrings("some/project.wsj", app.pendingReloadPath());
}

test ":e expands ~ in the requested path" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    const home_c = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.sliceTo(home_c, 0);

    for (":e ~/song.wsj") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(App.ReloadRequest.load, app.pending_reload);
    try std.testing.expect(std.mem.startsWith(u8, app.pendingReloadPath(), home));
    try std.testing.expect(std.mem.indexOf(u8, app.pendingReloadPath(), "~") == null);
}

test ":e! with no path reverts to the current project path" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // No project loaded yet: revert has nothing to revert to.
    app.handleKey(.{ .char = ':' }, 0);
    for ("e!") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(App.ReloadRequest.none, app.pending_reload);

    app.setProjectPath("song.wsj");
    for (":e!") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(App.ReloadRequest.load, app.pending_reload);
    try std.testing.expectEqualStrings("song.wsj", app.pendingReloadPath());
}

test ":new refuses on unsaved changes; :new! forces a blank-session request" {
    var app = try testApp();
    defer app.deinit();
    app.applyAction(.toggle_mute, 0);

    for (":new") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(App.ReloadRequest.none, app.pending_reload);

    for (":new!") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(App.ReloadRequest.blank, app.pending_reload);
}

test "R opens the command prompt pre-filled with :rename <n> for a track" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 1;

    app.handleKey(.{ .char = 'R' }, 0);
    try std.testing.expectEqual(ws.input.Mode.command, app.modal.mode);
    try std.testing.expectEqualStrings("rename 2 ", app.modal.cmd_buf[0..app.modal.cmd_len]);

    for ("keys") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("keys", app.session.project.tracks.items[1].name);
}

test "R opens the command prompt pre-filled with :rename <n> for a pad in the drum grid" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.view = .drum_grid;
    app.drum_cursor = .{ 3, 0 }; // pad 3 = "open"

    _ = drum_ed.handleKey(&app, .{ .char = 'R' });
    try std.testing.expectEqual(ws.input.Mode.command, app.modal.mode);
    try std.testing.expectEqualStrings("rename 4 ", app.modal.cmd_buf[0..app.modal.cmd_len]);

    for ("808oh") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("808oh", app.drumMachine().padName(3));
    // Renaming doesn't touch the actual sample.
    try std.testing.expect(!app.drumMachine().pads[3].?.pad.user_sample);
}

test "R renames the loaded clip in the slicer grid" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;

    _ = slicer_ed.handleKey(&app, .{ .char = 'R' });
    try std.testing.expectEqual(ws.input.Mode.command, app.modal.mode);
    try std.testing.expectEqualStrings("rename ", app.modal.cmd_buf[0..app.modal.cmd_len]);

    for ("break") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("break", app.slicerInst().clipName());
}

test ":rename is adaptive like :load - same command, different target by context" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();

    // No drum grid open, cursor on a track: targets the track.
    app.cursor = 0;
    for (":rename lead") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("lead", app.session.project.tracks.items[0].name);

    // Cursor on a group row: targets the group, not the cursor track.
    app.session.assignTrackGroup(1, try app.session.addGroup("bus"));
    app.tracksRowSync();
    const group_row = for (app.trackRows(), 0..) |r, i| {
        if (std.meta.activeTag(r) == .group) break i;
    } else unreachable;
    app.setTrackRow(group_row);
    for (":rename drumbus") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("drumbus", app.session.groups[0].?.name);
    try std.testing.expectEqualStrings("lead", app.session.project.tracks.items[0].name); // untouched

    // Drum grid open: targets the cursor pad, not the track or a group -
    // and (new) a bare name with no index renames it, unlike the old
    // :pad-rename which always required an explicit number.
    app.drum_track = 2;
    app.view = .drum_grid;
    app.drum_cursor = .{ 3, 0 }; // pad 3 = "open"
    for (":rename crash") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("crash", app.drumMachine().padName(3));
}

test "t taps the tempo from the average interval; a long gap restarts it" {
    var app = try testApp();
    defer app.deinit();

    const tap_ns: i96 = 500 * std.time.ns_per_ms; // 500ms/tap -> 120bpm
    app.handleKey(.{ .char = 't' }, 0);
    try std.testing.expect(!app.dirty); // one tap alone doesn't set anything yet
    app.handleKey(.{ .char = 't' }, tap_ns);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), app.session.project.tempo_bpm, 0.5);
    try std.testing.expect(app.dirty);

    // A third tap at the same spacing keeps the average locked in.
    app.handleKey(.{ .char = 't' }, tap_ns * 2);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), app.session.project.tempo_bpm, 0.5);

    // A gap past the 2s timeout starts a fresh run: the first tap after it
    // just restarts the count (tempo untouched), and a second at 1s spacing
    // proves the average didn't include the huge gap (which would otherwise
    // read as an absurdly slow bpm).
    const after_timeout = tap_ns * 2 + 3 * std.time.ns_per_s;
    app.handleKey(.{ .char = 't' }, after_timeout);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), app.session.project.tempo_bpm, 0.5);
    app.handleKey(.{ .char = 't' }, after_timeout + std.time.ns_per_s);
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), app.session.project.tempo_bpm, 0.5);
}

test "Tab completes an unambiguous mnemonic command name and adds a trailing space" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":restore") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("restore-backup ", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "command Tab-completion hides instrument-scoped commands under the wrong track" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();

    // Cursor on the synth track: "eucl" (drum-scoped) has no in-scope
    // candidate, so Tab is a no-op - cmd_buf is untouched.
    app.cursor = 0;
    for (":eucl") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("eucl", app.modal.cmd_buf[0..app.modal.cmd_len]);

    // Cursor on the drum track: the same prefix now completes in full.
    app.handleKey(.escape, 0);
    app.cursor = 2;
    for (":eucl") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("euclid ", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "Tab cycles named Euclidean rhythm presets" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 2;

    for (":euclid ") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("euclid tresillo", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("euclid cinquillo", app.modal.cmd_buf[0..app.modal.cmd_len]);

    app.handleKey(.escape, 0);
    commands.run(&app, "euclid tresillo");
    const dm = &app.session.racks.items[2].instrument.drum_machine;
    var hits: usize = 0;
    for (dm.midi[0]) |note| if (note != null) {
        hits += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), hits);
}

test "Tab cycles mnemonic command names and ignores compatibility aliases" {
    var app = try testApp();
    defer app.deinit();

    // The short q/qa spellings remain dispatchable but completion only
    // offers the mnemonic quit names, plus in-scope mnemonic commands.
    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("quit", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("quit!", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("quantize", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("quit", app.modal.cmd_buf[0..app.modal.cmd_len]);

    // The same rule turns the short write spelling into mnemonic commands,
    // never the w/wa/wq compatibility forms or the save fallback.
    app.modal.cmd_len = 0;
    app.modal.cmd_cursor = 0;
    for ("w") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("write", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("write-quit", app.modal.cmd_buf[0..app.modal.cmd_len]);

    // "track" matches only the track-* commands (table order: add/del/instrument).
    app.modal.cmd_len = 0;
    app.modal.cmd_cursor = 0;
    for ("track") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("track-add", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("track-del", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("track-instrument", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "suggestion popup highlight tracks the completed candidate" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();
    app.cursor = 2; // drum track: "d" stem now also matches drum-kit/drum-kit-save

    // The hidden `d` alias (for :track-del) never wins a completion. Melodic
    // commands are also out of scope on this drum track.
    for (":d") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("drum-kit", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.escape, 0);

    for (":dr") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0); // -> "drum-kit", with drum-kit-save behind it
    try std.testing.expectEqualStrings("drum-kit", app.modal.cmd_buf[0..app.modal.cmd_len]);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 30 });
    const frame = w.buffered();

    // The row actually highlighted must be the one the buffer holds, not
    // the row one slot further down that a hidden-alias-inflated cycle
    // index would land on (drum-kit-save) - see suggestionSelected.
    var want_buf: [32]u8 = undefined;
    const want_row = std.fmt.bufPrint(&want_buf, "{s}  {s: <16}", .{ style.sel, "drum-kit" }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, frame, want_row) != null);
    var wrong_buf: [32]u8 = undefined;
    const wrong_row = std.fmt.bufPrint(&wrong_buf, "{s}  {s: <16}", .{ style.sel, "drum-kit-save" }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, frame, wrong_row) == null);
}

test "typing after a Tab-cycle starts a fresh cycle instead of continuing the old one" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0); // -> "quit"
    app.handleKey(.tab, 0); // -> "quit!"
    try std.testing.expectEqualStrings("quit!", app.modal.cmd_buf[0..app.modal.cmd_len]);

    // Replacing the completed text and typing "quit" starts a new cycle
    // instead of resuming the stale one at its old index.
    for (0..5) |_| app.handleKey(.backspace, 0);
    for ("quit") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("quit", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "Tab does nothing past the command word for commands with no fixed argument set" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":bpm 1") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("bpm 1", app.modal.cmd_buf[0..app.modal.cmd_len]);

    app.modal.cmd_len = 0;
    app.modal.cmd_cursor = 0;
    for ("zzz") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("zzz", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test ":drum-kit Tab cycles the kit-name argument from the fixed variant list" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // "a" matches "analog" and "acoustic" (variant-table order) - Tab
    // steps between the two full names instead of stalling at "a".
    for (":drum-kit a") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("drum-kit analog", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("drum-kit acoustic", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("drum-kit analog", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test ":synth-preset Tab completes the preset-name argument from the fixed preset list" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // "sub" uniquely matches "sub-bass" - completes in full plus a
    // trailing space, same single-match behavior as command names.
    for (":synth-preset sub") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("synth-preset sub-bass ", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test ":metronome Tab cycles on/off" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // No argument typed yet - Tab steps between "on" and "off" directly
    // rather than stalling at their shared leading "o".
    for (":metronome ") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("metronome on", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("metronome off", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test ":snap-scale pulls off-scale notes onto the nearest tone, and sets the scale inline" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 61, .start_beat = 0.0, .duration_beat = 0.25 }); // C#
    pp.addNote(.{ .pitch = 62, .start_beat = 1.0, .duration_beat = 0.25 }); // D, already in D minor
    pp.addNote(.{ .pitch = 68, .start_beat = 2.0, .duration_beat = 0.25 }); // G#

    // With no scale set there's nothing to snap to - and nothing is touched.
    commands.run(&app, "snap-scale");
    try std.testing.expectEqual(@as(u7, 61), pp.notes[0].pitch);

    // Args set the scale first, exactly as :scale parses them.
    commands.run(&app, "snap-scale d minor");
    try std.testing.expectEqual(@as(?u4, 2), if (app.session.project.scale) |s| s.root else null);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch); // C# -> C
    try std.testing.expectEqual(@as(u7, 62), pp.notes[1].pitch); // untouched
    try std.testing.expectEqual(@as(u7, 67), pp.notes[2].pitch); // G# -> G

    // Idempotent, and undoable as one step.
    commands.run(&app, "snap-scale");
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);
    history.doUndo(&app);
    try std.testing.expectEqual(@as(u7, 61), pp.notes[0].pitch);
}

test ":scale Tab cycles off, root pitch classes, then scale-type names" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":scale ") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("scale off", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("scale C", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("scale C#", app.modal.cmd_buf[0..app.modal.cmd_len]);
    // Cycle through the remaining 10 pitch classes (D..B) to reach the scale-type names.
    for (0..11) |_| app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("scale major", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "Tab does not complete a second argument token" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":drum-kit an ") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("drum-kit an ", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "Tab is a no-op when the cursor isn't at the end of the buffer" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":boun") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.arrow_left, 0); // cursor now mid-line, not at the end
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("boun", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "autosave writes a silent <path>~ backup on a timer, without clearing dirty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try redirectHome(&tmp);

    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/p.wsj", .{&tmp.sub_path});
    app.setProjectPath(path);

    app.applyAction(.toggle_mute, 0); // dirty, no path-having save yet
    try std.testing.expect(app.dirty);

    // now_ns starts far enough past 0 that the interval check isn't trivially
    // satisfied by the zero-valued default (see maybeAutosave's doc comment).
    const base: i96 = 10_000 * std.time.ns_per_s;
    app.tick(base);
    var backup_buf: [96]u8 = undefined;
    const backup_path = try std.fmt.bufPrint(&backup_buf, "{s}~", .{path});
    var loaded = try ws.persist.load(std.testing.allocator, std.testing.io, backup_path);
    defer loaded.deinit();
    try std.testing.expect(app.dirty); // autosave never clears it

    // A second tick soon after doesn't re-attempt (throttled to the interval).
    app.tick(base + std.time.ns_per_s);
    try std.testing.expectEqual(base, app.last_autosave_ns);
}

test "remembered project paths are not truncated to 256 bytes" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    const path = "nested/" ++ ("a" ** 512) ++ "/song.wsj";
    app.setProjectPath(path);

    try std.testing.expectEqualStrings(path, app.projectPath().?);
}

test "autosave is a no-op when clean or when no project path is known" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    app.tick(10_000 * std.time.ns_per_s); // not dirty: nothing to do
    try std.testing.expectEqual(@as(i96, 0), app.last_autosave_ns);

    app.applyAction(.toggle_mute, 0); // dirty, but never saved anywhere
    app.tick(10_000 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(i96, 10_000 * std.time.ns_per_s), app.last_autosave_ns);
}

// ---------------------------------------------------------------------------
// File browser
// ---------------------------------------------------------------------------

/// Points a fresh App's project path at `tmp` (without a real project file
/// there - `openBrowser` only needs the directory) so `:e`/`:load`'s
/// no-arg browse starts inside the sandbox instead of the repo root.
fn appRootedAt(tmp: *std.testing.TmpDir) !App {
    try redirectHome(tmp);
    var app = try App.init(std.testing.allocator, std.testing.io);
    errdefer app.deinit();
    var buf: [96]u8 = undefined;
    const dummy = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/dummy.wsj", .{&tmp.sub_path});
    app.setProjectPath(dummy);
    return app;
}

test "file browser lists dirs first, then extension-filtered files, hiding dotfiles" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "zzz_sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.wav", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.wav", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".hidden.wav", .data = "x" });
    // Anything libsndfile decodes is offered, not only WAV.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "c.flac", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "d.OGG", .data = "x" });

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .sampler);
    app.openBrowser(.load_sample);

    try std.testing.expectEqual(AppView.file_browser, app.view);
    const entries = app.browser_entries.items;
    // dir + 2 .wav + .flac + .OGG; txt and dotfile excluded
    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expect(entries[0].is_dir);
    try std.testing.expectEqualStrings("zzz_sub", entries[0].name);
    try std.testing.expect(!entries[1].is_dir);
    try std.testing.expectEqualStrings("a.wav", entries[1].name);
    try std.testing.expectEqualStrings("b.wav", entries[2].name);
    try std.testing.expectEqualStrings("c.flac", entries[3].name);
    try std.testing.expectEqualStrings("d.OGG", entries[4].name);
}

test "the browser reopens where the last sample came from, but not for projects" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "kits");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "kits/kick.wav", .data = "x" });

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .sampler);

    app.openBrowser(.load_sample);
    app.handleKey(.{ .char = 'l' }, 0); // descend into kits/
    app.handleKey(.enter, 0); // pick kick.wav (dummy bytes: the read counts, the decode fails)

    // Second hunt starts in kits/, not back at the project directory.
    app.openBrowser(.load_sample);
    try std.testing.expect(std.mem.endsWith(u8, app.browser_dir, "kits"));

    // A project lives with the project, not with the samples.
    app.openBrowser(.open_project);
    try std.testing.expect(!std.mem.endsWith(u8, app.browser_dir, "kits"));
}

test "file browser: / fuzzy-searches filenames; n/N repeat and wrap around" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hihat.wav", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "kick.wav", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "snare.wav", .data = "x" });

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .sampler);
    app.openBrowser(.load_sample);
    // Alphabetical: hihat(0), kick(1), snare(2).
    try std.testing.expectEqual(@as(usize, 3), app.browser_entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.browser_cursor);

    for ("/snr") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.browser_cursor); // snare.wav

    // "i" matches hihat and kick (both have an 'i' in the basename), not
    // snare - n/N cycle between the two. (Every name ends in ".wav", so the
    // pattern has to avoid w/a/v or it'd match all three via the extension.)
    for ("/i") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 0), app.browser_cursor); // hihat.wav

    app.handleKey(.{ .char = 'n' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.browser_cursor); // kick.wav
    app.handleKey(.{ .char = 'n' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.browser_cursor); // wraps to hihat.wav
    app.handleKey(.{ .char = 'N' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.browser_cursor); // reverse: kick.wav
}

test "file browser mouse click during live search opens clicked row" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "kit");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "snare.wav", .data = "x" });

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    app.openBrowser(.load_sample);
    for ("/snr") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);

    app.handleMouse(.{ .x = 4, .y = app_mod.content_top + 2, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expect(std.mem.endsWith(u8, app.browser_dir, "kit"));
}

test "file browser: enter descends into a directory, h/backspace returns" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "kit");
    var sub = try tmp.dir.openDir(std.testing.io, "kit", .{ .iterate = true });
    defer sub.close(std.testing.io);
    try sub.writeFile(std.testing.io, .{ .sub_path = "snare.wav", .data = "x" });

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .sampler);
    app.openBrowser(.load_sample);
    try std.testing.expectEqual(@as(usize, 1), app.browser_entries.items.len); // just "kit/"

    app.handleKey(.enter, 0); // descend into kit/
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(@as(usize, 1), app.browser_entries.items.len);
    try std.testing.expectEqualStrings("snare.wav", app.browser_entries.items[0].name);

    for ("h") |c| app.handleKey(.{ .char = c }, 0); // back up to the parent
    try std.testing.expectEqual(@as(usize, 1), app.browser_entries.items.len);
    try std.testing.expect(app.browser_entries.items[0].is_dir);
}

test "file browser: enter on a file loads a sample and closes the browser" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .sampler);

    // Written at the project's own sample rate so loadWav doesn't resample
    // (which would change the sample count we assert below).
    var wav_buf: [64]u8 = undefined;
    var fw = std.Io.Writer.fixed(&wav_buf);
    try ws.wav.write(&fw, app.session.project.sample_rate, 1, &[_]f32{ 0.5, -0.5 }, .pcm16);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "vox.wav", .data = fw.buffered() });

    app.view = .sampler_editor;
    app.sampler_target = .{ .sampler = 0 };
    app.openBrowser(.load_sample);
    try std.testing.expectEqual(@as(usize, 1), app.browser_entries.items.len);

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view); // back to the caller's view
    try std.testing.expect(app.session.racks.items[0].instrument.sampler.pad.user_sample);
    try std.testing.expectEqual(@as(usize, 2), app.session.racks.items[0].instrument.sampler.pad.samples.len);
}

test "file browser: v selects a range, enter loads it into consecutive pads" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .drum_machine);

    var wav_buf: [64]u8 = undefined;
    var fw = std.Io.Writer.fixed(&wav_buf);
    try ws.wav.write(&fw, app.session.project.sample_rate, 1, &[_]f32{ 0.5, -0.5 }, .pcm16);
    for ([_][]const u8{ "a.wav", "b.wav", "c.wav", "d.wav" }) |name|
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = fw.buffered() });

    app.view = .drum_grid;
    app.drum_track = 0;
    app.drum_cursor = .{ 1, 0 }; // filling starts at pad 2, not pad 1
    app.openBrowser(.{ .load_pad = 1 });
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'j' }, 0);
    app.handleKey(.{ .char = 'j' }, 0); // a..c selected, d left out
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    app.handleKey(.enter, 0);

    try std.testing.expectEqual(AppView.drum_grid, app.view);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(app.browser_visual_anchor == null);
    try std.testing.expect(app.dirty);

    const dm = &app.session.racks.items[0].instrument.drum_machine;
    try std.testing.expect(dm.pads[0] == null); // below the cursor pad, untouched
    for ([_][]const u8{ "a", "b", "c" }, 1..) |stem, pad| {
        const p = dm.pads[pad] orelse return error.PadNotLoaded;
        try std.testing.expectEqualStrings(stem, ws.dsp.pad.trimmedName(&p.pad.name));
        try std.testing.expect(p.pad.user_sample);
    }
    try std.testing.expect(dm.pads[4] == null); // d.wav was outside the selection
}

test "file browser: v in an empty directory arms nothing (the showcmd chip would slice it)" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "empty");

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .drum_machine);
    app.view = .drum_grid;
    app.openBrowser(.{ .load_pad = 0 });
    app.handleKey(.{ .char = 'l' }, 0); // descend into empty/
    try std.testing.expectEqual(@as(usize, 0), app.browser_entries.items.len);

    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expect(app.browser_visual_anchor == null);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("", app.pendingCmdText(&buf));
}

test "file browser: showcmd clamps both ends of a stale visual range" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.wav", .data = "x" });

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .drum_machine);
    app.openBrowser(.{ .load_pad = 0 });
    app.modal.mode = .visual;
    app.browser_visual_anchor = 10;
    app.browser_cursor = 12;

    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("v1", app.pendingCmdText(&buf));

    app.browser_cursor = 0;
    app.handleKey(.enter, 0);
    try std.testing.expect(app.browser_visual_anchor == null);
}

test "file browser: esc/q cancels without picking, restoring the previous view" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.wav", .data = "x" });

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .sampler);
    app.openBrowser(.load_sample);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expectEqual(@as(usize, 0), app.browser_entries.items.len); // freed on close
    try std.testing.expect(!app.session.racks.items[0].instrument.sampler.pad.user_sample);
}

test ":load with no path browses and targets the selected instrument" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();

    // Blank track 0: no sampler/drum-machine to receive the load.
    for (":load") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "load: select");

    // With a sampler track selected, :load opens the sample browser.
    try app.session.setInstrument(0, .sampler);
    for (":load") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    app.handleKey(.escape, 0);

    // With a drum-machine track selected, :load targets the cursor pad.
    try app.session.setInstrument(0, .drum_machine);
    app.drum_cursor[0] = 2;
    for (":load") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(@as(u8, 2), app.browser_purpose.load_pad);
}

test ":load routes synth and slicer editor views to their audio types" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();

    try app.session.setInstrument(0, .poly_synth);
    app.view = .synth_editor;
    app.synth_cursor = 6; // OSC B
    for (":load") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(ws.dsp.PolySynth.OscSlot.b, app.browser_purpose.load_wavetable);
    app.handleKey(.escape, 0);

    try app.session.setInstrument(0, .slicer);
    app.view = .slicer_grid;
    for (":load") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(app_mod.BrowserPurpose.load_slice, app.browser_purpose);
}

test "entering an empty slicer track opens its editor before its file browser" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();

    try app.session.setInstrument(0, .slicer);
    app.cursor = 0;
    app.view = .tracks;
    app.handleKey(.enter, 0);

    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(app_mod.BrowserPurpose.load_slice, app.browser_purpose);
    try std.testing.expectEqual(AppView.sampler_editor, app.prev_view);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);

    // Once a clip is loaded, re-entering the track lands in the slice panel
    // itself instead of bouncing back to the browser.
    const sl = app.slicerInst();
    sl.sliceInto(1);
    app.allocator.free(sl.samples);
    sl.samples = try app.allocator.alloc(f32, 4);
    app.view = .tracks;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
}

test "enter in an editor with nothing loaded opens that editor's file browser" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();

    // Slicer grid: no clip, so there are no steps to toggle.
    try app.session.setInstrument(0, .slicer);
    app.view = .slicer_grid;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(app_mod.BrowserPurpose.load_slice, app.browser_purpose);
    app.handleKey(.escape, 0);

    // With a clip in, enter goes back to toggling the cursor step.
    const sl = app.slicerInst();
    app.allocator.free(sl.samples);
    sl.samples = try app.allocator.alloc(f32, 8);
    sl.sliceInto(2);
    app.view = .slicer_grid;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.slicer_grid, app.view);
    try std.testing.expect(sl.stepActive(0, 0));

    // Sampler editor on an empty drum pad.
    try app.session.setInstrument(0, .drum_machine);
    app.sampler_target = .{ .drum = 0 };
    app.drum_cursor[0] = 3;
    app.view = .sampler_editor;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(@as(u8, 3), app.browser_purpose.load_pad);
    app.handleKey(.escape, 0);

    // Sampler editor on an empty standalone Sampler.
    try app.session.setInstrument(0, .sampler);
    app.sampler_target = .{ .sampler = 0 };
    app.view = .sampler_editor;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(app_mod.BrowserPurpose.load_sample, app.browser_purpose);
    app.handleKey(.escape, 0);

    // Soundfont editor with no font.
    try app.session.setInstrument(0, .soundfont);
    app.view = .soundfont_editor;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(app_mod.BrowserPurpose.load_soundfont, app.browser_purpose);
}

test "loading a standalone sample restores prior sampler state on undo" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .sampler);

    const old_sample_count = app.session.racks.items[0].instrument.sampler.pad.samples.len;
    const old_root_note = app.session.racks.items[0].instrument.sampler.root_note;
    var wav_buf: [64]u8 = undefined;
    var fw = std.Io.Writer.fixed(&wav_buf);
    try ws.wav.write(&fw, app.session.project.sample_rate, 1, &[_]f32{ 0.1, 0.2, 0.3 }, .pcm16);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sample.wav", .data = fw.buffered() });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/sample.wav", .{&tmp.sub_path});

    commands_load.loadSampleFromPath(&app, path);
    try std.testing.expectEqual(@as(usize, 3), app.session.racks.items[0].instrument.sampler.pad.samples.len);

    history.doUndo(&app);
    try std.testing.expectEqual(old_sample_count, app.session.racks.items[0].instrument.sampler.pad.samples.len);
    try std.testing.expectEqual(old_root_note, app.session.racks.items[0].instrument.sampler.root_note);
}

test ":load in arrangement refuses without a sampler track, then targets a whole clip" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();

    app.view = .arrangement;
    for (":load") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "load: select");

    try app.session.setInstrument(0, .sampler);
    for (":load") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(app_mod.BrowserPurpose.load_clip, app.browser_purpose);
    app.handleKey(.escape, 0);

    // Contrived tempo so 1 frame = 1 beat exactly (sr*60/bpm == 1), keeping
    // the wav tiny while the beats math stays exact and easy to assert on.
    app.session.project.tempo_bpm = @as(f64, @floatFromInt(app.session.project.sample_rate)) * 60.0;
    const old_sample_count = app.session.racks.items[0].instrument.sampler.pad.samples.len;
    const old_user_sample = app.session.racks.items[0].instrument.sampler.pad.user_sample;
    const old_note_count = app.session.racks.items[0].pattern_player.?.note_count;
    const old_length_beats = app.session.racks.items[0].pattern_player.?.length_beats;

    var wav_buf: [64]u8 = undefined;
    var fw = std.Io.Writer.fixed(&wav_buf);
    try ws.wav.write(&fw, app.session.project.sample_rate, 1, &[_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 }, .pcm16);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/vox.wav", .{&tmp.sub_path});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "vox.wav", .data = fw.buffered() });

    app.arr_cursor_bar = 2;
    commands_load.loadClipFromPath(&app, path);

    try std.testing.expect(app.session.racks.items[0].instrument.sampler.pad.user_sample);
    try std.testing.expectEqual(@as(usize, 5), app.session.racks.items[0].instrument.sampler.pad.samples.len);

    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch); // default root_note
    try std.testing.expectEqual(@as(f32, 1.0), pp.notes[0].velocity);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), pp.length_beats, 1e-9);

    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try std.testing.expectEqual(@as(u32, 64), lane.clips.items[0].start_tick);
    try std.testing.expectEqual(@as(u32, 256), lane.clips.items[0].length_ticks); // ceil(5 beats / 4 per bar)

    history.doUndo(&app);
    try std.testing.expectEqual(old_sample_count, app.session.racks.items[0].instrument.sampler.pad.samples.len);
    try std.testing.expectEqual(old_user_sample, app.session.racks.items[0].instrument.sampler.pad.user_sample);
    try std.testing.expectEqual(old_note_count, app.session.racks.items[0].pattern_player.?.note_count);
    try std.testing.expectEqual(old_length_beats, app.session.racks.items[0].pattern_player.?.length_beats);
    try std.testing.expectEqual(@as(usize, 0), app.session.arrangement.lane(0).?.clips.items.len);
}

test ":e with no path always browses; selecting a file refuses when dirty" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "song.wsj", .data = "x" });

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    for (":e") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(@as(usize, 1), app.browser_entries.items.len);
    try std.testing.expectEqualStrings("song.wsj", app.browser_entries.items[0].name);
    app.handleKey(.escape, 0);

    // Browsing itself is safe even with unsaved changes, so the picker
    // still opens - but the refusal warns pre-emptively (right here) rather
    // than after the user's already hunted down a file to select.
    app.applyAction(.toggle_mute, 0); // dirty
    for (":e") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "unsaved changes");

    app.handleKey(.enter, 0); // select "song.wsj"
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "unsaved changes");
}

// ---------------------------------------------------------------------------
// Mouse - one representative test per view; each replays the exact row/col
// math its handleMouse (see editors/*.zig) derives from the view's own
// render layout, driven straight through App.handleMouse (bypassing
// terminal.decode, same as handleKey's tests bypass raw byte parsing).
// ---------------------------------------------------------------------------

// Every mouse test below phrases its rows as `content_top + n`, so they all
// move with the constant instead of checking it. This one checks it: the
// view's own first row (each view opens with its title line) has to land on
// screen row `content_top` in a real frame. It didn't for a while - the
// header lost its divider row and `content_top` kept counting it, putting
// every click one row above the cell it was aimed at.
test "content_top matches where a rendered frame actually starts the view" {
    var app = try testApp();
    defer app.deinit();

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });

    var screen_row: usize = 0;
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    while (lines.next()) |line| : (screen_row += 1) {
        if (std.mem.indexOf(u8, line, "TRACKS") != null) break;
    } else return error.TitleRowNotRendered;
    try std.testing.expectEqual(@as(usize, app_mod.content_top), screen_row);
}

test "mouse click on a tracks-view row selects and opens it" {
    var app = try testApp();
    defer app.deinit();

    // A real run loop always draws before dispatching input, which is what
    // populates `track_rows_shown` (needed to locate the pinned master row
    // under scrolling - see App.tracksMouse).
    var buf: [8 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 24 });

    // row 0 = "TRACKS" title; track i sits at row i+1 (see App.tracksMouse).
    app.handleMouse(.{ .x = 5, .y = app_mod.content_top + 3, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(usize, 2), app.cursor); // track 2 = drum machine
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
}

test "mouse scroll in tracks view moves the cursor like j/k" {
    var app = try testApp();
    defer app.deinit();

    app.handleMouse(.{ .x = 5, .y = app_mod.content_top, .button = .none, .kind = .scroll_down }, 80, 24, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    app.handleMouse(.{ .x = 5, .y = app_mod.content_top, .button = .none, .kind = .scroll_up }, 80, 24, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
}

test "tracks view scrolls to keep the cursor visible with many tracks" {
    var app = try testApp();
    defer app.deinit();

    // testApp() ships 4 tracks; add enough more that a small terminal can't
    // show them all at once alongside the pinned master row.
    for (0..20) |_| app.doTrackAdd(null);
    const track_count = app.session.project.tracks.items.len;
    try std.testing.expect(track_count > 20);

    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    app.cursor = track_count - 1;
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 15 });
    const frame = w.buffered();
    // The cursor's track must actually be drawn on screen...
    try std.testing.expect(std.mem.indexOf(u8, frame, ">") != null);
    // ...and the pinned master row must still be visible alongside it.
    try std.testing.expect(std.mem.indexOf(u8, frame, "MASTER") != null);

    // Scrolling back to the top must bring track 1 back into view.
    app.cursor = 0;
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 15 });
    try std.testing.expectEqual(@as(usize, 0), app.track_scroll);
}

test "arrangement view scrolls lanes to keep the cursor visible with many tracks" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;

    for (0..20) |_| app.doTrackAdd(null);
    const lane_count = app.session.project.tracks.items.len;
    try std.testing.expect(lane_count > 20);

    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    app.cursor = lane_count - 1;
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 15 });
    const frame = w.buffered();
    // The cursor's lane must actually be on screen - every auto-added
    // track's name truncates to the same "track " (6 chars, digits cut
    // off), so check the lane-number column instead of the name.
    var num_buf: [4]u8 = undefined;
    const last_num = try std.fmt.bufPrint(&num_buf, "{d}", .{lane_count});
    try std.testing.expect(std.mem.indexOf(u8, frame, last_num) != null);

    // A click at the scrolled window's first lane row must resolve to the
    // scrolled-in lane, not lane 0 (see App.arr_scroll_lane's mouse fix).
    app.handleMouse(.{ .x = 2, .y = app_mod.content_top + 2, .button = .left, .kind = .press }, 80, 15, 0);
    try std.testing.expectEqual(app.arr_scroll_lane, app.cursor);

    // Scrolling back to the top must bring lane 0 back into view.
    app.cursor = 0;
    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 80, .rows = 15 });
    try std.testing.expectEqual(@as(usize, 0), app.arr_scroll_lane);
}

test "mouse click toggles a drum step and drag paints a run of them" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.view = .drum_grid;

    // The drum grid ships empty; pad 0 has steps 1-3 inactive.
    try std.testing.expect(!app.drumMachine().stepActive(0, 1));
    try std.testing.expect(!app.drumMachine().stepActive(0, 2));
    try std.testing.expect(!app.drumMachine().stepActive(0, 3));

    // row 0 = title, row 1 = bar ruler, row 2 = pad 0. Cell columns (10-char
    // gutter, 1-char "│" every beat, 3-char cells): step1 x in [14,17),
    // step2 x in [17,20), step3 x in [20,23) - see editors/drum.zig's stepAt.
    const row = app_mod.content_top + 2;
    app.handleMouse(.{ .x = 15, .y = row, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expect(app.drumMachine().stepActive(0, 1));

    app.handleMouse(.{ .x = 18, .y = row, .button = .left, .kind = .drag }, 80, 24, 0);
    try std.testing.expect(app.drumMachine().stepActive(0, 2));

    app.handleMouse(.{ .x = 21, .y = row, .button = .left, .kind = .drag }, 80, 24, 0);
    try std.testing.expect(app.drumMachine().stepActive(0, 3));

    app.handleMouse(.{ .x = 21, .y = row, .button = .left, .kind = .release }, 80, 24, 0);
    try std.testing.expect(app.drum_paint_state == null);
}

test "mouse click on an empty piano-roll cell inserts a note" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    app.piano_scroll_step = 0;
    app.piano_scroll_pitch = 72;
    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);

    // 3 header rows; row 3 = pitch 72 (scroll_pitch - 0). Step 0's 3-char
    // cell starts right after the 6-char gutter.
    app.handleMouse(.{ .x = 7, .y = app_mod.content_top + 3, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(u7, 72), pp.notes[0].pitch);
}

test "piano-roll mouse grabs sustained note bodies without jumping the onset" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    app.piano_scroll_step = 0;
    app.piano_scroll_pitch = 72;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 72, .start_beat = 0.0, .duration_beat = 1.0 });

    const row = app_mod.content_top + 3;
    app.handleMouse(.{ .x = 13, .y = row, .button = .left, .kind = .press }, 80, 24, 0); // note body, step 2
    app.handleMouse(.{ .x = 16, .y = row, .button = .left, .kind = .drag }, 80, 24, 0); // pointer moves one step
    app.handleMouse(.{ .x = 16, .y = row, .button = .left, .kind = .release }, 80, 24, 0);

    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expect(pp.noteAt(72, 0.25) != null);
}

test "piano-roll draw-drag sizes the note it just placed, and that length sticks" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    app.piano_scroll_step = 0;
    app.piano_scroll_pitch = 72;
    app.piano_note_len = 0.25; // one 16th
    const pp = &app.session.racks.items[0].pattern_player.?;

    const row = app_mod.content_top + 3; // pitch 72
    app.handleMouse(.{ .x = 7, .y = row, .button = .left, .kind = .press }, 80, 24, 0); // step 0
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expect(app.piano_mouse_draw);
    // The press alone leaves the default length in place.
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), pp.notes[0].duration_beat, 1e-9);

    // Drag out to step 3 (x in [15,18)) - 4 steps = 1 beat.
    app.handleMouse(.{ .x = 16, .y = row, .button = .left, .kind = .drag }, 80, 24, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[0].duration_beat, 1e-9);
    app.handleMouse(.{ .x = 16, .y = row, .button = .left, .kind = .release }, 80, 24, 0);
    try std.testing.expect(!app.piano_mouse_draw);
    // FL's length chase: the next note drawn inherits what was drawn here.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), app.piano_note_len, 1e-9);

    // And the whole gesture is one undo entry, not insert-then-resize.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
}

test "piano-roll right-drag erases every note it sweeps, as one undo entry" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    app.piano_scroll_step = 0;
    app.piano_scroll_pitch = 72;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 72, .start_beat = 0.0, .duration_beat = 0.5 }); // covers steps 0-1
    pp.addNote(.{ .pitch = 71, .start_beat = 0.5, .duration_beat = 0.25 }); // step 2, row below

    // Press over the *body* of the first note (step 1, not its start) - the
    // brush erases what it sweeps over, not only what starts under it.
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 3, .button = .right, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expect(app.piano_erase_active);
    // Sweep on to the second note while the button stays down.
    app.handleMouse(.{ .x = 13, .y = app_mod.content_top + 4, .button = .right, .kind = .drag }, 80, 24, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
    app.handleMouse(.{ .x = 13, .y = app_mod.content_top + 4, .button = .right, .kind = .release }, 80, 24, 0);
    try std.testing.expect(!app.piano_erase_active);

    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(u16, 2), pp.note_count); // both back in one step
}

test "shift+drag clones a piano-roll note instead of moving it" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    app.piano_scroll_step = 0;
    app.piano_scroll_pitch = 72;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 72, .start_beat = 0.0, .duration_beat = 0.25, .velocity = 0.5 });

    app.handleMouse(.{ .x = 7, .y = app_mod.content_top + 3, .button = .left, .kind = .press, .shift = true }, 80, 24, 0);
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 4, .button = .left, .kind = .drag, .shift = true }, 80, 24, 0);
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 4, .button = .left, .kind = .release, .shift = true }, 80, 24, 0);

    try std.testing.expectEqual(@as(u16, 2), pp.note_count);
    // The original is back where the drag started, carrying its velocity.
    const source = pp.noteAt(72, 0.0) orelse return error.CloneMissing;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), source.velocity, 1e-6);
    try std.testing.expect(pp.noteStartsAt(71, 0.25)); // the dragged copy

    // One undo takes the whole gesture back out.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
}

test "piano-roll gutter click and ctrl+scroll move the pitch cursor" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    app.piano_scroll_pitch = 72;
    app.piano_cursor_pitch = 72;
    const pp = &app.session.racks.items[0].pattern_player.?;

    // Gutter (x < 6) is the preview keyboard: selects the row, places nothing.
    app.handleMouse(.{ .x = 2, .y = app_mod.content_top + 5, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(u7, 70), app.piano_cursor_pitch);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);

    // ctrl+scroll is the octave jump (plain scroll is a semitone).
    app.handleMouse(.{ .x = 20, .y = app_mod.content_top + 3, .button = .none, .kind = .scroll_up, .ctrl = true }, 80, 24, 0);
    try std.testing.expectEqual(@as(u7, 82), app.piano_cursor_pitch);
    app.handleMouse(.{ .x = 20, .y = app_mod.content_top + 3, .button = .none, .kind = .scroll_down }, 80, 24, 0);
    try std.testing.expectEqual(@as(u7, 81), app.piano_cursor_pitch);
}

test "mouse drag moves an existing piano-roll note; a plain click-release toggles it off" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    app.piano_scroll_step = 0;
    app.piano_scroll_pitch = 72;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 72, .start_beat = 0.0, .duration_beat = 0.25 });

    const row0 = app_mod.content_top + 3; // pitch 72, step 0
    app.handleMouse(.{ .x = 7, .y = row0, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expect(app.piano_grab);

    // Drag to step 1 (x in [9,12)), pitch 71 (one row down).
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 4, .button = .left, .kind = .drag }, 80, 24, 0);
    try std.testing.expectEqual(@as(u7, 71), pp.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), pp.notes[0].start_beat, 1e-9);

    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 4, .button = .left, .kind = .release }, 80, 24, 0);
    try std.testing.expect(!app.piano_grab);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count); // moved, not duplicated

    // A fresh press-then-release with no drag in between toggles it off
    // (matches enter's toggle) rather than leaving a no-op grab behind.
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 4, .button = .left, .kind = .press }, 80, 24, 0);
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 4, .button = .left, .kind = .release }, 80, 24, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
}

test "mouse drag moves an arrangement clip" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0); // 1-bar clip at bar 0, lane 0

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_scroll_bar = 0;
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expect(lane.clipAt(0) != null);

    // row 0 = title, row 1 = ruler, row 2 = lane 0. gutter=13, cell_w=4 -
    // bar 0's cell is x in [13,17), bar 2's is x in [21,25).
    const row = app_mod.content_top + 2;
    app.handleMouse(.{ .x = 14, .y = row, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(u32, 0), app.arr_drag_bar.?);

    app.handleMouse(.{ .x = 22, .y = row, .button = .left, .kind = .drag }, 80, 24, 0);
    try std.testing.expect(lane.clipAt(0) == null);
    try std.testing.expect(lane.clipAt(64) != null);

    app.handleMouse(.{ .x = 22, .y = row, .button = .left, .kind = .release }, 80, 24, 0);
    try std.testing.expect(app.arr_drag_bar == null);
}

test "right-click always erases a drum step, and a right-drag erases a run of them" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.view = .drum_grid;

    const dm = app.drumMachine();
    dm.toggleStep(0, 1); // step 1 starts ON, so a plain toggle would turn it back on
    try std.testing.expect(dm.stepActive(0, 1));
    try std.testing.expect(!dm.stepActive(0, 2));

    // Same cell geometry as the left-click paint test above.
    const row = app_mod.content_top + 2;
    app.handleMouse(.{ .x = 15, .y = row, .button = .right, .kind = .press }, 80, 24, 0);
    try std.testing.expect(!dm.stepActive(0, 1));

    app.handleMouse(.{ .x = 18, .y = row, .button = .right, .kind = .drag }, 80, 24, 0);
    try std.testing.expect(!dm.stepActive(0, 2)); // was already off, stays off

    app.handleMouse(.{ .x = 18, .y = row, .button = .right, .kind = .release }, 80, 24, 0);
    try std.testing.expect(app.drum_paint_state == null);
}

test "right-click deletes a piano-roll note without needing a grab/release cycle" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    app.piano_scroll_step = 0;
    app.piano_scroll_pitch = 72;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 72, .start_beat = 0.0, .duration_beat = 0.25 });

    app.handleMouse(.{ .x = 7, .y = app_mod.content_top + 3, .button = .right, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
    try std.testing.expect(!app.piano_grab); // no grab session was ever opened
}

test "right-click cuts an arrangement clip without starting a drag" {
    var app = try testApp();
    defer app.deinit();
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try app.session.stampClip(0, 0); // 1-bar clip at bar 0, lane 0

    app.view = .arrangement;
    app.cursor = 0;
    app.arr_scroll_bar = 0;
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expect(lane.clipAt(0) != null);

    const row = app_mod.content_top + 2;
    app.handleMouse(.{ .x = 14, .y = row, .button = .right, .kind = .press }, 80, 24, 0);
    try std.testing.expect(lane.clipAt(0) == null);
    try std.testing.expect(app.arr_drag_bar == null);
}

test "mouse scroll over a synth param row selects and nudges it" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.enter, 0); // opens the synth editor for track 0
    try std.testing.expectEqual(AppView.synth_editor, app.view);

    const old_macro = app.session.racks.items[0].instrument.poly_synth.macro1;

    // MACROS' first row (id 99) is MAIN subview's first content row; +1 for
    // header row above it, +1 again since this "row" param is 1-based
    // content-row numbering (row 1 == the first line below the title - see
    // editors/synth.zig's paramAtRow). synth_scroll starts at 0, so this
    // small a row is on-screen even at this test's 24-row terminal height.
    const row = app_mod.content_top + 2;
    app.handleMouse(.{ .x = 20, .y = row, .button = .none, .kind = .scroll_up }, 80, 24, 0);
    try std.testing.expectEqual(@as(u8, 99), app.synth_cursor);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.racks.items[0].instrument.poly_synth.macro1 > old_macro);
}

test "mouse click/drag on a sampler waveform moves the nearer marker" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.sampler_target = .{ .drum = 2 };
    app.drum_cursor[0] = 0;
    app.view = .sampler_editor;

    try std.testing.expectEqual(@as(f32, 0.0), app.drumMachine().pads[0].?.pad.start_norm);
    try std.testing.expectEqual(@as(f32, 1.0), app.drumMachine().pads[0].?.pad.end_norm);

    // Drum bank occupies rows 1-3. It must not behave like waveform.
    var block: [64]types.Sample = undefined;
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 2, .button = .left, .kind = .press }, 80, 48, 0);
    app.session.engine.process(&block);
    try std.testing.expectEqual(@as(f32, 0.0), app.drumMachine().pads[0].?.pad.start_norm);

    // Waveform starts after title and bank. x=10 is nearer start marker.
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 5, .button = .left, .kind = .press }, 80, 48, 0);
    app.session.engine.process(&block);
    try std.testing.expect(app.drumMachine().pads[0].?.pad.start_norm > 0.0);
    try std.testing.expectEqual(@as(f32, 1.0), app.drumMachine().pads[0].?.pad.end_norm); // untouched

    app.handleMouse(.{ .x = 20, .y = app_mod.content_top + 5, .button = .left, .kind = .drag }, 80, 48, 0);
    app.session.engine.process(&block);
    try std.testing.expect(app.drumMachine().pads[0].?.pad.start_norm > 0.1);

    app.handleMouse(.{ .x = 20, .y = app_mod.content_top + 5, .button = .left, .kind = .release }, 80, 48, 0);
    try std.testing.expect(app.sampler_drag_marker == null);

    // Param rows sit after prefix(4) + the waveform + SAMPLE's header, and
    // the waveform takes whatever the param list leaves of the 48-5 body.
    const wave = @min(sampler_ed.wave_max_rows, (48 - 5) -| (4 + sampler_ed.paramLineCount(true)));
    app.sampler_param = 7;
    app.handleMouse(.{ .x = 20, .y = app_mod.content_top + 4 + wave + 1, .button = .none, .kind = .scroll_up }, 80, 48, 0);
    try std.testing.expectEqual(@as(u8, 0), app.sampler_param);
}

test "empty sampler panel ignores hidden mouse controls" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.sampler_target = .{ .slice = 0 };
    app.view = .sampler_editor;
    app.sampler_param = 0;

    app.handleMouse(.{ .x = 20, .y = app_mod.content_top + 20, .button = .none, .kind = .scroll_up }, 80, 48, 0);
    try std.testing.expectEqual(@as(u8, 0), app.sampler_param);
    try std.testing.expect(!app.dirty);
}

test "soundfont mouse rows skip the section headers, and hit nothing while the empty state shows" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .soundfont);
    app.soundfont_track = 0;
    app.view = .soundfont_editor;

    // No .sf2 loaded, so the view draws its "No SoundFont loaded" state -
    // none of those rows is a param row, however tempting the arithmetic.
    app.soundfont_param = 0;
    for (0..8) |r| {
        app.handleMouse(.{ .x = 4, .y = @intCast(app_mod.content_top + r), .button = .left, .kind = .press }, 80, 24, 0);
        try std.testing.expectEqual(@as(u8, 0), app.soundfont_param);
    }

    // The row table itself: title(0), OUT(1), gain/pan/transpose(2-4),
    // PROGRAM(5), preset(6) - mirroring views/soundfont.zig.
    try std.testing.expectEqual(@as(?u8, null), soundfont_ed.rowParamForTest(0));
    try std.testing.expectEqual(@as(?u8, null), soundfont_ed.rowParamForTest(1));
    try std.testing.expectEqual(@as(?u8, 0), soundfont_ed.rowParamForTest(2));
    try std.testing.expectEqual(@as(?u8, 2), soundfont_ed.rowParamForTest(4));
    try std.testing.expectEqual(@as(?u8, null), soundfont_ed.rowParamForTest(5));
    try std.testing.expectEqual(@as(?u8, 3), soundfont_ed.rowParamForTest(6));
}

test "mouse click on a chain-strip slot box focuses that slot" {
    var app = try testApp();
    defer app.deinit();
    const fx = &app.session.racks.items[0].fx;
    const alloc = app.session.allocator;
    const sr = app.session.project.sample_rate;
    _ = try fx.insert(alloc, 0, .eq, sr);
    _ = try fx.insert(alloc, 1, .comp, sr);
    _ = try fx.insert(alloc, 2, .reverb, sr);
    spectrum_ed.switchToTrack(&app, 0);
    try std.testing.expectEqual(@as(usize, 0), app.fx_focus);

    // Strip middle row is view row 2; the second slot box (COMP) spans
    // columns 11..18 (see editors/fx_editor.zig's strip geometry).
    const row = app_mod.content_top + 2;
    app.handleMouse(.{ .x = 12, .y = row, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(usize, 1), app.fx_focus);

    // A click on the arrow between boxes changes nothing.
    app.handleMouse(.{ .x = 10, .y = row, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(usize, 1), app.fx_focus);

    // Third box (REVERB) starts at column 3 + 2*8 = 19.
    app.handleMouse(.{ .x = 20, .y = row, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(usize, 2), app.fx_focus);

    // The "+" box sits one slot past the last unit - clicking it opens the
    // FX picker for this track's chain.
    app.handleMouse(.{ .x = 28, .y = row, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(app_mod.AppView.fx_picker, app.view);
    try std.testing.expectEqual(app_mod.AppView.track_spectrum, app.fx_picker_return);
}

test "clicking the EQ band-detail rows lands on the field actually drawn there" {
    // Regression: the click-side row math carried its own hand-copied
    // flat-offset constants instead of sharing the render side's formula,
    // and drifted 2 rows out of sync with it at ordinary terminal sizes -
    // every click on the EQ body resolved to the wrong field (e.g.
    // clicking "kind" edited "q" instead). rows=24 here is non-compact
    // (compact triggers under 16) and short enough to hit the clamp where
    // the old click-side formula (9/12) and the render-side one (7/10)
    // actually disagreed.
    var app = try testApp();
    defer app.deinit();
    const fx = &app.session.racks.items[0].fx;
    const alloc = app.session.allocator;
    const sr = app.session.project.sample_rate;
    _ = try fx.insert(alloc, 0, .eq, sr);
    spectrum_ed.switchToTrack(&app, 0);

    const rows: usize = 24;
    const compact = rows < 16;
    const visual_rows = spectrum_ed.eqVisualRows(rows, compact, spectrum_ed.eq_band_rows);
    const overview_row0 = visual_rows + 1;
    // eq_band_rows = eq_overview_rows + eq_header_rows + eq_fields_per_band
    // (all pub except the first two, which only matter as this difference).
    const detail_row0 = overview_row0 + (spectrum_ed.eq_band_rows - spectrum_ed.eq_fields_per_band);
    const kind_row = spectrum_ed.bodyRow0(compact) + detail_row0;

    app.handleMouse(.{ .x = 5, .y = app_mod.content_top + @as(u16, @intCast(kind_row)), .button = .left, .kind = .press }, 80, @intCast(rows), 0);
    try std.testing.expectEqual(spectrum_ed.eq_field_kind, spectrum_ed.eqBandField(app.fx_param).field);
}

test "FX picker inserts after the focused slot and focuses the new unit" {
    var app = try testApp();
    defer app.deinit();
    spectrum_ed.switchToTrack(&app, 0);
    try std.testing.expectEqual(@as(usize, 0), app.session.racks.items[0].fx.units.items.len);

    // Chain empty: 'a' opens the picker; enter inserts the highlighted kind
    // (row 0 = gate) as the first unit and returns to the chain view.
    try std.testing.expect(spectrum_ed.handleKey(&app, .{ .char = 'a' }));
    try std.testing.expectEqual(app_mod.AppView.fx_picker, app.view);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(app_mod.AppView.track_spectrum, app.view);
    const fx = &app.session.racks.items[0].fx;
    try std.testing.expectEqual(@as(usize, 1), fx.units.items.len);
    try std.testing.expectEqual(ws.FxKind.gate, fx.units.items[0].kind());
    try std.testing.expectEqual(@as(usize, 0), app.fx_focus);

    // Insert again with the cursor on "Reverb": lands *after* the gate.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'a' });
    app.fx_picker_cursor = spectrum_ed.picker_kinds.len - 1;
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 2), fx.units.items.len);
    try std.testing.expectEqual(ws.FxKind.reverb, fx.units.items[1].kind());
    try std.testing.expectEqual(@as(usize, 1), app.fx_focus);

    // 'x' removes the focused reverb; focus clamps back to the gate.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'x' });
    try std.testing.expectEqual(@as(usize, 1), fx.units.items.len);
    try std.testing.expectEqual(ws.FxKind.gate, fx.units.items[0].kind());
    try std.testing.expectEqual(@as(usize, 0), app.fx_focus);
}

test "FX picker mouse click during live search inserts and leaves search mode" {
    var app = try testApp();
    defer app.deinit();
    spectrum_ed.switchToTrack(&app, 0);

    try std.testing.expect(spectrum_ed.handleKey(&app, .{ .char = 'a' }));
    for ("/reverb") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);

    app.handleMouse(.{ .x = 4, .y = app_mod.content_top + 3, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(app_mod.AppView.track_spectrum, app.view);
    try std.testing.expectEqual(ws.FxKind.reverb, app.session.racks.items[0].fx.units.items[0].kind());
}

test "FX chain: </> reorder and b bypass reach the engine chain" {
    var app = try testApp();
    defer app.deinit();
    spectrum_ed.switchToMaster(&app);
    const fx = &app.session.master_fx;
    const alloc = app.session.allocator;
    const sr = app.session.project.sample_rate;
    _ = try fx.insert(alloc, 0, .comp, sr);
    _ = try fx.insert(alloc, 1, .delay, sr);
    app.session.syncMasterChain();
    try std.testing.expectEqual(@as(usize, 2), app.session.engine.master_chain.slice().len);

    // '>' moves the focused comp after the delay; focus follows it.
    app.fx_focus = 0;
    _ = spectrum_ed.handleKey(&app, .{ .char = '>' });
    try std.testing.expectEqual(ws.FxKind.delay, fx.units.items[0].kind());
    try std.testing.expectEqual(ws.FxKind.comp, fx.units.items[1].kind());
    try std.testing.expectEqual(@as(usize, 1), app.fx_focus);
    // At the chain's end '>' is a no-op.
    _ = spectrum_ed.handleKey(&app, .{ .char = '>' });
    try std.testing.expectEqual(@as(usize, 1), app.fx_focus);

    // 'b' bypasses the focused comp: it stays in both the chain and the
    // engine's device list, and fades itself out of the signal.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'b' });
    try std.testing.expect(fx.units.items[1].bypassed);
    // Bypassed units stay in the device list and fade themselves out.
    try std.testing.expectEqual(@as(usize, 2), app.session.engine.master_chain.slice().len);
    _ = spectrum_ed.handleKey(&app, .{ .char = 'b' });
    try std.testing.expectEqual(@as(usize, 2), app.session.engine.master_chain.slice().len);
}

test "FX chain: param nudges coalesce into one undo step, u right after nudging still undoes it" {
    var app = try testApp();
    defer app.deinit();
    spectrum_ed.switchToTrack(&app, 0);
    _ = try app.session.racks.items[0].fx.insert(app.session.allocator, 0, .comp, app.session.project.sample_rate);
    app.session.syncTrackChain(0, app.session.racks.items[0]);
    const fx = &app.session.racks.items[0].fx;
    const before = spectrum_ed.getParam(&fx.units.items[0].payload, 0); // threshold

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    const nudged = spectrum_ed.getParam(&fx.units.items[0].payload, 0);
    try std.testing.expect(nudged > before);
    // Three nudges on the same param, no cursor move - still one open batch.
    try std.testing.expectEqual(@as(usize, 0), app.history.undo_stack.items.len);

    // u right away (no intervening flush point) must undo the whole batch.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectApproxEqAbs(before, spectrum_ed.getParam(&fx.units.items[0].payload, 0), 0.0001);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'U' });
    try std.testing.expectApproxEqAbs(nudged, spectrum_ed.getParam(&fx.units.items[0].payload, 0), 0.0001);
}

test "FX chain: A adds an automation lane for the focused unit's focused param" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();
    spectrum_ed.switchToTrack(&app, 0);
    const comp_unit = try app.session.racks.items[0].fx.insert(app.session.allocator, 0, .comp, app.session.project.sample_rate);
    app.session.syncTrackChain(0, app.session.racks.items[0]);
    app.fx_param = 0; // threshold

    // No clip selected in the automation editor yet - A refuses, no lane
    // created, view stays put.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'A' });
    try std.testing.expectEqual(app_mod.AppView.track_spectrum, app.view);

    try app.session.stampClip(0, 0);
    automation_ed.switchTo(&app, 0, 0);
    try std.testing.expectEqual(app_mod.AppView.automation, app.view);

    // Back to the chain view - `addFocusedFxParamLane` reads `currentTarget`
    // off `app.view`, and `automation_track`/`automation_clip` (set above)
    // are what it needs to find the clip, independent of which view is up.
    app.view = .track_spectrum;
    _ = spectrum_ed.handleKey(&app, .{ .char = 'A' });
    try std.testing.expectEqual(app_mod.AppView.automation, app.view);
    try std.testing.expectEqual(
        automation_ed.AutomationFocus{ .synth_param = .{ .instance_id = comp_unit.instance_id, .param_id = 0 } },
        app.automation_focus,
    );
    const clip = automation_ed.currentClip(&app).?;
    try std.testing.expectEqual(@as(usize, 1), clip.automation.synth_params.items.len);
    try std.testing.expectEqual(comp_unit.instance_id, clip.automation.synth_params.items[0].instance_id);

    // Comp's sidechain row isn't automatable - A is a no-op there.
    app.view = .track_spectrum;
    app.fx_param = ws.dsp.fx_params.comp_sidechain_idx;
    _ = spectrum_ed.handleKey(&app, .{ .char = 'A' });
    try std.testing.expectEqual(@as(usize, 1), clip.automation.synth_params.items.len);
}

test "FX chain: EQ kind field cycles all types and switches gain or slope control" {
    var app = try testApp();
    defer app.deinit();
    spectrum_ed.switchToTrack(&app, 0);
    _ = try app.session.racks.items[0].fx.insert(app.session.allocator, 0, .eq, app.session.project.sample_rate);
    app.session.syncTrackChain(0, app.session.racks.items[0]);
    const fx = &app.session.racks.items[0].fx;
    const eq = &fx.units.items[0].payload.eq;
    app.fx_param = spectrum_ed.eq_field_kind; // band 0's kind field
    // h/l only nudges a field's value once its submenu is open - band-select
    // mode (the default after switching focus) has h/l walk bands instead.
    app.eq_band_select = false;

    try std.testing.expectEqual(eq_mod.BandKind.peak, eq.bands[0].kind);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectEqual(eq_mod.BandKind.lowpass, eq.bands[0].kind);
    try std.testing.expectEqual(@as(u8, 1), eq.bands[0].slope); // untouched by a kind-only change

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectEqual(eq_mod.BandKind.highpass, eq.bands[0].kind);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectEqual(eq_mod.BandKind.lowshelf, eq.bands[0].kind);
    try std.testing.expectEqualStrings("gain", spectrum_ed.paramName(&fx.units.items[0].payload, spectrum_ed.eq_field_gain));

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectEqual(eq_mod.BandKind.highshelf, eq.bands[0].kind);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectEqual(eq_mod.BandKind.notch, eq.bands[0].kind);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectEqual(eq_mod.BandKind.tiltshelf, eq.bands[0].kind);

    // Clamped, not wrapped, past the last kind.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectEqual(eq_mod.BandKind.tiltshelf, eq.bands[0].kind);

    // Filter kinds use the shared fourth field for discrete slope stages.
    for (0..5) |_| _ = spectrum_ed.handleKey(&app, .{ .char = 'h' });
    try std.testing.expectEqual(eq_mod.BandKind.lowpass, eq.bands[0].kind);

    // The gain field's flat slot becomes "slope" once the band isn't peak:
    // fine steps walk one cascade stage (12dB/oct) at a time, clamped 1..4.
    app.fx_param = spectrum_ed.eq_field_gain;
    for (0..5) |_| _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectEqual(@as(u8, 4), eq.bands[0].slope);

    // Coarse jumps the full 1..max_slope range in one press.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'H' });
    try std.testing.expectEqual(@as(u8, 1), eq.bands[0].slope);

    // Back to peak: the same flat slot reverts to a normal dB gain slider.
    app.fx_param = spectrum_ed.eq_field_kind;
    _ = spectrum_ed.handleKey(&app, .{ .char = 'h' });
    try std.testing.expectEqual(eq_mod.BandKind.peak, eq.bands[0].kind);
    app.fx_param = spectrum_ed.eq_field_gain;
    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), eq.bands[0].gain_db, 0.0001);
}

test "FX chain: insert/bypass/remove are each their own undoable step" {
    var app = try testApp();
    defer app.deinit();
    spectrum_ed.switchToTrack(&app, 0);
    const fx = &app.session.racks.items[0].fx;

    _ = spectrum_ed.handleKey(&app, .{ .char = 'a' });
    spectrum_ed.insertFromPicker(&app, .comp);
    try std.testing.expectEqual(@as(usize, 1), fx.units.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'b' }); // bypass - its own step
    try std.testing.expect(fx.units.items[0].bypassed);
    try std.testing.expectEqual(@as(usize, 2), app.history.undo_stack.items.len);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'x' }); // remove - its own step
    try std.testing.expectEqual(@as(usize, 0), fx.units.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.history.undo_stack.items.len);

    // Undo the remove: the comp is back, still bypassed.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectEqual(@as(usize, 1), fx.units.items.len);
    try std.testing.expect(fx.units.items[0].bypassed);

    // Undo the bypass: active again.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expect(!fx.units.items[0].bypassed);

    // Undo the insert: gone again.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'u' });
    try std.testing.expectEqual(@as(usize, 0), fx.units.items.len);

    // Redo walks the same three states forward again.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'U' }); // redo insert
    try std.testing.expectEqual(@as(usize, 1), fx.units.items.len);
    try std.testing.expect(!fx.units.items[0].bypassed);
    _ = spectrum_ed.handleKey(&app, .{ .char = 'U' }); // redo bypass
    try std.testing.expect(fx.units.items[0].bypassed);
    _ = spectrum_ed.handleKey(&app, .{ .char = 'U' }); // redo remove
    try std.testing.expectEqual(@as(usize, 0), fx.units.items.len);
}

test "multiband compressor style renders as a bracketed toggle, not a slider" {
    var app = try testApp();
    defer app.deinit();
    spectrum_ed.switchToTrack(&app, 0);
    _ = spectrum_ed.handleKey(&app, .{ .char = 'a' });
    spectrum_ed.insertFromPicker(&app, .mb_comp);
    app.fx_param = spectrum_ed.mb_style;

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[classic]") != null);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    const fx = &app.session.racks.items[0].fx;
    try std.testing.expectEqual(ws.dsp.multiband_comp.Style.ott, fx.units.items[0].payload.mb_comp.style);

    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[OTT") != null);
}

test "compressor's scpad row only shows once the sidechain track is a drum machine" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();
    spectrum_ed.switchToTrack(&app, 0);
    _ = spectrum_ed.handleKey(&app, .{ .char = 'a' });
    spectrum_ed.insertFromPicker(&app, .comp);
    const fx = &app.session.racks.items[0].fx;
    const payload = &fx.units.items[0].payload;
    // Every comp row except scpad, which only appears for a drum-machine source.
    const comp_rows = ws.dsp.fx_params.paramCount(.comp) - 1;

    // No sidechain source picked yet: scpad stays hidden.
    try std.testing.expectEqual(comp_rows, spectrum_ed.visibleParamCount(&app, .comp, payload));

    // Sidechain pointed at track 1 (a sampler, not a drum machine): still hidden.
    payload.comp.sidechain_source = .{ .track = 1, .pad = null };
    try std.testing.expectEqual(comp_rows, spectrum_ed.visibleParamCount(&app, .comp, payload));

    // Sidechain pointed at track 2 (the drum machine): scpad appears.
    payload.comp.sidechain_source = .{ .track = 2, .pad = null };
    try std.testing.expectEqual(comp_rows + 1, spectrum_ed.visibleParamCount(&app, .comp, payload));

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "scpad") != null);

    // Pick a pad, then nudge the sidechain track (idx 6) off the drum
    // machine and onto the sampler - the now-stale pad selection must
    // clear itself (see clearStaleSidechainPad's doc comment for why a
    // lingering pad silently zeroes the detector instead of falling back
    // to whole-track sidechain).
    payload.comp.sidechain_source = .{ .track = 2, .pad = 3 };
    app.fx_param = ws.dsp.fx_params.comp_sidechain_idx;
    _ = spectrum_ed.handleKey(&app, .{ .char = 'h' }); // track 2 -> track 1
    try std.testing.expectEqual(@as(u16, 1), payload.comp.sidechain_source.?.track);
    try std.testing.expectEqual(@as(?u8, null), payload.comp.sidechain_source.?.pad);
    try std.testing.expectEqual(comp_rows, spectrum_ed.visibleParamCount(&app, .comp, payload));

    w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "scpad") == null);
}

test "FX chain: a param nudge followed by a structural edit are two separate undo steps" {
    var app = try testApp();
    defer app.deinit();
    spectrum_ed.switchToTrack(&app, 0);
    const fx = &app.session.racks.items[0].fx;
    _ = spectrum_ed.handleKey(&app, .{ .char = 'a' });
    spectrum_ed.insertFromPicker(&app, .comp);
    const undo_after_insert = app.history.undo_stack.items.len;
    const threshold_before = spectrum_ed.getParam(&fx.units.items[0].payload, 0);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' }); // nudge threshold - opens a batch
    try std.testing.expectEqual(undo_after_insert, app.history.undo_stack.items.len); // still open
    const threshold_nudged = spectrum_ed.getParam(&fx.units.items[0].payload, 0);
    try std.testing.expect(threshold_nudged > threshold_before);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'b' }); // bypass flushes the nudge, then records its own step
    try std.testing.expectEqual(undo_after_insert + 2, app.history.undo_stack.items.len);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'u' }); // undo the bypass only
    try std.testing.expect(!fx.units.items[0].bypassed);
    try std.testing.expectApproxEqAbs(threshold_nudged, spectrum_ed.getParam(&fx.units.items[0].payload, 0), 0.0001); // nudge still applied
}

test "FX chain: switchToGroup opens a group's chain via the same shared editor" {
    var app = try testApp();
    defer app.deinit();
    const g = try app.session.addGroup("bus");

    spectrum_ed.switchToGroup(&app, g);
    try std.testing.expectEqual(AppView.group_spectrum, app.view);
    try std.testing.expectEqual(g, app.eq_group);

    // 'a' opens the picker; accepting inserts into *this* group's chain,
    // not the master's or a track's - same insert path 'a' already uses
    // for those two, just resolved through fxPtr's third arm.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'a' });
    try std.testing.expectEqual(AppView.fx_picker, app.view);
    spectrum_ed.insertFromPicker(&app, .comp);
    try std.testing.expectEqual(AppView.group_spectrum, app.view);
    try std.testing.expectEqual(@as(usize, 1), app.session.groups[g].?.fx.units.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.engine.groups[g].chain.slice().len);

    // 'x' removes it, reaching the engine the same way.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'x' });
    try std.testing.expectEqual(@as(usize, 0), app.session.groups[g].?.fx.units.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.engine.groups[g].chain.slice().len);

    // esc leaves group_spectrum cleanly, back to whatever opened it.
    _ = spectrum_ed.handleKey(&app, .escape);
    try std.testing.expect(app.view != .group_spectrum);
}

test "tracks view: group rows render in folder order; z folds members behind the row" {
    var app = try testApp();
    defer app.deinit();
    // Group tracks 0+1; track 2 stays loose.
    const g = try app.session.addGroup("bus");
    app.session.assignTrackGroup(0, g);
    app.session.assignTrackGroup(1, g);

    app.tracksRowSync();
    // Folder order: group row where its first member sat, members under it,
    // the loose track after - master one past the end as always.
    try std.testing.expectEqual(@as(usize, 4), app.track_rows_len);
    try std.testing.expectEqual(g, app.track_rows_buf[0].group);
    try std.testing.expectEqual(@as(u16, 0), app.track_rows_buf[1].track);
    try std.testing.expectEqual(@as(u16, 1), app.track_rows_buf[2].track);
    try std.testing.expectEqual(@as(u16, 2), app.track_rows_buf[3].track);

    // z on the group row folds: member rows vanish, cursor stays put.
    app.view = .tracks;
    app.setTrackRow(0);
    try std.testing.expectEqual(@as(?u8, g), app.cursorGroup());
    app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expect(app.session.groups[g].?.folded);
    try std.testing.expectEqual(@as(usize, 2), app.track_rows_len); // group row + loose track
    try std.testing.expectEqual(@as(?u8, g), app.cursorGroup());

    // z from a member row folds too - the cursor climbs onto the group row.
    app.handleKey(.{ .char = 'z' }, 0); // unfold first
    try std.testing.expectEqual(@as(usize, 4), app.track_rows_len);
    app.setTrackRow(2); // track 1, inside the group
    app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expect(app.session.groups[g].?.folded);
    try std.testing.expectEqual(@as(?u8, g), app.cursorGroup());

    // A search hit hidden in the fold unfolds it, vim-style.
    for ("/samp") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(!app.session.groups[g].?.folded);
    app.tracksRowSync();
    try std.testing.expectEqual(@as(?u16, 1), app.cursorTrack());
}

test "tracks view: group row rides its bus fader, opens its chain, dd deletes the group" {
    var app = try testApp();
    defer app.deinit();
    const g = try app.session.addGroup("bus");
    app.session.assignTrackGroup(0, g);
    app.view = .tracks;
    app.tracksRowSync();
    app.setTrackRow(0); // the group row
    try std.testing.expectEqual(@as(?u8, g), app.cursorGroup());

    // -/+ step the bus fader, same 1 dB grain as track gain.
    app.handleKey(.{ .char = '-' }, 0);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), app.session.groups[g].?.gain_db, 0.001);
    app.handleKey(.{ .char = '+' }, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), app.session.groups[g].?.gain_db, 0.001);

    // enter opens the group's FX chain, same as a track row's chain view.
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.group_spectrum, app.view);
    try std.testing.expectEqual(g, app.eq_group);
    app.view = .tracks;

    // dd deletes the group; its member falls back to the master mix.
    app.handleKey(.{ .char = 'd' }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(app.session.groups[g] == null);
    try std.testing.expectEqual(@as(?u8, null), app.session.project.tracks.items[0].group);
    app.tracksRowSync();
    try std.testing.expectEqual(@as(usize, 3), app.track_rows_len); // plain track list again
}

test "tracks view: m/S on a group row flip the bus's own mute/solo flags" {
    var app = try testApp();
    defer app.deinit();
    const g = try app.session.addGroup("bus");
    app.session.assignTrackGroup(0, g);
    app.session.assignTrackGroup(1, g);
    app.view = .tracks;
    app.tracksRowSync();
    app.setTrackRow(0); // the group row
    try std.testing.expectEqual(@as(?u8, g), app.cursorGroup());

    // Both are real bus-level flags now, not a loop over every member -
    // member tracks' own muted/soloed fields are untouched.
    app.handleKey(.{ .char = 'm' }, 0);
    try std.testing.expect(app.session.groups[g].?.muted);
    try std.testing.expect(!app.session.project.tracks.items[0].muted);
    try std.testing.expect(!app.session.project.tracks.items[1].muted);

    app.handleKey(.{ .char = 'm' }, 0);
    try std.testing.expect(!app.session.groups[g].?.muted);

    app.handleKey(.{ .char = 'S' }, 0);
    try std.testing.expect(app.session.groups[g].?.soloed);
    try std.testing.expect(!app.session.project.tracks.items[0].soloed);
    try std.testing.expect(!app.session.project.tracks.items[1].soloed);

    app.handleKey(.{ .char = 'S' }, 0);
    try std.testing.expect(!app.session.groups[g].?.soloed);
}

test "tracks view: visual g groups the selected rows and lands on the new group's row" {
    var app = try testApp();
    defer app.deinit();
    app.view = .tracks;
    app.tracksRowSync();
    app.setTrackRow(0);
    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    app.handleKey(.{ .char = 'j' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    // g created the group and returned to normal mode on its row.
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(?u8, 0), app.session.project.tracks.items[0].group);
    try std.testing.expectEqual(@as(?u8, 0), app.session.project.tracks.items[1].group);
    try std.testing.expectEqual(@as(?u8, null), app.session.project.tracks.items[2].group);
    app.tracksRowSync();
    try std.testing.expectEqual(@as(?u8, 0), app.cursorGroup());
}

test "below the minimum terminal size, draw gates to the too-small notice" {
    var app = try testApp();
    defer app.deinit();

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 40, .rows = 10 });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "terminal too small") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "need 80x14, have 40x10") != null);
    // No view content leaks through the gate.
    try std.testing.expect(std.mem.indexOf(u8, out, "TRACKS") == null);

    // At exactly the minimum the real frame renders.
    var buf2: [32 * 1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try tui_mod.draw(&app, &w2, .{ .cols = 80, .rows = 14 });
    const out2 = w2.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out2, "terminal too small") == null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "TRACKS") != null);
}

test "f in the synth editor opens the preset picker; / narrows and enter applies" {
    var app = try testApp();
    defer app.deinit();
    app.synth_track = 0;
    app.view = .synth_editor;

    app.handleKey(.{ .char = 'f' }, 0);
    try std.testing.expectEqual(AppView.preset_picker, app.view);
    try std.testing.expectEqual(preset_ed.Kind.synth, app.preset_picker_kind);

    // `/` filters live via the modal search prompt; enter submits it and
    // stays in the picker with the narrowed list.
    for ("/acid-bass") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(AppView.preset_picker, app.view);
    var buf: [preset_ed.max_display_rows]preset_ed.DisplayRow = undefined;
    try std.testing.expectEqual(@as(usize, 1), preset_ed.entryCountOf(preset_ed.buildDisplayRows(&app, &buf)));

    // Enter applies the survivor to the synth and bounces back to the editor
    // that opened the picker, not out to the tracks view.
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    const s = &app.session.racks.items[0].instrument.poly_synth;
    const expected = ws.dsp.synth_presets.find("acid-bass").?;
    try std.testing.expectEqual(expected.voice_mode, s.voice_mode);
    try std.testing.expectApproxEqAbs(expected.filter_res, s.filter_res, 1e-6);
    try std.testing.expect(app.dirty);
}

test "preset picker mouse click during live search submits then applies match" {
    var app = try testApp();
    defer app.deinit();
    app.synth_track = 0;
    app.view = .synth_editor;

    app.handleKey(.{ .char = 'f' }, 0);
    for ("/acid-bass") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);

    var rows_buf: [preset_ed.max_display_rows]preset_ed.DisplayRow = undefined;
    const rows = preset_ed.buildDisplayRows(&app, &rows_buf);
    var display_row: usize = 0;
    for (rows, 0..) |row, i| switch (row) {
        .entry => {
            display_row = i;
            break;
        },
        .header => {},
    };
    app.handleMouse(.{ .x = 4, .y = @intCast(app_mod.content_top + 2 + display_row), .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    const expected = ws.dsp.synth_presets.find("acid-bass").?;
    try std.testing.expectEqual(expected.voice_mode, app.session.racks.items[0].instrument.poly_synth.voice_mode);
}

test "preset-picker filter reaches genre tags and user-saved presets" {
    var app = try testApp();
    defer app.deinit();
    // A saved preset alongside the factory list - App.deinit frees the name.
    const name = try app.allocator.dupe(u8, "my-fave");
    var patch: ws.dsp.PolySynth.Patch = .{};
    patch.gain = 0.42;
    try app.user_synth_presets.append(app.allocator, .{ .name = name, .patch = patch });

    app.synth_track = 0;
    app.view = .synth_editor;
    app.handleKey(.{ .char = 'f' }, 0);

    // A pure genre tag narrows to exactly that genre's presets.
    for ("/psytrance") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    var buf: [preset_ed.max_display_rows]preset_ed.DisplayRow = undefined;
    try std.testing.expectEqual(@as(usize, 3), preset_ed.entryCountOf(preset_ed.buildDisplayRows(&app, &buf)));

    // The saved preset is reachable by name and applies. (Its "saved"
    // category is matchable too, but as a subsequence it also catches
    // synthwave-lead - s,a,v,e,d - so the name is the precise handle.)
    for ("/my-fave") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 1), preset_ed.entryCountOf(preset_ed.buildDisplayRows(&app, &buf)));
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    const s = &app.session.racks.items[0].instrument.poly_synth;
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), s.gain, 1e-6);
}

test "synth preset picker pages and jumps between categories" {
    var app = try testApp();
    defer app.deinit();
    app.synth_track = 0;
    app.view = .synth_editor;
    app.handleKey(.{ .char = 'f' }, 0);

    app.handleKey(.{ .char = 'J' }, 0);
    try std.testing.expectEqual(@as(usize, 10), app.preset_picker_cursor);
    app.handleKey(.{ .char = 'K' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.preset_picker_cursor);

    // The first two factory sections are utility (init) and pad.
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.preset_picker_cursor);
    app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expect(app.preset_picker_cursor > 1);
    app.handleKey(.{ .char = '[' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.preset_picker_cursor);
}

test "synth preset audition plays C3 and cancel restores the original patch" {
    var app = try testApp();
    defer app.deinit();
    app.synth_track = 0;
    app.view = .synth_editor;
    const original = app.session.racks.items[0].instrument.poly_synth.toPatch();
    app.handleKey(.{ .char = 'f' }, 0);

    // Move off init, audition without accepting, and remain in the picker.
    app.handleKey(.{ .char = 'j' }, 0);
    app.handleKey(.{ .char = 'a' }, 123);
    try std.testing.expectEqual(AppView.preset_picker, app.view);
    try std.testing.expect(!app.dirty);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
    try std.testing.expectEqual(@as(u7, 48), app.note_offs[0].note);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "C3") != null);
    const auditioned = app.session.racks.items[0].instrument.poly_synth.toPatch();
    try std.testing.expect(auditioned.wt_pos != original.wt_pos or auditioned.filter_cutoff != original.filter_cutoff);

    app.handleKey(.escape, 124);
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    const restored = app.session.racks.items[0].instrument.poly_synth.toPatch();
    try std.testing.expectEqualDeep(original, restored);
    try std.testing.expect(!app.dirty);
}

test "undo puts back the sound a synth preset replaced" {
    var app = try testApp();
    defer app.deinit();
    app.synth_track = 0;
    app.view = .synth_editor;
    // Something hand-tuned to lose.
    app.session.racks.items[0].instrument.poly_synth.filter_cutoff = 777.0;
    const original = app.session.racks.items[0].instrument.poly_synth.toPatch();

    app.handleKey(.{ .char = 'f' }, 0);
    app.handleKey(.{ .char = 'j' }, 0);
    // Audition first: undo must restore what the picker opened on, not the
    // preview that `a` left in the rack.
    app.handleKey(.{ .char = 'a' }, 1);
    app.handleKey(.enter, 2);
    const applied = app.session.racks.items[0].instrument.poly_synth.toPatch();
    try std.testing.expect(applied.filter_cutoff != original.filter_cutoff);

    app.handleKey(.{ .char = 'u' }, 3);
    const restored = app.session.racks.items[0].instrument.poly_synth.toPatch();
    try std.testing.expectApproxEqAbs(original.filter_cutoff, restored.filter_cutoff, 1e-3);
}

test "f in the drum grid opens the kit picker and enter regenerates the pads" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.view = .drum_grid;

    app.handleKey(.{ .char = 'f' }, 0);
    try std.testing.expectEqual(AppView.preset_picker, app.view);
    try std.testing.expectEqual(preset_ed.Kind.drum, app.preset_picker_kind);

    // Variants list as init, default, analog - j twice, enter applies it.
    app.handleKey(.{ .char = 'j' }, 0);
    app.handleKey(.{ .char = 'j' }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
    try std.testing.expect(app.dirty);
    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "analog") != null);
}

test "f on an acoustic track lists the bundled library" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .acoustic);
    app.cursor = 0;
    app.view = .tracks;

    app.handleKey(.{ .char = 'f' }, 0);
    try std.testing.expectEqual(AppView.preset_picker, app.view);
    var rows_buf: [preset_ed.max_display_rows]preset_ed.DisplayRow = undefined;
    const rows = preset_ed.buildDisplayRows(&app, &rows_buf);
    try std.testing.expectEqual(std.enums.values(ws.dsp.builtin_library.Id).len, preset_ed.entryCountOf(rows));
    try std.testing.expectEqual(preset_ed.Kind.acoustic, app.preset_picker_kind);
}

test "soundfont is a separate instrument: its picker lists the loaded font, not the bundled banks" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .soundfont);
    const sf2 = try ws.dsp.soundfont.buildTestSf2(std.testing.allocator, false, app.session.project.sample_rate);
    defer std.testing.allocator.free(sf2);
    try app.session.racks.items[0].instrument.soundfont.loadSf2(sf2);
    app.cursor = 0;
    app.view = .tracks;

    app.handleKey(.{ .char = 'f' }, 0);
    try std.testing.expectEqual(AppView.preset_picker, app.view);
    try std.testing.expectEqual(preset_ed.Kind.soundfont, app.preset_picker_kind);
    var rows_buf: [preset_ed.max_display_rows]preset_ed.DisplayRow = undefined;
    const rows = preset_ed.buildDisplayRows(&app, &rows_buf);
    try std.testing.expectEqual(@as(usize, 1), preset_ed.entryCountOf(rows));
}

test ":library is offered on acoustic tracks and hidden on soundfont ones" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 0;

    try app.session.setInstrument(0, .acoustic);
    try std.testing.expectEqual(cmd_mod.Scope.acoustic, commands_load.activeScope(&app));

    try app.session.setInstrument(0, .soundfont);
    try std.testing.expectEqual(cmd_mod.Scope.soundfont, commands_load.activeScope(&app));
}

test "neither soundfont kind can be fed the other's content by a fully-typed command" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 0;

    // :library refuses a .sf2 track (dispatch ignores scope, so the command
    // has to check for itself).
    try app.session.setInstrument(0, .soundfont);
    commands.run(&app, "library harpsichord");
    try std.testing.expectEqual(@as(?ws.dsp.builtin_library.Id, null), app.session.racks.items[0].instrument.soundfont.builtin);

    // ...and :load-soundfont refuses an acoustic one, leaving its bank alone.
    try app.session.setInstrument(0, .acoustic);
    app.session.racks.items[0].instrument.acoustic.builtin = .marimba;
    commands.run(&app, "load-soundfont /nonexistent.sf2");
    try std.testing.expectEqual(ws.dsp.builtin_library.Id.marimba, app.session.racks.items[0].instrument.acoustic.builtin.?);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "esc leaves the preset picker without applying anything" {
    var app = try testApp();
    defer app.deinit();
    app.synth_track = 0;
    app.view = .synth_editor;
    const gain_before = app.session.racks.items[0].instrument.poly_synth.gain;

    app.handleKey(.{ .char = 'f' }, 0);
    app.handleKey(.{ .char = 'j' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    try std.testing.expectApproxEqAbs(gain_before, app.session.racks.items[0].instrument.poly_synth.gain, 1e-6);
}

test "Lua user commands dispatch through :, builtins win collisions" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.api.create_user_command('greet', function(o) hit = o.args end); wstudio.api.create_user_command('bpm', function() shadowed = true end)");
    app.lua_runtime = &rt;
    app.rebuildCmdTable();

    commands.run(&app, "greet from-test");
    try rt.loadString("assert(hit == 'from-test')");

    // A user command named like a builtin is shadowed: :bpm still sets tempo.
    commands.run(&app, "bpm 133");
    try std.testing.expectEqual(@as(f64, 133), app.session.project.tempo_bpm);
    try rt.loadString("assert(shadowed == nil)");

    // Unknown names still report with user commands in the table.
    commands.run(&app, "definitely-not-a-command");
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "not a command") != null);

    // Deleting the command and rebuilding drops it from dispatch.
    try rt.loadString("wstudio.api.del_user_command('greet'); hit = nil");
    app.rebuildCmdTable();
    commands.run(&app, "greet again");
    try rt.loadString("assert(hit == nil)");
}

test "user commands registered at runtime rebuild the dispatch table" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    app.lua_runtime = &rt;
    app.rebuildCmdTable();
    rt.app = &app; // attached: registry changes must self-rebuild

    // Registered after startup (as from an autocmd) - no manual rebuild.
    try rt.loadString("wstudio.api.create_user_command('aa', function() aahit = true end);" ++
        "wstudio.api.create_user_command('bb', function() bbhit = true end)");
    commands.run(&app, "bb");
    try rt.loadString("assert(bbhit == true)");

    // Deleting 'aa' shifts 'bb' down a slot; the table must follow so :bb
    // still runs bb's handler and :aa stops matching anything.
    try rt.loadString("wstudio.api.del_user_command('aa'); bbhit = nil");
    commands.run(&app, "bb");
    try rt.loadString("assert(bbhit == true)");
    commands.run(&app, "aa");
    try rt.loadString("assert(aahit == nil)");
}

test "Lua keymaps intercept keys, chord, and fall through" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.keymap.set('n', 'Q', function() qhit = (qhit or 0) + 1 end);" ++
        "wstudio.keymap.set('n', 'Qp', function() qphit = (qphit or 0) + 1 end);" ++
        "wstudio.keymap.set('n', 'j', function() jhit = true end, { view = 'piano_roll' })");
    app.lua_runtime = &rt;

    // View-restricted map: in the tracks view j falls through to the
    // builtin row motion.
    try std.testing.expectEqual(@as(usize, 0), app.track_row);
    app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.track_row);
    try rt.loadString("assert(jhit == nil)");

    // Chord: Q buffers (a longer candidate exists), p completes it. The
    // buffered Q must not reach the builtin path, and p must not open the
    // piano roll.
    app.handleKey(.{ .char = 'Q' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.track_row);
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try rt.loadString("assert(qphit == 1 and qhit == nil)");

    // Broken chord: Q buffers, j breaks it - the complete shorter Q map
    // fires and j falls through as the builtin motion.
    app.handleKey(.{ .char = 'Q' }, 0);
    app.handleKey(.{ .char = 'j' }, 0);
    try rt.loadString("assert(qhit == 1 and qphit == 1)");
    try std.testing.expectEqual(@as(usize, 2), app.track_row);
}

test "Lua keymaps cannot shadow command prompt" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.keymap.set('n', ':', function() hit = true end);" ++
        "wstudio.keymap.set('n', 'Q:', function() chord_hit = true end)");
    app.lua_runtime = &rt;

    app.handleKey(.{ .char = 'Q' }, 0);
    app.handleKey(.{ .char = ':' }, 0);
    try std.testing.expectEqual(ws.input.Mode.command, app.modal.mode);
    try std.testing.expectEqual(@as(u8, 0), app.keymap_pending_len);
    try rt.loadString("assert(hit == nil and chord_hit == nil)");
}

test "Lua autocmds fire from core emission points" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("log = {};" ++
        "wstudio.api.create_autocmd({'ViewEnter','PlaybackStart','PlaybackStop','TrackAdd','TrackDel','ProjectSavePre'}, " ++
        "{ callback = function(ev) log[#log+1] = ev.event .. ':' .. (ev.view or ev.track or ev.tempo or ev.path) end })");
    app.lua_runtime = &rt;

    // View switches surface at the frame boundary (tick), not mid-keypress.
    app.view = .arrangement;
    app.tick(0);
    try rt.loadString("assert(log[1] == 'ViewEnter:arrangement', log[1])");

    // Transport start/stop is watched off the engine's UI snapshot.
    _ = app.session.engine.send(.play);
    var block: [64]ws.types.Sample = undefined;
    app.session.engine.process(&block);
    app.tick(0);
    try rt.loadString("assert(log[2] == 'PlaybackStart:120.0', log[2])");
    _ = app.session.engine.send(.stop);
    app.session.engine.process(&block);
    app.tick(0);
    try rt.loadString("assert(log[3] == 'PlaybackStop:120.0', log[3])");

    // Track list changes emit 1-based indices immediately (doTrackAdd
    // parks the cursor on the inserted track, so that's the expected one).
    app.doTrackAdd("lead");
    const added = app.cursor;
    var check_buf: [64]u8 = undefined;
    try rt.loadString(try std.fmt.bufPrintZ(&check_buf, "assert(log[4] == 'TrackAdd:{d}', log[4])", .{added + 1}));
    app.doTrackDel(added);
    try rt.loadString(try std.fmt.bufPrintZ(&check_buf, "assert(log[5] == 'TrackDel:{d}', log[5])", .{added + 1}));

    // :write emits SavePre before touching the disk (Post only on success -
    // this App runs on failing io, so the save errors after the Pre event).
    commands.run(&app, "write nowhere.wsj");
    try rt.loadString("assert(log[6] == 'ProjectSavePre:nowhere.wsj', log[6]); assert(#log == 6)");
}

test "runtime attachment binds and clears both sides" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();

    app.attachRuntime(&rt);
    try std.testing.expectEqual(&app, rt.app.?);
    try std.testing.expectEqual(&rt, app.lua_runtime.?);
    try std.testing.expect(rt.host != null);

    app.detachRuntime(&rt);
    try std.testing.expect(rt.app == null);
    try std.testing.expect(rt.host == null);
    try std.testing.expect(app.lua_runtime == null);
}

test "wstudio.api transport and track surface" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;

    // Transport: play/stop route through the engine command queue, so the
    // snapshot flips once the (test-driven) process call drains it.
    var block: [64]ws.types.Sample = undefined;
    try rt.loadString("assert(wstudio.api.is_playing() == false); wstudio.api.play()");
    app.session.engine.process(&block);
    try rt.loadString("assert(wstudio.api.is_playing() == true); wstudio.api.stop()");
    app.session.engine.process(&block);
    try rt.loadString("assert(wstudio.api.is_playing() == false)");
    try rt.loadString("assert(wstudio.api.get_tempo() == 120); wstudio.api.set_tempo(93); assert(wstudio.api.get_tempo() == 93)");
    try std.testing.expectEqual(@as(f64, 93), app.session.project.tempo_bpm);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.set_tempo(1000)"));

    // track_get reads the control-side mirror; 0 means the cursor track.
    try rt.loadString("assert(wstudio.api.track_count() == 3)");
    try rt.loadString("t = wstudio.api.track_get(2); assert(t.name == 'samp' and t.kind == 'sampler' and t.muted == false and t.armed == false and t.group == nil)");
    app.session.toggleArm(1); // "samp" is internal index 1 (Lua's 1-based arg 2)
    try rt.loadString("assert(wstudio.api.track_get(2).armed == true)");
    app.session.toggleArm(1);
    app.cursor = 2;
    try rt.loadString("t = wstudio.api.track_get(0); assert(t.name == 'drums' and t.kind == 'drum')");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.track_get(99)"));

    // track_set applies each field through the UI's own paths (pan clamps).
    try rt.loadString("wstudio.api.track_set(1, { gain_db = -6, pan = -1.5, muted = true, soloed = true, name = 'bass' })");
    const t = app.session.project.tracks.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, -6), t.gain_db, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), t.pan, 1e-6);
    try std.testing.expect(t.muted and t.soloed);
    try std.testing.expectEqualStrings("bass", t.name);
    try rt.loadString("assert(wstudio.api.track_get(1).gain_db == -6.0)");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.track_set(1, { bogus = 1 })"));
    try rt.loadString("wstudio.api.track_set(1, { armed = true }); assert(wstudio.api.track_get(1).armed)");
    try std.testing.expect(app.session.isArmed(0));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.track_set(1, { name = 'should-not-stick', bogus = true })"));
    try std.testing.expectEqualStrings("bass", app.session.project.tracks.items[0].name);

    // track_add returns the new 1-based index with the instrument applied;
    // TrackAdd observers see that same committed state; track_del removes it.
    try rt.loadString("added_kind = nil; wstudio.api.create_autocmd('TrackAdd', { callback = function(ev) added_kind = wstudio.api.track_get(ev.track).kind end })");
    try rt.loadString("i = wstudio.api.track_add({ kind = 'drum', name = 'beats' })");
    try rt.loadString("t = wstudio.api.track_get(i); assert(t.kind == 'drum' and t.name == 'beats'); assert(added_kind == 'drum', added_kind)");
    try rt.loadString("n = wstudio.api.track_count(); wstudio.api.track_del(i); assert(wstudio.api.track_count() == n - 1)");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.track_add({ kind = 'nope' })"));
}

test "wstudio.api duplicates, reorders, and focuses tracks" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;
    try rt.loadString("moves = {}; wstudio.api.create_autocmd('TrackMove', { callback = function(ev) moves[#moves + 1] = ev.from .. ':' .. ev.to end })");

    try rt.loadString("copy = wstudio.api.track_duplicate(2); assert(copy == 4 and wstudio.api.track_count() == 4)");
    try rt.loadString("assert(wstudio.api.track_get(copy).kind == wstudio.api.track_get(2).kind)");
    try rt.loadString("at = wstudio.api.track_move(copy, 1); assert(at == 1); assert(#moves == 3 and moves[1] == '4:3' and moves[3] == '2:1')");
    try rt.loadString("assert(wstudio.api.track_get(1).kind == 'sampler'); wstudio.api.set_current_track(3); assert(wstudio.api.get_current_track() == 3)");
    try std.testing.expectEqual(@as(usize, 2), app.cursor);
}

test "wstudio.api transport snapshot and partial update" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;

    try rt.loadString("t = wstudio.api.transport_get(); assert(t.playing == false and t.tempo == 120 and t.position_beats == 0 and t.position_seconds == 0 and t.position_frames == 0); assert(t.sample_rate == 48000 and t.beats_per_bar == 4); assert(t.song_mode == false and t.metronome == false); assert(t.loop.enabled == false and t.loop.start_bar == nil and t.loop.end_bar == nil)");
    try rt.loadString("wstudio.api.transport_set({ tempo = 90, position_beats = 6, song_mode = true, metronome = true, loop = { enabled = true, start_bar = 2, end_bar = 4 }, playing = true })");

    var block: [64]ws.types.Sample = undefined;
    app.session.engine.process(&block);
    try rt.loadString("t = wstudio.api.transport_get(); assert(t.playing and t.tempo == 90 and t.song_mode and t.metronome); assert(math.abs(t.position_beats - 6) < 0.01); assert(t.loop.enabled and t.loop.start_bar == 2 and t.loop.end_bar == 4)");
    try std.testing.expectEqual(@as(u32, 1), app.session.project.loop_start_bar);
    try std.testing.expectEqual(@as(u32, 4), app.session.project.loop_end_bar);
    try std.testing.expect(app.dirty);

    try rt.loadString("wstudio.api.transport_set({ playing = false, loop = { enabled = false } })");
    app.session.engine.process(&block);
    try rt.loadString("t = wstudio.api.transport_get(); assert(not t.playing and not t.loop.enabled); assert(t.loop.start_bar == 2 and t.loop.end_bar == 4)");

    const tempo_before = app.session.project.tempo_bpm;
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.transport_set({ tempo = 140, bogus = true })"));
    try std.testing.expectEqual(tempo_before, app.session.project.tempo_bpm);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.transport_set({ loop = { enabled = true, start_bar = 5, end_bar = 4 } })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.transport_set({ position_beats = -1 })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.transport_set({ metronome = 'yes' })"));
}

test "wstudio.api exposes editor context and feature detection" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.gui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;

    try rt.loadString("assert(wstudio.api.has('get_context')); assert(not wstudio.api.has('future_api'))");
    try rt.loadString("c = wstudio.api.get_context(); assert(c.frontend == 'gui' and c.view == 'tracks' and c.mode == 'normal' and c.track == 1)");
    try rt.loadString("assert(wstudio.api.get_mode() == 'normal'); assert(wstudio.api.get_current_view() == 'tracks'); assert(wstudio.api.get_current_track() == 1)");
    try rt.loadString("wstudio.api.set_hl('focus', { fg = '#abcdef' })");
    try std.testing.expect(app.pending_colorscheme);
    app.pending_colorscheme = false;

    app.view = .piano_roll;
    app.piano_track = 2;
    app.cursor = app.session.project.tracks.items.len; // master row is not a track
    app.modal.mode = .insert;
    try rt.loadString("c = wstudio.api.get_context(); assert(c.view == 'piano_roll' and c.mode == 'insert' and c.track == 3)");

    app.view = .tracks;
    try rt.loadString("assert(wstudio.api.get_current_track() == nil); assert(wstudio.api.get_context().track == nil)");
}

test "wstudio.api project lifecycle snapshot, save, open, and new" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;
    try rt.loadString("events = {}; wstudio.api.create_autocmd({'ProjectSavePre','ProjectSavePost'}, { callback = function(ev) events[#events + 1] = ev.event .. ':' .. ev.path end })");

    try rt.loadString("p = wstudio.api.project_get(); assert(p.path == nil and not p.dirty and p.track_count == 1 and p.sample_rate == 48000 and p.beats_per_bar == 4 and p.tempo == 120 and not p.song_mode)");
    app.dirty = true;
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/lua-save.wsj", .{&tmp.sub_path});
    var lua_buf: [256]u8 = undefined;
    try rt.loadString(try std.fmt.bufPrintZ(&lua_buf, "saved = wstudio.api.project_save('{s}'); assert(saved == '{s}')", .{ path, path }));
    try std.testing.expect(!app.dirty);
    try std.testing.expectEqualStrings(path, app.projectPath().?);
    var loaded = try ws.persist.load(std.testing.allocator, std.testing.io, path);
    loaded.deinit();
    try rt.loadString(try std.fmt.bufPrintZ(&lua_buf, "assert(events[1] == 'ProjectSavePre:{s}' and events[2] == 'ProjectSavePost:{s}'); assert(wstudio.api.project_get().path == '{s}')", .{ path, path, path }));

    app.dirty = true;
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.project_open('other.wsj')"));
    try std.testing.expectEqual(@as(App.ReloadRequest, .none), app.pending_reload);
    try rt.loadString("wstudio.api.project_open('other.wsj', { force = true })");
    try std.testing.expectEqual(@as(App.ReloadRequest, .load), app.pending_reload);
    try std.testing.expectEqualStrings("other.wsj", app.pendingReloadPath());
    app.pending_reload = .none;
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.project_new()"));
    try rt.loadString("wstudio.api.project_new({ force = true })");
    try std.testing.expectEqual(@as(App.ReloadRequest, .blank), app.pending_reload);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.project_new({ force = 'yes' })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.project_new({ bogus = true })"));
}

test "wstudio.api reads and replaces melodic pattern content" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;

    try rt.loadString("p = wstudio.api.pattern_get(1); assert(p.kind == 'melodic' and p.length_beats == 4.0 and p.step_count == nil)");
    try rt.loadString("assert(#wstudio.api.notes_get(1) == 0)");

    // A whole-pattern write is one undo entry, and reads it back verbatim.
    try rt.loadString(
        \\wstudio.api.notes_set(1, {
        \\  { pitch = 60, start_beat = 0.0, duration_beat = 0.5, velocity = 0.4,
        \\    pan = -0.5, fine_cents = 30, release_scale = 2.0 },
        \\  { pitch = 64, start_beat = 1.5 },
        \\})
    );
    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectEqual(@as(u16, 2), pp.note_count);
    try std.testing.expect(app.dirty);
    try rt.loadString(
        \\n = wstudio.api.notes_get(1)
        \\assert(#n == 2)
        \\assert(n[1].pitch == 60 and n[1].start_beat == 0.0 and n[1].duration_beat == 0.5)
        \\assert(math.abs(n[1].velocity - 0.4) < 1e-6)
        \\-- per-note expression round-trips as written
        \\assert(math.abs(n[1].pan + 0.5) < 1e-6)
        \\assert(math.abs(n[1].fine_cents - 30) < 1e-4)
        \\assert(math.abs(n[1].release_scale - 2.0) < 1e-6)
        \\-- omitted fields fall back to the same defaults a step edit uses
        \\assert(n[2].pitch == 64 and n[2].duration_beat == 1.0)
        \\assert(n[2].pan == 0.0 and n[2].fine_cents == 0.0 and n[2].release_scale == 1.0)
    );
    // Out of range raises and applies nothing, the way `pitch = 200` does.
    try std.testing.expectError(error.LuaError, rt.loadString(
        \\wstudio.api.notes_set(1, { { pitch = 60, pan = -9 } })
    ));
    try std.testing.expectError(error.LuaError, rt.loadString(
        \\wstudio.api.notes_set(1, { { pitch = 60, release_scale = 99 } })
    ));
    try std.testing.expectEqual(@as(u16, 2), pp.note_count);
    history.doUndo(&app);
    history.doUndo(&app);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);

    // pattern_set moves the loop length; the drum-only fields are refused.
    try rt.loadString("wstudio.api.pattern_set(1, { length_beats = 8 }); assert(wstudio.api.pattern_get(1).length_beats == 8.0)");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.pattern_set(1, { step_count = 16 })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.pattern_set(1, { bogus = 1 })"));

    // Kind gating and validation both raise rather than half-apply.
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.notes_get(3)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.steps_get(1)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.notes_set(1, { { pitch = 200 } })"));
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
    try rt.loadString("big = {}; for i = 1, 513 do big[i] = { pitch = 60 } end");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.notes_set(1, big)"));
}

test "wstudio.api reads and replaces drum grid content" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;
    const dm = &app.session.racks.items[2].instrument.drum_machine;

    try rt.loadString("p = wstudio.api.pattern_get(3); assert(p.kind == 'drum' and p.steps_per_beat == 4 and p.step_count == 32 and p.length_beats == 8.0)");
    try rt.loadString("assert(#wstudio.api.steps_get(3) == 0)");

    try rt.loadString(
        \\wstudio.api.steps_set(3, {
        \\  { pad = 1, step = 1 },
        \\  { pad = 2, step = 5, velocity = 0.5, prob = 70, micro = -12, retrig = 3, tune = -5, cond = 'a1b2' },
        \\})
    );
    try std.testing.expect(dm.stepActive(0, 0));
    try std.testing.expect(dm.stepActive(1, 4));
    try std.testing.expectEqual(@as(u8, 64), dm.stepVel(1, 4)); // 0.5 * 127, rounded
    try std.testing.expectEqual(@as(u8, 70), dm.stepProb(1, 4));
    try std.testing.expectEqual(@as(i8, -12), dm.stepMicro(1, 4));
    try std.testing.expectEqual(@as(u8, 3), dm.stepRetrig(1, 4));
    try std.testing.expectEqual(@as(i8, -5), dm.stepTune(1, 4));
    try std.testing.expectEqual(ws.dsp.DrumMachine.Cond.a1b2, dm.stepCond(1, 4));
    try rt.loadString(
        \\s = wstudio.api.steps_get(3)
        \\assert(#s == 2)
        \\assert(s[1].pad == 1 and s[1].step == 1 and s[1].velocity == 1.0 and s[1].cond == 'always')
        \\assert(s[2].pad == 2 and s[2].step == 5 and s[2].prob == 70 and s[2].retrig == 3 and s[2].cond == 'a1b2')
    );

    // A rewrite replaces the whole grid, and undoes as one entry.
    try rt.loadString("wstudio.api.steps_set(3, { { pad = 4, step = 9 } })");
    try std.testing.expect(!dm.stepActive(0, 0) and dm.stepActive(3, 8));
    history.doUndo(&app);
    try std.testing.expect(dm.stepActive(0, 0) and dm.stepActive(1, 4));

    // A bad entry anywhere in the list leaves the grid untouched.
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.steps_set(3, { { pad = 1, step = 1 }, { pad = 1, step = 99 } })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.steps_set(3, { { pad = 1, step = 1, cond = 'nope' } })"));
    try std.testing.expect(dm.stepActive(1, 4));

    // pattern_set resizes the grid; length_beats resolves to a step count.
    try rt.loadString("wstudio.api.pattern_set(3, { step_count = 64 }); assert(wstudio.api.pattern_get(3).step_count == 64)");
    try rt.loadString("wstudio.api.pattern_set(3, { length_beats = 2 }); assert(wstudio.api.pattern_get(3).step_count == 8)");
}

test "wstudio.api builds and tunes FX chains" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;
    const chain = &app.session.racks.items[0].fx;

    // A bare integer targets a track; the buses need the opts table.
    try rt.loadString("assert(#wstudio.api.fx_list(1) == 0 and #wstudio.api.fx_list({ master = true }) == 0)");
    try rt.loadString("assert(wstudio.api.fx_add(1, 'sat') == 1)");
    try rt.loadString("assert(wstudio.api.fx_add(1, 'delay') == 2)");
    try rt.loadString("assert(wstudio.api.fx_add(1, 'reverb', { pos = 1 }) == 1)");
    try std.testing.expectEqual(@as(usize, 3), chain.units.items.len);
    try rt.loadString(
        \\f = wstudio.api.fx_list(1)
        \\assert(#f == 3 and f[1].kind == 'reverb' and f[2].kind == 'sat' and f[3].kind == 'delay')
        \\assert(f[2].bypassed == false and f[2].param_count == 4 and f[2].instance_id ~= f[3].instance_id)
    );
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.fx_add(1, 'nope')"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.fx_add(1, 'clap')"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.fx_list({ group = 1 })"));

    // Params come back named, with their ranges; set takes name or index.
    try rt.loadString(
        \\p = wstudio.api.fx_params(1, 2)
        \\assert(#p == 4 and p[1].name == 'drive' and p[1].min == 0.0 and p[1].max == 36.0 and p[1].list == false)
    );
    try rt.loadString("wstudio.api.fx_param_set(1, 2, 'drive', 12); assert(wstudio.api.fx_params(1, 2)[1].value == 12.0)");
    try rt.loadString("wstudio.api.fx_param_set(1, 2, 3, 0.25); assert(wstudio.api.fx_params(1, 2)[3].value == 0.25)");
    // Out of range clamps, exactly as the editor's own h/l nudge does.
    try rt.loadString("wstudio.api.fx_param_set(1, 2, 'drive', 999); assert(wstudio.api.fx_params(1, 2)[1].value == 36.0)");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.fx_param_set(1, 2, 'nope', 1)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.fx_param_set(1, 2, 9, 1)"));

    // Structural edits: bypass, reorder, remove - each its own undo entry.
    try rt.loadString("wstudio.api.fx_set(1, 1, { bypassed = true }); assert(wstudio.api.fx_list(1)[1].bypassed)");
    try std.testing.expect(chain.units.items[0].bypassed);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.fx_set(1, 1, { bogus = true })"));
    try rt.loadString("assert(wstudio.api.fx_move(1, 1, 3) == 3)");
    try rt.loadString("f = wstudio.api.fx_list(1); assert(f[1].kind == 'sat' and f[3].kind == 'reverb')");
    history.doUndo(&app);
    try rt.loadString("f = wstudio.api.fx_list(1); assert(f[1].kind == 'reverb')");
    try rt.loadString("wstudio.api.fx_del(1, 1); assert(#wstudio.api.fx_list(1) == 2)");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.fx_del(1, 9)"));

    // The master bus takes the same calls without disturbing the track chain.
    try rt.loadString("wstudio.api.fx_add({ master = true }, 'comp'); assert(#wstudio.api.fx_list({ master = true }) == 1)");
    try std.testing.expectEqual(@as(usize, 1), app.session.master_fx.units.items.len);
    try std.testing.expectEqual(@as(usize, 2), chain.units.items.len);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.fx_list({ bogus = 1 })"));
}

test "wstudio.api stamps arrangement clips and names sections" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    rt.app = &app;
    app.lua_runtime = &rt;

    // A track with no instrument has nothing to place.
    try rt.loadString("assert(#wstudio.api.clip_list(1) == 0)");
    try app.session.setInstrument(1, .empty);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.clip_add(2, 1)"));
    try app.session.setInstrument(1, .sampler);
    try rt.loadString("wstudio.api.notes_set(1, { { pitch = 60, duration_beat = 4 } })");
    try rt.loadString("wstudio.api.clip_add(1, 1); wstudio.api.clip_add(1, 3)");
    try rt.loadString(
        \\cl = wstudio.api.clip_list(1)
        \\assert(#cl == 2 and cl[1].start_bar == 1 and cl[2].start_bar == 3)
        \\assert(cl[1].kind == 'melodic' and cl[1].length_bars == 1 and cl[1].start_tick == 0)
        \\assert(cl[2].start_tick == 256) -- 2 bars * 4 beats * 32 ticks
    );
    try std.testing.expectEqual(@as(usize, 2), app.session.arrangement.lane(0).?.clips.items.len);
    try std.testing.expect(app.dirty);

    // A drum track stamps its grid as a drum clip.
    try rt.loadString("wstudio.api.steps_set(3, { { pad = 1, step = 1 } }); wstudio.api.clip_add(3, 1)");
    try rt.loadString("assert(wstudio.api.clip_list(3)[1].kind == 'drum')");

    // Delete by the bar the clip covers; undo puts it back.
    try rt.loadString("wstudio.api.clip_del(1, 3); assert(#wstudio.api.clip_list(1) == 1)");
    history.doUndo(&app);
    try rt.loadString("assert(#wstudio.api.clip_list(1) == 2)");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.clip_del(1, 9)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.clip_add(1, 0)"));
    try rt.loadString("wstudio.api.clip_clear(1); assert(#wstudio.api.clip_list(1) == 0)");

    // Sections are placed in beats, and read back with their exact tick.
    try rt.loadString("assert(#wstudio.api.section_list() == 0)");
    try rt.loadString("wstudio.api.section_set(0, 'intro'); wstudio.api.section_set(8, 'verse')");
    try rt.loadString(
        \\s = wstudio.api.section_list()
        \\assert(#s == 2 and s[1].name == 'intro' and s[1].beat == 0.0 and s[1].tick == 0)
        \\assert(s[2].name == 'verse' and s[2].beat == 8.0 and s[2].tick == 256)
    );
    try rt.loadString("wstudio.api.section_set(0, 'top'); assert(wstudio.api.section_list()[1].name == 'top')");
    try rt.loadString("wstudio.api.section_del(8); assert(#wstudio.api.section_list() == 1)");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.section_del(8)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.section_set(0, '')"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.section_set(-1, 'nope')"));
}

test "applyUserConfig plumbs the round-2 options" {
    var app = try testApp();
    defer app.deinit();
    var cfg: @import("../config.zig").Config = .{};
    cfg.tap_timeout_ms = 500;
    cfg.autosave_interval_s = 0;
    cfg.default_octave = 2;
    cfg.default_tempo = 93;
    cfg.default_beats_per_bar = 3;
    app.applyUserConfig(cfg, true);
    try std.testing.expectEqual(@as(i96, 500 * std.time.ns_per_ms), app.tap_timeout_ns);
    try std.testing.expectEqual(@as(i96, 0), app.autosave_interval_ns);
    try std.testing.expectEqual(@as(u4, 2), app.modal.octave);
    try std.testing.expectEqual(@as(f64, 93), app.session.project.tempo_bpm);
    try std.testing.expectEqual(@as(u8, 3), app.session.project.beats_per_bar);

    // blank = false leaves the (loaded) project's tempo alone.
    cfg.default_tempo = 200;
    app.applyUserConfig(cfg, false);
    try std.testing.expectEqual(@as(f64, 93), app.session.project.tempo_bpm);
}

test "applyUserConfig plumbs the round-3 options" {
    var app = try testApp();
    defer app.deinit();
    var cfg: @import("../config.zig").Config = .{};
    cfg.default_velocity = 0.4;
    cfg.note_preview_ms = 500;
    cfg.cmd_history_lines = 3;
    cfg.status_message_ms = 1234;
    cfg.default_browse_dir.buf[0..4].* = "/tmp".*;
    cfg.default_browse_dir.len = 4;
    for ([_][]const u8{ "one", "two", "three", "four" }) |line|
        try app.cmd_history.append(app.allocator, try app.allocator.dupe(u8, line));
    app.applyUserConfig(cfg, true);
    try std.testing.expectEqual(@as(f32, 0.4), app.default_velocity);
    try std.testing.expectEqual(@as(i96, 500 * std.time.ns_per_ms), app.note_preview_ns);
    try std.testing.expectEqual(@as(usize, 3), app.cmd_history_cap);
    try std.testing.expectEqual(@as(i96, 1234 * std.time.ns_per_ms), app.status_message_ns);
    try std.testing.expectEqualStrings("/tmp", app.default_browse_dir.slice());
    try std.testing.expectEqual(@as(usize, 3), app.cmd_history.items.len);
    try std.testing.expectEqualStrings("two", app.cmd_history.items[0]);
    try std.testing.expectEqual(@as(usize, 3), app.cmd_history_pos);

    // New commands keep the already-trimmed history bounded.
    for ([_][]const u8{ ":bpm 121", ":bpm 122", ":bpm 123", ":bpm 124" }) |line| {
        for (line) |c| app.handleKey(.{ .char = c }, 0);
        app.handleKey(.enter, 0);
    }
    try std.testing.expectEqual(@as(usize, 3), app.cmd_history.items.len);
    try std.testing.expectEqualStrings("bpm 122", app.cmd_history.items[0]);
}

test "stepping past the newest history entry blanks the prompt cursor too" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try redirectHome(&tmp);

    var app = try testApp();
    defer app.deinit();
    for (":bpm 121") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    app.handleKey(.{ .char = ':' }, 0);
    app.handleKey(.ctrl_p, 0); // recall "bpm 121", cursor at its end
    app.handleKey(.ctrl_n, 0); // past the newest: fresh, empty line
    try std.testing.expectEqual(@as(usize, 0), app.modal.cmd_len);
    try std.testing.expectEqual(@as(usize, 0), app.modal.cmd_cursor);
}

test "applyUserConfig plumbs the round-4 editor options" {
    var app = try testApp();
    defer app.deinit();
    var cfg: @import("../config.zig").Config = .{};
    cfg.default_drum_grid = .eighth;
    cfg.default_piano_grid = .thirty_second;
    cfg.default_arrangement_grid = .sixteenth;
    cfg.piano_ghost_notes = true;
    app.applyUserConfig(cfg, true);
    try std.testing.expectEqual(ws.time_grid.Division.eighth, app.drum_grid);
    try std.testing.expectEqual(ws.time_grid.Division.thirty_second, app.piano_division);
    try std.testing.expectEqual(@as(f64, 0.125), app.piano_note_len);
    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.arr_grid);
    try std.testing.expect(app.piano_ghost);
}

test "applyUserConfig plumbs the round-5 workflow options" {
    var app = try testApp();
    defer app.deinit();
    var cfg: @import("../config.zig").Config = .{};
    cfg.default_project_path = @import("../config.zig").PathBuf.init("untitled.wsj");
    cfg.file_browser_show_hidden = true;
    cfg.default_piano_triplet_grid = true;
    cfg.default_piano_note_length_steps = 3;
    app.applyUserConfig(cfg, true);
    try std.testing.expectEqualStrings("untitled.wsj", app.defaultProjectPath());
    try std.testing.expect(app.file_browser_show_hidden);
    try std.testing.expectEqual(.triplet, app.piano_grid);
    try std.testing.expectEqual(@as(f64, 0.5), app.piano_note_len);
}

test "applyUserConfig plumbs the round-6 options" {
    var app = try testApp();
    defer app.deinit();
    const config_mod = @import("../config.zig");
    var cfg: config_mod.Config = .{};
    cfg.bounce_tail_seconds = 8.5;
    cfg.bounce_bit_depth = .pcm24;
    cfg.default_bounce_path = config_mod.PathBuf.init("mix.wav");
    cfg.default_stems_dir = config_mod.PathBuf.init("parts");
    cfg.master_limiter_ceiling_db = -6;
    cfg.master_limiter_release_ms = 250;
    cfg.default_drum_steps = 64;
    cfg.default_slicer_steps = 32;
    cfg.default_pattern_length_beats = 8;
    cfg.default_swing = 62;
    cfg.completion_popup_rows = 4;
    cfg.waveform_low_hz = 120;
    cfg.waveform_high_hz = 6000;
    cfg.tui_piano_cell_width = 5;
    cfg.tui_drum_cell_width = 1;
    cfg.tui_arrangement_cell_width = 6;
    cfg.tui_spectrum_db_range = 96;
    app.applyUserConfig(cfg, false);

    try std.testing.expectApproxEqAbs(@as(f32, 8.5), app.bounce_tail_seconds, 1e-6);
    try std.testing.expectEqual(ws.wav.BitDepth.pcm24, app.bounce_bit_depth);
    try std.testing.expectEqualStrings("mix.wav", app.default_bounce_path.slice());
    try std.testing.expectEqualStrings("parts", app.default_stems_dir.slice());
    try std.testing.expectEqual(@as(u8, 4), app.completion_popup_rows);
    // The cell-width options reach the views through these three accessors.
    try std.testing.expectEqual(@as(usize, 5), app.pianoCellWidth());
    try std.testing.expectEqual(@as(usize, 1), app.drumCellWidth());
    try std.testing.expectEqual(@as(usize, 6), app.arrCellWidth());
    try std.testing.expectApproxEqAbs(@as(f32, 96), app.tui_spectrum_db_range, 1e-6);
    // waveform.zig is module-level state; both frontends' draw code reads it.
    try std.testing.expectApproxEqAbs(@as(f32, 120), @import("../ui/waveform.zig").low_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6000), @import("../ui/waveform.zig").high_hz, 1e-6);

    // The limiter rides the engine command queue, so it needs a drain.
    var block: [64]ws.types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expectApproxEqAbs(ws.types.dbToGain(@as(f32, -6)), app.session.engine.limiter.ceiling, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 250), app.session.engine.limiter.release_ms, 1e-6);

    // New-instrument defaults land on Session and apply to the next rack
    // built, not to instruments that already exist.
    try std.testing.expectEqual(@as(u16, 64), app.session.defaults.drum_steps);
    try app.session.setInstrument(0, .drum_machine);
    try std.testing.expectEqual(@as(u16, 64), app.session.racks.items[0].instrument.drum_machine.step_count);
    try std.testing.expectApproxEqAbs(@as(f32, 62), app.session.racks.items[0].instrument.drum_machine.swing.load(.monotonic), 1e-6);
    try app.session.setInstrument(0, .slicer);
    try std.testing.expectEqual(@as(u8, 32), app.session.racks.items[0].instrument.slicer.step_count);
    try app.session.setInstrument(0, .poly_synth);
    try std.testing.expectEqual(@as(f64, 8), app.session.racks.items[0].pattern_player.?.length_beats);
    try std.testing.expectApproxEqAbs(@as(f32, 62), app.session.racks.items[0].pattern_player.?.swing.load(.monotonic), 1e-6);
}

test "applyUserConfig plumbs session defaults" {
    var app = try testApp();
    defer app.deinit();
    var cfg: @import("../config.zig").Config = .{};
    cfg.default_master_gain_db = -9;
    cfg.default_piano_pitch = 120;
    cfg.default_song_mode = true;
    app.applyUserConfig(cfg, false);
    try std.testing.expectEqual(@as(f32, -9), app.master_gain_db);
    try std.testing.expectEqual(@as(u7, 120), app.piano_cursor_pitch);
    try std.testing.expectEqual(@as(u7, 127), app.piano_scroll_pitch);
    try std.testing.expect(app.session.song_mode);

    cfg.default_piano_pitch = 36;
    cfg.default_song_mode = false;
    app.applyUserConfig(cfg, false);
    try std.testing.expectEqual(@as(u7, 36), app.piano_cursor_pitch);
    try std.testing.expectEqual(@as(u7, 48), app.piano_scroll_pitch);
    try std.testing.expect(!app.session.song_mode);
}

test "openBrowser falls back to default_browse_dir when no project path is known" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "kick.wav", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".hidden.wav", .data = "x" });

    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .sampler);

    var cfg: @import("../config.zig").Config = .{};
    var dir_buf: [96]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    @memcpy(cfg.default_browse_dir.buf[0..dir.len], dir);
    cfg.default_browse_dir.len = @intCast(dir.len);
    app.applyUserConfig(cfg, true);

    // No project path set, so openBrowser falls back to the configured
    // directory instead of cwd - see `openBrowser`.
    app.openBrowser(.load_sample);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(@as(usize, 1), app.browser_entries.items.len);
    try std.testing.expectEqualStrings("kick.wav", app.browser_entries.items[0].name);

    cfg.file_browser_show_hidden = true;
    app.applyUserConfig(cfg, true);
    app.openBrowser(.load_sample);
    try std.testing.expectEqual(@as(usize, 2), app.browser_entries.items.len);
    try std.testing.expectEqualStrings(".hidden.wav", app.browser_entries.items[0].name);
}

test ":colorscheme reports, switches (scoped per frontend), and rejects bad names" {
    var app = try testApp();
    defer app.deinit();
    var rt = try @import("../config.zig").Runtime.init(.tui);
    defer rt.deinit();
    app.lua_runtime = &rt;

    // No argument reports the active theme; nothing pending yet.
    commands.run(&app, "colorscheme");
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "none") != null);
    try std.testing.expect(!app.pending_colorscheme);

    // A TUI runtime accepts "none" (turns theming back off) and built-in names.
    commands.run(&app, "colorscheme patina");
    try std.testing.expectEqual(@import("../config.zig").TuiTheme.patina, rt.config.tui_theme);
    try std.testing.expect(app.pending_colorscheme);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "patina") != null);

    app.pending_colorscheme = false;
    commands.run(&app, "colorscheme catppuccin_mocha");
    try std.testing.expectEqual(@import("../config.zig").TuiTheme.catppuccin_mocha, rt.config.tui_theme);
    try std.testing.expect(app.pending_colorscheme);

    // The alias dispatches the same handler.
    app.pending_colorscheme = false;
    commands.run(&app, "colo umbra");
    try std.testing.expectEqual(@import("../config.zig").TuiTheme.umbra, rt.config.tui_theme);
    try std.testing.expect(app.pending_colorscheme);

    // A bad name reports and changes nothing.
    app.pending_colorscheme = false;
    commands.run(&app, "colorscheme neon");
    try std.testing.expectEqual(@import("../config.zig").TuiTheme.umbra, rt.config.tui_theme);
    try std.testing.expect(!app.pending_colorscheme);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "unknown name") != null);

    // A GUI runtime doesn't offer (or accept) "none" - there's no such
    // state for the panel skin - and writes gui_theme instead.
    var gui_rt = try @import("../config.zig").Runtime.init(.gui);
    defer gui_rt.deinit();
    app.lua_runtime = &gui_rt;
    commands.run(&app, "colorscheme none");
    try std.testing.expectEqual(@import("../config.zig").GuiTheme.patina, gui_rt.config.gui_theme);
    try std.testing.expect(!app.pending_colorscheme);
    commands.run(&app, "colorscheme graphite");
    try std.testing.expectEqual(@import("../config.zig").GuiTheme.graphite, gui_rt.config.gui_theme);
    try std.testing.expect(app.pending_colorscheme);
}

test "a loop too long for the u16 step grid draws and edits instead of panicking" {
    var app = try testApp();
    defer app.deinit();
    app.piano_track = 0;
    app.view = .piano_roll;
    app.piano_division = .one_twenty_eighth; // 32 steps per beat
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    // 512 bars of 4: 2048 * 32 = 65536, one past what a u16 step index holds.
    // Reachable by holding `+` in the roll, or importing a long MIDI file.
    pp.length_beats = 2048.0;

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 24 });

    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.{ .char = 'g' }, 0);
    app.handleKey(.{ .char = 'G' }, 0);
}

test ":track-instrument leaves an editor open on the track it just swapped" {
    var app = try testApp();
    defer app.deinit();
    _ = try app.session.addTrack("slice");
    try app.session.setInstrument(3, .slicer);

    // Slicer grid open on track 4, swapped to a synth from the command line:
    // the view has to drop back to tracks, or the next keypress reads
    // `instrument.slicer` on a rack holding a poly_synth.
    app.slicer_track = 3;
    app.view = .slicer_grid;
    commands.run(&app, "track-instrument 4 synth");
    try std.testing.expectEqual(app_mod.AppView.tracks, app.view);
    app.handleKey(.{ .char = 'j' }, 0);

    // Same for the drum grid, and for a sampler editor pointed at a pad of
    // the machine that's going away.
    try app.session.setInstrument(3, .drum_machine);
    app.drum_track = 3;
    app.view = .drum_grid;
    commands.run(&app, "track-instrument 4 sampler");
    try std.testing.expectEqual(app_mod.AppView.tracks, app.view);

    try app.session.setInstrument(3, .drum_machine);
    app.sampler_target = .{ .drum = 3 };
    app.view = .sampler_editor;
    commands.run(&app, "track-instrument 4 synth");
    try std.testing.expectEqual(app_mod.AppView.tracks, app.view);
}

test "scrolling down from the bottom of the help view doesn't overflow" {
    var app = try testApp();
    defer app.deinit();
    app.view = .help;
    // `G` parks the scroll at usize max and lets the next draw clamp it. A
    // second key arriving in the same input burst - before any draw - used
    // to add to that saturated value and panic.
    app.handleKey(.{ .char = 'G' }, 0);
    app.handleKey(.{ .char = 'j' }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    app.handleMouse(.{ .x = 10, .y = 10, .button = .none, .kind = .scroll_down }, 100, 24, 0);
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tui_mod.draw(&app, &w, .{ .cols = 100, .rows = 24 });
}

test "the synth editor draws at the 4-column terminal width" {
    var app = try testApp();
    defer app.deinit();
    app.view = .synth_editor;
    var buf: [512 * 1024]u8 = undefined;

    // synth_layout.numCols opens a fourth column at 210 cols; two of the
    // per-column scratch arrays here were still sized for three, so every
    // draw this wide indexed past the end.
    for ([_]u16{ 107, 108, 159, 160, 209, 210, 400 }) |cols| {
        var w = std.Io.Writer.fixed(&buf);
        try tui_mod.draw(&app, &w, .{ .cols = cols, .rows = 60 });
    }
}

test "every mod-matrix source has a name the synth editor can draw" {
    var app = try testApp();
    defer app.deinit();
    app.view = .synth_editor;
    const synth = &app.session.racks.items[0].instrument.poly_synth;
    var buf: [512 * 1024]u8 = undefined;

    // `h`/`l` on a matrix source cycles the whole ModSource enum; the name
    // table stopped at env3, so the two sources past it panicked on draw.
    for (std.enums.values(ws.dsp.synth.ModSource)) |source| {
        synth.mod_matrix[0].source = source;
        var w = std.Io.Writer.fixed(&buf);
        try tui_mod.draw(&app, &w, .{ .cols = 210, .rows = 60 });
    }
}

test "applying a synth preset defers the displaced FX chain's free until the audio thread passes it" {
    var app = try testApp();
    defer app.deinit();
    const rack = app.session.racks.items[0];
    _ = try rack.fx.insert(std.testing.allocator, 0, .reverb, app.session.project.sample_rate);
    app.session.syncTrackChain(0, rack);

    app.synth_track = 0;
    app.view = .synth_editor;
    app.handleKey(.{ .char = 'f' }, 0);
    app.handleKey(.{ .char = 'j' }, 0);
    app.handleKey(.{ .char = 'a' }, 0);

    // The chain the engine read last block can still point at the displaced
    // reverb, so it has to be queued rather than freed under the audio
    // thread's feet - auditioning down the preset list crashed on exactly
    // that, in Reverb.processBlock.
    try std.testing.expect(app.session.retired_fx.items.len > 0);

    // Two completed blocks put every in-flight block strictly past it, so
    // the queue drains instead of growing once per preset walked past.
    var out = [_]f32{0} ** 128;
    app.session.engine.process(&out);
    app.session.engine.process(&out);
    app.session.reclaimRetiredFx();
    try std.testing.expectEqual(@as(usize, 0), app.session.retired_fx.items.len);
}

test "cc-learn binds the armed param to the next controller message, not an earlier one" {
    var app = try testApp();
    defer app.deinit();

    // Arm on the synth's filter cutoff, the way :cc-learn does.
    app.view = .synth_editor;
    app.synth_track = 0;
    app.synth_cursor = 21;
    commands.run(&app, "cc-learn");
    try std.testing.expect(app.cc_learn != null);

    // A frame with nothing on the wire leaves it armed.
    app.tick(1);
    try std.testing.expect(app.cc_learn != null);
    try std.testing.expect(app.session.project.cc_bindings[0] == null);

    var block: [128]f32 = undefined;
    _ = app.session.engine.sendMidi(.{ .cc = .{ .track = 0, .cc = 74, .value = 100 } });
    app.session.engine.process(&block);
    app.tick(2);
    try std.testing.expect(app.cc_learn == null);
    const b = app.session.project.cc_bindings[0].?;
    try std.testing.expectEqual(@as(u7, 74), b.cc);
    try std.testing.expectEqual(@as(u32, 21), b.target.param_id);
    try std.testing.expectEqual(@as(u16, 0), b.target.track);

    // Re-learning the same knob onto another param re-points it rather than
    // leaving one CC driving two things.
    app.synth_cursor = 22;
    commands.run(&app, "cc-learn");
    _ = app.session.engine.sendMidi(.{ .cc = .{ .track = 0, .cc = 74, .value = 20 } });
    app.session.engine.process(&block);
    app.tick(3);
    try std.testing.expectEqual(@as(u32, 22), app.session.project.cc_bindings[0].?.target.param_id);
    try std.testing.expect(app.session.project.cc_bindings[1] == null);
}

test "every command survives hostile arguments" {
    // `testApp` runs on `std.Io.failing`, so nothing here can touch the disk.
    // Bounce/stems are the exception: that path traps rather than erroring on
    // a failing Io and would hang the suite (see docs and prior incidents).
    const denied = [_][]const u8{ "bounce", "stems", "export", "export-midi" };
    const hostile = [_][]const u8{
        "",
        " ",
        "0",
        "-1",
        "99999999999999999999",
        "1e400",
        "nan",
        "-inf",
        "abc",
        "!!!",
        "..",
        "1 -1 nan",
        "0 0 0 0 0",
        "a" ** 400,
    };
    for (hostile) |arg| {
        var app = try testApp();
        defer app.deinit();
        // Guard against a vacuous pass if the table ever comes back empty.
        try std.testing.expect(app.allCmds().len > 50);
        for (app.allCmds()) |c| {
            var skip = false;
            for (denied) |d| {
                if (std.mem.startsWith(u8, c.name, d)) skip = true;
            }
            if (skip) continue;
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ c.name, arg }) catch continue;
            commands.run(&app, line);
        }
    }
}

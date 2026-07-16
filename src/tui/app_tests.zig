//! Integration tests for the TUI App: input dispatch, per-view editors,
//! undo/redo, commands, and frame rendering. Split out of app.zig so the
//! runtime file stays navigable; pulled in by the `test` block there.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const eq_mod = ws.dsp.eq;
const InstrumentKind = ws.InstrumentKind;
const app_mod = @import("app.zig");
const App = app_mod.App;
const history = @import("history.zig");
const AppView = app_mod.AppView;
const note_ms = app_mod.note_ms;
const commands = @import("commands.zig");
const drum_ed = @import("editors/drum.zig");
const slicer_ed = @import("editors/slicer.zig");
const automation_ed = @import("editors/automation.zig");
const style = @import("style.zig");
const piano_ed = @import("editors/piano.zig");
const sampler_ed = @import("editors/sampler.zig");
const spectrum_ed = @import("editors/spectrum.zig");
const preset_ed = @import("editors/preset_picker.zig");
const icons = @import("icons.zig");
const modal_mod = ws.input;

// Not exposed by std.c on this target; declared directly (libc is already
// linked) so tests using real io can redirect $HOME at a scratch dir.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Redirects $HOME at `tmp` for tests that build an App with real io (not
/// `std.Io.failing`) and dispatch real commands - otherwise cmd-history/
/// synth-preset persistence would leak writes into the developer's actual
/// `~/.config/wstudio/`. Same convention user_presets.zig's own tests use.
/// setenv is process-global but tests run single-threaded, so this is safe.
fn redirectHome(tmp: *std.testing.TmpDir) !void {
    var buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrintZ(&buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = setenv("HOME", home.ptr, 1);
}

/// Build a deterministic 3-track app for tests: synth(0), sampler(1), drums(2).
fn testApp() !App {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    errdefer app.deinit();
    try app.session.setInstrument(0, .poly_synth);
    _ = try app.session.addTrack("samp");
    try app.session.setInstrument(1, .sampler);
    _ = try app.session.addTrack("drums");
    try app.session.setInstrument(2, .drum_machine);
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

test "renderBounce sequences notes offline and restores transport" {
    var app = try testApp();
    defer app.deinit();

    // Sequence a note at beat 0 on the synth track; leave the transport stopped.
    app.session.racks.items[0].pattern_player.?.addNote(
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 },
    );
    try std.testing.expect(!app.session.engine.transport.playing);

    var buffer: [4096 * engine_mod.channels]types.Sample = undefined;
    commands.renderBounce(&app, &buffer, 0);

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
    commands.renderBounce(&app, &buffer, start_frame);

    var peak: f32 = 0.0;
    for (buffer) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.001); // note sounds immediately from the note's own start

    try std.testing.expectEqual(@as(u64, 12345), app.session.engine.transport.position_frames);
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

    // No args reports the current value without changing it.
    for (":swing") |c| app.handleKey(.{ .char = c }, 100);
    app.handleKey(.enter, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 75.0), pp.swing.load(.monotonic), 1e-6);
}

test "toggle_mute flips project state and reaches the engine" {
    var app = try testApp();
    defer app.deinit();

    app.applyAction(.toggle_mute, 0);
    try std.testing.expect(app.session.project.tracks.items[0].muted);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.engine.tracks[0].muted);
}

test "toggle_solo flips project state and reaches the engine" {
    var app = try testApp();
    defer app.deinit();

    app.applyAction(.toggle_solo, 0);
    try std.testing.expect(app.session.project.tracks.items[0].soloed);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.engine.tracks[0].soloed);
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

test "enter on a drum track switches to drum_grid view" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 2; // drum machine
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
    try std.testing.expectEqual(@as(u16, 2), app.drum_track);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
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
    _ = slicer_ed.handleKey(&app, .{ .char = ']' });
    _ = slicer_ed.handleKey(&app, .{ .char = 'r' });
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.slicerInst().slices[3].start_norm > start_before);
    try std.testing.expect(app.slicerInst().slices[3].reverse);
}

test "slicer grid: velocity cycle + fine nudge on an active step only" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(2);
    app.slicer_cursor = .{ 0, 0 };

    // No step yet: c and _ refuse rather than editing a phantom step.
    _ = slicer_ed.handleKey(&app, .{ .char = 'c' });
    try std.testing.expectEqual(@as(u8, 127), app.slicerInst().stepVel(0, 0));

    _ = slicer_ed.handleKey(&app, .enter);
    _ = slicer_ed.handleKey(&app, .{ .char = 'c' });
    try std.testing.expectEqual(@as(u8, 95), app.slicerInst().stepVel(0, 0));
    _ = slicer_ed.handleKey(&app, .{ .char = '_' });
    try std.testing.expectEqual(@as(u8, 94), app.slicerInst().stepVel(0, 0));
    _ = slicer_ed.handleKey(&app, .{ .char = '=' });
    try std.testing.expectEqual(@as(u8, 95), app.slicerInst().stepVel(0, 0));
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
    commands.run(&app, "slice 4");
    app.slicer_cursor = .{ 1, 3 };
    _ = slicer_ed.handleKey(&app, .enter); // step on
    try std.testing.expect(app.slicerInst().stepActive(1, 3));

    commands.run(&app, "slice 8"); // re-chop over the programmed pattern
    try std.testing.expectEqual(@as(u8, 8), app.slicerInst().slice_count);

    _ = slicer_ed.handleKey(&app, .{ .char = 'u' }); // undo the re-chop
    try std.testing.expectEqual(@as(u8, 4), app.slicerInst().slice_count);
    try std.testing.expect(app.slicerInst().stepActive(1, 3));

    _ = slicer_ed.handleKey(&app, .{ .char = 'u' }); // undo the step
    try std.testing.expect(!app.slicerInst().stepActive(1, 3));

    _ = slicer_ed.handleKey(&app, .{ .char = 'U' }); // redo the step
    try std.testing.expect(app.slicerInst().stepActive(1, 3));
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

test "slicer grid: visual range yank/paste and dot-repeat" {
    var app = try testApp();
    defer app.deinit();
    try app.session.setInstrument(0, .slicer);
    app.slicer_track = 0;
    app.view = .slicer_grid;
    app.slicerInst().sliceInto(2);
    app.slicerInst().toggleStep(0, 0);
    app.slicerInst().toggleStep(1, 1);

    // v + l + y: yank steps 0-1 across all slices.
    app.slicer_cursor = .{ 0, 0 };
    _ = slicer_ed.handleKey(&app, .{ .char = 'v' });
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

test "slicer grid: variant bank keys ( ) N D, undoable as one stack" {
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

    _ = slicer_ed.handleKey(&app, .{ .char = '(' }); // back to A
    try std.testing.expectEqual(@as(u8, 0), app.slicerInst().variant);
    try std.testing.expect(app.slicerInst().stepActive(0, 0));
    _ = slicer_ed.handleKey(&app, .{ .char = ')' }); // forward to B
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
    app.slicer_cursor = .{ 1, 0 };
    _ = slicer_ed.handleKey(&app, .{ .char = 'C' });
    try std.testing.expectEqual(@as(u8, 1), app.slicerInst().choke_group[1]);
    try std.testing.expectEqual(@as(u8, 0), app.slicerInst().choke_group[0]);
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

    // The generated default clip is one pluck: chop must not crash and must
    // leave a valid (>= 1) slicing either way, undoable.
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
    _ = drum_ed.handleKey(&app, .enter);
    try std.testing.expect(!app.drumMachine().stepActive(0, 0));
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
    _ = drum_ed.handleKey(&app, .{ .char = 'Z' });
    try std.testing.expectEqual(ws.time_grid.Division.eighth, app.drum_grid);
    _ = drum_ed.handleKey(&app, .{ .char = 'z' });
    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.drum_grid);
    _ = drum_ed.handleKey(&app, .{ .char = 'z' });
    try std.testing.expectEqual(ws.time_grid.Division.thirty_second, app.drum_grid);
}

test "drum grid g jumps the step cursor to the pattern start" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.drum_cursor = .{ 0, 5 };

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
    try app.draw(&w, .{ .cols = 100, .rows = 30 });
    const off_output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, off_output, style.dim ++ "[") == null);

    app.piano_ghost = true;
    var buf2: [32 * 1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try app.draw(&w2, .{ .cols = 100, .rows = 30 });
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
    try app.draw(&w, .{ .cols = 100, .rows = 30 });
    // Uncolored (default): the clip cell still wears the generic accent.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), style.acc) != null);

    app.session.project.tracks.items[0].color = 1; // red, index 0 of the palette
    var buf2: [32 * 1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try app.draw(&w2, .{ .cols = 100, .rows = 30 });
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
    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0); // extend the selection to step 3

    app.handleKey(.{ .char = 'y' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 2), app.piano_range_clip.?.count);

    // Paste at step 8: P is a visual-mode action, so re-enter visual first
    // (v establishes the cursor as the paste point; no need to extend it).
    app.piano_cursor_step = 8;
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'P' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 5), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 2.0) != null);
    try std.testing.expect(pp.noteAt(64, 2.25) != null);

    // Select the same range again and delete it - only the untouched note remains.
    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'v' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 3), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expect(pp.noteAt(72, 2.0) != null);
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
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'w' }, 0); // extend one beat forward (0 -> 4)
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 4), app.piano_cursor_step);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expect(pp.noteAt(62, 1.0) == null);
    try std.testing.expect(pp.noteAt(64, 2.0) != null); // untouched, outside the range

    // b moves the extended selection back a beat (from step 12, lands on 8).
    app.piano_cursor_step = 12;
    app.handleKey(.{ .char = 'v' }, 0);
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
    for ("v3ly") |c| app.handleKey(.{ .char = c }, 0);
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

    app.piano_cursor_step = 6;
    _ = piano_ed.handleKey(&app, .enter);
    try std.testing.expect(pp.noteAt(60, 1.0) != null);

    // Toggling back rescales the cursor by its beat position (step 6 @ 6
    // steps/beat = beat 1 = step 4 @ 4 steps/beat), not a raw index copy.
    _ = piano_ed.handleKey(&app, .{ .char = 'T' });
    try std.testing.expectEqual(@as(u16, 4), app.pianoStepsPerBeat());
    try std.testing.expectEqual(@as(u16, 4), app.piano_cursor_step);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), app.piano_note_len, 1e-9);
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
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "1/16") != null);

    _ = piano_ed.handleKey(&app, .{ .char = 'Z' });
    try std.testing.expectEqual(ws.time_grid.Division.eighth, app.piano_division);

    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "PIANO ROLL") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "1/8") != null);

    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.piano_division);
    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    try std.testing.expectEqual(ws.time_grid.Division.thirty_second, app.piano_division);
    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
    _ = piano_ed.handleKey(&app, .{ .char = 'z' });
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
    try app.draw(&w, .{ .cols = 100, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "scratch") == null);

    // Song mode, unlinked to any clip: flagged.
    app.session.setSongMode(true);
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 100, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "scratch: not in the song until stamped") != null);

    // Linked to a clip (arrangement's 'e'): no warning even in song mode.
    try app.session.stampClip(0, 0);
    app.view = .arrangement;
    app.handleKey(.{ .char = 'e' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 100, .rows = 24 });
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

    // Returning to tracks is mode-neutral: it doubles as the mixer while
    // the song plays, so it must never flip the mode itself.
    app.handleKey(.tab, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expect(app.session.song_mode);

    // Opening a pattern editor from tracks while stopped flips back.
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
}

test "z and Z select arrangement grid subdivisions" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    try app.session.stampClip(0, 0);

    try std.testing.expectEqual(ws.time_grid.Division.quarter, app.arr_grid);
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "1/4") != null);

    app.handleKey(.{ .char = 'Z' }, 0);
    try std.testing.expectEqual(ws.time_grid.Division.quarter, app.arr_grid);

    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "ARRANGEMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "1/4") != null);

    app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expectEqual(ws.time_grid.Division.eighth, app.arr_grid);
    app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expectEqual(ws.time_grid.Division.sixteenth, app.arr_grid);
    app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expectEqual(ws.time_grid.Division.thirty_second, app.arr_grid);
}

test "arrangement places moves and cuts clips on the 1/128 grid" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    app.cursor = 0;
    for (0..5) |_| app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expectEqual(ws.time_grid.Division.one_twenty_eighth, app.arr_grid);

    app.arr_cursor_bar = 1;
    app.handleKey(.enter, 0);
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(u32, 1), lane.clips.items[0].start_tick);
    const old_len = lane.clips.items[0].length_ticks;
    app.arr_cursor_bar = 1;
    app.handleKey(.{ .char = '-' }, 0);
    try std.testing.expectEqual(old_len - 1, lane.clips.items[0].length_ticks);
    app.handleKey(.{ .char = '>' }, 0);
    try std.testing.expectEqual(@as(u32, 2), lane.clips.items[0].start_tick);
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
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = 21 }, app.automation_focus);

    // Now tab cycles gain -> pan -> cutoff -> gain, and j nudges the cutoff
    // curve, clamped 20..20_000 like the synth's own param.
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    const synth_clip = automation_ed.currentClip(&app).?;
    try std.testing.expectEqual(@as(usize, 1), synth_clip.automation.findSynthParam(21).?.len);
    app.automation_focus = .gain;
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.pan, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = 21 }, app.automation_focus);
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
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = 7 }, app.automation_focus);
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    const sampler_clip = automation_ed.currentClip(&app).?;
    try std.testing.expectEqual(@as(usize, 1), sampler_clip.automation.findSynthParam(7).?.len);
    app.automation_focus = .gain;
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.pan, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = 7 }, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.gain, app.automation_focus);

    // Drum track: p refuses (drum params are per-pad/per-step, no single
    // per-track setParamAbsolute id space to automate) - gain <-> pan only.
    try app.session.stampClip(2, 0);
    automation_ed.switchTo(&app, 2, 0);
    try std.testing.expectEqual(automation_ed.AutomationFocus.gain, app.automation_focus);
    _ = automation_ed.handleKey(&app, .{ .char = 'p' });
    try std.testing.expectEqual(AppView.automation, app.view); // picker refused to open
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.pan, app.automation_focus);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus.gain, app.automation_focus);

    // Switching back to the synth clip while focus is .gain still offers the
    // cutoff lane again via tab (it's already on that clip).
    automation_ed.switchTo(&app, 0, 0);
    _ = automation_ed.handleKey(&app, .tab);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(automation_ed.AutomationFocus{ .synth_param = 21 }, app.automation_focus);
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

    for (&dm.pattern) |*p| p.store(0, .monotonic);
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

test "drum grid visual mode selects a step range across pads for y/d/P" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.setStepVel(0, 0, 31);
    dm.toggleStep(1, 2);
    dm.toggleStep(3, 14); // outside both the selection and the paste target below

    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'v' }, 0);
    try std.testing.expectEqual(ws.input.Mode.visual, app.modal.mode);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0); // extend to step 3
    app.handleKey(.{ .char = 'y' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u8, 4), app.drum_range_clip.?.width);

    // Paste at step 8 (all pads): P is a visual-mode action, so re-enter
    // visual first (v establishes the cursor as the paste point).
    app.drum_cursor[1] = 8;
    app.handleKey(.{ .char = 'v' }, 0);
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
    app.handleKey(.{ .char = 'v' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expect(!dm.stepActive(0, 0));
    try std.testing.expect(!dm.stepActive(1, 2));
}

test "drum grid visual mode: w/b extend the selection by bar, matching normal-mode jumpBar" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (&dm.pattern) |*p| p.store(0, .monotonic);
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
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.setStepVel(0, 0, 31);
    dm.toggleStep(1, 2);

    // Visual range yank, then a plain normal-mode p at the new cursor -
    // no re-entering visual mode required.
    app.drum_cursor = .{ 0, 0 };
    for ("v3ly") |c| app.handleKey(.{ .char = c }, 0);
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
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.toggleStep(1, 2);
    dm.toggleStep(3, 14); // outside the range below

    app.drum_cursor = .{ 0, 0 };
    for ("y3l") |c| app.handleKey(.{ .char = c }, 0); // y + motion: yank steps 0-3
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u8, 4), app.drum_range_clip.?.width);
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

test "drum grid char/word tiers: x clears just this cell, w/b jump by 4-step group" {
    var app = try testApp();
    defer app.deinit();
    app.view = .drum_grid;
    app.drum_track = 2;
    const dm = app.drumMachine();
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.setStepCount(32);
    dm.toggleStep(0, 5); // outside the first 4-step group (0-3)
    dm.toggleStep(2, 5);
    dm.toggleStep(2, 2); // inside the first 4-step group
    dm.toggleStep(1, 20); // far away, untouched by anything below

    // x: instant single-cell clear, no operator arming needed.
    app.drum_cursor = .{ 0, 5 };
    app.handleKey(.{ .char = 'x' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(!dm.stepActive(0, 5));
    try std.testing.expect(dm.stepActive(2, 5)); // a different pad's step at the same column survives

    // w: jump forward to the next 4-step group boundary (step 4); b: back to 0.
    app.drum_cursor = .{ 0, 0 };
    app.handleKey(.{ .char = 'w' }, 0);
    try std.testing.expectEqual(@as(u8, 4), app.drum_cursor[1]);
    app.handleKey(.{ .char = 'b' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.drum_cursor[1]);

    // dw: clear exactly the current 4-step group (0-3), leaving steps
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

    const before = app.drumMachine().pattern[0].load(.acquire);
    _ = drum_ed.handleKey(&app, .{ .char = 'P' });
    try std.testing.expectEqual(before, app.drumMachine().pattern[0].load(.acquire));

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
    const kick_before = dm.pattern[0].load(.acquire);

    app.drum_cursor = .{ 0, 2 };
    _ = drum_ed.handleKey(&app, .enter); // toggle a step
    _ = drum_ed.handleKey(&app, .{ .char = 'N' }); // new variant (B)
    try std.testing.expectEqual(@as(u8, 2), dm.variant_count);

    _ = drum_ed.handleKey(&app, .{ .char = 'u' }); // undo variant add
    try std.testing.expectEqual(@as(u8, 1), dm.variant_count);
    _ = drum_ed.handleKey(&app, .{ .char = 'u' }); // undo the toggle
    try std.testing.expectEqual(kick_before, dm.pattern[0].load(.acquire));

    _ = drum_ed.handleKey(&app, .{ .char = 'U' }); // redo the toggle
    try std.testing.expectEqual(kick_before ^ (1 << 2), dm.pattern[0].load(.acquire));
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
    pp.notes[0].pitch = 72; // different content for the second stamp
    app.arr_cursor_bar = 0;
    app.handleKey(.enter, 0);
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

test "arrangement g plays from the cursor bar" {
    var app = try testApp();
    defer app.deinit();

    app.view = .arrangement;
    app.arr_cursor_bar = 2;
    app.handleKey(.{ .char = 'g' }, 0);

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

    const signature = app.session.project.beats_per_bar;
    commands.run(&app, "sig 3/4/4");
    try std.testing.expectEqual(signature, app.session.project.beats_per_bar);

    commands.run(&app, "seek 18446744073709551615");
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "too large") != null);

    commands.run(&app, "gain   1 -6");
    try std.testing.expectApproxEqAbs(@as(f32, -6.0), app.session.project.tracks.items[0].gain_db, 1e-6);
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
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "DRUMS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "kick") != null);
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

    for ("3j") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u8, 3), app.sampler_param);
    for ("2k") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u8, 1), app.sampler_param);

    app.handleKey(.{ .char = 'G' }, 0);
    try std.testing.expectEqual(@as(u8, ws.dsp.Sampler.param_count - 1), app.sampler_param);
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

test "draw renders drum-pad sampler editor without overflowing" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.sampler_target = .{ .drum = 2 };
    app.drum_cursor = .{ 0, 0 };
    app.view = .sampler_editor;
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 30 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SAMPLER") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "attack") != null);
}

test "draw renders standalone sampler editor with root row" {
    var app = try testApp();
    defer app.deinit();

    app.sampler_target = .{ .sampler = 1 };
    app.view = .sampler_editor;
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 34 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SAMPLER") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "root") != null);
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

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "TRACKS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "synth") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "drums") != null);
    // Per-track instrument-kind icons (synth, sampler, drum) are present.
    try std.testing.expect(std.mem.indexOf(u8, frame, icons.synth) != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, icons.sampler) != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, icons.drum) != null);
}

test "draw shows a dirty-flag warning icon in the header once edited" {
    var app = try testApp();
    defer app.deinit();

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.warn) == null);

    app.applyAction(.toggle_mute, 0);
    try std.testing.expect(app.dirty);
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.warn) != null);
}

test "transport indicator shows the unicode glyph without the font, the icon with it, never both" {
    var app = try testApp();
    defer app.deinit();
    var buf: [32 * 1024]u8 = undefined;
    defer icons.font_installed = false;

    icons.font_installed = false;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\u{25A0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.stop) == null);

    icons.font_installed = true;
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\u{25A0}") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.stop) != null);

    _ = app.session.engine.send(.play);
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);

    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\u{25BA}") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.play) != null);

    icons.font_installed = false;
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
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
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
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
        .{ .view = .synth_fx_picker, .label = "SYNTH FX" },
        .{ .view = .preset_picker, .label = "PRESETS" },
    };
    for (cases) |case| {
        app.view = case.view;
        app.setStatus("picker feedback", .{});
        var w = std.Io.Writer.fixed(&buf);
        try app.draw(&w, .{ .cols = 120, .rows = 24 });
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
    try app.draw(&w, .{ .cols = 100, .rows = 24 });
    const track_frame = w.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, track_frame, "[enter:edit]"));
    try std.testing.expect(std.mem.indexOf(u8, track_frame, "p: piano  s: fx  m: mute") != null);

    app.setTrackRow(app.track_rows_len);
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 100, .rows = 24 });
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
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "TRACKS") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "BASICS") != null);
    // Long entries are clamped by the renderer instead of relying on the
    // terminal to wrap them into unbudgeted rows.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "then MASTER last") == null);

    // g still jumps all the way back up to the command table.
    app.handleKey(.{ .char = 'g' }, 0);
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
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
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "FX CHAIN") != null);
    // A fresh chain is empty - the body is the insert hint.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "chain empty") != null);
}

test "draw renders track_spectrum after pressing s" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.{ .char = 's' }, 0);
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
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
    try app.draw(&w, .{ .cols = 120, .rows = 40 });
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

test "track delete remaps a surviving track's undo entry instead of wiping history" {
    var app = try testApp();
    defer app.deinit();

    // Capture the drum machine at track 2 (factory pattern), then toggle a
    // step so it diverges from the captured "before" state.
    const before = app.session.racks.items[2].instrument.drum_machine.variantData(0).pattern[0];
    history.push(&app, history.captureDrum(&app, 2));
    app.session.racks.items[2].instrument.drum_machine.toggleStep(0, 0);
    try std.testing.expect(app.session.racks.items[2].instrument.drum_machine.variantData(
        app.session.racks.items[2].instrument.drum_machine.variant,
    ).pattern[0] != before);

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
    try std.testing.expectEqual(before, dm.variantData(dm.variant).pattern[0]);
}

test "track delete drops an undo entry that named the deleted track" {
    var app = try testApp();
    defer app.deinit();

    const before = app.session.racks.items[2].instrument.drum_machine.variantData(0).pattern[0];
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
    try std.testing.expect(dm.variantData(dm.variant).pattern[0] != before);
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
    const before = app.session.racks.items[2].instrument.drum_machine.variantData(0).pattern[0];
    history.push(&app, history.captureDrum(&app, 2));
    app.session.racks.items[2].instrument.drum_machine.toggleStep(0, 0);

    app.cursor = 2; // the drum machine
    app.handleKey(.{ .char = 'K' }, 0); // swap up with the sampler at index 1

    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.history.undo_stack.items.len);
    try std.testing.expectEqual(@as(u16, 1), app.history.undo_stack.items[0].drum.track);

    app.handleKey(.{ .char = 'u' }, 0);
    const dm = &app.session.racks.items[1].instrument.drum_machine;
    try std.testing.expectEqual(before, dm.variantData(dm.variant).pattern[0]);
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

    // Cycle all the way around: 7 colors + "none" = 8 states total.
    for (0..7) |_| app.handleKey(.{ .char = ']' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.session.project.tracks.items[0].color);

    // Backward wraps the other way, straight to the last color.
    app.handleKey(.{ .char = '[' }, 0);
    try std.testing.expectEqual(@as(u8, 7), app.session.project.tracks.items[0].color);

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

test ":group-add/:group-rename/:group-del/:track-group/:group-fx" {
    var app = try testApp();
    defer app.deinit();

    for (":group-add") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("untitled group", app.session.groups[0].?.name);

    for (":group-rename 1 drum bus") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("drum bus", app.session.groups[0].?.name);

    for (":track-group 3 1") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(?u8, 0), app.session.project.tracks.items[2].group);

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

test ":sig sets beats per bar and reshapes bar math" {
    var app = try testApp();
    defer app.deinit();

    for (":sig 3") |c| app.handleKey(.{ .char = c }, 0);
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

    // Bad input is rejected and leaves the setting alone.
    for (":sig 3/8") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u8, 3), app.session.project.beats_per_bar);
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

test ":track-rename renames a track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":track-rename 1 renamed") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("renamed", app.session.project.tracks.items[0].name);
}

test ":track-rename with no track number renames the cursor track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    _ = try app.session.addTrack("second");
    app.cursor = 1;

    for (":track-rename bass") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("untitled track", app.session.project.tracks.items[0].name);
    try std.testing.expectEqualStrings("bass", app.session.project.tracks.items[1].name);

    // A single bare number is still a missing-<name> error, not a rename
    // to that numeral - the same lone-index usage that already errored.
    for (":track-rename 3") |c| app.handleKey(.{ .char = c }, 0);
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

test "synth editor jk moves cursor, hl adjusts waveform" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u8, 0), app.synth_cursor);

    var block: [64]types.Sample = undefined;
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    const synth = &app.session.racks.items[0].instrument.poly_synth;
    try std.testing.expect(synth.waveform != .saw);

    // AMP ENV's "attack" (id 16) is the MAIN subview's 46th nav entry now
    // that OSC A/B/C, SUB, NOISE, MOD, and FILTER 1/2 all sort ahead of it
    // - see synth_layout.zig's main_sections declaration order.
    for (0..46) |_| app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u8, 16), app.synth_cursor);

    const old_attack = synth.attack_s;
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    try std.testing.expect(synth.attack_s > old_attack);
}

test "draw renders synth editor without errors" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.synth_editor, app.view);

    // Tall enough that the whole single-column MAIN body (~76 rows - see
    // synth_layout.zig's main_sections) fits without scrolling, so this
    // stays a simple "did real content render" smoke test rather than a
    // reflection of exactly where AMP ENV happens to land in the order.
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 100 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SYNTH") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "attack") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "sustain") != null);
}

test "synth section focus isolates navigation and rendering" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expect(app.synth_section_focus);

    app.handleKey(.{ .char = 'G' }, 0);
    try std.testing.expectEqual(@as(u8, 185), app.synth_cursor);
    app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u8, 185), app.synth_cursor);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 120, .rows = 30 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "FOCUS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "OSC A") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "OSC B") == null);

    app.handleKey(.{ .char = '}' }, 0);
    // At 120 columns, the next card in column-major visual order is OSC C.
    try std.testing.expectEqual(@as(u8, 50), app.synth_cursor);
    app.handleKey(.{ .char = 'z' }, 0);
    try std.testing.expect(!app.synth_section_focus);
}

test "synth editor g/G jump to the first/last parameter" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    // Just a "did we move off the start" sanity check before testing g/G -
    // 10 j's lands on OSC B's first entry (id 6, on/off) now that OSC A's
    // 10 entries (waveform..wt.pos) sort ahead of it.
    for (0..10) |_| app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u8, 6), app.synth_cursor);

    app.handleKey(.{ .char = 'g' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.synth_cursor);
    app.handleKey(.{ .char = 'G' }, 0);
    // Last id of the "main" subview: OUT's "gain" (id 38) - the last
    // section in synth_layout.zig's main_sections declaration order.
    try std.testing.expectEqual(@as(u8, 38), app.synth_cursor);
}

test "synth editor param nudges coalesce into one undo step, u/U round-trips" {
    var app = try testApp();
    defer app.deinit();
    var block: [64]types.Sample = undefined;

    app.handleKey(.enter, 0); // cursor 0 = synth
    // 46 j's: land on attack (id 16), the AMP ENV section's first entry -
    // see synth_layout.zig's main_sections declaration order.
    for (0..46) |_| app.handleKey(.{ .char = 'j' }, 0); // land on attack (a numeric param)
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

    app.handleKey(.enter, 0); // cursor 0 = synth
    // 48 j's: land on sustain (id 18), AMP ENV's 3rd entry (attack, decay,
    // sustain - see synth_layout.zig's main_sections).
    for (0..48) |_| app.handleKey(.{ .char = 'j' }, 0); // sustain (0..1, clamps)
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
    // 10 j's: land on osc_b_on (id 6), OSC B's first entry - OSC A's 10
    // entries (waveform..wt.pos) sort ahead of it now.
    for (0..10) |_| app.handleKey(.{ .char = 'j' }, 0); // osc_b_on (a toggle)
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
    // 46 j's: land on attack (id 16) - see synth_layout.zig's main_sections.
    for (0..46) |_| app.handleKey(.{ .char = 'j' }, 0); // attack
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

    app.handleKey(.{ .char = 'g' }, 0); // flushes the open decay batch
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
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
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
    try app.draw(&w, .{ .cols = 120, .rows = 36 });
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
    try app.draw(&w, .{ .cols = 100, .rows = 24 });
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

test "piano roll p does not open for drum track" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 2; // drum machine
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
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
    app.handleKey(.enter, 0);
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
    app.handleKey(.enter, 0);
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
    app.handleKey(.enter, 0);
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

    // dd/yy are the tier above a bar range: the whole lane. x stays the
    // single-clip instant delete (this editor's "char", one bar).
    try app.session.stampClip(0, 0);
    app.arr_cursor_bar = 20;
    app.handleKey(.{ .char = 'x' }, 0);
    try std.testing.expect(lane.clipAt(640) == null);

    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.arr_range_clip.?.clips.len); // just bar 0's clip left
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

test "piano roll . repeats the last drag on whatever note sits under the new cursor" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;
    app.handleKey(.enter, 0); // C4 @ step 0
    app.piano_cursor_step = 4;
    app.handleKey(.enter, 0); // C4 @ step 4 (a second note to repeat onto)

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
    app.piano_cursor_step = 4;
    app.piano_cursor_pitch = 60;
    app.handleKey(.enter, 0);

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
    for (&dm.pattern) |*p| p.store(0, .monotonic);
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

    // b toggles it off; playback then runs past the old loop end.
    app.handleKey(.{ .char = 'b' }, 0);
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

test "R opens the command prompt pre-filled with :track-rename <n> " {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 1;

    app.handleKey(.{ .char = 'R' }, 0);
    try std.testing.expectEqual(ws.input.Mode.command, app.modal.mode);
    try std.testing.expectEqualStrings("track-rename 2 ", app.modal.cmd_buf[0..app.modal.cmd_len]);

    for ("keys") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("keys", app.session.project.tracks.items[1].name);
}

test "R opens the command prompt pre-filled with :pad-rename <n> in the drum grid" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.view = .drum_grid;
    app.drum_cursor = .{ 3, 0 }; // pad 3 = "open"

    _ = drum_ed.handleKey(&app, .{ .char = 'R' });
    try std.testing.expectEqual(ws.input.Mode.command, app.modal.mode);
    try std.testing.expectEqualStrings("pad-rename 4 ", app.modal.cmd_buf[0..app.modal.cmd_len]);

    for ("808oh") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("808oh", app.drumMachine().padName(3));
    // Renaming doesn't touch the actual sample.
    try std.testing.expect(!app.drumMachine().pads[3].?.pad.user_sample);
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

    // Cursor on the synth track: "pad-r" (drum-scoped) has no in-scope
    // candidate, so Tab is a no-op - cmd_buf is untouched.
    app.cursor = 0;
    for (":pad-r") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("pad-r", app.modal.cmd_buf[0..app.modal.cmd_len]);

    // Cursor on the drum track: the same prefix now completes in full.
    app.handleKey(.escape, 0);
    app.cursor = 2;
    for (":pad-r") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("pad-rename ", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "Tab cycles mnemonic command names and ignores compatibility aliases" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // The short q/qa spellings remain dispatchable but completion only
    // offers the mnemonic quit names.
    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("quit", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("quit!", app.modal.cmd_buf[0..app.modal.cmd_len]);
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

    // "track" matches only the track-* commands (table order: add/del/rename).
    app.modal.cmd_len = 0;
    app.modal.cmd_cursor = 0;
    for ("track") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("track-add", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("track-del", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("track-rename", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "suggestion popup highlight tracks the completed candidate" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();
    app.cursor = 2; // drum track: "d" stem now also matches drum-kit/drum-kit-save

    for (":d") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0); // -> "drum-kit"; the short d alias is ignored
    try std.testing.expectEqualStrings("drum-kit", app.modal.cmd_buf[0..app.modal.cmd_len]);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 100, .rows = 30 });
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
/// there - `openBrowser` only needs the directory) so `:e`/`:load-sample`'s
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

    var app = try appRootedAt(&tmp);
    defer app.deinit();
    try app.session.setInstrument(0, .sampler);
    app.openBrowser(.load_sample);

    try std.testing.expectEqual(AppView.file_browser, app.view);
    const entries = app.browser_entries.items;
    try std.testing.expectEqual(@as(usize, 3), entries.len); // dir + 2 .wav, txt and dotfile excluded
    try std.testing.expect(entries[0].is_dir);
    try std.testing.expectEqualStrings("zzz_sub", entries[0].name);
    try std.testing.expect(!entries[1].is_dir);
    try std.testing.expectEqualStrings("a.wav", entries[1].name);
    try std.testing.expectEqualStrings("b.wav", entries[2].name);
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

test ":load-sample with no path browse; refuse first with no matching track; targets pad on a drum track" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();

    // Blank track 0: no sampler/drum-machine to receive the load.
    for (":load-sample") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "load-sample: select");

    // With a sampler track selected, :load-sample opens the browser.
    try app.session.setInstrument(0, .sampler);
    for (":load-sample") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    app.handleKey(.escape, 0);

    // With a drum-machine track selected, :load-sample targets the cursor pad.
    try app.session.setInstrument(0, .drum_machine);
    app.drum_cursor[0] = 2;
    for (":load-sample") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
    try std.testing.expectEqual(@as(u8, 2), app.browser_purpose.load_pad);
}

test ":load-clip refuses without a sampler track, then loads a whole-clip note and stamps it" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();

    for (":load-clip") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "load-clip: select");

    try app.session.setInstrument(0, .sampler);
    // Contrived tempo so 1 frame = 1 beat exactly (sr*60/bpm == 1), keeping
    // the wav tiny while the beats math stays exact and easy to assert on.
    app.session.project.tempo_bpm = @as(f64, @floatFromInt(app.session.project.sample_rate)) * 60.0;

    var wav_buf: [64]u8 = undefined;
    var fw = std.Io.Writer.fixed(&wav_buf);
    try ws.wav.write(&fw, app.session.project.sample_rate, 1, &[_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 }, .pcm16);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/vox.wav", .{&tmp.sub_path});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "vox.wav", .data = fw.buffered() });

    app.arr_cursor_bar = 2;
    commands.loadClipFromPath(&app, path);

    try std.testing.expect(app.session.racks.items[0].instrument.sampler.pad.user_sample);
    try std.testing.expectEqual(@as(usize, 5), app.session.racks.items[0].instrument.sampler.pad.samples.len);

    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch); // default root_note
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), pp.length_beats, 1e-9);

    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try std.testing.expectEqual(@as(u32, 64), lane.clips.items[0].start_tick);
    try std.testing.expectEqual(@as(u32, 256), lane.clips.items[0].length_ticks); // ceil(5 beats / 4 per bar)
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

test "mouse click on a tracks-view row selects and opens it" {
    var app = try testApp();
    defer app.deinit();

    // A real run loop always draws before dispatching input, which is what
    // populates `track_rows_shown` (needed to locate the pinned master row
    // under scrolling - see App.tracksMouse).
    var buf: [8 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });

    // row 0 = "TRACKS" title; track i sits at row i+1 (see App.tracksMouse).
    app.handleMouse(.{ .x = 5, .y = app_mod.content_top + 3, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(usize, 2), app.cursor); // track 2 = drum machine
    try std.testing.expectEqual(AppView.drum_grid, app.view);
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
    try app.draw(&w, .{ .cols = 80, .rows = 15 });
    const frame = w.buffered();
    // The cursor's track must actually be drawn on screen...
    try std.testing.expect(std.mem.indexOf(u8, frame, ">") != null);
    // ...and the pinned master row must still be visible alongside it.
    try std.testing.expect(std.mem.indexOf(u8, frame, "MASTER") != null);

    // Scrolling back to the top must bring track 1 back into view.
    app.cursor = 0;
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 15 });
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
    try app.draw(&w, .{ .cols = 80, .rows = 15 });
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
    try app.draw(&w, .{ .cols = 80, .rows = 15 });
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

    // row 0 = title, row 1 = step header, row 2 = pad 0. Cell columns (10-char
    // gutter, 1-char "│" every 4 steps, 3-char cells): step1 x in [14,17),
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

test "mouse scroll over a synth param row selects and nudges it" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.enter, 0); // opens the synth editor for track 0
    try std.testing.expectEqual(AppView.synth_editor, app.view);

    const old_detune = app.session.racks.items[0].instrument.poly_synth.detune_cents;

    // OSC A's "detune" (id 2) is the MAIN subview's 3rd content row (0:wave,
    // 1:pls.width, 2:detune - see synth_layout.zig's main_sections); +1 for
    // the header row above it, +1 again since this "row" param is 1-based
    // content-row numbering (row 1 == the first line below the title - see
    // editors/synth.zig's paramAtRow). synth_scroll starts at 0, so this
    // small a row is on-screen even at this test's 24-row terminal height.
    const row = app_mod.content_top + 4;
    app.handleMouse(.{ .x = 20, .y = row, .button = .none, .kind = .scroll_up }, 80, 24, 0);
    try std.testing.expectEqual(@as(u8, 2), app.synth_cursor);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.racks.items[0].instrument.poly_synth.detune_cents > old_detune);
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

    // rows=30 gives the waveform its full 8-row cap (rows [1,9)); gutter=2,
    // width=min(cols-2,120)=78 for cols=80. x=10 -> norm ~0.10, nearer the
    // start marker (0.0) than the end (1.0).
    var block: [64]types.Sample = undefined;
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 3, .button = .left, .kind = .press }, 80, 30, 0);
    app.session.engine.process(&block);
    try std.testing.expect(app.drumMachine().pads[0].?.pad.start_norm > 0.0);
    try std.testing.expectEqual(@as(f32, 1.0), app.drumMachine().pads[0].?.pad.end_norm); // untouched

    app.handleMouse(.{ .x = 20, .y = app_mod.content_top + 3, .button = .left, .kind = .drag }, 80, 30, 0);
    app.session.engine.process(&block);
    try std.testing.expect(app.drumMachine().pads[0].?.pad.start_norm > 0.1);

    app.handleMouse(.{ .x = 20, .y = app_mod.content_top + 3, .button = .left, .kind = .release }, 80, 30, 0);
    try std.testing.expect(app.sampler_drag_marker == null);
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
    // columns 11..18 (see editors/spectrum.zig's strip geometry).
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
    try std.testing.expectEqual(@as(usize, 2), app.session.engine.master_chain_len);

    // '>' moves the focused comp after the delay; focus follows it.
    app.fx_focus = 0;
    _ = spectrum_ed.handleKey(&app, .{ .char = '>' });
    try std.testing.expectEqual(ws.FxKind.delay, fx.units.items[0].kind());
    try std.testing.expectEqual(ws.FxKind.comp, fx.units.items[1].kind());
    try std.testing.expectEqual(@as(usize, 1), app.fx_focus);
    // At the chain's end '>' is a no-op.
    _ = spectrum_ed.handleKey(&app, .{ .char = '>' });
    try std.testing.expectEqual(@as(usize, 1), app.fx_focus);

    // 'b' bypasses the focused comp: kept in the chain, dropped from the
    // engine's device list.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'b' });
    try std.testing.expect(fx.units.items[1].bypassed);
    try std.testing.expectEqual(@as(usize, 1), app.session.engine.master_chain_len);
    _ = spectrum_ed.handleKey(&app, .{ .char = 'b' });
    try std.testing.expectEqual(@as(usize, 2), app.session.engine.master_chain_len);
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

test "FX chain: EQ kind field cycles peak/lowpass/highpass, gain row becomes slope for a filter band" {
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

    // Clamped, not wrapped, past highpass.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    try std.testing.expectEqual(eq_mod.BandKind.highpass, eq.bands[0].kind);

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
    for (0..3) |_| _ = spectrum_ed.handleKey(&app, .{ .char = 'h' });
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
    try app.draw(&w, .{ .cols = 100, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[classic]") != null);

    _ = spectrum_ed.handleKey(&app, .{ .char = 'l' });
    const fx = &app.session.racks.items[0].fx;
    try std.testing.expectEqual(ws.dsp.multiband_comp.Style.ott, fx.units.items[0].payload.mb_comp.style);

    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 100, .rows = 30 });
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

    // No sidechain source picked yet: scpad stays hidden.
    try std.testing.expectEqual(@as(usize, 6), spectrum_ed.visibleParamCount(&app, .comp, payload));

    // Sidechain pointed at track 1 (a sampler, not a drum machine): still hidden.
    payload.comp.sidechain_source = .{ .track = 1, .pad = null };
    try std.testing.expectEqual(@as(usize, 6), spectrum_ed.visibleParamCount(&app, .comp, payload));

    // Sidechain pointed at track 2 (the drum machine): scpad appears.
    payload.comp.sidechain_source = .{ .track = 2, .pad = null };
    try std.testing.expectEqual(@as(usize, 7), spectrum_ed.visibleParamCount(&app, .comp, payload));

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 100, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "scpad") != null);

    // Pick a pad, then nudge the sidechain track (idx 5) off the drum
    // machine and onto the sampler - the now-stale pad selection must
    // clear itself (see clearStaleSidechainPad's doc comment for why a
    // lingering pad silently zeroes the detector instead of falling back
    // to whole-track sidechain).
    payload.comp.sidechain_source = .{ .track = 2, .pad = 3 };
    app.fx_param = 5;
    _ = spectrum_ed.handleKey(&app, .{ .char = 'h' }); // track 2 -> track 1
    try std.testing.expectEqual(@as(u16, 1), payload.comp.sidechain_source.?.track);
    try std.testing.expectEqual(@as(?u8, null), payload.comp.sidechain_source.?.pad);
    try std.testing.expectEqual(@as(usize, 6), spectrum_ed.visibleParamCount(&app, .comp, payload));

    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 100, .rows = 30 });
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
    try std.testing.expectEqual(@as(usize, 1), app.session.engine.groups[g].chain_len);

    // 'x' removes it, reaching the engine the same way.
    _ = spectrum_ed.handleKey(&app, .{ .char = 'x' });
    try std.testing.expectEqual(@as(usize, 0), app.session.groups[g].?.fx.units.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.engine.groups[g].chain_len);

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
    try app.draw(&w, .{ .cols = 40, .rows = 10 });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "terminal too small") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "need 80x14, have 40x10") != null);
    // No view content leaks through the gate.
    try std.testing.expect(std.mem.indexOf(u8, out, "TRACKS") == null);

    // At exactly the minimum the real frame renders.
    var buf2: [32 * 1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try app.draw(&w2, .{ .cols = 80, .rows = 14 });
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

    // Enter applies the survivor to the synth and bounces back.
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    const s = &app.session.racks.items[0].instrument.poly_synth;
    const expected = ws.dsp.synth_presets.find("acid-bass").?;
    try std.testing.expectEqual(expected.voice_mode, s.voice_mode);
    try std.testing.expectApproxEqAbs(expected.filter_res, s.filter_res, 1e-6);
    try std.testing.expect(app.dirty);
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
    try std.testing.expect(auditioned.waveform != original.waveform or auditioned.filter_cutoff != original.filter_cutoff);

    app.handleKey(.escape, 124);
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    const restored = app.session.racks.items[0].instrument.poly_synth.toPatch();
    try std.testing.expectEqualDeep(original, restored);
    try std.testing.expect(!app.dirty);
}

test "f in the drum grid opens the kit picker and enter regenerates the pads" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.view = .drum_grid;

    app.handleKey(.{ .char = 'f' }, 0);
    try std.testing.expectEqual(AppView.preset_picker, app.view);
    try std.testing.expectEqual(preset_ed.Kind.drum, app.preset_picker_kind);

    // j to the second variant ("analog"), enter applies it.
    app.handleKey(.{ .char = 'j' }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
    try std.testing.expect(app.dirty);
    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "analog") != null);
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
    try rt.loadString("t = wstudio.api.track_get(2); assert(t.name == 'samp' and t.kind == 'sampler' and t.muted == false and t.group == nil)");
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

    // track_add returns the new 1-based index with the instrument applied;
    // track_del removes it again.
    try rt.loadString("i = wstudio.api.track_add({ kind = 'drum', name = 'beats' })");
    try rt.loadString("t = wstudio.api.track_get(i); assert(t.kind == 'drum' and t.name == 'beats')");
    try rt.loadString("n = wstudio.api.track_count(); wstudio.api.track_del(i); assert(wstudio.api.track_count() == n - 1)");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.track_add({ kind = 'nope' })"));
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

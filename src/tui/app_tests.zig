//! Integration tests for the TUI App: input dispatch, per-view editors,
//! undo/redo, commands, and frame rendering. Split out of app.zig so the
//! runtime file stays navigable; pulled in by the `test` block there.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const InstrumentKind = ws.InstrumentKind;
const app_mod = @import("app.zig");
const App = app_mod.App;
const AppView = app_mod.AppView;
const note_ms = app_mod.note_ms;
const commands = @import("commands.zig");
const drum_ed = @import("editors/drum.zig");
const automation_ed = @import("editors/automation.zig");
const style = @import("style.zig");
const piano_ed = @import("editors/piano.zig");
const sampler_ed = @import("editors/sampler.zig");
const spectrum_ed = @import("editors/spectrum.zig");
const icons = @import("icons.zig");
const modal_mod = ws.input;

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
    // Tracks: 0 "track 1", 1 "samp", 2 "drums" (+ master row at 3).
    app.cursor = 0;

    for ("/drs") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(ws.input.Mode.search, app.modal.mode);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.cursor); // "drums"

    for ("/smp") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor); // "samp"

    // Only "samp" matches "smp" — n/N both just re-land on it (wraparound
    // with a single hit).
    app.handleKey(.{ .char = 'n' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    app.handleKey(.{ .char = 'N' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor);

    // A pattern matching two tracks ("track 1" and "samp" both have 'a';
    // "drums" doesn't) cycles between them, skipping the non-match.
    for ("/a") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor); // "track 1"
    app.handleKey(.{ .char = 'n' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor); // "samp"
    app.handleKey(.{ .char = 'n' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor); // back to "track 1"
    app.handleKey(.{ .char = 'N' }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor); // reverse: "samp"
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
    try std.testing.expectEqual(@as(usize, 0), app.cursor); // no match — stays put
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "no match") != null);
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
    for (":humanize 80") |c| app.handleKey(.{ .char = c }, 100) ;
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

test "drum grid step toggle" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;

    try std.testing.expect(app.drumMachine().stepActive(0, 0));
    app.drum_cursor = .{ 0, 0 };
    _ = drum_ed.handleKey(&app, .enter);
    try std.testing.expect(!app.drumMachine().stepActive(0, 0));
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

    // Select the same range again and delete it — only the untouched note remains.
    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'v' }, 0);
    for ("3l") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(u16, 3), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expect(pp.noteAt(72, 2.0) != null);
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

    // dd/yy are the tier above w/b's bar range: the whole pattern.
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u16, 2), app.piano_clip.?.count); // both remaining notes
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
}

test "piano roll char/word tiers: x deletes the note under the cursor, w/b jump by bar" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 8.0; // 4 beats/bar, straight grid (4 steps/beat) -> 16 steps/bar
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 64, .start_beat = 4.0, .duration_beat = 0.25 }); // bar 2, step 16

    // x: instant single-note delete, no operator arming needed.
    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'x' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(pp.noteAt(60, 0.0) == null);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);

    // w: jump forward to the next bar boundary (step 16); b: back to bar 0.
    app.piano_cursor_step = 0;
    app.handleKey(.{ .char = 'w' }, 0);
    try std.testing.expectEqual(@as(u16, 16), app.piano_cursor_step);
    app.handleKey(.{ .char = 'b' }, 0);
    try std.testing.expectEqual(@as(u16, 0), app.piano_cursor_step);

    // dw: delete exactly the current bar's worth of steps (0-15), leaving
    // the note at bar 2 (step 16) untouched.
    for ("dw") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(pp.noteAt(64, 4.0) != null);
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

test "Z toggles piano roll zoom and compacts the rendered grid" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    const pp = &app.session.racks.items[0].pattern_player.?;
    pp.length_beats = 16.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });

    try std.testing.expectEqual(@as(usize, 3), app.pianoCellWidth());
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "zoom") == null);

    _ = piano_ed.handleKey(&app, .{ .char = 'Z' });
    try std.testing.expectEqual(@as(usize, 1), app.pianoCellWidth());

    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "PIANO ROLL") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "zoom") != null);

    _ = piano_ed.handleKey(&app, .{ .char = 'Z' });
    try std.testing.expectEqual(@as(usize, 3), app.pianoCellWidth());
}

test "piano roll flags an unlinked scratch pattern in song mode, not pattern mode" {
    var app = try testApp();
    defer app.deinit();
    app.view = .piano_roll;
    app.piano_track = 0;
    var buf: [32 * 1024]u8 = undefined;

    // Pattern mode: the live pattern IS what plays — no scratch warning.
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

test "Z toggles arrangement zoom and compacts the rendered timeline" {
    var app = try testApp();
    defer app.deinit();
    app.view = .arrangement;
    try app.session.stampClip(0, 0);

    try std.testing.expectEqual(@as(usize, 4), app.arrCellWidth());
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "zoom") == null);

    app.handleKey(.{ .char = 'Z' }, 0);
    try std.testing.expectEqual(@as(usize, 2), app.arrCellWidth());

    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "ARRANGEMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "zoom") != null);

    app.handleKey(.{ .char = 'Z' }, 0);
    try std.testing.expectEqual(@as(usize, 4), app.arrCellWidth());
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

    // Select the same range again and delete it — the curve goes bare.
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'v' });
    for ("3l") |c| _ = automation_ed.handleKey(&app, .{ .char = c });
    _ = automation_ed.handleKey(&app, .{ .char = 'd' });
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 0), clip.automation.gain.len);

    // Paste the yanked points back — like piano/arrangement, range-paste only
    // lives inside visual mode (a plain normal-mode `P` is a different,
    // whole-content clipboard that automation doesn't have).
    _ = automation_ed.handleKey(&app, .{ .char = 'v' });
    _ = automation_ed.handleKey(&app, .{ .char = 'P' });
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), clip.automation.gain.len);
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

test "automation editor char/word tiers: x deletes the point under the cursor, w/b jump by bar" {
    var app = try testApp();
    defer app.deinit();

    try app.session.stampClip(0, 0);
    // Extend the clip to 2 bars so there's a second bar boundary to jump to.
    automation_ed.switchTo(&app, 0, 0);
    const clip = automation_ed.currentClip(&app).?;
    clip.length_bars = 2;

    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 0
    try std.testing.expectEqual(@as(usize, 1), clip.automation.gain.len);

    // x: instant single-point delete, no operator arming needed.
    _ = automation_ed.handleKey(&app, .{ .char = 'x' });
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 0), clip.automation.gain.len);

    // w: jump forward to the next bar boundary (step 16, 4 beats/bar * 4);
    // b: back to bar 0.
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'w' });
    try std.testing.expectEqual(@as(u32, 16), app.automation_cursor_step);
    _ = automation_ed.handleKey(&app, .{ .char = 'b' });
    try std.testing.expectEqual(@as(u32, 0), app.automation_cursor_step);

    // dw: delete exactly the current bar's worth of points (steps 0-15),
    // leaving a point at bar 2 (step 16) untouched.
    app.automation_cursor_step = 16;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 16
    app.automation_cursor_step = 0;
    _ = automation_ed.handleKey(&app, .{ .char = 'j' }); // point at step 0
    try std.testing.expectEqual(@as(usize, 2), clip.automation.gain.len);
    for ("dw") |c| _ = automation_ed.handleKey(&app, .{ .char = c });
    try std.testing.expectEqual(@as(usize, 1), clip.automation.gain.len);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), clip.automation.gain[0].beat, 1e-9); // step 16 = beat 4
}

test "automation editor: tab offers filter cutoff only on a synth track" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();

    // Synth track: tab cycles gain -> pan -> filter_cutoff -> gain.
    try app.session.stampClip(0, 0);
    automation_ed.switchTo(&app, 0, 0);
    try std.testing.expectEqual(engine_mod.AutomationTarget.gain, app.automation_target);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(engine_mod.AutomationTarget.pan, app.automation_target);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(engine_mod.AutomationTarget.filter_cutoff, app.automation_target);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(engine_mod.AutomationTarget.gain, app.automation_target);

    // j nudges the cutoff curve, clamped 20..20_000 like the synth's own param.
    _ = automation_ed.handleKey(&app, .tab); // -> pan
    _ = automation_ed.handleKey(&app, .tab); // -> filter_cutoff
    _ = automation_ed.handleKey(&app, .{ .char = 'j' });
    const synth_clip = automation_ed.currentClip(&app).?;
    try std.testing.expectEqual(@as(usize, 1), synth_clip.automation.filter_cutoff.len);

    // Sampler track: filter_cutoff is skipped entirely — gain <-> pan only.
    try app.session.stampClip(1, 0);
    automation_ed.switchTo(&app, 1, 0);
    try std.testing.expectEqual(engine_mod.AutomationTarget.gain, app.automation_target);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(engine_mod.AutomationTarget.pan, app.automation_target);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(engine_mod.AutomationTarget.gain, app.automation_target);

    // Switching back to the synth clip while target is .gain still offers
    // cutoff again (the fallback in switchTo only fires the other way).
    automation_ed.switchTo(&app, 0, 0);
    _ = automation_ed.handleKey(&app, .tab);
    _ = automation_ed.handleKey(&app, .tab);
    try std.testing.expectEqual(engine_mod.AutomationTarget.filter_cutoff, app.automation_target);
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
    dm.setStepVel(0, 7, 2);
    _ = drum_ed.handleKey(&app, .{ .char = 'y' }); // yy yanks the whole pattern
    _ = drum_ed.handleKey(&app, .{ .char = 'y' });

    // A fresh variant wipes the grid; paste restores the yanked pattern.
    _ = drum_ed.handleKey(&app, .{ .char = 'N' });
    dm.clearPad(0);
    dm.setStepCount(16);
    _ = drum_ed.handleKey(&app, .{ .char = 'P' });
    try std.testing.expect(dm.stepActive(0, 7));
    try std.testing.expectEqual(@as(u2, 2), dm.stepVel(0, 7));
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
    dm.setStepVel(0, 0, 3);
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
    try std.testing.expectEqual(@as(u2, 3), dm.stepVel(0, 8));
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

    // dd/yy are the tier above w/b's bar range: the whole pattern.
    dm.toggleStep(2, 5);
    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(app.drum_clip != null);
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(!dm.stepActive(2, 5));
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

    // ctrl-r is vim's canonical redo key — works the same as 'U'.
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

    // Diverge the live pattern afterwards — the clip keeps its own copy.
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
    // pattern again — no link.
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
    try std.testing.expectEqual(@as(u64, 192_256), app.session.engine.transport.position_frames);
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
    try std.testing.expect(app.session.racks.items[2].instrument.drum_machine.pads[0].pad.pitch_semitones > 0.0);
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
    try std.testing.expect(std.mem.indexOf(u8, frame, "NORMAL") != null);
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

test "transport indicator shows the ascii glyph without the font, the icon with it, never both" {
    var app = try testApp();
    defer app.deinit();
    var buf: [32 * 1024]u8 = undefined;
    defer icons.font_installed = false;

    icons.font_installed = false;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.stop) == null);

    icons.font_installed = true;
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[]") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.stop) != null);

    _ = app.session.engine.send(.play);
    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);

    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "|>") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.play) != null);

    icons.font_installed = false;
    w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "|>") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), icons.play) == null);
}

test "icons.detectFontInstalled reports false when the font isn't in the user's font dir" {
    // testApp()/App.init never call this (it needs a real std.Io, not the
    // std.Io.failing used by the fake IO in tests) — exercise it directly.
    try std.testing.expect(icons.detectFontInstalled(std.testing.io) == false);
}

test "blank track row shows the empty hint" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "empty") != null);
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
    // A fresh chain is empty — the body is the insert hint.
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

    // The analyzer belongs to an EQ unit's editor — insert one and focus it.
    _ = try app.session.racks.items[0].fx.insert(
        app.session.allocator, 0, .eq, app.session.project.sample_rate,
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

test "track add appends a blank track at the end" {
    var app = try testApp();
    defer app.deinit();

    const initial_tracks = app.session.project.tracks.items.len;
    app.doTrackAdd("strings");

    try std.testing.expectEqual(initial_tracks + 1, app.session.project.tracks.items.len);
    try std.testing.expectEqual(initial_tracks + 1, app.session.racks.items.len);
    const last = app.session.racks.items.len - 1;
    try std.testing.expectEqualStrings("strings", app.session.project.tracks.items[last].name);
    try std.testing.expectEqual(InstrumentKind.empty, std.meta.activeTag(app.session.racks.items[last].instrument));
    try std.testing.expectEqual(@as(usize, last), app.cursor);
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
    try std.testing.expectEqual(@as(u32, 3), clip.length_bars);

    // Bad input is rejected and leaves the setting alone.
    for (":sig 3/8") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u8, 3), app.session.project.beats_per_bar);
}

test ":track-add command adds a blank track" {
    var app = try testApp();
    defer app.deinit();

    const before = app.session.project.tracks.items.len;
    for (":track-add mytrack") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(before + 1, app.session.project.tracks.items.len);
    const last = app.session.project.tracks.items.len - 1;
    try std.testing.expectEqualStrings("mytrack", app.session.project.tracks.items[last].name);
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
    try std.testing.expectEqualStrings("track 1", app.session.project.tracks.items[0].name);
    try std.testing.expectEqualStrings("bass", app.session.project.tracks.items[1].name);

    // A single bare number is still a missing-<name> error, not a rename
    // to that numeral — the same lone-index usage that already errored.
    for (":track-rename 3") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("bass", app.session.project.tracks.items[1].name);
}

test ":gain/:pan/:eq with no args at all report the cursor track" {
    // Only the fully-argless form falls back to the cursor track — a single
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

    for (":eq") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(std.mem.indexOf(u8, app.status_buf[0..app.status_len], "track 2") != null);

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

    for (0..16) |_| app.handleKey(.{ .char = 'j' }, 0);
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

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 60 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SYNTH") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "attack") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "sustain") != null);
}

test "synth editor g/G jump to the first/last parameter" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    for (0..10) |_| app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u8, 10), app.synth_cursor);

    app.handleKey(.{ .char = 'g' }, 0);
    try std.testing.expectEqual(@as(u8, 0), app.synth_cursor);
    app.handleKey(.{ .char = 'G' }, 0);
    try std.testing.expectEqual(@as(u8, style.synth_param_count - 1), app.synth_cursor);
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

    app.handleKey(.{ .char = 'a' }, 0); // pitch 60 -> pad 60 % 8 = 4
    try std.testing.expectEqual(ws.input.Mode.insert, app.modal.mode); // still recording

    const dm = &app.session.racks.items[2].instrument.drum_machine;
    const step = dm.currentStep();
    try std.testing.expect(dm.stepActive(4, step));
    // Cursor follows the hit so the grid shows where the take landed.
    try std.testing.expectEqual(@as(u8, 4), app.drum_cursor[0]);
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

    // Pitch 60 maps to pad 4, which the shipped kit's default groove leaves
    // silent (only pads 0/1/2 have a default pattern) — check the whole
    // pad's row stayed empty rather than a single step, so the test doesn't
    // depend on where a stopped transport's playhead happens to sit.
    const dm = &app.session.racks.items[2].instrument.drum_machine;
    var s: u8 = 0;
    while (s < dm.step_count) : (s += 1) try std.testing.expect(!dm.stepActive(4, s));
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
    try std.testing.expect(dm.stepActive(4, step));

    // A second hit on the same (pad, step) while the playhead hasn't moved
    // must not toggle it back off.
    app.handleKey(.{ .char = 'a' }, 0);
    try std.testing.expect(dm.stepActive(4, step));
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
    // previews, no count) — the following motion moves 1, not 5.
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
    try std.testing.expect(lane.clipAt(4) != null);
    try std.testing.expectEqual(@as(u32, 5), app.arr_cursor_bar);

    // Move the pasted clip right two bars with a count; cursor follows.
    app.arr_cursor_bar = 4;
    for ("2>") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expect(lane.clipAt(4) == null);
    try std.testing.expect(lane.clipAt(6) != null);
    try std.testing.expectEqual(@as(u32, 6), app.arr_cursor_bar);

    // Kind guard: the melodic clip won't paste onto the drum lane.
    app.cursor = 2;
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'P' }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.session.arrangement.lane(2).?.clips.items.len);

    // Undo restores the pre-move layout (entry targets lane 0).
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expect(lane.clipAt(4) != null);
    try std.testing.expect(lane.clipAt(6) == null);
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
    app.handleKey(.{ .char = 'l' }, 0); // extend to bar 1 — covers both stamped clips

    app.handleKey(.{ .char = 'y' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.arr_range_clip.?.clips.len);

    const lane = app.session.arrangement.lane(0).?;
    app.arr_cursor_bar = 10;
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'P' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(lane.clipAt(10) != null);
    try std.testing.expect(lane.clipAt(11) != null);
    try std.testing.expect(lane.clipAt(5) != null); // untouched by the paste

    // Select the original range again and delete it.
    app.arr_cursor_bar = 0;
    app.handleKey(.{ .char = 'v' }, 0);
    app.handleKey(.{ .char = 'l' }, 0);
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expect(lane.clipAt(0) == null);
    try std.testing.expect(lane.clipAt(1) == null);
    try std.testing.expect(lane.clipAt(5) != null);
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
    for ("y1l") |c| app.handleKey(.{ .char = c }, 0); // y + motion: yank bars 0-1
    try std.testing.expectEqual(ws.input.Mode.normal, app.modal.mode);
    try std.testing.expectEqual(@as(usize, 2), app.arr_range_clip.?.clips.len);
    try std.testing.expectEqual(@as(u32, 1), app.arr_cursor_bar); // cursor follows the motion

    const lane = app.session.arrangement.lane(0).?;
    app.arr_cursor_bar = 0;
    for ("d1l") |c| app.handleKey(.{ .char = c }, 0); // d + motion: delete bars 0-1
    try std.testing.expect(lane.clipAt(0) == null);
    try std.testing.expect(lane.clipAt(1) == null);
    try std.testing.expect(lane.clipAt(5) != null); // untouched, outside the range

    // dd/yy are the tier above a bar range: the whole lane. x stays the
    // single-clip instant delete (this editor's "char", one bar).
    try app.session.stampClip(0, 0);
    app.arr_cursor_bar = 5;
    app.handleKey(.{ .char = 'x' }, 0);
    try std.testing.expect(lane.clipAt(5) == null);

    for ("yy") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.arr_range_clip.?.clips.len); // just bar 0's clip left
    for ("dd") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(usize, 0), lane.clips.items.len);

    // p/P paste from that same whole-lane yank; cursor jumps past it.
    app.arr_cursor_bar = 10;
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expect(lane.clipAt(10) != null);
    try std.testing.expectEqual(@as(u32, 11), app.arr_cursor_bar);
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
    try std.testing.expectEqual(@as(u32, 1), lane.clipAt(0).?.length_bars);

    // '+' grows the clip by 3 bars (endBar 0+4=4); count-prefixed like '<'/'>'.
    for ("3+") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u32, 4), lane.clipAt(0).?.length_bars);
    // Growth now overlaps and evicts the clip stamped at bar 3.
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try std.testing.expect(lane.clipAt(3) != null);

    // '.' repeats the last resize (another +3 bars) at the cursor.
    app.handleKey(.{ .char = '.' }, 0);
    try std.testing.expectEqual(@as(u32, 7), lane.clipAt(0).?.length_bars);

    // '-' shrinks it back down, clamped to a minimum of 1 bar.
    for ("9-") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u32, 1), lane.clipAt(0).?.length_bars);

    // Undo restores the length from before the shrink.
    app.handleKey(.{ .char = 'u' }, 0);
    try std.testing.expectEqual(@as(u32, 7), lane.clipAt(0).?.length_bars);

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
    app.handleKey(.escape, 0); // drop — stays in the roll
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
    try std.testing.expect(pp.noteAt(61, 1.25) != null); // to step5/pitch61 — same (Δstep,Δpitch)

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
    app.arr_cursor_bar = 10;
    app.handleKey(.{ .char = '.' }, 0); // repeat: delete bars 10-11
    try std.testing.expect(lane.clipAt(10) == null);
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
    for ("2>") |c| app.handleKey(.{ .char = c }, 0); // move the bar-0 clip to bar 2
    const lane = app.session.arrangement.lane(0).?;
    try std.testing.expect(lane.clipAt(2) != null);
    try std.testing.expect(lane.clipAt(0) == null);

    app.arr_cursor_bar = 5;
    app.handleKey(.{ .char = '.' }, 0); // repeat: move the bar-5 clip by +2 too
    try std.testing.expect(lane.clipAt(7) != null);
    try std.testing.expect(lane.clipAt(5) == null);
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
    app.arr_cursor_bar = 1;
    app.handleKey(.{ .char = '(' }, 0);
    app.arr_cursor_bar = 2;
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
    try std.testing.expect(!app.drumMachine().pads[3].pad.user_sample);
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

test ":e Tab completes an unambiguous command name and adds a trailing space" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // "boun" is now ambiguous (bounce / bounce-stems); "expor" still isn't.
    for (":expor") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("export ", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "command Tab-completion hides instrument-scoped commands under the wrong track" {
    var app = try testApp(); // synth(0), sampler(1), drums(2)
    defer app.deinit();

    // Cursor on the synth track: "load-p" (drum-scoped) has no in-scope
    // candidate, so Tab is a no-op — cmd_buf is untouched.
    app.cursor = 0;
    for (":load-p") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("load-p", app.modal.cmd_buf[0..app.modal.cmd_len]);

    // Cursor on the drum track: the same prefix now completes in full.
    app.handleKey(.escape, 0);
    app.cursor = 2;
    for (":load-p") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("load-pad ", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test "Tab cycles through multiple command-name matches instead of stalling at a common prefix" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // "q" matches q / q! / quit / qa / qa! (table order) — Tab steps
    // through all five in turn and wraps back to the first.
    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("q", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("q!", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("quit", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("qa", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("qa!", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("q", app.modal.cmd_buf[0..app.modal.cmd_len]);

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

test "typing after a Tab-cycle starts a fresh cycle instead of continuing the old one" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0); // -> "q"
    app.handleKey(.tab, 0); // -> "q!"
    try std.testing.expectEqualStrings("q!", app.modal.cmd_buf[0..app.modal.cmd_len]);

    // Clearing back to "q" and typing "uit" makes "quit" — an unambiguous
    // command name, so Tab completes it in full (+ trailing space) instead
    // of resuming the stale q!/quit/qa/qa! cycle at its old index.
    app.handleKey(.backspace, 0);
    app.handleKey(.backspace, 0);
    for ("quit") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("quit ", app.modal.cmd_buf[0..app.modal.cmd_len]);
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

    // "a" matches "analog" and "acoustic" (variant-table order) — Tab
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

    // "sub" uniquely matches "sub-bass" — completes in full plus a
    // trailing space, same single-match behavior as command names.
    for (":synth-preset sub") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("synth-preset sub-bass ", app.modal.cmd_buf[0..app.modal.cmd_len]);
}

test ":metronome Tab cycles on/off; :master-comp Tab completes its sub-keywords" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // No argument typed yet — Tab steps between "on" and "off" directly
    // rather than stalling at their shared leading "o".
    for (":metronome ") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("metronome on", app.modal.cmd_buf[0..app.modal.cmd_len]);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("metronome off", app.modal.cmd_buf[0..app.modal.cmd_len]);

    app.modal.cmd_len = 0;
    app.modal.cmd_cursor = 0;
    for ("master-comp thr") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.tab, 0);
    try std.testing.expectEqualStrings("master-comp thresh ", app.modal.cmd_buf[0..app.modal.cmd_len]);
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
/// there — `openBrowser` only needs the directory) so `:e`/`:load-sample`/
/// `:load-pad`'s no-arg browse starts inside the sandbox instead of the repo
/// root.
fn appRootedAt(tmp: *std.testing.TmpDir) !App {
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
    // snare — n/N cycle between the two. (Every name ends in ".wav", so the
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

test ":load-sample/:load-pad with no path browse; refuse first with no matching track" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app = try appRootedAt(&tmp);
    defer app.deinit();

    // Blank track 0: no sampler/drum-machine to receive the load.
    for (":load-sample") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "load-sample: select");

    for (":load-pad 1") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "load-pad: select");

    // With a sampler track selected, :load-sample opens the browser.
    try app.session.setInstrument(0, .sampler);
    for (":load-sample") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.file_browser, app.view);
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
    try std.testing.expectEqual(@as(u32, 2), lane.clips.items[0].start_bar);
    try std.testing.expectEqual(@as(u32, 2), lane.clips.items[0].length_bars); // ceil(5 beats / 4 per bar)
}

test ":e with no path browses when clean, refuses when dirty" {
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

    app.applyAction(.toggle_mute, 0); // dirty
    for (":e") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
    try std.testing.expectStringStartsWith(app.status_buf[0..app.status_len], "unsaved changes");
}

// ---------------------------------------------------------------------------
// Mouse — one representative test per view; each replays the exact row/col
// math its handleMouse (see editors/*.zig) derives from the view's own
// render layout, driven straight through App.handleMouse (bypassing
// terminal.decode, same as handleKey's tests bypass raw byte parsing).
// ---------------------------------------------------------------------------

test "mouse click on a tracks-view row selects and opens it" {
    var app = try testApp();
    defer app.deinit();

    // A real run loop always draws before dispatching input, which is what
    // populates `track_rows_shown` (needed to locate the pinned master row
    // under scrolling — see App.tracksMouse).
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
    // The cursor's lane must actually be on screen — every auto-added
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

    // Pad 0's default groove (kick, 0x1111) has steps 1-3 inactive.
    try std.testing.expect(!app.drumMachine().stepActive(0, 1));
    try std.testing.expect(!app.drumMachine().stepActive(0, 2));
    try std.testing.expect(!app.drumMachine().stepActive(0, 3));

    // row 0 = title, row 1 = step header, row 2 = pad 0. Cell columns (10-char
    // gutter, 1-char "│" every 4 steps, 3-char cells): step1 x in [14,17),
    // step2 x in [17,20), step3 x in [20,23) — see editors/drum.zig's stepAt.
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

    // row 0 = title, row 1 = ruler, row 2 = lane 0. gutter=13, cell_w=4 —
    // bar 0's cell is x in [13,17), bar 2's is x in [21,25).
    const row = app_mod.content_top + 2;
    app.handleMouse(.{ .x = 14, .y = row, .button = .left, .kind = .press }, 80, 24, 0);
    try std.testing.expectEqual(@as(u32, 0), app.arr_drag_bar.?);

    app.handleMouse(.{ .x = 22, .y = row, .button = .left, .kind = .drag }, 80, 24, 0);
    try std.testing.expect(lane.clipAt(0) == null);
    try std.testing.expect(lane.clipAt(2) != null);

    app.handleMouse(.{ .x = 22, .y = row, .button = .left, .kind = .release }, 80, 24, 0);
    try std.testing.expect(app.arr_drag_bar == null);
}

test "mouse scroll over a synth param row selects and nudges it" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.enter, 0); // opens the synth editor for track 0
    try std.testing.expectEqual(AppView.synth_editor, app.view);

    const old_attack = app.session.racks.items[0].instrument.poly_synth.attack_s;

    // paramRow(16) == 21 (attack — see editors/synth.zig); synth_scroll
    // starts at 0, so content row 21 lands on it directly.
    const row = app_mod.content_top + 21;
    app.handleMouse(.{ .x = 20, .y = row, .button = .none, .kind = .scroll_up }, 80, 24, 0);
    try std.testing.expectEqual(@as(u8, 16), app.synth_cursor);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.racks.items[0].instrument.poly_synth.attack_s > old_attack);
}

test "mouse click/drag on a sampler waveform moves the nearer marker" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    app.sampler_target = .{ .drum = 2 };
    app.drum_cursor[0] = 0;
    app.view = .sampler_editor;

    try std.testing.expectEqual(@as(f32, 0.0), app.drumMachine().pads[0].pad.start_norm);
    try std.testing.expectEqual(@as(f32, 1.0), app.drumMachine().pads[0].pad.end_norm);

    // rows=30 gives the waveform its full 8-row cap (rows [1,9)); gutter=2,
    // width=min(cols-2,120)=78 for cols=80. x=10 -> norm ~0.10, nearer the
    // start marker (0.0) than the end (1.0).
    var block: [64]types.Sample = undefined;
    app.handleMouse(.{ .x = 10, .y = app_mod.content_top + 3, .button = .left, .kind = .press }, 80, 30, 0);
    app.session.engine.process(&block);
    try std.testing.expect(app.drumMachine().pads[0].pad.start_norm > 0.0);
    try std.testing.expectEqual(@as(f32, 1.0), app.drumMachine().pads[0].pad.end_norm); // untouched

    app.handleMouse(.{ .x = 20, .y = app_mod.content_top + 3, .button = .left, .kind = .drag }, 80, 30, 0);
    app.session.engine.process(&block);
    try std.testing.expect(app.drumMachine().pads[0].pad.start_norm > 0.1);

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

    // The "+" box sits one slot past the last unit — clicking it opens the
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

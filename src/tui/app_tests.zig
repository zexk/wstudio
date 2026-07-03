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
const piano_ed = @import("editors/piano.zig");
const sampler_ed = @import("editors/sampler.zig");

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

test "cursor movement clamps to track range" {
    var app = try testApp();
    defer app.deinit();

    app.applyAction(.{ .move = .{ .dy = 10 } }, 0);
    try std.testing.expectEqual(@as(usize, 2), app.cursor);
    app.applyAction(.{ .move = .{ .dy = -1 } }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    app.applyAction(.{ .move = .{ .dy = -10 } }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
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
    commands.renderBounce(&app, &buffer);

    var peak: f32 = 0.0;
    for (buffer) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.001);

    try std.testing.expect(!app.session.engine.transport.playing);
    try std.testing.expectEqual(@as(u64, 0), app.session.engine.transport.position_frames);
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

test "piano roll yank/paste moves a pattern across tracks" {
    var app = try testApp();
    defer app.deinit();

    // Track 0 (synth): one note, 8-beat loop. Yank it.
    app.piano_track = 0;
    const src = &app.session.racks.items[0].pattern_player.?;
    src.addNote(.{ .pitch = 72, .start_beat = 1.0, .duration_beat = 0.5 });
    src.length_beats = 8.0;
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

test "drum grid yank/paste carries pattern, velocity, and length" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    const dm = app.drumMachine();

    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.setStepCount(32);
    dm.toggleStep(0, 7);
    dm.setStepVel(0, 7, 2);
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
    try std.testing.expect(app.session.racks.items[2].instrument.drum_machine.pads[0].?.pitch_semitones > 0.0);
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
}

test "blank track row shows the empty hint" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "empty") != null);
}

test ":help opens help view; draw shows command table; esc closes" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":help") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.help, app.view);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
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
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "SPECTRUM") != null);
}

test "draw renders track_spectrum after pressing s" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.{ .char = 's' }, 0);
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "SPECTRUM") != null);
}

test "spectrum fills FFT buffer and draws with real data" {
    var app = try testApp();
    defer app.deinit();

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

    // A 16-step (4-beat) drum pattern now spans 2 bars of 3/4 when stamped.
    try app.session.stampClip(2, 0);
    const clip = app.session.arrangement.lane(2).?.clips.items[0];
    try std.testing.expectEqual(@as(u32, 2), clip.length_bars);

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
    try std.testing.expectEqual(@as(u8, 15), app.drum_cursor[1]); // 16 steps

    // An unused count is discarded by the handled key it preceded ('p'
    // previews, no count) — the following motion moves 1, not 5.
    for ("5p") |c| app.handleKey(.{ .char = c }, 0);
    for ("h") |c| app.handleKey(.{ .char = c }, 0);
    try std.testing.expectEqual(@as(u8, 14), app.drum_cursor[1]);

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

    // Yank, paste at bar 4; the cursor jumps past the pasted clip.
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

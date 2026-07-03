//! Arrangement (song timeline) input: bar/lane cursor, clip stamping and
//! deletion, play-from-cursor, drum-variant cycling, clip editing via the
//! piano roll, and the song/pattern mode toggle. The render half lives in
//! views/arrangement.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const DrumMachine = ws.dsp.DrumMachine;
const App = @import("../app.zig").App;
const history = @import("../history.zig");
const piano = @import("piano.zig");

/// h/l move ±1 bar, H/L ±4 bars (one phrase), j/k change lane (shared
/// `cursor`), enter stamps the live pattern as a clip, x deletes, [/]
/// cycle a drum lane's pattern variant, T toggles song/pattern mode.
/// Returns false for unhandled keys (space, `:`, …) so the transport and
/// command line still work. Scroll is clamped at draw.
pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const lane_count = app.session.project.tracks.items.len;
    switch (key) {
        .escape => { app.view = .tracks; return true; },
        .enter => { stampClip(app); return true; },
        .char => |c| switch (c) {
            // Block insert mode — piano keys would collide with navigation.
            'i' => return true,
            'h' => { moveBar(app, -1); return true; },
            'l' => { moveBar(app, 1); return true; },
            'H' => { moveBar(app, -4); return true; },
            'L' => { moveBar(app, 4); return true; },
            '0' => { app.arr_cursor_bar = 0; return true; },
            'j' => { if (app.cursor + 1 < lane_count) app.cursor += 1; return true; },
            'k' => { if (app.cursor > 0) app.cursor -= 1; return true; },
            'x' => { deleteClip(app); return true; },
            'e' => { editClip(app); return true; },
            'g' => { playFromCursor(app); return true; },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            '[' => { cycleDrumVariant(app, -1); return true; },
            ']' => { cycleDrumVariant(app, 1); return true; },
            'T' => {
                app.session.setSongMode(!app.session.song_mode);
                app.setStatus("{s} mode", .{if (app.session.song_mode) "song" else "pattern"});
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}

fn moveBar(app: *App, delta: i64) void {
    const nb = @as(i64, app.arr_cursor_bar) + delta;
    app.arr_cursor_bar = @intCast(@max(@as(i64, 0), nb));
}

/// Seek the playhead to the cursor bar, starting playback if stopped —
/// audition the song from the point being arranged (same bar math as
/// `:seek`, minus the 1-based parsing).
fn playFromCursor(app: *App) void {
    const sr = @as(f64, @floatFromInt(app.session.project.sample_rate));
    const bpm = @max(app.session.project.tempo_bpm, 1.0);
    const bpb: f64 = @floatFromInt(app.session.project.beats_per_bar);
    const frames_per_bar: u64 = @intFromFloat(sr * 60.0 / bpm * bpb);
    _ = app.session.engine.send(.{ .seek_frames = app.arr_cursor_bar * frames_per_bar });
    if (!app.session.engine.uiSnapshot().playing) _ = app.session.engine.send(.play);
    app.setStatus("play from bar {d}", .{app.arr_cursor_bar + 1});
}

/// On a drum lane, cycle which pattern variant `enter` will stamp. This is
/// the machine's active variant — the same one the drum grid edits and
/// pattern mode plays — so there is only one notion of "selected pattern".
fn cycleDrumVariant(app: *App, delta: i32) void {
    if (app.cursor >= app.session.racks.items.len) return;
    switch (app.session.racks.items[app.cursor].instrument) {
        .drum_machine => |*dm| {
            if (dm.variant_count <= 1) {
                app.setStatus("one pattern — create variants in the drum grid (N)", .{});
                return;
            }
            dm.cycleVariant(delta);
            app.setStatus("pattern {c} ({d}/{d})", .{
                DrumMachine.variantLetter(dm.variant), dm.variant + 1, dm.variant_count,
            });
        },
        else => app.setStatus("not a drum track", .{}),
    }
}

/// Capture the cursor track's live pattern as a clip at the cursor bar,
/// then jump the cursor to the clip's end for quick sequential placing.
fn stampClip(app: *App) void {
    if (app.cursor >= app.session.racks.items.len) return;
    if (std.meta.activeTag(app.session.racks.items[app.cursor].instrument) == .empty) {
        app.setStatus("empty track — insert an instrument first", .{});
        return;
    }
    // Stamping may evict overlapped clips; the lane snapshot covers both.
    history.push(app, history.captureLane(app, @intCast(app.cursor)));
    app.session.stampClip(app.cursor, app.arr_cursor_bar) catch {
        app.setStatus("stamp failed (out of memory)", .{});
        return;
    };
    if (app.session.arrangement.lane(app.cursor)) |lane| {
        if (lane.clipAt(app.arr_cursor_bar)) |clip| {
            switch (clip.content) {
                .drum => |d| app.setStatus("stamped {d}-bar clip (pat {c})", .{
                    clip.length_bars, DrumMachine.variantLetter(d.variant),
                }),
                .melodic => app.setStatus("stamped {d}-bar clip", .{clip.length_bars}),
            }
            app.arr_cursor_bar = clip.endBar();
        }
    }
    // Keep song playback in sync with the edit if it's driving the transport.
    if (app.session.song_mode) app.session.rebuildSongData();
}

/// Open the melodic clip under the cursor in the piano roll, Ableton
/// style: its notes load into the pattern player as a working copy and
/// every edit writes back into the clip itself (piano.syncLinkedClip).
/// The live pattern is replaced by the loaded clip — the clip is the
/// data; the player is just the surface it's edited and played on.
fn editClip(app: *App) void {
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    const clip = lane.clipAt(app.arr_cursor_bar) orelse {
        app.setStatus("no clip here — enter stamps one", .{});
        return;
    };
    switch (clip.content) {
        .melodic => |m| {
            const track: u16 = @intCast(app.cursor);
            if (app.session.racks.items[track].pattern_player == null) return;
            // The load clobbers the working buffer; make it undoable.
            // Captured before the switch so a previous clip link (if the
            // buffer held another clip) is part of the snapshot.
            const pre = history.captureMelodic(app, track);
            piano.switchTo(app, track);
            if (app.view != .piano_roll) {
                if (pre) |p| { var e = p; e.deinit(app.allocator); }
                return;
            }
            history.push(app, pre);
            app.session.racks.items[track].pattern_player.?.setNotes(m.notes, m.length_beats);
            app.piano_clip_link = .{ .track = track, .start_bar = clip.start_bar };
            app.setStatus("editing clip @ bar {d} — edits land in the clip", .{clip.start_bar + 1});
        },
        .drum => app.setStatus("drum clips play the pattern bank — edit variants in the grid", .{}),
    }
}

fn deleteClip(app: *App) void {
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    if (lane.clipAt(app.arr_cursor_bar) == null) {
        app.setStatus("no clip here", .{});
        return;
    }
    history.push(app, history.captureLane(app, @intCast(app.cursor)));
    _ = lane.removeAt(app.allocator, app.arr_cursor_bar);
    app.setStatus("deleted clip", .{});
    if (app.session.song_mode) app.session.rebuildSongData();
}

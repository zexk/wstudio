//! Arrangement (song timeline) input: bar/lane cursor, clip stamping and
//! deletion, play-from-cursor, drum-variant cycling, clip editing via the
//! piano roll, the song/pattern mode toggle, and visual-mode range select
//! (v, then y/d/p — a bar-range on the current lane only). The render half
//! lives in views/arrangement.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const DrumMachine = ws.dsp.DrumMachine;
const App = @import("../app.zig").App;
const history = @import("../history.zig");
const piano = @import("piano.zig");
const automation = @import("automation.zig");
const view = @import("../views/arrangement.zig");

/// h/l move ±1 bar, H/L ±4 bars (one phrase), j/k change lane (shared
/// `cursor`), enter stamps the live pattern as a clip, x deletes, y/p
/// yank/paste a clip, </> shift it by bars, ( ) b set/toggle the A/B
/// loop, [/] cycle a drum lane's pattern variant, T toggles song/pattern
/// mode, v starts a bar-range selection on the current lane, a opens the
/// gain/pan automation editor on the clip under the cursor. Tab (like
/// escape) returns to the tracks view — tracks' own Tab is the mirror,
/// switching into arrangement.
/// Returns false for unhandled keys (space, `:`, …) so the transport and
/// command line still work. Scroll is clamped at draw.
pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const lane_count = app.session.project.tracks.items.len;

    // Visual mode: a bar-range selection on the current lane only (lanes are
    // tracks, and undo snapshots one lane at a time — see captureLane).
    // Motions and range y/d/p live in handleVisual; everything else is
    // swallowed so a stray keypress can't jump views mid-selection.
    if (app.modal.mode == .visual) return handleVisual(app, key, lane_count);

    switch (key) {
        .escape, .tab => { app.view = .tracks; return true; },
        .enter => { stampClip(app); return true; },
        .ctrl_r => { history.doRedo(app); return true; },
        .char => |c| switch (c) {
            // Block insert mode — piano keys would collide with navigation.
            'i' => return true,
            // Motions take a vim count prefix (3l, 2j, …).
            'h' => { moveBar(app, -app.takeCount()); return true; },
            'l' => { moveBar(app, app.takeCount()); return true; },
            'H' => { moveBar(app, -4 * app.takeCount()); return true; },
            'L' => { moveBar(app, 4 * app.takeCount()); return true; },
            '0' => { app.arr_cursor_bar = 0; return true; },
            'j' => { moveLane(app, lane_count, app.takeCount()); return true; },
            'k' => { moveLane(app, lane_count, -app.takeCount()); return true; },
            'x' => { deleteClip(app); return true; },
            'y' => { yankClip(app); return true; },
            'p', 'P' => { pasteClip(app); return true; },
            'v' => {
                app.arr_visual_anchor = app.arr_cursor_bar;
                app.modal.mode = .visual;
                app.setStatus("visual: hjkl extend, y/d/p act on the range, esc cancels", .{});
                return true;
            },
            '<' => { moveClip(app, -app.takeCount()); return true; },
            '>' => { moveClip(app, app.takeCount()); return true; },
            '.' => { repeatLastEdit(app); return true; },
            'e' => { editClip(app); return true; },
            'g' => { playFromCursor(app); return true; },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            '[' => { cycleDrumVariant(app, -1); return true; },
            ']' => { cycleDrumVariant(app, 1); return true; },
            'a' => { automation.switchTo(app, @intCast(app.cursor), app.arr_cursor_bar); return true; },
            '(' => { setLoopStart(app); return true; },
            ')' => { setLoopEnd(app); return true; },
            'b' => { toggleLoop(app); return true; },
            'T' => {
                app.session.setSongMode(!app.session.song_mode);
                app.dirty = true;
                app.setStatus("{s} mode", .{if (app.session.song_mode) "song" else "pattern"});
                return true;
            },
            'Z' => { toggleZoom(app); return true; },
            else => return false,
        },
        else => return false,
    }
}

/// Visual mode's reduced key set: motions extend the selection, y/d/p act
/// on it and return to normal, escape cancels. Everything else is
/// swallowed (returns true) so it can't jump views or open another editor
/// mid-selection; digits fall through (return false) so modal.handleNormal
/// keeps accumulating the count prefix.
fn handleVisual(app: *App, key: modal_mod.Key, lane_count: usize) bool {
    switch (key) {
        .escape => { exitVisual(app); app.setStatus("selection cancelled", .{}); return true; },
        .char => |c| switch (c) {
            'h' => { moveBar(app, -app.takeCount()); return true; },
            'l' => { moveBar(app, app.takeCount()); return true; },
            'H' => { moveBar(app, -4 * app.takeCount()); return true; },
            'L' => { moveBar(app, 4 * app.takeCount()); return true; },
            'j' => { moveLane(app, lane_count, app.takeCount()); return true; },
            'k' => { moveLane(app, lane_count, -app.takeCount()); return true; },
            'y' => { yankSelection(app); return true; },
            'd' => { deleteSelection(app); return true; },
            'p', 'P' => { pasteSelection(app); return true; },
            '0'...'9' => return false,
            else => return true,
        },
        else => return true,
    }
}

/// Leave visual mode, clearing the anchor so the selection can't linger.
fn exitVisual(app: *App) void {
    app.modal.mode = .normal;
    app.modal.count = 0;
    app.modal.pending = null;
    app.arr_visual_anchor = null;
}

const BarRange = struct { lo: u32, hi: u32 };

fn selectionRange(app: *App) BarRange {
    const anchor = app.arr_visual_anchor orelse app.arr_cursor_bar;
    return .{ .lo = @min(anchor, app.arr_cursor_bar), .hi = @max(anchor, app.arr_cursor_bar) };
}

/// Yank every clip on the current lane whose start_bar falls within the
/// selected range, rebased so the range's first bar becomes bar 0.
fn yankSelection(app: *App) void {
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    const r = selectionRange(app);
    var list: std.ArrayListUnmanaged(ws.Clip) = .empty;
    for (lane.clips.items) |c| {
        if (c.start_bar < r.lo or c.start_bar > r.hi) continue;
        var copy = c.dupe(app.allocator) catch {
            for (list.items) |*done| done.deinit(app.allocator);
            list.deinit(app.allocator);
            app.setStatus("yank failed (out of memory)", .{});
            return;
        };
        copy.start_bar -= r.lo;
        list.append(app.allocator, copy) catch {
            copy.deinit(app.allocator);
            for (list.items) |*done| done.deinit(app.allocator);
            list.deinit(app.allocator);
            app.setStatus("yank failed (out of memory)", .{});
            return;
        };
    }
    const owned = list.toOwnedSlice(app.allocator) catch {
        for (list.items) |*c| c.deinit(app.allocator);
        list.deinit(app.allocator);
        app.setStatus("yank failed (out of memory)", .{});
        return;
    };
    if (app.arr_range_clip) |old| {
        for (old.clips) |*c| c.deinit(app.allocator);
        app.allocator.free(old.clips);
    }
    app.arr_range_clip = .{ .clips = owned };
    app.setStatus("yanked {d} clip(s) over {d} bars", .{ owned.len, r.hi - r.lo + 1 });
    exitVisual(app);
}

/// Delete every clip on the current lane whose start_bar falls within the
/// selected range.
fn deleteSelection(app: *App) void {
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    history.push(app, history.captureLane(app, @intCast(app.cursor)));
    const r = selectionRange(app);
    var removed: u32 = 0;
    var i: usize = 0;
    while (i < lane.clips.items.len) {
        if (lane.clips.items[i].start_bar >= r.lo and lane.clips.items[i].start_bar <= r.hi) {
            var c = lane.clips.orderedRemove(i);
            c.deinit(app.allocator);
            removed += 1;
        } else i += 1;
    }
    app.last_edit = .{ .arr_range_delete = .{ .width = r.hi - r.lo + 1 } };
    app.setStatus("deleted {d} clip(s)", .{removed});
    if (app.session.song_mode) app.session.rebuildSongData();
    exitVisual(app);
}

/// Paste the range clipboard onto the current lane starting at the cursor
/// bar, evicting whatever it overlaps (same rule as stamping/pasting a
/// single clip). Skips clips whose kind doesn't match the lane's instrument.
fn pasteSelection(app: *App) void {
    const clip = app.arr_range_clip orelse {
        app.setStatus("nothing yanked — select a range and y first", .{});
        exitVisual(app);
        return;
    };
    if (app.cursor >= app.session.racks.items.len) { exitVisual(app); return; }
    const rack = app.session.racks.items[app.cursor];
    const lane = app.session.arrangement.lane(app.cursor) orelse { exitVisual(app); return; };
    history.push(app, history.captureLane(app, @intCast(app.cursor)));
    var pasted: u32 = 0;
    for (clip.clips) |c| {
        const kind_ok = switch (c.content) {
            .melodic => rack.pattern_player != null,
            .drum => std.meta.activeTag(rack.instrument) == .drum_machine,
        };
        if (!kind_ok) continue;
        var copy = c.dupe(app.allocator) catch continue;
        copy.start_bar += app.arr_cursor_bar;
        lane.place(app.allocator, copy) catch {
            copy.deinit(app.allocator);
            continue;
        };
        pasted += 1;
    }
    app.last_edit = .arr_range_paste;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("pasted {d} clip(s)", .{pasted});
    exitVisual(app);
}

/// `.`: replay the last compound edit (a clip move, or a visual range
/// delete/paste) at the current cursor. No-op ("nothing to repeat") if the
/// last edit came from a different editor or there wasn't one.
fn repeatLastEdit(app: *App) void {
    switch (app.last_edit) {
        .arr_move_clip => |v| moveClip(app, v.delta),
        .arr_range_delete => |v| {
            app.arr_visual_anchor = app.arr_cursor_bar + (v.width - 1);
            deleteSelection(app);
        },
        .arr_range_paste => pasteSelection(app),
        else => app.setStatus("nothing to repeat", .{}),
    }
}

fn moveBar(app: *App, delta: i64) void {
    const nb = @as(i64, app.arr_cursor_bar) + delta;
    app.arr_cursor_bar = @intCast(@max(@as(i64, 0), nb));
}

/// `Z`: toggle horizontal zoom between normal (4 cols/bar) and compact
/// (2 cols/bar) — see `App.arr_zoom`. Purely a render/scroll setting, like
/// the piano roll's `toggleZoom`: no bar indices move.
fn toggleZoom(app: *App) void {
    app.arr_zoom = if (app.arr_zoom == .normal) .compact else .normal;
    app.setStatus("zoom: {s}", .{if (app.arr_zoom == .compact) "compact" else "normal"});
}

/// Move the lane cursor by `delta`, clamped to the track list.
fn moveLane(app: *App, lane_count: usize, delta: i32) void {
    const top = @max(@as(i64, @intCast(lane_count)) - 1, 0);
    app.cursor = @intCast(std.math.clamp(@as(i64, @intCast(app.cursor)) + delta, 0, top));
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
            app.dirty = true;
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

/// A/B loop brace: ( sets the start at the cursor bar. Setting a valid
/// region arms the loop immediately (b toggles it after).
fn setLoopStart(app: *App) void {
    const p = &app.session.project;
    p.loop_start_bar = app.arr_cursor_bar;
    if (p.loop_end_bar > p.loop_start_bar) {
        p.loop_enabled = true;
        app.setStatus("loop: bars {d}–{d}", .{ p.loop_start_bar + 1, p.loop_end_bar });
    } else {
        app.setStatus("loop start: bar {d} — ) sets the end", .{p.loop_start_bar + 1});
    }
    app.dirty = true;
    app.session.syncLoop();
}

/// ) sets the loop end after the cursor bar (the bar is included).
fn setLoopEnd(app: *App) void {
    const p = &app.session.project;
    p.loop_end_bar = app.arr_cursor_bar + 1;
    if (p.loop_end_bar > p.loop_start_bar) {
        p.loop_enabled = true;
        app.setStatus("loop: bars {d}–{d}", .{ p.loop_start_bar + 1, p.loop_end_bar });
    } else {
        app.setStatus("loop end: bar {d} — ( sets the start", .{p.loop_end_bar});
    }
    app.dirty = true;
    app.session.syncLoop();
}

/// b toggles the loop on/off once a region exists.
fn toggleLoop(app: *App) void {
    const p = &app.session.project;
    if (p.loop_end_bar <= p.loop_start_bar) {
        app.setStatus("no loop region — ( and ) set one", .{});
        return;
    }
    p.loop_enabled = !p.loop_enabled;
    if (p.loop_enabled)
        app.setStatus("loop on: bars {d}–{d}", .{ p.loop_start_bar + 1, p.loop_end_bar })
    else
        app.setStatus("loop off", .{});
    app.dirty = true;
    app.session.syncLoop();
}

/// Yank the clip under the cursor into the app-wide clip clipboard.
fn yankClip(app: *App) void {
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    const clip = lane.clipAt(app.arr_cursor_bar) orelse {
        app.setStatus("no clip here — enter stamps one", .{});
        return;
    };
    const copy = clip.dupe(app.allocator) catch {
        app.setStatus("yank failed (out of memory)", .{});
        return;
    };
    if (app.arr_clip) |*old| old.deinit(app.allocator);
    app.arr_clip = copy;
    app.setStatus("yanked {d}-bar clip", .{copy.length_bars});
}

/// Place a copy of the yanked clip at the cursor bar — evicting whatever it
/// overlaps, like stamping — then jump the cursor past it for quick
/// sequential pasting. Clip kind must match the lane's instrument.
fn pasteClip(app: *App) void {
    const src = app.arr_clip orelse {
        app.setStatus("nothing yanked — y copies a clip", .{});
        return;
    };
    if (app.cursor >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.cursor];
    const kind_ok = switch (src.content) {
        .melodic => rack.pattern_player != null,
        .drum    => std.meta.activeTag(rack.instrument) == .drum_machine,
    };
    if (!kind_ok) {
        app.setStatus("clip kind doesn't match this track", .{});
        return;
    }
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    var copy = src.dupe(app.allocator) catch {
        app.setStatus("paste failed (out of memory)", .{});
        return;
    };
    copy.start_bar = app.arr_cursor_bar;
    history.push(app, history.captureLane(app, @intCast(app.cursor)));
    lane.place(app.allocator, copy) catch {
        app.setStatus("paste failed (out of memory)", .{});
        return;
    };
    app.arr_cursor_bar = copy.endBar();
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("pasted {d}-bar clip", .{copy.length_bars});
}

/// Shift the clip under the cursor by `delta` bars (clamped at bar 0). Clips
/// it lands on are evicted — the same overwrite rule as stamping and pasting.
fn moveClip(app: *App, delta: i32) void {
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    const clip = lane.clipAt(app.arr_cursor_bar) orelse {
        app.setStatus("no clip here", .{});
        return;
    };
    const new_start: u32 = @intCast(@max(@as(i64, clip.start_bar) + delta, 0));
    if (new_start == clip.start_bar) return;
    history.push(app, history.captureLane(app, @intCast(app.cursor)));
    app.last_edit = .{ .arr_move_clip = .{ .delta = delta } };
    // Detach the clip (keeping ownership of its content), retarget, re-place.
    var moved: ws.Clip = for (lane.clips.items, 0..) |c, i| {
        if (c.covers(app.arr_cursor_bar)) break lane.clips.orderedRemove(i);
    } else unreachable; // clipAt() above proved a covering clip exists
    moved.start_bar = new_start;
    lane.place(app.allocator, moved) catch {
        app.setStatus("move failed (out of memory)", .{});
        return;
    };
    app.arr_cursor_bar = new_start;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("clip → bar {d}", .{new_start + 1});
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

/// Bar at column `x`, or null if `x` falls in the lane-name gutter. Mirrors
/// views/arrangement.zig's `gutter`/`App.arrCellWidth()` — each bar column
/// is a 1-char separator + content cell (3 chars normal, 1 compact).
fn barAt(scroll_bar: u32, x: usize, cw: usize) ?u32 {
    if (x < view.gutter) return null;
    const col: u32 = @intCast((x - view.gutter) / cw);
    return scroll_bar + col;
}

/// Click a cell to move the (lane, bar) cursor there — no auto-stamp;
/// stamping a clip stays a deliberate `enter`. Press on a cell covered by a
/// clip starts tracking a drag; each motion event feeds the incremental bar
/// delta into the existing `moveClip`. Scroll moves the bar cursor, or —
/// over the lane-name gutter — the lane cursor, regardless of which row the
/// mouse sits on.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16) void {
    _ = cols; // column count is derived from scroll + cell width, not terminal-width-dependent
    const lane_count = app.session.project.tracks.items.len;
    const cw = app.arrCellWidth();

    switch (ev.kind) {
        .scroll_up => { if (ev.x < view.gutter) moveLane(app, lane_count, -1) else moveBar(app, -1); return; },
        .scroll_down => { if (ev.x < view.gutter) moveLane(app, lane_count, 1) else moveBar(app, 1); return; },
        else => {},
    }

    if (row < 2) return; // title / bar-ruler rows — see views/arrangement.zig
    // Offset by the vertical scroll drawArrangement clamped last frame —
    // row 2 is the *first visible* lane, not lane 0, once the lane list
    // scrolls (see App.arr_scroll_lane).
    const lane = app.arr_scroll_lane + (row - 2);
    if (lane >= lane_count) return;

    switch (ev.kind) {
        .press => {
            app.cursor = lane;
            if (barAt(app.arr_scroll_bar, ev.x, cw)) |bar| app.arr_cursor_bar = bar;
            const has_clip = if (app.session.arrangement.lane(lane)) |l|
                l.clipAt(app.arr_cursor_bar) != null
            else
                false;
            app.arr_drag_bar = if (has_clip) app.arr_cursor_bar else null;
        },
        .drag => {
            const last = app.arr_drag_bar orelse return;
            const new_bar = barAt(app.arr_scroll_bar, ev.x, cw) orelse return;
            if (new_bar == last) return;
            // moveClip looks up the clip at the CURRENT cursor bar and
            // leaves the cursor on wherever it lands.
            app.arr_cursor_bar = last;
            const delta: i32 = @as(i32, @intCast(new_bar)) - @as(i32, @intCast(last));
            moveClip(app, delta);
            app.arr_drag_bar = app.arr_cursor_bar;
        },
        .release => app.arr_drag_bar = null,
        else => {},
    }
}

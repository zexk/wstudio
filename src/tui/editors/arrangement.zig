//! Arrangement (song timeline) input: bar/lane cursor, clip stamping and
//! deletion, play-from-cursor, drum-variant cycling, clip editing via the
//! piano roll, the song/pattern mode toggle, visual-mode range select
//! (v, then y/d/p — a bar-range on the current lane only), and operator+
//! motion grammar (x/d/y — a bar is already this editor's atomic unit, so
//! dd/yy are the tier above it: the whole lane; see the operator-pending
//! block below). The render half lives in views/arrangement.zig.

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
/// `cursor`), enter stamps the live pattern as a clip, x deletes the clip
/// under the cursor, d/y are operators (dd/yy act on the whole lane, d/y +
/// h/l/H/L act on a bar range), p pastes, </> shift a clip by bars, +/-
/// edge-resize a clip's length by bars (its content loops to fill whatever
/// span it's given), ( ) b set/toggle the A/B
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

    // Operator-pending mode: `d`/`y` arm here (armOperator below), then
    // h/l/H/L act on the bar range from the arming point (current lane
    // only) — no j/k here, same lane-only restriction visual mode's own
    // range select has. Vim's char/word/line hierarchy collapses a tier in
    // this editor: a bar already IS the atomic unit (`x` deletes one, h/l
    // already move one at a time — there's no finer grain to distinguish
    // "char" from "word" here), so the same operator key again (dd/yy)
    // clears/yanks the entire lane, the tier above a bar. Anything else
    // cancels.
    if (app.arr_op_pending) |op| {
        app.arr_op_pending = null;
        switch (key) {
            .escape => { app.arr_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            .char => |c| switch (c) {
                '0'...'9' => { app.arr_op_pending = op; return false; },
                'd', 'y' => {
                    if (c == op) {
                        if (op == 'd') clearLane(app) else yankWholeLane(app);
                    } else app.setStatus("cancelled", .{});
                    return true;
                },
                'h' => { moveBar(app, -app.takeCount()); finishOperator(app, op); return true; },
                'l' => { moveBar(app, app.takeCount()); finishOperator(app, op); return true; },
                'H' => { moveBar(app, -4 * app.takeCount()); finishOperator(app, op); return true; },
                'L' => { moveBar(app, 4 * app.takeCount()); finishOperator(app, op); return true; },
                else => { app.arr_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            },
            else => { app.arr_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
        }
    }

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
            // x: vim's char-delete — the clip under the cursor, instantly,
            // no operator needed (a bar is already this editor's atomic
            // unit; see the operator-pending block above).
            'x' => { deleteClip(app); return true; },
            // y is an operator (see armOperator) — yy yanks every clip on
            // the lane, y + a motion yanks the bar range it covers.
            'y' => { armOperator(app, 'y'); return true; },
            // d is likewise an operator; dd clears every clip on the lane,
            // d + a motion (h/l/H/L) deletes the range.
            'd' => { armOperator(app, 'd'); return true; },
            // p/P paste the range clipboard at the cursor bar — the same
            // clipboard yy/y+motion fill, since a single clip is just a
            // 1-bar range (see pasteSelection).
            'p', 'P' => { pasteSelection(app); return true; },
            'v' => {
                app.arr_visual_anchor = app.arr_cursor_bar;
                app.modal.mode = .visual;
                app.setStatus("visual: hjkl extend, y/d/p act on the range, esc cancels", .{});
                return true;
            },
            '<' => { moveClip(app, -app.takeCount()); return true; },
            '>' => { moveClip(app, app.takeCount()); return true; },
            '-' => { resizeClip(app, -app.takeCount()); return true; },
            '+' => { resizeClip(app, app.takeCount()); return true; },
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

/// Arm `d`/`y` as a pending operator (see the operator-pending block in
/// handleKey): remembers the cursor bar as the range anchor, same field
/// visual mode's `v` sets, so the eventual delete/yank reuses
/// selectionRange as-is.
fn armOperator(app: *App, op: u8) void {
    app.arr_visual_anchor = app.arr_cursor_bar;
    app.arr_op_pending = op;
    app.setStatus("{c}: h/l/H/L act on the range, {c}{c} acts on the whole lane", .{ op, op, op });
}

/// Complete an operator+motion: run the range delete/yank between the
/// anchor `armOperator` set and the cursor's new position.
fn finishOperator(app: *App, op: u8) void {
    if (op == 'd') deleteSelection(app) else yankSelection(app);
}

/// `dd`/`yy`'s whole-lane range: bar 0 through the last clip's end (the
/// widest range that's guaranteed to catch every clip's start_bar, which is
/// what deleteSelection/yankSelection actually filter on). Saves and
/// restores `arr_cursor_bar` around the call so clearing/yanking the whole
/// lane doesn't otherwise move the cursor, like vim's dd/yy don't jump far.
fn wholeLaneRange(app: *App, lane: *ws.arrangement.Lane, act: *const fn (*App) void) void {
    var hi: u32 = 0;
    for (lane.clips.items) |c| hi = @max(hi, c.endBar() -| 1);
    const saved_cursor = app.arr_cursor_bar;
    app.arr_visual_anchor = 0;
    app.arr_cursor_bar = hi;
    act(app);
    app.arr_cursor_bar = saved_cursor;
}

/// `dd`: clear every clip on the current lane — vim's whole-line dd, one
/// tier coarser than x's single-clip delete and h/l's bar range.
fn clearLane(app: *App) void {
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    if (lane.clips.items.len == 0) { app.setStatus("lane already empty", .{}); return; }
    wholeLaneRange(app, lane, deleteSelection);
}

/// `yy`: yank every clip on the current lane (the tier above a single
/// clip's `y`+motion range).
fn yankWholeLane(app: *App) void {
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    if (lane.clips.items.len == 0) { app.setStatus("lane is empty", .{}); return; }
    wholeLaneRange(app, lane, yankSelection);
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
/// single clip). Skips clips whose kind doesn't match the lane's
/// instrument. Also the normal-mode `p`/`P` handler — a single clip is just
/// a 1-bar range, so there's no separate single-clip paste path anymore.
/// Jumps the cursor past the rightmost pasted clip for quick sequential
/// pasting (leaves it alone if nothing was actually pasted).
fn pasteSelection(app: *App) void {
    const clip = app.arr_range_clip orelse {
        app.setStatus("nothing yanked — select a range and y first", .{});
        exitVisual(app);
        return;
    };
    if (app.cursor >= app.session.racks.items.len) { exitVisual(app); return; }
    const rack = app.session.racks.items[app.cursor];
    const lane = app.session.arrangement.lane(app.cursor) orelse { exitVisual(app); return; };
    const kind_ok = struct {
        fn check(r: @TypeOf(rack), c: ws.Clip) bool {
            return switch (c.content) {
                .melodic => r.pattern_player != null,
                .drum => std.meta.activeTag(r.instrument) == .drum_machine,
            };
        }
    }.check;
    // Skip pushing history (and touching the lane) entirely if nothing in
    // the clipboard actually matches this lane's instrument — matching the
    // old single-clip paste's behavior of leaving undo history untouched
    // on a kind mismatch, rather than recording a no-op entry.
    const any_kind_ok = for (clip.clips) |c| { if (kind_ok(rack, c)) break true; } else false;
    if (!any_kind_ok) {
        app.setStatus("clip kind doesn't match this track", .{});
        exitVisual(app);
        return;
    }
    history.push(app, history.captureLane(app, @intCast(app.cursor)));
    var pasted: u32 = 0;
    var end_bar = app.arr_cursor_bar;
    for (clip.clips) |c| {
        if (!kind_ok(rack, c)) continue;
        var copy = c.dupe(app.allocator) catch continue;
        copy.start_bar += app.arr_cursor_bar;
        end_bar = @max(end_bar, copy.endBar());
        lane.place(app.allocator, copy) catch {
            copy.deinit(app.allocator);
            continue;
        };
        pasted += 1;
    }
    if (pasted > 0) app.arr_cursor_bar = end_bar;
    app.last_edit = .arr_range_paste;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("pasted {d} clip(s)", .{pasted});
    exitVisual(app);
}

/// `.`: replay the last compound edit (a clip move, a clip resize, or a
/// visual range delete/paste) at the current cursor. No-op ("nothing to
/// repeat") if the last edit came from a different editor or there wasn't
/// one.
fn repeatLastEdit(app: *App) void {
    switch (app.last_edit) {
        .arr_move_clip => |v| moveClip(app, v.delta),
        .arr_resize_clip => |v| resizeClip(app, v.delta),
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

/// `+`/`-`: edge-resize the clip under the cursor by `delta` bars (count-
/// scaled, like `<`/`>`), clamped to a minimum of 1 bar. Growing evicts
/// whatever clips the new span now overlaps — the same eviction rule
/// `moveClip`/stamp/paste already follow. A clip's own content loops to fill
/// whatever span it's given (Session.rebuildSongData for melodic clips,
/// DrumMachine.fireSongStep for drum clips), so growing a short pattern is
/// exactly how it repeats across a longer phrase.
fn resizeClip(app: *App, delta: i32) void {
    const lane = app.session.arrangement.lane(app.cursor) orelse return;
    const clip = lane.clipAt(app.arr_cursor_bar) orelse {
        app.setStatus("no clip here", .{});
        return;
    };
    const new_len: u32 = @intCast(@max(@as(i64, clip.length_bars) + delta, 1));
    if (new_len == clip.length_bars) return;
    history.push(app, history.captureLane(app, @intCast(app.cursor)));
    app.last_edit = .{ .arr_resize_clip = .{ .delta = delta } };
    var resized: ws.Clip = for (lane.clips.items, 0..) |c, i| {
        if (c.covers(app.arr_cursor_bar)) break lane.clips.orderedRemove(i);
    } else unreachable; // clipAt() above proved a covering clip exists
    resized.length_bars = new_len;
    lane.place(app.allocator, resized) catch {
        app.setStatus("resize failed (out of memory)", .{});
        return;
    };
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("clip length → {d} bar(s)", .{new_len});
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

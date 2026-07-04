//! Per-clip gain/pan automation editor: a breakpoint grid, vim-style.
//!
//! The cursor moves along the clip's own beat axis in 16th-note steps (the
//! same unit the piano roll/drum grid use — beat = step / 4.0). h/l move it;
//! j/k nudge the value at the cursor's exact beat, creating a point there if
//! none exists yet (starting from whatever the curve currently interpolates
//! to, so a nudge on a bare stretch doesn't jump to an arbitrary default);
//! x deletes the point at the cursor exactly; tab switches between editing
//! the gain and pan curves; v starts a step-range selection on the current
//! curve — y/d/P act on it (breakpoints only, not the interpolated curve
//! shape in between); `.` repeats the last nudge or visual range op. Same
//! shapes as the piano roll's visual mode/`.` repeat, one axis instead of
//! two. The render half lives in views/automation.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const automation_mod = ws.dsp.automation;
const AutomationPoint = automation_mod.AutomationPoint;
const engine_mod = ws.engine;
const App = @import("../app.zig").App;
const history = @import("../history.zig");
const view = @import("../views/automation.zig");

/// Gain (dB, matches `:gain`/`Track.gain_db`) and pan (-1..1, matches
/// `Track.pan`) ranges — same clamps `persist.zig`'s loader enforces.
const gain_range = [2]f32{ -60.0, 12.0 };
const pan_range = [2]f32{ -1.0, 1.0 };
const gain_step: f32 = 1.0;
const pan_step: f32 = 0.05;

/// Open the automation editor on the clip under the arrangement cursor.
/// `cursor_bar` need only fall inside the clip's span — the link is stored
/// against the clip's own `start_bar` (see `App.automation_clip`'s doc
/// comment), matching `piano_clip_link`'s convention.
pub fn switchTo(app: *App, track: u16, cursor_bar: u32) void {
    const lane = app.session.arrangement.lane(track) orelse return;
    const clip = lane.clipAt(cursor_bar) orelse {
        app.setStatus("no clip here — enter stamps one, then 'a' automates it", .{});
        return;
    };
    app.automation_clip = .{ .track = track, .start_bar = clip.start_bar };
    app.automation_track = track;
    app.automation_cursor_step = 0;
    app.automation_scroll = 0;
    app.view = .automation;
}

/// Resolve `app.automation_clip` to a live pointer, relocating by (track,
/// start_bar) since clip storage can move as the lane is edited. Null if the
/// clip vanished from under the editor (deleted, moved) — `App.exitStaleEditors`
/// bounces the view back to arrangement in that case.
pub fn currentClip(app: *App) ?*ws.Clip {
    const link = app.automation_clip orelse return null;
    const lane = app.session.arrangement.lane(link.track) orelse return null;
    return lane.clipAt(link.start_bar);
}

fn stepsPerBar(app: *App) u32 {
    return @as(u32, app.session.project.beats_per_bar) * 4;
}

/// Last valid cursor step: the clip's own end, inclusive — lets a fade
/// resolve exactly at the clip's last instant, not one step short of it.
fn maxStep(app: *App, clip: *const ws.Clip) u32 {
    return clip.length_bars * stepsPerBar(app);
}

fn curvePoints(clip: *ws.Clip, target: engine_mod.AutomationTarget) *[]AutomationPoint {
    return switch (target) {
        .gain => &clip.automation.gain,
        .pan => &clip.automation.pan,
    };
}

fn curveRange(target: engine_mod.AutomationTarget) [2]f32 {
    return switch (target) {
        .gain => gain_range,
        .pan => pan_range,
    };
}

fn curveStep(target: engine_mod.AutomationTarget) f32 {
    return switch (target) {
        .gain => gain_step,
        .pan => pan_step,
    };
}

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const clip = currentClip(app) orelse return false;

    // Visual mode: a step-range selection on the currently-edited curve.
    // Motions and range y/d/P live in handleVisual; everything else is
    // swallowed so a stray keypress can't jump views or switch curves
    // mid-selection.
    if (app.modal.mode == .visual) return handleVisual(app, key, clip);

    switch (key) {
        .escape => { app.view = .arrangement; return true; },
        .tab => {
            app.automation_target = if (app.automation_target == .gain) .pan else .gain;
            return true;
        },
        .char => |c| switch (c) {
            'h' => { moveCursor(app, clip, -app.takeCount()); return true; },
            'l' => { moveCursor(app, clip, app.takeCount()); return true; },
            'H' => { moveCursor(app, clip, -4 * app.takeCount()); return true; },
            'L' => { moveCursor(app, clip, 4 * app.takeCount()); return true; },
            'j' => { nudgeValue(app, clip, -app.takeCount()); return true; },
            'k' => { nudgeValue(app, clip, app.takeCount()); return true; },
            'J' => { nudgeValue(app, clip, -10 * app.takeCount()); return true; },
            'K' => { nudgeValue(app, clip, 10 * app.takeCount()); return true; },
            'x' => { deletePoint(app, clip); return true; },
            'v' => {
                app.automation_visual_anchor = app.automation_cursor_step;
                app.modal.mode = .visual;
                app.setStatus("visual: hjkl extend, y/d/P act on the range, esc cancels", .{});
                return true;
            },
            '.' => { repeatLastEdit(app, clip); return true; },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            else => return false,
        },
        else => return false,
    }
}

/// Visual mode's reduced key set: motions extend the selection, y/d/P act
/// on it and return to normal, escape cancels. Everything else is
/// swallowed (returns true) so it can't jump views or switch curves
/// mid-selection; digits fall through (return false) so modal.handleNormal
/// keeps accumulating the count prefix.
fn handleVisual(app: *App, key: modal_mod.Key, clip: *ws.Clip) bool {
    switch (key) {
        .escape => { exitVisual(app); app.setStatus("selection cancelled", .{}); return true; },
        .char => |c| switch (c) {
            'h' => { moveCursor(app, clip, -app.takeCount()); return true; },
            'l' => { moveCursor(app, clip, app.takeCount()); return true; },
            'H' => { moveCursor(app, clip, -4 * app.takeCount()); return true; },
            'L' => { moveCursor(app, clip, 4 * app.takeCount()); return true; },
            'y' => { yankSelection(app, clip); return true; },
            'd' => { deleteSelection(app, clip); return true; },
            'P' => { pasteSelection(app, clip); return true; },
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
    app.automation_visual_anchor = null;
}

const StepRange = struct { lo: u32, hi: u32 };

fn selectionRange(app: *App) StepRange {
    const anchor = app.automation_visual_anchor orelse app.automation_cursor_step;
    return .{ .lo = @min(anchor, app.automation_cursor_step), .hi = @max(anchor, app.automation_cursor_step) };
}

/// Yank every breakpoint on the current curve whose beat falls within the
/// selected step range, rebased so the range's first step becomes beat 0.
fn yankSelection(app: *App, clip: *ws.Clip) void {
    const r = selectionRange(app);
    const lo_beat = @as(f64, @floatFromInt(r.lo)) * 0.25;
    const hi_beat = @as(f64, @floatFromInt(r.hi)) * 0.25 + 0.25;
    const points = curvePoints(clip, app.automation_target).*;
    var list: std.ArrayListUnmanaged(AutomationPoint) = .empty;
    for (points) |p| {
        if (p.beat < lo_beat or p.beat >= hi_beat) continue;
        list.append(app.allocator, .{ .beat = p.beat - lo_beat, .value = p.value }) catch {
            list.deinit(app.allocator);
            app.setStatus("yank failed (out of memory)", .{});
            return;
        };
    }
    const owned = list.toOwnedSlice(app.allocator) catch {
        list.deinit(app.allocator);
        app.setStatus("yank failed (out of memory)", .{});
        return;
    };
    if (app.automation_range_clip) |old| app.allocator.free(old.points);
    app.automation_range_clip = .{ .points = owned };
    app.setStatus("yanked {d} point(s) ({d} steps)", .{ owned.len, r.hi - r.lo + 1 });
    exitVisual(app);
}

/// Delete every breakpoint on the current curve whose beat falls within the
/// selected step range.
fn deleteSelection(app: *App, clip: *ws.Clip) void {
    const r = selectionRange(app);
    const lo_beat = @as(f64, @floatFromInt(r.lo)) * 0.25;
    const hi_beat = @as(f64, @floatFromInt(r.hi)) * 0.25 + 0.25;
    history.push(app, history.captureLane(app, app.automation_track));
    const points = curvePoints(clip, app.automation_target);
    var removed: usize = 0;
    var i: usize = 0;
    while (i < points.len) {
        if (points.*[i].beat >= lo_beat and points.*[i].beat < hi_beat) {
            _ = automation_mod.removePoint(app.allocator, points, points.*[i].beat);
            removed += 1;
        } else i += 1;
    }
    app.last_edit = .{ .automation_range_delete = .{ .width = r.hi - r.lo + 1 } };
    app.setStatus("deleted {d} point(s)", .{removed});
    if (app.session.song_mode) app.session.rebuildSongData();
    exitVisual(app);
}

/// Paste the range clipboard's breakpoints onto the curve active *now*
/// (`automation_target`, which may differ from the one yanked if `tab` was
/// pressed since), starting at the cursor step.
fn pasteSelection(app: *App, clip: *ws.Clip) void {
    const rc = app.automation_range_clip orelse {
        app.setStatus("nothing yanked — select a range and y first", .{});
        exitVisual(app);
        return;
    };
    history.push(app, history.captureLane(app, app.automation_track));
    const points = curvePoints(clip, app.automation_target);
    const base_beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;
    const max_beat: f64 = @as(f64, @floatFromInt(maxStep(app, clip))) * 0.25;
    for (rc.points) |p| {
        const beat = std.math.clamp(base_beat + p.beat, 0, max_beat);
        automation_mod.setPoint(app.allocator, points, beat, p.value) catch {
            app.setStatus("paste failed (out of memory)", .{});
            return;
        };
    }
    app.last_edit = .automation_range_paste;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("pasted {d} point(s)", .{rc.points.len});
    exitVisual(app);
}

/// `.`: replay the last nudge or visual range delete/paste at the current
/// cursor. No-op ("nothing to repeat") if the last edit came from a
/// different editor or there wasn't one.
fn repeatLastEdit(app: *App, clip: *ws.Clip) void {
    switch (app.last_edit) {
        .automation_nudge => |v| nudgeValue(app, clip, v.delta),
        .automation_range_delete => |v| {
            app.automation_visual_anchor = app.automation_cursor_step + (v.width - 1);
            deleteSelection(app, clip);
        },
        .automation_range_paste => pasteSelection(app, clip),
        else => app.setStatus("nothing to repeat", .{}),
    }
}

/// The step under screen column `x`, or null if `x` falls in the left
/// gutter or past the clip's own end. Shared logic for click and scroll.
fn stepAt(app: *App, clip: *const ws.Clip, x: u16) ?u32 {
    const g: u32 = @intCast(view.gutter);
    if (x < g) return null;
    const step = app.automation_scroll + (@as(u32, x) - g);
    if (step > maxStep(app, clip)) return null;
    return step;
}

/// Row 0 is the title; any row below it (ruler, bar graph, or caret) picks a
/// column the same way — clicking the ruler works just as well as clicking
/// the bars. Click moves the cursor there; scroll moves it and nudges the
/// value (matching the synth editor's scroll convention — ctrl = coarse).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize) void {
    const clip = currentClip(app) orelse return;
    if (row == 0) return;
    switch (ev.kind) {
        .press => {
            if (stepAt(app, clip, ev.x)) |step| app.automation_cursor_step = step;
        },
        .scroll_up, .scroll_down => {
            const step = stepAt(app, clip, ev.x) orelse return;
            app.automation_cursor_step = step;
            const dir: i32 = if (ev.kind == .scroll_up) 1 else -1;
            nudgeValue(app, clip, dir * (if (ev.ctrl) @as(i32, 10) else 1));
        },
        else => {},
    }
}

fn moveCursor(app: *App, clip: *const ws.Clip, delta: i32) void {
    const max_step: i64 = maxStep(app, clip);
    const cur: i64 = @as(i64, app.automation_cursor_step) + delta;
    app.automation_cursor_step = @intCast(std.math.clamp(cur, 0, max_step));
}

/// Nudge the curve's value at the cursor's exact beat by `steps`, creating a
/// point there if none exists — starting from whatever the curve currently
/// interpolates to at that beat (0 if the curve is empty), so the first nudge
/// on a bare stretch moves relative to what's already playing, not an
/// arbitrary default.
fn nudgeValue(app: *App, clip: *ws.Clip, steps: i32) void {
    if (steps == 0) return;
    const target = app.automation_target;
    const beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;
    const points = curvePoints(clip, target);
    const range = curveRange(target);
    const cur = automation_mod.interpolate(points.*, beat) orelse 0.0;
    const new_val = std.math.clamp(
        cur + @as(f32, @floatFromInt(steps)) * curveStep(target),
        range[0], range[1],
    );
    // Captured before the mutation — the whole lane, same granularity the
    // arrangement's own clip edits (move/delete) undo at.
    history.push(app, history.captureLane(app, app.automation_track));
    automation_mod.setPoint(app.allocator, points, beat, new_val) catch {
        app.setStatus("automation edit failed (out of memory)", .{});
        return;
    };
    app.last_edit = .{ .automation_nudge = .{ .delta = steps } };
    if (app.session.song_mode) app.session.rebuildSongData();
}

fn deletePoint(app: *App, clip: *ws.Clip) void {
    const target = app.automation_target;
    const beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;
    const points = curvePoints(clip, target);
    if (!hasPointAt(points.*, beat)) {
        app.setStatus("no point exactly here", .{});
        return;
    }
    history.push(app, history.captureLane(app, app.automation_track));
    _ = automation_mod.removePoint(app.allocator, points, beat);
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("point removed", .{});
}

fn hasPointAt(points: []const AutomationPoint, beat: f64) bool {
    for (points) |p| {
        if (@abs(p.beat - beat) < 1e-9) return true;
    }
    return false;
}

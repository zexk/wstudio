//! Per-clip gain/pan automation editor: a breakpoint grid, vim-style.
//!
//! The cursor moves along the clip's own beat axis in 16th-note steps (the
//! same unit the piano roll/drum grid use — beat = step / 4.0). h/l move it;
//! j/k nudge the value at the cursor's exact beat, creating a point there if
//! none exists yet (starting from whatever the curve currently interpolates
//! to, so a nudge on a bare stretch doesn't jump to an arbitrary default);
//! x deletes the point at the cursor exactly; tab switches between editing
//! the gain and pan curves. The render half lives in views/automation.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const automation_mod = ws.dsp.automation;
const AutomationPoint = automation_mod.AutomationPoint;
const engine_mod = ws.engine;
const App = @import("../app.zig").App;

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
            else => return false,
        },
        else => return false,
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
    automation_mod.setPoint(app.allocator, points, beat, new_val) catch {
        app.setStatus("automation edit failed (out of memory)", .{});
        return;
    };
    app.dirty = true;
    if (app.session.song_mode) app.session.rebuildSongData();
}

fn deletePoint(app: *App, clip: *ws.Clip) void {
    const target = app.automation_target;
    const beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;
    const points = curvePoints(clip, target);
    if (automation_mod.removePoint(app.allocator, points, beat)) {
        app.dirty = true;
        if (app.session.song_mode) app.session.rebuildSongData();
        app.setStatus("point removed", .{});
    } else {
        app.setStatus("no point exactly here", .{});
    }
}

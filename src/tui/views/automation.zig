//! Per-clip gain/pan automation view + its status bar. The input half lives
//! in editors/automation.zig.

const std = @import("std");
const ws = @import("wstudio");
const engine_mod = ws.engine;
const automation_mod = ws.dsp.automation;
const AutomationPoint = automation_mod.AutomationPoint;
const cmd_mod = @import("../cmd.zig");
const style = @import("../style.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const sel = style.sel;
const blu = style.blu;
const yel = style.yel;
const endLine = style.endLine;

// Lower-eighths block glyphs, shortest to tallest — same idea as
// views/spectrum.zig's `eq_glyphs`, generalised to an arbitrary [lo, hi].
const level_glyphs = [_][]const u8{
    "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
    "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}",
};

fn valueGlyph(val: ?f32, range: [2]f32) []const u8 {
    const v = val orelse return level_glyphs[0];
    const norm = std.math.clamp((v - range[0]) / (range[1] - range[0]), 0.0, 1.0);
    const lvl: usize = @intFromFloat(@round(norm * @as(f32, @floatFromInt(level_glyphs.len - 1))));
    return level_glyphs[@min(lvl, level_glyphs.len - 1)];
}

/// Left indent before the step columns start — shared with
/// editors/automation.zig's mouse handler so a click/scroll's column maps to
/// the same step the bar graph/caret row actually draw it at.
pub const gutter: usize = 3;

fn hasPointAt(points: []const AutomationPoint, beat: f64) bool {
    for (points) |p| {
        if (@abs(p.beat - beat) < 1e-9) return true;
    }
    return false;
}

/// Resolve the clip the view (and editors/automation.zig) are both bound to.
/// Duplicated here rather than imported (see tui.zig's doc comment: view
/// renderers take `app: anytype` and never import app.zig, so they can't
/// share a helper typed against the concrete `*App`).
fn currentClip(app: anytype) ?*const ws.Clip {
    const link = app.automation_clip orelse return null;
    const lane = app.session.arrangement.lane(link.track) orelse return null;
    return lane.clipAt(link.start_bar);
}

fn curveRange(target: engine_mod.AutomationTarget) [2]f32 {
    return switch (target) {
        .gain => .{ -40.0, 12.0 }, // wider than the persisted -60 floor — a
        // fade all the way to -60dB would otherwise pin the whole graph flat
        .pan => .{ -1.0, 1.0 },
    };
}

fn curvePoints(clip: *const ws.Clip, target: engine_mod.AutomationTarget) []const AutomationPoint {
    return switch (target) {
        .gain => clip.automation.gain,
        .pan => clip.automation.pan,
    };
}

pub fn drawAutomation(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
) !void {
    _ = snap;
    const clip = currentClip(app) orelse {
        try w.writeAll(bold ++ " AUTOMATION" ++ rst ++ dim ++ "  clip gone — esc" ++ rst);
        try endLine(w);
        for (1..@max(1, rows -| 3)) |_| try endLine(w);
        return;
    };

    const track_name = if (app.automation_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.automation_track].name
    else
        "?";
    const target = app.automation_target;
    const target_label: []const u8 = if (target == .gain) "GAIN" else "PAN";

    try w.writeAll(bold ++ " AUTOMATION" ++ rst);
    try w.print("  \"{s}\"", .{track_name});
    try w.writeAll(dim ++ "  clip " ++ rst);
    try w.print("{d}\u{2192}{d}", .{ clip.start_bar + 1, clip.endBar() });
    try w.writeAll(dim ++ "  " ++ rst ++ acc ++ bold);
    try w.print(" {s} ", .{target_label});
    try w.writeAll(rst ++ dim ++ " (tab: switch curve)" ++ rst);
    try endLine(w);

    const bpb = app.session.project.beats_per_bar;
    const steps_per_bar: u32 = @as(u32, bpb) * 4;
    const total_steps = clip.length_bars * steps_per_bar;
    const visible: u32 = @intCast(@max(1, cols -| gutter));

    if (app.automation_cursor_step < app.automation_scroll) app.automation_scroll = app.automation_cursor_step;
    if (app.automation_cursor_step >= app.automation_scroll + visible)
        app.automation_scroll = app.automation_cursor_step - visible + 1;
    const scroll = app.automation_scroll;

    const points = curvePoints(clip, target);
    const range = curveRange(target);

    // Visual-mode selection: a step range on the current curve only.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.automation_visual_anchor orelse app.automation_cursor_step;
    const sel_lo: u32 = @min(sel_anchor, app.automation_cursor_step);
    const sel_hi: u32 = @max(sel_anchor, app.automation_cursor_step);

    // Ruler: bar boundaries.
    try w.writeAll(dim ++ "   " ++ rst);
    var col: u32 = 0;
    while (col < visible and scroll + col <= total_steps) : (col += 1) {
        const step = scroll + col;
        try w.writeAll(if (step % steps_per_bar == 0) blu ++ "|" ++ rst else " ");
    }
    try endLine(w);

    // Bar graph: one glyph per step. Explicit points are bold+accent,
    // interpolated-only steps are dim, the cursor is reverse-video, a
    // visual-mode selection tints its range yellow (matching the piano
    // roll's `in_sel` convention).
    try w.writeAll("   ");
    col = 0;
    while (col < visible and scroll + col <= total_steps) : (col += 1) {
        const step = scroll + col;
        const beat = @as(f64, @floatFromInt(step)) * 0.25;
        const is_cursor = step == app.automation_cursor_step;
        const is_point = hasPointAt(points, beat);
        const in_sel = visual_active and step >= sel_lo and step <= sel_hi;
        const val = automation_mod.interpolate(points, beat);
        if (is_cursor) {
            try w.writeAll(sel);
        } else if (is_point) {
            try w.writeAll(bold);
            try w.writeAll(if (in_sel) yel else acc);
        } else if (in_sel) {
            try w.writeAll(yel);
        } else {
            try w.writeAll(dim);
        }
        try w.writeAll(valueGlyph(val, range));
        if (is_cursor or is_point or in_sel) try w.writeAll(rst);
    }
    try endLine(w);

    // Caret row marking the cursor column.
    try w.writeAll("   ");
    col = 0;
    while (col < visible and scroll + col <= total_steps) : (col += 1) {
        try w.writeAll(if (scroll + col == app.automation_cursor_step) acc ++ "^" ++ rst else " ");
    }
    try endLine(w);

    const used = 5;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawAutomationStatus(app: anytype, w: *std.Io.Writer, cmds: []const cmd_mod.Def) !void {
    if (app.modal.mode == .command) {
        try cmd_mod.writePrompt(w, cmds, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor, 60);
        return;
    }
    if (app.modal.mode == .search) {
        try cmd_mod.writeSearchPrompt(w, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor);
        return;
    }
    const clip = currentClip(app) orelse {
        try w.writeAll(dim ++ "clip gone — esc" ++ rst);
        return;
    };

    const bpb = app.session.project.beats_per_bar;
    const steps_per_bar: u32 = @as(u32, bpb) * 4;
    const bar = app.automation_cursor_step / steps_per_bar;
    const step_in_bar = app.automation_cursor_step % steps_per_bar;
    const beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;

    if (app.modal.mode == .visual) {
        try w.writeAll(yel ++ sel ++ " VISUAL " ++ rst ++ " ");
    }
    try w.writeAll(acc ++ sel);
    try w.print(" {d}.{d} ", .{ bar + 1, step_in_bar + 1 });
    try w.writeAll(rst);

    const target = app.automation_target;
    const points = curvePoints(clip, target);
    if (automation_mod.interpolate(points, beat)) |v| {
        const explicit = hasPointAt(points, beat);
        try w.writeAll(dim ++ "  " ++ rst);
        if (explicit) try w.writeAll(bold);
        switch (target) {
            .gain => try w.print("{d:.1}dB", .{v}),
            .pan => try w.print("{d:.2}", .{v}),
        }
        if (explicit) {
            try w.writeAll(rst);
            try w.writeAll(dim ++ " (point)" ++ rst);
        } else {
            try w.writeAll(dim ++ " (interpolated)" ++ rst);
        }
    } else {
        try w.writeAll(dim ++ "  no automation yet — j/k adds a point" ++ rst);
    }

    try w.writeAll(dim ++ "  h/l:move  j/k:nudge  x:delete  v:select  .:repeat  tab:curve  esc:back" ++ rst);

    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

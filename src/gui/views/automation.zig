const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const automation_ed = @import("../../ui/editors/automation.zig");
const history = @import("../../ui/history.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const color = style.color;
const trackColor = style.trackColor;
const theme = &style.palette;

/// The envelope pane yields to the point readout under it instead of pushing
/// it off screen (see widgets.PaneFit). One layout for every curve, so the fit
/// needs no key.
var pane_fit: widgets.PaneFit = .{};

pub fn draw(app: anytype) void {
    const clip = automation_ed.currentClip(&app.core);
    drawHeader(app, clip);
    zgui.spacing();
    if (clip == null) {
        drawEmptyState();
        return;
    }

    const live_clip = clip.?;
    const length_beats: f32 = @floatCast(ws.time_grid.tickToBeat(live_clip.length_ticks));
    const value_range = automation_ed.curveRange(&app.core, app.core.automation_focus);
    const points = automation_ed.curvePoints(&app.core, live_clip, app.core.automation_focus) catch {
        drawEmptyState();
        return;
    };
    const snap = app.core.session.engine.uiSnapshot();
    const playhead = automation_ed.playheadBeat(live_clip, snap.position_frames, app.core.session.project.sample_rate, app.core.session.project.tempo_bpm, snap.playing);

    drawTargetStrip(app, live_clip);
    zgui.spacing();
    widgets.sectionTitle("ENVELOPE", theme.modulation);
    drawCurve(app, points, @max(0.25, length_beats), value_range, playhead);
    const below_top = zgui.getCursorPosY();
    drawEditor(points.*);
    pane_fit.settle(below_top, 0);
}

fn drawHeader(app: anytype, clip: ?*const ws.Clip) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 72;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("automation-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    const track_idx = @min(@as(usize, app.core.automation_track), app.core.session.project.tracks.items.len -| 1);
    const track = app.core.session.project.tracks.items[track_idx];
    const accent = trackColor(track.color);
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg2), .rounding = style.panel_rounding });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(accent), .rounding = style.item_rounding });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(theme.fg3), "CLIP AUTOMATION", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(theme.fg0), "{s}", .{track.name});
    if (clip) |c| {
        const ticks_per_bar = ws.time_grid.barTicks(app.core.session.project.beats_per_bar);
        draw_list.addText(.{ origin[0] + width - 190, origin[1] + 13 }, color(accent), "CLIP @ BAR {d}", .{c.start_tick / ticks_per_bar + 1});
        draw_list.addText(.{ origin[0] + width - 190, origin[1] + 39 }, color(theme.fg3), "{d:.2} BEATS", .{ws.time_grid.tickToBeat(c.length_ticks)});
    }
}

fn drawEmptyState() void {
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("automation-empty", .{ .w = width, .h = 150 });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 150 }, .col = color(theme.bg2), .rounding = style.panel_rounding });
    draw_list.addText(.{ origin[0] + 22, origin[1] + 29 }, color(theme.fg0), "No clip selected", .{});
    draw_list.addText(.{ origin[0] + 22, origin[1] + 59 }, color(theme.fg3), "Place a clip, then press a on it in the arrangement.", .{});
}

fn drawTargetStrip(app: anytype, clip: *ws.Clip) void {
    widgets.sectionTitle("CURVE", theme.focus);
    if (zgui.beginChild("automation-targets", .{ .w = 0, .h = 52, .window_flags = .{ .horizontal_scrollbar = true } })) {
        drawTargetButton(app, "GAIN", .gain, 0);
        zgui.sameLine(.{ .spacing = 6 });
        drawTargetButton(app, "PAN", .pan, 1);
        for (clip.automation.synth_params.items, 0..) |lane, i| {
            zgui.sameLine(.{ .spacing = 6 });
            const label = if (automation_ed.findAutomatableParam(&app.core, lane.param_id)) |p| p.label else "PARAM";
            drawTargetButton(app, label, .{ .synth_param = lane.param_id }, i + 2);
        }
        zgui.sameLine(.{ .spacing = 8 });
        if (zgui.button("+ PARAM##automation-param", .{ .h = 32 })) {
            app.core.handleKey(.{ .char = 'p' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
    zgui.endChild();
}

fn drawTargetButton(app: anytype, text: []const u8, target: automation_ed.AutomationFocus, index: usize) void {
    var buf: [80]u8 = undefined;
    const label = std.fmt.bufPrintZ(&buf, "{s}##automation-target-{d}", .{ text, index }) catch return;
    const active = std.meta.eql(app.core.automation_focus, target);
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) theme.focus else theme.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else theme.fg2 });
    if (zgui.button(label, .{ .h = 32 })) app.core.automation_focus = target;
    zgui.popStyleColor(.{ .count = 2 });
}

/// Point in `points` (if any) sitting within a half-step of the cursor
/// beat - drives the curve widget's focus ring so the keyboard cursor and
/// the mouse-draggable nodes stay visually in sync.
fn focusedPointIndex(app: anytype, points: []const ws.dsp.automation.AutomationPoint) ?usize {
    const cursor_beat = @as(f64, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
    for (points, 0..) |p, i| if (@abs(p.beat - cursor_beat) < 0.125) return i;
    return null;
}

fn drawCurve(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, length_beats: f32, value_range: [2]f32, playhead: ?f64) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = pane_fit.height(180, 560);
    const origin = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg0), .rounding = style.panel_rounding });

    const plot_origin = [2]f32{ origin[0] + 58, origin[1] + 14 };
    const plot_size = [2]f32{ @max(1, width - 72), height - 42 };
    const plot_end = [2]f32{ plot_origin[0] + plot_size[0], plot_origin[1] + plot_size[1] };

    // The draggable/insertable/deletable curve itself - background, snap
    // grid, connecting lines, and one node per point, all in one widget
    // (widgets.zig's curveEditor). The view-specific chrome below (bar
    // ruler, axis labels, zero line, cursor readout) draws on top of it.
    zgui.setCursorScreenPos(plot_origin);
    const curve_result = widgets.curveEditor("automation-curve", .{
        .points = points.*,
        .beat_hi = length_beats,
        .value_lo = value_range[0],
        .value_hi = value_range[1],
        .snap_beats = 0.25,
        .accent = theme.modulation,
        .focused_index = focusedPointIndex(app, points.*),
        .width = plot_size[0],
        .height = plot_size[1],
    });
    if (curve_result.moved) |m| {
        recordAutomationGesture(app);
        points.*[m.index] = .{ .beat = m.beat, .value = m.value };
        app.core.automation_cursor_step = @intFromFloat(@round(m.beat * 4));
        app.core.dirty = true;
    }
    if (curve_result.inserted) |ins| {
        app.core.automation_cursor_step = @intFromFloat(@round(ins.beat * 4));
        setPointAt(app, points, ins.beat, ins.value);
    }
    if (curve_result.removed) |beat| {
        recordAutomationGesture(app);
        if (ws.dsp.automation.removePoint(app.core.allocator, points, beat) catch {
            app.core.setStatus("automation edit failed (out of memory)", .{});
            return;
        }) {
            app.core.dirty = true;
        }
    }
    if (curve_result.activated_index) |i| {
        if (i < points.*.len) app.core.automation_cursor_step = @intFromFloat(@round(points.*[i].beat * 4));
    }

    // The widget above only reserved plot_size's worth of layout space
    // (it doesn't know about this view's outer margins) - reserve the rest
    // so whatever draws after drawCurve starts below the full chrome, not
    // wherever the widget's own cursor landed.
    zgui.setCursorScreenPos(origin);
    zgui.dummy(.{ .w = width, .h = height });

    const beats_per_bar: u8 = app.core.session.project.beats_per_bar;
    const grid_strides = beatGridStrides(length_beats, plot_size[0]);
    const line_stride = grid_strides[0];
    const label_stride = grid_strides[1];
    const last_beat: u32 = @intFromFloat(@floor(length_beats));
    for (0..last_beat / line_stride + 1) |line_index| {
        const beat_index: u32 = @intCast(line_index * line_stride);
        const beat: f32 = @floatFromInt(beat_index);
        const x = plot_origin[0] + beat / length_beats * plot_size[0];
        const bar_line = beat_index % beats_per_bar == 0;
        draw_list.addLine(.{ .p1 = .{ x, plot_origin[1] }, .p2 = .{ x, plot_end[1] }, .col = color(if (bar_line) theme.bg5 else theme.line), .thickness = if (bar_line) 1.5 else 1 });
        if (beat_index % label_stride == 0) {
            draw_list.addText(.{ x + 4, plot_end[1] + 7 }, color(if (bar_line) theme.fg2 else theme.fg3), "{d}", .{beat_index + 1});
        }
    }
    for (1..4) |i| {
        const fraction = @as(f32, @floatFromInt(i)) / 4;
        const y = plot_origin[1] + plot_size[1] * fraction;
        draw_list.addLine(.{ .p1 = .{ plot_origin[0], y }, .p2 = .{ plot_end[0], y }, .col = color(theme.line), .thickness = 1 });
    }
    for (0..5) |i| {
        const fraction = @as(f32, @floatFromInt(i)) / 4;
        const value = value_range[1] - fraction * (value_range[1] - value_range[0]);
        const y = plot_origin[1] + plot_size[1] * fraction;
        if (std.meta.activeTag(app.core.automation_focus) == .gain) {
            draw_list.addText(.{ origin[0] + 8, y - 7 }, color(theme.fg3), "{d:.0}", .{value});
        } else {
            draw_list.addText(.{ origin[0] + 8, y - 7 }, color(theme.fg3), "{d:.2}", .{value});
        }
    }
    if (value_range[0] < 0 and value_range[1] > 0) {
        const zero = curvePoint(plot_origin, plot_size, 0, 0, length_beats, value_range);
        draw_list.addLine(.{ .p1 = .{ plot_origin[0], zero[1] }, .p2 = .{ plot_end[0], zero[1] }, .col = color(.{ theme.fg3[0], theme.fg3[1], theme.fg3[2], 0.45 }), .thickness = 1.5 });
    }

    if (app.core.modal.mode == .visual) {
        const anchor = app.core.automation_visual_anchor orelse app.core.automation_cursor_step;
        const lo = @min(anchor, app.core.automation_cursor_step);
        const hi = @max(anchor, app.core.automation_cursor_step) + 1;
        const x1 = plot_origin[0] + @as(f32, @floatFromInt(lo)) * 0.25 / length_beats * plot_size[0];
        const x2 = plot_origin[0] + @as(f32, @floatFromInt(hi)) * 0.25 / length_beats * plot_size[0];
        draw_list.addRectFilled(.{ .pmin = .{ x1, plot_origin[1] }, .pmax = .{ @min(x2, plot_end[0]), plot_end[1] }, .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.12 }) });
    }

    if (playhead) |beat| {
        const x = plot_origin[0] + @as(f32, @floatCast(beat)) / length_beats * plot_size[0];
        draw_list.addLine(.{ .p1 = .{ x, plot_origin[1] }, .p2 = .{ x, plot_end[1] }, .col = color(theme.danger), .thickness = 2 });
    }

    // The curve line/nodes themselves are drawn by widgets.curveEditor
    // above; just the keyboard-cursor readout (a separate notion from
    // "a node is focused" - the cursor can sit between points) draws here.
    const cursor_beat = @as(f32, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
    const cursor_value = ws.dsp.automation.interpolate(points.*, cursor_beat) orelse 0;
    const cursor = curvePoint(plot_origin, plot_size, cursor_beat, cursor_value, length_beats, value_range);
    const stored_point = focusedPointIndex(app, points.*) != null;
    draw_list.addLine(.{ .p1 = .{ cursor[0], plot_origin[1] }, .p2 = .{ cursor[0], plot_end[1] }, .col = color(theme.focus), .thickness = 2 });
    draw_list.addLine(.{ .p1 = .{ plot_origin[0], cursor[1] }, .p2 = .{ plot_end[0], cursor[1] }, .col = color(.{ theme.focus[0], theme.focus[1], theme.focus[2], 0.48 }), .thickness = 1 });
    if (stored_point) {
        draw_list.addCircleFilled(.{ .p = cursor, .r = 5, .col = color(theme.focus) });
    } else {
        draw_list.addLine(.{ .p1 = .{ cursor[0] - 5, cursor[1] }, .p2 = .{ cursor[0] + 5, cursor[1] }, .col = color(theme.focus), .thickness = 2 });
        draw_list.addLine(.{ .p1 = .{ cursor[0], cursor[1] - 5 }, .p2 = .{ cursor[0], cursor[1] + 5 }, .col = color(theme.focus), .thickness = 2 });
    }
    draw_list.addCircle(.{ .p = cursor, .r = 8, .col = color(theme.fg0), .thickness = 1 });
    const badge_width: f32 = if (stored_point) 88 else 134;
    const badge = [2]f32{ @min(cursor[0] + 9, plot_end[0] - badge_width - 6), @max(plot_origin[1] + 7, cursor[1] - 29) };
    draw_list.addRectFilled(.{ .pmin = badge, .pmax = .{ badge[0] + badge_width, badge[1] + 22 }, .col = color(theme.bg4), .rounding = style.item_rounding });
    if (stored_point) {
        draw_list.addText(.{ badge[0] + 7, badge[1] + 2 }, color(theme.fg0), "{d:.2}  {d:.2}", .{ cursor_beat, cursor_value });
    } else {
        draw_list.addText(.{ badge[0] + 7, badge[1] + 2 }, color(theme.fg1), "INSERT  {d:.2}  {d:.2}", .{ cursor_beat, cursor_value });
    }
    draw_list.addRect(.{ .pmin = plot_origin, .pmax = plot_end, .col = color(theme.bg5), .rounding = style.panel_rounding, .thickness = 1 });
}

fn beatGridStrides(length_beats: f32, width: f32) [2]u32 {
    const line_stride = @max(1, @as(u32, @intFromFloat(@ceil(length_beats * 4 / width))));
    const min_label_stride = @max(1, @as(u32, @intFromFloat(@ceil(length_beats * 58 / width))));
    const label_stride = (std.math.divCeil(u32, min_label_stride, line_stride) catch unreachable) * line_stride;
    return .{ line_stride, label_stride };
}

fn curvePoint(origin: [2]f32, size: [2]f32, beat: f32, value: f32, length_beats: f32, value_range: [2]f32) [2]f32 {
    const x_norm = std.math.clamp(beat / length_beats, 0, 1);
    const y_norm = std.math.clamp((value - value_range[0]) / (value_range[1] - value_range[0]), 0, 1);
    return .{ origin[0] + x_norm * size[0], origin[1] + (1.0 - y_norm) * size[1] };
}

/// The curve's own footer: point count plus the two mouse gestures the
/// curve widget answers to. Beat/value for the cursor are already on the
/// curve's readout badge, and setting/deleting a point is the click and
/// double-click right there, so there is no second editor panel.
fn drawEditor(points: []const ws.dsp.automation.AutomationPoint) void {
    zgui.textDisabled("{d} points   click add   double-click delete", .{points.len});
}

fn setPointAt(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, beat: f64, value: f32) void {
    recordAutomationGesture(app);
    ws.dsp.automation.setPoint(app.core.allocator, points, beat, value) catch return;
    app.core.dirty = true;
}

pub fn recordAutomationGesture(app: anytype) void {
    if (app.automation_edit_active) return;
    history.recordLane(&app.core, app.core.automation_track);
    app.automation_edit_active = true;
}

pub fn drawParamPicker(app: anytype) void {
    zgui.textColored(theme.focus, "AUTOMATION PARAMETER", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("ENTER ADD   / FILTER   ESC BACK", .{});
    zgui.separator();
    const params = automation_ed.instrumentAutomatableParams(&app.core);
    var buf: [automation_ed.max_param_display_rows]automation_ed.ParamDisplayRow = undefined;
    const rows = automation_ed.buildParamDisplayRows(params, automation_ed.activeParamFilter(&app.core), &buf);
    const width = @min(zgui.getContentRegionAvail()[0], 820);
    for (rows) |row| switch (row) {
        .header => |name| {
            zgui.spacing();
            zgui.textColored(theme.fg3, "{s}", .{name});
            zgui.separator();
        },
        .param => |i| {
            const p = params[i];
            const selected = app.core.automation_param_cursor == i;
            var id_buf: [48]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "automation-param-{d}", .{i}) catch continue;
            const origin = zgui.getCursorScreenPos();
            const clicked = zgui.invisibleButton(id, .{ .w = width, .h = 36 });
            widgets.noteFocusRow(selected, origin[1], 36);
            const hovered = zgui.isItemHovered(.{});
            const draw_list = zgui.getWindowDrawList();
            draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 34 }, .col = color(if (selected) theme.bg4 else if (hovered) theme.bg3 else theme.bg2), .rounding = style.item_rounding });
            if (selected) draw_list.addRect(.{ .pmin = .{ origin[0] + 1, origin[1] + 1 }, .pmax = .{ origin[0] + width - 1, origin[1] + 33 }, .col = color(theme.focus), .rounding = style.item_rounding, .thickness = 2 });
            draw_list.addText(.{ origin[0] + 12, origin[1] + 8 }, color(if (selected) theme.fg0 else theme.fg1), "{s}", .{p.label});
            var range_buf: [48]u8 = undefined;
            const range = compactParamRange(&range_buf, p.label, p.range);
            const range_width = zgui.calcTextSize(range, .{})[0];
            draw_list.addText(.{ origin[0] + width - range_width - 12, origin[1] + 8 }, color(theme.fg2), "{s}", .{range});
            if (clicked) {
                app.core.clickAutomationParamPickerItem(i, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
        },
    };
}

fn compactParamRange(buf: []u8, label: []const u8, range: [2]f32) []const u8 {
    if (range[0] >= 0 and range[1] <= 1) {
        return std.fmt.bufPrint(buf, "{d:.0} .. {d:.0}%", .{ range[0] * 100, range[1] * 100 }) catch "";
    }
    const unit: []const u8 = if (containsAny(label, &.{ "FREQ", "CUTOFF", "XOVER", "SHIFT" }))
        " Hz"
    else if (containsAny(label, &.{ "SEMI", "PITCH" }))
        " st"
    else if (containsAny(label, &.{"DETUNE"}))
        " ct"
    else if (containsAny(label, &.{ "THRESH", "MAKEUP", "EQ LO GAIN", "EQ MID GAIN", "EQ HI GAIN", "GAIN IN", "GAIN OUT" }))
        " dB"
    else
        "";
    return std.fmt.bufPrint(buf, "{d:.2} .. {d:.2}{s}", .{ range[0], range[1], unit }) catch "";
}

fn containsAny(label: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(label, needle) != null) return true;
    }
    return false;
}

test "curvePoint maps the lane's corners and clamps past them" {
    const testing = std.testing;
    const origin = [2]f32{ 40, 80 };
    const size = [2]f32{ 400, 200 };
    const range = [2]f32{ -12, 12 };

    // Beat 0 at the left, the lane's last beat at the right; the value axis is
    // inverted (a high value draws near the top).
    const low = curvePoint(origin, size, 0, range[0], 16, range);
    try testing.expectApproxEqAbs(origin[0], low[0], 0.01);
    try testing.expectApproxEqAbs(origin[1] + size[1], low[1], 0.01);
    const high = curvePoint(origin, size, 16, range[1], 16, range);
    try testing.expectApproxEqAbs(origin[0] + size[0], high[0], 0.01);
    try testing.expectApproxEqAbs(origin[1], high[1], 0.01);
    const mid = curvePoint(origin, size, 8, 0, 16, range);
    try testing.expectApproxEqAbs(origin[0] + size[0] / 2, mid[0], 0.01);
    try testing.expectApproxEqAbs(origin[1] + size[1] / 2, mid[1], 0.01);

    // A point past the lane's length (a clip shortened under it) stays on the
    // widget instead of drawing off into the next panel.
    const past = curvePoint(origin, size, 99, 999, 16, range);
    try testing.expectApproxEqAbs(origin[0] + size[0], past[0], 0.01);
    try testing.expectApproxEqAbs(origin[1], past[1], 0.01);
}

test "beat grid bounds work for long clips" {
    try std.testing.expectEqual([2]u32{ 1, 2 }, beatGridStrides(16, 800));
    try std.testing.expectEqual([2]u32{ 4000, 60_000 }, beatGridStrides(1_000_000, 1000));
}

test "compactParamRange labels the unit the param's name implies" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("0 .. 100%", compactParamRange(&buf, "MIX", .{ 0, 1 }));
    try testing.expectEqualStrings("20.00 .. 20000.00 Hz", compactParamRange(&buf, "FILTER CUTOFF", .{ 20, 20_000 }));
    try testing.expectEqualStrings("-24.00 .. 24.00 st", compactParamRange(&buf, "PITCH SEMI", .{ -24, 24 }));
    try testing.expectEqualStrings("-50.00 .. 50.00 ct", compactParamRange(&buf, "DETUNE", .{ -50, 50 }));
    try testing.expectEqualStrings("-60.00 .. 0.00 dB", compactParamRange(&buf, "COMP THRESH", .{ -60, 0 }));
    try testing.expectEqualStrings("1.00 .. 8.00", compactParamRange(&buf, "VOICES", .{ 1, 8 }));
}

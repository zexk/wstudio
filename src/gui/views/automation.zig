const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const automation_ed = @import("../../ui/editors/automation.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const color = style.color;
const trackColor = style.trackColor;
const patina = &style.palette;

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

    drawTargetStrip(app, live_clip);
    zgui.spacing();
    widgets.sectionTitle("ENVELOPE", patina.modulation);
    drawCurve(app, points, @max(0.25, length_beats), value_range);
    zgui.spacing();
    drawEditor(app, points, @max(0.25, length_beats), value_range);
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
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(patina.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(accent), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(patina.fg3), "CLIP AUTOMATION", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(patina.fg0), "{s}", .{track.name});
    if (clip) |c| {
        const ticks_per_bar = ws.time_grid.barTicks(app.core.session.project.beats_per_bar);
        draw_list.addText(.{ origin[0] + width - 190, origin[1] + 13 }, color(accent), "CLIP @ BAR {d}", .{c.start_tick / ticks_per_bar + 1});
        draw_list.addText(.{ origin[0] + width - 190, origin[1] + 39 }, color(patina.fg3), "{d:.2} BEATS", .{ws.time_grid.tickToBeat(c.length_ticks)});
    }
}

fn drawEmptyState() void {
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("automation-empty", .{ .w = width, .h = 150 });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 150 }, .col = color(patina.bg2), .rounding = 4 });
    draw_list.addText(.{ origin[0] + 22, origin[1] + 29 }, color(patina.fg0), "No clip selected", .{});
    draw_list.addText(.{ origin[0] + 22, origin[1] + 59 }, color(patina.fg3), "Place a clip, then press a on it in the arrangement.", .{});
}

fn drawTargetStrip(app: anytype, clip: *ws.Clip) void {
    widgets.sectionTitle("CURVE", patina.focus);
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

fn drawTargetButton(app: anytype, text: []const u8, target: automation_ed.AutomationFocus, index: usize) void {
    var buf: [80]u8 = undefined;
    const label = std.fmt.bufPrintZ(&buf, "{s}##automation-target-{d}", .{ text, index }) catch return;
    const active = std.meta.eql(app.core.automation_focus, target);
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) patina.focus else patina.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) patina.bg0 else patina.fg2 });
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

fn drawCurve(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, length_beats: f32, value_range: [2]f32) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = std.math.clamp(zgui.getContentRegionAvail()[1] - 104, 280, 560);
    const origin = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(patina.bg0), .rounding = 4 });

    const plot_origin = [2]f32{ origin[0] + 58, origin[1] + 14 };
    const plot_size = [2]f32{ @max(1, width - 72), height - 42 };
    const plot_end = [2]f32{ plot_origin[0] + plot_size[0], plot_origin[1] + plot_size[1] };

    // The draggable/insertable/deletable curve itself - background, snap
    // grid, connecting lines, and one node per point, all in one widget
    // (widgets.zig's curveEditor). The view-specific chrome below (bar
    // ruler, axis labels, zero line, cursor readout) draws on top of it.
    var curve_buf: [128]widgets.CurvePoint = undefined;
    const curve_n = @min(points.*.len, curve_buf.len);
    for (points.*[0..curve_n], curve_buf[0..curve_n]) |src, *dst| dst.* = .{ .beat = src.beat, .value = src.value };
    zgui.setCursorScreenPos(plot_origin);
    const curve_result = widgets.curveEditor("automation-curve", .{
        .points = curve_buf[0..curve_n],
        .beat_hi = length_beats,
        .value_lo = value_range[0],
        .value_hi = value_range[1],
        .snap_beats = 0.25,
        .accent = patina.modulation,
        .focused_index = focusedPointIndex(app, points.*),
        .width = plot_size[0],
        .height = plot_size[1],
    });
    if (curve_result.moved) |m| {
        points.*[m.index] = .{ .beat = m.beat, .value = m.value };
        app.core.automation_cursor_step = @intFromFloat(@round(m.beat * 4));
        app.core.dirty = true;
        app.core.session.rebuildSongData();
    }
    if (curve_result.inserted) |ins| {
        app.core.automation_cursor_step = @intFromFloat(@round(ins.beat * 4));
        setPointAt(app, points, ins.beat, ins.value);
    }
    if (curve_result.removed) |beat| {
        if (ws.dsp.automation.removePoint(app.core.allocator, points, beat)) {
            app.core.dirty = true;
            app.core.session.rebuildSongData();
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
    const label_stride = @max(1, @as(u32, @intFromFloat(@ceil(58.0 / (plot_size[0] / length_beats)))));
    const last_beat: u32 = @intFromFloat(@floor(length_beats));
    for (0..last_beat + 1) |beat_index| {
        const beat: f32 = @floatFromInt(beat_index);
        const x = plot_origin[0] + beat / length_beats * plot_size[0];
        const bar_line = beat_index % beats_per_bar == 0;
        draw_list.addLine(.{ .p1 = .{ x, plot_origin[1] }, .p2 = .{ x, plot_end[1] }, .col = color(if (bar_line) patina.bg5 else patina.line), .thickness = if (bar_line) 1.5 else 1 });
        if (beat_index % label_stride == 0) {
            draw_list.addText(.{ x + 4, plot_end[1] + 7 }, color(if (bar_line) patina.fg2 else patina.fg3), "{d}", .{beat_index + 1});
        }
    }
    for (1..4) |i| {
        const fraction = @as(f32, @floatFromInt(i)) / 4;
        const y = plot_origin[1] + plot_size[1] * fraction;
        draw_list.addLine(.{ .p1 = .{ plot_origin[0], y }, .p2 = .{ plot_end[0], y }, .col = color(patina.line), .thickness = 1 });
    }
    for (0..5) |i| {
        const fraction = @as(f32, @floatFromInt(i)) / 4;
        const value = value_range[1] - fraction * (value_range[1] - value_range[0]);
        const y = plot_origin[1] + plot_size[1] * fraction;
        if (std.meta.activeTag(app.core.automation_focus) == .gain) {
            draw_list.addText(.{ origin[0] + 8, y - 7 }, color(patina.fg3), "{d:.0}", .{value});
        } else {
            draw_list.addText(.{ origin[0] + 8, y - 7 }, color(patina.fg3), "{d:.2}", .{value});
        }
    }
    if (value_range[0] < 0 and value_range[1] > 0) {
        const zero = curvePoint(plot_origin, plot_size, 0, 0, length_beats, value_range);
        draw_list.addLine(.{ .p1 = .{ plot_origin[0], zero[1] }, .p2 = .{ plot_end[0], zero[1] }, .col = color(.{ patina.fg3[0], patina.fg3[1], patina.fg3[2], 0.45 }), .thickness = 1.5 });
    }

    if (app.core.modal.mode == .visual) {
        const anchor = app.core.automation_visual_anchor orelse app.core.automation_cursor_step;
        const lo = @min(anchor, app.core.automation_cursor_step);
        const hi = @max(anchor, app.core.automation_cursor_step) + 1;
        const x1 = plot_origin[0] + @as(f32, @floatFromInt(lo)) * 0.25 / length_beats * plot_size[0];
        const x2 = plot_origin[0] + @as(f32, @floatFromInt(hi)) * 0.25 / length_beats * plot_size[0];
        draw_list.addRectFilled(.{ .pmin = .{ x1, plot_origin[1] }, .pmax = .{ @min(x2, plot_end[0]), plot_end[1] }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.12 }) });
    }

    // The curve line/nodes themselves are drawn by widgets.curveEditor
    // above; just the keyboard-cursor readout (a separate notion from
    // "a node is focused" - the cursor can sit between points) draws here.
    const cursor_beat = @as(f32, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
    const cursor_value = ws.dsp.automation.interpolate(points.*, cursor_beat) orelse 0;
    const cursor = curvePoint(plot_origin, plot_size, cursor_beat, cursor_value, length_beats, value_range);
    draw_list.addLine(.{ .p1 = .{ cursor[0], plot_origin[1] }, .p2 = .{ cursor[0], plot_end[1] }, .col = color(patina.focus), .thickness = 2 });
    draw_list.addLine(.{ .p1 = .{ plot_origin[0], cursor[1] }, .p2 = .{ plot_end[0], cursor[1] }, .col = color(.{ patina.focus[0], patina.focus[1], patina.focus[2], 0.48 }), .thickness = 1 });
    draw_list.addCircleFilled(.{ .p = cursor, .r = 5, .col = color(patina.focus) });
    draw_list.addCircle(.{ .p = cursor, .r = 8, .col = color(patina.fg0), .thickness = 1 });
    const badge = [2]f32{ @min(cursor[0] + 9, plot_end[0] - 94), @max(plot_origin[1] + 7, cursor[1] - 29) };
    draw_list.addRectFilled(.{ .pmin = badge, .pmax = .{ badge[0] + 88, badge[1] + 22 }, .col = color(patina.bg4), .rounding = 3 });
    draw_list.addText(.{ badge[0] + 7, badge[1] + 2 }, color(patina.fg0), "{d:.2}  {d:.2}", .{ cursor_beat, cursor_value });
    draw_list.addRect(.{ .pmin = plot_origin, .pmax = plot_end, .col = color(patina.bg5), .rounding = 2, .thickness = 1 });
}

fn curvePoint(origin: [2]f32, size: [2]f32, beat: f32, value: f32, length_beats: f32, value_range: [2]f32) [2]f32 {
    const x_norm = std.math.clamp(beat / length_beats, 0, 1);
    const y_norm = std.math.clamp((value - value_range[0]) / (value_range[1] - value_range[0]), 0, 1);
    return .{ origin[0] + x_norm * size[0], origin[1] + (1.0 - y_norm) * size[1] };
}

fn drawEditor(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, length_beats: f32, value_range: [2]f32) void {
    if (zgui.beginChild("automation-editor", .{ .w = 0, .h = 82, .child_flags = .{ .border = true } })) {
        zgui.textColored(patina.focus, "POINT", .{});
        zgui.sameLine(.{ .spacing = 12 });
        var beat = @as(f32, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
        zgui.setNextItemWidth(180);
        if (zgui.sliderFloat("Beat", .{ .v = &beat, .min = 0, .max = length_beats, .cfmt = "%.2f" })) app.core.automation_cursor_step = @intFromFloat(@round(beat * 4));
        const cursor_beat = @as(f64, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
        var value = ws.dsp.automation.interpolate(points.*, cursor_beat) orelse 0;
        zgui.sameLine(.{ .spacing = 16 });
        zgui.setNextItemWidth(180);
        if (zgui.sliderFloat("Value", .{ .v = &value, .min = value_range[0], .max = value_range[1], .cfmt = if (std.meta.activeTag(app.core.automation_focus) == .gain) "%.1f dB" else "%.2f" })) setPoint(app, points, value);
        zgui.sameLine(.{ .spacing = 16 });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = patina.focus_soft });
        if (zgui.button("SET", .{ .h = 30 })) setPoint(app, points, value);
        zgui.popStyleColor(.{});
        zgui.sameLine(.{ .spacing = 6 });
        if (zgui.button("DELETE", .{ .h = 30 })) {
            if (ws.dsp.automation.removePoint(app.core.allocator, points, cursor_beat)) {
                app.core.dirty = true;
                app.core.session.rebuildSongData();
            }
        }
        zgui.sameLine(.{ .spacing = 12 });
        zgui.textDisabled("{d} points   click graph to add   right-click to delete", .{points.*.len});
    }
    zgui.endChild();
}

fn setPoint(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, value: f32) void {
    const beat = @as(f64, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
    setPointAt(app, points, beat, value);
}

fn setPointAt(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, beat: f64, value: f32) void {
    ws.dsp.automation.setPoint(app.core.allocator, points, beat, value) catch return;
    app.core.dirty = true;
    app.core.session.rebuildSongData();
}

pub fn drawParamPicker(app: anytype) void {
    zgui.textColored(patina.focus, "AUTOMATION PARAMETER", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("ENTER ADD   ESC BACK   / FILTER", .{});
    zgui.separator();
    const params = automation_ed.instrumentAutomatableParams(&app.core);
    var buf: [automation_ed.max_param_display_rows]automation_ed.ParamDisplayRow = undefined;
    const rows = automation_ed.buildParamDisplayRows(params, automation_ed.activeParamFilter(&app.core), &buf);
    if (zgui.beginChild("automation-params", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (rows) |row| switch (row) {
            .header => |name| {
                zgui.spacing();
                zgui.textColored(patina.fg3, "{s}", .{name});
                zgui.separator();
            },
            .param => |i| {
                const p = params[i];
                const selected = app.core.automation_param_cursor == i;
                zgui.pushStyleColor4f(.{ .idx = .button, .c = if (selected) patina.bg4 else patina.bg2 });
                zgui.pushStyleColor4f(.{ .idx = .text, .c = if (selected) patina.focus else patina.fg1 });
                var label_buf: [128]u8 = undefined;
                const label = std.fmt.bufPrintZ(&label_buf, "{s}   {d:.2} .. {d:.2}##automation-param-{d}", .{ p.label, p.range[0], p.range[1], i }) catch continue;
                if (zgui.button(label, .{ .w = -1, .h = 34 })) {
                    app.core.automation_param_cursor = @intCast(i);
                    automation_ed.selectParam(&app.core, p.id);
                }
                zgui.popStyleColor(.{ .count = 2 });
            },
        };
    }
    zgui.endChild();
}

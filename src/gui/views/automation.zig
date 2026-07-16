const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const automation_ed = @import("../../tui/editors/automation.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const color = style.color;
const trackColor = style.trackColor;
const patina = style.patina;

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

fn drawCurve(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, length_beats: f32, value_range: [2]f32) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 240;
    const origin = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton("automation-curve", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(patina.bg0), .rounding = 4 });

    for (1..8) |i| {
        const x = origin[0] + width * @as(f32, @floatFromInt(i)) / 8;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = color(if (i % 4 == 0) patina.bg5 else patina.line), .thickness = 1 });
    }
    for (1..4) |i| {
        const y = origin[1] + height * @as(f32, @floatFromInt(i)) / 4;
        draw_list.addLine(.{ .p1 = .{ origin[0], y }, .p2 = .{ origin[0] + width, y }, .col = color(patina.line), .thickness = 1 });
    }

    if (app.core.modal.mode == .visual) {
        const anchor = app.core.automation_visual_anchor orelse app.core.automation_cursor_step;
        const lo = @min(anchor, app.core.automation_cursor_step);
        const hi = @max(anchor, app.core.automation_cursor_step) + 1;
        const x1 = origin[0] + @as(f32, @floatFromInt(lo)) * 0.25 / length_beats * width;
        const x2 = origin[0] + @as(f32, @floatFromInt(hi)) * 0.25 / length_beats * width;
        draw_list.addRectFilled(.{ .pmin = .{ x1, origin[1] }, .pmax = .{ @min(x2, origin[0] + width), origin[1] + height }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.12 }) });
    }

    var previous: ?[2]f32 = null;
    for (points.*) |point| {
        const p = curvePoint(origin, .{ width, height }, @floatCast(point.beat), point.value, length_beats, value_range);
        if (previous) |prev| draw_list.addLine(.{ .p1 = prev, .p2 = p, .col = color(patina.modulation), .thickness = 2 });
        draw_list.addCircleFilled(.{ .p = p, .r = 5, .col = color(patina.modulation) });
        draw_list.addCircle(.{ .p = p, .r = 7, .col = color(patina.fg0), .thickness = 1 });
        previous = p;
    }

    const cursor_beat = @as(f32, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
    const cursor_value = ws.dsp.automation.interpolate(points.*, cursor_beat) orelse 0;
    const cursor = curvePoint(origin, .{ width, height }, cursor_beat, cursor_value, length_beats, value_range);
    draw_list.addLine(.{ .p1 = .{ cursor[0], origin[1] }, .p2 = .{ cursor[0], origin[1] + height }, .col = color(patina.focus), .thickness = 2 });
    draw_list.addCircleFilled(.{ .p = cursor, .r = 5, .col = color(patina.focus) });
    draw_list.addCircle(.{ .p = cursor, .r = 8, .col = color(patina.fg0), .thickness = 1 });

    if (hovered and clicked) {
        const beat = std.math.clamp((mouse[0] - origin[0]) / width * length_beats, 0, length_beats);
        app.core.automation_cursor_step = @intFromFloat(@round(beat * 4));
        const norm = 1.0 - std.math.clamp((mouse[1] - origin[1]) / height, 0, 1);
        const value = value_range[0] + norm * (value_range[1] - value_range[0]);
        setPoint(app, points, value);
    }
}

fn curvePoint(origin: [2]f32, size: [2]f32, beat: f32, value: f32, length_beats: f32, value_range: [2]f32) [2]f32 {
    const x_norm = std.math.clamp(beat / length_beats, 0, 1);
    const y_norm = std.math.clamp((value - value_range[0]) / (value_range[1] - value_range[0]), 0, 1);
    return .{ origin[0] + x_norm * size[0], origin[1] + (1.0 - y_norm) * size[1] };
}

fn drawEditor(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, length_beats: f32, value_range: [2]f32) void {
    if (zgui.beginChild("automation-editor", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        widgets.sectionTitle("POINT EDITOR", patina.focus);
        var beat = @as(f32, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
        if (zgui.sliderFloat("Beat", .{ .v = &beat, .min = 0, .max = length_beats, .cfmt = "%.2f" })) app.core.automation_cursor_step = @intFromFloat(@round(beat * 4));
        const cursor_beat = @as(f64, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
        var value = ws.dsp.automation.interpolate(points.*, cursor_beat) orelse 0;
        if (zgui.sliderFloat("Value", .{ .v = &value, .min = value_range[0], .max = value_range[1], .cfmt = if (std.meta.activeTag(app.core.automation_focus) == .gain) "%.1f dB" else "%.2f" })) setPoint(app, points, value);
        zgui.spacing();
        zgui.pushStyleColor4f(.{ .idx = .button, .c = patina.focus_soft });
        if (zgui.button("ADD / UPDATE POINT", .{ .h = 34 })) setPoint(app, points, value);
        zgui.popStyleColor(.{});
        zgui.sameLine(.{ .spacing = 6 });
        if (zgui.button("DELETE POINT", .{ .h = 34 })) {
            if (ws.dsp.automation.removePoint(app.core.allocator, points, cursor_beat)) {
                app.core.dirty = true;
                app.core.session.rebuildSongData();
            }
        }
        zgui.sameLine(.{});
        zgui.textDisabled("{d} points", .{points.*.len});
    }
    zgui.endChild();
}

fn setPoint(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, value: f32) void {
    const beat = @as(f64, @floatFromInt(app.core.automation_cursor_step)) * 0.25;
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

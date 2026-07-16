const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const color = style.color;
const trackColor = style.trackColor;
const umbra = style.umbra;

pub fn draw(app: anytype) void {
    const lane = if (app.core.cursor < app.core.session.arrangement.lanes.items.len) &app.core.session.arrangement.lanes.items[app.core.cursor] else null;
    drawHeader(app, if (lane) |l| l.clips.items.len else 0);
    zgui.spacing();
    if (lane == null or lane.?.clips.items.len == 0) {
        drawEmptyState();
        return;
    }

    app.automation_clip = @min(app.automation_clip, lane.?.clips.items.len - 1);
    widgets.sectionTitle("CLIP", umbra.iris);
    for (lane.?.clips.items, 0..) |clip, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 6 });
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "CLIP {d}##auto-clip-{d}", .{ i + 1, i }) catch continue;
        const active = app.automation_clip == i;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) umbra.iris else umbra.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) umbra.bg0 else umbra.fg2 });
        if (zgui.button(label, .{ .h = 32 })) app.automation_clip = i;
        zgui.popStyleColor(.{ .count = 2 });
        _ = clip;
    }

    const clip = &lane.?.clips.items[app.automation_clip];
    const length_beats: f32 = @floatCast(ws.time_grid.tickToBeat(clip.length_ticks));
    const value_range: [2]f32 = if (app.automation_target == .gain) .{ -60, 12 } else .{ -1, 1 };
    app.automation_value = std.math.clamp(app.automation_value, value_range[0], value_range[1]);
    const points: *[]ws.dsp.automation.AutomationPoint = switch (app.automation_target) {
        .gain => &clip.automation.gain,
        .pan => &clip.automation.pan,
    };

    zgui.spacing();
    widgets.sectionTitle("ENVELOPE", umbra.mauve);
    drawCurve(app, points.*, @max(0.25, length_beats), value_range);
    zgui.spacing();
    drawEditor(app, points, @max(0.25, length_beats), value_range);
}

fn drawHeader(app: anytype, clip_count: usize) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 72;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("automation-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    const track = app.core.session.project.tracks.items[app.core.cursor];
    const accent = trackColor(track.color);
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(accent), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(umbra.fg3), "CLIP AUTOMATION", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(umbra.fg0), "{s}", .{track.name});
    draw_list.addText(.{ origin[0] + width - 150, origin[1] + 13 }, color(accent), "{d} CLIPS", .{clip_count});
    draw_list.addText(.{ origin[0] + width - 150, origin[1] + 39 }, color(umbra.fg3), "GAIN / PAN", .{});
}

fn drawEmptyState() void {
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("automation-empty", .{ .w = width, .h = 150 });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 150 }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addText(.{ origin[0] + 22, origin[1] + 29 }, color(umbra.fg0), "No clip selected", .{});
    draw_list.addText(.{ origin[0] + 22, origin[1] + 59 }, color(umbra.fg3), "Place a clip in the arrangement to shape its automation.", .{});
}

fn drawCurve(app: anytype, points: []const ws.dsp.automation.AutomationPoint, length_beats: f32, value_range: [2]f32) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 210;
    const origin = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton("automation-curve", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg0), .rounding = 4 });

    for (1..8) |i| {
        const x = origin[0] + width * @as(f32, @floatFromInt(i)) / 8;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = color(if (i % 4 == 0) umbra.bg5 else umbra.line), .thickness = 1 });
    }
    for (1..4) |i| {
        const y = origin[1] + height * @as(f32, @floatFromInt(i)) / 4;
        draw_list.addLine(.{ .p1 = .{ origin[0], y }, .p2 = .{ origin[0] + width, y }, .col = color(umbra.line), .thickness = 1 });
    }

    var previous: ?[2]f32 = null;
    for (points) |point| {
        const p = curvePoint(origin, .{ width, height }, @floatCast(point.beat), point.value, length_beats, value_range);
        if (previous) |prev| draw_list.addLine(.{ .p1 = prev, .p2 = p, .col = color(umbra.mauve), .thickness = 2 });
        draw_list.addCircleFilled(.{ .p = p, .r = 5, .col = color(umbra.mauve) });
        draw_list.addCircle(.{ .p = p, .r = 7, .col = color(umbra.fg0), .thickness = 1 });
        previous = p;
    }

    const cursor = curvePoint(origin, .{ width, height }, app.automation_beat, app.automation_value, length_beats, value_range);
    draw_list.addLine(.{ .p1 = .{ cursor[0], origin[1] }, .p2 = .{ cursor[0], origin[1] + height }, .col = color(umbra.iris), .thickness = 1 });
    draw_list.addCircleFilled(.{ .p = cursor, .r = 4, .col = color(umbra.iris) });

    if (hovered and clicked) {
        app.automation_beat = std.math.clamp((mouse[0] - origin[0]) / width * length_beats, 0, length_beats);
        const norm = 1.0 - std.math.clamp((mouse[1] - origin[1]) / height, 0, 1);
        app.automation_value = value_range[0] + norm * (value_range[1] - value_range[0]);
    }
}

fn curvePoint(origin: [2]f32, size: [2]f32, beat: f32, value: f32, length_beats: f32, value_range: [2]f32) [2]f32 {
    const x_norm = std.math.clamp(beat / length_beats, 0, 1);
    const y_norm = std.math.clamp((value - value_range[0]) / (value_range[1] - value_range[0]), 0, 1);
    return .{ origin[0] + x_norm * size[0], origin[1] + (1.0 - y_norm) * size[1] };
}

fn drawEditor(app: anytype, points: *[]ws.dsp.automation.AutomationPoint, length_beats: f32, value_range: [2]f32) void {
    if (zgui.beginChild("automation-editor", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        widgets.sectionTitle("POINT EDITOR", umbra.iris);
        const gain_active = app.automation_target == .gain;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (gain_active) umbra.iris else umbra.bg2 });
        if (zgui.button("GAIN", .{ .w = 82, .h = 32 })) app.automation_target = .gain;
        zgui.popStyleColor(.{});
        zgui.sameLine(.{ .spacing = 6 });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (!gain_active) umbra.iris else umbra.bg2 });
        if (zgui.button("PAN", .{ .w = 82, .h = 32 })) app.automation_target = .pan;
        zgui.popStyleColor(.{});
        zgui.spacing();
        _ = zgui.sliderFloat("Beat", .{ .v = &app.automation_beat, .min = 0, .max = length_beats, .cfmt = "%.2f" });
        _ = zgui.sliderFloat("Value", .{ .v = &app.automation_value, .min = value_range[0], .max = value_range[1], .cfmt = if (gain_active) "%.1f dB" else "%.2f" });
        zgui.spacing();
        zgui.pushStyleColor4f(.{ .idx = .button, .c = umbra.iris_soft });
        if (zgui.button("ADD / UPDATE POINT", .{ .h = 34 })) {
            ws.dsp.automation.setPoint(app.core.allocator, points, app.automation_beat, app.automation_value) catch {};
            app.core.session.rebuildSongData();
        }
        zgui.popStyleColor(.{});
        zgui.sameLine(.{ .spacing = 6 });
        if (zgui.button("DELETE POINT", .{ .h = 34 })) {
            if (ws.dsp.automation.removePoint(app.core.allocator, points, app.automation_beat)) app.core.session.rebuildSongData();
        }
        zgui.sameLine(.{});
        zgui.textDisabled("{d} points", .{points.*.len});
    }
    zgui.endChild();
}

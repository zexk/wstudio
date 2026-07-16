const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");

pub fn draw(app: anytype) void {
    zgui.textDisabled("AUTOMATION", .{});
    const lane = if (app.core.cursor < app.core.session.arrangement.lanes.items.len) &app.core.session.arrangement.lanes.items[app.core.cursor] else null;
    if (lane == null or lane.?.clips.items.len == 0) {
        zgui.textDisabled("Place a clip in the arrangement to edit its automation.", .{});
        return;
    }
    app.automation_clip = @min(app.automation_clip, lane.?.clips.items.len - 1);
    for (lane.?.clips.items, 0..) |clip, i| {
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "Clip {d}##auto-clip-{d}", .{ i + 1, i }) catch continue;
        if (zgui.selectable(label, .{ .selected = app.automation_clip == i, .w = 100 })) app.automation_clip = i;
        zgui.sameLine(.{});
        zgui.textDisabled("tick {d}, length {d}", .{ clip.start_tick, clip.length_ticks });
    }
    const clip = &lane.?.clips.items[app.automation_clip];
    zgui.separator();
    if (zgui.button("Gain", .{})) app.automation_target = .gain;
    zgui.sameLine(.{});
    if (zgui.button("Pan", .{})) app.automation_target = .pan;
    zgui.sameLine(.{});
    zgui.text("Editing {s}", .{@tagName(app.automation_target)});

    const length_beats: f32 = @floatCast(ws.time_grid.tickToBeat(clip.length_ticks));
    _ = zgui.sliderFloat("Beat", .{ .v = &app.automation_beat, .min = 0, .max = @max(0.25, length_beats), .cfmt = "%.2f" });
    const value_range: [2]f32 = if (app.automation_target == .gain) .{ -60, 12 } else .{ -1, 1 };
    app.automation_value = std.math.clamp(app.automation_value, value_range[0], value_range[1]);
    _ = zgui.sliderFloat("Value", .{ .v = &app.automation_value, .min = value_range[0], .max = value_range[1] });
    const points: *[]ws.dsp.automation.AutomationPoint = switch (app.automation_target) {
        .gain => &clip.automation.gain,
        .pan => &clip.automation.pan,
    };
    if (zgui.button("Add / update point", .{})) {
        ws.dsp.automation.setPoint(app.core.allocator, points, app.automation_beat, app.automation_value) catch {};
        app.core.session.rebuildSongData();
    }
    zgui.sameLine(.{});
    if (zgui.button("Delete point", .{})) {
        if (ws.dsp.automation.removePoint(app.core.allocator, points, app.automation_beat)) app.core.session.rebuildSongData();
    }
    zgui.separatorText("Points");
    for (points.*, 0..) |point, i| {
        zgui.text("{d: >2}. beat {d:.2}   value {d:.3}", .{ i + 1, point.beat, point.value });
    }
}

const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const color = style.color;
const umbra = style.umbra;

pub fn draw(app: anytype) void {
    const sampler = switch (app.core.session.racks.items[app.core.cursor].instrument) {
        .sampler => |*s| s,
        else => {
            zgui.textDisabled("Select a Sampler track.", .{});
            return;
        },
    };
    drawHeader(app, sampler);
    zgui.spacing();
    widgets.sectionTitle("SAMPLE WAVEFORM", umbra.cyan);
    if (sampler.pad_lock.tryLock()) {
        defer sampler.pad_lock.unlock();
        widgets.waveform("##sampler-wave", sampler.pad.samples);
    }
    zgui.spacing();

    const gap: f32 = 10;
    const column_w = @max(300, (zgui.getContentRegionAvail()[0] - gap) / 2);
    if (zgui.beginChild("sampler-left", .{ .w = column_w, .h = 0, .child_flags = .{ .border = true } })) {
        widgets.sectionTitle("PLAYBACK", umbra.iris);
        drawParam(app, sampler, 0, "Start", "%.3f");
        drawParam(app, sampler, 1, "End", "%.3f");
        drawParam(app, sampler, 2, "Pitch", "%.0f st");
        drawParam(app, sampler, 10, "Root note", "%.0f");
        zgui.spacing();
        widgets.sectionTitle("MODE", umbra.mauve);
        drawToggle(app, sampler, 9, "REVERSE", "FORWARD");
        zgui.sameLine(.{ .spacing = 6 });
        drawToggle(app, sampler, 11, "MONO", "POLY");
    }
    zgui.endChild();
    zgui.sameLine(.{ .spacing = gap });
    if (zgui.beginChild("sampler-right", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        widgets.sectionTitle("AMPLITUDE ENVELOPE", umbra.yellow);
        drawParam(app, sampler, 3, "Attack", "%.3f s");
        drawParam(app, sampler, 4, "Decay", "%.3f s");
        drawParam(app, sampler, 5, "Sustain", "%.2f");
        drawParam(app, sampler, 6, "Release", "%.3f s");
        zgui.spacing();
        widgets.sectionTitle("OUTPUT", umbra.cyan);
        drawParam(app, sampler, 7, "Gain", "%.1f dB");
        drawParam(app, sampler, 8, "Pan", "%.2f");
    }
    zgui.endChild();
}

fn drawHeader(app: anytype, sampler: *const ws.dsp.Sampler) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 72;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("sampler-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(umbra.iris), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(umbra.fg3), "SAMPLER", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(umbra.fg0), "{s}", .{app.core.session.project.tracks.items[app.core.cursor].name});
    draw_list.addText(.{ origin[0] + width - 310, origin[1] + 12 }, color(umbra.iris), "{s}", .{sampler.clipName()});
    draw_list.addText(.{ origin[0] + width - 310, origin[1] + 39 }, color(umbra.fg3), "{d} SAMPLES  ROOT {d}", .{ sampler.pad.samples.len, sampler.root_note });
}

fn paramRange(id: u8) [2]f32 {
    return switch (id) {
        0, 1, 5, 8, 9, 11 => .{ 0, 1 },
        2 => .{ -48, 48 },
        3, 4 => .{ 0, 5 },
        6 => .{ 0, 10 },
        7 => .{ -60, 12 },
        10 => .{ 0, 127 },
        else => .{ 0, 1 },
    };
}

fn drawParam(app: anytype, sampler: *ws.dsp.Sampler, id: u8, label_text: []const u8, format: [:0]const u8) void {
    var value = sampler.paramValue(id) orelse return;
    const range = paramRange(id);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##sampler-{d}", .{ label_text, id }) catch return;
    const focused = app.core.sampler_param == id;
    style.pushControlFocus(focused, umbra.iris);
    defer style.popControlFocus(focused);
    if (zgui.sliderFloat(label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format })) {
        _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = @intCast(app.core.cursor), .id = id, .value = value } });
    }
    if (zgui.isItemActivated()) app.core.sampler_param = id;
}

fn drawToggle(app: anytype, sampler: *ws.dsp.Sampler, id: u8, on_label: [:0]const u8, off_label: [:0]const u8) void {
    const value = sampler.paramValue(id) orelse return;
    const active = value >= 0.5;
    const focused = app.core.sampler_param == id;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) umbra.iris else if (focused) umbra.bg4 else umbra.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) umbra.bg0 else if (focused) umbra.iris else umbra.fg2 });
    if (zgui.button(if (active) on_label else off_label, .{ .w = 106, .h = 32 })) {
        app.core.sampler_param = id;
        _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = @intCast(app.core.cursor), .id = id, .value = if (active) 0 else 1 } });
    }
    zgui.popStyleColor(.{ .count = 2 });
}

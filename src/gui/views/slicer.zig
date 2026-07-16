const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const step_grid = @import("step_grid.zig");

const color = style.color;
const umbra = style.umbra;

pub fn draw(app: anytype) void {
    const rack = app.core.session.racks.items[app.core.cursor];
    const slicer = switch (rack.instrument) {
        .slicer => |*s| s,
        else => {
            zgui.textDisabled("Select a Slicer track.", .{});
            return;
        },
    };
    drawHeader(app, slicer);
    zgui.spacing();
    widgets.sectionTitle("SOURCE WAVEFORM", umbra.cyan);
    if (slicer.sample_lock.tryLock()) {
        defer slicer.sample_lock.unlock();
        widgets.waveform("##slicer-wave", slicer.samples);
    }
    zgui.spacing();
    widgets.sectionTitle("SLICE SEQUENCE", umbra.iris);
    step_grid.draw(.slicer, slicer, @min(@as(usize, 12), slicer.slice_count), slicer.step_count, null);
}

fn drawHeader(app: anytype, slicer: *const ws.dsp.Slicer) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 72;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("slicer-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(umbra.cyan), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(umbra.fg3), "SAMPLE SLICER", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(umbra.fg0), "{s}", .{app.core.session.project.tracks.items[app.core.cursor].name});
    draw_list.addText(.{ origin[0] + width - 310, origin[1] + 12 }, color(umbra.cyan), "{d} SLICES", .{slicer.slice_count});
    draw_list.addText(.{ origin[0] + width - 190, origin[1] + 12 }, color(umbra.fg1), "{d} STEPS", .{slicer.step_count});
    draw_list.addText(.{ origin[0] + width - 310, origin[1] + 39 }, color(umbra.fg3), "{s}", .{std.mem.trimEnd(u8, &slicer.name, " ")});
}

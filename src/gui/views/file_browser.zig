const std = @import("std");
const zgui = @import("zgui");
const style = @import("../style.zig");

const color = style.color;
const umbra = style.umbra;

pub fn draw(app: anytype) void {
    drawHeader(app);
    zgui.spacing();
    zgui.textDisabled("PROJECT FILES", .{});
    zgui.sameLine(.{});
    zgui.textColored(umbra.fg3, "ENTER OPEN   H PARENT   R REFRESH   ESC BACK", .{});
    zgui.separator();

    if (app.core.browser_entries.items.len == 0) {
        zgui.spacing();
        zgui.textColored(umbra.fg1, "This folder is empty.", .{});
        zgui.textDisabled("Only folders and compatible project files are shown.", .{});
        return;
    }

    if (zgui.beginChild("files", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (app.core.browser_entries.items, 0..) |entry, i| {
            if (drawEntry(entry.name, entry.is_dir, app.core.browser_cursor == i, i)) {
                app.core.browser_cursor = i;
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
        }
    }
    zgui.endChild();
}

fn drawHeader(app: anytype) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 88;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("file-browser-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(umbra.cyan), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(umbra.fg3), "PROJECT BROWSER", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 36 }, color(umbra.fg0), "{s}", .{std.fs.path.basename(app.core.browser_dir)});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 61 }, color(umbra.fg3), "{s}", .{app.core.browser_dir});
    draw_list.addText(.{ origin[0] + width - 130, origin[1] + 13 }, color(umbra.cyan), "{d} ITEMS", .{app.core.browser_entries.items.len});
}

fn drawEntry(name: []const u8, is_dir: bool, selected: bool, index: usize) bool {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 50;
    const origin = zgui.getCursorScreenPos();
    var id_buf: [48]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "browser-entry-{d}", .{index}) catch return false;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();
    const accent = if (is_dir) umbra.cyan else umbra.iris;
    if (selected or hovered) draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height },
        .col = color(if (selected) umbra.bg4 else umbra.bg2),
        .rounding = 3,
    });
    draw_list.addRectFilled(.{ .pmin = .{ origin[0], origin[1] + 8 }, .pmax = .{ origin[0] + 4, origin[1] + height - 8 }, .col = color(accent), .rounding = 2 });
    draw_list.addText(.{ origin[0] + 15, origin[1] + 8 }, color(if (selected) umbra.fg0 else umbra.fg1), "{s}", .{name});
    draw_list.addText(.{ origin[0] + 15, origin[1] + 29 }, color(umbra.fg3), "{s}", .{if (is_dir) "FOLDER" else "WSTUDIO PROJECT"});
    draw_list.addText(.{ origin[0] + width - 28, origin[1] + 15 }, color(accent), "{s}", .{if (is_dir) ">" else "WS"});
    return clicked;
}

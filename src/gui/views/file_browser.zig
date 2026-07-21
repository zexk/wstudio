const std = @import("std");
const zgui = @import("zgui");
const style = @import("../style.zig");

const color = style.color;
const theme = &style.palette;

pub fn draw(app: anytype) void {
    drawHeader(app);
    zgui.spacing();
    zgui.textDisabled("{s}", .{if (app.core.browser_bookmark_mode) "BOOKMARKS" else "FILES"});
    zgui.sameLine(.{});
    zgui.textColored(theme.fg3, "{s}", .{if (app.core.browser_bookmark_mode) "ENTER JUMP   B CLOSE" else "ENTER OPEN   / SEARCH"});
    zgui.separator();

    if (app.core.browser_bookmark_mode) {
        drawBookmarks(app);
        return;
    }

    if (app.core.browser_entries.items.len == 0) {
        zgui.spacing();
        zgui.textColored(theme.fg1, "This directory is empty.", .{});
        zgui.textDisabled("Only directories and files compatible with this operation are shown.", .{});
        return;
    }

    const available = zgui.getContentRegionAvail()[0];
    if (available >= 880) {
        drawBookmarkSidebar(app, 220);
        zgui.sameLine(.{ .spacing = 10 });
    }
    if (zgui.beginChild("files", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        zgui.textDisabled("NAME", .{});
        zgui.sameLine(.{});
        zgui.setCursorPosX(zgui.getContentRegionAvail()[0] - 104);
        zgui.textDisabled("TYPE", .{});
        zgui.separator();
        for (app.core.browser_entries.items, 0..) |entry, i| {
            if (drawEntry(entry.name, entry.is_dir, app.core.browser_cursor == i, i)) {
                app.core.browser_cursor = i;
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
                // handleKey may have just freed/replaced browser_entries
                // (descending into a directory, or closing the browser on a
                // file pick) - the slice this loop is iterating is stale now.
                break;
            }
        }
    }
    zgui.endChild();
}

fn drawBookmarkSidebar(app: anytype, width: f32) void {
    if (zgui.beginChild("bookmark-sidebar", .{ .w = width, .h = -1, .child_flags = .{ .border = true } })) {
        zgui.textColored(theme.audio, "LOCATIONS", .{});
        zgui.separator();
        if (zgui.button("CURRENT DIRECTORY", .{ .w = -1, .h = 32 })) app.core.browserJumpTo(app.core.browser_dir);
        if (std.c.getenv("HOME")) |home_z| {
            if (zgui.button("HOME", .{ .w = -1, .h = 32 })) app.core.browserJumpTo(std.mem.sliceTo(home_z, 0));
        }
        if (app.core.projectPath()) |project_path| {
            const project_dir = std.fs.path.dirname(project_path) orelse ".";
            if (zgui.button("PROJECT", .{ .w = -1, .h = 32 })) app.core.browserJumpTo(project_dir);
        }
        zgui.spacing();
        zgui.textColored(theme.fg2, "BOOKMARKS", .{});
        zgui.separator();
        if (app.core.bookmarks.items.len == 0) {
            zgui.textDisabled("Press b to add this location.", .{});
        } else for (app.core.bookmarks.items, 0..) |bookmark, i| {
            var id_buf: [48]u8 = undefined;
            const label = std.fmt.bufPrintZ(&id_buf, "{s}##bookmark-side-{d}", .{ std.fs.path.basename(bookmark.path), i }) catch continue;
            if (zgui.button(label, .{ .w = -1, .h = 32 })) {
                app.core.browser_bookmark_mode = true;
                app.core.bookmark_cursor = i;
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
        }
    }
    zgui.endChild();
}

fn drawHeader(app: anytype) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 56;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("file-browser-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(theme.audio), .rounding = 3 });
    var purpose_buf: [64]u8 = undefined;
    const purpose = purposeLabel(app.core.browser_purpose, &purpose_buf);
    draw_list.addText(.{ origin[0] + 17, origin[1] + 8 }, color(theme.fg3), "LOCATION", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 31 }, color(theme.fg0), "{s}", .{app.core.browser_dir});
    draw_list.addText(.{ origin[0] + width - 300, origin[1] + 8 }, color(theme.audio), "{s}", .{purpose});
    draw_list.addText(.{ origin[0] + width - 110, origin[1] + 32 }, color(theme.fg2), "{d} ITEMS", .{app.core.browser_entries.items.len});
    const pattern = app.core.searchPattern();
    if (pattern.len > 0) draw_list.addText(.{ origin[0] + width - 300, origin[1] + 32 }, color(theme.modulation), "search: {s}", .{pattern});
}

fn purposeLabel(purpose: anytype, buf: []u8) []const u8 {
    var label_buf: [40]u8 = undefined;
    const label = purpose.label(&label_buf);
    var upper_label_buf: [40]u8 = undefined;
    const upper_label = std.ascii.upperString(upper_label_buf[0..label.len], label);
    var upper_ext_buf: [8]u8 = undefined;
    const ext = purpose.ext();
    const upper_ext = std.ascii.upperString(upper_ext_buf[0..ext.len], ext);
    return std.fmt.bufPrint(buf, "{s}  {s}", .{ upper_label, upper_ext }) catch label;
}

fn drawBookmarks(app: anytype) void {
    if (app.core.bookmarks.items.len == 0) {
        zgui.textDisabled("No bookmarks. Press b on a file or directory to add one.", .{});
        return;
    }
    if (zgui.beginChild("bookmarks", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (app.core.bookmarks.items, 0..) |bookmark, i| {
            if (drawEntry(bookmark.path, bookmark.is_dir, app.core.bookmark_cursor == i, i)) {
                app.core.bookmark_cursor = i;
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
                break;
            }
        }
    }
    zgui.endChild();
}

fn drawEntry(name: []const u8, is_dir: bool, selected: bool, index: usize) bool {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 50;
    const origin = zgui.getCursorScreenPos();
    var id_buf: [48]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "browser-entry-{d}", .{index}) catch return false;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    if (selected) zgui.setScrollHereY(.{});
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();
    const accent = if (is_dir) theme.audio else theme.focus;
    if (selected or hovered) draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height },
        .col = color(if (selected) theme.bg4 else theme.bg2),
        .rounding = 3,
    });
    if (selected) draw_list.addRect(.{ .pmin = .{ origin[0] + 1, origin[1] + 1 }, .pmax = .{ origin[0] + width - 1, origin[1] + height - 1 }, .col = color(theme.focus), .rounding = 3, .thickness = 2 });
    draw_list.addRectFilled(.{ .pmin = .{ origin[0], origin[1] + 8 }, .pmax = .{ origin[0] + 4, origin[1] + height - 8 }, .col = color(accent), .rounding = 2 });
    draw_list.addText(.{ origin[0] + 15, origin[1] + 8 }, color(if (selected) theme.fg0 else theme.fg1), "{s}", .{name});
    const type_label = if (is_dir) "DIRECTORY" else std.fs.path.extension(name);
    draw_list.addText(.{ origin[0] + width - 116, origin[1] + 16 }, color(theme.fg2), "{s}", .{type_label});
    draw_list.addText(.{ origin[0] + width - 28, origin[1] + 15 }, color(accent), "{s}", .{if (is_dir) ">" else "*"});
    return clicked;
}

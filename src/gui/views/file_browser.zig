const std = @import("std");
const zgui = @import("zgui");
const style = @import("../style.zig");

const color = style.color;
const umbra = style.umbra;

pub fn draw(app: anytype) void {
    drawHeader(app);
    zgui.spacing();
    zgui.textDisabled("{s}", .{if (app.core.browser_bookmark_mode) "BOOKMARKS" else "FILES"});
    zgui.sameLine(.{});
    zgui.textColored(umbra.fg3, "{s}", .{if (app.core.browser_bookmark_mode) "ENTER JUMP   D DELETE   B CLOSE" else "ENTER OPEN   H PARENT   B MARK   SHIFT+B BOOKMARKS   / SEARCH"});
    zgui.separator();

    if (app.core.browser_bookmark_mode) {
        drawBookmarks(app);
        return;
    }

    if (app.core.browser_entries.items.len == 0) {
        zgui.spacing();
        zgui.textColored(umbra.fg1, "This folder is empty.", .{});
        zgui.textDisabled("Only folders and files compatible with this operation are shown.", .{});
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
    var purpose_buf: [64]u8 = undefined;
    const purpose = purposeLabel(app.core.browser_purpose, &purpose_buf);
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(umbra.fg3), "FILE BROWSER", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 36 }, color(umbra.fg0), "{s}", .{std.fs.path.basename(app.core.browser_dir)});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 61 }, color(umbra.fg3), "{s}", .{app.core.browser_dir});
    draw_list.addText(.{ origin[0] + width - 300, origin[1] + 13 }, color(umbra.cyan), "{s}", .{purpose});
    draw_list.addText(.{ origin[0] + width - 110, origin[1] + 40 }, color(umbra.fg2), "{d} ITEMS", .{app.core.browser_entries.items.len});
    const pattern = app.core.searchPattern();
    if (pattern.len > 0) draw_list.addText(.{ origin[0] + width - 300, origin[1] + 63 }, color(umbra.mauve), "search: {s}", .{pattern});
}

fn purposeLabel(purpose: anytype, buf: []u8) []const u8 {
    return switch (purpose) {
        .open_project => "OPEN PROJECT  .WSJ",
        .load_sample => "LOAD SAMPLE  .WAV",
        .load_pad => |pad| std.fmt.bufPrint(buf, "LOAD PAD {d}  .WAV", .{pad + 1}) catch "LOAD PAD  .WAV",
        .load_clip => "LOAD CLIP  .WAV",
        .load_slice => "LOAD SLICER CLIP  .WAV",
        .load_wavetable => |slot| std.fmt.bufPrint(buf, "LOAD WAVETABLE OSC {s}  .WAV", .{@tagName(slot)}) catch "LOAD WAVETABLE  .WAV",
    };
}

fn drawBookmarks(app: anytype) void {
    if (app.core.bookmarks.items.len == 0) {
        zgui.textDisabled("No bookmarks. Press b on a file or folder to add one.", .{});
        return;
    }
    if (zgui.beginChild("bookmarks", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (app.core.bookmarks.items, 0..) |bookmark, i| {
            if (drawEntry(bookmark.path, bookmark.is_dir, app.core.bookmark_cursor == i, i)) {
                app.core.bookmark_cursor = i;
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
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
    draw_list.addText(.{ origin[0] + 15, origin[1] + 29 }, color(umbra.fg3), "{s}", .{if (is_dir) "FOLDER" else std.fs.path.extension(name)});
    draw_list.addText(.{ origin[0] + width - 28, origin[1] + 15 }, color(accent), "{s}", .{if (is_dir) ">" else "*"});
    return clicked;
}

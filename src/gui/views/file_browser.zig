const std = @import("std");
const zgui = @import("zgui");
const style = @import("../style.zig");

const color = style.color;
const patina = &style.palette;

pub fn draw(app: anytype) void {
    drawHeader(app);
    zgui.spacing();
    zgui.textDisabled("{s}", .{if (app.core.browser_bookmark_mode) "BOOKMARKS" else "FILES"});
    zgui.sameLine(.{});
    zgui.textColored(patina.fg3, "{s}", .{if (app.core.browser_bookmark_mode) "ENTER JUMP   B CLOSE" else "ENTER OPEN   / SEARCH"});
    zgui.separator();

    if (app.core.browser_bookmark_mode) {
        drawBookmarks(app);
        return;
    }

    if (app.core.browser_entries.items.len == 0) {
        zgui.spacing();
        zgui.textColored(patina.fg1, "This folder is empty.", .{});
        zgui.textDisabled("Only folders and files compatible with this operation are shown.", .{});
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
            }
        }
    }
    zgui.endChild();
}

fn drawBookmarkSidebar(app: anytype, width: f32) void {
    if (zgui.beginChild("bookmark-sidebar", .{ .w = width, .h = -1, .child_flags = .{ .border = true } })) {
        zgui.textColored(patina.audio, "BOOKMARKS", .{});
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
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(patina.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(patina.audio), .rounding = 3 });
    var purpose_buf: [64]u8 = undefined;
    const purpose = purposeLabel(app.core.browser_purpose, &purpose_buf);
    draw_list.addText(.{ origin[0] + 17, origin[1] + 8 }, color(patina.fg3), "LOCATION", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 31 }, color(patina.fg0), "{s}", .{app.core.browser_dir});
    draw_list.addText(.{ origin[0] + width - 300, origin[1] + 8 }, color(patina.audio), "{s}", .{purpose});
    draw_list.addText(.{ origin[0] + width - 110, origin[1] + 32 }, color(patina.fg2), "{d} ITEMS", .{app.core.browser_entries.items.len});
    const pattern = app.core.searchPattern();
    if (pattern.len > 0) draw_list.addText(.{ origin[0] + width - 300, origin[1] + 32 }, color(patina.modulation), "search: {s}", .{pattern});
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
    const accent = if (is_dir) patina.audio else patina.focus;
    if (selected or hovered) draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height },
        .col = color(if (selected) patina.bg4 else patina.bg2),
        .rounding = 3,
    });
    if (selected) draw_list.addRect(.{ .pmin = .{ origin[0] + 1, origin[1] + 1 }, .pmax = .{ origin[0] + width - 1, origin[1] + height - 1 }, .col = color(patina.focus), .rounding = 3, .thickness = 2 });
    draw_list.addRectFilled(.{ .pmin = .{ origin[0], origin[1] + 8 }, .pmax = .{ origin[0] + 4, origin[1] + height - 8 }, .col = color(accent), .rounding = 2 });
    draw_list.addText(.{ origin[0] + 15, origin[1] + 8 }, color(if (selected) patina.fg0 else patina.fg1), "{s}", .{name});
    const type_label = if (is_dir) "FOLDER" else std.fs.path.extension(name);
    draw_list.addText(.{ origin[0] + width - 116, origin[1] + 16 }, color(patina.fg2), "{s}", .{type_label});
    draw_list.addText(.{ origin[0] + width - 28, origin[1] + 15 }, color(accent), "{s}", .{if (is_dir) ">" else "*"});
    return clicked;
}

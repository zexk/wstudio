const std = @import("std");
const zgui = @import("zgui");
const picker = @import("picker.zig");
const style = @import("../style.zig");

const theme = &style.palette;
const color = style.color;

pub fn draw(app: anytype) void {
    if (app.core.browser_bookmark_mode) {
        zgui.textColored(theme.audio, "BOOKMARKS", .{});
        zgui.separator();
        drawBookmarks(app);
        return;
    }

    var purpose_buf: [64]u8 = undefined;
    zgui.textColored(theme.audio, "BROWSE", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("{s}", .{purposeLabel(app.core.browser_purpose, &purpose_buf)});
    const pattern = app.core.searchPattern();
    if (pattern.len > 0) {
        zgui.sameLine(.{ .spacing = 14 });
        zgui.textColored(theme.modulation, "search: {s}", .{pattern});
    }
    zgui.textDisabled("{s}", .{app.core.browser_dir});
    zgui.separator();

    if (app.core.browser_entries.items.len == 0) {
        zgui.textDisabled("(empty)", .{});
        return;
    }

    if (zgui.beginChild("files", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (app.core.browser_entries.items, 0..) |entry, i| {
            if (drawEntry(entry.name, entry.is_dir, app.core.browser_cursor == i, i, pattern)) {
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

fn purposeLabel(purpose: anytype, buf: []u8) []const u8 {
    var label_buf: [40]u8 = undefined;
    const label = purpose.label(&label_buf);
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ label, purpose.ext() }) catch label;
}

fn drawBookmarks(app: anytype) void {
    if (app.core.bookmarks.items.len == 0) {
        zgui.textDisabled("(no bookmarks)", .{});
        return;
    }
    if (zgui.beginChild("bookmarks", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (app.core.bookmarks.items, 0..) |bookmark, i| {
            if (drawEntry(bookmark.path, bookmark.is_dir, app.core.bookmark_cursor == i, i, "")) {
                app.core.bookmark_cursor = i;
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
                break;
            }
        }
    }
    zgui.endChild();
}

fn drawEntry(name: []const u8, is_dir: bool, selected: bool, index: usize, filter: []const u8) bool {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 24;
    const origin = zgui.getCursorScreenPos();
    var id_buf: [48]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "browser-entry-{d}", .{index}) catch return false;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    if (selected) zgui.setScrollHereY(.{});
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();
    if (selected or hovered) draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height },
        .col = color(if (selected) theme.bg4 else theme.bg2),
        .rounding = 3,
    });
    // Hover paints a fill too - without this the cursor row and a hovered
    // row read the same.
    if (selected) draw_list.addRect(.{
        .pmin = .{ origin[0] + 1, origin[1] + 1 },
        .pmax = .{ origin[0] + width - 1, origin[1] + height - 1 },
        .col = color(theme.focus),
        .rounding = 3,
        .thickness = 1,
    });
    // Trailing "/" marks directories, same as the TUI listing.
    var name_buf: [512]u8 = undefined;
    const shown = if (is_dir) std.fmt.bufPrint(&name_buf, "{s}/", .{name}) catch name else name;
    // Same match highlight the TUI browser paints in reverse video: the `/`
    // search only moves the cursor, so without it there's nothing showing
    // *why* a row matched.
    picker.drawFuzzyLabel(draw_list, .{ origin[0] + 8, origin[1] + 4 }, shown, filter, theme.modulation, if (selected) theme.fg0 else theme.fg1);
    return clicked;
}

//! The file browser, drawn as a Telescope-style overlay like every other
//! picker (see `picker.beginOverlay`): it is a modal "choose one of these
//! rows" list over whatever view opened it, not a workspace of its own. The
//! panel frame, backdrop, scroll clipping and row width all come from the
//! shared overlay, so this file only emits the heading and the rows.

const std = @import("std");
const zgui = @import("zgui");
const picker = @import("picker.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const theme = &style.palette;
const color = style.color;

pub fn draw(app: anytype) void {
    if (app.core.browser_bookmark_mode) {
        zgui.textColored(theme.audio, "BOOKMARKS", .{});
        zgui.separator();
        zgui.textDisabled("j/k move   enter open   d delete   esc close", .{});
        zgui.spacing();
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
    zgui.textDisabled("/ search   j/k move   enter open   v select   - up   m mark   esc close", .{});
    zgui.spacing();

    if (app.core.browser_entries.items.len == 0) {
        zgui.textDisabled("(empty)", .{});
        return;
    }

    // Visual mode: an inclusive index range over the listing, outlined like
    // the tracks view outlines its own visual rows. Directories inside the
    // range stay unmarked - loadPadsFromEntries skips them.
    const anchor = app.core.browser_visual_anchor;
    const sel_lo = @min(anchor orelse 0, app.core.browser_cursor);
    const sel_hi = @max(anchor orelse 0, app.core.browser_cursor);

    for (app.core.browser_entries.items, 0..) |entry, i| {
        const in_visual = anchor != null and i >= sel_lo and i <= sel_hi and !entry.is_dir;
        if (drawEntry(entry.name, entry.is_dir, app.core.browser_cursor == i, in_visual, i, pattern)) {
            app.core.browser_cursor = i;
            app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            // handleKey may have just freed/replaced browser_entries
            // (descending into a directory, or closing the browser on a
            // file pick) - the slice this loop is iterating is stale now.
            break;
        }
    }
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
    for (app.core.bookmarks.items, 0..) |bookmark, i| {
        if (drawEntry(bookmark.path, bookmark.is_dir, app.core.bookmark_cursor == i, false, i, "")) {
            app.core.bookmark_cursor = i;
            app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            break;
        }
    }
}

fn drawEntry(name: []const u8, is_dir: bool, selected: bool, in_visual: bool, index: usize, filter: []const u8) bool {
    const width = picker.overlayWidth();
    const height: f32 = 24;
    const origin = zgui.getCursorScreenPos();
    var id_buf: [48]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "browser-entry-{d}", .{index}) catch return false;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    // Pager-style, not `setScrollHereY`: re-centring every frame would pin
    // the list to the cursor and leave the wheel with nothing to do.
    widgets.noteFocusRow(selected, origin[1], height);
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();
    if (selected or hovered or in_visual) draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height },
        .col = color(if (selected) theme.bg4 else theme.bg2),
        .rounding = style.item_rounding,
    });
    // Hover paints a fill too - without this the cursor row and a hovered
    // row read the same. A visual-range row gets the fg0 outline the tracks
    // view already uses for its own visual rows.
    if (selected or in_visual) draw_list.addRect(.{
        .pmin = .{ origin[0] + 1, origin[1] + 1 },
        .pmax = .{ origin[0] + width - 1, origin[1] + height - 1 },
        .col = color(if (selected) theme.focus else theme.fg0),
        .rounding = style.item_rounding,
        .thickness = if (in_visual and !selected) 2 else 1,
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

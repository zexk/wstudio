//! Minimal netrw/dired-style file browser view: lists the current directory,
//! `j`/`k` move, `enter`/`l` descend or pick, `h`/backspace go up. See
//! `App.openBrowser`/`App.handleBrowserKey` for the input side.

const std = @import("std");
const app_mod = @import("../../ui/app.zig");
const style = @import("../style.zig");
const fuzzy = @import("../../ui/fuzzy.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const sel = style.sel;
const endLine = style.endLine;

fn purposeLabel(purpose: app_mod.BrowserPurpose, buf: []u8) []const u8 {
    var label_buf: [40]u8 = undefined;
    const label = purpose.label(&label_buf);
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ label, purpose.ext() }) catch label;
}

pub fn drawFileBrowser(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    if (app.browser_bookmark_mode) return drawBookmarkList(app, w, rows);

    var label_buf: [32]u8 = undefined;
    try w.writeAll(bold ++ " BROWSE" ++ rst);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(acc);
    try w.writeAll(purposeLabel(app.browser_purpose, &label_buf));
    try w.writeAll(rst);
    try endLine(w);
    try w.writeAll(dim);
    try w.writeAll(app.browser_dir);
    try w.writeAll(rst);
    try endLine(w);

    const entries = app.browser_entries.items;
    const body = rows -| 6; // 2 lines above + the caller's header/transport/status (4)
    const visible = @max(body, 1);
    if (entries.len == 0) {
        try w.writeAll(dim ++ "  (empty)" ++ rst);
        try endLine(w);
        for (1..visible) |_| try endLine(w);
        return;
    }

    if (app.browser_cursor < app.browser_scroll) app.browser_scroll = app.browser_cursor;
    if (app.browser_cursor >= app.browser_scroll + visible)
        app.browser_scroll = app.browser_cursor - visible + 1;
    const off = app.browser_scroll;
    const end = @min(off + visible, entries.len);

    const pattern = app.searchPattern();
    for (entries[off..end], off..) |entry, i| {
        const is_sel = i == app.browser_cursor;
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try writeHighlighted(w, entry.name, pattern, is_sel);
        if (entry.is_dir) try w.writeAll("/");
        try w.writeAll(rst);
        try endLine(w);
    }
    for (end - off..visible) |_| try endLine(w);
}

/// Writes `name`, reverse-video highlighting the bytes the last `/` search
/// pattern matched (see App.searchPattern). On the already-reverse-video
/// selected row, `sel` would be invisible against itself, so matched bytes
/// get `bold` instead and the row's `sel` is re-applied after each one.
fn writeHighlighted(w: *std.Io.Writer, name: []const u8, pattern: []const u8, row_selected: bool) !void {
    // zig fmt: off
    if (pattern.len == 0) { try w.writeAll(name); return; }
    // zig fmt: on
    var match_buf: [128]bool = undefined;
    const checked = name[0..@min(name.len, match_buf.len)];
    fuzzy.matchPositions(pattern, checked, match_buf[0..checked.len]);
    for (name, 0..) |c, i| {
        const hl = i < checked.len and match_buf[i];
        if (hl) try w.writeAll(if (row_selected) bold else sel);
        try w.writeByte(c);
        if (hl) {
            try w.writeAll(rst);
            if (row_selected) try w.writeAll(sel);
        }
    }
}

/// `B`'s overlay: the bookmark list in place of the directory listing, same
/// visual layout as drawFileBrowser's own list (see App.handleBookmarkListKey
/// for the input side).
fn drawBookmarkList(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    try w.writeAll(bold ++ " BOOKMARKS" ++ rst);
    try endLine(w);
    try w.writeAll(dim ++ "persisted in ~/.config/wstudio/bookmarks.json" ++ rst);
    try endLine(w);

    const marks = app.bookmarks.items;
    const body = rows -| 6; // 2 lines above + the caller's header/transport/status (4)
    const visible = @max(body, 1);
    if (marks.len == 0) {
        try w.writeAll(dim ++ "  (no bookmarks)" ++ rst);
        try endLine(w);
        for (1..visible) |_| try endLine(w);
        return;
    }

    if (app.bookmark_cursor < app.bookmark_scroll) app.bookmark_scroll = app.bookmark_cursor;
    if (app.bookmark_cursor >= app.bookmark_scroll + visible)
        app.bookmark_scroll = app.bookmark_cursor - visible + 1;
    const off = app.bookmark_scroll;
    const end = @min(off + visible, marks.len);

    for (marks[off..end], off..) |bm, i| {
        const is_sel = i == app.bookmark_cursor;
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.writeAll(bm.path);
        if (bm.is_dir) try w.writeAll("/");
        try w.writeAll(rst);
        try endLine(w);
    }
    for (end - off..visible) |_| try endLine(w);
}

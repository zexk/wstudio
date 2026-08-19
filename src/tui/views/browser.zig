//! Minimal netrw/dired-style file browser view: lists the current directory,
//! `j`/`k` move, `enter`/`l` descend or pick, `h`/backspace go up. See
//! `App.openBrowser`/`App.handleBrowserKey` for the input side.

const std = @import("std");
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const sel = style.sel;
const yel = style.yel;
const endLine = style.endLine;

pub fn drawFileBrowser(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize) !void {
    if (app.browser_recent_mode) return drawRecentProjects(app, w, rows, cols);
    if (app.browser_bookmark_mode) return drawBookmarkList(app, w, rows, cols);

    var label_buf: [32]u8 = undefined;
    try w.writeAll(" ");
    try w.writeAll(icons.iconOr(icons.browse ++ " ", ""));
    try w.writeAll(bold ++ "BROWSE" ++ rst);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(acc);
    try w.writeAll(app.browser_purpose.displayLabel(&label_buf));
    try w.writeAll(rst);
    // The pickers echo their filter here; the browser echoes its search for
    // the same reason - the highlight alone doesn't say what was typed.
    if (app.searchPattern().len > 0) {
        try w.writeAll(yel);
        try w.print("  /{s}", .{app.searchPattern()});
        try w.writeAll(rst);
    }
    try endLine(w);
    // Paths are the one thing here with no length bound at all, so every
    // row holding one goes through the clamp: a deep directory would
    // otherwise wrap and push the listing down a line per entry.
    try w.writeAll(dim);
    try style.writeClamped(w, app.browser_dir, cols);
    try endLine(w);

    const entries = app.browser_entries.items;
    const body = rows -| 6; // 2 lines above + the caller's header/transport/status (4)
    const visible = @max(body, 1);
    if (entries.len == 0) {
        try w.writeAll(dim ++ "  NO FILES" ++ rst);
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
    // Visual mode: an inclusive index range over the listing, marked the
    // same way the tracks view marks its own row selection (`~` + yel).
    // Directories inside the range never light up - loadPadsFromEntries
    // skips them, so showing them as selected would be a lie.
    const sel_anchor = app.browser_visual_anchor orelse app.browser_cursor;
    const sel_lo = @min(sel_anchor, app.browser_cursor);
    const sel_hi = @max(sel_anchor, app.browser_cursor);

    for (entries[off..end], off..) |entry, i| {
        const is_sel = i == app.browser_cursor;
        const in_sel = app.browser_visual_anchor != null and i >= sel_lo and i <= sel_hi and !entry.is_dir;
        if (is_sel) try w.writeAll(sel) else if (in_sel) try w.writeAll(yel);
        try w.writeAll(if (is_sel) "  > " else if (in_sel) "  ~ " else "    ");
        var row_buf: [1024]u8 = undefined;
        var row_w = std.Io.Writer.fixed(&row_buf);
        try style.writeHighlighted(&row_w, entry.name, pattern, if (is_sel) bold else sel, if (is_sel) sel else "", 0);
        if (entry.is_dir) try row_w.writeAll("/");
        try style.writeClamped(w, row_w.buffered(), cols -| 4);
        try endLine(w);
    }
    for (end - off..visible) |_| try endLine(w);
}

fn drawRecentProjects(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize) !void {
    try w.writeAll(" ");
    try w.writeAll(icons.iconOr(icons.recent ++ " ", ""));
    try w.writeAll(bold ++ "RECENT PROJECTS" ++ rst);
    try endLine(w);
    try w.writeAll(dim ++ "opened projects appear here" ++ rst);
    try endLine(w);
    const visible = @max(rows -| 6, 1);
    if (app.recent_project_cursor < app.recent_project_scroll) app.recent_project_scroll = app.recent_project_cursor;
    if (app.recent_project_cursor >= app.recent_project_scroll + visible)
        app.recent_project_scroll = app.recent_project_cursor - visible + 1;
    const off = app.recent_project_scroll;
    const end = @min(off + visible, app.recent_projects.items.len);
    if (app.recent_projects.items.len == 0) {
        try w.writeAll(dim ++ "  NO RECENT PROJECTS" ++ rst);
        try endLine(w);
    }
    for (app.recent_projects.items[off..end], off..) |path, i| {
        const is_sel = i == app.recent_project_cursor;
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try style.writeClamped(w, path, cols -| 4);
        try endLine(w);
    }
    for ((end - off) + @intFromBool(app.recent_projects.items.len == 0)..visible) |_| try endLine(w);
}

/// `B`'s overlay: the bookmark list in place of the directory listing, same
/// visual layout as drawFileBrowser's own list (see App.handleBookmarkListKey
/// for the input side).
fn drawBookmarkList(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize) !void {
    try w.writeAll(" ");
    try w.writeAll(icons.iconOr(icons.bookmark ++ " ", ""));
    try w.writeAll(bold ++ "BOOKMARKS" ++ rst);
    try endLine(w);
    try w.writeAll(dim ++ "b marks current path" ++ rst);
    try endLine(w);

    const marks = app.bookmarks.items;
    const body = rows -| 6; // 2 lines above + the caller's header/transport/status (4)
    const visible = @max(body, 1);
    if (marks.len == 0) {
        try w.writeAll(dim ++ "  NO BOOKMARKS" ++ rst);
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
        try style.writeClamped(w, bm.path, cols -| 5);
        if (bm.is_dir) try w.writeAll("/");
        try w.writeAll(rst);
        try endLine(w);
    }
    for (end - off..visible) |_| try endLine(w);
}

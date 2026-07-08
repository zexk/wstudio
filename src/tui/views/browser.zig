//! Minimal netrw/dired-style file browser view: lists the current directory,
//! `j`/`k` move, `enter`/`l` descend or pick, `h`/backspace go up. See
//! `App.openBrowser`/`App.handleBrowserKey` for the input side.

const std = @import("std");
const ws = @import("wstudio");
const app_mod = @import("../app.zig");
const style = @import("../style.zig");
const cmd_mod = @import("../cmd.zig");
const fuzzy = @import("../fuzzy.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const sel = style.sel;
const endLine = style.endLine;

fn purposeLabel(purpose: app_mod.BrowserPurpose, buf: []u8) []const u8 {
    return switch (purpose) {
        .open_project => "open project (.wsj)",
        .load_sample => "load sample (.wav)",
        .load_pad => |pad| std.fmt.bufPrint(buf, "load pad {d} (.wav)", .{pad}) catch "load pad (.wav)",
        .load_clip => "load clip (.wav)",
    };
}

pub fn drawFileBrowser(app: anytype, w: *std.Io.Writer, rows: usize) !void {
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
    const body = rows -| 7; // 2 lines above + the frame's 5 (header/hr/transport/hr/status)
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
    if (pattern.len == 0) { try w.writeAll(name); return; }
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

pub fn drawFileBrowserStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.modal.mode == .search) {
        try cmd_mod.writeSearchPrompt(w, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor);
        return;
    }
    try w.writeAll(" j/k: move   enter/l: open   h/backspace: up   ~: home   /: search   esc/q: cancel");
}

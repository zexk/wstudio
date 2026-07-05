//! Minimal netrw/dired-style file browser view: lists the current directory,
//! `j`/`k` move, `enter`/`l` descend or pick, `h`/backspace go up. See
//! `App.openBrowser`/`App.handleBrowserKey` for the input side.

const std = @import("std");
const ws = @import("wstudio");
const app_mod = @import("../app.zig");
const style = @import("../style.zig");
const cmd_mod = @import("../cmd.zig");

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
    const body = rows -| 4; // header (2 lines) + rule + status, roughly
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

    for (entries[off..end], off..) |entry, i| {
        const is_sel = i == app.browser_cursor;
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.writeAll(entry.name);
        if (entry.is_dir) try w.writeAll("/");
        try w.writeAll(rst);
        try endLine(w);
    }
    for (end - off..visible) |_| try endLine(w);
}

pub fn drawFileBrowserStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.modal.mode == .search) {
        try cmd_mod.writeSearchPrompt(w, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor);
        return;
    }
    try w.writeAll(" j/k: move   enter/l: open   h/backspace: up   ~: home   /: search   esc/q: cancel");
}

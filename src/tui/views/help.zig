//! Help view (scrollable command/keybinding reference). The content model -
//! sections, text build, scroll targets, search - lives in ui/help.zig;
//! this file only renders a scroll window of it.

const std = @import("std");
const ws = @import("wstudio");
const cmd_mod = @import("../../ui/cmd.zig");
const config_mod = @import("../../config.zig");
const help_model = @import("../../ui/help.zig");
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const sel = style.sel;
const endLine = style.endLine;

// Re-exported so callers (app.zig, commands.zig, tui.zig) keep addressing
// the help model through this view for now.
pub const Section = help_model.Section;
pub const scrollForSection = help_model.scrollForSection;
pub const search = help_model.search;
const HelpText = help_model.HelpText;
const buildHelp = help_model.buildHelp;

/// Write `line` in full-line reverse video: `sel` up front, re-asserted
/// after every embedded reset so the line's interior styling can't switch
/// the highlight back off partway through. endLine's trailing `rst` closes it.
fn writeHighlighted(w: *std.Io.Writer, line: []const u8) !void {
    try w.writeAll(sel);
    var rest = line;
    while (std.mem.indexOf(u8, rest, rst)) |p| {
        try w.writeAll(rest[0 .. p + rst.len]);
        try w.writeAll(sel);
        rest = rest[p + rst.len ..];
    }
    try w.writeAll(rest);
}

/// Renders a scroll window of the help text. `scroll` is clamped in place so
/// the caller's stored offset can never run past the last screenful. `hit`
/// (the last `/` search match, if any) renders reverse-video when in view.
pub fn drawHelp(w: *std.Io.Writer, rows: usize, cols: usize, cmds: []const cmd_mod.Def, keymaps: []const config_mod.Keymap, scroll: *usize, hit: ?usize) !void {
    var t = HelpText{};
    buildHelp(&t, cmds, keymaps);

    const body = rows -| 4; // lines available below the caller's header, above transport/status
    const visible = body -| 1; // one row reserved for the sticky title
    const max_scroll = t.count -| visible;
    if (scroll.* > max_scroll) scroll.* = max_scroll;
    const off = scroll.*;
    const end = @min(off + visible, t.count);

    // Sticky title with a position indicator.
    try w.writeAll(bold ++ " " ++ icons.help ++ " HELP" ++ rst);
    try w.writeAll(dim ++ "   esc: close   j/k: scroll   /: search");
    if (t.count > visible) {
        try w.print("   {d}–{d}/{d}", .{ off + 1, end, t.count });
        if (off < max_scroll) try w.writeAll("  ↓");
        if (off > 0) try w.writeAll("  ↑");
    }
    try endLine(w);

    var i = off;
    while (i < end) : (i += 1) {
        if (hit == i) {
            var line_buf: [1024]u8 = undefined;
            var line_w = std.Io.Writer.fixed(&line_buf);
            try writeHighlighted(&line_w, t.line(i));
            try style.writeClamped(w, line_w.buffered(), cols);
        } else try style.writeClamped(w, t.line(i), cols);
        try endLine(w);
    }

    // Pad any remaining body rows so short windows don't leave stale content.
    for (1 + (end - off)..body) |_| try endLine(w);
}

test {
    _ = help_model;
}

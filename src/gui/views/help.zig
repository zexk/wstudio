//! Help view: the live keyboard/command reference, rendered from
//! `ui/help.zig`'s shared `HelpText` model - the same command table + user
//! keymaps the TUI's drawHelp reads - instead of a hand-kept, easily stale
//! row list. `j/k/d/u`
//! and `/` search are already wired generically in `ui/app.zig` (they just
//! move `help_scroll`/`help_search_hit`); this file only has to render the
//! window those fields point at.

const std = @import("std");
const zgui = @import("zgui");
const help_model = @import("../../ui/help.zig");
const ansi = @import("../../ui/ansi.zig");
const style = @import("../style.zig");

const theme = &style.palette;

pub fn draw(app: anytype) void {
    drawReference(app);
}

fn drawReference(app: anytype) void {
    var t = help_model.HelpText{};
    help_model.buildHelp(&t, app.core.allCmds(), app.core.userKeymapsSlice());
    if (t.count == 0) return;

    const line_h: f32 = 20;
    const header_h: f32 = 26;
    const body_h = @max(200, zgui.getContentRegionAvail()[1] - header_h);
    const visible: usize = @intFromFloat(@max(1.0, body_h / line_h));
    const max_scroll = t.count -| visible;
    if (app.core.help_scroll > max_scroll) app.core.help_scroll = max_scroll;
    const off = app.core.help_scroll;
    const end = @min(off + visible, t.count);

    zgui.textColored(theme.modulation, "REFERENCE", .{});
    zgui.sameLine(.{ .spacing = 12 });
    zgui.textDisabled("esc: close   j/k/d/u: scroll   /: search   {d}-{d}/{d}", .{ off + 1, end, t.count });
    zgui.separator();

    if (zgui.beginChild("help-reference-body", .{ .w = 0, .h = body_h })) {
        var i = off;
        while (i < end) : (i += 1) drawLine(app, t.line(i), i);
    }
    zgui.endChild();
}

/// Classifies one already-ANSI-formatted help line by which of
/// `ui/help.zig`'s three row builders (`section`/`group`/`key`) produced
/// it, and renders the GUI equivalent of that styling - same shared text,
/// a GUI-appropriate paint instead of terminal SGR codes.
fn drawLine(app: anytype, raw: []const u8, index: usize) void {
    if (raw.len == 0) {
        zgui.spacing();
        return;
    }
    const hit = if (app.core.help_search_hit) |h| h == index else false;
    const text_color = if (hit) theme.focus else theme.fg1;
    var buf: [512]u8 = undefined;

    if (std.mem.startsWith(u8, raw, ansi.bold)) {
        zgui.spacing();
        zgui.textColored(if (hit) theme.focus else theme.modulation, "{s}", .{ansi.stripAnsi(raw, &buf)});
        return;
    }
    if (std.mem.startsWith(u8, raw, ansi.dim)) {
        zgui.textColored(if (hit) theme.focus else theme.fg3, "{s}", .{ansi.stripAnsi(raw, &buf)});
        return;
    }
    // A `key()` row: accent-colored key text, `rst`, then dim description.
    var key_buf: [64]u8 = undefined;
    var desc_buf: [448]u8 = undefined;
    const split = std.mem.indexOf(u8, raw, ansi.rst) orelse raw.len;
    const key_text = ansi.stripAnsi(raw[0..split], &key_buf);
    const desc_text = if (split < raw.len) ansi.stripAnsi(raw[split + ansi.rst.len ..], &desc_buf) else "";
    const padded_key = std.fmt.bufPrint(&buf, "{s: <18}", .{key_text}) catch key_text;
    zgui.textColored(if (hit) theme.focus else theme.audio, "{s}", .{padded_key});
    zgui.sameLine(.{ .spacing = 4 });
    zgui.textColored(text_color, "{s}", .{desc_text});
}

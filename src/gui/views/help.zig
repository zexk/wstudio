//! Help view: a short header/launcher strip over the live keyboard/command
//! reference. The reference itself is rendered from `ui/help.zig`'s shared
//! `HelpText` model - the same command table + user keymaps the TUI's
//! drawHelp reads - instead of a hand-kept, easily stale row list. `j/k/d/u`
//! and `/` search are already wired generically in `ui/app.zig` (they just
//! move `help_scroll`/`help_search_hit`); this file only has to render the
//! window those fields point at.

const std = @import("std");
const zgui = @import("zgui");
const help_model = @import("../../ui/help.zig");
const ansi = @import("../../ui/ansi.zig");
const style = @import("../style.zig");

const color = style.color;
const patina = &style.palette;

pub fn draw(app: anytype) void {
    drawHeader();
    zgui.spacing();
    drawLaunchers(app);
    zgui.spacing();
    drawReference(app);
}

fn drawHeader() void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 72;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("help-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(patina.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(patina.modulation), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(patina.fg3), "WSTUDIO REFERENCE", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(patina.fg0), "Keyboard first, mouse friendly", .{});
    draw_list.addText(.{ origin[0] + width - 180, origin[1] + 27 }, color(patina.modulation), "VIM MODAL WORKFLOW", .{});
}

/// Faster mouse-driven paths to views also reachable by keybind (enter on a
/// blank track, `:preset`, tab to the file browser) - additive, not a
/// second source of truth for what those views contain.
fn drawLaunchers(app: anytype) void {
    zgui.textDisabled("QUICK OPEN", .{});
    zgui.separator();
    zgui.pushStyleColor4f(.{ .idx = .button, .c = patina.focus_soft });
    if (zgui.button("INSTRUMENTS", .{ .h = 34 })) app.openPicker(.instrument_picker);
    zgui.popStyleColor(.{});
    zgui.sameLine(.{ .spacing = 6 });
    if (zgui.button("PRESETS", .{ .h = 34 })) app.openPicker(.preset_picker);
    zgui.sameLine(.{ .spacing = 6 });
    if (zgui.button("PROJECTS", .{ .h = 34 })) app.core.view = .file_browser;
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

    zgui.textColored(patina.modulation, "REFERENCE", .{});
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
    const text_color = if (hit) patina.focus else patina.fg1;
    var buf: [512]u8 = undefined;

    if (std.mem.startsWith(u8, raw, ansi.bold)) {
        zgui.spacing();
        zgui.textColored(if (hit) patina.focus else patina.modulation, "{s}", .{ansi.stripAnsi(raw, &buf)});
        return;
    }
    if (std.mem.startsWith(u8, raw, ansi.dim)) {
        zgui.textColored(if (hit) patina.focus else patina.fg3, "{s}", .{ansi.stripAnsi(raw, &buf)});
        return;
    }
    // A `key()` row: accent-colored key text, `rst`, then dim description.
    var key_buf: [64]u8 = undefined;
    var desc_buf: [448]u8 = undefined;
    const split = std.mem.indexOf(u8, raw, ansi.rst) orelse raw.len;
    const key_text = ansi.stripAnsi(raw[0..split], &key_buf);
    const desc_text = if (split < raw.len) ansi.stripAnsi(raw[split + ansi.rst.len ..], &desc_buf) else "";
    const padded_key = std.fmt.bufPrint(&buf, "{s: <18}", .{key_text}) catch key_text;
    zgui.textColored(if (hit) patina.focus else patina.audio, "{s}", .{padded_key});
    zgui.sameLine(.{ .spacing = 4 });
    zgui.textColored(text_color, "{s}", .{desc_text});
}

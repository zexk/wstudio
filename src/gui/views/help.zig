//! Help view: the live keyboard/command reference, rendered from
//! `ui/help.zig`'s shared `HelpText` model - the same command table + user
//! keymaps the TUI's drawHelp reads - instead of a hand-kept, easily stale
//! row list. `j/k/d/u`, `{`/`}` and `/` search are already wired generically
//! in `ui/app.zig` (they just move `help_scroll`/`help_search_hit`); this
//! file only has to render the window those fields point at.
//!
//! Rows are painted straight onto the draw list at a fixed `line_h` pitch
//! rather than flowed as ImGui text: the model is a flat line list with a
//! caller-owned scroll offset, so every row has to occupy exactly the height
//! the viewport math assumed, and the key column has to line up under a
//! proportional font (space padding does not).

const std = @import("std");
const zgui = @import("zgui");
const help_model = @import("../../ui/help.zig");
const widgets = @import("../widgets.zig");
const ansi = @import("../../ui/ansi.zig");
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");

const theme = &style.palette;
const color = style.color;

/// Width of the section-nav column, and the x where a key row's description
/// starts (a wider key chip pushes its own description past it).
const nav_w: f32 = 208;
/// Below this workspace width the nav column costs more room than it earns,
/// so the body gets everything (the `{`/`}` jumps still work).
const nav_min_width: f32 = 720;
const desc_col: f32 = 176;
const row_pad: f32 = 12;

pub fn draw(app: anytype) void {
    var t = help_model.HelpText{};
    help_model.buildHelp(&t, app.core.allCmds(), app.core.userKeymapsSlice());
    if (t.count == 0) return;

    // Measured, not the hardcoded 20 this used to assume: at the default
    // font a line is 24px, so the window claimed ~35 lines fit where 30 did
    // and the body overflowed its child.
    const line_h = @max(1.0, zgui.getTextLineHeightWithSpacing());
    const header_h: f32 = 34;
    const body_h = @max(200, zgui.getContentRegionAvail()[1] - header_h);
    const visible: usize = @intFromFloat(@max(1.0, body_h / line_h));
    var viewport = help_model.viewport(t.count, visible, &app.core.help_scroll);

    // The wheel scrolls the same `help_scroll` window `j`/`k` do. Claim it
    // before ImGui can: this body renders a fixed slice of lines rather than
    // the whole text, so an ImGui scrollbar here would slide the slice
    // around under a line counter that knows nothing about it - two scroll
    // positions for one view, and `j` snapping back to the other one.
    if (style.wheel_delta != 0) {
        style.wheel_consumed = true;
        const step: isize = if (style.modDown()) 10 else 3;
        const delta: isize = if (style.wheel_delta > 0) -step else step;
        const next = @as(isize, @intCast(app.core.help_scroll)) + delta;
        app.core.help_scroll = @intCast(std.math.clamp(next, 0, @as(isize, @intCast(viewport.max_scroll))));
        viewport = help_model.viewport(t.count, visible, &app.core.help_scroll);
    }

    // The line one past the top is what the reader is actually looking at:
    // a section jump parks the scroll on the blank spacer above the title.
    const anchor = @min(viewport.off + 1, t.count - 1);
    const current_section = t.sectionLineAt(anchor);

    drawHeader(&t, viewport, current_section);
    if (zgui.getContentRegionAvail()[0] >= nav_min_width) {
        drawNav(app, &t, current_section, body_h, line_h);
        zgui.sameLine(.{ .spacing = 10 });
    }
    drawBody(app, &t, viewport, body_h, line_h);
}

fn drawHeader(t: *const help_model.HelpText, viewport: help_model.Viewport, current_section: ?usize) void {
    widgets.coloredTitle(theme.modulation, icons.help ++ "  HELP", .{});
    if (current_section) |s| {
        zgui.sameLine(.{ .spacing = 10 });
        zgui.textColored(theme.audio, "{s}", .{shortTitle(help_model.sectionTitle(t.line(s)))});
    }
    zgui.sameLine(.{ .spacing = 16 });
    widgets.hoverHelp("j/k scroll  d/u page  { } section  / search  esc close");
    zgui.sameLine(.{ .spacing = 16 });
    zgui.textDisabled("{d}-{d}/{d}", .{ viewport.off + 1, viewport.end, t.count });
    zgui.separator();
}

/// Clickable table of contents. Every section the model emits is listed, so
/// what the reference covers is visible at a glance instead of only
/// discoverable by scrolling 500 lines past it.
fn drawNav(app: anytype, t: *const help_model.HelpText, current_section: ?usize, body_h: f32, line_h: f32) void {
    if (!zgui.beginChild("help-nav", .{ .w = nav_w, .h = body_h, .child_flags = .{ .border = true } })) {
        zgui.endChild();
        return;
    }
    const draw_list = zgui.getWindowDrawList();
    const width = zgui.getContentRegionAvail()[0];
    const pad = (line_h - zgui.getTextLineHeight()) / 2;

    var next = t.sectionLineAt(0);
    while (next) |s| : (next = t.nextSectionLine(s)) {
        const origin = zgui.getCursorScreenPos();
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "help-nav-{d}", .{s}) catch continue;
        const clicked = zgui.invisibleButton(id, .{ .w = width, .h = line_h });
        const hovered = zgui.isItemHovered(.{});
        const active = current_section == s;
        if (active or hovered) draw_list.addRectFilled(.{
            .pmin = origin,
            .pmax = .{ origin[0] + width, origin[1] + line_h },
            .col = color(if (active) theme.bg3 else theme.bg2),
            .rounding = style.item_rounding,
        });
        if (active) draw_list.addRectFilled(.{
            .pmin = origin,
            .pmax = .{ origin[0] + 3, origin[1] + line_h },
            .col = color(theme.focus),
        });
        draw_list.addText(
            .{ origin[0] + 10, origin[1] + pad },
            color(if (active) theme.fg0 else theme.fg2),
            "{s}",
            .{navLabel(help_model.sectionTitle(t.line(s)))},
        );
        // The spacer above the title, matching `scrollForSection`, so a
        // clicked section reads the same as one `?` jumped to.
        if (clicked) app.core.help_scroll = s -| 1;
    }
    zgui.endChild();
}

fn drawBody(app: anytype, t: *const help_model.HelpText, viewport: help_model.Viewport, body_h: f32, line_h: f32) void {
    if (!zgui.beginChild("help-reference-body", .{
        .w = 0,
        .h = body_h,
        .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true },
    })) {
        zgui.endChild();
        return;
    }
    const draw_list = zgui.getWindowDrawList();
    const origin = zgui.getCursorScreenPos();
    const width = zgui.getContentRegionAvail()[0];
    var i = viewport.off;
    while (i < viewport.end) : (i += 1) {
        const y = origin[1] + @as(f32, @floatFromInt(i - viewport.off)) * line_h;
        const hit = if (app.core.help_search_hit) |h| h == i else false;
        drawRow(draw_list, t.line(i), .{ .x = origin[0], .y = y, .w = width - 12, .h = line_h, .hit = hit });
    }
    drawPositionBar(draw_list, origin, width, body_h, t.count, viewport);
    zgui.endChild();
}

/// The body paints a fixed slice of the line list, so ImGui's own scrollbar
/// has nothing to measure (and is switched off, see the wheel comment in
/// `draw`). This is the missing "how far in am I" cue drawn by hand.
fn drawPositionBar(draw_list: zgui.DrawList, origin: [2]f32, width: f32, body_h: f32, count: usize, viewport: help_model.Viewport) void {
    if (viewport.max_scroll == 0) return;
    const total: f32 = @floatFromInt(count);
    const shown: f32 = @floatFromInt(viewport.end - viewport.off);
    const x = origin[0] + width - 6;
    draw_list.addRectFilled(.{
        .pmin = .{ x, origin[1] },
        .pmax = .{ x + 4, origin[1] + body_h },
        .col = color(theme.bg2),
        .rounding = style.item_rounding,
    });
    const thumb_h = @max(24, body_h * shown / total);
    const travel = body_h - thumb_h;
    const y = origin[1] + travel * @as(f32, @floatFromInt(viewport.off)) / @as(f32, @floatFromInt(viewport.max_scroll));
    draw_list.addRectFilled(.{
        .pmin = .{ x, y },
        .pmax = .{ x + 4, y + thumb_h },
        .col = color(theme.focus_soft),
        .rounding = style.item_rounding,
    });
}

const Row = struct { x: f32, y: f32, w: f32, h: f32, hit: bool };

/// Classifies one already-ANSI-formatted help line by which of
/// `ui/help.zig`'s row builders (`section`/`group`/`key`) produced it, and
/// paints the GUI equivalent of that styling - same shared text, a
/// GUI-appropriate treatment instead of terminal SGR codes.
fn drawRow(draw_list: zgui.DrawList, raw: []const u8, row: Row) void {
    if (raw.len == 0) return;
    const pad = (row.h - zgui.getTextLineHeight()) / 2;
    var buf: [512]u8 = undefined;

    if (row.hit) draw_list.addRectFilled(.{
        .pmin = .{ row.x, row.y },
        .pmax = .{ row.x + row.w, row.y + row.h },
        .col = color(.{ theme.focus[0], theme.focus[1], theme.focus[2], 0.28 }),
        .rounding = style.item_rounding,
    });

    if (help_model.isSectionLine(raw)) {
        const title = help_model.sectionTitle(raw);
        if (!row.hit) draw_list.addRectFilled(.{
            .pmin = .{ row.x, row.y },
            .pmax = .{ row.x + row.w, row.y + row.h },
            .col = color(theme.bg2),
            .rounding = style.item_rounding,
        });
        draw_list.addRectFilled(.{
            .pmin = .{ row.x, row.y },
            .pmax = .{ row.x + 3, row.y + row.h },
            .col = color(theme.modulation),
        });
        draw_list.addText(.{ row.x + row_pad, row.y + pad }, color(theme.modulation), "{s}", .{title});
        return;
    }

    // `group` headings and the few free-standing prose rows share the dim
    // prefix; a heading is the all-caps one, and earns a rule out to the
    // right margin so it reads as a divider rather than another sentence.
    if (std.mem.startsWith(u8, raw, ansi.dim)) {
        const text = std.mem.trimStart(u8, ansi.stripAnsi(raw, &buf), " ");
        const heading = isHeading(text);
        const x = if (heading) row.x + row_pad else row.x + desc_col;
        const tone = if (row.hit) theme.fg0 else if (heading) theme.fg2 else theme.fg3;
        draw_list.addText(.{ x, row.y + pad }, color(tone), "{s}", .{text});
        if (heading) {
            const rule_x = x + zgui.calcTextSize(text, .{})[0] + 10;
            const mid = row.y + row.h / 2;
            draw_list.addLine(.{ .p1 = .{ rule_x, mid }, .p2 = .{ row.x + row.w, mid }, .col = color(theme.line), .thickness = 1 });
        }
        return;
    }

    // A `key()` row: the keys, then `rst`, then the description. The keys
    // get a chip so the eye can scan the left column without reading it.
    var key_buf: [64]u8 = undefined;
    var desc_buf: [448]u8 = undefined;
    const split = std.mem.indexOf(u8, raw, ansi.rst) orelse raw.len;
    const keys = std.mem.trim(u8, ansi.stripAnsi(raw[0..split], &key_buf), " ");
    const desc = std.mem.trimStart(u8, if (split < raw.len) ansi.stripAnsi(raw[split + ansi.rst.len ..], &desc_buf) else "", " ");
    var desc_x = row.x + desc_col;
    if (keys.len > 0) {
        const key_w = zgui.calcTextSize(keys, .{})[0];
        draw_list.addRectFilled(.{
            .pmin = .{ row.x + row_pad, row.y + 1 },
            .pmax = .{ row.x + row_pad + key_w + 16, row.y + row.h - 1 },
            .col = color(theme.bg2),
            .rounding = style.item_rounding,
        });
        draw_list.addText(.{ row.x + row_pad + 8, row.y + pad }, color(theme.audio), "{s}", .{keys});
        desc_x = @max(desc_x, row.x + row_pad + key_w + 26);
    }
    // A key-less row is a continuation of the one above it (the model
    // indents those); keeping it dim stops it reading as its own binding.
    const desc_tone = if (row.hit) theme.fg0 else if (keys.len > 0) theme.fg1 else theme.fg3;
    draw_list.addText(.{ desc_x, row.y + pad }, color(desc_tone), "{s}", .{desc});
}

/// Section titles carry a parenthetical gloss ("FX CHAIN  (same chain view
/// for a track...)"); the nav column and header want just the name.
fn shortTitle(title: []const u8) []const u8 {
    const cut = std.mem.indexOf(u8, title, "  (") orelse return title;
    return title[0..cut];
}

/// Nav labels also drop the " EDITOR" suffix - the column is one word wide,
/// and "ACOUSTIC / SOUNDFONT EDITOR" is the one title that overruns it.
fn navLabel(title: []const u8) []const u8 {
    const short = shortTitle(title);
    return if (std.mem.endsWith(u8, short, " EDITOR")) short[0 .. short.len - " EDITOR".len] else short;
}

fn isHeading(text: []const u8) bool {
    for (text) |c| if (std.ascii.isLower(c)) return false;
    return true;
}

test "short titles drop the parenthetical gloss" {
    try std.testing.expectEqualStrings("FX CHAIN", shortTitle("FX CHAIN  (same chain view for a track)"));
    try std.testing.expectEqualStrings("TRACKS", shortTitle("TRACKS"));
}

test "nav labels drop the editor suffix, keep single-word titles" {
    try std.testing.expectEqualStrings("ACOUSTIC / SOUNDFONT", navLabel("ACOUSTIC / SOUNDFONT EDITOR"));
    try std.testing.expectEqualStrings("PIANO ROLL", navLabel("PIANO ROLL"));
    try std.testing.expectEqualStrings("FX CHAIN", navLabel("FX CHAIN  (same chain view for a track)"));
}

test "headings are the all-caps dim rows, prose is not" {
    try std.testing.expect(isHeading("ORGANIZE AND MIX"));
    try std.testing.expect(!isHeading("cells: [x] plain, (x) tuned"));
}

//! Shared TUI palette and primitive output helpers. Lives apart from the view
//! renderers (views/*.zig) and the facade (tui.zig) so both can import it
//! without a cycle.

const std = @import("std");
const ws = @import("wstudio");
const ansi = @import("../ui/ansi.zig");
const types = ws.types;
const Mode = ws.input.Mode;


// The SGR palette lives in ui/ansi.zig (shared with the GUI's strip-and-
// re-render path); re-exported here so TUI code keeps saying `style.acc`.
pub const rst = ansi.rst;
pub const bold = ansi.bold;
pub const dim = ansi.dim;
pub const acc = ansi.acc;
pub const grn = ansi.grn;
pub const yel = ansi.yel;
pub const red = ansi.red;
pub const sel = ansi.sel;
pub const blu = ansi.blu;
pub const mag = ansi.mag;
pub const bcyn = ansi.bcyn;
pub const bwht = ansi.bwht;
pub const track_palette = ansi.track_palette;
pub const track_color_names = ansi.track_color_names;
pub const stripAnsi = ansi.stripAnsi;
pub const endLine = ansi.endLine;

/// Background counterparts of the three mode colours (SGR 40-47), used only
/// by the status-line mode badge below - everywhere else in the TUI gets
/// its block look from `sel` (reverse video) instead, since that adapts to
/// whatever the terminal's real background is. The badge needs a literal
/// background code (reverse video would work fine here too, actually, but
/// this keeps the badge's look independent of whatever `sel` is doing
/// elsewhere on the same row).
const bg_grn = "\x1b[42m";
const bg_yel = "\x1b[43m";
const bg_mag = "\x1b[45m";
const bg_cyn = "\x1b[46m";
/// Bold black text reads cleanly on all three badge background colours
/// above (they're all ANSI "normal" intensity, so black-on-them has good
/// contrast regardless of the terminal's light/dark theme).
const badge_fg = "\x1b[30m" ++ bold;

fn modeBadgeBg(mode: Mode) []const u8 {
    return switch (mode) {
        .normal => bg_grn,
        .insert => bg_yel,
        .visual => bg_mag,
        // The `:`/`/` prompt itself lives on its own row now (see
        // App.draw's prompt row) - the status row still shows a badge,
        // cyan so both ends of the row visibly flag "you're typing".
        .command, .search => bg_cyn,
    };
}

fn modeBadgeLetter(mode: Mode) []const u8 {
    return switch (mode) {
        .normal => "N",
        .insert => "I",
        .visual => "V",
        .command => "C",
        .search => "S",
    };
}

// ---------------------------------------------------------------------------
// Primitive helpers
// ---------------------------------------------------------------------------

pub fn hr(w: *std.Io.Writer, cols: u16) !void {
    try w.writeAll(dim);
    for (0..@min(cols, 200)) |_| try w.writeAll("─");
    try endLine(w);
}

/// SGR prefix for one step-grid cell - the same cursor > playhead >
/// selection > active precedence in the drum and slicer grids, so the two
/// views can't drift apart on step colors (their glyphs stay bespoke).
pub fn stepCellSgr(active: bool, is_cursor: bool, is_play: bool, in_sel: bool) []const u8 {
    if (is_cursor) return sel;
    if (is_play) return grn ++ bold;
    if (in_sel) return if (active) yel ++ bold else yel;
    if (active) return acc;
    return dim;
}

/// Renders `raw` (may contain ANSI SGR sequences) as a header/transport
/// row: content clamped to `cols`, no fill (a reverse-video fill read as
/// a stray highlighted bar; see docs/ui-conventions.md).
pub fn writeChromeRow(w: *std.Io.Writer, raw: []const u8, cols: u16) !void {
    try writeClamped(w, raw, cols);
    try endLine(w);
}

/// Writes the lualine-style mode badge: a single letter (N/I/V, plus C/S
/// for command/search) on a colour-coded background, deliberately with no
/// divider glyph or second chip (docs/ui-conventions.md has the design
/// story). Callers print the view name and status content as plain text
/// right after. The `:`/`/` prompt renders on its own row (App.draw), so
/// the status row stays informative while typing.
pub fn writeModeBadge(w: *std.Io.Writer, mode: Mode) !void {
    try w.writeAll(modeBadgeBg(mode));
    try w.writeAll(badge_fg);
    try w.print(" {s} ", .{modeBadgeLetter(mode)});
    try w.writeAll(rst);
}

/// Right-edge view-name chip, matching writeModeBadge's look (solid colour
/// block, bold black text) so the status row's two ends read as a pair.
/// Shares the mode badge's background colour rather than a fixed hue, so
/// both ends of the row visibly change together when the mode changes.
/// `tone` covers callers whose chip doubles as a state flag instead of the
/// mode (the arrangement's SONG/PATTERN toggle keeps its own green/yellow
/// regardless of mode).
pub const BadgeTone = enum { cyan, green, yellow };

pub fn writeViewBadge(w: *std.Io.Writer, name: []const u8, mode: Mode) !void {
    try w.writeAll(modeBadgeBg(mode));
    try w.writeAll(badge_fg);
    try w.print(" {s} ", .{name});
    try w.writeAll(rst);
}

pub fn writeViewBadgeColored(w: *std.Io.Writer, name: []const u8, tone: BadgeTone) !void {
    try w.writeAll(switch (tone) {
        // zig fmt: off
        .cyan => bg_cyn, .green => bg_grn, .yellow => bg_yel,
        // zig fmt: on
    });
    try w.writeAll(badge_fg);
    try w.print(" {s} ", .{name});
    try w.writeAll(rst);
}

/// Visible column width of `raw` (may contain ANSI SGR sequences): escapes
/// cost nothing, everything else counts as one column per UTF-8 lead byte.
/// Shared by writeClamped (left content) and writeSplitRow (both sides).
fn visibleWidth(raw: []const u8) usize {
    var i: usize = 0;
    var col: usize = 0;
    while (i < raw.len) {
        if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '[') {
            i += 2;
            while (i < raw.len and !((raw[i] >= 'A' and raw[i] <= 'Z') or (raw[i] >= 'a' and raw[i] <= 'z'))) : (i += 1) {}
            if (i < raw.len) i += 1;
            continue;
        }
        if (raw[i] & 0xC0 != 0x80) col += 1;
        i += 1;
    }
    return col;
}

/// Write `raw` (a single line, no \r\n, may contain ANSI SGR sequences) to
/// `w`, clamped to `max_cols` visible columns. ANSI escapes are copied
/// through verbatim (they cost no width); everything else counts as one
/// column per UTF-8 lead byte. Footer status lines are built from several
/// independent `w.print` calls with no shared width budget, so a verbose
/// status message can silently overflow past the terminal's right edge and
/// wrap onto a new row - which pushes the whole frame down by one line and
/// scrolls the header off the top. This is the guard against that.
pub fn writeClamped(w: *std.Io.Writer, raw: []const u8, max_cols: usize) !void {
    var i: usize = 0;
    var col: usize = 0;
    while (i < raw.len) {
        if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '[') {
            const start = i;
            i += 2;
            while (i < raw.len and !((raw[i] >= 'A' and raw[i] <= 'Z') or (raw[i] >= 'a' and raw[i] <= 'z'))) : (i += 1) {}
            if (i < raw.len) i += 1; // include the terminator letter
            try w.writeAll(raw[start..i]);
            continue;
        }
        if (col >= max_cols) break;
        if (raw[i] & 0xC0 != 0x80) col += 1; // UTF-8 continuation bytes are free
        try w.writeByte(raw[i]);
        i += 1;
    }
    try w.writeAll(rst);
}

/// Writes `left` then right-aligns `right` flush against `cols` (padding
/// the gap between them with spaces) - the lualine "sections" look: mode/
/// position info reading left-to-right, identity info (current view, L/R
/// meters) pinned to the right edge instead of trailing wherever the left
/// content happens to end. Both `left` and `right` may contain ANSI SGR
/// sequences. If they'd collide (combined width leaves no gap), `right` is
/// dropped and `left` is clamped instead - same "truncate rather than
/// corrupt" rule writeClamped already follows, so a narrow terminal loses
/// the right-aligned extra before it loses the primary content.
pub fn writeSplitRow(w: *std.Io.Writer, left: []const u8, right: []const u8, cols: usize) !void {
    const left_w = visibleWidth(left);
    const right_w = visibleWidth(right);
    if (right_w == 0 or left_w + 1 + right_w > cols) {
        try writeClamped(w, left, cols);
        return;
    }
    try w.writeAll(left);
    try w.writeAll(rst);
    try w.splatByteAll(' ', cols - left_w - right_w);
    try w.writeAll(right);
    try w.writeAll(rst);
}

/// writeClamped, then pad with spaces out to exactly `width` visible
/// columns - the building block for side-by-side column layouts (the synth
/// editor's wide two-column mode zips lines through this).
pub fn writePadded(w: *std.Io.Writer, raw: []const u8, width: usize) !void {
    try writeClamped(w, raw, width);
    const vw = visibleWidth(raw);
    if (vw < width) try w.splatByteAll(' ', width - vw);
}

pub fn meter(w: *std.Io.Writer, peak: f32) !void {
    const cells = 10;
    const db = types.gainToDb(peak);
    const norm = std.math.clamp((db + 50.0) / 50.0, 0.0, 1.0);
    const filled: usize = @intFromFloat(norm * cells);
    const colour: []const u8 = if (db >= 0.0) red else if (db >= -6.0) yel else grn;
    try w.writeAll(colour);
    try w.writeByte('[');
    for (0..cells) |i| try w.writeAll(if (i < filled) "█" else "░");
    try w.writeByte(']');
    try w.writeAll(rst);
}

// ---------------------------------------------------------------------------
// Form-row primitives - shared by the synth and sampler editors
// ---------------------------------------------------------------------------

pub const form_bar_w_default: usize = 18;
pub const form_section_w_default: usize = 42;
/// Width knobs for the form-row primitives below (synthBar's cell count and
/// synthSection's fill width). App.draw resets both to the compact defaults
/// at the top of every frame; wide-layout views then opt in for that frame
/// only - so no view ever inherits another view's widths.
pub var form_bar_w: usize = form_bar_w_default;
pub var form_section_w: usize = form_section_w_default;

/// Smooth horizontal level bar. `color` tints the filled portion; the track is
/// always dim. Fractional fill is rendered with a partial block for the last
/// cell so small changes are visible.
pub fn synthBar(w: *std.Io.Writer, value: f32, max_val: f32, is_sel: bool, color: []const u8) !void {
    const bar_w: usize = form_bar_w;
    const frac = std.math.clamp(value / max_val, 0.0, 1.0) * @as(f32, @floatFromInt(bar_w));
    const full: usize = @intFromFloat(@floor(frac));
    const rem = frac - @floor(frac);
    // U+258F..U+2589 - 1/8 .. 7/8 left blocks.
    const eighths = [_][]const u8{ "", "\u{258F}", "\u{258E}", "\u{258D}", "\u{258C}", "\u{258B}", "\u{258A}", "\u{2589}" };
    const e: usize = @intFromFloat(rem * 8.0);
    const has_part = full < bar_w and e > 0;

    try w.writeAll(dim);
    try w.writeByte('[');
    try w.writeAll(rst);
    // filled cells
    try w.writeAll(color);
    if (is_sel) try w.writeAll(bold);
    for (0..full) |_| try w.writeAll("\u{2588}");
    if (has_part) try w.writeAll(eighths[std.math.clamp(e, 1, 7)]);
    try w.writeAll(rst);
    // empty track
    try w.writeAll(dim);
    const used = full + @as(usize, if (has_part) 1 else 0);
    for (used..bar_w) |_| try w.writeAll("\u{2591}");
    try w.writeByte(']');
    try w.writeAll(rst);
}

/// Colored section divider: `▌ LABEL ─────────` filling to a fixed width.
pub fn synthSection(w: *std.Io.Writer, label: []const u8, color: []const u8) !void {
    try w.writeAll("  ");
    try w.writeAll(color);
    try w.writeAll(bold);
    try w.writeAll("\u{258C} ");
    try w.writeAll(label);
    try w.writeByte(' ');
    try w.writeAll(rst);
    try w.writeAll(dim);
    const used = 5 + label.len; // "  " + "▌ " + label + " "
    const total = form_section_w;
    if (used < total) for (used..total) |_| try w.writeAll("\u{2500}");
    try endLine(w);
}

/// Left gutter + padded label. Selected rows get a bright `▸` cursor; inactive
/// (dimmed) rows are rendered dim.
pub fn rowHead(w: *std.Io.Writer, is_sel: bool, dimmed: bool, label: []const u8) !void {
    if (is_sel) {
        try w.writeAll(bcyn);
        try w.writeAll(bold);
        try w.print("\u{25B8} {s: <9}", .{label});
        try w.writeAll(rst);
    } else if (dimmed) {
        try w.writeAll(dim);
        try w.print("  {s: <9}", .{label});
        try w.writeAll(rst);
    } else {
        try w.print("  {s: <9}", .{label});
    }
}

/// Trailing value readout, brightened when selected, dimmed when inactive.
pub fn rowVal(w: *std.Io.Writer, is_sel: bool, dimmed: bool, s: []const u8) !void {
    try w.writeAll("  ");
    if (is_sel) {
        try w.writeAll(bwht);
        try w.writeAll(bold);
        try w.writeAll(s);
        try w.writeAll(rst);
    } else if (dimmed) {
        try w.writeAll(dim);
        try w.writeAll(s);
        try w.writeAll(rst);
    } else {
        try w.writeAll(s);
    }
}

/// One bar parameter row: `▸ label  [bar]  value`.
pub fn barRow(
    w: *std.Io.Writer,
    is_sel: bool,
    dimmed: bool,
    color: []const u8,
    label: []const u8,
    value: f32,
    max_val: f32,
    val_str: []const u8,
) !void {
    try rowHead(w, is_sel, dimmed, label);
    try w.writeByte(' ');
    const bc = if (is_sel) bcyn else if (dimmed) dim else color;
    try synthBar(w, value, max_val, is_sel, bc);
    try rowVal(w, is_sel, dimmed, val_str);
    try endLine(w);
}

/// One enum/toggle row: label followed by bracketed options, the active one
/// highlighted in the section color (bright when the row is selected).
pub fn enumRow(
    w: *std.Io.Writer,
    is_sel: bool,
    dimmed: bool,
    color: []const u8,
    label: []const u8,
    names: []const []const u8,
    idx: usize,
) !void {
    try rowHead(w, is_sel, dimmed, label);
    try w.writeByte(' ');
    for (names, 0..) |nm, i| {
        if (i == idx) {
            try w.writeAll(if (is_sel) bcyn else if (dimmed) dim else color);
            try w.writeAll(bold);
            try w.print("[{s: <5}]", .{nm});
            try w.writeAll(rst);
        } else {
            try w.writeAll(dim);
            try w.print(" {s: <5} ", .{nm});
            try w.writeAll(rst);
        }
    }
    try endLine(w);
}

test "writeChromeRow leaves short content unpadded, no reverse-video fill" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeChromeRow(&w, bold ++ "hi" ++ rst, 10);
    const out = w.buffered();

    // Original content survives untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, bold ++ "hi" ++ rst) != null);
    // No fill of any kind past the content.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") == null);
    // Ends the line like any other row (\x1b[K erases any leftover from the
    // previous frame instead of a fill covering it).
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[K\r\n"));
}

test "writeChromeRow doesn't overflow when content already fills the row" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeChromeRow(&w, "0123456789", 10);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[K\r\n"));
}

test "writeChromeRow truncates content wider than the row instead of overflowing" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeChromeRow(&w, "0123456789ABCDEF", 10);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "0123456789") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ABCDEF") == null);
}

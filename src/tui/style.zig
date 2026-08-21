//! Shared TUI palette and primitive output helpers. Lives apart from the view
//! renderers (views/*.zig) and the facade (tui.zig) so both can import it
//! without a cycle.

const std = @import("std");
const ws = @import("wstudio");
const ansi = @import("../ui/ansi.zig");
const fuzzy = @import("../ui/fuzzy.zig");
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
pub const bmag = ansi.bmag;
pub const bwht = ansi.bwht;
pub const track_palette = ansi.track_palette;
pub const track_color_names = ansi.track_color_names;
pub const stripAnsi = ansi.stripAnsi;
pub const endLine = ansi.endLine;

/// One accent per FX family, shared by picker and editor.
pub fn fxKindColor(kind: ws.FxKind) []const u8 {
    return switch (kind) {
        .gate, .comp, .mb_comp, .ott, .limiter, .transient_shaper, .expander, .clipper => yel,
        .eq, .filter, .crossover, .utility, .stereo_width => grn,
        .sat, .amp, .crush, .tape => mag,
        .chorus, .flanger, .phaser, .freq_shift, .pitch_shift, .auto_pan => bcyn,
        .delay, .reverb => blu,
        .clap, .vst3 => acc,
    };
}

test "FX families share TUI accents" {
    try std.testing.expectEqualStrings(fxKindColor(.gate), fxKindColor(.limiter));
    try std.testing.expectEqualStrings(fxKindColor(.eq), fxKindColor(.crossover));
    try std.testing.expectEqualStrings(fxKindColor(.sat), fxKindColor(.tape));
    try std.testing.expectEqualStrings(fxKindColor(.chorus), fxKindColor(.phaser));
    try std.testing.expectEqualStrings(fxKindColor(.delay), fxKindColor(.reverb));
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
pub fn stepCellSgr(active: bool, is_cursor: bool, is_play: bool, in_sel: bool, in_edit: bool) []const u8 {
    if (is_cursor) return sel;
    if (is_play) return grn ++ bold;
    if (in_sel) {
        const c = if (in_edit) mag else yel;
        return if (active) c ++ bold else c;
    }
    if (active) return acc;
    return dim;
}

/// Stable tint for choke groups across drum and slicer grids.
pub fn chokeGroupColor(group: u8) []const u8 {
    const colors = [_][]const u8{ yel, mag, blu, red };
    return if (group == 0) dim else colors[(group - 1) % colors.len];
}

test "choke groups share TUI accents" {
    try std.testing.expectEqualStrings(dim, chokeGroupColor(0));
    try std.testing.expectEqualStrings(chokeGroupColor(1), chokeGroupColor(5));
}

/// Renders `raw` (may contain ANSI SGR sequences) as a header/transport
/// row: content clamped to `cols`, no fill (a reverse-video fill read as
/// a stray highlighted bar; see docs/ui-conventions.md).
pub fn writeChromeRow(w: *std.Io.Writer, raw: []const u8, cols: u16) !void {
    try writeClamped(w, raw, cols);
    try endLine(w);
}

pub const writeModeBadge = ansi.writeModeBadge;
pub const BadgeTone = ansi.BadgeTone;
pub const writeViewBadge = ansi.writeViewBadge;
pub const writeViewBadgeColored = ansi.writeViewBadgeColored;

/// Display width of one codepoint: 0 for combining marks and the zero-width
/// selectors, 2 for the East Asian Wide/Fullwidth and emoji blocks, 1 for
/// everything else. Deliberately a range table and not a Unicode database:
/// the private use area (ui/icons.zig) has to stay one column, and the
/// blocks below are the ones a sample filename or a preset name carries.
pub fn charWidth(cp: u21) usize {
    // zig fmt: off
    const zero = [_][2]u21{
        .{ 0x0300, 0x036F }, .{ 0x1AB0, 0x1AFF }, .{ 0x1DC0, 0x1DFF },
        .{ 0x200B, 0x200F }, .{ 0x20D0, 0x20FF }, .{ 0xFE00, 0xFE0F },
        .{ 0xFE20, 0xFE2F },
    };
    const wide = [_][2]u21{
        .{ 0x1100, 0x115F },  .{ 0x2E80, 0x303E },  .{ 0x3041, 0x33FF },
        .{ 0x3400, 0x4DBF },  .{ 0x4E00, 0x9FFF },  .{ 0xA000, 0xA4CF },
        .{ 0xAC00, 0xD7A3 },  .{ 0xF900, 0xFAFF },  .{ 0xFE30, 0xFE6F },
        .{ 0xFF00, 0xFF60 },  .{ 0xFFE0, 0xFFE6 },  .{ 0x1F300, 0x1F64F },
        .{ 0x1F680, 0x1F6FF }, .{ 0x1F900, 0x1F9FF }, .{ 0x20000, 0x3FFFD },
    };
    // zig fmt: on
    for (zero) |r| if (cp >= r[0] and cp <= r[1]) return 0;
    for (wide) |r| if (cp >= r[0] and cp <= r[1]) return 2;
    return 1;
}

/// One step through `raw`: how many bytes the next chunk spans and how many
/// columns it advances the cursor. An SGR escape is a zero-width chunk; an
/// invalid byte counts as one column and one byte, so a mangled name still
/// truncates instead of looping. The single place that walks a row, so
/// visibleWidth and writeClamped cannot disagree about where the edge is.
fn nextCell(raw: []const u8, i: usize) struct { len: usize, width: usize } {
    if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '[') {
        var j = i + 2;
        while (j < raw.len and !((raw[j] >= 'A' and raw[j] <= 'Z') or (raw[j] >= 'a' and raw[j] <= 'z'))) : (j += 1) {}
        if (j < raw.len) j += 1; // include the terminator letter
        return .{ .len = j - i, .width = 0 };
    }
    const len = std.unicode.utf8ByteSequenceLength(raw[i]) catch return .{ .len = 1, .width = 1 };
    if (i + len > raw.len) return .{ .len = 1, .width = 1 };
    const cp = std.unicode.utf8Decode(raw[i..][0..len]) catch return .{ .len = 1, .width = 1 };
    return .{ .len = len, .width = charWidth(cp) };
}

/// Visible column width of `raw` (may contain ANSI SGR sequences): escapes
/// cost nothing, everything else costs what the terminal advances by.
/// Shared by writeClamped (left content) and writeSplitRow (both sides).
pub fn visibleWidth(raw: []const u8) usize {
    var i: usize = 0;
    var col: usize = 0;
    while (i < raw.len) {
        const cell = nextCell(raw, i);
        col += cell.width;
        i += cell.len;
    }
    return col;
}

/// Write `raw` (a single line, no \r\n, may contain ANSI SGR sequences) to
/// `w`, clamped to `max_cols` visible columns. ANSI escapes are copied
/// through verbatim (they cost no width); everything else costs the columns
/// the terminal advances by. Footer status lines are built from several
/// independent `w.print` calls with no shared width budget, so a verbose
/// status message can silently overflow past the terminal's right edge and
/// wrap onto a new row - which pushes the whole frame down by one line and
/// scrolls the header off the top. This is the guard against that.
pub fn writeClamped(w: *std.Io.Writer, raw: []const u8, max_cols: usize) !void {
    var i: usize = 0;
    var col: usize = 0;
    while (i < raw.len) {
        const cell = nextCell(raw, i);
        // A whole codepoint at a time: stopping inside one would emit half a
        // glyph. A wide glyph straddling the right edge is dropped entirely -
        // half of one is a different glyph, not a narrower one.
        if (cell.width > 0 and col + cell.width > max_cols) break;
        try w.writeAll(raw[i..][0..cell.len]);
        col += cell.width;
        i += cell.len;
    }
    try w.writeAll(rst);
}

/// Writes `text` highlighting the bytes the `/` pattern fuzzy-matched (see
/// ui/fuzzy.zig), then pads with spaces to `pad_to` columns so it can stand
/// in for a `{s: <n}` field. `hl` is the SGR the matched bytes get,
/// `restore` the row's own SGR - re-applied after every matched run, since
/// ending one needs a reset and that would otherwise drop a coloured or
/// reverse-video row back to plain mid-word. Every list that takes a `/`
/// shows its matches this way: the browser, both pickers, presets, params.
pub fn writeHighlighted(
    w: *std.Io.Writer,
    text: []const u8,
    pattern: []const u8,
    hl: []const u8,
    restore: []const u8,
    pad_to: usize,
) !void {
    if (pattern.len == 0) {
        try w.writeAll(text);
    } else {
        var match_buf: [128]bool = undefined;
        const checked = text[0..@min(text.len, match_buf.len)];
        fuzzy.matchPositions(pattern, checked, match_buf[0..checked.len]);
        for (text, 0..) |c, i| {
            const on = i < checked.len and match_buf[i];
            if (on) try w.writeAll(hl);
            try w.writeByte(c);
            if (on) {
                try w.writeAll(rst);
                try w.writeAll(restore);
            }
        }
    }
    for (0..pad_to -| visibleWidth(text)) |_| try w.writeByte(' ');
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

test "wide glyphs cost two columns and never straddle the clamp" {
    // A CJK name in a gutter used to measure one column per codepoint, so the
    // row it sat in overflowed the terminal by its own width.
    try std.testing.expectEqual(@as(usize, 6), visibleWidth("音楽室"));
    try std.testing.expectEqual(@as(usize, 3), visibleWidth("\x1b[31mabc\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("e\u{0301}"));

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // 5 columns is two full glyphs; the third would straddle the edge.
    try writeClamped(&w, "音楽室", 5);
    try std.testing.expectEqualStrings("音楽" ++ rst, w.buffered());

    var pad_buf: [64]u8 = undefined;
    var pw = std.Io.Writer.fixed(&pad_buf);
    try writePadded(&pw, "音楽室", 8);
    try std.testing.expectEqual(@as(usize, 8), visibleWidth(pw.buffered()));
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
    return synthSectionIcon(w, "", label, color);
}

/// `synthSection` with a leading icon. `icon` is one cell wide (the bundled
/// font is the Mono variant) but several bytes, so it is counted separately
/// from `label` - measuring the whole heading by byte length would eat three
/// dashes off the divider.
pub fn synthSectionIcon(w: *std.Io.Writer, icon: []const u8, label: []const u8, color: []const u8) !void {
    try w.writeAll("  ");
    try w.writeAll(color);
    try w.writeAll(bold);
    try w.writeAll("\u{258C} ");
    if (icon.len > 0) {
        try w.writeAll(icon);
        try w.writeByte(' ');
    }
    try w.writeAll(label);
    try w.writeByte(' ');
    try w.writeAll(rst);
    try w.writeAll(dim);
    const used = 5 + label.len + @as(usize, if (icon.len > 0) 2 else 0); // "  " + "▌ " + icon + label + " "
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

/// One enum row: label followed by bracketed options, the active one
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

/// One binary-state row: compact current-state chip instead of two enum
/// choices. Mirrors GUI pill switches and keeps booleans distinct from lists.
pub fn toggleRow(w: *std.Io.Writer, is_sel: bool, dimmed: bool, color: []const u8, label: []const u8, on: bool) !void {
    try rowHead(w, is_sel, dimmed, label);
    try w.writeByte(' ');
    try w.writeAll(if (is_sel) bcyn else if (dimmed or !on) dim else color);
    if (is_sel or on) try w.writeAll(bold);
    try w.writeAll(if (on) "[on ]" else "[off]");
    try w.writeAll(rst);
    try endLine(w);
}

/// One list row when showing every option would overflow: current choice
/// bracketed by direction marks, matching h/l stepping without a fake bar.
pub fn choiceRow(w: *std.Io.Writer, is_sel: bool, dimmed: bool, color: []const u8, label: []const u8, value: []const u8) !void {
    try rowHead(w, is_sel, dimmed, label);
    try w.writeByte(' ');
    try w.writeAll(if (is_sel) bcyn else if (dimmed) dim else color);
    if (is_sel) try w.writeAll(bold);
    try w.print("< {s} >", .{value});
    try w.writeAll(rst);
    try endLine(w);
}

test "toggle rows show one compact current state" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toggleRow(&w, false, false, acc, "enabled", true);
    var plain: [128]u8 = undefined;
    try std.testing.expectEqualStrings("  enabled   [on ]\r\n", stripAnsi(w.buffered(), &plain));
}

test "choice rows show direction without implying magnitude" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try choiceRow(&w, false, false, acc, "sync", "1/16");
    var plain: [128]u8 = undefined;
    try std.testing.expectEqualStrings("  sync      < 1/16 >\r\n", stripAnsi(w.buffered(), &plain));
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

/// Bar-number ruler over a step grid (drum, slicer). Each label's last digit
/// sits on the beat-separator column of the rows below, so the numbers line
/// up with the "│" ticks exactly like the piano roll's header row
/// (views/piano.zig) - the rest of the row stays blank. A bar boundary that
/// isn't beat-aligned (odd meters over an /8 denominator) has no separator
/// column to land on, so its label falls back to the cell's own columns.
pub fn writeBarRuler(
    w: *std.Io.Writer,
    gutter: usize,
    scroll: u32,
    visible: u32,
    step_count: u32,
    stride: u32,
    steps_per_beat: u32,
    cell_width: usize,
    meter_denominator: u32,
    bar_units: u32,
) !void {
    var buf: [512]u8 = @splat(' ');
    var x: usize = gutter;
    var col: u32 = 0;
    while (col < visible and scroll + col * stride < step_count and x < buf.len) : (col += 1) {
        const s = scroll + col * stride;
        const on_beat = s % steps_per_beat == 0;
        if (on_beat) x += 1;
        if (barLabel(s, meter_denominator, bar_units)) |l| {
            // Beat-aligned: the label ends on the separator column (x - 1).
            // Otherwise it starts at the cell's first column.
            const at: usize = if (on_beat) x - 2 else x;
            if (at + 1 < buf.len) buf[at..][0..2].* = l;
        }
        x += cell_width;
    }
    try w.writeAll(dim);
    try w.writeAll(std.mem.trimEnd(u8, buf[0..@min(x, buf.len)], " "));
    try endLine(w);
}

fn barLabel(step: u32, meter_denominator: u32, bar_units: u32) ?[2]u8 {
    if (bar_units == 0) return null;
    const units = step * meter_denominator;
    if (units % bar_units != 0) return null;
    const bar = units / bar_units + 1;
    if (bar >= 100) return .{ ' ', '+' };
    var buf: [2]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:>2}", .{bar}) catch return null;
    return buf;
}

/// Tabbed section divider: `▌ OSC [A] B  C ─────`, the drawn card's tab in
/// brackets and its siblings dim. Only the live card's body follows it, so
/// this is the TUI's read of the GUI's tab bar (`[`/`]` cycle them - see
/// editors/synth.zig's cycleCursorTab).
pub fn synthTabSection(w: *std.Io.Writer, group: []const u8, labels: []const []const u8, active: usize, color: []const u8) !void {
    try w.writeAll("  ");
    try w.writeAll(color);
    try w.writeAll(bold);
    try w.writeAll("\u{258C} ");
    try w.writeAll(group);
    try w.writeByte(' ');
    var used = 5 + group.len; // "  " + "▌ " + group + " "
    for (labels, 0..) |label, i| {
        if (i == active) {
            try w.writeAll(color);
            try w.writeAll(bold);
            try w.print("[{s}]", .{label});
        } else {
            try w.writeAll(rst);
            try w.writeAll(dim);
            try w.print(" {s} ", .{label});
        }
        used += label.len + 2;
    }
    try w.writeAll(rst);
    try w.writeAll(dim);
    try w.writeByte(' ');
    used += 1;
    if (used < form_section_w) for (used..form_section_w) |_| try w.writeAll("\u{2500}");
    try endLine(w);
}

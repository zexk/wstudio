//! Shared TUI palette and primitive output helpers. Lives apart from the view
//! renderers (views/*.zig) and the facade (tui.zig) so both can import it
//! without a cycle.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;

pub const spectrum_rows: usize = 18;
pub const spectrum_band_count: usize = 80;
/// Number of editable synth parameters.
/// OSC A : 0:waveform 1:pulse_width 2:detune 3:unison 4:uni.det 5:uni.spread
/// OSC B : 6:b_on 7:b_waveform 8:b_pw 9:b_semi 10:b_detune 11:b_level 12:b_unison 13:b_uni.det
/// MOD   : 14:mod_mode 15:mod_amount
/// ENV   : 16:attack 17:decay 18:sustain 19:release
/// FILTER: 20:filter_type 21:cutoff 22:res 23:fenv_amount
/// FENV  : 24:fenv_attack 25:fenv_decay 26:fenv_sustain 27:fenv_release
/// LFO   : 28:lfo_shape 29:lfo_rate 30:lfo_depth 31:lfo_target
/// VOICE : 32:voice_mode 33:glide
/// SUB   : 34:sub_level 35:sub_shape
/// NOISE : 36:noise_level 37:noise_color
/// OUT   : 38:gain
pub const synth_param_count: u8 = 39;

// ---------------------------------------------------------------------------
// Palette — all colour codes go here; never raw \x1b sequences elsewhere
// ---------------------------------------------------------------------------

pub const rst  = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim  = "\x1b[2m";
pub const acc  = "\x1b[36m";   // cyan  – interactive / instrument labels
pub const grn  = "\x1b[32m";   // green – playing / active steps
pub const yel  = "\x1b[33m";   // yellow – INSERT mode / muted
pub const red  = "\x1b[31m";   // red   – clip / error
pub const sel  = "\x1b[7m";    // reverse-video – selected row / cursor
pub const blu  = "\x1b[34m";   // blue   – voice / routing
pub const mag  = "\x1b[35m";   // magenta – modulation / movement
pub const bcyn = "\x1b[96m";   // bright cyan – cursor / selected row
pub const bwht = "\x1b[97m";   // bright white – selected value

// ---------------------------------------------------------------------------
// Primitive helpers
// ---------------------------------------------------------------------------

pub fn endLine(w: *std.Io.Writer) !void {
    // Reset before erasing so background colour never bleeds to the right edge.
    try w.writeAll(rst ++ "\x1b[K\r\n");
}

pub fn hr(w: *std.Io.Writer, cols: u16) !void {
    try w.writeAll(dim);
    for (0..@min(cols, 200)) |_| try w.writeAll("─");
    try endLine(w);
}

/// Renders `raw` (may contain ANSI SGR sequences) as a full-width "chrome"
/// bar: the content as-is, then the remainder of the row filled with a
/// reverse-video block out to `cols`. Used for the header and transport
/// rows so they read as UI frame all the way to the edge without a
/// dedicated rule-line row underneath (see the v1.0.0 tackle-list item on
/// reclaiming those rows for content).
pub fn writeChromeRow(w: *std.Io.Writer, raw: []const u8, cols: u16) !void {
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
        if (col >= cols) break;
        if (raw[i] & 0xC0 != 0x80) col += 1; // UTF-8 continuation bytes are free
        try w.writeByte(raw[i]);
        i += 1;
    }
    if (col < cols) {
        try w.writeAll("\x1b[7m");
        try w.splatByteAll(' ', cols - col);
    }
    try endLine(w);
}

/// Write `raw` (a single line, no \r\n, may contain ANSI SGR sequences) to
/// `w`, clamped to `max_cols` visible columns. ANSI escapes are copied
/// through verbatim (they cost no width); everything else counts as one
/// column per UTF-8 lead byte. Footer status lines are built from several
/// independent `w.print` calls with no shared width budget, so a verbose
/// status message can silently overflow past the terminal's right edge and
/// wrap onto a new row — which pushes the whole frame down by one line and
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
// Form-row primitives — shared by the synth and sampler editors
// ---------------------------------------------------------------------------

/// Smooth horizontal level bar. `color` tints the filled portion; the track is
/// always dim. Fractional fill is rendered with a partial block for the last
/// cell so small changes are visible.
pub fn synthBar(w: *std.Io.Writer, value: f32, max_val: f32, is_sel: bool, color: []const u8) !void {
    const bar_w: usize = 18;
    const frac = std.math.clamp(value / max_val, 0.0, 1.0) * @as(f32, @floatFromInt(bar_w));
    const full: usize = @intFromFloat(@floor(frac));
    const rem = frac - @floor(frac);
    // U+258F..U+2589 — 1/8 .. 7/8 left blocks.
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
    const total = 42;
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

test "writeChromeRow pads short content with a reverse-video fill to the exact column count" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeChromeRow(&w, bold ++ "hi" ++ rst, 10);
    const out = w.buffered();

    // Original content survives untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, bold ++ "hi" ++ rst) != null);
    // Reverse-video fill follows, padded to exactly 10 visible columns
    // (2 already written by "hi", so 8 fill spaces).
    const fill_start = std.mem.indexOf(u8, out, "\x1b[7m").?;
    var spaces: usize = 0;
    var i = fill_start + 4;
    while (i < out.len and out[i] == ' ') : (i += 1) spaces += 1;
    try std.testing.expectEqual(@as(usize, 8), spaces);
    // Ends the line like any other row.
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[K\r\n"));
}

test "writeChromeRow doesn't overflow when content already fills the row" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeChromeRow(&w, "0123456789", 10);
    const out = w.buffered();
    // No fill needed — content exactly fills 10 columns.
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

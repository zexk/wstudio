//! Frontend-shared ANSI/SGR vocabulary. The TUI renders these codes
//! directly; the GUI treats SGR-styled text from the shared renderers as
//! canonical content and strips the codes (stripAnsi) before drawing its
//! own presentation. Keeping the palette and the stripper in one shared
//! module lets ui/ modules emit styled text without depending on the TUI.

const std = @import("std");
const ws = @import("wstudio");

// ---------------------------------------------------------------------------
// Palette - all colour codes go here; never raw \x1b sequences elsewhere
// ---------------------------------------------------------------------------

// zig fmt: off
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
// zig fmt: on

/// Fixed per-track color palette (see `Track.color`, cycled with `[`/`]`
/// in the tracks view). Reuses the existing semantic constants above rather
/// than inventing new ANSI codes - a track color and, say, the mute
/// indicator's yellow are different row segments, so sharing a hue causes
/// no real ambiguity. `color == 0` (not in this array) means uncolored.
pub const track_palette = [_][]const u8{ red, yel, grn, acc, blu, mag, bwht };
pub const track_color_names = [_][]const u8{ "red", "yellow", "green", "cyan", "blue", "magenta", "white" };
comptime {
    std.debug.assert(track_palette.len == ws.track_color_count);
    std.debug.assert(track_color_names.len == ws.track_color_count);
}

pub fn endLine(w: *std.Io.Writer) !void {
    // Reset before erasing so background colour never bleeds to the right edge.
    try w.writeAll(rst ++ "\x1b[K\r\n");
}

// ---------------------------------------------------------------------------
// Status-line mode/view badges - shared by both frontends' status renderers
// (ui/status.zig writes these directly; the GUI strips the codes back out).
// ---------------------------------------------------------------------------

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

const Mode = ws.input.Mode;

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

/// Copy `raw`'s visible bytes (ANSI escape sequences dropped) into `buf`,
/// truncating if it wouldn't fit. Used wherever styled TUI output must be
/// matched or re-rendered as plain text (help search, GUI status line).
pub fn stripAnsi(raw: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    var len: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '[') {
            i += 2;
            while (i < raw.len and !(raw[i] >= 0x40 and raw[i] <= 0x7e)) : (i += 1) {}
            continue; // the loop's own i += 1 consumes the terminator byte
        }
        if (len >= buf.len) break;
        buf[len] = raw[i];
        len += 1;
    }
    return buf[0..len];
}

test "stripAnsi drops SGR sequences, keeps visible bytes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("  hi there", stripAnsi("\x1b[36m  hi \x1b[0m\x1b[2mthere", &buf));
    try std.testing.expectEqualStrings("plain", stripAnsi("plain", &buf));
    try std.testing.expectEqualStrings(" N   1/5  oct 4", stripAnsi("\x1b[42m\x1b[30m N \x1b[0m  \x1b[2m1/5  oct \x1b[0m4", &buf));
}

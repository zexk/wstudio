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

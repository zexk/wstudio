//! Icon glyphs for the TUI, drawn from a 16-glyph subset of "Symbols Nerd
//! Font Mono" (MIT license; see assets/fonts/LICENSE and the Nerd Fonts
//! project at https://github.com/ryanoasis/nerd-fonts). Codepoints were
//! looked up in the project's authoritative glyphnames.json rather than
//! guessed, then the font was subsetted with fonttools' pyftsubset down to
//! just these sixteen glyphs (~3 KB vs. ~2.5 MB for the full symbols font).
//!
//! These are Private Use Area codepoints: a terminal only renders them as
//! icons if its font actually has glyphs there, otherwise they show as
//! tofu/placeholder boxes. `zig build install-font` writes the embedded
//! font to the user's font directory; sites that also have an ASCII
//! rendering (see `font_installed` below) show only the icon once it's
//! installed, and only the ASCII otherwise, so a missing font never shows
//! as a stray tofu box next to text that already says the same thing. The
//! Mono variant guarantees each glyph is exactly one terminal cell wide, so
//! it never throws off the hand-aligned columns elsewhere in the TUI.

pub const play = "\u{f04b}"; // fa-play
pub const stop = "\u{f04d}"; // fa-stop
pub const mute = "\u{f075f}"; // md-volume_mute
pub const solo = "\u{f005}"; // fa-star
pub const save = "\u{f0c7}"; // fa-save
pub const warn = "\u{f071}"; // fa-warning — unsaved-changes indicator
pub const synth = "\u{ec1a}"; // cod-piano
pub const drum = "\u{ee32}"; // fa-drum
pub const sampler = "\u{ef9d}"; // fa-wave_square
pub const eq = "\u{f0ea2}"; // md-equalizer
pub const arrangement = "\u{f0bd1}"; // md-timeline
pub const tempo = "\u{f07da}"; // md-metronome
pub const help = "\u{f02d7}"; // md-help_circle
pub const master = "\u{f025}"; // fa-headphones
pub const loop = "\u{f0547}"; // md-repeat_variant
pub const logo = "\u{f1de}"; // fa-sliders
/// Same codepoint as `logo` — the app logo IS a sliders glyph, which happens
/// to be a fitting icon for the Slicer instrument too. No new glyph needed.
pub const slicer = logo;

const std = @import("std");
const ws = @import("wstudio");

/// True once `zig build install-font` has written the bundled font to the
/// user's font directory (checked by `detectFontInstalled`, cached here by
/// `tui/app.zig:run` at startup). Call sites that also have an ASCII
/// fallback branch on this so exactly one of the two ever renders — without
/// it, an uninstalled font just means a stray tofu box next to the ASCII
/// glyph that already said the same thing.
pub var font_installed: bool = false;

/// Checks whether the embedded icon font (see `ws.icon_font_ttf`) is present
/// in the user's font directory. Does real filesystem I/O, so call it once
/// with the process's real `std.Io` (not a test double) and cache the result
/// in `font_installed` rather than calling it per frame.
pub fn detectFontInstalled(io: std.Io) bool {
    var path_buf: [1024]u8 = undefined;
    const dir = fontDir(&path_buf) catch return false;
    var full_buf: [1024]u8 = undefined;
    const full_path = std.fmt.bufPrint(&full_buf, "{s}/wstudio-icons.ttf", .{dir}) catch return false;
    std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
    return true;
}

/// `$XDG_DATA_HOME/fonts`, falling back to `$HOME/.local/share/fonts` —
/// mirrors tools/install_font.zig's fontDir (kept separate since tools/ only
/// imports the wstudio library module, not this one).
fn fontDir(buf: []u8) ![]const u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/fonts", .{std.mem.sliceTo(xdg, 0)});
    }
    if (std.c.getenv("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.local/share/fonts", .{std.mem.sliceTo(home, 0)});
    }
    return error.NoFontDir;
}

test "every icon decodes to exactly one codepoint" {
    const all = [_][]const u8{
        play, stop, mute, solo, save, warn, synth, drum,
        sampler, eq, arrangement, tempo, help, master, loop, logo,
    };
    for (all) |icon| {
        var it = std.unicode.Utf8Iterator{ .bytes = icon, .i = 0 };
        const cp = it.nextCodepoint() orelse return error.Empty;
        try std.testing.expect(cp >= 0xe000 and cp <= 0xfffff); // PUA range
        try std.testing.expectEqual(@as(?u21, null), it.nextCodepoint()); // exactly one
    }
}

test "embedded font asset (ws.icon_font_ttf) looks like a valid, small TTF" {
    const bytes = ws.icon_font_ttf;
    try std.testing.expectEqualStrings("\x00\x01\x00\x00", bytes[0..4]); // sfnt version
    try std.testing.expect(bytes.len > 0 and bytes.len < 100 * 1024);
}

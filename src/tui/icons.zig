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
//! font to the user's font directory; until it's installed and selected in
//! the terminal, icons are harmless but won't look like anything in
//! particular — every call site below adds an icon as a decoration next to
//! existing text/ASCII, never in place of it, so the TUI stays legible
//! either way. The Mono variant guarantees each glyph is exactly one
//! terminal cell wide, so it never throws off the hand-aligned columns
//! elsewhere in the TUI.

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

const std = @import("std");
const ws = @import("wstudio");

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

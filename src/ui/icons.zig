//! Icon glyphs for the TUI and GUI, drawn from a 43-glyph subset of "Symbols
//! Nerd Font Mono" (MIT license; see assets/fonts/LICENSE and the Nerd Fonts
//! project at https://github.com/ryanoasis/nerd-fonts). Codepoints are the
//! ones the upstream font's own `post` table names (`fa-play`, `md-undo`,
//! ...) rather than guesses; assets/fonts/LICENSE records the pyftsubset
//! command that cut it down to just these glyphs (~5.4 KB vs. ~2.5 MB for
//! the full symbols font), including how to re-read those names.
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
//!
//! `font_installed` also folds in `wstudio.o.has_nerdfonts` (see
//! `config.zig`): a terminal-capability toggle in the yazi/kickstart.nvim
//! mold, for anyone rendering with a Nerd Font wstudio didn't install
//! itself (a system-wide patched font, a remote session, etc.) where the
//! `zig build install-font` filesystem probe can't see it. `tui/tui.zig`
//! ORs the two together at startup and on `:reload-config`, so either one
//! turning on is enough - there's no Lua-side way to force icons off once
//! the embedded font really is installed.

pub const play = "\u{f04b}"; // fa-play
pub const stop = "\u{f04d}"; // fa-stop
pub const mute = "\u{f075f}"; // md-volume_mute
pub const solo = "\u{f005}"; // fa-star
pub const save = "\u{f0c7}"; // fa-save
pub const warn = "\u{f071}"; // fa-warning - unsaved-changes indicator
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
/// md-content_cut - scissors read unambiguously as "chop" even at one
/// terminal cell, matching the Slicer's whole workflow (:chop, variants A-H).
pub const slicer = "\u{f0190}";
/// md-music_box_multiple - stacked instrument cards each showing a note,
/// reading as "a bank of programs" for a SoundFont's many instrument zones.
pub const soundfont = "\u{f0333}";
/// md-record - solid dot, the record-arm indicator (`r` toggles it).
pub const record = "\u{f044a}";
/// md-sine_wave - master-bus phase-correlation readout.
pub const phase = "\u{f095b}";
/// An `audio` track, whose sound is its recorded clips rather than a
/// generator. Same md-sine_wave glyph as `phase` above - a bare waveform is
/// what both of them mean, and the two never share a surface.
pub const audio_track = "\u{f095b}";
/// md-volume_high - master-bus LUFS loudness readout; pairs with `mute`
/// (md-volume_mute) as its "loud" counterpart.
pub const loudness = "\u{f057e}";
/// md-power_plug - CLAP/VST3 hosted plugins, distinct from `synth`'s piano
/// glyph so a hosted plugin reads differently from wstudio's own synth.
pub const plugin = "\u{f06a5}";
pub const position = "\u{f034e}"; // md-map_marker
pub const meter = "\u{f07db}"; // md-metronome_tick
pub const sample_rate = "\u{f04c5}"; // md-speedometer
pub const audio = "\u{f04c3}"; // md-speaker
pub const project = "\u{f1359}"; // md-folder_music
pub const automation = "\u{f0e93}"; // md-chart_timeline_variant
pub const rescan = "\u{f0450}"; // md-refresh
pub const bypass = "\u{f06a6}"; // md-power_plug_off

// The GUI's toolbar buttons. These say nothing the surrounding Unicode
// couldn't (they replaced a literal "\u{2190}", "+", "\u{00D7}" and so on),
// so unlike the icons above they're not about vocabulary - they're about
// coming from the same font as their neighbours. Mixing DejaVu's arrows and
// math signs in with Nerd Font glyphs put two unrelated stroke weights and
// optical sizes in one row of buttons. The TUI keeps the plain Unicode: a
// terminal has no second font to fall out of step with.
pub const undo = "\u{f054c}"; // md-undo
pub const redo = "\u{f044e}"; // md-redo
pub const prev = "\u{f053}"; // fa-chevron_left
pub const next = "\u{f054}"; // fa-chevron_right
pub const plus = "\u{f067}"; // fa-plus
pub const minus = "\u{f068}"; // fa-minus
pub const left = "\u{f060}"; // fa-arrow_left
pub const right = "\u{f061}"; // fa-arrow_right
pub const up = "\u{f062}"; // fa-arrow_up
pub const down = "\u{f063}"; // fa-arrow_down
pub const close = "\u{f00d}"; // fa-xmark
pub const fold_closed = "\u{f035f}"; // md-menu_right
pub const fold_open = "\u{f035d}"; // md-menu_down

const std = @import("std");
const ws = @import("wstudio");

/// True once `zig build install-font` has written the bundled font to the
/// user's font directory (checked by `detectFontInstalled`, cached here by
/// `tui/app.zig:run` at startup). Call sites that also have an ASCII
/// fallback branch on this so exactly one of the two ever renders - without
/// it, an uninstalled font just means a stray tofu box next to the ASCII
/// glyph that already said the same thing.
pub var font_installed: bool = false;

/// Checks whether the embedded icon font (see `ws.icon_font_ttf`) is present
/// in the user's font directory. Does real filesystem I/O, so call it once
/// with the process's real `std.Io` (not a test double) and cache the result
/// in `font_installed` rather than calling it per frame.
pub fn detectFontInstalled(io: std.Io) bool {
    var path_buf: [1024]u8 = undefined;
    const dir = ws.iconFontDir(&path_buf) catch return false;
    var full_buf: [1024]u8 = undefined;
    const full_path = std.fmt.bufPrint(&full_buf, "{s}/wstudio-icons.ttf", .{dir}) catch return false;
    std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
    return true;
}

/// `icon` if `font_installed`, else `ascii` - the one-line form of the
/// branch already spelled out longhand at the play/stop and mute/solo call
/// sites. `ascii` is often `""`: wherever an icon sits next to a text label
/// that already says the same thing (a view's " SYNTH" title, an
/// instrument's full name in a picker row), dropping the icon loses
/// nothing, so there's no separate glyph to invent.
pub fn iconOr(icon: []const u8, ascii: []const u8) []const u8 {
    return if (font_installed) icon else ascii;
}

test "every icon decodes to exactly one codepoint" {
    // Walks this file's declarations rather than a hand-kept list, which
    // went stale the moment an icon was added - the same drift that left a
    // glyph range list in gui.zig four icons behind. Every string constant
    // here is an icon; the non-icon declarations are imports, a bool and
    // two functions, none of which are pointers.
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const value = @field(@This(), decl.name);
        if (@typeInfo(@TypeOf(value)) != .pointer) continue;
        const icon: []const u8 = value;
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

/// Walks the embedded font's format-12 cmap subtable (the only one that
/// reaches past U+FFFF, where most of these icons live) looking for one
/// codepoint. Enough of a TTF reader for the test below and nothing more.
fn fontHasCodepoint(cp: u21) bool {
    const bytes = ws.icon_font_ttf;
    const be = std.mem.readInt;
    const num_tables = be(u16, bytes[4..6], .big);
    var cmap: usize = 0;
    for (0..num_tables) |i| {
        const rec = 12 + i * 16;
        if (std.mem.eql(u8, bytes[rec..][0..4], "cmap")) cmap = be(u32, bytes[rec + 8 ..][0..4], .big);
    }
    if (cmap == 0) return false;
    for (0..be(u16, bytes[cmap + 2 ..][0..2], .big)) |i| {
        const sub = cmap + be(u32, bytes[cmap + 4 + i * 8 + 4 ..][0..4], .big);
        if (be(u16, bytes[sub..][0..2], .big) != 12) continue;
        for (0..be(u32, bytes[sub + 12 ..][0..4], .big)) |g| {
            const group = sub + 16 + g * 12;
            const first = be(u32, bytes[group..][0..4], .big);
            const last = be(u32, bytes[group + 4 ..][0..4], .big);
            if (cp >= first and cp <= last) return true;
        }
    }
    return false;
}

test "the embedded font actually has every icon this file names" {
    // The one thing that turns an icon into a tofu box: naming a codepoint
    // the subsetted font was never cut with. Re-run the pyftsubset command
    // in assets/fonts/LICENSE with the new codepoint added when this fails.
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const value = @field(@This(), decl.name);
        if (@typeInfo(@TypeOf(value)) != .pointer) continue;
        const icon: []const u8 = value;
        var it = std.unicode.Utf8Iterator{ .bytes = icon, .i = 0 };
        const cp = it.nextCodepoint() orelse return error.Empty;
        if (!fontHasCodepoint(cp)) {
            std.debug.print("icon '{s}' is U+{X}, which the font has no glyph for\n", .{ decl.name, cp });
            return error.MissingGlyph;
        }
    }
}

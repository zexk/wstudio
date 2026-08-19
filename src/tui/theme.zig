//! TUI palette theming: recolor the terminal's ANSI palette (OSC 4) and its
//! default text/page colors (OSC 10/11) once at startup, instead of
//! touching any of the ~30 view files that print `ansi.zig`'s `acc`/`grn`/
//! `yel`/... constants. Those stay exactly what they've always been -
//! literal comptime strings like `"\x1b[36m"`, concatenated with `++` at
//! dozens of call sites (`grn ++ bold` and friends) - because index 6 not
//! meaning "cyan" anymore is the terminal's problem to solve, the same
//! trick base16-shell/pywal use to theme every other TUI in the terminal
//! at once. Rewriting every call site to carry a runtime color instead of a
//! comptime one was the alternative, and would have meant `++` no longer
//! compiling anywhere color and a text attribute get combined.
//!
//! This is global to the physical terminal, not scoped to wstudio's
//! alternate screen: tmux/screen forward these OSC codes to the real
//! terminal by default, so turning a theme on recolors every other pane
//! sharing that terminal too, for as long as wstudio is running (it's
//! undone on quit). That's why `tui_theme` (config.zig) defaults to
//! `.none` - unlike `gui_theme`, which only ever paints wstudio's own
//! window, opting into a name here is a choice about someone else's
//! terminal session too, not just this program's.

const std = @import("std");
const ws = @import("wstudio");
const config_mod = @import("../config.zig");

const Slot = struct { index: u8, hex: u24 };

/// `a` pushed `num/den` of the way toward `b`, in plain sRGB bytes - enough
/// for nudging one palette tier off another, and it keeps this file free of
/// a color-space dependency.
fn toward(a: u24, b: u24, num: u32, den: u32) u24 {
    var out: u24 = 0;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const av: u32 = (a >> shift) & 0xff;
        const bv: u32 = (b >> shift) & 0xff;
        const mixed = if (bv > av) av + (bv - av) * num / den else av - (av - bv) * num / den;
        out |= @as(u24, @intCast(mixed)) << shift;
    }
    return out;
}

/// ANSI color index -> hex.
///
/// The six chromatic normals are the identity's accent tier (`tracks` 10-15)
/// and the brights are those same accents pushed toward `fg0`, which means
/// "more emphatic" in both polarities: lighter on a dark theme, darker on a
/// light one. Both tiers therefore inherit the accent's contrast against the
/// page, which is the whole point - these six are what every view prints
/// through `ansi.zig`'s `acc`/`grn`/`yel`/... constants, so they are body
/// text, not decoration.
///
/// The greys come from the text ramp rather than the surface ramp for the
/// same reason: slot 7 is `wht` at call sites, and slot 8 is what a terminal
/// renders comment-grey with. Only slot 0 is a background.
///
/// Track fills (`tracks` 0-5) deliberately do *not* appear here. They are
/// mixed halfway into the canvas so a track row can carry a label, which
/// leaves them far too close to the page to read as text - as the normal
/// tier, they put every colored word in the TUI under 3.5:1.
fn slots(id: *const ws.theme_identity.Identity) [16]Slot {
    var result: [16]Slot = undefined;
    for (&result, 0..) |*slot, index| slot.* = .{
        .index = @intCast(index),
        .hex = switch (index) {
            0 => id.bg0,
            1...6 => id.tracks[9 + index],
            7 => id.fg1,
            8 => id.fg3,
            9...14 => toward(id.tracks[index + 1], id.fg0, 45, 100),
            else => id.fg0,
        },
    };
    return result;
}

fn writeHex(w: *std.Io.Writer, hex: u24) !void {
    try w.print("rgb:{x:0>2}/{x:0>2}/{x:0>2}", .{ (hex >> 16) & 0xff, (hex >> 8) & 0xff, hex & 0xff });
}

/// Reset sequence: OSC 104 with no index resets every color OSC 4 has ever
/// set in this session in one shot; 110/111 reset the default fg/bg. Sent
/// before applying a theme (so a mid-session switch never leaves a stale
/// slot behind) and again on quit.
pub const reset_osc = "\x1b]104\x07" ++ "\x1b]110\x07" ++ "\x1b]111\x07";

/// Renders the OSC blob for `theme` into `buf` - empty for `.none`, which
/// leaves the terminal's own palette untouched entirely.
pub fn oscFor(theme: config_mod.TuiTheme, overrides: *const ws.theme_identity.Overrides, buf: []u8) []const u8 {
    if (theme == .none) return "";
    // `TuiTheme` is `Name` with `.none` prepended (config/options.zig), so the
    // ordinals line up one apart.
    const name: ws.theme_identity.Name = @enumFromInt(@intFromEnum(theme) - 1);
    const resolved = overrides.apply(ws.theme_identity.get(name).*);
    const id = &resolved;
    var w: std.Io.Writer = .fixed(buf);
    for (slots(id)) |s| {
        w.print("\x1b]4;{d};", .{s.index}) catch break;
        writeHex(&w, s.hex) catch break;
        w.writeByte(0x07) catch break;
    }
    w.writeAll("\x1b]10;") catch {};
    writeHex(&w, id.fg0) catch {};
    w.writeByte(0x07) catch {};
    w.writeAll("\x1b]11;") catch {};
    writeHex(&w, id.bg1) catch {};
    w.writeByte(0x07) catch {};
    return w.buffered();
}

/// Big enough for 16 OSC-4 sets plus OSC 10/11, each well under 24 bytes.
pub const osc_buf_len = 512;

/// Apply `theme` to `term` (any type exposing `write([]const u8)` - both
/// terminal.zig's and terminal_windows.zig's `Terminal`, kept generic here
/// so this module stays platform-agnostic). No-op for `.none`.
pub fn apply(term: anytype, theme: config_mod.TuiTheme, overrides: *const ws.theme_identity.Overrides) void {
    var buf: [osc_buf_len]u8 = undefined;
    const osc = oscFor(theme, overrides, &buf);
    if (osc.len > 0) term.write(osc);
}

/// Undo a previously applied theme. No-op (and safe to call unconditionally)
/// when `theme` is `.none`, since nothing was ever sent.
pub fn reset(term: anytype, theme: config_mod.TuiTheme) void {
    if (theme != .none) term.write(reset_osc);
}

test "oscFor is empty for .none, non-empty and index-bearing otherwise" {
    var buf: [osc_buf_len]u8 = undefined;
    const overrides: ws.theme_identity.Overrides = .{};
    try std.testing.expectEqualStrings("", oscFor(.none, &overrides, &buf));
    const patina = oscFor(.patina, &overrides, &buf);
    try std.testing.expect(patina.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, patina, "\x1b]4;0;rgb:") != null);
    try std.testing.expect(std.mem.indexOf(u8, patina, "\x1b]4;6;rgb:") != null);
    try std.testing.expect(std.mem.indexOf(u8, patina, "\x1b]4;15;rgb:") != null);
    try std.testing.expect(std.mem.indexOf(u8, patina, "\x1b]10;rgb:") != null);
    try std.testing.expect(std.mem.indexOf(u8, patina, "\x1b]11;rgb:") != null);

    const solarized = oscFor(.solarized_light, &overrides, &buf);
    try std.testing.expect(std.mem.indexOf(u8, solarized, "\x1b]10;rgb:00/2b/36") != null);
    try std.testing.expect(std.mem.indexOf(u8, solarized, "\x1b]11;rgb:fd/f6/e3") != null);
}

test "reset_osc covers palette, fg, and bg resets" {
    try std.testing.expect(std.mem.indexOf(u8, reset_osc, "\x1b]104") != null);
    try std.testing.expect(std.mem.indexOf(u8, reset_osc, "\x1b]110") != null);
    try std.testing.expect(std.mem.indexOf(u8, reset_osc, "\x1b]111") != null);
}

test "oscFor applies semantic highlight overrides" {
    var overrides: ws.theme_identity.Overrides = .{};
    // track16 is the accent tier's cyan, which slot 6 now reads.
    overrides.set(.track16, 0x123abc);
    var buf: [osc_buf_len]u8 = undefined;
    const osc = oscFor(.patina, &overrides, &buf);
    try std.testing.expect(std.mem.indexOf(u8, osc, "\x1b]4;6;rgb:12/3a/bc") != null);
    // ...and the bright slot beside it is that same color pushed toward fg0,
    // so overriding one accent moves its pair rather than stranding it.
    try std.testing.expect(std.mem.indexOf(u8, osc, "\x1b]4;14;rgb:12/3a/bc") == null);
    try std.testing.expect(std.mem.indexOf(u8, osc, "\x1b]4;14;rgb:") != null);
}

test "every ANSI slot a view can print is legible on the themed background" {
    // The TUI sets the terminal's background to bg1 (OSC 11), so every color
    // a view prints text in is read against it, and SC 1.4.3 wants 4.5:1 for
    // body text. Only the in-house themes are held to it: an imported palette
    // ships upstream's published values, several of which do not clear the
    // floor on their own background (catppuccin_latte's green is 2.75:1
    // against its own base), and matching upstream is the point of shipping
    // them at all.
    for (ws.theme_identity.in_house) |name| {
        const id = ws.theme_identity.get(name);
        for (slots(id), 0..) |slot, index| {
            // Slot 0 is a background. Slot 8 is the conventional dim slot -
            // every established scheme puts a deliberately quiet grey there
            // (nord's own is 1.6:1), so it is not held to a text floor.
            if (index == 0 or index == 8) continue;
            const got = ws.theme_identity.contrast(slot.hex, id.bg1);
            if (got < 4.5) {
                std.debug.print("{s} ANSI slot {d} (#{x:0>6}) is {d:.2}:1 on bg1, wanted 4.5\n", .{ @tagName(name), index, slot.hex, got });
                return error.SlotTooDim;
            }
        }
    }
}

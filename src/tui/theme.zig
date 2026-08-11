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

comptime {
    // `oscFor` resolves a `TuiTheme` tag to an identity by name. The two enums
    // are written out separately (TuiTheme carries the extra `.none`), so a
    // name added to only one of them would be an `orelse unreachable` panic on
    // the first frame instead of a build error.
    if (std.meta.tags(config_mod.TuiTheme).len != std.meta.tags(ws.theme_identity.Name).len + 1)
        @compileError("TuiTheme must be theme_identity.Name plus `none`");
    for (std.meta.tags(config_mod.TuiTheme)) |tag| {
        if (tag != .none and std.meta.stringToEnum(ws.theme_identity.Name, @tagName(tag)) == null)
            @compileError("TuiTheme." ++ @tagName(tag) ++ " has no theme_identity.Name");
    }
}

/// ANSI color index -> hex. Track colors and terminal normal/bright slots
/// share one full 16-color table in the theme identity.
fn slots(id: *const ws.theme_identity.Identity) [16]Slot {
    const track_for_slot = [16]u8{ 7, 0, 2, 1, 4, 5, 3, 8, 9, 10, 11, 12, 13, 14, 15, 6 };
    var result: [16]Slot = undefined;
    for (&result, 0..) |*slot, index| slot.* = .{ .index = @intCast(index), .hex = id.tracks[track_for_slot[index]] };
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
    const name = std.meta.stringToEnum(ws.theme_identity.Name, @tagName(theme)).?;
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
    overrides.set(.track4, 0x123abc);
    var buf: [osc_buf_len]u8 = undefined;
    const osc = oscFor(.patina, &overrides, &buf);
    try std.testing.expect(std.mem.indexOf(u8, osc, "\x1b]4;6;rgb:12/3a/bc") != null);
}

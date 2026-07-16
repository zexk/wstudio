const std = @import("std");
const zgui = @import("zgui");
const ws = @import("wstudio");
const config_mod = @import("../config.zig");

pub fn rgb(comptime value: u24) [4]f32 {
    return .{
        @as(f32, @floatFromInt(value >> 16)) / 255.0,
        @as(f32, @floatFromInt(value >> 8 & 0xff)) / 255.0,
        @as(f32, @floatFromInt(value & 0xff)) / 255.0,
        1.0,
    };
}

pub fn color(rgba: [4]f32) u32 {
    return zgui.colorConvertFloat4ToU32(rgba);
}

pub const Palette = struct {
    light: bool = false,
    bg0: [4]f32,
    bg1: [4]f32,
    bg2: [4]f32,
    bg3: [4]f32,
    bg4: [4]f32,
    bg5: [4]f32,
    fg0: [4]f32,
    fg1: [4]f32,
    fg2: [4]f32,
    fg3: [4]f32,
    line: [4]f32,
    line_soft: [4]f32,
    focus: [4]f32,
    focus_soft: [4]f32,
    track_cursor: [4]f32,
    modulation: [4]f32,
    danger: [4]f32,
    rhythm: [4]f32,
    audio: [4]f32,
    tracks: [7][4]f32,
};

/// The Patina identity is intentionally green through the full surface stack,
/// not neutral charcoal with a branded accent. See docs/gui-color-identity.md.
const patina_colors: Palette = .{
    .bg0 = rgb(0x06100e),
    .bg1 = rgb(0x0b1916),
    .bg2 = rgb(0x12241f),
    .bg3 = rgb(0x1b302a),
    .bg4 = rgb(0x284239),
    .bg5 = rgb(0x38584d),
    .fg0 = rgb(0xf2eadb),
    .fg1 = rgb(0xc9c0ae),
    .fg2 = rgb(0x9a9282),
    .fg3 = rgb(0x6f7569),
    .line = rgb(0x1c352e),
    .line_soft = rgb(0x0d201b),
    .focus = rgb(0xf08777),
    .focus_soft = rgb(0xb76559),
    .track_cursor = rgb(0xf2eadb),
    .modulation = rgb(0xd69ac0),
    .danger = rgb(0xf06468),
    .rhythm = rgb(0xc9cf73),
    .audio = rgb(0x71b9ac),
    .tracks = .{ rgb(0xf08777), rgb(0xf06468), rgb(0xc9cf73), rgb(0x71b9ac), rgb(0xd69ac0), rgb(0xd6a15f), rgb(0x9b9acb) },
};

/// Light counterpart specified alongside Patina in the color identity doc.
const patina_light_colors: Palette = .{
    .light = true,
    .bg0 = rgb(0xdce6dd),
    .bg1 = rgb(0xf3efe4),
    .bg2 = rgb(0xebe4d6),
    .bg3 = rgb(0xd9e2d8),
    .bg4 = rgb(0xc7d8cd),
    .bg5 = rgb(0xa9c0b2),
    .fg0 = rgb(0x17231f),
    .fg1 = rgb(0x34463f),
    .fg2 = rgb(0x5f6e66),
    .fg3 = rgb(0x7e897f),
    .line = rgb(0xc7d8cd),
    .line_soft = rgb(0xe1e6dc),
    .focus = rgb(0xad493f),
    .focus_soft = rgb(0xd88475),
    .track_cursor = rgb(0x17231f),
    .modulation = rgb(0x964778),
    .danger = rgb(0xb93640),
    .rhythm = rgb(0x626a19),
    .audio = rgb(0x247067),
    .tracks = .{ rgb(0xd86f61), rgb(0xde6870), rgb(0xb6bd5f), rgb(0x65aaa0), rgb(0xc787ac), rgb(0xc9964d), rgb(0x8b8abd) },
};

/// Neutral-charcoal counterpart: the same lightness ramp and warm text with
/// the green tint removed, accents unchanged - the conventional look the
/// identity doc describes patina as deliberately not being, offered as
/// `gui_theme = "graphite"` for people who want exactly that.
const graphite_colors: Palette = .{
    .bg0 = rgb(0x0b0b0d),
    .bg1 = rgb(0x131316),
    .bg2 = rgb(0x1c1c21),
    .bg3 = rgb(0x27272e),
    .bg4 = rgb(0x36363f),
    .bg5 = rgb(0x4c4c58),
    .fg0 = rgb(0xf2eadb),
    .fg1 = rgb(0xc9c0ae),
    .fg2 = rgb(0x9a9282),
    .fg3 = rgb(0x71716c),
    .line = rgb(0x2a2a31),
    .line_soft = rgb(0x17171b),
    .focus = rgb(0xf08777),
    .focus_soft = rgb(0xb76559),
    .track_cursor = rgb(0xf2eadb),
    .modulation = rgb(0xd69ac0),
    .danger = rgb(0xf06468),
    .rhythm = rgb(0xc9cf73),
    .audio = rgb(0x71b9ac),
    .tracks = .{ rgb(0xf08777), rgb(0xf06468), rgb(0xc9cf73), rgb(0x71b9ac), rgb(0xd69ac0), rgb(0xd6a15f), rgb(0x9b9acb) },
};

/// The original violet GUI palette, restored as an optional theme.
const umbra_colors: Palette = .{
    .bg0 = rgb(0x0c040f),
    .bg1 = rgb(0x160a19),
    .bg2 = rgb(0x231426),
    .bg3 = rgb(0x301f34),
    .bg4 = rgb(0x412d45),
    .bg5 = rgb(0x553e5a),
    .fg0 = rgb(0xd9d1da),
    .fg1 = rgb(0xb1a7b3),
    .fg2 = rgb(0x887b8c),
    .fg3 = rgb(0x645567),
    .line = rgb(0x1d1120),
    .line_soft = rgb(0x130915),
    .focus = rgb(0xb07bbc),
    .focus_soft = rgb(0x886498),
    .track_cursor = rgb(0xd9d1da),
    .modulation = rgb(0xc68fc1),
    .danger = rgb(0xb97873),
    .rhythm = rgb(0xc1a77b),
    .audio = rgb(0x7cb0af),
    .tracks = .{ rgb(0xb07bbc), rgb(0xb97873), rgb(0xc1a77b), rgb(0x7cb0af), rgb(0xc68fc1), rgb(0x7899c1), rgb(0x86b978) },
};

/// The active palette. Every draw site reads through this (via each file's
/// `const patina = &style.palette;` alias), so `selectPalette` at startup
/// re-skins the whole GUI. Mutated once, before the first frame.
pub var palette: Palette = patina_colors;

test "track cursor stays outside every theme's track rotation" {
    for ([_]Palette{ patina_colors, patina_light_colors, graphite_colors, umbra_colors }) |theme| {
        for (theme.tracks) |track| try std.testing.expect(!std.meta.eql(theme.track_cursor, track));
    }
}

pub fn selectPalette(theme: config_mod.GuiTheme) void {
    palette = switch (theme) {
        .patina => patina_colors,
        .patina_light => patina_light_colors,
        .graphite => graphite_colors,
        .umbra => umbra_colors,
    };
}

pub fn trackColor(index: u8) [4]f32 {
    if (index == 0 or index > palette.tracks.len) return palette.fg3;
    return palette.tracks[index - 1];
}

/// One accent per FX family, shared by the rack slots and the picker cards
/// so a unit keeps its color from browse to edit.
pub fn fxKindAccent(kind: ws.FxKind) [4]f32 {
    return switch (kind) {
        .gate, .comp, .mb_comp, .ott => palette.danger,
        .eq => palette.rhythm,
        .sat, .crush, .tape => palette.modulation,
        .chorus, .flanger, .phaser, .freq_shift => palette.focus,
        .delay, .reverb => palette.audio,
    };
}

pub fn pushControlFocus(focused: bool, accent: [4]f32) void {
    if (!focused) return;
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = palette.bg4 });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = palette.bg5 });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = accent });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = accent });
}

pub fn popControlFocus(focused: bool) void {
    if (focused) zgui.popStyleColor(.{ .count = 4 });
}

pub fn setTheme() void {
    const style = zgui.getStyle();
    if (palette.light) zgui.styleColorsLight(style) else zgui.styleColorsDark(style);
    style.setColor(.text, palette.fg0);
    style.setColor(.text_disabled, palette.fg3);
    style.setColor(.window_bg, palette.bg1);
    style.setColor(.child_bg, palette.bg1);
    style.setColor(.popup_bg, palette.bg2);
    style.setColor(.border, palette.line);
    style.setColor(.border_shadow, .{ 0, 0, 0, 0 });
    style.setColor(.frame_bg, palette.bg2);
    style.setColor(.frame_bg_hovered, palette.bg3);
    style.setColor(.frame_bg_active, palette.bg4);
    style.setColor(.title_bg, palette.bg0);
    style.setColor(.title_bg_active, palette.bg2);
    style.setColor(.title_bg_collapsed, palette.bg0);
    style.setColor(.menu_bar_bg, palette.bg2);
    style.setColor(.scrollbar_bg, palette.bg0);
    style.setColor(.scrollbar_grab, palette.bg4);
    style.setColor(.scrollbar_grab_hovered, palette.bg5);
    style.setColor(.scrollbar_grab_active, palette.focus_soft);
    style.setColor(.check_mark, palette.modulation);
    style.setColor(.slider_grab, palette.focus_soft);
    style.setColor(.slider_grab_active, palette.focus);
    style.setColor(.button, palette.bg3);
    style.setColor(.button_hovered, palette.bg4);
    style.setColor(.button_active, palette.focus_soft);
    style.setColor(.header, palette.bg3);
    style.setColor(.header_hovered, palette.bg4);
    style.setColor(.header_active, palette.focus_soft);
    style.setColor(.separator, palette.line);
    style.setColor(.separator_hovered, palette.focus_soft);
    style.setColor(.separator_active, palette.focus);
    style.setColor(.plot_lines, palette.audio);
    style.setColor(.plot_lines_hovered, palette.modulation);
    style.setColor(.plot_histogram, palette.focus);
    style.setColor(.plot_histogram_hovered, palette.modulation);
    style.setColor(.table_header_bg, palette.bg2);
    style.setColor(.table_border_strong, palette.bg5);
    style.setColor(.table_border_light, palette.line);
    style.setColor(.table_row_bg_alt, .{ palette.bg2[0], palette.bg2[1], palette.bg2[2], 0.45 });
    style.setColor(.text_selected_bg, .{ palette.focus[0], palette.focus[1], palette.focus[2], 0.35 });
    style.setColor(.nav_cursor, palette.focus);
    style.setColor(.modal_window_dim_bg, .{ palette.bg0[0], palette.bg0[1], palette.bg0[2], 0.78 });
    style.window_rounding = 0;
    style.child_rounding = 0;
    style.popup_rounding = 0;
    style.tab_rounding = 0;
    style.frame_rounding = 2;
    style.grab_rounding = 2;
    style.scrollbar_rounding = 0;
    style.window_padding = .{ 12, 12 };
    style.frame_padding = .{ 8, 6 };
    style.item_spacing = .{ 8, 8 };
    style.item_inner_spacing = .{ 6, 5 };
    style.scrollbar_size = 14;
}

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
    modulation: [4]f32,
    danger: [4]f32,
    rhythm: [4]f32,
    audio: [4]f32,
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
    .modulation = rgb(0xd69ac0),
    .danger = rgb(0xf06468),
    .rhythm = rgb(0xc9cf73),
    .audio = rgb(0x71b9ac),
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
    .modulation = rgb(0xd69ac0),
    .danger = rgb(0xf06468),
    .rhythm = rgb(0xc9cf73),
    .audio = rgb(0x71b9ac),
};

/// The active palette. Every draw site reads through this (via each file's
/// `const patina = &style.palette;` alias), so `selectPalette` at startup
/// re-skins the whole GUI. Mutated once, before the first frame.
pub var palette: Palette = patina_colors;

pub fn selectPalette(theme: config_mod.GuiTheme) void {
    palette = switch (theme) {
        .patina => patina_colors,
        .graphite => graphite_colors,
    };
}

pub fn trackColor(index: u8) [4]f32 {
    const accents = [_][4]f32{ palette.focus, palette.danger, palette.rhythm, palette.audio, palette.modulation, rgb(0xd6a15f), rgb(0x9b9acb) };
    if (index == 0 or index > accents.len) return palette.fg3;
    return accents[index - 1];
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
    zgui.styleColorsDark(style);
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

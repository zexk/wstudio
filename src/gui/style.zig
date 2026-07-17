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

/// Renders a shared hex identity (src/theme_identity.zig, also read by the
/// TUI's OSC theming) into the float RGBA this panel skin draws with - the
/// hex tables live in one place so the GUI and TUI can't drift into two
/// different ideas of what "patina" or "umbra" look like.
fn fromIdentity(comptime id: ws.theme_identity.Identity) Palette {
    return .{
        .light = id.light,
        .bg0 = rgb(id.bg0),
        .bg1 = rgb(id.bg1),
        .bg2 = rgb(id.bg2),
        .bg3 = rgb(id.bg3),
        .bg4 = rgb(id.bg4),
        .bg5 = rgb(id.bg5),
        .fg0 = rgb(id.fg0),
        .fg1 = rgb(id.fg1),
        .fg2 = rgb(id.fg2),
        .fg3 = rgb(id.fg3),
        .line = rgb(id.line),
        .line_soft = rgb(id.line_soft),
        .focus = rgb(id.focus),
        .focus_soft = rgb(id.focus_soft),
        .track_cursor = rgb(id.track_cursor),
        .modulation = rgb(id.modulation),
        .danger = rgb(id.danger),
        .rhythm = rgb(id.rhythm),
        .audio = rgb(id.audio),
        .tracks = .{ rgb(id.tracks[0]), rgb(id.tracks[1]), rgb(id.tracks[2]), rgb(id.tracks[3]), rgb(id.tracks[4]), rgb(id.tracks[5]), rgb(id.tracks[6]) },
    };
}

const patina_colors: Palette = fromIdentity(ws.theme_identity.patina);
const patina_light_colors: Palette = fromIdentity(ws.theme_identity.patina_light);
const graphite_colors: Palette = fromIdentity(ws.theme_identity.graphite);
const umbra_colors: Palette = fromIdentity(ws.theme_identity.umbra);

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

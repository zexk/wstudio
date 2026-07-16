const zgui = @import("zgui");

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

/// The Patina identity is intentionally green through the full surface stack,
/// not neutral charcoal with a branded accent. See docs/gui-color-identity.md.
pub const patina = struct {
    pub const bg0 = rgb(0x06100e);
    pub const bg1 = rgb(0x0b1916);
    pub const bg2 = rgb(0x12241f);
    pub const bg3 = rgb(0x1b302a);
    pub const bg4 = rgb(0x284239);
    pub const bg5 = rgb(0x38584d);
    pub const fg0 = rgb(0xf2eadb);
    pub const fg1 = rgb(0xc9c0ae);
    pub const fg2 = rgb(0x9a9282);
    pub const fg3 = rgb(0x6f7569);
    pub const line = rgb(0x1c352e);
    pub const line_soft = rgb(0x0d201b);
    pub const focus = rgb(0xf08777);
    pub const focus_soft = rgb(0xb76559);
    pub const modulation = rgb(0xd69ac0);
    pub const danger = rgb(0xf06468);
    pub const rhythm = rgb(0xc9cf73);
    pub const audio = rgb(0x71b9ac);
};

pub fn trackColor(index: u8) [4]f32 {
    const palette = [_][4]f32{ patina.focus, patina.danger, patina.rhythm, patina.audio, patina.modulation, rgb(0xd6a15f), rgb(0x9b9acb) };
    if (index == 0 or index > palette.len) return patina.fg3;
    return palette[index - 1];
}

pub fn pushControlFocus(focused: bool, accent: [4]f32) void {
    if (!focused) return;
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = patina.bg4 });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = patina.bg5 });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = accent });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = accent });
}

pub fn popControlFocus(focused: bool) void {
    if (focused) zgui.popStyleColor(.{ .count = 4 });
}

pub fn setTheme() void {
    const style = zgui.getStyle();
    zgui.styleColorsDark(style);
    style.setColor(.text, patina.fg0);
    style.setColor(.text_disabled, patina.fg3);
    style.setColor(.window_bg, patina.bg1);
    style.setColor(.child_bg, patina.bg1);
    style.setColor(.popup_bg, patina.bg2);
    style.setColor(.border, patina.line);
    style.setColor(.border_shadow, .{ 0, 0, 0, 0 });
    style.setColor(.frame_bg, patina.bg2);
    style.setColor(.frame_bg_hovered, patina.bg3);
    style.setColor(.frame_bg_active, patina.bg4);
    style.setColor(.title_bg, patina.bg0);
    style.setColor(.title_bg_active, patina.bg2);
    style.setColor(.title_bg_collapsed, patina.bg0);
    style.setColor(.menu_bar_bg, patina.bg2);
    style.setColor(.scrollbar_bg, patina.bg0);
    style.setColor(.scrollbar_grab, patina.bg4);
    style.setColor(.scrollbar_grab_hovered, patina.bg5);
    style.setColor(.scrollbar_grab_active, patina.focus_soft);
    style.setColor(.check_mark, patina.modulation);
    style.setColor(.slider_grab, patina.focus_soft);
    style.setColor(.slider_grab_active, patina.focus);
    style.setColor(.button, patina.bg3);
    style.setColor(.button_hovered, patina.bg4);
    style.setColor(.button_active, patina.focus_soft);
    style.setColor(.header, patina.bg3);
    style.setColor(.header_hovered, patina.bg4);
    style.setColor(.header_active, patina.focus_soft);
    style.setColor(.separator, patina.line);
    style.setColor(.separator_hovered, patina.focus_soft);
    style.setColor(.separator_active, patina.focus);
    style.setColor(.plot_lines, patina.audio);
    style.setColor(.plot_lines_hovered, patina.modulation);
    style.setColor(.plot_histogram, patina.focus);
    style.setColor(.plot_histogram_hovered, patina.modulation);
    style.setColor(.table_header_bg, patina.bg2);
    style.setColor(.table_border_strong, patina.bg5);
    style.setColor(.table_border_light, patina.line);
    style.setColor(.table_row_bg_alt, .{ patina.bg2[0], patina.bg2[1], patina.bg2[2], 0.45 });
    style.setColor(.text_selected_bg, .{ patina.focus[0], patina.focus[1], patina.focus[2], 0.35 });
    style.setColor(.nav_cursor, patina.focus);
    style.setColor(.modal_window_dim_bg, .{ patina.bg0[0], patina.bg0[1], patina.bg0[2], 0.78 });
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

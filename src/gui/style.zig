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

pub const umbra = struct {
    pub const bg0 = rgb(0x0c040f);
    pub const bg1 = rgb(0x160a19);
    pub const bg2 = rgb(0x231426);
    pub const bg3 = rgb(0x301f34);
    pub const bg4 = rgb(0x412d45);
    pub const bg5 = rgb(0x553e5a);
    pub const fg0 = rgb(0xd9d1da);
    pub const fg1 = rgb(0xb1a7b3);
    pub const fg2 = rgb(0x887b8c);
    pub const fg3 = rgb(0x645567);
    pub const line = rgb(0x1d1120);
    pub const line_soft = rgb(0x130915);
    pub const iris = rgb(0xb07bbc);
    pub const iris_soft = rgb(0x886498);
    pub const mauve = rgb(0xc68fc1);
    pub const red = rgb(0xb97873);
    pub const yellow = rgb(0xc1a77b);
    pub const cyan = rgb(0x7cb0af);
};

pub fn trackColor(index: u8) [4]f32 {
    const palette = [_][4]f32{ umbra.iris, umbra.red, umbra.yellow, umbra.cyan, umbra.mauve, rgb(0x7899c1), rgb(0x86b978) };
    if (index == 0 or index > palette.len) return umbra.fg3;
    return palette[index - 1];
}

pub fn pushControlFocus(focused: bool, accent: [4]f32) void {
    if (!focused) return;
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = umbra.bg4 });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = umbra.bg5 });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = accent });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = accent });
}

pub fn popControlFocus(focused: bool) void {
    if (focused) zgui.popStyleColor(.{ .count = 4 });
}

pub fn setTheme() void {
    const style = zgui.getStyle();
    zgui.styleColorsDark(style);
    style.setColor(.text, umbra.fg0);
    style.setColor(.text_disabled, umbra.fg3);
    style.setColor(.window_bg, umbra.bg1);
    style.setColor(.child_bg, umbra.bg1);
    style.setColor(.popup_bg, umbra.bg2);
    style.setColor(.border, umbra.line);
    style.setColor(.border_shadow, .{ 0, 0, 0, 0 });
    style.setColor(.frame_bg, umbra.bg2);
    style.setColor(.frame_bg_hovered, umbra.bg3);
    style.setColor(.frame_bg_active, umbra.bg4);
    style.setColor(.title_bg, umbra.bg0);
    style.setColor(.title_bg_active, umbra.bg2);
    style.setColor(.title_bg_collapsed, umbra.bg0);
    style.setColor(.menu_bar_bg, umbra.bg2);
    style.setColor(.scrollbar_bg, umbra.bg0);
    style.setColor(.scrollbar_grab, umbra.bg4);
    style.setColor(.scrollbar_grab_hovered, umbra.bg5);
    style.setColor(.scrollbar_grab_active, umbra.iris_soft);
    style.setColor(.check_mark, umbra.mauve);
    style.setColor(.slider_grab, umbra.iris_soft);
    style.setColor(.slider_grab_active, umbra.iris);
    style.setColor(.button, umbra.bg3);
    style.setColor(.button_hovered, umbra.bg4);
    style.setColor(.button_active, umbra.iris_soft);
    style.setColor(.header, umbra.bg3);
    style.setColor(.header_hovered, umbra.bg4);
    style.setColor(.header_active, umbra.iris_soft);
    style.setColor(.separator, umbra.line);
    style.setColor(.separator_hovered, umbra.iris_soft);
    style.setColor(.separator_active, umbra.iris);
    style.setColor(.plot_lines, umbra.cyan);
    style.setColor(.plot_lines_hovered, umbra.mauve);
    style.setColor(.plot_histogram, umbra.iris);
    style.setColor(.plot_histogram_hovered, umbra.mauve);
    style.setColor(.table_header_bg, umbra.bg2);
    style.setColor(.table_border_strong, umbra.bg5);
    style.setColor(.table_border_light, umbra.line);
    style.setColor(.table_row_bg_alt, .{ umbra.bg2[0], umbra.bg2[1], umbra.bg2[2], 0.45 });
    style.setColor(.text_selected_bg, .{ umbra.iris[0], umbra.iris[1], umbra.iris[2], 0.35 });
    style.setColor(.nav_cursor, umbra.iris);
    style.setColor(.modal_window_dim_bg, .{ umbra.bg0[0], umbra.bg0[1], umbra.bg0[2], 0.78 });
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

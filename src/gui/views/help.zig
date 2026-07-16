const zgui = @import("zgui");
const style = @import("../style.zig");

const color = style.color;
const umbra = style.umbra;

const Row = struct { key: []const u8, text: []const u8 };

const transport_rows = [_]Row{
    .{ .key = "Space", .text = "Play or stop" },
    .{ .key = "gg / Home", .text = "Seek to start" },
    .{ .key = "G / End", .text = "Seek to arrangement end" },
    .{ .key = "[ / ]", .text = "Master volume down / up" },
};

const editing_rows = [_]Row{
    .{ .key = "j / k", .text = "Move the active selection" },
    .{ .key = "m / S", .text = "Mute / solo selected track" },
    .{ .key = "i / Esc", .text = "Enter / leave piano mode" },
    .{ .key = "a..p", .text = "Play notes in insert mode" },
    .{ .key = "z / x", .text = "Octave down / up" },
};

const workspace_rows = [_]Row{
    .{ .key = "Tracks", .text = "Track list and mixer state" },
    .{ .key = "Arrange", .text = "Song clips by bar" },
    .{ .key = "Piano", .text = "Melodic step editing" },
    .{ .key = "Drums", .text = "Pad step sequencer" },
    .{ .key = "Slicer", .text = "Slice step sequencer" },
};

const device_rows = [_]Row{
    .{ .key = "Synth", .text = "Oscillator and modulation editor" },
    .{ .key = "Sampler", .text = "Sample playback and envelope" },
    .{ .key = "FX", .text = "Chain, bypass, reorder, and remove" },
    .{ .key = "Auto", .text = "Clip gain and pan envelopes" },
    .{ .key = "? / F1", .text = "Return to this reference" },
};

pub fn draw(app: anytype) void {
    drawHeader();
    zgui.spacing();
    const gap: f32 = 10;
    const column_w = @max(320, (zgui.getContentRegionAvail()[0] - gap) / 2);
    if (zgui.beginChild("help-left", .{ .w = column_w, .h = 0 })) {
        drawPanel("help-transport", "TRANSPORT", umbra.red, &transport_rows);
        zgui.spacing();
        drawPanel("help-editing", "KEYBOARD EDITING", umbra.yellow, &editing_rows);
    }
    zgui.endChild();
    zgui.sameLine(.{ .spacing = gap });
    if (zgui.beginChild("help-right", .{ .w = 0, .h = 0 })) {
        drawPanel("help-workspaces", "WORKSPACES", umbra.iris, &workspace_rows);
        zgui.spacing();
        drawPanel("help-devices", "DEVICES AND DATA", umbra.cyan, &device_rows);
        zgui.spacing();
        drawLaunchers(app);
    }
    zgui.endChild();
}

fn drawHeader() void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 72;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("help-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(umbra.mauve), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(umbra.fg3), "WSTUDIO REFERENCE", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(umbra.fg0), "Keyboard first, mouse friendly", .{});
    draw_list.addText(.{ origin[0] + width - 180, origin[1] + 27 }, color(umbra.mauve), "VIM MODAL WORKFLOW", .{});
}

fn drawPanel(id: [:0]const u8, title: []const u8, accent: [4]f32, rows: []const Row) void {
    const height = 52 + @as(f32, @floatFromInt(rows.len)) * 36;
    if (zgui.beginChild(id, .{ .w = 0, .h = height, .child_flags = .{ .border = true } })) {
        zgui.textColored(accent, "{s}", .{title});
        zgui.separator();
        for (rows) |row| drawRow(row, accent);
    }
    zgui.endChild();
}

fn drawRow(row: Row, accent: [4]f32) void {
    const origin = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();
    const key_w: f32 = 112;
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + key_w, origin[1] + 27 }, .col = color(umbra.bg2), .rounding = 3 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 3, origin[1] + 27 }, .col = color(accent), .rounding = 2 });
    draw_list.addText(.{ origin[0] + 10, origin[1] + 5 }, color(umbra.fg0), "{s}", .{row.key});
    draw_list.addText(.{ origin[0] + key_w + 13, origin[1] + 5 }, color(umbra.fg1), "{s}", .{row.text});
    zgui.dummy(.{ .w = 0, .h = 28 });
}

fn drawLaunchers(app: anytype) void {
    zgui.textDisabled("QUICK OPEN", .{});
    zgui.separator();
    zgui.pushStyleColor4f(.{ .idx = .button, .c = umbra.iris_soft });
    if (zgui.button("INSTRUMENTS", .{ .h = 34 })) app.openPicker(.instrument_picker);
    zgui.popStyleColor(.{});
    zgui.sameLine(.{ .spacing = 6 });
    if (zgui.button("PRESETS", .{ .h = 34 })) app.openPicker(.preset_picker);
    zgui.sameLine(.{ .spacing = 6 });
    if (zgui.button("PROJECTS", .{ .h = 34 })) app.core.view = .file_browser;
}

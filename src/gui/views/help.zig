const zgui = @import("zgui");
const style = @import("../style.zig");

const umbra = style.umbra;

pub fn draw(app: anytype) void {
    zgui.textDisabled("HELP / VIEW INDEX", .{});
    const rows = [_]struct { key: []const u8, text: []const u8 }{
        .{ .key = "Space", .text = "Play or stop" },
        .{ .key = "j / k, arrows", .text = "Select track (accepts counts)" },
        .{ .key = "gg / Home", .text = "Seek to start" },
        .{ .key = "G / End", .text = "Seek to arrangement end" },
        .{ .key = "m / S", .text = "Mute / solo selected track" },
        .{ .key = "[ / ]", .text = "Master volume down / up (accepts counts)" },
        .{ .key = "i / Esc", .text = "Enter / leave piano keyboard mode" },
        .{ .key = "a..p, z / x", .text = "Play notes, octave down / up in insert mode" },
        .{ .key = "? / F1", .text = "Show help" },
        .{ .key = "Tracks", .text = "Track list and mixer state" },
        .{ .key = "Arrange", .text = "Song clips by bar" },
        .{ .key = "Piano", .text = "Melodic step editing" },
        .{ .key = "Drums / Slicer", .text = "Step toggles" },
        .{ .key = "Synth / Sampler", .text = "Instrument parameters" },
        .{ .key = "FX", .text = "Chain, bypass, insert, and remove" },
        .{ .key = "Scope", .text = "Master meters and chain" },
        .{ .key = "Auto", .text = "Clip automation summary" },
    };
    for (rows) |row| {
        zgui.textColored(umbra.mauve, "{s}", .{row.key});
        zgui.sameLine(.{ .offset_from_start_x = 150 });
        zgui.text("{s}", .{row.text});
    }
    zgui.separator();
    if (zgui.button("Instrument picker", .{})) app.openPicker(.instrument_picker);
    zgui.sameLine(.{});
    if (zgui.button("Preset picker", .{})) app.openPicker(.preset_picker);
    zgui.sameLine(.{});
    if (zgui.button("File browser", .{})) app.core.view = .file_browser;
}

pub const types = @import("core/types.zig");
pub const ring_buffer = @import("core/ring_buffer.zig");
pub const wav = @import("core/wav.zig");
pub const theme_identity = @import("theme_identity.zig");
pub const version = "1.0.0-beta.9";

pub const Transport = @import("transport.zig").Transport;
pub const TimeSignature = @import("transport.zig").TimeSignature;

pub const Project = @import("project.zig").Project;
pub const Track = @import("project.zig").Track;
pub const Section = @import("project.zig").Section;
pub const track_color_count = @import("project.zig").track_color_count;
pub const SendTarget = @import("project.zig").SendTarget;
pub const SendSlot = @import("project.zig").SendSlot;
pub const max_sends_per_track = @import("project.zig").max_sends_per_track;
pub const arrangement = @import("arrangement.zig");
pub const time_grid = @import("time_grid.zig");
pub const time_map = @import("time_map.zig");
pub const Arrangement = arrangement.Arrangement;
pub const Clip = arrangement.Clip;
pub const Rack = @import("rack.zig").Rack;
pub const Instrument = @import("rack.zig").Instrument;
pub const InstrumentKind = @import("rack.zig").InstrumentKind;
pub const Fx = @import("rack.zig").Fx;
pub const FxUnit = @import("rack.zig").FxUnit;
pub const FxPayload = @import("rack.zig").FxPayload;
pub const FxKind = @import("rack.zig").FxKind;
pub const plugin_catalog = @import("plugin_catalog.zig");
pub const vst3 = @import("vst3.zig");
pub const clap = @import("clap.zig");
pub const plugin_host = @import("plugin_host.zig");

pub const engine = @import("audio/engine.zig");
pub const Engine = engine.Engine;
pub const backend = @import("audio/backend.zig");
pub const audio_host = @import("audio/host.zig");
pub const AudioHost = audio_host.AudioHost;
pub const audio_input = @import("audio/capture.zig");
pub const AudioInput = audio_input.AudioInput;
pub const device_list = switch (@import("builtin").os.tag) {
    .linux => @import("audio/devices/linux.zig"),
    .windows => @import("audio/devices/windows.zig"),
    .macos => @import("audio/devices/macos.zig"),
    else => struct {
        pub fn write(_: *std.Io.Writer) !void {}
    },
};
pub const midi_velocity = @import("audio/midi/velocity.zig");
pub const alsa = if (@import("builtin").os.tag == .linux)
    @import("audio/backends/alsa.zig")
else
    struct {};
pub const pipewire = if (@import("builtin").os.tag == .linux)
    @import("audio/backends/pipewire.zig")
else
    struct {};
pub const jack = if (@import("builtin").os.tag == .linux)
    @import("audio/backends/jack.zig")
else
    struct {};
pub const wasapi = if (@import("builtin").os.tag == .windows)
    @import("audio/backends/wasapi.zig")
else
    struct {};
pub const coreaudio = if (@import("builtin").os.tag == .macos)
    @import("audio/backends/coreaudio.zig")
else
    struct {};
pub const midi_in = switch (@import("builtin").os.tag) {
    .linux => @import("audio/midi/linux.zig"),
    .macos => @import("audio/midi/macos.zig"),
    .windows => @import("audio/midi/windows.zig"),
    else => struct {},
};

pub const dsp = @import("dsp.zig");

pub const Session = @import("session.zig").Session;
pub const persist = @import("persist.zig");
pub const bounce = @import("bounce.zig");

pub const midi = @import("midi.zig");
pub const midi_file = @import("midi_file.zig");

pub const theory = @import("theory.zig");

pub const input = @import("input/modal.zig");
pub const ModalInput = input.ModalInput;

const std = @import("std");
const builtin = @import("builtin");

/// Platform user font directory.
pub fn iconFontDir(buf: []u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (std.c.getenv("LOCALAPPDATA")) |local| return std.fmt.bufPrint(buf, "{s}\\Microsoft\\Windows\\Fonts", .{std.mem.sliceTo(local, 0)});
        return error.NoFontDir;
    }
    if (builtin.os.tag == .macos) {
        if (std.c.getenv("HOME")) |home| return std.fmt.bufPrint(buf, "{s}/Library/Fonts", .{std.mem.sliceTo(home, 0)});
        return error.NoFontDir;
    }
    if (std.c.getenv("XDG_DATA_HOME")) |xdg| return std.fmt.bufPrint(buf, "{s}/fonts", .{std.mem.sliceTo(xdg, 0)});
    if (std.c.getenv("HOME")) |home| return std.fmt.bufPrint(buf, "{s}/.local/share/fonts", .{std.mem.sliceTo(home, 0)});
    return error.NoFontDir;
}

/// A 43-glyph subset of "Symbols Nerd Font Mono" (MIT; see
/// assets/fonts/LICENSE) used for the TUI's icons (ui/icons.zig). Exposed
/// here - rather than embedded directly in ui/icons.zig - so the
/// `install-font` build tool can reach it too: @embedFile can't cross a
/// module's root, and tools only import this "wstudio" module, not raw
/// paths under src/tui/.
pub const icon_font_ttf: []const u8 = @embedFile("assets/fonts/wstudio-icons.ttf");

/// DejaVu Sans is the GUI's bundled text face. Keeping it embedded makes the
/// desktop frontend independent of host font configuration.
pub const gui_font_ttf: []const u8 = @embedFile("assets/fonts/DejaVuSans.ttf");

test "embedded GUI face looks like a valid TrueType font" {
    try std.testing.expectEqualStrings("\x00\x01\x00\x00", gui_font_ttf[0..4]);
    try std.testing.expect(gui_font_ttf.len > 100 * 1024 and gui_font_ttf.len < 1024 * 1024);
}

test {
    std.testing.refAllDecls(@This());
}

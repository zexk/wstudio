pub const types = @import("core/types.zig");
pub const ring_buffer = @import("core/ring_buffer.zig");
pub const wav = @import("core/wav.zig");

pub const Transport = @import("transport.zig").Transport;
pub const TimeSignature = @import("transport.zig").TimeSignature;

pub const Project = @import("project.zig").Project;
pub const Track = @import("project.zig").Track;
pub const track_color_count = @import("project.zig").track_color_count;
pub const arrangement = @import("arrangement.zig");
pub const Arrangement = arrangement.Arrangement;
pub const Clip = arrangement.Clip;
pub const Rack = @import("rack.zig").Rack;
pub const Instrument = @import("rack.zig").Instrument;
pub const InstrumentKind = @import("rack.zig").InstrumentKind;
pub const Fx = @import("rack.zig").Fx;
pub const FxUnit = @import("rack.zig").FxUnit;
pub const FxPayload = @import("rack.zig").FxPayload;
pub const FxKind = @import("rack.zig").FxKind;

pub const engine = @import("audio/engine.zig");
pub const Engine = engine.Engine;
pub const backend = @import("audio/backend.zig");
pub const alsa = if (@import("builtin").os.tag == .linux)
    @import("audio/alsa.zig")
else
    struct {};
pub const wasapi = if (@import("builtin").os.tag == .windows)
    @import("audio/wasapi.zig")
else
    struct {};
pub const midi_in = if (@import("builtin").os.tag == .linux)
    @import("audio/midi_in.zig")
else
    struct {};

pub const dsp = @import("dsp.zig");

pub const Session = @import("session.zig").Session;
pub const persist = @import("persist.zig");

pub const midi = @import("midi.zig");

pub const theory = @import("theory.zig");

pub const input = @import("input/modal.zig");
pub const ModalInput = input.ModalInput;

/// A 16-glyph subset of "Symbols Nerd Font Mono" (MIT; see
/// assets/fonts/LICENSE) used for the TUI's icons (tui/icons.zig). Exposed
/// here - rather than embedded directly in tui/icons.zig - so the
/// `install-font` build tool can reach it too: @embedFile can't cross a
/// module's root, and tools only import this "wstudio" module, not raw
/// paths under src/tui/.
pub const icon_font_ttf: []const u8 = @embedFile("assets/fonts/wstudio-icons.ttf");

test {
    _ = midi;
    _ = midi_in;
    _ = types;
    _ = ring_buffer;
    _ = wav;
    _ = Transport;
    _ = Project;
    _ = engine;
    _ = backend;
    _ = alsa;
    _ = wasapi;
    _ = dsp;
    _ = Session;
    _ = persist;
    _ = theory;
    _ = input;
}

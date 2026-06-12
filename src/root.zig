//! wstudio engine library. Frontends import this module; nothing else
//! in src/ is public API.

pub const types = @import("core/types.zig");
pub const ring_buffer = @import("core/ring_buffer.zig");
pub const wav = @import("core/wav.zig");

pub const Transport = @import("transport.zig").Transport;
pub const TimeSignature = @import("transport.zig").TimeSignature;

pub const Project = @import("project.zig").Project;
pub const Track = @import("project.zig").Track;

pub const engine = @import("audio/engine.zig");
pub const Engine = engine.Engine;
pub const backend = @import("audio/backend.zig");

pub const dsp = @import("dsp.zig");

pub const input = @import("input/modal.zig");
pub const ModalInput = input.ModalInput;

pub const tui = struct {
    pub const terminal = @import("tui/terminal.zig");
    pub const App = @import("tui/app.zig").App;
    pub const run = @import("tui/app.zig").run;
};

// Reference every namespace so `zig build test` picks up their tests.
test {
    _ = types;
    _ = ring_buffer;
    _ = wav;
    _ = Transport;
    _ = Project;
    _ = engine;
    _ = backend;
    _ = dsp;
    _ = input;
    _ = tui.terminal;
    _ = tui.App;
}

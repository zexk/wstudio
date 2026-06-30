pub const types = @import("core/types.zig");
pub const ring_buffer = @import("core/ring_buffer.zig");
pub const wav = @import("core/wav.zig");

pub const Transport = @import("transport.zig").Transport;
pub const TimeSignature = @import("transport.zig").TimeSignature;

pub const Project = @import("project.zig").Project;
pub const Track = @import("project.zig").Track;
pub const arrangement = @import("arrangement.zig");
pub const Arrangement = arrangement.Arrangement;
pub const Clip = arrangement.Clip;
pub const Rack = @import("rack.zig").Rack;
pub const Instrument = @import("rack.zig").Instrument;
pub const InstrumentKind = @import("rack.zig").InstrumentKind;
pub const Fx = @import("rack.zig").Fx;

pub const engine = @import("audio/engine.zig");
pub const Engine = engine.Engine;
pub const backend = @import("audio/backend.zig");
pub const alsa = if (@import("builtin").os.tag == .linux)
    @import("audio/alsa.zig")
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

pub const input = @import("input/modal.zig");
pub const ModalInput = input.ModalInput;

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
    _ = dsp;
    _ = Session;
    _ = persist;
    _ = input;
}

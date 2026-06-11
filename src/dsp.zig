//! Built-in device rack: instruments and effects that ship with the
//! app. All implement the `Device` interface in `dsp/device.zig`.

pub const device = @import("dsp/device.zig");
pub const Device = device.Device;
pub const Event = device.Event;

pub const PolySynth = @import("dsp/synth.zig").PolySynth;
pub const Waveform = @import("dsp/synth.zig").Waveform;
pub const StereoDelay = @import("dsp/delay.zig").StereoDelay;
pub const Reverb = @import("dsp/reverb.zig").Reverb;
pub const Compressor = @import("dsp/compressor.zig").Compressor;

test {
    _ = device;
    _ = PolySynth;
    _ = StereoDelay;
    _ = Reverb;
    _ = Compressor;
}

pub const device = @import("dsp/device.zig");
pub const Device = device.Device;
pub const Event = device.Event;

pub const PolySynth = @import("dsp/synth.zig").PolySynth;
pub const Waveform = @import("dsp/synth.zig").Waveform;
pub const synth_presets = @import("dsp/synth_presets.zig");
pub const StereoDelay = @import("dsp/delay.zig").StereoDelay;
pub const Reverb = @import("dsp/reverb.zig").Reverb;
pub const Compressor = @import("dsp/compressor.zig").Compressor;
pub const Limiter = @import("dsp/limiter.zig").Limiter;
pub const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
pub const Pad = @import("dsp/pad.zig").Pad;
pub const pad = @import("dsp/pad.zig");
pub const Sampler = @import("dsp/sampler.zig").Sampler;
pub const drum_kit = @import("dsp/drum_kit.zig");

pub const pattern = @import("dsp/pattern.zig");
pub const PatternPlayer = pattern.PatternPlayer;

pub const automation = @import("dsp/automation.zig");
pub const AutomationPoint = automation.AutomationPoint;
pub const AutomationCurve = automation.AutomationCurve;

pub const fft = @import("dsp/fft.zig");
pub const SpectrumAnalyzer = @import("dsp/spectrum.zig").SpectrumAnalyzer;
pub const spectrum = @import("dsp/spectrum.zig");
pub const GraphicEq = @import("dsp/eq.zig").GraphicEq;
pub const eq = @import("dsp/eq.zig");

test {
    _ = device;
    _ = PolySynth;
    _ = synth_presets;
    _ = StereoDelay;
    _ = Reverb;
    _ = Compressor;
    _ = Limiter;
    _ = DrumMachine;
    _ = pad;
    _ = Sampler;
    _ = drum_kit;
    _ = pattern;
    _ = automation;
    _ = fft;
    _ = SpectrumAnalyzer;
    _ = GraphicEq;
}

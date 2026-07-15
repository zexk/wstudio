pub const device = @import("dsp/device.zig");
pub const Device = device.Device;
pub const Event = device.Event;

pub const synth = @import("dsp/synth.zig");
pub const PolySynth = synth.PolySynth;
pub const Waveform = synth.Waveform;
pub const wavetable = @import("dsp/wavetable.zig");
pub const synth_presets = @import("dsp/synth_presets.zig");
pub const StereoDelay = @import("dsp/delay.zig").StereoDelay;
pub const Reverb = @import("dsp/reverb.zig").Reverb;
pub const Compressor = @import("dsp/compressor.zig").Compressor;
pub const multiband_comp = @import("dsp/multiband_comp.zig");
pub const MultibandComp = multiband_comp.MultibandComp;
pub const Ott = @import("dsp/ott.zig").Ott;
pub const Limiter = @import("dsp/limiter.zig").Limiter;
pub const Gate = @import("dsp/gate.zig").Gate;
pub const Saturator = @import("dsp/saturator.zig").Saturator;
pub const Crusher = @import("dsp/crusher.zig").Crusher;
pub const Chorus = @import("dsp/chorus.zig").Chorus;
pub const chorus = @import("dsp/chorus.zig");
pub const Phaser = @import("dsp/phaser.zig").Phaser;
pub const Flanger = @import("dsp/flanger.zig").Flanger;
pub const Tape = @import("dsp/tape.zig").Tape;
pub const FreqShifter = @import("dsp/freq_shift.zig").FreqShifter;
pub const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
pub const Pad = @import("dsp/pad.zig").Pad;
pub const pad = @import("dsp/pad.zig");
pub const Sampler = @import("dsp/sampler.zig").Sampler;
pub const pitch = @import("dsp/pitch.zig");
pub const drum_kit = @import("dsp/drum_kit.zig");
pub const Slicer = @import("dsp/slicer.zig").Slicer;

pub const pattern = @import("dsp/pattern.zig");
pub const PatternPlayer = pattern.PatternPlayer;

pub const automation = @import("dsp/automation.zig");
pub const AutomationPoint = automation.AutomationPoint;
pub const AutomationCurve = automation.AutomationCurve;

pub const fft = @import("dsp/fft.zig");
pub const SpectrumAnalyzer = @import("dsp/spectrum.zig").SpectrumAnalyzer;
pub const spectrum = @import("dsp/spectrum.zig");
pub const ParametricEq = @import("dsp/eq.zig").ParametricEq;
pub const eq = @import("dsp/eq.zig");

test {
    _ = device;
    _ = PolySynth;
    _ = wavetable;
    _ = synth_presets;
    _ = StereoDelay;
    _ = Reverb;
    _ = Compressor;
    _ = MultibandComp;
    _ = Ott;
    _ = Limiter;
    _ = Gate;
    _ = Saturator;
    _ = Crusher;
    _ = Chorus;
    _ = Phaser;
    _ = Flanger;
    _ = Tape;
    _ = FreqShifter;
    _ = DrumMachine;
    _ = pad;
    _ = Sampler;
    _ = pitch;
    _ = drum_kit;
    _ = Slicer;
    _ = pattern;
    _ = automation;
    _ = fft;
    _ = SpectrumAnalyzer;
    _ = ParametricEq;
}

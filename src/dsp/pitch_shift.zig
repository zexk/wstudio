//! Granular pitch shifter: transposes without changing playback speed, so a
//! bass line drops an octave and a vocal takes a harmony without either
//! getting longer.
//!
//! Two read taps chase the write head through one circular line per channel.
//! Each tap's delay sweeps the full grain length at `1 - rate` samples per
//! sample, which makes the read position advance at `rate` and is the whole
//! transposition; the taps sit half a grain apart and are Hann-windowed, so
//! the one crossing the discontinuity is silent exactly where the other is
//! at full level and the two windows sum to unity everywhere between.
//!
//! Chosen over a phase vocoder (an FFT per block, plus phase-locking work to
//! avoid a smeared "phasey" transient) because this is a handful of reads per
//! sample with no block latency beyond the grain itself, and over the pad's
//! WSOLA (dsp/pad.zig) because that one hops through a fully buffered sample
//! it can correlation-search; a live insert has only the past to read from.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const delay_line = @import("delay_line.zig");

const Sample = types.Sample;

/// Longest grain the editor allows, and what the line is sized for. Past
/// ~120ms the two taps drift far enough apart to hear as a doubling rather
/// than one voice.
pub const max_grain_ms: f32 = 120.0;
/// Shortest, in ms. Below this a grain is under one period of a low note, so
/// the window chops the fundamental into a buzz.
pub const min_grain_ms: f32 = 10.0;

/// Transposition small enough to treat as none. The two taps are static at
/// exactly unity rate, which would leave a fixed two-tap comb filter in the
/// signal rather than a passthrough - so the whole grain machinery is
/// skipped here instead. Just under a cent, far below the ~5 cent beating a
/// player can hear against an unshifted source.
const unity_epsilon: f32 = 0.005;

pub const PitchShift = struct {
    sample_rate: u32,
    lines: [2][]Sample,
    index: usize = 0,
    /// Position within the grain cycle, 0..1 - the tap delays and both
    /// window levels derive from it. Shared by both channels so a stereo
    /// source keeps its image instead of the two sides windowing apart.
    phase: f32 = 0.0,
    /// Transposition in semitones, plus a fine offset in cents. Two controls
    /// rather than one so a harmony interval stays exact while a detune
    /// stays reachable - a single semitone knob fine enough to detune would
    /// need 24 turns to reach an octave.
    semitones: f32 = 0.0,
    cents: f32 = 0.0,
    grain_ms: f32 = 60.0,
    /// 0 = dry only, 1 = wet only. Defaults to fully wet: a shifter is
    /// usually asked to replace the pitch, not to double it (dial it back
    /// for a harmony against the original).
    mix: f32 = 1.0,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !PitchShift {
        const safe_rate = @max(sample_rate, 1);
        // The deepest tap sits one full grain behind the write head; the
        // extra frames are the interpolator's 4-point window plus slack.
        const frames: usize = @intFromFloat(max_grain_ms * 0.001 * @as(f32, @floatFromInt(safe_rate)));
        const left = try allocator.alloc(Sample, @max(frames + 8, 8));
        errdefer allocator.free(left);
        const right = try allocator.alloc(Sample, @max(frames + 8, 8));
        @memset(left, 0.0);
        @memset(right, 0.0);
        return .{
            .sample_rate = safe_rate,
            .lines = .{ left, right },
        };
    }

    pub fn deinit(self: *PitchShift, allocator: std.mem.Allocator) void {
        allocator.free(self.lines[0]);
        allocator.free(self.lines[1]);
    }

    pub fn reset(self: *PitchShift) void {
        @memset(self.lines[0], 0.0);
        @memset(self.lines[1], 0.0);
        self.index = 0;
        self.phase = 0.0;
    }

    pub const device = dsp.deviceOf(@This());

    // No `latencyFrames`: each tap's delay sweeps the whole grain rather
    // than sitting at a fixed offset, so there is no constant figure to
    // report. Declaring the grain length would have the engine delay every
    // other chain by an amount this one only hits once per cycle.

    /// Pitch-shift an interleaved stereo buffer in place.
    pub fn processBlock(self: *PitchShift, buf: []Sample) void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const semis = dsp.sanitizeParam(self.semitones, -24.0, 24.0, 0.0) +
            dsp.sanitizeParam(self.cents, -100.0, 100.0, 0.0) / 100.0;
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 1.0);
        const grain_ms = dsp.sanitizeParam(self.grain_ms, min_grain_ms, max_grain_ms, 60.0);
        // One frame short of the allocated span, so the deepest tap plus the
        // interpolator's lookahead can never reach past the write head.
        const grain: f32 = @min(grain_ms * 0.001 * sr, @as(f32, @floatFromInt(self.lines[0].len - 8)));
        const rate = std.math.pow(f32, 2.0, semis / 12.0);
        const inc = (1.0 - rate) / @max(grain, 1.0);
        const unity = @abs(semis) < unity_epsilon;

        if (!std.math.isFinite(self.phase)) self.phase = 0.0;

        const frames = buf.len / 2;
        for (0..frames) |i| {
            inline for (0..2) |ch| {
                const line = self.lines[ch];
                const dry = dsp.sanitizeParam(buf[i * 2 + ch], -16.0, 16.0, 0.0);
                line[self.index] = dry;
                const wet = if (unity) dry else blk: {
                    const other = @mod(self.phase + 0.5, 1.0);
                    const a = delay_line.readInterp(line, self.index, self.phase * grain);
                    const b = delay_line.readInterp(line, self.index, other * grain);
                    break :blk a * hann(self.phase) + b * hann(other);
                };
                buf[i * 2 + ch] = dry * (1.0 - mix) + wet * mix;
            }
            self.phase += inc;
            self.phase -= @floor(self.phase);
            self.index = (self.index + 1) % self.lines[0].len;
        }
    }
};

/// Hann window over one grain cycle, zero at the wrap point where the tap
/// jumps. `hann(x) + hann(x + 0.5)` is 1 for every x, which is what lets the
/// two taps cross over without a level dip.
fn hann(x: f32) f32 {
    return 0.5 - 0.5 * @cos(2.0 * std.math.pi * x);
}

test "the two grain windows always sum to unity" {
    var x: f32 = 0.0;
    while (x < 1.0) : (x += 0.01) {
        const other = @mod(x + 0.5, 1.0);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), hann(x) + hann(other), 1e-5);
    }
}

test "no transposition passes the signal through untouched" {
    var shifter = try PitchShift.init(std.testing.allocator, 48_000);
    defer shifter.deinit(std.testing.allocator);
    var buf = [_]Sample{ 0.5, -0.25, 0.75, 0.125 };
    shifter.processBlock(&buf);
    try std.testing.expectEqualSlices(Sample, &.{ 0.5, -0.25, 0.75, 0.125 }, &buf);
}

test "shifting an octave up halves the period of a sine" {
    const sr: u32 = 48_000;
    var shifter = try PitchShift.init(std.testing.allocator, sr);
    defer shifter.deinit(std.testing.allocator);
    shifter.semitones = 12.0;

    // 500 Hz in; count zero crossings out over a settled stretch and expect
    // roughly twice as many. Loose bounds: the grain crossfade smears the
    // waveform, so this checks the transposition, not a spectral purity the
    // algorithm doesn't claim.
    var buf: [4_800]Sample = undefined;
    var n: usize = 0;
    var crossings: usize = 0;
    for (0..8) |block| {
        for (0..buf.len / 2) |i| {
            const t = @as(f32, @floatFromInt(n + i)) / @as(f32, @floatFromInt(sr));
            const s = @sin(2.0 * std.math.pi * 500.0 * t);
            buf[i * 2] = s;
            buf[i * 2 + 1] = s;
        }
        shifter.processBlock(&buf);
        n += buf.len / 2;
        if (block < 4) continue; // let the line fill and the grain cycle settle
        var prev = buf[0];
        for (1..buf.len / 2) |i| {
            const cur = buf[i * 2];
            if ((prev <= 0.0 and cur > 0.0) or (prev >= 0.0 and cur < 0.0)) crossings += 1;
            prev = cur;
        }
    }
    // 4 blocks x 2400 frames = 0.2s. 500 Hz has 200 crossings there, 1 kHz
    // has 400.
    try std.testing.expect(crossings > 300);
    try std.testing.expect(crossings < 500);
}

test "pitch shift stays finite and bounded under hostile input" {
    var shifter = try PitchShift.init(std.testing.allocator, 48_000);
    defer shifter.deinit(std.testing.allocator);
    shifter.semitones = std.math.nan(f32);
    shifter.cents = std.math.inf(f32);
    shifter.grain_ms = -1.0;
    shifter.mix = std.math.nan(f32);
    var buf = [_]Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1.0 };
    shifter.processBlock(&buf);
    for (buf) |s| try std.testing.expect(std.math.isFinite(s));

    shifter.semitones = -24.0;
    shifter.cents = 0.0;
    shifter.grain_ms = 60.0;
    shifter.mix = 1.0;
    try dsp.expectBoundedUnderNoise(&shifter, 2.0);
}

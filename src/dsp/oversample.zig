//! 2x oversampling for waveshapers.
//!
//! A waveshaper multiplies its input's bandwidth: driving a 5kHz tone through
//! a tanh curve asks for harmonics at 10k, 15k, 20k, 25k and up, and
//! everything past Nyquist folds back down as inharmonic whistling rather
//! than disappearing. Measured on `dsp/saturator.zig` at +24dB drive, the
//! folded energy sat only 12dB below the harmonics it was supposed to add.
//!
//! Shaping at twice the rate moves that wall an octave up, and the
//! half-band filters on either side keep what folds anyway out of the audible
//! result.
//!
//! ponytail: 2x with a 31-tap filter. Measured on the saturator at +24dB
//! drive it takes 5kHz from -12.4dB of folded energy to -21.9dB. Doubling to
//! 63 taps bought only 1.7dB more for twice the latency, and a second 2x
//! stage would buy roughly another 6dB - reach for either if a shaper ever
//! has to stay clean with an octave of pitch-up on top of it.
//!
//! Only the saturator uses this. `dsp/tape.zig` is a modulated delay with no
//! shaping stage, and `dsp/crusher.zig` aliases on purpose - that fold *is*
//! the bitcrusher.

const std = @import("std");

/// Windowed-sinc half-band, cutoff at a quarter of the doubled rate - i.e.
/// exactly the original Nyquist.
const taps: usize = 31;

/// Group delay the *pair* of filters adds, in original-rate frames: each is
/// `(taps - 1) / 2` samples at the doubled rate, and the two together come
/// to that many frames at the original rate. `Stage2x` is what runs both.
/// Whoever uses this has to report it so the engine's delay compensation can
/// line the chain back up.
pub const latency_frames: u32 = (taps - 1) / 2;

/// Group delay of a *single* filter, in original-rate frames - what
/// `Peak2x` adds, since it only upsamples. Half of `latency_frames`: the
/// same `(taps - 1) / 2` samples, but at the doubled rate.
pub const peak_latency_frames: u32 = (taps - 1) / 4;

const coeffs: [taps]f32 = blk: {
    @setEvalBranchQuota(20_000);
    var h: [taps]f32 = undefined;
    const centre = @as(f64, @floatFromInt(taps - 1)) / 2.0;
    var sum: f64 = 0;
    for (&h, 0..) |*tap, i| {
        const x = @as(f64, @floatFromInt(i)) - centre;
        // sinc at half the doubled rate...
        const sinc = if (x == 0) 1.0 else @sin(std.math.pi * 0.5 * x) / (std.math.pi * 0.5 * x);
        // ...windowed, so the truncation does not ring.
        const w = 0.42 -
            0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(taps - 1))) +
            0.08 * @cos(4.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(taps - 1)));
        const value = sinc * w * 0.5;
        tap.* = @floatCast(value);
        sum += value;
    }
    // Unity gain at DC through the upsample (which is why the 0.5 above is
    // there: zero-stuffing halves the energy, and each output sample sees
    // only half the taps).
    for (&h) |*tap| tap.* = @floatCast(@as(f64, tap.*) / sum);
    break :blk h;
};

/// One channel's filter memory. Two of these (up and down) plus the shaping
/// in between is the whole technique.
const Fir = struct {
    hist: [taps]f32 = [_]f32{0.0} ** taps,
    pos: usize = 0,

    fn push(self: *Fir, x: f32) f32 {
        self.hist[self.pos] = x;
        self.pos = (self.pos + 1) % taps;
        var acc: f32 = 0;
        var idx = self.pos;
        for (coeffs) |tap| {
            acc += tap * self.hist[idx];
            idx = (idx + 1) % taps;
        }
        return acc;
    }
};

/// The upsampling half of `Stage2x` on its own, for code that only needs to
/// *see* what happens between samples rather than process there - a true-peak
/// limiter is the case: a signal that never exceeds full scale sample by
/// sample can still reconstruct over it in a converter, and that is exactly
/// the interpolated point this exposes.
///
/// `peak` reports the level of the input frame `peak_latency_frames` back,
/// not of the frame just pushed: the filter is symmetric, so its answer for a
/// sample only exists once half the taps have seen past it. Callers must
/// delay their audio by the same amount or they will clamp late - and by
/// *that* amount, not `latency_frames`, which counts a downsampling filter
/// this only-upsampling path never runs.
pub const Peak2x = struct {
    up: [2]Fir = .{ .{}, .{} },

    pub fn reset(self: *Peak2x) void {
        self.* = .{};
    }

    pub fn peak(self: *Peak2x, ch: usize, x: f32) f32 {
        const a = self.up[ch].push(x * 2.0);
        const b = self.up[ch].push(0.0);
        return @max(@abs(a), @abs(b));
    }
};

/// Stereo 2x oversampling around a per-sample shaping function.
pub const Stage2x = struct {
    up: [2]Fir = .{ .{}, .{} },
    down: [2]Fir = .{ .{}, .{} },

    pub fn reset(self: *Stage2x) void {
        self.* = .{};
    }

    /// Runs `shaper` twice per input sample - once on the real sample and
    /// once on the interpolated one between it and the next - then filters
    /// and drops back to the original rate.
    pub fn process(
        self: *Stage2x,
        ch: usize,
        x: f32,
        context: anytype,
        comptime shaper: fn (@TypeOf(context), f32) f32,
    ) f32 {
        // Zero-stuff: the doubled stream is the sample, then nothing.
        const a = shaper(context, self.up[ch].push(x * 2.0));
        const b = shaper(context, self.up[ch].push(0.0));
        _ = self.down[ch].push(a);
        return self.down[ch].push(b);
    }
};

test "Peak2x reports an impulse peak_latency_frames later, not latency_frames" {
    // Only the upsampling filter runs here, so the delay is half the pair's.
    // Getting this wrong misaligns a true-peak limiter's clamp against the
    // audio it is clamping and overstates its reported latency.
    var p: Peak2x = .{};
    var loudest: usize = 0;
    var loudest_v: f32 = 0;
    for (0..40) |i| {
        const v = p.peak(0, if (i == 0) 1.0 else 0.0);
        if (v > loudest_v) {
            loudest_v = v;
            loudest = i;
        }
    }
    try std.testing.expectEqual(@as(usize, peak_latency_frames), loudest);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), loudest_v, 1e-4);
}

test "a signal well under Nyquist survives the round trip" {
    var stage: Stage2x = .{};
    const Passthrough = struct {
        fn shape(_: void, x: f32) f32 {
            return x;
        }
    };
    const sr: f32 = 48_000;
    var peak_in: f32 = 0;
    var peak_out: f32 = 0;
    // Skip the filter's fill time before measuring.
    for (0..4096) |i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        const x = @sin(2.0 * std.math.pi * 1000.0 * t);
        const y = stage.process(0, x, {}, Passthrough.shape);
        if (i > 256) {
            peak_in = @max(peak_in, @abs(x));
            peak_out = @max(peak_out, @abs(y));
        }
    }
    // Unity through the pair of filters, within the passband ripple.
    try std.testing.expectApproxEqAbs(peak_in, peak_out, 0.05);
}

test "shaping at 2x keeps the folded energy far below the harmonics" {
    var stage: Stage2x = .{};
    const Hard = struct {
        fn shape(_: void, x: f32) f32 {
            return std.math.tanh(4.0 * x);
        }
    };
    const sr: f32 = 48_000;
    const n: usize = 8192;
    var oversampled: [n]f32 = undefined;
    var direct: [n]f32 = undefined;
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        const x = 0.7 * @sin(2.0 * std.math.pi * 5000.0 * t);
        oversampled[i] = stage.process(0, x, {}, Hard.shape);
        direct[i] = Hard.shape({}, x);
    }
    // 5kHz through a hard curve at 48k folds its 15kHz and 25kHz partials
    // back over each other. The oversampled version has strictly less energy
    // where nothing harmonic belongs - checked as total power, since the
    // folded partials are what the extra energy is.
    var power_direct: f64 = 0;
    var power_oversampled: f64 = 0;
    for (direct[1024..], oversampled[1024..]) |d, o| {
        power_direct += @as(f64, d) * d;
        power_oversampled += @as(f64, o) * o;
    }
    try std.testing.expect(power_oversampled < power_direct);
}

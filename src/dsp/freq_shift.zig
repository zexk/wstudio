//! Bode-style frequency shifter: moves every partial by a fixed Hz amount
//! (unlike a pitch shifter, which preserves harmonic ratios) via single-
//! sideband modulation. The input is turned into an analytic signal by a
//! Hilbert transform (two cascaded allpass filter banks, ~0.7° phase error
//! from 20Hz to Nyquist at 44.1/48kHz), then multiplied by a complex
//! quadrature oscillator and the real part taken. A signed `shift_hz` picks
//! the direction: positive shifts up, negative down - the classic single
//! bipolar control a Bode/Moog frequency shifter exposes.
//!
//! Hilbert transform structure and coefficients: Olli Niemitalo, "Hilbert
//! transform" (yehar.com/blog/?p=368) - the four-section, ~0.7° design.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

const num_sections = 4;

/// Branch 2 (the "real" component) - no extra delay.
const branch2_a = [num_sections]f32{ 0.4021921162426, 0.8561710882420, 0.9722909545651, 0.9952884791278 };
/// Branch 1 (the "imaginary" component) - gets a trailing one-sample delay
/// (see `Channel.process`) so its poles/zeros interleave with branch 2's on
/// the real axis, which is what gives the pair its low ripple.
const branch1_a = [num_sections]f32{ 0.6923878, 0.9360654322959, 0.9882295226860, 0.9987488452737 };

/// One cascaded second-order allpass stage: out(t) = a²·(in(t)+out(t-2)) - in(t-2).
const ApSection = struct {
    a2: f32,
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    fn process(self: *ApSection, in: f32) f32 {
        const out = self.a2 * (in + self.y2) - self.x2;
        self.x2 = self.x1;
        self.x1 = in;
        self.y2 = self.y1;
        self.y1 = out;
        return out;
    }

    fn reset(self: *ApSection) void {
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }
};

fn initBranch(comptime a_vals: [num_sections]f32) [num_sections]ApSection {
    var sects: [num_sections]ApSection = undefined;
    for (a_vals, 0..) |a, i| sects[i] = .{ .a2 = a * a };
    return sects;
}

/// Per-channel Hilbert transformer: `process` returns the analytic signal's
/// (re, im) pair for one input sample.
const Channel = struct {
    branch1: [num_sections]ApSection = initBranch(branch1_a),
    branch2: [num_sections]ApSection = initBranch(branch2_a),
    delay1: f32 = 0.0,

    fn process(self: *Channel, in: f32) struct { re: f32, im: f32 } {
        var s2 = in;
        for (&self.branch2) |*sect| s2 = sect.process(s2);

        var s1 = in;
        for (&self.branch1) |*sect| s1 = sect.process(s1);
        const im = self.delay1;
        self.delay1 = s1;

        return .{ .re = s2, .im = im };
    }

    fn reset(self: *Channel) void {
        for (&self.branch1) |*sect| sect.reset();
        for (&self.branch2) |*sect| sect.reset();
        self.delay1 = 0.0;
    }
};

pub const FreqShifter = struct {
    sample_rate: f32 = 48_000.0,
    /// Bipolar shift in Hz: positive moves every partial up, negative down.
    shift_hz: f32 = 0.0,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 1.0,
    /// Quadrature oscillator phase, radians, wrapped to [-2π, 2π).
    phase: f32 = 0.0,
    ch: [2]Channel = .{ .{}, .{} },

    pub fn init(sample_rate: u32) FreqShifter {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *FreqShifter, buf: []Sample) void {
        const phase_inc = 2.0 * std.math.pi * self.shift_hz / self.sample_rate;
        const frames = buf.len / 2;
        for (0..frames) |i| {
            const c = @cos(self.phase);
            const s = @sin(self.phase);
            inline for (0..2) |ch| {
                const dry = buf[i * 2 + ch];
                const iq = self.ch[ch].process(dry);
                const wet = iq.re * c - iq.im * s;
                buf[i * 2 + ch] = dry * (1.0 - self.mix) + wet * self.mix;
            }
            self.phase += phase_inc;
            if (self.phase >= 2.0 * std.math.pi) self.phase -= 2.0 * std.math.pi;
            if (self.phase < -2.0 * std.math.pi) self.phase += 2.0 * std.math.pi;
        }
    }

    /// Clears the allpass/delay history and oscillator phase, leaving
    /// sample_rate and the user-facing params (shift/mix) untouched.
    pub fn reset(self: *FreqShifter) void {
        for (&self.ch) |*c| c.reset();
        self.phase = 0.0;
    }
};

// ---------------------------------------------------------------------------
// Tests

test "mix 0 passes the input untouched" {
    var fs = FreqShifter.init(48_000);
    fs.mix = 0.0;
    fs.shift_hz = 300.0;
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    const expected = buf;
    fs.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "output stays bounded under sustained input" {
    var fs = FreqShifter.init(48_000);
    fs.shift_hz = 500.0;
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var buf: [512]Sample = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        for (&buf) |*s| s.* = rand.float(f32) * 2.0 - 1.0;
        fs.processBlock(&buf);
        for (buf) |s| try std.testing.expect(@abs(s) < 10.0);
    }
}

test "silence in, silence out" {
    var fs = FreqShifter.init(48_000);
    fs.shift_hz = 200.0;
    var buf = [_]Sample{0.0} ** 256;
    fs.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
}

/// Single-frequency magnitude via a direct O(N) DFT bin (Goertzel-equivalent) -
/// good enough at test size to tell "energy moved to the shifted frequency"
/// from "energy stayed put", which is the property that actually matters:
/// a sign error in the Hilbert combine would shift down instead of up (or
/// leave both sidebands present), and this test would catch either.
fn dftMag(buf: []const Sample, freq_hz: f32, sr: f32) f32 {
    var re: f32 = 0.0;
    var im: f32 = 0.0;
    for (buf, 0..) |s, n| {
        const theta = 2.0 * std.math.pi * freq_hz * @as(f32, @floatFromInt(n)) / sr;
        re += s * @cos(theta);
        im -= s * @sin(theta);
    }
    return @sqrt(re * re + im * im);
}

test "upshift moves a pure tone's energy to input+shift, not input-shift" {
    const sr: f32 = 48_000.0;
    var fs = FreqShifter.init(48_000);
    fs.shift_hz = 200.0;

    const settle = 4000;
    const measure = 4096;
    var buf: [settle + measure]Sample = undefined;
    for (&buf, 0..) |*s, n| {
        const theta = 2.0 * std.math.pi * 1000.0 * @as(f32, @floatFromInt(n)) / sr;
        s.* = @sin(theta);
    }
    // Interleave into a fake stereo buffer (mono source on both channels),
    // process, then read channel 0 back out for analysis.
    var stereo: [(settle + measure) * 2]Sample = undefined;
    for (buf, 0..) |s, n| {
        stereo[n * 2] = s;
        stereo[n * 2 + 1] = s;
    }
    fs.processBlock(&stereo);

    var mono: [measure]Sample = undefined;
    for (0..measure) |n| mono[n] = stereo[(settle + n) * 2];

    const up = dftMag(&mono, 1200.0, sr); // 1000 + 200
    const down = dftMag(&mono, 800.0, sr); // 1000 - 200 (the wrong sideband)
    try std.testing.expect(up > down * 4.0);
}

test "downshift (negative shift_hz) moves energy the other way" {
    const sr: f32 = 48_000.0;
    var fs = FreqShifter.init(48_000);
    fs.shift_hz = -200.0;

    const settle = 4000;
    const measure = 4096;
    var stereo: [(settle + measure) * 2]Sample = undefined;
    for (0..settle + measure) |n| {
        const theta = 2.0 * std.math.pi * 1000.0 * @as(f32, @floatFromInt(n)) / sr;
        const s = @sin(theta);
        stereo[n * 2] = s;
        stereo[n * 2 + 1] = s;
    }
    fs.processBlock(&stereo);

    var mono: [measure]Sample = undefined;
    for (0..measure) |n| mono[n] = stereo[(settle + n) * 2];

    const up = dftMag(&mono, 1200.0, sr);
    const down = dftMag(&mono, 800.0, sr);
    try std.testing.expect(down > up * 4.0);
}

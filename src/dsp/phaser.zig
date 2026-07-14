//! Stereo phaser: four first-order allpass stages per channel, their corner
//! frequency swept by a sine LFO (the right channel a quarter cycle behind),
//! with feedback around the cascade. Mixed 50/50 against the dry path the
//! phase rotation carves the moving notches the effect is named for.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

const num_stages = 4;
/// Sweep floor; depth 1 carries the corner ~4.5 octaves up (≈100Hz–2.3kHz).
const sweep_lo_hz: f32 = 100.0;
const sweep_octaves: f32 = 4.5;

pub const Phaser = struct {
    /// Only meaningful for a bare `.{}` (PolySynth's internal-FX slot embeds
    /// one by value); every other caller sets the real rate via `init`.
    sample_rate: f32 = 48_000.0,
    rate_hz: f32 = 0.4,
    /// 0 = parked at the sweep floor, 1 = full ~4.5-octave sweep.
    depth: f32 = 0.9,
    feedback: f32 = 0.5,
    /// 0 = dry only, 1 = wet only. 0.5 gives the deepest notches.
    mix: f32 = 0.5,
    phase: f32 = 0.0,
    /// Per-channel allpass state: x[n-1] / y[n-1] for each stage, plus the
    /// previous cascade output feeding the feedback path.
    x1: [2][num_stages]f32 = .{ .{ 0.0, 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0, 0.0 } },
    y1: [2][num_stages]f32 = .{ .{ 0.0, 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0, 0.0 } },
    fb: [2]f32 = .{ 0.0, 0.0 },

    pub fn init(sample_rate: u32) Phaser {
        return .{ .sample_rate = @floatFromInt(sample_rate) };
    }

    pub const device = dsp.deviceOf(@This());

    /// Phase an interleaved stereo buffer in place.
    pub fn processBlock(self: *Phaser, buf: []Sample) void {
        const phase_inc = 2.0 * std.math.pi * self.rate_hz / self.sample_rate;
        const frames = buf.len / 2;
        for (0..frames) |i| {
            inline for (0..2) |ch| {
                // LFO 0..1, mapped exponentially across the sweep range.
                const lfo = (@sin(self.phase - @as(f32, @floatFromInt(ch)) * (std.math.pi / 2.0)) + 1.0) * 0.5;
                const fc = @min(
                    sweep_lo_hz * std.math.pow(f32, 2.0, lfo * self.depth * sweep_octaves),
                    self.sample_rate * 0.45,
                );
                const t = std.math.tan(std.math.pi * fc / self.sample_rate);
                const a = (t - 1.0) / (t + 1.0);

                const dry = buf[i * 2 + ch];
                var s = dry + self.fb[ch] * self.feedback;
                inline for (0..num_stages) |st| {
                    const y = a * s + self.x1[ch][st] - a * self.y1[ch][st];
                    self.x1[ch][st] = s;
                    self.y1[ch][st] = y;
                    s = y;
                }
                self.fb[ch] = s;
                buf[i * 2 + ch] = dry * (1.0 - self.mix) + s * self.mix;
            }
            self.phase += phase_inc;
            if (self.phase >= 2.0 * std.math.pi) self.phase -= 2.0 * std.math.pi;
        }
    }

    /// Clears the allpass/feedback history and phase, leaving sample_rate
    /// and the user-facing params (rate/depth/feedback/mix) untouched.
    pub fn reset(self: *Phaser) void {
        self.x1 = .{ .{ 0.0, 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0, 0.0 } };
        self.y1 = .{ .{ 0.0, 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0, 0.0 } };
        self.fb = .{ 0.0, 0.0 };
        self.phase = 0.0;
    }
};

// ---------------------------------------------------------------------------
// Tests

test "mix 0 passes the input untouched" {
    var phaser = Phaser.init(48_000);
    phaser.mix = 0.0;
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    const expected = buf;
    phaser.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "output stays bounded under sustained input with feedback" {
    var phaser = Phaser.init(48_000);
    phaser.feedback = 0.9;
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var buf: [512]Sample = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        for (&buf) |*s| s.* = rand.float(f32) * 2.0 - 1.0;
        phaser.processBlock(&buf);
        for (buf) |s| try std.testing.expect(@abs(s) < 10.0);
    }
}

test "silence in, silence out" {
    var phaser = Phaser.init(48_000);
    var buf = [_]Sample{0.0} ** 256;
    phaser.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
}

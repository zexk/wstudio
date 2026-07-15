//! Stereo flanger: a short modulated delay line with feedback, swept by a
//! sine LFO (the right channel a quarter cycle behind, same stereo-widening
//! trick as `Phaser`). Same algorithm as the synth-internal fixed-ring
//! flanger in `dsp/synth.zig` (PolySynth can't own a heap buffer), ported to
//! a standalone track/master-chain FX unit with its own params on `self`
//! instead of taking them per block.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Flanger = struct {
    /// Only meaningful for a bare `.{}`; every real caller sets the actual
    /// rate via `init` (same convention as `Phaser.sample_rate`).
    sample_rate: f32 = 48_000.0,
    rate_hz: f32 = 0.3,
    /// 0 = parked at minimum delay, 1 = full sweep to `max_delay`.
    depth: f32 = 0.7,
    feedback: f32 = 0.5,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 0.5,
    phase: f32 = 0.0,
    ring: [2][len]f32 = [_][len]f32{[_]f32{0.0} ** len} ** 2,
    pos: usize = 0,

    /// 1024 samples caps the sweep at ~21ms at 48kHz (flanger through
    /// light-chorus territory) - matches the synth-internal ring's sizing.
    pub const len: usize = 1024;

    pub fn init(sample_rate: u32) Flanger {
        return .{ .sample_rate = @floatFromInt(sample_rate) };
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *Flanger, buf: []Sample) void {
        const len_f: f32 = @floatFromInt(len);
        const max_delay: f32 = len_f - 4.0;
        const inc = self.rate_hz / self.sample_rate;
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            inline for (0..2) |ch| {
                const ph = self.phase + @as(f32, if (ch == 1) 0.25 else 0.0);
                const lfo = 0.5 + 0.5 * @sin(ph * 2.0 * std.math.pi);
                // >= 1 sample of delay so the fractional read below never
                // touches the frame being written this iteration.
                const delay = 1.0 + lfo * self.depth * (max_delay - 1.0);
                var rp = @as(f32, @floatFromInt(self.pos)) - delay;
                if (rp < 0.0) rp += len_f;
                const tap_i: usize = @intFromFloat(rp);
                const frac = rp - @floor(rp);
                const tap = self.ring[ch][tap_i % len] * (1.0 - frac) +
                    self.ring[ch][(tap_i + 1) % len] * frac;
                const dry = buf[i + ch];
                self.ring[ch][self.pos] = dry + tap * self.feedback;
                buf[i + ch] = dry * (1.0 - self.mix) + tap * self.mix;
            }
            self.pos = (self.pos + 1) % len;
            self.phase += inc;
            self.phase -= @floor(self.phase);
        }
    }

    /// Clears the delay ring and phase, leaving sample_rate and the
    /// user-facing params (rate/depth/feedback/mix) untouched.
    pub fn reset(self: *Flanger) void {
        self.ring = [_][len]f32{[_]f32{0.0} ** len} ** 2;
        self.pos = 0;
        self.phase = 0.0;
    }
};

// ---------------------------------------------------------------------------
// Tests

test "mix 0 passes the input untouched" {
    var flanger = Flanger.init(48_000);
    flanger.mix = 0.0;
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    const expected = buf;
    flanger.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "output stays bounded under sustained input with feedback" {
    var flanger = Flanger.init(48_000);
    flanger.feedback = 0.9;
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var buf: [512]Sample = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        for (&buf) |*s| s.* = rand.float(f32) * 2.0 - 1.0;
        flanger.processBlock(&buf);
        for (buf) |s| try std.testing.expect(@abs(s) < 10.0);
    }
}

test "silence in, silence out" {
    var flanger = Flanger.init(48_000);
    var buf = [_]Sample{0.0} ** 256;
    flanger.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
}

//! Tape wow + flutter: a dual-LFO modulated delay line that wobbles pitch
//! instead of comb-filtering it. Wow (slow, ~0.05-3Hz) is the deep pitch
//! drift of a warped reel; flutter (fast, ~3-15Hz) is the fine jitter of an
//! uneven capstan. Unlike `Chorus`/`Flanger`, the LFOs are bipolar around a
//! fixed center delay (symmetric speed-up/slow-down) rather than swept
//! one-directionally from a minimum, and there's no feedback path - tape
//! wobble doesn't resonate, it just drifts.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Tape = struct {
    sample_rate: f32 = 48_000.0,
    wow_rate_hz: f32 = 0.6,
    wow_depth: f32 = 0.4,
    flutter_rate_hz: f32 = 8.0,
    flutter_depth: f32 = 0.25,
    /// 0 = dry only, 1 = wet only. Defaults full-wet: this colors the whole
    /// signal (like tape hiss) rather than blending a doubled copy.
    mix: f32 = 1.0,
    phase_wow: f32 = 0.0,
    phase_flutter: f32 = 0.0,
    ring: [2][len]f32 = [_][len]f32{[_]f32{0.0} ** len} ** 2,
    pos: usize = 0,

    /// Center delay sits at half the ring so the bipolar wow+flutter swing
    /// (up to `max_wow_ms + max_flutter_ms` either direction) never reads
    /// past either end. 1024 samples matches Flanger/Chorus's ring sizing.
    pub const len: usize = 1024;
    const max_wow_ms: f32 = 8.0;
    const max_flutter_ms: f32 = 1.5;

    pub fn init(sample_rate: u32) Tape {
        return .{ .sample_rate = @floatFromInt(sample_rate) };
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *Tape, buf: []Sample) void {
        const len_f: f32 = @floatFromInt(len);
        const center = len_f / 2.0;
        const max_wow_samples = max_wow_ms * 0.001 * self.sample_rate;
        const max_flutter_samples = max_flutter_ms * 0.001 * self.sample_rate;
        const wow_inc = self.wow_rate_hz / self.sample_rate;
        const flutter_inc = self.flutter_rate_hz / self.sample_rate;
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const wow = @sin(self.phase_wow * 2.0 * std.math.pi);
            const flutter = @sin(self.phase_flutter * 2.0 * std.math.pi);
            const delay = center +
                wow * self.wow_depth * max_wow_samples +
                flutter * self.flutter_depth * max_flutter_samples;
            inline for (0..2) |ch| {
                var rp = @as(f32, @floatFromInt(self.pos)) - delay;
                if (rp < 0.0) rp += len_f;
                const tap_i: usize = @intFromFloat(rp);
                const frac = rp - @floor(rp);
                const tap = self.ring[ch][tap_i % len] * (1.0 - frac) +
                    self.ring[ch][(tap_i + 1) % len] * frac;
                const dry = buf[i + ch];
                self.ring[ch][self.pos] = dry;
                buf[i + ch] = dry * (1.0 - self.mix) + tap * self.mix;
            }
            self.pos = (self.pos + 1) % len;
            self.phase_wow += wow_inc;
            self.phase_wow -= @floor(self.phase_wow);
            self.phase_flutter += flutter_inc;
            self.phase_flutter -= @floor(self.phase_flutter);
        }
    }

    /// Clears the delay ring and phases, leaving sample_rate and the
    /// user-facing params untouched.
    pub fn reset(self: *Tape) void {
        self.ring = [_][len]f32{[_]f32{0.0} ** len} ** 2;
        self.pos = 0;
        self.phase_wow = 0.0;
        self.phase_flutter = 0.0;
    }
};

// ---------------------------------------------------------------------------
// Tests

test "mix 0 passes the input untouched" {
    var tape = Tape.init(48_000);
    tape.mix = 0.0;
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    const expected = buf;
    tape.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "output stays bounded under sustained input" {
    var tape = Tape.init(48_000);
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var buf: [512]Sample = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        for (&buf) |*s| s.* = rand.float(f32) * 2.0 - 1.0;
        tape.processBlock(&buf);
        for (buf) |s| try std.testing.expect(@abs(s) < 2.0);
    }
}

test "silence in, silence out" {
    var tape = Tape.init(48_000);
    var buf = [_]Sample{0.0} ** 256;
    tape.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
}

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
const Lfo = @import("lfo.zig").Lfo;
const delay_line = @import("delay_line.zig");

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
    lfo_wow: Lfo = .{},
    lfo_flutter: Lfo = .{},
    ring: [2][len]f32 = [_][len]f32{[_]f32{0.0} ** len} ** 2,
    pos: usize = 0,

    /// Center delay sits at half the ring so the bipolar wow+flutter swing
    /// (up to `max_wow_ms + max_flutter_ms` either direction) never reads
    /// past either end. 1024 samples matches Flanger/Chorus's ring sizing.
    pub const len: usize = 1024;
    const max_wow_ms: f32 = 8.0;
    const max_flutter_ms: f32 = 1.5;

    pub fn init(sample_rate: u32) Tape {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *Tape, buf: []Sample) void {
        const len_f: f32 = @floatFromInt(len);
        const center = len_f / 2.0;
        const max_wow_samples = max_wow_ms * 0.001 * self.sample_rate;
        const max_flutter_samples = max_flutter_ms * 0.001 * self.sample_rate;
        const wow_rate = dsp.sanitizeParam(self.wow_rate_hz, 0.05, 3.0, 0.6);
        const wow_depth = dsp.sanitizeParam(self.wow_depth, 0.0, 1.0, 0.4);
        const flutter_rate = dsp.sanitizeParam(self.flutter_rate_hz, 3.0, 15.0, 8.0);
        const flutter_depth = dsp.sanitizeParam(self.flutter_depth, 0.0, 1.0, 0.25);
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 1.0);
        self.lfo_wow.sanitize();
        self.lfo_flutter.sanitize();
        const wow_inc = wow_rate / self.sample_rate;
        const flutter_inc = flutter_rate / self.sample_rate;
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const wow = self.lfo_wow.sine(0.0);
            const flutter = self.lfo_flutter.sine(0.0);
            const delay = center +
                wow * wow_depth * max_wow_samples +
                flutter * flutter_depth * max_flutter_samples;
            inline for (0..2) |ch| {
                const tap = delay_line.readInterp(&self.ring[ch], self.pos, delay);
                const dry = buf[i + ch];
                self.ring[ch][self.pos] = dry;
                buf[i + ch] = dry * (1.0 - mix) + tap * mix;
            }
            self.pos = (self.pos + 1) % len;
            self.lfo_wow.tick(wow_inc);
            self.lfo_flutter.tick(flutter_inc);
        }
    }

    /// Clears the delay ring and phases, leaving sample_rate and the
    /// user-facing params untouched.
    pub fn reset(self: *Tape) void {
        self.ring = [_][len]f32{[_]f32{0.0} ** len} ** 2;
        self.pos = 0;
        self.lfo_wow.reset();
        self.lfo_flutter.reset();
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

test "high sample rates wrap taps that span more than one ring" {
    var tape = Tape.init(384_000);
    tape.lfo_wow.phase = 0.25;
    tape.lfo_flutter.phase = 0.25;
    tape.wow_depth = 1.0;
    tape.flutter_depth = 1.0;
    var buf = [_]Sample{ 0.25, -0.25 };
    tape.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "invalid parameters cannot trap or poison output" {
    var tape = Tape.init(48_000);
    tape.wow_rate_hz = std.math.nan(f32);
    tape.wow_depth = -std.math.inf(f32);
    tape.flutter_rate_hz = std.math.inf(f32);
    tape.flutter_depth = std.math.nan(f32);
    tape.mix = std.math.inf(f32);
    tape.lfo_wow.phase = std.math.nan(f32);
    tape.lfo_flutter.phase = std.math.inf(f32);
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    tape.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

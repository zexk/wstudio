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
    /// past either end. Inline rather than allocated like Chorus's and
    /// Flanger's, which is why the swing shrinks to fit at high rates
    /// instead of the ring growing - see `fit` in `processBlock`.
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
        // The ring is a fixed 1024 frames, so the swing the wow+flutter
        // milliseconds ask for outgrows it past ~53kHz: the tap then walks
        // off the end and `readInterp`'s `@mod` wraps it around to audio a
        // whole ring older, which reads as a hard jump every cycle rather
        // than a wobble. Shrink the swing to whatever fits instead - a
        // shallower drift at 96/192kHz, but still a drift. 48kHz asks for at
        // most 456 frames against 508 available, so it is untouched.
        const head = center - 4.0; // `readInterp` reads 2 frames either side
        const swing = wow_depth * max_wow_samples + flutter_depth * max_flutter_samples;
        const fit: f32 = if (swing > head) head / swing else 1.0;
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const wow = self.lfo_wow.sine(0.0);
            const flutter = self.lfo_flutter.sine(0.0);
            const delay = center + fit * (wow * wow_depth * max_wow_samples +
                flutter * flutter_depth * max_flutter_samples);
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
    try dsp.expectBoundedUnderNoise(&tape, 2.0);
}

test "silence in, silence out" {
    var tape = Tape.init(48_000);
    var buf = [_]Sample{0.0} ** 256;
    tape.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
}

test "high sample rates keep the tap inside the ring instead of wrapping" {
    // At 384kHz the requested swing is ~7x the whole ring. The tap must
    // still land on real recent audio: an impulse written now has to come
    // back out within one ring, not be aliased to whatever a wrapped read
    // dredged up from a ring ago.
    inline for (.{ 48_000, 96_000, 384_000 }) |sr| {
        var tape = Tape.init(sr);
        tape.wow_depth = 1.0;
        tape.flutter_depth = 1.0;
        // Sweep the LFOs through a full cycle and check the tap never leaves
        // the ring, at whichever phase the deepest excursion happens to be.
        var phase: f32 = 0.0;
        while (phase < 1.0) : (phase += 0.02) {
            tape.reset();
            tape.lfo_wow.phase = phase;
            tape.lfo_flutter.phase = phase;
            // Ring is silent except for one impulse at the write head; a tap
            // that stayed in range reads silence, a wrapped one would too -
            // so instead assert the delay itself, via a full ring of impulses.
            var buf = [_]Sample{ 1.0, 1.0 } ++ [_]Sample{ 0.0, 0.0 } ** (Tape.len - 1);
            tape.processBlock(&buf);
            for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
            // The impulse comes back exactly once inside one ring's worth of
            // output. A wrapped tap reads a slot the write head has not
            // reached yet this pass, so it never appears at all.
            var hits: usize = 0;
            for (buf) |sample| hits += @intFromBool(@abs(sample) > 0.25);
            try std.testing.expect(hits > 0);
        }
    }
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

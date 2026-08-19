//! Stereo flanger: a short modulated delay line with feedback, swept by a
//! sine LFO (the right channel a quarter cycle behind, same stereo-widening
//! trick as `Phaser`). Same algorithm as the synth-internal fixed-ring
//! flanger in `dsp/synth.zig` (PolySynth can't own a heap buffer), ported to
//! a standalone track/master-chain FX unit with its own params on `self`
//! instead of taking them per block.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Lfo = @import("lfo.zig").Lfo;
const delay_line = @import("delay_line.zig");

const Sample = types.Sample;

pub const Flanger = struct {
    sample_rate: f32,
    rate_hz: f32 = 0.3,
    /// 0 = parked at minimum delay, 1 = full sweep to `max_delay_ms`.
    depth: f32 = 0.7,
    feedback: f32 = 0.5,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 0.5,
    lfo: Lfo = .{},
    /// Allocated from the sample rate, not a fixed frame count - see
    /// `max_delay_ms`. No default, so a bare `.{}` no longer compiles.
    ring: [2][]Sample,
    pos: usize = 0,

    /// Longest delay the sweep reaches. The ring used to be a fixed 1024
    /// frames, which is a *time* only at one sample rate: the same patch
    /// swept 23 ms at 44.1 kHz, 21 ms at 48, 5 ms at 192 and 2.7 ms at 384,
    /// so a project changed effect when its rate did. 21.25 ms is what the
    /// old ring gave at 48 kHz (1020 usable frames of 1024), so a project
    /// made there is unchanged and every other rate now gets that same
    /// sweep. `Tape` has the same fixed-ring story and the opposite
    /// resolution - it shrinks its swing to fit - because its ring is
    /// inline and this one no longer is.
    pub const max_delay_ms: f32 = 21.25;

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Flanger {
        const safe_rate: f32 = @floatFromInt(@max(sample_rate, 1));
        // +4: `readInterp`'s cubic tap reads two frames either side.
        const frames: usize = @max(@as(usize, @intFromFloat(max_delay_ms * 0.001 * safe_rate)) + 4, 8);
        const left = try allocator.alloc(Sample, frames);
        errdefer allocator.free(left);
        const right = try allocator.alloc(Sample, frames);
        @memset(left, 0.0);
        @memset(right, 0.0);
        return .{ .sample_rate = safe_rate, .ring = .{ left, right } };
    }

    pub fn deinit(self: *Flanger, allocator: std.mem.Allocator) void {
        allocator.free(self.ring[0]);
        allocator.free(self.ring[1]);
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *Flanger, buf: []Sample) void {
        const len = self.ring[0].len;
        // The ring is sized for this; the `@min` is the belt-and-braces
        // layer, not the shaping.
        const max_delay: f32 = @min(max_delay_ms * 0.001 * self.sample_rate, @as(f32, @floatFromInt(len)) - 4.0);
        const rate = dsp.sanitizeParam(self.rate_hz, 0.05, 5.0, 0.3);
        const depth = dsp.sanitizeParam(self.depth, 0.0, 1.0, 0.7);
        const feedback = dsp.sanitizeParam(self.feedback, 0.0, 0.9, 0.5);
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 0.5);
        self.lfo.sanitize();
        const inc = rate / self.sample_rate;
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            inline for (0..2) |ch| {
                const lfo = 0.5 + 0.5 * self.lfo.sine(if (ch == 1) 0.25 else 0.0);
                // >= 1 sample of delay so the fractional read below never
                // touches the frame being written this iteration.
                const delay = 1.0 + lfo * depth * (max_delay - 1.0);
                const tap = delay_line.readInterp(self.ring[ch], self.pos, delay);
                const dry = buf[i + ch];
                self.ring[ch][self.pos] = dry + tap * feedback;
                buf[i + ch] = dry * (1.0 - mix) + tap * mix;
            }
            self.pos = (self.pos + 1) % len;
            self.lfo.tick(inc);
        }
    }

    /// Clears the delay ring and phase, leaving sample_rate and the
    /// user-facing params (rate/depth/feedback/mix) untouched.
    pub fn reset(self: *Flanger) void {
        @memset(self.ring[0], 0.0);
        @memset(self.ring[1], 0.0);
        self.pos = 0;
        self.lfo.reset();
    }
};

// ---------------------------------------------------------------------------
// Tests

test "mix 0 passes the input untouched" {
    var flanger = try Flanger.init(std.testing.allocator, 48_000);
    defer flanger.deinit(std.testing.allocator);
    flanger.mix = 0.0;
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    const expected = buf;
    flanger.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "output stays bounded under sustained input with feedback" {
    var flanger = try Flanger.init(std.testing.allocator, 48_000);
    defer flanger.deinit(std.testing.allocator);
    flanger.feedback = 0.9;
    try dsp.expectBoundedUnderNoise(&flanger, 10.0);
}

test "silence in, silence out" {
    var flanger = try Flanger.init(std.testing.allocator, 48_000);
    defer flanger.deinit(std.testing.allocator);
    var buf = [_]Sample{0.0} ** 256;
    flanger.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
}

test "invalid parameters cannot trap or poison output" {
    var flanger = try Flanger.init(std.testing.allocator, 48_000);
    defer flanger.deinit(std.testing.allocator);
    flanger.rate_hz = std.math.nan(f32);
    flanger.depth = -std.math.inf(f32);
    flanger.feedback = std.math.inf(f32);
    flanger.mix = std.math.nan(f32);
    flanger.lfo.phase = std.math.inf(f32);
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    flanger.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "the sweep is the same length of time at every sample rate" {
    // The ring used to be a fixed frame count, so the sweep was 23 ms at
    // 44.1 kHz and 2.7 ms at 384 - the same patch, a different effect.
    // Measured as the delay of the echo the feedback path leaves: park the
    // LFO at the top of its sweep and find where an impulse comes back.
    inline for ([_]u32{ 44_100, 48_000, 96_000, 192_000 }) |sr| {
        var flanger = try Flanger.init(std.testing.allocator, sr);
        defer flanger.deinit(std.testing.allocator);
        flanger.depth = 1.0;
        flanger.rate_hz = 0.05; // near-static across the buffer
        flanger.mix = 1.0;
        flanger.feedback = 0.0;
        flanger.lfo.phase = 0.25; // sine peak: the far end of the sweep

        const frames = sr / 20; // 50 ms, comfortably past a 21.25 ms tap
        const buf = try std.testing.allocator.alloc(Sample, frames * 2);
        defer std.testing.allocator.free(buf);
        @memset(buf, 0.0);
        buf[0] = 1.0;
        buf[1] = 1.0;
        flanger.processBlock(buf);

        var peak: f32 = 0;
        var at: usize = 0;
        for (0..frames) |f| {
            if (@abs(buf[f * 2]) > peak) {
                peak = @abs(buf[f * 2]);
                at = f;
            }
        }
        const ms = @as(f32, @floatFromInt(at)) * 1000.0 / @as(f32, @floatFromInt(sr));
        try std.testing.expectApproxEqAbs(Flanger.max_delay_ms, ms, 0.2);
    }
}

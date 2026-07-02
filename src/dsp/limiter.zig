//! Master-bus brick-wall limiter: instant attack, smoothed release.
//!
//! Sits after the master gain in Engine.process, so nothing upstream of the
//! WAV writer's ±1 clamp (or the DAC) ever exceeds the ceiling — hot mixes
//! get momentary gain reduction instead of hard-clip distortion. Stereo-
//! linked and allocation-free; transparent (gain = 1) while the programme
//! stays under the ceiling.

const std = @import("std");
const types = @import("../core/types.zig");

const Sample = types.Sample;

pub const Limiter = struct {
    sample_rate: f32,
    /// Output ceiling, linear (≈ -0.4 dBFS): headroom for the 16-bit round.
    ceiling: f32 = 0.955,
    /// Gain-recovery time constant after a reduction.
    release_ms: f32 = 80.0,
    /// Current gain (≤ 1). Drops instantly on overshoot, recovers toward 1.
    gain: f32 = 1.0,

    pub fn init(sample_rate: u32) Limiter {
        return .{ .sample_rate = @floatFromInt(sample_rate) };
    }

    pub fn reset(self: *Limiter) void {
        self.gain = 1.0;
    }

    /// Limit an interleaved stereo buffer in place.
    pub fn processBlock(self: *Limiter, buf: []Sample) void {
        const release = @exp(-1.0 / (self.release_ms * 0.001 * self.sample_rate));
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            // Recover toward unity, then drop the gain so this frame's
            // stereo peak cannot pass the ceiling (instant attack).
            self.gain = 1.0 - release * (1.0 - self.gain);
            const level = @max(@abs(buf[i]), @abs(buf[i + 1])) * self.gain;
            if (level > self.ceiling) self.gain *= self.ceiling / level;
            buf[i]     *= self.gain;
            buf[i + 1] *= self.gain;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

test "loud input never exceeds the ceiling" {
    var lim = Limiter.init(48_000);
    var buf: [512]Sample = undefined;
    // A +12 dB square-ish signal: alternating ±4.0.
    for (&buf, 0..) |*s, i| s.* = if (i % 4 < 2) 4.0 else -4.0;
    lim.processBlock(&buf);
    for (buf) |s| try std.testing.expect(@abs(s) <= lim.ceiling + 1e-5);
}

test "quiet input passes through untouched" {
    var lim = Limiter.init(48_000);
    var buf: [512]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    var expected: [512]Sample = undefined;
    @memcpy(&expected, &buf);
    lim.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lim.gain, 1e-6);
}

test "gain recovers toward unity after a transient" {
    var lim = Limiter.init(48_000);
    var buf: [512]Sample = undefined;
    @memset(&buf, 2.0); // sustained overshoot pulls the gain down
    lim.processBlock(&buf);
    const reduced = lim.gain;
    try std.testing.expect(reduced < 0.6);

    // Silence: the gain climbs back toward 1 at the release rate.
    // 120 blocks × 256 frames ≈ 8 release time constants at 80 ms.
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        @memset(&buf, 0.0);
        lim.processBlock(&buf);
    }
    try std.testing.expect(lim.gain > 0.99);
    try std.testing.expect(lim.gain > reduced);
}

//! Noise gate: mutes the signal while it stays under the threshold.
//! Stereo-linked peak detector with a short fixed decay drives a smoothed
//! open/close gain; attack sets how fast the gate opens on a transient,
//! release how fast it falls shut after the input drops away.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Gate = struct {
    sample_rate: f32 = 48_000.0,
    threshold_db: f32 = -50.0,
    attack_ms: f32 = 1.0,
    release_ms: f32 = 100.0,
    /// Detector state: stereo peak with a fixed ~50ms decay.
    env: f32 = 0.0,
    /// Current gain: 0 shut ... 1 open. Starts shut so a track that begins
    /// under the threshold doesn't leak its first buffer.
    gain: f32 = 0.0,

    pub fn init(sample_rate: u32) Gate {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
    }

    pub const device = dsp.deviceOf(@This());

    /// Gate an interleaved stereo buffer in place.
    pub fn processBlock(self: *Gate, buf: []Sample) void {
        // A negative/zero attack_ms or release_ms flips the exponent
        // positive, giving a decay coefficient >= 1 - the envelope/gain
        // recurrences below then diverge geometrically within one block.
        const threshold_db = dsp.sanitizeParam(self.threshold_db, -80.0, 0.0, -50.0);
        const attack_ms = dsp.sanitizeParam(self.attack_ms, 0.1, 50.0, 1.0);
        const release_ms = dsp.sanitizeParam(self.release_ms, 5.0, 1000.0, 100.0);
        // zig fmt: off
        const thresh    = std.math.pow(f32, 10.0, threshold_db / 20.0);
        const det_decay = @exp(-1.0 / (0.050 * self.sample_rate));
        const attack    = @exp(-1.0 / (attack_ms * 0.001 * self.sample_rate));
        const release   = @exp(-1.0 / (release_ms * 0.001 * self.sample_rate));
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const peak = @max(@abs(buf[i]), @abs(buf[i + 1]));
            self.env = @max(peak, self.env * det_decay);
            const target: f32 = if (self.env >= thresh) 1.0 else 0.0;
            const coef = if (target > self.gain) attack else release;
            self.gain = target + coef * (self.gain - target);
            buf[i]     *= self.gain;
            // zig fmt: on
            buf[i + 1] *= self.gain;
        }
    }

    /// Clears detector/gain state without touching `sample_rate` - callers
    /// embedding a `Gate` by value (e.g. PolySynth's internal FX section)
    /// must use this instead of `= .{}`, which would reset sample_rate to
    /// the struct default and desync it from the real session rate.
    pub fn reset(self: *Gate) void {
        self.env = 0.0;
        self.gain = 0.0;
    }
};

// ---------------------------------------------------------------------------
// Tests

test "loud input opens the gate to near unity" {
    var gate = Gate.init(48_000);
    var buf: [4096]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = if (i % 4 < 2) 0.5 else -0.5;
    gate.processBlock(&buf);
    try std.testing.expect(gate.gain > 0.99);
    // Past the 1ms attack the signal passes essentially untouched.
    try std.testing.expectApproxEqAbs(@as(Sample, 0.5), @abs(buf[4000]), 1e-2);
}

test "sub-threshold input stays shut" {
    var gate = Gate.init(48_000);
    gate.threshold_db = -20.0;
    var buf: [4096]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = 0.01 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    gate.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
}

test "invalid parameters cannot trap or poison output" {
    var gate = Gate.init(48_000);
    gate.threshold_db = std.math.nan(f32);
    gate.attack_ms = -1.0;
    gate.release_ms = std.math.inf(f32);
    var buf: [256]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = if (i % 4 < 2) 0.5 else -0.5;
    gate.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "gate falls shut after the input drops away" {
    var gate = Gate.init(48_000);
    gate.release_ms = 20.0;
    var buf: [4096]Sample = undefined;
    @memset(&buf, 0.5);
    gate.processBlock(&buf);
    try std.testing.expect(gate.gain > 0.99);

    // ~0.5s of silence: detector and gain both decay to nothing.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        @memset(&buf, 0.0);
        gate.processBlock(&buf);
    }
    try std.testing.expect(gate.gain < 1e-3);
}

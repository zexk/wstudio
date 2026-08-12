//! Downward expander: the compressor's gain computer pointed the other way.
//!
//! A compressor makes what is over the threshold quieter. An expander makes
//! what is *under* it quieter, by `ratio` dB for every dB it falls short. A
//! gate is the same idea taken to its limit - one threshold, and everything
//! under it drops to a fixed floor - which is why a gate chatters on
//! material that hovers and an expander does not: there is no state to flip,
//! only a curve to follow.
//!
//! That makes this the quadrant the rack was missing. Reach for it to thin
//! room tone under a close mic, to widen the dynamic range a recording lost
//! to over-compression, or anywhere a gate is too abrupt.
//!
//! The detector, envelope and knee are the compressor's - see
//! `dsp/detector.zig` and `Compressor.envelopeOverDb`.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const detector = @import("detector.zig");
const Compressor = @import("compressor.zig").Compressor;

const Sample = types.Sample;

/// Floor on the attenuation, matching the gate's full-mute range. Without a
/// bound the ratio asks for whatever the distance to `gainToDb`'s -120 dB
/// floor happens to be, so a silent passage would be attenuated by an
/// arbitrary amount and come back as a click when signal returns.
pub const max_reduction_db: f32 = -80.0;

pub const Expander = struct {
    sample_rate: f32 = 48_000.0,
    /// Level under which expansion starts.
    threshold_db: f32 = -40.0,
    /// dB of attenuation per dB under the threshold. 1 = no expansion.
    ratio: f32 = 2.0,
    attack_ms: f32 = 5.0,
    release_ms: f32 = 150.0,
    /// Width of the soft-knee transition around the threshold, dB. 0 = the
    /// curve bends the instant the level crosses.
    knee_db: f32 = 6.0,
    /// How far the expander may attenuate, dB. Bounds the curve the way the
    /// gate's `range_db` bounds a shut gate.
    range_db: f32 = -40.0,
    /// Detector shaping - the compressor's three controls, same meanings.
    sc_mode: f32 = 0.0,
    sc_hpf_hz: f32 = 0.0,
    sc_lpf_hz: f32 = 0.0,
    /// Envelope follower state (linear).
    env: f32 = 0.0,
    det_state: detector.Detector = .{},
    /// Most recent gain change, for UI metering. Negative, like the
    /// compressor's.
    gain_reduction_db: f32 = 0.0,

    pub fn init(sample_rate: u32) Expander {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
    }

    pub const device = dsp.deviceOf(@This());

    /// Attenuation in dB for a level `under_db` below the threshold (0 at or
    /// over it). The mirror of `Compressor.downwardReductionDb`: same slope,
    /// same quadratic knee, measured downward instead of upward.
    pub fn expansionDb(under_db: f32, ratio: f32, knee_db: f32, range_db: f32) f32 {
        const slope = ratio - 1.0;
        const raw = if (knee_db <= 0.0)
            (if (under_db > 0.0) -under_db * slope else 0.0)
        else blk: {
            const half = knee_db * 0.5;
            if (under_db <= -half) break :blk 0.0;
            if (under_db >= half) break :blk -under_db * slope;
            const x = under_db + half;
            break :blk -slope * (x * x) / (2.0 * knee_db);
        };
        return @max(raw, range_db);
    }

    pub fn processBlock(self: *Expander, buf: []Sample) void {
        const frames = buf.len / 2;
        const threshold_db = dsp.sanitizeParam(self.threshold_db, -80.0, 0.0, -40.0);
        const ratio = dsp.sanitizeParam(self.ratio, 1.0, 20.0, 2.0);
        const attack_ms = dsp.sanitizeParam(self.attack_ms, 0.1, 500.0, 5.0);
        const release_ms = dsp.sanitizeParam(self.release_ms, 1.0, 2000.0, 150.0);
        const knee_db = dsp.sanitizeParam(self.knee_db, 0.0, 24.0, 6.0);
        const range_db = dsp.sanitizeParam(self.range_db, max_reduction_db, 0.0, -40.0);
        const attack = dsp.smoothingCoefMs(attack_ms, self.sample_rate);
        const release = dsp.smoothingCoefMs(release_ms, self.sample_rate);

        const shaping = detector.shapingFor(
            dsp.sanitizeParam(self.sc_hpf_hz, 0.0, 2000.0, 0.0),
            dsp.sanitizeParam(self.sc_lpf_hz, 0.0, 20_000.0, 0.0),
            dsp.sanitizeParam(self.sc_mode, 0.0, 1.0, 0.0) >= 0.5,
            self.sample_rate,
        );
        if (!shaping.active()) self.det_state.reset();

        for (0..frames) |i| {
            const level = self.det_state.level(shaping, buf[i * 2], buf[i * 2 + 1]);
            // The envelope tracks the signal; "under" is what the gain
            // computer wants, so the compressor's over-threshold value is
            // negated rather than recomputed.
            const under_db = -Compressor.envelopeOverDb(&self.env, level, attack, release, threshold_db);
            const reduction_db = expansionDb(under_db, ratio, knee_db, range_db);
            self.gain_reduction_db = reduction_db;
            const gain = types.dbToGain(reduction_db);
            buf[i * 2] *= gain;
            buf[i * 2 + 1] *= gain;
        }
    }

    /// Clears envelope/detector state without touching `sample_rate`.
    pub fn reset(self: *Expander) void {
        self.env = 0.0;
        self.det_state.reset();
        self.gain_reduction_db = 0.0;
    }
};

// ---------------------------------------------------------------------------
// Tests

test "signal over the threshold passes, signal under it is pushed down" {
    var exp = Expander.init(48_000);
    exp.threshold_db = -20.0;
    exp.ratio = 2.0;
    exp.knee_db = 0.0;
    exp.attack_ms = 0.5;
    exp.release_ms = 5.0;
    exp.range_db = -60.0; // wide enough that the curve, not the bound, decides

    var buf: [4096]Sample = undefined;

    // -6 dB, well over threshold: untouched once the envelope settles.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        @memset(&buf, types.dbToGain(-6.0));
        exp.processBlock(&buf);
    }
    try std.testing.expectApproxEqAbs(types.dbToGain(-6.0), buf[4000], 1e-3);

    // -40 dB, 20 dB under threshold. The slope is `ratio - 1`, so ratio 2
    // asks for 20 dB of extra attenuation and the level lands 60 dB down.
    i = 0;
    while (i < 40) : (i += 1) {
        @memset(&buf, types.dbToGain(-40.0));
        exp.processBlock(&buf);
    }
    try std.testing.expectApproxEqAbs(@as(f32, -60.0), types.gainToDb(@abs(buf[4000])), 1.0);
}

test "range bounds how far the expander can attenuate" {
    var exp = Expander.init(48_000);
    exp.threshold_db = -20.0;
    exp.ratio = 8.0;
    exp.knee_db = 0.0;
    exp.range_db = -12.0;
    exp.release_ms = 5.0;

    var buf: [4096]Sample = undefined;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        @memset(&buf, types.dbToGain(-60.0)); // far under: asks for -320 dB
        exp.processBlock(&buf);
    }
    try std.testing.expectApproxEqAbs(@as(f32, -12.0), exp.gain_reduction_db, 0.5);
}

test "ratio 1 is a passthrough at every level" {
    var exp = Expander.init(48_000);
    exp.ratio = 1.0;
    var buf: [512]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = 0.001 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    var expected: [512]Sample = undefined;
    @memcpy(&expected, &buf);
    exp.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-9);
}

test "the knee bends the curve instead of cornering it" {
    // Right at the threshold a hard knee does nothing and a soft one has
    // already started, which is the whole point of the control.
    const hard = Expander.expansionDb(0.0, 4.0, 0.0, -80.0);
    const soft = Expander.expansionDb(0.0, 4.0, 12.0, -80.0);
    try std.testing.expectEqual(@as(f32, 0.0), hard);
    try std.testing.expect(soft < -0.5);
    // Well past the knee the two agree again.
    try std.testing.expectApproxEqAbs(
        Expander.expansionDb(24.0, 4.0, 0.0, -80.0),
        Expander.expansionDb(24.0, 4.0, 12.0, -80.0),
        1e-4,
    );
}

test "invalid parameters cannot trap or poison output" {
    var exp = Expander.init(48_000);
    exp.threshold_db = std.math.nan(f32);
    exp.ratio = -3.0;
    exp.attack_ms = 0.0;
    exp.release_ms = std.math.inf(f32);
    exp.knee_db = std.math.nan(f32);
    var buf: [256]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = if (i % 4 < 2) 0.5 else -0.5;
    exp.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

//! Loudness clipper: a hard ceiling with a knee, ahead of the limiter.
//!
//! A limiter turns a peak down; a clipper cuts its top off. On a modern
//! master the clipper does the work the limiter would otherwise have to do
//! with gain reduction, which is what keeps a loud mix from breathing: two
//! dB of clipped snare transient is inaudible, two dB of limiter pumping is
//! not. That is the workflow this unit exists for, and the reason it is a
//! separate insert from `dsp/saturator.zig`, whose curves are normalized to
//! preserve level rather than to enforce a ceiling.
//!
//! `odp` (overdrive protection, LSP's name for it) is a soft pre-stage: it
//! eases the level toward the ceiling ahead of the clip instead of letting
//! every peak arrive at full height, so the same loudness costs fewer hard
//! corners and less high-order distortion.
//!
//! Every curve here more than doubles the signal's bandwidth, so the whole
//! stage runs at twice the sample rate - the same treatment, and the same
//! reported latency, as the saturator's.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const oversample = @import("oversample.zig");

const Sample = types.Sample;

/// Highest `shape` index.
pub const max_shape: f32 = 2.0;

/// How wide a knee each shape puts under the ceiling, as a fraction of it.
/// The shapes are knees rather than different curve families: what separates
/// a clipper from a saturator is that everything under the knee has to come
/// through untouched, and once that is fixed the only choice left is how far
/// down the bend starts.
fn kneeFor(kind: u3) f32 {
    return switch (kind) {
        1 => 0.5, // soft: bends from half the ceiling up
        2 => 0.25, // medium
        else => 0.0, // hard: the plain clamp, loudest and most audible
    };
}

/// Normalized clipper: `|x| <= 1 - knee` passes untouched, and the rest
/// bends toward the ceiling.
///
/// The bend is `t + k·(1 - e^(-(|x|-t)/k))` with `t = 1 - knee` and
/// `k = knee`: it leaves the linear region with slope 1 (no corner), is
/// monotone, and approaches the ceiling without ever reaching it, so the
/// ceiling holds however hard the unit is driven.
///
/// A curve that both lands *on* the ceiling at `|x| = 1` and arrives flat is
/// not available: with slope 1 at the bottom, 0 at the top and an average of
/// 1 across the knee, it would have to exceed slope 1 somewhere, which means
/// amplifying part of the signal - the opposite of what a clipper is for.
fn clipVal(kind: u3, x: f32) f32 {
    const knee = kneeFor(kind);
    const mag = @abs(x);
    const linear = 1.0 - knee;
    if (mag <= linear) return x;
    if (knee <= 0.0) return std.math.copysign(@as(f32, 1.0), x);
    const bent = linear + knee * (1.0 - @exp(-(mag - linear) / knee));
    return std.math.copysign(bent, x);
}

pub const Clipper = struct {
    sample_rate: f32 = 48_000.0,
    /// Gain applied before the curve. Driving into a fixed ceiling is how a
    /// clipper is worked: more input, more of the signal against the top.
    drive_db: f32 = 0.0,
    /// Output ceiling, dB. The curve is normalized to unity, so this is
    /// simply what unity means.
    ceiling_db: f32 = -0.3,
    /// 0 = hard, 1 = soft, 2 = medium.
    shape: f32 = 0.0,
    /// Overdrive protection: 0 = off, 1 = on. A soft envelope-driven trim
    /// that eases loud passages toward the ceiling before the curve sees
    /// them, so the same loudness needs less hard clipping.
    odp: f32 = 0.0,
    /// How far below the ceiling overdrive protection starts working.
    odp_knee_db: f32 = 6.0,
    /// ODP envelope state (linear peak).
    odp_env: f32 = 0.0,
    /// Most recent ODP trim in dB, for UI metering. 0 when it is off or
    /// idle.
    odp_gain_db: f32 = 0.0,
    stage: oversample.Stage2x = .{},

    pub fn init(sample_rate: u32) Clipper {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
    }

    pub const device = dsp.deviceOf(@This());

    /// The oversampler's filters delay the signal; the engine compensates.
    pub fn latencyFrames(_: *const Clipper) u32 {
        return oversample.latency_frames;
    }

    pub fn reset(self: *Clipper) void {
        self.stage.reset();
        self.odp_env = 0.0;
        self.odp_gain_db = 0.0;
    }

    /// What the oversampler calls back into, per doubled-rate sample.
    const Curve = struct {
        kind: u3,
        ceiling: f32,

        fn apply(self: Curve, x: f32) f32 {
            return clipVal(self.kind, x / self.ceiling) * self.ceiling;
        }
    };

    /// The curve `processBlock` is about to run - shared with `transfer` so
    /// the drawn shape cannot drift from the audible one.
    fn curveFor(self: *const Clipper) Curve {
        const ceiling_db = dsp.sanitizeParam(self.ceiling_db, -24.0, 0.0, -0.3);
        const kind: u3 = @intFromFloat(std.math.clamp(@round(dsp.sanitizeParam(self.shape, 0.0, max_shape, 0.0)), 0, max_shape));
        return .{ .kind = kind, .ceiling = types.dbToGain(ceiling_db) };
    }

    /// The static transfer curve the GUI plots: -1..1 in, through DRIVE and
    /// the selected knee against the ceiling. ODP is deliberately left out -
    /// it is an envelope follower, so it has no fixed curve to draw.
    pub fn transfer(self: *const Clipper, x: f32) f32 {
        const drive = types.dbToGain(dsp.sanitizeParam(self.drive_db, 0.0, 24.0, 0.0));
        return self.curveFor().apply(x * drive);
    }

    pub fn processBlock(self: *Clipper, buf: []Sample) void {
        const frames = buf.len / 2;
        const drive_db = dsp.sanitizeParam(self.drive_db, 0.0, 24.0, 0.0);
        const odp_on = dsp.sanitizeParam(self.odp, 0.0, 1.0, 0.0) >= 0.5;
        const odp_knee_db = dsp.sanitizeParam(self.odp_knee_db, 0.0, 24.0, 6.0);
        if (!std.math.isFinite(self.odp_env) or self.odp_env < 0.0) self.odp_env = 0.0;

        const drive = types.dbToGain(drive_db);
        const curve = self.curveFor();
        const ceiling = curve.ceiling;
        // ODP is deliberately slow to let go and quick to grab: it is
        // conditioning, not an effect, and a fast recovery would put the
        // pumping back that clipping is being used to avoid.
        const odp_attack = dsp.smoothingCoefMs(5.0, self.sample_rate);
        const odp_release = dsp.smoothingCoefMs(250.0, self.sample_rate);
        const odp_threshold = ceiling * types.dbToGain(-odp_knee_db);

        for (0..frames) |i| {
            var l = buf[i * 2] * drive;
            var r = buf[i * 2 + 1] * drive;

            if (odp_on) {
                const level = @max(@abs(l), @abs(r));
                const coef = if (level > self.odp_env) odp_attack else odp_release;
                self.odp_env = coef * self.odp_env + (1.0 - coef) * level;
                // Halve the excess over the knee rather than remove it: the
                // curve is still meant to do the clipping, this only stops
                // it being asked for the whole overshoot at once.
                const trim: f32 = if (self.odp_env > odp_threshold)
                    (odp_threshold + (self.odp_env - odp_threshold) * 0.5) / self.odp_env
                else
                    1.0;
                self.odp_gain_db = types.gainToDb(trim);
                l *= trim;
                r *= trim;
            } else if (self.odp_gain_db != 0.0) {
                self.odp_env = 0.0;
                self.odp_gain_db = 0.0;
            }

            buf[i * 2] = self.stage.process(0, l, curve, Curve.apply);
            buf[i * 2 + 1] = self.stage.process(1, r, curve, Curve.apply);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

/// Runs `level` (and its negation on the right channel) long enough for the
/// oversampler's filters to settle, and returns the settled peak.
fn settledPeak(clip: *Clipper, level: f32) f32 {
    var buf: [1024]Sample = undefined;
    var peak: f32 = 0.0;
    for (0..8) |blk| {
        for (0..buf.len / 2) |f| {
            buf[f * 2] = level;
            buf[f * 2 + 1] = -level;
        }
        clip.processBlock(&buf);
        if (blk == 7) for (buf) |s| {
            peak = @max(peak, @abs(s));
        };
    }
    return peak;
}

test "every shape holds the ceiling however hard it is driven" {
    inline for ([_]f32{ 0.0, 1.0, 2.0 }) |shape| {
        var clip = Clipper.init(48_000);
        clip.shape = shape;
        clip.ceiling_db = -6.0;
        clip.drive_db = 24.0;
        // The oversampler's half-band filters overshoot slightly on a
        // square edge; the ceiling is on the shaped signal, not on the
        // reconstruction ripple.
        try std.testing.expect(settledPeak(&clip, 1.0) <= types.dbToGain(-6.0) + 0.02);
    }
}

test "a signal well under the ceiling comes through unclipped" {
    var clip = Clipper.init(48_000);
    clip.ceiling_db = 0.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), settledPeak(&clip, 0.2), 0.01);
}

test "the soft shape rounds where the hard one corners" {
    // Same input at the ceiling: hard clip passes it untouched, soft is
    // already bending.
    var hard = Clipper.init(48_000);
    hard.ceiling_db = 0.0;
    var soft = Clipper.init(48_000);
    soft.ceiling_db = 0.0;
    soft.shape = 1.0;
    try std.testing.expect(settledPeak(&soft, 0.8) < settledPeak(&hard, 0.8));
}

test "overdrive protection trims a loud passage before the curve sees it" {
    var clip = Clipper.init(48_000);
    clip.ceiling_db = 0.0;
    clip.odp = 1.0;
    clip.odp_knee_db = 6.0;
    _ = settledPeak(&clip, 1.0);
    // Well over the knee, so the trim is real, and it is a trim rather than
    // a limiter: a fraction of a dB to a few dB, never the whole overshoot.
    try std.testing.expect(clip.odp_gain_db < -0.5);
    try std.testing.expect(clip.odp_gain_db > -12.0);
}

test "invalid parameters cannot trap or poison output" {
    var clip = Clipper.init(48_000);
    clip.drive_db = std.math.nan(f32);
    clip.ceiling_db = std.math.inf(f32);
    clip.shape = -5.0;
    clip.odp = std.math.nan(f32);
    clip.odp_env = std.math.nan(f32);
    var buf: [256]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = if (i % 4 < 2) 0.9 else -0.9;
    clip.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "the plotted transfer curve is the curve the audio path runs" {
    // `transfer` only feeds the GUI, so nothing would fail if it drifted
    // from `processBlock`. ODP off, since that stage is an envelope
    // follower and deliberately outside the static curve.
    for ([_]f32{ 0.0, 1.0, 2.0 }) |shape| {
        for ([_]f32{ 0.0, 12.0 }) |drive| {
            var clip = Clipper.init(48_000);
            clip.shape = shape;
            clip.drive_db = drive;
            var buf: [256]Sample = undefined;
            for ([_]f32{ 0.1, 0.5, 0.9 }) |level| {
                clip.reset();
                var i: usize = 0;
                while (i < buf.len) : (i += 2) {
                    buf[i] = level;
                    buf[i + 1] = -level;
                }
                clip.processBlock(&buf);
                try std.testing.expectApproxEqAbs(clip.transfer(level), buf[buf.len - 2], 0.02);
                try std.testing.expectApproxEqAbs(clip.transfer(-level), buf[buf.len - 1], 0.02);
            }
        }
    }
}

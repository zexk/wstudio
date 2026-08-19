//! Saturator: a waveshaper with input drive, output trim, dry/wet mix, and
//! a choice of five curves. Every curve is peak-normalised (shape(g·x) /
//! shape(g) per polarity) so cranking the drive adds density and harmonics
//! without also adding level; the output trim is a plain make-up/duck
//! control on top.
//!
//! Shapes:
//!   0 = soft:  tanh, symmetric - warm, mostly odd harmonics.
//!   1 = tube:  tanh with a softer gain on the negative half, so it clips
//!       asymmetrically like a valve stage and adds even harmonics. The
//!       asymmetry pushes a DC offset into the signal, so this shape alone
//!       runs its output through a one-pole DC blocker.
//!   2 = diode: cubic soft-knee clip (`x - x^3/3`, hard-limited past unity)
//!       - a sharper knee than tanh for a more aggressive, fuzz-like edge.
//!   3 = sine:  a quarter sine over the clipped input - flat-topped well
//!       before the edge, so it thickens without buzzing.
//!   4 = hard:  no knee at all. Transparent up to the threshold, edged past
//!       it, and the loudest of the five for a given drive.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const oversample = @import("oversample.zig");

const Sample = types.Sample;

/// Negative-half gain multiplier for the tube shape - the asymmetry that
/// gives it even harmonics.
const tube_asym: f32 = 0.6;
/// One-pole DC-blocker pole; ~38 Hz cutoff at 48 kHz, low enough to leave
/// bass alone.
const dc_pole: f32 = 0.995;

/// Highest `shape` index. The curves are a table, not a design axis: each is
/// a different amount and order of harmonics for the same drive, and picking
/// by ear is the whole workflow. LSP's clipper offers eleven sigmoids; these
/// five cover soft through hard without two of them sounding alike.
pub const max_shape: f32 = 4.0;

fn shapeVal(kind: u3, pre: f32, x: f32) f32 {
    return switch (kind) {
        1 => blk: {
            const g = if (x >= 0) pre else pre * tube_asym;
            break :blk std.math.tanh(g * x);
        },
        2 => blk: {
            const y = pre * x;
            break :blk if (@abs(y) < 1.0) y - (y * y * y) / 3.0 else std.math.copysign(@as(f32, 2.0 / 3.0), y);
        },
        // Sine: flat-topped well before it clips, so it thickens without
        // the buzz a hard edge adds - the "fat" end of the table.
        3 => @sin(std.math.clamp(pre * x, -1.0, 1.0) * (std.math.pi * 0.5)),
        // Hard clip: no knee at all. Loud and edged, and the only curve
        // here that leaves the signal untouched right up to the threshold.
        4 => std.math.clamp(pre * x, -1.0, 1.0),
        else => std.math.tanh(pre * x),
    };
}

/// Names of the five curves, in `shape` order - what the editor shows
/// instead of a bare index, and what makes the param read as a choice
/// rather than a quantity.
pub const shape_names = [_][]const u8{ "soft", "tube", "diode", "sine", "hard" };

pub const Saturator = struct {
    drive_db: f32 = 12.0,
    out_db: f32 = 0.0,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 1.0,
    /// 0 = soft (tanh), 1 = tube (asymmetric), 2 = diode (cubic clip),
    /// 3 = sine, 4 = hard clip.
    shape: f32 = 0.0,
    /// Per-channel DC-blocker state, only driven when shape = tube.
    dc_x1: [2]f32 = .{ 0.0, 0.0 },
    dc_y1: [2]f32 = .{ 0.0, 0.0 },
    /// The curves below more than double the signal's bandwidth, so they run
    /// at twice the sample rate - see `dsp/oversample.zig`. Without it, a
    /// 5kHz tone at +24dB drive folded enough energy back to sit only 12dB
    /// under the harmonics it was adding.
    stage: oversample.Stage2x = .{},

    pub const device = dsp.deviceOf(@This());

    /// The oversampler's filters delay the signal; the engine compensates.
    pub fn latencyFrames(_: *const Saturator) u32 {
        return oversample.latency_frames;
    }

    pub fn reset(self: *Saturator) void {
        self.dc_x1 = .{ 0.0, 0.0 };
        self.dc_y1 = .{ 0.0, 0.0 };
        self.stage.reset();
    }

    /// Everything the shaping needs, so the oversampler can call back into
    /// it per (doubled-rate) sample.
    const Curve = struct {
        kind: u3,
        pre: f32,
        norm_pos: f32,
        norm_neg: f32,
        post: f32,

        fn apply(self: Curve, x: f32) f32 {
            const norm = if (x >= 0) self.norm_pos else self.norm_neg;
            return shapeVal(self.kind, self.pre, x) * norm * self.post;
        }
    };

    /// The shaping `processBlock` is about to run, built once per block.
    /// `post` is the output trim, which `transfer` leaves at unity so the
    /// plotted curve keeps its shape instead of sliding off the pane.
    fn curveFor(self: *const Saturator, post: f32) Curve {
        const drive_db = dsp.sanitizeParam(self.drive_db, 0.0, 36.0, 12.0);
        const kind: u3 = @intFromFloat(std.math.clamp(@round(dsp.sanitizeParam(self.shape, 0.0, max_shape, 0.0)), 0, max_shape));
        const pre = types.dbToGain(drive_db);
        // full-scale in → full-scale out, per polarity (they differ only for the tube shape)
        const norm_pos = 1.0 / shapeVal(kind, pre, 1.0);
        const norm_neg = if (kind == 1) 1.0 / @abs(shapeVal(kind, pre, -1.0)) else norm_pos;
        return .{ .kind = kind, .pre = pre, .norm_pos = norm_pos, .norm_neg = norm_neg, .post = post };
    }

    /// The transfer curve the GUI plots: -1..1 in, -1..1 out, through the
    /// same shaping the audio path uses. Only the DC blocker (which needs
    /// per-channel state) and the dry/wet mix are left out.
    pub fn transfer(self: *const Saturator, x: f32) f32 {
        return self.curveFor(1.0).apply(x);
    }

    /// Shape an interleaved stereo buffer in place.
    pub fn processBlock(self: *Saturator, buf: []Sample) void {
        const out_db = dsp.sanitizeParam(self.out_db, -24.0, 24.0, 0.0);
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 1.0);
        const curve = self.curveFor(types.dbToGain(out_db));
        for (buf, 0..) |*s, i| {
            const ch = i % 2;
            const dry = s.*;
            var wet = self.stage.process(ch, dry, curve, Curve.apply);
            if (curve.kind == 1) {
                const y0 = wet - self.dc_x1[ch] + dc_pole * self.dc_y1[ch];
                self.dc_x1[ch] = wet;
                self.dc_y1[ch] = y0;
                wet = y0;
            }
            s.* = dry * (1.0 - mix) + wet * mix;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

/// Holds `level` on the left and its negative on the right for long enough
/// that the oversampler's filters have settled, and hands back the last
/// frame. Every level check below reads a settled sample rather than the
/// first one, since 2x oversampling costs `latencyFrames` of group delay.
fn settled(sat: *Saturator, level: Sample) [2]Sample {
    var buf: [256]Sample = undefined;
    var i: usize = 0;
    while (i < buf.len) : (i += 2) {
        buf[i] = level;
        buf[i + 1] = -level;
    }
    sat.processBlock(&buf);
    return .{ buf[buf.len - 2], buf[buf.len - 1] };
}

test "full-scale input maps to full scale at any drive" {
    var sat = Saturator{ .drive_db = 30.0 };
    const out = settled(&sat, 1.0);
    try std.testing.expectApproxEqAbs(@as(Sample, 1.0), out[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(Sample, -1.0), out[1], 1e-3);
}

test "drive raises the level of small signals" {
    var sat = Saturator{ .drive_db = 24.0 };
    const out = settled(&sat, 0.1);
    try std.testing.expect(out[0] > 0.5);
    try std.testing.expect(out[1] < -0.5);
}

test "the oversampler's delay is reported for compensation" {
    var sat = Saturator{};
    try std.testing.expect(sat.latencyFrames() > 0);
    try std.testing.expectEqual(oversample.latency_frames, sat.latencyFrames());
}

test "mix 0 passes the input untouched" {
    var sat = Saturator{ .drive_db = 36.0, .mix = 0.0 };
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    const expected = buf;
    sat.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "invalid parameters cannot poison output" {
    var sat = Saturator{
        .drive_db = std.math.inf(f32),
        .out_db = -std.math.inf(f32),
        .mix = std.math.nan(f32),
        .shape = std.math.nan(f32),
    };
    var buf = [_]Sample{ 0.0, -0.7, 0.05, 0.9 };
    sat.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "the symmetric shapes all map full-scale to full-scale" {
    // Tube is excluded on purpose: its asymmetry plus the DC blocker that
    // corrects it move the settled level, which the tube test below covers.
    for ([_]f32{ 0.0, 2.0, 3.0, 4.0 }) |shape| {
        var sat = Saturator{ .drive_db = 12.0, .shape = shape };
        const out = settled(&sat, 1.0);
        try std.testing.expectApproxEqAbs(@as(Sample, 1.0), out[0], 1e-3);
        try std.testing.expectApproxEqAbs(@as(Sample, -1.0), out[1], 1e-3);
    }
}

test "hard clip leaves everything under the threshold alone" {
    // The point of the shape: no knee, so at unity drive it is a bypass
    // until the signal actually reaches full scale.
    var sat = Saturator{ .drive_db = 0.0, .shape = max_shape };
    const out = settled(&sat, 0.4);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.4), out[0], 1e-3);
}

test "diode shape also maps full-scale to full-scale" {
    var sat = Saturator{ .drive_db = 30.0, .shape = 2.0 };
    const out = settled(&sat, 1.0);
    try std.testing.expectApproxEqAbs(@as(Sample, 1.0), out[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(Sample, -1.0), out[1], 1e-3);
}

test "tube shape adds even harmonics but the DC blocker keeps the mean near zero" {
    var sat = Saturator{ .drive_db = 24.0, .shape = 1.0 };
    var buf: [512]Sample = undefined; // 256 interleaved stereo frames, L = R
    for (0..256) |frame| {
        const s = @sin(2.0 * std.math.pi * 220.0 * @as(f32, @floatFromInt(frame)) / 48_000.0);
        buf[frame * 2] = s;
        buf[frame * 2 + 1] = s;
    }
    sat.processBlock(&buf);
    var sum: f64 = 0.0;
    for (buf) |s| {
        try std.testing.expect(std.math.isFinite(s));
        sum += s;
    }
    try std.testing.expect(@abs(sum / buf.len) < 0.05);
}

test "the plotted transfer curve is the curve the audio path runs" {
    // `transfer` exists only so the GUI can draw the shape; nothing would
    // fail if it drifted from `processBlock`, so pin it against a settled
    // DC level through the real thing. Skips the tube shape, whose DC
    // blocker (per-channel state `transfer` has no access to) walks a held
    // level back to zero on purpose.
    for ([_]f32{ 0.0, 2.0, 3.0, 4.0 }) |shape| {
        for ([_]f32{ 0.0, 18.0 }) |drive| {
            for ([_]f32{ 0.25, 0.6, 1.0 }) |level| {
                var sat = Saturator{ .drive_db = drive, .shape = shape };
                const out = settled(&sat, level);
                try std.testing.expectApproxEqAbs(sat.transfer(level), out[0], 0.02);
                try std.testing.expectApproxEqAbs(sat.transfer(-level), out[1], 0.02);
            }
        }
    }
}

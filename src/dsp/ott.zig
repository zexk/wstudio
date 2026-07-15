//! OTT as its own chain unit: a fixed, aggressively-tuned wrapper over
//! `MultibandComp` (style locked to `.ott`, deep thresholds, hot ratios,
//! per-band makeup) exposing only the four controls Xfer's plugin made
//! famous: depth (dry/wet), time (scales attack+release together), and
//! in/out gain. Anyone who wants to reach the underlying crossover points
//! or per-band settings inserts a full Multiband unit instead; this one
//! exists so "that sound" is two keystrokes, not nine parameter edits.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const MultibandComp = @import("multiband_comp.zig").MultibandComp;

const Sample = types.Sample;

/// Attack/release at time = 1.0x; `setTime` scales both together, keeping
/// their ratio (the unit's "speed" is one knob, like the original).
const base_attack_ms: f32 = 13.0;
const base_release_ms: f32 = 130.0;

pub const Ott = struct {
    mb: MultibandComp = .{},
    /// Speed multiplier on the fixed attack/release pair, 0.25x..4x.
    time: f32 = 1.0,
    gain_in_db: f32 = 0.0,
    gain_out_db: f32 = 0.0,

    pub fn init(sample_rate: u32) Ott {
        var mb = MultibandComp.init(sample_rate);
        mb.style = .ott;
        mb.setXovers(120.0, 2500.0);
        mb.attack_ms = base_attack_ms;
        mb.release_ms = base_release_ms;
        // Deep thresholds + hot ratios squash both ways toward -30dB-ish;
        // the makeup lifts the flattened result back to musical level so
        // inserting the unit reads as "denser", not "quieter". Slight
        // bright tilt (high band squashed least) keeps the top end alive.
        mb.bands[0] = .{ .threshold_db = -32.0, .ratio = 5.0, .makeup_db = 9.0 };
        mb.bands[1] = .{ .threshold_db = -30.0, .ratio = 5.0, .makeup_db = 9.0 };
        mb.bands[2] = .{ .threshold_db = -28.0, .ratio = 4.0, .makeup_db = 9.0 };
        return .{ .mb = mb };
    }

    /// Dry/wet blend, 0..1 - rides `MultibandComp.mix` directly.
    pub fn depth(self: *const Ott) f32 {
        return self.mb.mix;
    }

    pub fn setDepth(self: *Ott, v: f32) void {
        if (!std.math.isFinite(v)) return;
        self.mb.mix = std.math.clamp(v, 0.0, 1.0);
    }

    pub fn setTime(self: *Ott, v: f32) void {
        if (!std.math.isFinite(v)) return;
        self.time = std.math.clamp(v, 0.25, 4.0);
        self.mb.attack_ms = base_attack_ms * self.time;
        self.mb.release_ms = base_release_ms * self.time;
    }

    pub fn processBlock(self: *Ott, buf: []Sample) void {
        const gin = types.dbToGain(self.gain_in_db);
        const gout = types.dbToGain(self.gain_out_db);
        if (self.gain_in_db != 0.0) for (buf) |*s| {
            s.* *= gin;
        };
        self.mb.processBlock(buf);
        if (self.gain_out_db != 0.0) for (buf) |*s| {
            s.* *= gout;
        };
    }

    pub const device = dsp.deviceOf(@This());

    /// Clears the underlying MultibandComp's crossover/envelope state
    /// without touching its sample-rate-derived coefficients - callers
    /// embedding an `Ott` by value (e.g. PolySynth's internal FX section)
    /// must use this instead of `= .{}`.
    pub fn reset(self: *Ott) void {
        self.mb.reset();
    }
};

test "defaults squash a quiet signal upward" {
    var ott = Ott.init(48_000);
    var quiet: [512]Sample = undefined;
    for (0..200) |_| {
        for (0..256) |i| {
            const s: f32 = if (i % 4 < 2) 0.01 else -0.01;
            quiet[i * 2] = s;
            quiet[i * 2 + 1] = s;
        }
        ott.processBlock(&quiet);
    }
    // -40dBFS in, well above it out: the upward stage plus makeup is the
    // whole point of the fixed tuning.
    try std.testing.expect(@abs(quiet[510]) > 0.03);
}

test "depth 0 passes the signal through untouched" {
    var ott = Ott.init(48_000);
    ott.setDepth(0.0);
    var buf: [512]Sample = undefined;
    for (0..40) |_| {
        @memset(&buf, 0.5);
        ott.processBlock(&buf);
    }
    try std.testing.expectApproxEqAbs(@as(Sample, 0.5), buf[510], 1e-4);
}

test "setTime scales the shared attack/release pair and clamps" {
    var ott = Ott.init(48_000);
    ott.setTime(2.0);
    try std.testing.expectApproxEqAbs(base_attack_ms * 2.0, ott.mb.attack_ms, 1e-3);
    try std.testing.expectApproxEqAbs(base_release_ms * 2.0, ott.mb.release_ms, 1e-3);
    ott.setTime(100.0);
    try std.testing.expectEqual(@as(f32, 4.0), ott.time);
}

test "setters ignore non-finite values" {
    var ott = Ott.init(48_000);
    const depth = ott.depth();
    const time = ott.time;
    ott.setDepth(std.math.nan(f32));
    ott.setTime(std.math.inf(f32));
    try std.testing.expectEqual(depth, ott.depth());
    try std.testing.expectEqual(time, ott.time);
}

test "out gain applies after the squash" {
    var loud = Ott.init(48_000);
    var cut = Ott.init(48_000);
    cut.gain_out_db = -12.0;
    var buf_a: [512]Sample = undefined;
    var buf_b: [512]Sample = undefined;
    for (0..100) |_| {
        @memset(&buf_a, 0.25);
        @memset(&buf_b, 0.25);
        loud.processBlock(&buf_a);
        cut.processBlock(&buf_b);
    }
    try std.testing.expectApproxEqAbs(buf_a[510] * types.dbToGain(-12.0), buf_b[510], 1e-3);
}

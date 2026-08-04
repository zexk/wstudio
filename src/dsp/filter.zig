//! Multimode resonant filter with drive and dry/wet mix.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

pub const Filter = struct {
    /// 0 = low-pass, 1 = high-pass, 2 = band-pass.
    mode: f32 = 0,
    cutoff_hz: f32 = 1000,
    resonance: f32 = 0.7,
    drive_db: f32 = 0,
    mix: f32 = 1,
    sample_rate: f32,
    low: [2]f32 = .{ 0, 0 },
    band: [2]f32 = .{ 0, 0 },

    pub fn init(sample_rate: u32) Filter {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1000)) };
    }

    pub fn processBlock(self: *Filter, buf: []types.Sample) void {
        const cutoff = dsp.sanitizeParam(self.cutoff_hz, 20, @min(20_000, self.sample_rate * 0.45), 1000);
        const resonance = dsp.sanitizeParam(self.resonance, 0.1, 1.4, 0.7);
        const drive = types.dbToGain(dsp.sanitizeParam(self.drive_db, 0, 24, 0));
        const mix = dsp.sanitizeParam(self.mix, 0, 1, 1);
        const mode: u2 = @intFromFloat(std.math.clamp(@round(dsp.sanitizeParam(self.mode, 0, 2, 0)), 0, 2));
        const damping = 1 / resonance;
        // This SVF topology is only conditionally stable: solving its
        // characteristic equation's Jury conditions for [low, band] gives
        // f^2 + 2*f*damping < 4 as the binding constraint (the other,
        // f*damping < 2, is looser and falls out for free once this one
        // holds). Past that boundary the state (self.low/self.band, never
        // clamped like the output is) grows every sample instead of
        // settling, reaching NaN within a few hundred blocks - reachable at
        // ordinary settings (e.g. resonance 1.4, cutoff 20kHz at 48kHz is
        // already past it). Capping f at the boundary (95% of it, for
        // rounding headroom) trades a silently narrower cutoff at extreme
        // resonance for never leaving the filter stuck blown up until
        // `reset()`.
        const f_stable_max = 0.95 * (-damping + @sqrt(damping * damping + 4.0));
        const f = @min(2 * @sin(std.math.pi * cutoff / self.sample_rate), f_stable_max);

        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            inline for (0..2) |channel| {
                const dry = dsp.sanitizeParam(buf[i + channel], -16, 16, 0);
                const input = std.math.tanh(dry * drive);
                self.low[channel] += f * self.band[channel];
                const high = input - self.low[channel] - damping * self.band[channel];
                self.band[channel] += f * high;
                const wet = switch (mode) {
                    0 => self.low[channel],
                    1 => high,
                    else => self.band[channel],
                };
                buf[i + channel] = std.math.clamp(dry * (1 - mix) + wet * mix, -16, 16);
            }
        }
    }

    pub fn reset(self: *Filter) void {
        self.low = .{ 0, 0 };
        self.band = .{ 0, 0 };
    }

    pub const device = dsp.deviceOf(@This());
};

test "filter modes stay finite under hostile input" {
    inline for (0..3) |mode| {
        var filter = Filter.init(48_000);
        filter.mode = mode;
        filter.cutoff_hz = 20_000;
        filter.resonance = 1.4;
        filter.drive_db = 24;
        try dsp.expectBoundedUnderNoise(&filter, 16.1);
    }
}

test "mix zero passes input unchanged" {
    var filter = Filter.init(48_000);
    filter.mix = 0;
    var buf = [_]types.Sample{ 0.25, -0.5, 0.75, -1 };
    const expected = buf;
    filter.processBlock(&buf);
    try std.testing.expectEqualSlices(types.Sample, &expected, &buf);
}

test "low resonance and high cutoff together do not blow the filter's state up to NaN" {
    // This SVF's char.-eq. determinant is 1 - f*damping; f*damping >= 2
    // makes the (never-clamped) low/band state diverge exponentially every
    // sample instead of settling - reachable at the corner every knob can
    // independently reach (minimum resonance, near-maximum cutoff).
    inline for (0..3) |mode| {
        var filter = Filter.init(48_000);
        filter.mode = mode;
        filter.cutoff_hz = 20_000;
        filter.resonance = 0.1;
        var buf: [512]types.Sample = undefined;
        for (0..200) |_| {
            for (&buf, 0..) |*s, i| s.* = 0.1 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
            filter.processBlock(&buf);
        }
        try std.testing.expect(std.math.isFinite(filter.low[0]));
        try std.testing.expect(std.math.isFinite(filter.band[0]));
        for (buf) |s| try std.testing.expect(std.math.isFinite(s));
    }
}

test "every resonance/cutoff corner stays finite under sustained resonant excitation" {
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    for (0..200) |_| {
        var filter = Filter.init(48_000);
        filter.resonance = 0.1 + rand.float(f32) * 1.3; // full [0.1, 1.4] range
        filter.cutoff_hz = 20 + rand.float(f32) * (20_000 - 20);
        var buf: [512]types.Sample = undefined;
        for (0..50) |_| {
            for (&buf, 0..) |*s, i| s.* = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
            filter.processBlock(&buf);
        }
        try std.testing.expect(std.math.isFinite(filter.low[0]));
        try std.testing.expect(std.math.isFinite(filter.band[0]));
    }
}

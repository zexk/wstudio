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
        const f = 2 * @sin(std.math.pi * cutoff / self.sample_rate);
        const damping = 1 / resonance;

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

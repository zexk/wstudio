//! Stereo utility: gain, polarity, mono, channel selection, and swap.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

pub const Utility = struct {
    gain_db: f32 = 0,
    invert: f32 = 0,
    mono: f32 = 0,
    /// 0 = stereo, 1 = left, 2 = right.
    channel: f32 = 0,
    swap: f32 = 0,

    pub const device = dsp.deviceOf(@This());

    pub fn reset(self: *Utility) void {
        _ = self;
    }

    pub fn processBlock(self: *Utility, buf: []types.Sample) void {
        const gain = types.dbToGain(dsp.sanitizeParam(self.gain_db, -24, 24, 0));
        const polarity: f32 = if (dsp.sanitizeParam(self.invert, 0, 1, 0) >= 0.5) -1 else 1;
        const mono = dsp.sanitizeParam(self.mono, 0, 1, 0) >= 0.5;
        const channel: u2 = @intFromFloat(@round(dsp.sanitizeParam(self.channel, 0, 2, 0)));
        const swap = dsp.sanitizeParam(self.swap, 0, 1, 0) >= 0.5;

        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            var left = dsp.sanitizeParam(buf[i], -16, 16, 0);
            var right = dsp.sanitizeParam(buf[i + 1], -16, 16, 0);
            switch (channel) {
                1 => right = left,
                2 => left = right,
                else => if (mono) {
                    left = (left + right) * 0.5;
                    right = left;
                },
            }
            if (swap) std.mem.swap(f32, &left, &right);
            buf[i] = left * gain * polarity;
            buf[i + 1] = right * gain * polarity;
        }
    }
};

test "utility channel operations and gain compose" {
    var utility: Utility = .{ .gain_db = 6.0206, .invert = 1, .swap = 1 };
    var buf = [_]types.Sample{ 0.25, -0.5 };
    utility.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 1), buf[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), buf[1], 1e-4);

    utility = .{ .mono = 1 };
    buf = .{ 0.25, -0.5 };
    utility.processBlock(&buf);
    try std.testing.expectApproxEqAbs(buf[0], buf[1], 1e-6);

    utility = .{ .channel = 1 };
    buf = .{ 0.25, -0.5 };
    utility.processBlock(&buf);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25 }, &buf);
}

test "utility stays finite under hostile input" {
    var utility: Utility = .{
        .gain_db = std.math.nan(f32),
        .invert = std.math.inf(f32),
        .mono = std.math.nan(f32),
        .channel = std.math.inf(f32),
        .swap = std.math.nan(f32),
    };
    var buf = [_]types.Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1 };
    utility.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

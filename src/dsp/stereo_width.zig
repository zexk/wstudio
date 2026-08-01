//! Mono-compatible mid/side stereo width with output trim.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

pub const StereoWidth = struct {
    width: f32 = 1,
    output_db: f32 = 0,
    correlation: f32 = 1,

    pub const device = dsp.deviceOf(@This());

    pub fn reset(self: *StereoWidth) void {
        _ = self;
    }

    pub fn processBlock(self: *StereoWidth, buf: []types.Sample) void {
        const width = dsp.sanitizeParam(self.width, 0, 2, 1);
        const output = types.dbToGain(dsp.sanitizeParam(self.output_db, -24, 12, 0));
        var sum_lr: f64 = 0;
        var sum_l2: f64 = 0;
        var sum_r2: f64 = 0;
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const left = dsp.sanitizeParam(buf[i], -16, 16, 0);
            const right = dsp.sanitizeParam(buf[i + 1], -16, 16, 0);
            const mid = (left + right) * 0.5;
            const side = (left - right) * 0.5 * width;
            buf[i] = (mid + side) * output;
            buf[i + 1] = (mid - side) * output;
            sum_lr += @as(f64, buf[i]) * buf[i + 1];
            sum_l2 += @as(f64, buf[i]) * buf[i];
            sum_r2 += @as(f64, buf[i + 1]) * buf[i + 1];
        }
        const denom = @sqrt(sum_l2 * sum_r2);
        self.correlation = if (denom > 1e-12) @floatCast(std.math.clamp(sum_lr / denom, -1, 1)) else 1;
    }
};

test "width zero is mono and width one passes stereo unchanged" {
    var width: StereoWidth = .{ .width = 0 };
    var buf = [_]types.Sample{ 0.75, -0.25 };
    width.processBlock(&buf);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25 }, &buf);

    width.width = 1;
    buf = .{ 0.75, -0.25 };
    width.processBlock(&buf);
    try std.testing.expectEqualSlices(f32, &.{ 0.75, -0.25 }, &buf);
}

test "stereo width stays finite under hostile input" {
    var width: StereoWidth = .{ .width = std.math.nan(f32), .output_db = std.math.inf(f32) };
    var buf = [_]types.Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1 };
    width.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
    try std.testing.expect(std.math.isFinite(width.correlation));
}

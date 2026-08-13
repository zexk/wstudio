//! Stereo utility: gain, polarity, mono, channel selection, and swap.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

pub const Utility = struct {
    pub const max_delay_frames: usize = 4096;

    gain_db: f32 = 0,
    invert: f32 = 0,
    mono: f32 = 0,
    /// 0 = stereo, 1 = left, 2 = right.
    channel: f32 = 0,
    swap: f32 = 0,
    delay_frames: f32 = 0,
    delay_line_l: []types.Sample,
    delay_line_r: []types.Sample,
    write_pos: usize = 0,

    pub const device = dsp.deviceOf(@This());

    pub fn init(allocator: std.mem.Allocator) !Utility {
        const left = try allocator.alloc(types.Sample, max_delay_frames + 1);
        errdefer allocator.free(left);
        const right = try allocator.alloc(types.Sample, max_delay_frames + 1);
        @memset(left, 0);
        @memset(right, 0);
        return .{ .delay_line_l = left, .delay_line_r = right };
    }

    pub fn deinit(self: *Utility, allocator: std.mem.Allocator) void {
        allocator.free(self.delay_line_l);
        allocator.free(self.delay_line_r);
        self.delay_line_l = &.{};
        self.delay_line_r = &.{};
    }

    pub fn reset(self: *Utility) void {
        @memset(self.delay_line_l, 0);
        @memset(self.delay_line_r, 0);
        self.write_pos = 0;
    }

    pub fn processBlock(self: *Utility, buf: []types.Sample) void {
        const gain = types.dbToGain(dsp.sanitizeParam(self.gain_db, -24, 24, 0));
        const polarity: f32 = if (dsp.sanitizeParam(self.invert, 0, 1, 0) >= 0.5) -1 else 1;
        const mono = dsp.sanitizeParam(self.mono, 0, 1, 0) >= 0.5;
        const channel: u2 = @intFromFloat(@round(dsp.sanitizeParam(self.channel, 0, 2, 0)));
        const swap = dsp.sanitizeParam(self.swap, 0, 1, 0) >= 0.5;
        const delay: usize = @intFromFloat(@round(dsp.sanitizeParam(self.delay_frames, 0, max_delay_frames, 0)));

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
            self.delay_line_l[self.write_pos] = left * gain * polarity;
            self.delay_line_r[self.write_pos] = right * gain * polarity;
            const read_pos = (self.write_pos + self.delay_line_l.len - delay) % self.delay_line_l.len;
            buf[i] = self.delay_line_l[read_pos];
            buf[i + 1] = self.delay_line_r[read_pos];
            self.write_pos = (self.write_pos + 1) % self.delay_line_l.len;
        }
    }
};

test "utility channel operations and gain compose" {
    var utility = try Utility.init(std.testing.allocator);
    defer utility.deinit(std.testing.allocator);
    utility.gain_db = 6.0206;
    utility.invert = 1;
    utility.swap = 1;
    var buf = [_]types.Sample{ 0.25, -0.5 };
    utility.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 1), buf[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), buf[1], 1e-4);

    utility.deinit(std.testing.allocator);
    utility = try Utility.init(std.testing.allocator);
    utility.mono = 1;
    buf = .{ 0.25, -0.5 };
    utility.processBlock(&buf);
    try std.testing.expectApproxEqAbs(buf[0], buf[1], 1e-6);

    utility.deinit(std.testing.allocator);
    utility = try Utility.init(std.testing.allocator);
    utility.channel = 1;
    buf = .{ 0.25, -0.5 };
    utility.processBlock(&buf);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25 }, &buf);
}

test "utility stays finite under hostile input" {
    var utility = try Utility.init(std.testing.allocator);
    defer utility.deinit(std.testing.allocator);
    utility.gain_db = std.math.nan(f32);
    utility.invert = std.math.inf(f32);
    utility.mono = std.math.nan(f32);
    utility.channel = std.math.inf(f32);
    utility.swap = std.math.nan(f32);
    var buf = [_]types.Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1 };
    utility.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "utility delays by exact sample frames" {
    var utility = try Utility.init(std.testing.allocator);
    defer utility.deinit(std.testing.allocator);
    utility.delay_frames = 2;
    var buf = [_]types.Sample{ 1, -1, 2, -2, 3, -3, 4, -4 };
    utility.processBlock(&buf);
    try std.testing.expectEqualSlices(types.Sample, &.{ 0, 0, 0, 0, 1, -1, 2, -2 }, &buf);
}

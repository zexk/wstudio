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
    noise_on: f32 = 0,
    /// 0 white, 1 pink, 2 brown, 3 blue, 4 violet.
    noise_color: f32 = 0,
    noise_db: f32 = -18,
    delay_line_l: []types.Sample,
    delay_line_r: []types.Sample,
    write_pos: usize = 0,
    noise_state: u32 = 0x6d2b79f5,
    noise_low: f32 = 0,
    noise_prev: f32 = 0,
    noise_diff_prev: f32 = 0,

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
        self.noise_state = 0x6d2b79f5;
        self.noise_low = 0;
        self.noise_prev = 0;
        self.noise_diff_prev = 0;
    }

    fn noiseSample(self: *Utility, color: u3) f32 {
        var x = self.noise_state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.noise_state = x;
        const white = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(std.math.maxInt(u32))) * 2.0 - 1.0;
        const diff = (white - self.noise_prev) * 0.5;
        const second_diff = (diff - self.noise_diff_prev) * 0.5;
        self.noise_low = self.noise_low * 0.98 + white * 0.02;
        self.noise_prev = white;
        self.noise_diff_prev = diff;
        return switch (color) {
            1 => std.math.clamp(self.noise_low * 3.0 + white * 0.35, -1.0, 1.0),
            2 => std.math.clamp(self.noise_low * 4.0, -1.0, 1.0),
            3 => diff,
            4 => second_diff,
            else => white,
        };
    }

    pub fn processBlock(self: *Utility, buf: []types.Sample) void {
        const gain = types.dbToGain(dsp.sanitizeParam(self.gain_db, -24, 24, 0));
        const polarity: f32 = if (dsp.sanitizeParam(self.invert, 0, 1, 0) >= 0.5) -1 else 1;
        const mono = dsp.sanitizeParam(self.mono, 0, 1, 0) >= 0.5;
        const channel: u2 = @intFromFloat(@round(dsp.sanitizeParam(self.channel, 0, 2, 0)));
        const swap = dsp.sanitizeParam(self.swap, 0, 1, 0) >= 0.5;
        const delay: usize = @intFromFloat(@round(dsp.sanitizeParam(self.delay_frames, 0, max_delay_frames, 0)));
        const noise_on = dsp.sanitizeParam(self.noise_on, 0, 1, 0) >= 0.5;
        const noise_color: u3 = @intFromFloat(@round(dsp.sanitizeParam(self.noise_color, 0, 4, 0)));
        const noise_gain = types.dbToGain(dsp.sanitizeParam(self.noise_db, -60, 0, -18));

        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            var left = dsp.sanitizeParam(buf[i], -16, 16, 0);
            var right = dsp.sanitizeParam(buf[i + 1], -16, 16, 0);
            if (noise_on) {
                const noise = self.noiseSample(noise_color) * noise_gain;
                left += noise;
                right += noise;
            }
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

test "utility generates deterministic colored noise" {
    var utility = try Utility.init(std.testing.allocator);
    defer utility.deinit(std.testing.allocator);
    utility.noise_on = 1;
    utility.noise_color = 2;
    var first = [_]types.Sample{0} ** 16;
    utility.processBlock(&first);
    try std.testing.expect(first[0] != 0);
    for (first) |sample| try std.testing.expect(std.math.isFinite(sample));

    utility.reset();
    var second = [_]types.Sample{0} ** 16;
    utility.processBlock(&second);
    try std.testing.expectEqualSlices(types.Sample, &first, &second);
}

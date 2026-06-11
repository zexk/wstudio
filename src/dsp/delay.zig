//! Stereo feedback delay. Delay lines are allocated once at init for
//! the maximum time; changing the time is a control-side operation.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const StereoDelay = struct {
    sample_rate: u32,
    lines: [2][]Sample,
    index: [2]usize = .{ 0, 0 },
    delay_frames: usize,
    feedback: f32 = 0.35,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 0.25,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        max_delay_s: f32,
    ) !StereoDelay {
        const max_frames: usize = @intFromFloat(max_delay_s * @as(f32, @floatFromInt(sample_rate)));
        const left = try allocator.alloc(Sample, @max(max_frames, 1));
        errdefer allocator.free(left);
        const right = try allocator.alloc(Sample, @max(max_frames, 1));
        @memset(left, 0.0);
        @memset(right, 0.0);
        return .{
            .sample_rate = sample_rate,
            .lines = .{ left, right },
            .delay_frames = left.len,
        };
    }

    pub fn deinit(self: *StereoDelay, allocator: std.mem.Allocator) void {
        allocator.free(self.lines[0]);
        allocator.free(self.lines[1]);
    }

    /// Control side; not RT-safe (clears the lines).
    pub fn setTime(self: *StereoDelay, seconds: f32) void {
        const frames: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(self.sample_rate)));
        self.delay_frames = std.math.clamp(frames, 1, self.lines[0].len);
        self.clear();
    }

    pub fn clear(self: *StereoDelay) void {
        @memset(self.lines[0], 0.0);
        @memset(self.lines[1], 0.0);
        self.index = .{ 0, 0 };
    }

    pub fn device(self: *StereoDelay) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .reset = resetOpaque,
    };

    pub fn processBlock(self: *StereoDelay, buf: []Sample) void {
        const frames = buf.len / 2;
        for (0..frames) |i| {
            inline for (0..2) |ch| {
                const dry = buf[i * 2 + ch];
                const line = self.lines[ch];
                const idx = self.index[ch];
                const wet = line[idx];
                line[idx] = dry + wet * self.feedback;
                self.index[ch] = (idx + 1) % self.delay_frames;
                buf[i * 2 + ch] = dry * (1.0 - self.mix) + wet * self.mix;
            }
        }
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *StereoDelay = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *StereoDelay = @ptrCast(@alignCast(ptr));
        self.clear();
    }
};

test "impulse echoes at the delay time with feedback decay" {
    var delay = try StereoDelay.init(std.testing.allocator, 1000, 1.0);
    defer delay.deinit(std.testing.allocator);
    delay.setTime(0.1); // 100 frames
    delay.mix = 0.5;
    delay.feedback = 0.5;

    // 400 frames stereo: impulse at frame 0
    var buf = [_]Sample{0.0} ** 800;
    buf[0] = 1.0;
    buf[1] = 1.0;
    delay.processBlock(&buf);

    try std.testing.expectApproxEqAbs(@as(Sample, 0.5), buf[0], 1e-6); // dry half
    try std.testing.expectApproxEqAbs(@as(Sample, 0.5), buf[100 * 2], 1e-6); // first echo
    try std.testing.expectApproxEqAbs(@as(Sample, 0.25), buf[200 * 2], 1e-6); // second echo
    try std.testing.expectEqual(@as(Sample, 0.0), buf[50 * 2]); // silence between
}

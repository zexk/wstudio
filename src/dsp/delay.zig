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
        const safe_rate = @max(sample_rate, 1);
        const safe_max_s = if (std.math.isFinite(max_delay_s) and max_delay_s > 0.0) max_delay_s else 1.0;
        const max_frames_f = safe_max_s * @as(f32, @floatFromInt(safe_rate));
        const max_frames: usize = if (max_frames_f >= @as(f32, @floatFromInt(std.math.maxInt(usize))))
            std.math.maxInt(usize)
        else
            @intFromFloat(max_frames_f);
        const left = try allocator.alloc(Sample, @max(max_frames, 1));
        errdefer allocator.free(left);
        const right = try allocator.alloc(Sample, @max(max_frames, 1));
        @memset(left, 0.0);
        @memset(right, 0.0);
        return .{
            .sample_rate = safe_rate,
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
        if (!std.math.isFinite(seconds)) return;
        const frames_f = @max(seconds, 0.0) * @as(f32, @floatFromInt(self.sample_rate));
        self.delay_frames = if (frames_f >= @as(f32, @floatFromInt(self.lines[0].len)))
            self.lines[0].len
        else
            @max(@as(usize, @intFromFloat(frames_f)), 1);
        self.reset();
    }

    pub fn timeSeconds(self: *const StereoDelay) f32 {
        return @as(f32, @floatFromInt(self.delay_frames)) / @as(f32, @floatFromInt(self.sample_rate));
    }

    pub fn reset(self: *StereoDelay) void {
        @memset(self.lines[0], 0.0);
        @memset(self.lines[1], 0.0);
        self.index = .{ 0, 0 };
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *StereoDelay, buf: []Sample) void {
        // feedback >= 1 makes the line's own recurrence grow unbounded on
        // every repeat instead of decaying.
        const feedback = if (std.math.isFinite(self.feedback)) std.math.clamp(self.feedback, 0.0, 0.95) else 0.35;
        const mix = if (std.math.isFinite(self.mix)) std.math.clamp(self.mix, 0.0, 1.0) else 0.25;
        const frames = buf.len / 2;
        for (0..frames) |i| {
            inline for (0..2) |ch| {
                const dry = buf[i * 2 + ch];
                const line = self.lines[ch];
                const idx = self.index[ch];
                const wet = line[idx];
                line[idx] = dry + wet * feedback;
                self.index[ch] = (idx + 1) % self.delay_frames;
                buf[i * 2 + ch] = dry * (1.0 - mix) + wet * mix;
            }
        }
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

test "invalid feedback/mix cannot poison output" {
    var delay = try StereoDelay.init(std.testing.allocator, 1000, 1.0);
    defer delay.deinit(std.testing.allocator);
    delay.setTime(0.1);
    delay.feedback = std.math.inf(f32);
    delay.mix = std.math.nan(f32);
    var buf = [_]Sample{0.5} ** 800;
    delay.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "invalid delay timing inputs stay safe" {
    var delay = try StereoDelay.init(std.testing.allocator, 0, std.math.nan(f32));
    defer delay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), delay.sample_rate);
    try std.testing.expectEqual(@as(usize, 1), delay.delay_frames);
    try std.testing.expectEqual(@as(f32, 1.0), delay.timeSeconds());

    delay.setTime(std.math.nan(f32));
    try std.testing.expectEqual(@as(usize, 1), delay.delay_frames);
    delay.setTime(std.math.inf(f32));
    try std.testing.expectEqual(@as(usize, 1), delay.delay_frames);
    delay.setTime(-1.0);
    try std.testing.expectEqual(@as(usize, 1), delay.delay_frames);
}

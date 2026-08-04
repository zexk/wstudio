//! Stereo feedback delay: a fixed-size ring per channel read through
//! `delay_line`'s cubic-Lagrange tap, so `time_s` is a plain per-block
//! param (like feedback/mix) that can be swept live with no click and no
//! buffer-clearing reset - unlike the old integer-only tap, which needed a
//! control-side `setTime` that resized the active ring and zeroed it.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const delay_line = @import("delay_line.zig");

const Sample = types.Sample;

pub const StereoDelay = struct {
    sample_rate: u32,
    lines: [2][]Sample,
    pos: usize = 0,
    /// Read-only after `init`: the true capacity of `lines` in seconds, so
    /// `time_s` never clamps to a value that would wrap past what was
    /// actually allocated.
    max_time_s: f32,
    time_s: f32 = 0.375,
    feedback: f32 = 0.35,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 0.25,
    /// One-pole lowpass in the feedback path, 0 = off (bright repeats that
    /// match the old unfiltered tap exactly), 1 = heavily damped - each
    /// repeat darkens like a tape/BBD echo unit instead of ringing bright
    /// forever.
    damp: f32 = 0.0,
    damp_state: [2]f32 = .{ 0.0, 0.0 },

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
        // Floor of 4, not 1: delay_line.readInterp's cubic tap reads two
        // frames either side of the read position.
        const capacity = @max(max_frames, 4);
        const left = try allocator.alloc(Sample, capacity);
        errdefer allocator.free(left);
        const right = try allocator.alloc(Sample, capacity);
        @memset(left, 0.0);
        @memset(right, 0.0);
        return .{
            .sample_rate = safe_rate,
            .lines = .{ left, right },
            .max_time_s = @as(f32, @floatFromInt(capacity)) / @as(f32, @floatFromInt(safe_rate)),
        };
    }

    pub fn deinit(self: *StereoDelay, allocator: std.mem.Allocator) void {
        allocator.free(self.lines[0]);
        allocator.free(self.lines[1]);
    }

    pub fn reset(self: *StereoDelay) void {
        @memset(self.lines[0], 0.0);
        @memset(self.lines[1], 0.0);
        self.pos = 0;
        self.damp_state = .{ 0.0, 0.0 };
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *StereoDelay, buf: []Sample) void {
        // feedback >= 1 makes the line's own recurrence grow unbounded on
        // every repeat instead of decaying.
        const feedback = dsp.sanitizeParam(self.feedback, 0.0, 0.95, 0.35);
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 0.25);
        const time_s = dsp.sanitizeParam(self.time_s, 0.0, self.max_time_s, 0.375);
        const damp = dsp.sanitizeParam(self.damp, 0.0, 1.0, 0.0);
        // Floor of 1 frame: the read happens before this frame's write, so a
        // tap of exactly 0 would land on `line[pos]` before it's overwritten
        // - the sample from a full ring-length ago, not "just written". That
        // turns the bottom of the time knob into a multi-second ghost echo
        // instead of a near-instant one; the old integer-index version had
        // the same floor for the same reason (its ring length *was*
        // `delay_frames`, so it could never wrap onto itself mid-read).
        const delay_frames = @max(time_s * @as(f32, @floatFromInt(self.sample_rate)), 1.0);
        const frames = buf.len / 2;
        for (0..frames) |i| {
            inline for (0..2) |ch| {
                const dry = buf[i * 2 + ch];
                const line = self.lines[ch];
                const raw_tap = delay_line.readInterp(line, self.pos, delay_frames);
                self.damp_state[ch] = raw_tap * (1.0 - damp) + self.damp_state[ch] * damp;
                const tap = self.damp_state[ch];
                line[self.pos] = dry + tap * feedback;
                buf[i * 2 + ch] = dry * (1.0 - mix) + tap * mix;
            }
            self.pos = (self.pos + 1) % self.lines[0].len;
        }
    }
};

test "impulse echoes at the delay time with feedback decay" {
    var delay = try StereoDelay.init(std.testing.allocator, 1000, 1.0);
    defer delay.deinit(std.testing.allocator);
    delay.time_s = 0.1; // 100 frames
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

test "fractional delay time interpolates instead of snapping to one integer tap" {
    var delay = try StereoDelay.init(std.testing.allocator, 1000, 1.0);
    defer delay.deinit(std.testing.allocator);
    delay.time_s = 0.1005; // 100.5 frames: read position sits half way between
    // frame 0 (the impulse) and frame 1 (silence) when it arrives at frame 101.
    delay.mix = 1.0;
    delay.feedback = 0.0;

    var buf = [_]Sample{0.0} ** 400;
    buf[0] = 1.0;
    buf[1] = 1.0;
    delay.processBlock(&buf);

    // Old integer-only tap would truncate to exactly 100 frames and echo
    // the impulse at full strength (1.0); the cubic Lagrange tap instead
    // blends the impulse with its zero neighbor.
    try std.testing.expectApproxEqAbs(@as(Sample, 0.5625), buf[101 * 2], 1e-4);
}

test "damp shrinks the second echo compared to an undamped run" {
    const params = struct {
        fn secondEcho(damp: f32) !f32 {
            var delay = try StereoDelay.init(std.testing.allocator, 8000, 1.0);
            defer delay.deinit(std.testing.allocator);
            delay.time_s = 0.01; // 80 frames: two echoes fit in one block
            delay.mix = 1.0;
            delay.feedback = 0.6;
            delay.damp = damp;

            var buf = [_]Sample{0.0} ** 400;
            buf[0] = 1.0;
            buf[1] = 1.0;
            delay.processBlock(&buf);
            return @abs(buf[160 * 2]);
        }
    };
    try std.testing.expect(try params.secondEcho(0.9) < try params.secondEcho(0.0));
}

test "changing time_s live does not clear the ring" {
    var delay = try StereoDelay.init(std.testing.allocator, 1000, 1.0);
    defer delay.deinit(std.testing.allocator);
    delay.time_s = 0.1;
    delay.mix = 1.0;
    delay.feedback = 0.5;

    var buf = [_]Sample{0.0} ** 4;
    buf[0] = 1.0;
    delay.processBlock(&buf); // writes line[0] = 1.0
    delay.time_s = 0.2; // old setTime would have zeroed the ring here

    try std.testing.expectApproxEqAbs(@as(Sample, 1.0), delay.lines[0][0], 1e-6);
}

test "time_s at the bottom of its range echoes near-instantly, not a full ring-length later" {
    var delay = try StereoDelay.init(std.testing.allocator, 1000, 1.0);
    defer delay.deinit(std.testing.allocator);
    delay.time_s = 0.0;
    delay.feedback = 0.0;
    delay.mix = 1.0;

    var buf = [_]Sample{0.0} ** (1002 * 2);
    buf[0] = 1.0;
    delay.processBlock(&buf);

    // The old read-before-write ring read `line[pos]` before this frame's
    // write ever landed there - at delay_frames = 0 that slot only holds
    // fresh data once every `lines[0].len` (1000) frames, so the impulse
    // reappeared a full ring-length later instead of immediately.
    try std.testing.expectApproxEqAbs(@as(Sample, 0.0), buf[1000 * 2], 1e-4);
    var early_energy: f32 = 0.0;
    for (buf[0 .. 10 * 2]) |s| early_energy += @abs(s);
    try std.testing.expect(early_energy > 0.5);
}

test "invalid parameters cannot poison output" {
    var delay = try StereoDelay.init(std.testing.allocator, 1000, 1.0);
    defer delay.deinit(std.testing.allocator);
    delay.time_s = std.math.nan(f32);
    delay.feedback = std.math.inf(f32);
    delay.mix = std.math.nan(f32);
    delay.damp = -std.math.inf(f32);
    var buf = [_]Sample{0.5} ** 800;
    delay.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "degenerate init args still produce a usable, finite delay" {
    var delay = try StereoDelay.init(std.testing.allocator, 0, std.math.nan(f32));
    defer delay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), delay.sample_rate);
    try std.testing.expect(delay.lines[0].len >= 4);

    var buf = [_]Sample{0.5} ** 32;
    delay.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

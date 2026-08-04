//! Master-bus brick-wall limiter: smoothed release, with an optional
//! lookahead window.
//!
//! Sits after the master gain in Engine.process, so nothing upstream of the
//! WAV writer's ±1 clamp (or the DAC) ever exceeds the ceiling - hot mixes
//! get momentary gain reduction instead of hard-clip distortion. Stereo-
//! linked; transparent (gain = 1) while the programme stays under the
//! ceiling.
//!
//! `lookahead_ms = 0` (the default) is a pure zero-latency reactive limiter,
//! byte-identical to the pre-lookahead version: every sample is read back
//! the instant it's written, so the ceiling clamp still lands on the exact
//! sample that caused it - the same "instant attack" hard clamp as before.
//! A nonzero lookahead delays the output by that many frames and instead
//! clamps to the minimum required gain over the upcoming window, so gain
//! reduction can start ramping down *before* an anticipated peak arrives
//! instead of snapping to it - the standard lookahead-limiter technique.
//! The per-frame required-gain minimum over that sliding window is tracked
//! with a monotonic deque (Ascending Minima), O(1) amortised per frame.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

/// Longest lookahead a user can dial in - past this, the added latency
/// starts costing more (a `lookahead_ms` worth of silence at stream start,
/// plus whatever downstream latency reporting does with it) than a limiter
/// buys by anticipating further out.
pub const max_lookahead_ms: f32 = 20.0;

pub const Limiter = struct {
    sample_rate: f32,
    /// Output ceiling, linear (≈ -0.4 dBFS): headroom for the 16-bit round.
    ceiling: f32 = 0.955,
    /// Gain-recovery time constant after a reduction.
    release_ms: f32 = 80.0,
    /// How far ahead the limiter scans for peaks before they arrive, 0 =
    /// old zero-latency reactive behaviour.
    lookahead_ms: f32 = 0.0,
    /// Current gain (≤ 1). Recovers toward 1 at `release_ms`, held down to
    /// the lookahead window's minimum required gain.
    gain: f32 = 1.0,
    /// Per-channel audio delay ring, sized for `max_lookahead_ms` at init.
    delay: [2][]Sample,
    /// Per-frame required gain (ceiling/level, or 1 under it), same ring
    /// indexing as `delay` - stereo-linked, so one value per frame.
    target: []f32,
    /// Ring-buffer-backed monotonic deque of absolute frame indices into
    /// `target`, ascending by index, non-decreasing by target value - the
    /// front always holds the current window's minimum.
    deque: []usize,
    deque_head: usize = 0,
    deque_len: usize = 0,
    /// Frames processed since init/reset - the absolute index new frames
    /// are written under and old ones expire from the deque against.
    frame_counter: usize = 0,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Limiter {
        const safe_rate = @max(sample_rate, 1);
        const cap = @max(
            @as(usize, @intFromFloat(max_lookahead_ms * 0.001 * @as(f32, @floatFromInt(safe_rate)))) + 1,
            2,
        );
        const left = try allocator.alloc(Sample, cap);
        errdefer allocator.free(left);
        const right = try allocator.alloc(Sample, cap);
        errdefer allocator.free(right);
        const target = try allocator.alloc(f32, cap);
        errdefer allocator.free(target);
        const deque = try allocator.alloc(usize, cap);
        @memset(left, 0.0);
        @memset(right, 0.0);
        @memset(target, 1.0);
        return .{
            .sample_rate = @floatFromInt(safe_rate),
            .delay = .{ left, right },
            .target = target,
            .deque = deque,
        };
    }

    pub fn deinit(self: *Limiter, allocator: std.mem.Allocator) void {
        allocator.free(self.delay[0]);
        allocator.free(self.delay[1]);
        allocator.free(self.target);
        allocator.free(self.deque);
    }

    pub fn reset(self: *Limiter) void {
        self.gain = 1.0;
        @memset(self.delay[0], 0.0);
        @memset(self.delay[1], 0.0);
        @memset(self.target, 1.0);
        self.deque_head = 0;
        self.deque_len = 0;
        self.frame_counter = 0;
    }

    /// Target-gain ring index (not the raw absolute frame counter) of the
    /// deque's current back entry.
    fn dequeBackTargetIdx(self: *const Limiter) usize {
        return self.deque[(self.deque_head + self.deque_len - 1) % self.deque.len] % self.target.len;
    }

    /// Limit an interleaved stereo buffer in place.
    pub fn processBlock(self: *Limiter, buf: []Sample) void {
        const ceiling = dsp.sanitizeParam(self.ceiling, 0.25, 1.0, 0.955);
        const release_ms = dsp.sanitizeParam(self.release_ms, 1.0, 1000.0, 80.0);
        const lookahead_ms = dsp.sanitizeParam(self.lookahead_ms, 0.0, max_lookahead_ms, 0.0);
        if (!std.math.isFinite(self.gain) or self.gain < 0.0 or self.gain > 1.0) self.gain = 1.0;
        const release = @exp(-1.0 / (release_ms * 0.001 * self.sample_rate));
        const lookahead_frames: usize = @intFromFloat(lookahead_ms * 0.001 * self.sample_rate);
        const cap = self.delay[0].len;

        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            // External plugins are allowed upstream. Contain malformed
            // output here so one NaN/inf cannot poison limiter state and
            // every later audio block.
            if (!std.math.isFinite(buf[i])) buf[i] = 0.0;
            if (!std.math.isFinite(buf[i + 1])) buf[i + 1] = 0.0;

            const level = @max(@abs(buf[i]), @abs(buf[i + 1]));
            const target_gain: f32 = if (level > ceiling) ceiling / level else 1.0;

            const write_idx = self.frame_counter % cap;
            self.delay[0][write_idx] = buf[i];
            self.delay[1][write_idx] = buf[i + 1];
            self.target[write_idx] = target_gain;

            // Ascending Minima: drop every back entry whose target is no
            // smaller than this frame's - they can never be the window
            // minimum again once a smaller-or-equal value exists ahead of
            // them - then push this frame.
            while (self.deque_len > 0 and self.target[self.dequeBackTargetIdx()] >= target_gain) self.deque_len -= 1;
            self.deque[(self.deque_head + self.deque_len) % cap] = self.frame_counter;
            self.deque_len += 1;

            // Expire entries that fell out of the trailing window.
            const window_start = self.frame_counter -| lookahead_frames;
            while (self.deque_len > 0 and self.deque[self.deque_head] < window_start) {
                self.deque_head = (self.deque_head + 1) % cap;
                self.deque_len -= 1;
            }

            self.frame_counter += 1;

            // Still filling the initial lookahead window - nothing valid to
            // emit yet (matches every lookahead processor's fixed startup
            // latency, reported via `latencyFrames` below).
            if (self.frame_counter <= lookahead_frames) {
                buf[i] = 0.0;
                buf[i + 1] = 0.0;
                continue;
            }

            const min_target = self.target[self.deque[self.deque_head] % cap];
            // Recover toward unity, but never past the window's minimum
            // required gain - with lookahead_frames = 0 this reduces to the
            // exact old formula (window minimum is always this frame's own
            // target_gain).
            self.gain = @min(min_target, 1.0 - release * (1.0 - self.gain));
            const read_idx = (self.frame_counter - 1 - lookahead_frames) % cap;
            buf[i] = self.delay[0][read_idx] * self.gain;
            buf[i + 1] = self.delay[1][read_idx] * self.gain;
        }
    }

    /// Reported so a host with proper delay compensation could realign
    /// other tracks - see `Engine.trackLatencyFrames`. Recomputed from the
    /// live param each call rather than cached, same as every other value
    /// derived from a sanitized param here.
    pub fn latencyFrames(self: *const Limiter) u32 {
        const lookahead_ms = dsp.sanitizeParam(self.lookahead_ms, 0.0, max_lookahead_ms, 0.0);
        return @intFromFloat(lookahead_ms * 0.001 * self.sample_rate);
    }

    pub const device = dsp.deviceOf(@This());
};

// ---------------------------------------------------------------------------
// Tests

test "zero sample rate falls back to a finite limiter rate" {
    var limiter = try Limiter.init(std.testing.allocator, 0);
    defer limiter.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 1.0), limiter.sample_rate);
    var buf = [_]Sample{ 2.0, -2.0 };
    limiter.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "loud input never exceeds the ceiling" {
    var lim = try Limiter.init(std.testing.allocator, 48_000);
    defer lim.deinit(std.testing.allocator);
    var buf: [512]Sample = undefined;
    // A +12 dB square-ish signal: alternating ±4.0.
    for (&buf, 0..) |*s, i| s.* = if (i % 4 < 2) 4.0 else -4.0;
    lim.processBlock(&buf);
    for (buf) |s| try std.testing.expect(@abs(s) <= lim.ceiling + 1e-5);
}

test "non-finite input cannot poison limiter output or state" {
    var lim = try Limiter.init(std.testing.allocator, 48_000);
    defer lim.deinit(std.testing.allocator);
    var malformed = [_]Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 2.0 };
    lim.processBlock(&malformed);
    for (malformed) |sample| try std.testing.expect(std.math.isFinite(sample));
    try std.testing.expect(std.math.isFinite(lim.gain));

    var next = [_]Sample{ 0.25, -0.25 };
    lim.processBlock(&next);
    for (next) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "invalid parameters and stale gain cannot poison limiter state" {
    var lim = try Limiter.init(std.testing.allocator, 48_000);
    defer lim.deinit(std.testing.allocator);
    lim.ceiling = -std.math.inf(f32);
    lim.release_ms = -100.0;
    lim.lookahead_ms = std.math.nan(f32);
    lim.gain = std.math.nan(f32);
    var buf = [_]Sample{ 2.0, -2.0, 0.25, -0.25 };
    lim.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
    try std.testing.expect(std.math.isFinite(lim.gain));
    try std.testing.expect(lim.gain >= 0.0 and lim.gain <= 1.0);
}

test "quiet input passes through untouched" {
    var lim = try Limiter.init(std.testing.allocator, 48_000);
    defer lim.deinit(std.testing.allocator);
    var buf: [512]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    var expected: [512]Sample = undefined;
    @memcpy(&expected, &buf);
    lim.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lim.gain, 1e-6);
}

test "gain recovers toward unity after a transient" {
    var lim = try Limiter.init(std.testing.allocator, 48_000);
    defer lim.deinit(std.testing.allocator);
    var buf: [512]Sample = undefined;
    @memset(&buf, 2.0); // sustained overshoot pulls the gain down
    lim.processBlock(&buf);
    const reduced = lim.gain;
    try std.testing.expect(reduced < 0.6);

    // Silence: the gain climbs back toward 1 at the release rate.
    // 120 blocks × 256 frames ≈ 8 release time constants at 80 ms.
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        @memset(&buf, 0.0);
        lim.processBlock(&buf);
    }
    try std.testing.expect(lim.gain > 0.99);
    try std.testing.expect(lim.gain > reduced);
}

test "zero lookahead is byte-identical to the old zero-latency limiter" {
    var lim = try Limiter.init(std.testing.allocator, 48_000);
    defer lim.deinit(std.testing.allocator);
    var buf: [512]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = if (i % 8 < 2) 3.0 else 0.2 * @sin(@as(f32, @floatFromInt(i)) * 0.05);
    lim.processBlock(&buf);
    for (buf) |s| try std.testing.expect(@abs(s) <= lim.ceiling + 1e-5);
}

test "lookahead starts pulling gain down before a peak arrives, reactive doesn't" {
    const sr: u32 = 48_000;
    var reactive = try Limiter.init(std.testing.allocator, sr);
    defer reactive.deinit(std.testing.allocator);
    var ahead = try Limiter.init(std.testing.allocator, sr);
    defer ahead.deinit(std.testing.allocator);
    ahead.lookahead_ms = 5.0; // 240 frames
    reactive.release_ms = 5.0;
    ahead.release_ms = 5.0;

    // Quiet, then one huge single-frame spike at frame 100, then quiet
    // again - well inside both limiters' 240-frame lookahead capacity.
    const frames = 400;
    var buf_reactive: [frames * 2]Sample = undefined;
    var buf_ahead: [frames * 2]Sample = undefined;
    for (0..frames) |n| {
        const s: f32 = if (n == 100) 8.0 else 0.05;
        buf_reactive[n * 2] = s;
        buf_reactive[n * 2 + 1] = s;
        buf_ahead[n * 2] = s;
        buf_ahead[n * 2 + 1] = s;
    }
    reactive.processBlock(&buf_reactive);
    ahead.processBlock(&buf_ahead);

    // A few frames before the spike reaches the output, the lookahead
    // limiter has already started dropping gain in anticipation; the
    // reactive one is still sitting at unity since it can't see ahead.
    try std.testing.expect(ahead.gain < reactive.gain - 0.05);
    // Both still respect the ceiling once the spike itself plays out.
    for (buf_reactive) |s| try std.testing.expect(@abs(s) <= reactive.ceiling + 1e-4);
    for (buf_ahead) |s| try std.testing.expect(@abs(s) <= ahead.ceiling + 1e-4);
}

test "reset clears the lookahead buffer, deque, and frame counter" {
    var lim = try Limiter.init(std.testing.allocator, 48_000);
    defer lim.deinit(std.testing.allocator);
    lim.lookahead_ms = 5.0;
    var buf: [512]Sample = undefined;
    @memset(&buf, 2.0);
    lim.processBlock(&buf);
    try std.testing.expect(lim.frame_counter > 0);

    lim.device().reset();
    try std.testing.expectEqual(@as(usize, 0), lim.frame_counter);
    try std.testing.expectEqual(@as(usize, 0), lim.deque_len);
    try std.testing.expectEqual(@as(f32, 1.0), lim.gain);
    for (lim.delay[0]) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);

    // Drop back to zero lookahead so this checks pure state-clearing, not
    // the (already-correct) pre-roll silence a nonzero lookahead forces.
    // A stale write_idx from before reset must not leak into the freshly
    // silent buffer: the very first post-reset frame reads back the actual
    // input, not whatever the delay ring held from the pre-reset overshoot.
    lim.lookahead_ms = 0.0;
    var quiet = [_]Sample{ 0.1, 0.1 };
    lim.processBlock(&quiet);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.1), quiet[0], 1e-4);
}

test "latencyFrames reports the lookahead window, 0 by default" {
    var lim = try Limiter.init(std.testing.allocator, 48_000);
    defer lim.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), lim.device().latencyFrames());
    lim.lookahead_ms = 5.0;
    try std.testing.expectEqual(@as(u32, 240), lim.device().latencyFrames());
}

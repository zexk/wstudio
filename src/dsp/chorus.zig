//! Stereo chorus: a short LFO-modulated delay mixed against the dry signal.
//! One sine LFO, the right channel a quarter-cycle behind the left, sweeps
//! each channel's read tap ±depth_ms around a fixed 12ms base, the classic
//! detuned-double effect. Lines are allocated once at init (base + max depth
//! fits comfortably); linear-interpolated reads keep the sweep smooth.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

/// Centre of the modulated tap. Sits far enough out that the deepest sweep
/// (±max_depth_ms) never reaches the write head.
const base_delay_ms: f32 = 12.0;
/// Bound `depth_ms` is clamped to by the FX editor; the line is sized off it.
pub const max_depth_ms: f32 = 10.0;

pub const Chorus = struct {
    sample_rate: u32,
    lines: [2][]Sample,
    index: usize = 0,
    rate_hz: f32 = 0.8,
    depth_ms: f32 = 4.0,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 0.5,
    phase: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Chorus {
        const safe_rate = @max(sample_rate, 1);
        const line_ms = base_delay_ms + max_depth_ms + 2.0; // +2ms interp margin
        const frames: usize = @intFromFloat(line_ms * 0.001 * @as(f32, @floatFromInt(safe_rate)));
        const left = try allocator.alloc(Sample, @max(frames, 4));
        errdefer allocator.free(left);
        const right = try allocator.alloc(Sample, @max(frames, 4));
        @memset(left, 0.0);
        @memset(right, 0.0);
        return .{
            .sample_rate = safe_rate,
            .lines = .{ left, right },
        };
    }

    pub fn deinit(self: *Chorus, allocator: std.mem.Allocator) void {
        allocator.free(self.lines[0]);
        allocator.free(self.lines[1]);
    }

    pub fn reset(self: *Chorus) void {
        @memset(self.lines[0], 0.0);
        @memset(self.lines[1], 0.0);
        self.index = 0;
        self.phase = 0.0;
    }

    pub const device = dsp.deviceOf(@This());

    /// Chorus an interleaved stereo buffer in place.
    pub fn processBlock(self: *Chorus, buf: []Sample) void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const rate = dsp.sanitizeParam(self.rate_hz, 0.05, 5.0, 0.8);
        const depth = dsp.sanitizeParam(self.depth_ms, 0.0, max_depth_ms, 4.0);
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 0.5);
        if (!std.math.isFinite(self.phase)) self.phase = 0.0;
        const phase_inc = 2.0 * std.math.pi * rate / sr;
        const frames = buf.len / 2;
        for (0..frames) |i| {
            inline for (0..2) |ch| {
                const line = self.lines[ch];
                line[self.index] = buf[i * 2 + ch];

                // Right channel trails the LFO by a quarter cycle for width.
                const lfo = @sin(self.phase - @as(f32, @floatFromInt(ch)) * (std.math.pi / 2.0));
                const delay_frames = (base_delay_ms + depth * lfo) * 0.001 * sr;
                var pos = @as(f32, @floatFromInt(self.index)) - delay_frames;
                if (pos < 0) pos += @floatFromInt(line.len);
                const idx0: usize = @intFromFloat(pos);
                const frac = pos - @as(f32, @floatFromInt(idx0));
                const idx1 = (idx0 + 1) % line.len;
                const wet = line[idx0] * (1.0 - frac) + line[idx1] * frac;

                buf[i * 2 + ch] = buf[i * 2 + ch] * (1.0 - mix) + wet * mix;
            }
            self.index = (self.index + 1) % self.lines[0].len;
            self.phase += phase_inc;
            if (self.phase >= 2.0 * std.math.pi) self.phase -= 2.0 * std.math.pi;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

test "depth 0 reduces to a fixed 12ms tap" {
    var chorus = try Chorus.init(std.testing.allocator, 1000);
    defer chorus.deinit(std.testing.allocator);
    chorus.depth_ms = 0.0;
    chorus.mix = 0.5;

    // Impulse at frame 0 → dry half at 0, wet half at the 12-frame tap.
    var buf = [_]Sample{0.0} ** 64;
    buf[0] = 1.0;
    buf[1] = 1.0;
    chorus.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.5), buf[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.5), buf[12 * 2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.0), buf[6 * 2], 1e-4);
}

test "mix 0 passes the input untouched" {
    var chorus = try Chorus.init(std.testing.allocator, 48_000);
    defer chorus.deinit(std.testing.allocator);
    chorus.mix = 0.0;
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    const expected = buf;
    chorus.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "invalid parameters cannot poison output" {
    var chorus = try Chorus.init(std.testing.allocator, 48_000);
    defer chorus.deinit(std.testing.allocator);
    chorus.rate_hz = std.math.nan(f32);
    chorus.depth_ms = -std.math.inf(f32);
    chorus.mix = std.math.inf(f32);
    chorus.phase = std.math.nan(f32);
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    chorus.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

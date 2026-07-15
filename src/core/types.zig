//! Fundamental audio types and unit conversions.

const std = @import("std");

/// Internal processing format. All DSP runs on f32; conversion to the
/// device/file format happens only at the edges.
pub const Sample = f32;

/// A frame is one sample per channel at a single instant in time.
pub const FrameCount = u32;

pub const default_sample_rate: u32 = 48_000;
pub const default_block_frames: FrameCount = 256;

/// Upper bound a backend may ask the engine to process in one call.
/// Lets the engine use fixed scratch buffers - no allocation on the
/// audio thread.
pub const max_block_frames: FrameCount = 4096;

pub fn framesToSeconds(frames: u64, sample_rate: u32) f64 {
    return @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(@max(sample_rate, 1)));
}

pub fn secondsToFrames(seconds: f64, sample_rate: u32) u64 {
    if (std.math.isNan(seconds) or seconds <= 0.0 or sample_rate == 0) return 0;
    if (std.math.isPositiveInf(seconds)) return std.math.maxInt(u64);
    const frames = @round(seconds * @as(f64, @floatFromInt(sample_rate)));
    if (frames >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(frames);
}

/// Decibels to linear amplitude.
pub fn dbToGain(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

/// Linear amplitude to decibels. Clamps at -120 dB to avoid -inf.
pub fn gainToDb(gain: f32) f32 {
    if (gain <= 0.000001) return -120.0;
    return 20.0 * std.math.log10(gain);
}

test "frame/time conversion round-trips" {
    try std.testing.expectEqual(@as(u64, 48_000), secondsToFrames(1.0, 48_000));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), framesToSeconds(22_050, 44_100), 1e-9);
}

test "frame/time conversion handles invalid and overflowing inputs" {
    try std.testing.expectEqual(@as(f64, 48_000.0), framesToSeconds(48_000, 0));
    try std.testing.expectEqual(@as(u64, 0), secondsToFrames(-1.0, 48_000));
    try std.testing.expectEqual(@as(u64, 0), secondsToFrames(std.math.nan(f64), 48_000));
    try std.testing.expectEqual(@as(u64, 0), secondsToFrames(1.0, 0));
    try std.testing.expectEqual(std.math.maxInt(u64), secondsToFrames(std.math.inf(f64), 48_000));
    try std.testing.expectEqual(std.math.maxInt(u64), secondsToFrames(1.0e300, 48_000));
}

test "dB conversion" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dbToGain(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dbToGain(-6.0206), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -6.0206), gainToDb(0.5), 1e-3);
    try std.testing.expectEqual(@as(f32, -120.0), gainToDb(0.0));
}

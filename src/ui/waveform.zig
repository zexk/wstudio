//! Shared sample-to-overview downsampling for waveform panes - both the TUI
//! (character-grid bars) and GUI (pixel line plots) reduce a sample buffer
//! to one peak-amplitude value per display column before drawing it their
//! own way.

const std = @import("std");

/// Fill `out` with one peak (max |sample|) per bucket, splitting `samples`
/// into `out.len` equal-ish buckets.
pub fn peakBuckets(samples: []const f32, out: []f32) void {
    const width = out.len;
    if (width == 0) return;
    for (out, 0..) |*bucket, x| {
        const lo = x * samples.len / width;
        const hi = @max(lo + 1, (x + 1) * samples.len / width);
        var peak: f32 = 0;
        for (samples[lo..@min(hi, samples.len)]) |v| peak = @max(peak, @abs(v));
        bucket.* = peak;
    }
}

/// Playback time scale a pad's region gets: `pitch_semitones` speeds it up
/// (rate = 2^(semi/12)), `stretch_ratio` stretches it back out. 1.0 is the
/// source's own timing, >1 plays longer, <1 shorter - the same
/// `stretch_ratio / rate` duration factor dsp/pad.zig renders with.
pub fn timeScale(pitch_semitones: f32, stretch_ratio: f32) f32 {
    const rate = std.math.pow(f32, 2.0, pitch_semitones / 12.0);
    return stretch_ratio / @max(rate, 1e-6);
}

/// Where a warped region's playback ends on the source-time axis the pane is
/// drawn against: past `end_norm` when the pad is stretched or pitched down,
/// short of it when pitched up. Clamped to the pane.
pub fn playedEndNorm(start_norm: f32, end_norm: f32, scale: f32) f32 {
    return @min(1.0, start_norm + @max(0.0, end_norm - start_norm) * scale);
}

/// `peakBuckets` with the play region time-warped by `scale`. The pane keeps
/// its source-time x-axis - trim markers stay on the columns they trim, and
/// mouse hit-testing keeps mapping straight back to `start_norm`/`end_norm` -
/// but region columns read the source at `start + (x - start) / scale`, so a
/// stretched pad's waveform visibly spreads past its end marker and a
/// pitched-up one visibly finishes early. Columns past the played end come
/// out silent. `scale == 1` renders exactly like `peakBuckets`.
pub fn peakBucketsWarped(
    samples: []const f32,
    out: []f32,
    start_norm: f32,
    end_norm: f32,
    scale: f32,
) void {
    if (scale == 1.0 or out.len == 0 or samples.len == 0) return peakBuckets(samples, out);
    const width: f32 = @floatFromInt(out.len);
    const len_f: f32 = @floatFromInt(samples.len);
    const inv = 1.0 / @max(scale, 1e-6);
    for (out, 0..) |*bucket, x| {
        var lo_n = @as(f32, @floatFromInt(x)) / width;
        var hi_n = @as(f32, @floatFromInt(x + 1)) / width;
        if (hi_n > start_norm) {
            lo_n = start_norm + (@max(lo_n, start_norm) - start_norm) * inv;
            hi_n = start_norm + (hi_n - start_norm) * inv;
            if (lo_n >= end_norm) {
                bucket.* = 0;
                continue;
            }
            hi_n = @min(hi_n, end_norm);
        }
        var lo: usize = @intFromFloat(std.math.clamp(lo_n, 0.0, 1.0) * len_f);
        lo = @min(lo, samples.len - 1);
        var hi: usize = @intFromFloat(std.math.clamp(hi_n, 0.0, 1.0) * len_f);
        hi = @min(@max(hi, lo + 1), samples.len);
        var peak: f32 = 0;
        for (samples[lo..hi]) |v| peak = @max(peak, @abs(v));
        bucket.* = peak;
    }
}

test "peakBuckets finds the loudest sample per bucket" {
    var out: [4]f32 = undefined;
    peakBuckets(&.{ 0.1, -0.9, 0.2, 0.05, 0.3, -0.2, 0.0, 0.4 }, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), out[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), out[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), out[3], 1e-6);
}

test "peakBuckets handles more buckets than samples" {
    var out: [5]f32 = undefined;
    peakBuckets(&.{ 0.5, -0.5 }, &out);
    for (out) |bucket| try std.testing.expectApproxEqAbs(@as(f32, 0.5), bucket, 1e-6);
}

test "peakBuckets handles no samples" {
    var out: [3]f32 = undefined;
    peakBuckets(&.{}, &out);
    for (out) |bucket| try std.testing.expectEqual(@as(f32, 0), bucket);
}

test "timeScale ties pitch and stretch into one duration factor" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), timeScale(0, 1.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), timeScale(0, 2.0), 1e-6);
    // +1 octave halves the duration; matching stretch cancels it.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), timeScale(12, 1.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), timeScale(12, 2.0), 1e-5);
}

test "peakBucketsWarped spreads a stretched region and ends a compressed one early" {
    const samples = [_]f32{ 1, 1, 1, 1, 0, 0, 0, 0 };
    var out: [8]f32 = undefined;

    // Unwarped: the loud half is the left half.
    peakBucketsWarped(&samples, &out, 0, 1, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[6], 1e-6);

    // 2x stretch: the same audio now covers the whole pane.
    peakBucketsWarped(&samples, &out, 0, 1, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[6], 1e-6);

    // 0.5x: the region is done by the pane's midpoint.
    peakBucketsWarped(&samples, &out, 0, 1, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[7], 1e-6);
}

test "peakBucketsWarped leaves audio before the region start alone" {
    const samples = [_]f32{ 0.5, 0.5, 0.5, 0.5, 1, 1, 1, 1 };
    var out: [8]f32 = undefined;
    peakBucketsWarped(&samples, &out, 0.5, 1.0, 2.0);
    // Pre-region columns keep their source content...
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[3], 1e-6);
    // ...and the region's own content is stretched from the start marker on,
    // so the pane never runs out of it (playedEndNorm clamps at 1).
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[7], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), playedEndNorm(0.5, 1.0, 2.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), playedEndNorm(0.5, 1.0, 0.5), 1e-6);
}

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

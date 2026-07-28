//! Shared sample-to-overview downsampling for waveform panes - both the TUI
//! (character-grid bars) and GUI (pixel line plots) reduce a sample buffer
//! to one peak-amplitude value per display column before drawing it their
//! own way.

const std = @import("std");

/// Source-sample range display column `x` reads. `scale` warps the play
/// region the way `peakBucketsWarped` documents; null means the column is
/// past the played end and should render as silence. The one place the
/// column-to-sample mapping lives, so the peak pass and the band pass can
/// never disagree about which samples a column covers.
fn bucketRange(
    x: usize,
    width: usize,
    samples_len: usize,
    start_norm: f32,
    end_norm: f32,
    scale: f32,
) ?struct { lo: usize, hi: usize } {
    if (width == 0 or samples_len == 0) return null;
    if (scale == 1.0) {
        const lo = x * samples_len / width;
        const hi = @max(lo + 1, (x + 1) * samples_len / width);
        return .{ .lo = lo, .hi = @min(hi, samples_len) };
    }
    const width_f: f32 = @floatFromInt(width);
    const len_f: f32 = @floatFromInt(samples_len);
    const inv = 1.0 / @max(scale, 1e-6);
    var lo_n = @as(f32, @floatFromInt(x)) / width_f;
    var hi_n = @as(f32, @floatFromInt(x + 1)) / width_f;
    if (hi_n > start_norm) {
        lo_n = start_norm + (@max(lo_n, start_norm) - start_norm) * inv;
        hi_n = start_norm + (hi_n - start_norm) * inv;
        if (lo_n >= end_norm) return null;
        hi_n = @min(hi_n, end_norm);
    }
    var lo: usize = @intFromFloat(std.math.clamp(lo_n, 0.0, 1.0) * len_f);
    lo = @min(lo, samples_len - 1);
    var hi: usize = @intFromFloat(std.math.clamp(hi_n, 0.0, 1.0) * len_f);
    hi = @min(@max(hi, lo + 1), samples_len);
    return .{ .lo = lo, .hi = hi };
}

/// Fill `out` with one peak (max |sample|) per bucket, splitting `samples`
/// into `out.len` equal-ish buckets.
pub fn peakBuckets(samples: []const f32, out: []f32) void {
    peakBucketsWarped(samples, out, 0.0, 1.0, 1.0);
}

/// Rough frequency content of a column, for Serato-style waveform tinting.
pub const Band = enum { low, mid, high };

/// Band split points in Hz. Bass/body/air, the same three-way read a DJ
/// waveform gives at a glance. Set against the shipped kit rather than by
/// textbook octave boundaries: this centroid is an energy-weighted RMS
/// frequency, so any noise in a sound pulls it well above where a listener
/// would put it (kick.wav measures ~60 Hz, snare.wav ~8 kHz, hihat.wav
/// ~11 kHz). A 2 kHz top split would have painted nearly everything as air.
///
/// Module-level and mutable because `bandBuckets` is called straight from
/// both frontends' draw code, which has no App handle to thread a setting
/// through. `App.applyUserConfig` writes them from
/// `wstudio.o.waveform_low_hz`/`waveform_high_hz`; only the UI thread ever
/// touches either side.
pub var low_hz: f32 = 200.0;
pub var high_hz: f32 = 4000.0;

/// Fill `out` with each column's dominant frequency band, over exactly the
/// buckets `peakBucketsWarped` draws. The centroid comes from the mean
/// squared first difference over the mean square rather than an FFT: for a
/// sine at `f` that ratio is `(2 sin(pi f / sr))^2`, which inverts straight
/// back to `f` for one extra accumulator over samples the peak pass already
/// walks. Rough by construction (broadband content lands on its centre of
/// mass, which is the point), and a column with no energy reads `.mid` so a
/// silent stretch doesn't flash a colour.
pub fn bandBuckets(
    samples: []const f32,
    out: []Band,
    sample_rate: u32,
    start_norm: f32,
    end_norm: f32,
    scale: f32,
) void {
    const sr: f32 = @floatFromInt(@max(sample_rate, 1));
    for (out, 0..) |*bucket, x| {
        bucket.* = .mid;
        const r = bucketRange(x, out.len, samples.len, start_norm, end_norm, scale) orelse continue;
        var energy: f32 = 0;
        var diff: f32 = 0;
        var prev: f32 = samples[r.lo];
        for (samples[r.lo..r.hi]) |v| {
            energy += v * v;
            const d = v - prev;
            diff += d * d;
            prev = v;
        }
        if (energy <= 1e-12) continue;
        // asin's domain: heavy aliasing/noise can push the ratio past the
        // Nyquist-limit value of 4, which just means "as high as it gets".
        const ratio = @min(@sqrt(diff / energy) * 0.5, 1.0);
        const hz = sr / std.math.pi * std.math.asin(ratio);
        bucket.* = if (hz < low_hz) .low else if (hz < high_hz) .mid else .high;
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
    for (out, 0..) |*bucket, x| {
        bucket.* = 0;
        const r = bucketRange(x, out.len, samples.len, start_norm, end_norm, scale) orelse continue;
        var peak: f32 = 0;
        for (samples[r.lo..r.hi]) |v| peak = @max(peak, @abs(v));
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

test "bandBuckets separates a sub-bass rumble from a hissy top end" {
    const sr: u32 = 48_000;
    const len = sr / 2;
    const samples = try std.testing.allocator.alloc(f32, len);
    defer std.testing.allocator.free(samples);
    // First half 60 Hz, second half 8 kHz.
    for (samples, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr));
        const hz: f32 = if (i < len / 2) 60.0 else 8000.0;
        s.* = 0.5 * @sin(2.0 * std.math.pi * hz * t);
    }

    var bands: [8]Band = undefined;
    bandBuckets(samples, &bands, sr, 0, 1, 1.0);
    try std.testing.expectEqual(Band.low, bands[1]);
    try std.testing.expectEqual(Band.high, bands[6]);
}

test "bandBuckets reads silence as neutral rather than a colour" {
    const samples = [_]f32{0} ** 4096;
    var bands: [4]Band = undefined;
    bandBuckets(&samples, &bands, 48_000, 0, 1, 1.0);
    for (bands) |b| try std.testing.expectEqual(Band.mid, b);

    // Past a compressed region's played end, same neutral read.
    bandBuckets(&samples, &bands, 48_000, 0, 1, 0.25);
    for (bands) |b| try std.testing.expectEqual(Band.mid, b);
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

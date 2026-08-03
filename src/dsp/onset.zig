//! Spectral-flux onset strength, shared by the slicer's transient chopper
//! and the tempo detector. Control thread only: it walks a whole clip and is
//! called from commands, never from a render block.
//!
//! A broadband energy envelope only sees an onset that lifts the clip's
//! *total* level, so a hat over a sustained bass note, or any hit inside an
//! already-loud compressed bar, never registers. This differences the
//! log-magnitude spectrum instead (SuperFlux, Boeck & Widmer 2013), so a
//! frame scores when it adds energy *anywhere* in the spectrum, with a
//! three-bin maximum filter on the previous frame so vibrato and pitch
//! slides drift within their own neighbourhood and read as no attack.

const std = @import("std");
const fft_mod = @import("fft.zig");

/// 1024 samples at 200 fps: ~47 Hz per bin and a 5 ms grid, which is finer
/// than any boundary anyone can hear placed wrong, and still fine enough for
/// the tempo detector's shortest lag.
pub const frame: usize = 1024;
pub const fps: f32 = 200.0;

pub fn hopFor(sample_rate: u32) usize {
    return @max(@as(usize, @intFromFloat(@as(f32, @floatFromInt(sample_rate)) / fps)), 64);
}

/// Frames the envelope will have for a clip of `len` samples, or 0 when the
/// clip is too short to analyze at all.
pub fn frameCount(len: usize, sample_rate: u32) usize {
    if (len <= frame) return 0;
    return (len - frame) / hopFor(sample_rate) + 1;
}

/// Onset strength per frame. Caller owns the returned slice. Frame `t`
/// covers `[t*hop, t*hop + frame)` and, being Hann-weighted, reports on the
/// audio around its centre rather than its start.
pub fn envelope(alloc: std.mem.Allocator, samples: []const f32, sample_rate: u32) ![]f32 {
    const hop = hopFor(sample_rate);
    const frames = frameCount(samples.len, sample_rate);
    if (frames == 0) return error.ClipTooShort;
    const odf = try alloc.alloc(f32, frames);
    errdefer alloc.free(odf);

    const bins: usize = frame / 2;
    var re: [frame]f32 = undefined;
    var im: [frame]f32 = undefined;
    var cur: [bins]f32 = undefined;
    var prev = [_]f32{0} ** bins;

    for (0..frames) |t| {
        @memcpy(re[0..], samples[t * hop ..][0..frame]);
        @memset(im[0..], 0);
        fft_mod.hannWindow(re[0..]);
        fft_mod.fft(frame, re[0..], im[0..]);
        // Log magnitude, so a quiet hit in a quiet bar counts as much as a
        // loud one in a loud bar - the flux is about change, not level.
        for (0..bins) |b| cur[b] = @log(1.0 + fft_mod.magnitude(re[b], im[b]));

        var flux: f32 = 0;
        if (t > 0) {
            for (0..bins) |b| {
                const lo = if (b == 0) 0 else b - 1;
                const hi = @min(b + 2, bins);
                var m = prev[lo];
                for (prev[lo..hi]) |p| m = @max(m, p);
                flux += @max(0.0, cur[b] - m);
            }
        }
        odf[t] = flux;
        prev = cur;
    }
    return odf;
}

test "envelope spikes on attacks and stays flat through a held tone" {
    const sr: u32 = 48_000;
    const buf = try std.testing.allocator.alloc(f32, sr);
    defer std.testing.allocator.free(buf);
    // A held 220 Hz tone with one noise burst dropped in at the halfway mark.
    for (buf, 0..) |*x, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr));
        x.* = 0.5 * @sin(2.0 * std.math.pi * 220.0 * t);
    }
    var rng = std.Random.DefaultPrng.init(3);
    for (buf[sr / 2 ..][0 .. sr / 100]) |*x| x.* += (rng.random().float(f32) * 2.0 - 1.0) * 0.3;

    const env = try envelope(std.testing.allocator, buf, sr);
    defer std.testing.allocator.free(env);

    const hop = hopFor(sr);
    const burst_frame = (sr / 2) / hop;
    var quiet_peak: f32 = 0;
    for (env, 0..) |v, t| {
        // Frame 0 has no predecessor to difference against, and the frames
        // straddling the burst are the thing being measured.
        if (t == 0 or (t + 4 >= burst_frame and t <= burst_frame + 4)) continue;
        quiet_peak = @max(quiet_peak, v);
    }
    var burst_peak: f32 = 0;
    for (env[burst_frame -| 2..][0..5]) |v| burst_peak = @max(burst_peak, v);
    try std.testing.expect(burst_peak > quiet_peak * 10.0);
}

test "envelope declines a clip shorter than one frame" {
    var buf: [512]f32 = undefined;
    @memset(&buf, 0.0);
    try std.testing.expectError(error.ClipTooShort, envelope(std.testing.allocator, &buf, 48_000));
}

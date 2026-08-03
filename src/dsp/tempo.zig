//! Tempo estimation for a loaded clip - the analysis half of Serato-style
//! "BPM sync", where a loop is stretched to the project tempo instead of
//! being nudged into place by ear. Autocorrelates an onset-strength envelope
//! (10 ms RMS hops, differenced so a steady tone contributes nothing) and
//! reads the strongest periodicity in the musically plausible lag range. A
//! broadband envelope is enough here where `slicer.detectOnsets` needs
//! spectral flux: autocorrelation only wants the pulse to be periodic, not
//! every hit of it to be found.
//!
//! Control thread only: it walks the whole clip and is called from commands,
//! never from a render block.

const std = @import("std");

pub const Result = struct {
    bpm: f32,
    /// Peak autocorrelation score relative to the mean over the searched lag
    /// range. 1.0 means "no peak at all"; the detector rejects anything below
    /// `min_confidence` rather than reporting a tempo it made up.
    confidence: f32,
};

/// Below this the peak isn't distinguishable from the surrounding lags -
/// sustained pads, single hits, noise. Tuned so a clip with an audible pulse
/// clears it and unpitched/arrhythmic material doesn't.
const min_confidence: f32 = 1.25;

/// Tempo range searched before folding. Wide, because the fold below pulls
/// half/double-time results back into the range people actually name.
const bpm_min: f32 = 60.0;
const bpm_max: f32 = 200.0;

/// Where a folded tempo is allowed to land. A drum loop detected at 174 and
/// one detected at 87 are the same loop; picking a single home range keeps
/// the stretch ratio the command derives from it sane.
const fold_min: f32 = 70.0;
const fold_max: f32 = 140.0;

/// Estimate `samples`' tempo, or null when there is no clear pulse. Needs a
/// couple of seconds of audio: below that the autocorrelation has too few
/// periods to average over and the answer is a coin flip, so it declines
/// rather than guessing.
pub fn detect(samples: []const f32, sample_rate: u32) ?Result {
    const hop: usize = @max(sample_rate / 100, 32);
    const hops = samples.len / hop;
    const hop_s: f32 = @as(f32, @floatFromInt(hop)) / @as(f32, @floatFromInt(@max(sample_rate, 1)));

    const lag_max: usize = @intFromFloat(@round(60.0 / bpm_min / hop_s));
    const lag_min: usize = @intFromFloat(@round(60.0 / bpm_max / hop_s));
    if (lag_min == 0 or lag_max <= lag_min) return null;
    // Two full cycles at the slowest tempo, so even the longest lag has real
    // overlap to correlate over.
    if (hops < lag_max * 2) return null;

    var flux = std.heap.stackFallback(4096 * @sizeOf(f32), std.heap.page_allocator);
    const alloc = flux.get();
    const env = alloc.alloc(f32, hops) catch return null;
    defer alloc.free(env);

    // Onset strength: half-wave-rectified RMS difference. A held note has a
    // flat envelope and contributes nothing; every attack shows as a spike.
    var prev: f32 = 0;
    var mean: f32 = 0;
    var peak_rms: f32 = 0;
    var quiet_rms: f32 = std.math.floatMax(f32);
    var peak_flux: f32 = 0;
    for (env, 0..) |*e, h| {
        var acc: f32 = 0;
        for (samples[h * hop ..][0..hop]) |x| acc += x * x;
        const rms = @sqrt(acc / @as(f32, @floatFromInt(hop)));
        e.* = @max(0.0, rms - prev);
        prev = rms;
        mean += e.*;
        peak_rms = @max(peak_rms, rms);
        quiet_rms = @min(quiet_rms, rms);
        if (h > 0) peak_flux = @max(peak_flux, e.*);
    }
    mean /= @floatFromInt(hops);
    if (mean <= 1e-9) return null;
    // A sustained tone still ripples a little, because a 10 ms hop rarely
    // holds a whole number of periods - and the confidence ratio below is
    // scale-invariant, so that ripple autocorrelates into a confident piece
    // of nonsense. Two cheap gates, each catching a different way to have no
    // beat: at least one attack worth a real fraction of the clip's own peak
    // level, and an envelope that actually goes quiet between hits. A clip
    // that never drops below half its peak has no rhythm to track by energy,
    // whatever the correlation says - `:bpm-sync <n>` is the answer there.
    if (peak_flux < peak_rms * 0.05) return null;
    if (quiet_rms > peak_rms * 0.5) return null;
    // Mean-removed, so a lag's score measures periodicity rather than the
    // clip's overall loudness (which correlates with everything).
    for (env) |*e| e.* -= mean;

    var best_lag: usize = 0;
    var best: f32 = -std.math.floatMax(f32);
    var total: f32 = 0;
    var lag = lag_min;
    while (lag <= lag_max) : (lag += 1) {
        var dot: f32 = 0;
        for (env[0 .. hops - lag], env[lag..]) |a, b| dot += a * b;
        // Divide by the overlap so a long lag isn't penalized for comparing
        // fewer frames than a short one.
        const score = dot / @as(f32, @floatFromInt(hops - lag));
        total += score;
        if (score > best) {
            best = score;
            best_lag = lag;
        }
    }
    if (best_lag == 0 or best <= 0.0) return null;

    const avg = total / @as(f32, @floatFromInt(lag_max - lag_min + 1));
    if (!(avg > 0.0)) return null;
    const confidence = best / avg;
    if (confidence < min_confidence) return null;

    var bpm = 60.0 / (@as(f32, @floatFromInt(best_lag)) * hop_s);
    while (bpm > fold_max) bpm /= 2.0;
    while (bpm < fold_min) bpm *= 2.0;
    return .{ .bpm = bpm, .confidence = confidence };
}

/// Playback duration multiplier (`dsp.Pad.stretch_ratio`) that makes a clip
/// running at `clip_bpm` line up with `project_bpm`. A clip faster than the
/// project has to play *longer*, so the ratio is clip over project. Clamped
/// to the pad's own stretch range; the caller reports the clamp.
pub fn stretchToTempo(clip_bpm: f32, project_bpm: f32) f32 {
    if (!(clip_bpm > 0.0) or !(project_bpm > 0.0)) return 1.0;
    return std.math.clamp(clip_bpm / project_bpm, 0.25, 4.0);
}

test "detect finds the pulse of a steady click track and folds it home" {
    const sr: u32 = 48_000;
    const bpm: f32 = 120.0;
    const samples = try std.testing.allocator.alloc(f32, sr * 8);
    defer std.testing.allocator.free(samples);
    @memset(samples, 0.0);

    // A click every beat: 5 ms of decaying noise-free tone.
    const period: usize = @intFromFloat(@as(f32, @floatFromInt(sr)) * 60.0 / bpm);
    var at: usize = 0;
    while (at + 240 < samples.len) : (at += period) {
        for (samples[at..][0..240], 0..) |*s, i| {
            const t: f32 = @floatFromInt(i);
            s.* = @exp(-t / 60.0) * @sin(t * 0.4);
        }
    }

    const r = detect(samples, sr) orelse return error.NoTempoDetected;
    try std.testing.expectApproxEqAbs(bpm, r.bpm, 3.0);
}

test "detect declines on material with no pulse" {
    const sr: u32 = 48_000;
    const samples = try std.testing.allocator.alloc(f32, sr * 8);
    defer std.testing.allocator.free(samples);

    // A held tone: flat envelope, so the onset-strength signal is ~nothing.
    for (samples, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr));
        s.* = 0.4 * @sin(2.0 * std.math.pi * 220.0 * t);
    }
    try std.testing.expectEqual(@as(?Result, null), detect(samples, sr));

    // Too short to average over.
    try std.testing.expectEqual(@as(?Result, null), detect(samples[0 .. sr / 2], sr));
}

test "stretchToTempo slows a fast loop down and clamps the extremes" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), stretchToTempo(174.0, 87.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), stretchToTempo(60.0, 120.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stretchToTempo(120.0, 120.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), stretchToTempo(400.0, 20.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stretchToTempo(0.0, 120.0), 1e-6);
}

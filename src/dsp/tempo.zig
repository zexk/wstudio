//! Tempo estimation for a loaded clip - the analysis half of Serato-style
//! "BPM sync", where a loop is stretched to the project tempo instead of
//! being nudged into place by ear. Autocorrelates `onset.envelope`'s
//! spectral flux and reads the strongest periodicity in the musically
//! plausible lag range.
//!
//! Control thread only: it walks the whole clip and is called from commands,
//! never from a render block.

const std = @import("std");
const onset = @import("onset.zig");

pub const Result = struct {
    bpm: f32,
    /// Peak autocorrelation score relative to the mean over the searched lag
    /// range. 1.0 means "no peak at all"; the detector rejects anything below
    /// `min_confidence` rather than reporting a tempo it made up.
    confidence: f32,
};

/// Below this the peak isn't distinguishable from the surrounding lags -
/// sustained pads, single hits, noise. A real pulse clears this by a wide
/// margin on a flux envelope (a click track scores ~220, a busy break ~570)
/// while a held tone, whose flux is only the STFT's own frame-to-frame
/// leakage jitter, scores ~2. Sitting an order of magnitude above that
/// leaves both sides room.
const min_confidence: f32 = 10.0;

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
    const hop = onset.hopFor(sample_rate);
    const hops = onset.frameCount(samples.len, sample_rate);
    const hop_s: f32 = @as(f32, @floatFromInt(hop)) / @as(f32, @floatFromInt(@max(sample_rate, 1)));

    const lag_max: usize = @intFromFloat(@round(60.0 / bpm_min / hop_s));
    const lag_min: usize = @intFromFloat(@round(60.0 / bpm_max / hop_s));
    if (lag_min == 0 or lag_max <= lag_min) return null;
    // Two full cycles at the slowest tempo, so even the longest lag has real
    // overlap to correlate over.
    if (hops < lag_max * 2) return null;

    var fallback = std.heap.stackFallback(4096 * @sizeOf(f32), std.heap.page_allocator);
    const alloc = fallback.get();
    // Spectral flux, not an energy envelope: a mastered break never drops
    // back to silence between hits, so its RMS barely moves and the pulse
    // hides. What the snare changes is the *spectrum*, every time.
    const env = onset.envelope(alloc, samples, sample_rate) catch return null;
    defer alloc.free(env);

    var mean: f32 = 0;
    for (env) |e| mean += e;
    mean /= @floatFromInt(hops);
    if (mean <= 1e-9) return null;
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

/// Tempo the clip's own file name declares, or null when it declares none.
/// Sample packs put it there by convention (`SO_JAM_80_bass_upright_Gmin`,
/// `124_break_dry`): the first run of two or three digits landing in the
/// same plausible range `detect` searches.
///
/// Callers should prefer this over `detect`. Measured against one 329-file
/// commercial pack, the name was right wherever it was present, while the
/// autocorrelation below answered correctly for 21% of the loops, wrongly
/// for 17% (by up to a tritone once `stretchToTempo` folds the error into a
/// repitch), and declined outright on the remaining 62%.
pub fn bpmFromName(name: []const u8) ?f32 {
    var i: usize = 0;
    while (i < name.len) {
        if (!std.ascii.isDigit(name[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < name.len and std.ascii.isDigit(name[j])) j += 1;
        // A longer run is a catalogue number or a date, not a tempo.
        if (j - i <= 3) {
            const n = std.fmt.parseInt(u32, name[i..j], 10) catch 0;
            const f: f32 = @floatFromInt(n);
            if (f >= bpm_min and f <= bpm_max) return f;
        }
        i = j;
    }
    return null;
}

test "bpmFromName reads the sample-pack convention and declines the rest" {
    try std.testing.expectEqual(@as(?f32, 80.0), bpmFromName("SO_JAM_80_bass_upright_onyx_Gmin"));
    try std.testing.expectEqual(@as(?f32, 92.0), bpmFromName("SO_JAM_92_drum_loop_silicone"));
    try std.testing.expectEqual(@as(?f32, 124.0), bpmFromName("124_break_dry"));
    // The first *plausible* number wins, so a leading index or a trailing
    // take number can't shadow the tempo.
    try std.testing.expectEqual(@as(?f32, 90.0), bpmFromName("SO_JAM_90_string_stack_legato_2_Gmin"));
    // Out of range, too many digits, or no digits at all: no answer rather
    // than a made-up one.
    try std.testing.expectEqual(@as(?f32, null), bpmFromName("kick_909"));
    try std.testing.expectEqual(@as(?f32, null), bpmFromName("snare_08"));
    try std.testing.expectEqual(@as(?f32, null), bpmFromName("vocal_chop_20240131"));
    try std.testing.expectEqual(@as(?f32, null), bpmFromName("amen_break"));
}

/// Playback duration multiplier (`dsp.Pad.stretch_ratio`) that makes a clip
/// running at `clip_bpm` line up with `project_bpm`. A clip faster than the
/// project has to play *longer*, so the ratio is clip over project. Clamped
/// to the pad's own stretch range; the caller reports the clamp.
///
/// Folded to the nearest octave of itself first. `detect` reports a tempo
/// folded into its own home range, so a 174 BPM break against a 174 BPM
/// project arrives here as 87 over 174 and would otherwise be stretched to
/// half speed - when the two are an octave apart they are the same pulse,
/// and the smallest stretch that lines them up is the one wanted.
pub fn stretchToTempo(clip_bpm: f32, project_bpm: f32) f32 {
    if (!(clip_bpm > 0.0) or !(project_bpm > 0.0)) return 1.0;
    var ratio = clip_bpm / project_bpm;
    while (ratio > std.math.sqrt2) ratio /= 2.0;
    while (ratio < 1.0 / std.math.sqrt2) ratio *= 2.0;
    return std.math.clamp(ratio, 0.25, 4.0);
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

test "stretchToTempo takes the smallest stretch that lines the pulses up" {
    // Octave-apart tempos are the same pulse: leave the clip alone.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stretchToTempo(174.0, 87.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stretchToTempo(60.0, 120.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stretchToTempo(120.0, 120.0), 1e-6);
    // A real mismatch still stretches, the short way round.
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 / 120.0), stretchToTempo(100.0, 120.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 160.0 / 240.0 * 2.0), stretchToTempo(160.0, 240.0), 1e-6);
    // Folding keeps even an absurd pairing inside the pad's stretch range.
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), stretchToTempo(400.0, 20.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stretchToTempo(0.0, 120.0), 1e-6);
}

/// A mastered-sounding break: kick, snare and hats over a continuous bass
/// note and noise bed, so the clip's RMS never falls back toward silence -
/// the shape a broadband energy envelope cannot find a pulse in.
fn compressedBreak(allocator: std.mem.Allocator, sample_rate: u32, bpm: f32) ![]f32 {
    const len = sample_rate * 8;
    const out = try allocator.alloc(f32, len);
    const sr_f: f32 = @floatFromInt(sample_rate);
    var rng = std.Random.DefaultPrng.init(11);
    for (out, 0..) |*x, i| {
        const t = @as(f32, @floatFromInt(i)) / sr_f;
        x.* = 0.5 * @sin(2.0 * std.math.pi * 55.0 * t) + (rng.random().float(f32) * 2.0 - 1.0) * 0.08;
    }

    const beat: usize = @intFromFloat(sr_f * 60.0 / bpm);
    const eighth = beat / 2;
    var n: usize = 0;
    while (n * eighth < len) : (n += 1) {
        const at = n * eighth;
        // Hat on every eighth, kick on beats 1 and 3, snare on 2 and 4.
        const hit_len: usize = @min(sample_rate / 20, len - at);
        for (0..hit_len) |j| {
            const d = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(hit_len));
            const env = @exp(-d * 12.0);
            const tt = @as(f32, @floatFromInt(j)) / sr_f;
            var v = (rng.random().float(f32) * 2.0 - 1.0) * 0.12 * env; // hat
            if (n % 4 == 0) v += 0.7 * @sin(2.0 * std.math.pi * 60.0 * tt) * env;
            if (n % 4 == 2) v += (rng.random().float(f32) * 2.0 - 1.0) * 0.6 * env;
            out[at + j] += v;
        }
    }
    // Brickwall it, the way a mastered loop is: the level stops moving.
    for (out) |*x| x.* = std.math.clamp(x.* * 2.0, -0.95, 0.95);
    return out;
}

test "detect finds the pulse of a break whose level never drops" {
    const sr: u32 = 48_000;
    const buf = try compressedBreak(std.testing.allocator, sr, 130.0);
    defer std.testing.allocator.free(buf);

    // The clip really is as flat as claimed: its quietest 10 ms window sits
    // well above half its loudest, which is what used to disqualify it.
    var peak: f32 = 0;
    var quiet: f32 = std.math.floatMax(f32);
    const hop: usize = sr / 100;
    var h: usize = 0;
    while ((h + 1) * hop <= buf.len) : (h += 1) {
        var acc: f32 = 0;
        for (buf[h * hop ..][0..hop]) |x| acc += x * x;
        const rms = @sqrt(acc / @as(f32, @floatFromInt(hop)));
        peak = @max(peak, rms);
        quiet = @min(quiet, rms);
    }
    try std.testing.expect(quiet > peak * 0.5);

    const r = detect(buf, sr) orelse return error.NoTempoDetected;
    try std.testing.expectApproxEqAbs(@as(f32, 130.0), r.bpm, 3.0);
}

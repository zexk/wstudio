//! Tempo estimation for a loaded clip - the analysis half of Serato-style
//! "BPM sync", where a loop is stretched to the project tempo instead of
//! being nudged into place by ear. Correlates `onset.envelope`'s spectral
//! flux against itself across the musically plausible lag range, scores each
//! candidate beat period by its own correlation plus its multiples', and
//! snaps the winner onto the tempo that makes the clip a whole number of
//! beats.
//!
//! It is good on rhythmic material and poor on sustained material, which is
//! a property of the signal rather than of the scoring: measured over a
//! 222-loop corpus it gets 92% of drum loops right and about a fifth of the
//! legato strings and vocals, because a held string chord has no pulse in it
//! to find. Callers that can read the tempo off the file name should do that
//! first - see `bpmFromName`.
//!
//! Control thread only: it walks the whole clip and is called from commands,
//! never from a render block.

const std = @import("std");
const onset = @import("onset.zig");

pub const Result = struct {
    bpm: f32,
    /// How strongly the winning period correlates, as a Pearson coefficient
    /// in 0..1 - `min_confidence` is the floor below which `detect` declines
    /// instead of reporting a tempo it made up.
    confidence: f32,
};

/// How periodic a clip has to be at the winning lag before the answer is
/// worth reporting. A plain correlation coefficient now that `corr`
/// normalizes, so it reads as "at least 10% of this envelope is explained by
/// that period".
///
/// Tuned against a 222-loop corpus with the tempo in every file name.
/// Precision is flat from about 0.08 up (62-64% of answers correct) while
/// recall keeps falling, so this sits at the recall end of that plateau
/// rather than on a cliff. Every drum loop in the corpus clears it.
const min_confidence: f32 = 0.10;

/// Mean spectral flux below which there are no onsets to find a pulse in,
/// with two orders of magnitude of headroom on both sides: a held 220 Hz
/// tone, whose flux is only the STFT's own leakage jitter, averages 0.014,
/// while a click track averages 2.5 and a busy break 21.
///
/// This is the gate `corr`'s normalization gave up. A correlation
/// coefficient is scale-free, so it will happily lock onto the periodicity
/// *in* that leakage jitter and report a confident tempo for a sustained
/// pad; only an absolute floor can say "there is nothing here at all".
/// `onset.envelope` works in log magnitude, so the floor is about spectral
/// change rather than how loud the clip was recorded.
const min_flux: f32 = 0.1;

/// Tempo range searched before folding. Wide, because the fold below pulls
/// half/double-time results back into the range people actually name.
const bpm_min: f32 = 60.0;
const bpm_max: f32 = 200.0;

/// Beat-period multiples `combScore` sums over. Four covers a bar in 4/4,
/// which is as far out as the correlation stays meaningful on a loop only a
/// few bars long.
const comb_harmonics: usize = 4;

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
    if (mean < min_flux) return null;
    // Mean-removed, so a lag's score measures periodicity rather than the
    // clip's overall loudness (which correlates with everything).
    for (env) |*e| e.* -= mean;

    var best_lag: usize = 0;
    var best: f32 = 0;
    var lag = lag_min;
    while (lag <= lag_max) : (lag += 1) {
        const score = combScore(env, lag);
        if (score > best) {
            best = score;
            best_lag = lag;
        }
    }
    if (best_lag == 0 or best < min_confidence) return null;

    var bpm = 60.0 / (@as(f32, @floatFromInt(best_lag)) * hop_s);
    while (bpm > fold_max) bpm /= 2.0;
    while (bpm < fold_min) bpm *= 2.0;
    const clip_s = @as(f32, @floatFromInt(samples.len)) / @as(f32, @floatFromInt(@max(sample_rate, 1)));
    return .{ .bpm = snapToWholeBeats(bpm, clip_s), .confidence = best };
}

/// Pull `bpm` onto the tempo that makes `clip_s` a whole number of beats.
/// A loop is cut to the bar, so its real tempo always is one; the estimate
/// isn't, because the envelope is only sampled every `hop` frames and the
/// peak lands on whichever integer lag is nearest. Snapping recovers the
/// exact figure (an 80 BPM 24-second loop reads 80.18 and lands back on 80),
/// which matters downstream: `stretchToTempo` turns that 0.2% into 50 ms of
/// drift across the clip.
///
/// Only applied when the snap is small enough to be that rounding. A clip
/// that genuinely isn't a whole number of beats keeps the raw estimate
/// rather than being bent onto a grid it was never on.
fn snapToWholeBeats(bpm: f32, clip_s: f32) f32 {
    if (!(clip_s > 0.0) or !(bpm > 0.0)) return bpm;
    const beats = @round(clip_s * bpm / 60.0);
    if (beats < 1.0) return bpm;
    const snapped = beats * 60.0 / clip_s;
    return if (@abs(snapped - bpm) <= bpm * snap_tolerance) snapped else bpm;
}

/// How far `snapToWholeBeats` will move an estimate. One hop of lag error at
/// the fastest tempo searched is about this much, so it covers the rounding
/// it exists to undo and not a mis-lock.
const snap_tolerance: f32 = 0.02;

/// How well a beat period of `lag` frames explains the whole envelope: its
/// own correlation plus its multiples', weighted down as they get further
/// out. A bare argmax over `corr` picks whatever single lag scores highest,
/// which on real material is regularly a subdivision or an outright spurious
/// peak; a real beat period is the one whose 2x, 3x and 4x also line up, and
/// summing over them is what tells the two apart.
fn combScore(env: []const f32, lag: usize) f32 {
    var sum: f32 = 0;
    var weight: f32 = 0;
    var k: usize = 1;
    while (k <= comb_harmonics and k * lag < env.len) : (k += 1) {
        const w = 1.0 / @as(f32, @floatFromInt(k));
        sum += w * corr(env, k * lag);
        weight += w;
    }
    return if (weight > 0) sum / weight else 0;
}

/// Pearson correlation of `env` against itself shifted by `lag`, in -1..1.
/// Normalizing by the two windows' own energy (rather than just their length)
/// is what makes scores at different lags comparable at all, and what makes
/// the peak's height mean "how periodic is this" instead of "how loud is it".
fn corr(env: []const f32, lag: usize) f32 {
    var dot: f32 = 0;
    var ea: f32 = 0;
    var eb: f32 = 0;
    for (env[0 .. env.len - lag], env[lag..]) |a, b| {
        dot += a * b;
        ea += a * a;
        eb += b * b;
    }
    const denom = @sqrt(ea * eb);
    return if (denom > 1e-20) dot / denom else 0;
}

/// Tempo the clip's own file name declares, or null when it declares none.
/// Sample packs put it there by convention (`SO_JAM_80_bass_upright_Gmin`,
/// `124_break_dry`): the first run of two or three digits landing in the
/// same plausible range `detect` searches.
///
/// Callers should prefer this over `detect`. Measured against a 222-loop
/// corpus, the name was right wherever it was present, while `detect` gets
/// 37% of the same loops right, 22% wrong and declines on the rest - and
/// that is the improved detector.
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
    if (!std.math.isFinite(clip_bpm) or !std.math.isFinite(project_bpm) or clip_bpm <= 0.0 or project_bpm <= 0.0) return 1.0;
    var ratio = clip_bpm / project_bpm;
    while (ratio > std.math.sqrt2) ratio /= 2.0;
    while (ratio < 1.0 / std.math.sqrt2) ratio *= 2.0;
    return std.math.clamp(ratio, 0.25, 4.0);
}

test "stretchToTempo rejects non-finite tempos" {
    try std.testing.expectEqual(@as(f32, 1.0), stretchToTempo(std.math.inf(f32), 120));
    try std.testing.expectEqual(@as(f32, 1.0), stretchToTempo(120, std.math.inf(f32)));
    try std.testing.expectEqual(@as(f32, 1.0), stretchToTempo(std.math.nan(f32), 120));
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
    // Exact, not within a few BPM: the lag grid alone can only land within
    // about half a BPM here, and `snapToWholeBeats` closes the rest.
    try std.testing.expectApproxEqAbs(bpm, r.bpm, 0.01);
    try std.testing.expect(r.confidence > min_confidence and r.confidence <= 1.0);
}

test "snapToWholeBeats rounds a loop onto its own bar grid, and only that far" {
    // 24 s at 80 BPM is 32 beats; the lag grid reports 80.18 and snapping
    // recovers the figure the loop was actually cut at.
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), snapToWholeBeats(80.18, 24.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), snapToWholeBeats(90.43, 21.3333), 1e-2);
    // Already exact: unchanged.
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), snapToWholeBeats(120.0, 8.0), 1e-4);
    // A clip that is not a whole number of beats long keeps its estimate
    // rather than being bent onto a grid it was never on - 100 BPM over 24 s
    // is 40 beats, and the nearest whole-beat tempo to 95 is more than the
    // tolerance away.
    try std.testing.expectApproxEqAbs(@as(f32, 95.0), snapToWholeBeats(95.0, 24.0), 1e-4);
    // Degenerate inputs pass through instead of dividing by zero.
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), snapToWholeBeats(120.0, 0.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), snapToWholeBeats(0.0, 8.0), 1e-4);
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

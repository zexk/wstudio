//! Single-shot fundamental-frequency estimation for melodic sample loads -
//! control-thread only, not part of the audio-thread render path. Used by
//! `Sampler.detectRootNote` to guess a newly loaded clip's root note instead
//! of leaving it at whatever the pad's previous clip was tuned to.
//!
//! Implements YIN (de Cheveigne & Kawahara 2002): a cumulative-mean-normalized
//! difference function that's far less prone to octave errors than raw
//! autocorrelation, at a similar cost. Percussive/noisy material (drum hits,
//! most one-shots) has no single dominant period, so `detect` returns null
//! rather than stamping a bogus note on it.
//!
//! YIN is run over several windows spread across the clip and the results are
//! taken as a median, rather than trusting one window near the head. A single
//! window is one coin flip: land it on a noisy attack, a vibrato peak or the
//! one bar where the bassline moves and the whole sample gets the wrong root.
//! pYIN (Mauch & Dixon 2014) tracks a contour through an HMM for the same
//! reason, but a median is what the ensemble literature finds hard to beat
//! for a single answer, and an octave error in one window cannot move it.

const std = @import("std");

pub const Result = struct {
    /// Nearest MIDI note to the detected pitch.
    note: u7,
    /// Deviation from `note`, in cents (-50..50).
    cents: f32,
};

const min_freq: f32 = 32.70; // C1
const max_freq: f32 = 2093.0; // C7 - covers virtually every melodic sample;
// widening it just admits more octave errors from inharmonic content.
const yin_threshold: f32 = 0.15; // standard YIN absolute threshold
const no_dip_cutoff: f32 = 0.4; // fallback global-min acceptance ceiling
const max_tau: usize = 4096; // covers sr/min_freq up to ~134kHz
/// Two periods of the lowest note the detector will report is all YIN needs;
/// past that the extra samples only cost time. Bounds worst-case cost
/// regardless of clip length.
const max_window: usize = 4096;
/// Spread across the clip. More is steadier but the cost is linear in this,
/// and past a handful the median stops moving.
const max_windows: usize = 8;
/// A window whose estimate lands further than this from the median is an
/// outlier, not a vote. Half a semitone: wide enough for vibrato, narrow
/// enough that an octave error never counts as agreement.
const agree_semitones: f32 = 0.5;

/// Estimate the fundamental of `samples` (mono, `sample_rate` Hz). Returns
/// null when the clip is too short or has no clear single pitch.
pub fn detect(samples: []const f32, sample_rate: u32) ?Result {
    const sr_f: f32 = @floatFromInt(sample_rate);
    const tau_min_f = sr_f / max_freq;
    if (tau_min_f < 1.0) return null;
    const tau_min: usize = @intFromFloat(@floor(tau_min_f));
    const tau_max: usize = @min(max_tau, @as(usize, @intFromFloat(@ceil(sr_f / min_freq))));
    if (tau_max <= tau_min + 2) return null;

    // Skip the attack transient: its broadband noise skews the estimate.
    const skip: usize = @min(samples.len, sample_rate / 50); // ~20ms
    const buf = samples[skip..];
    const w: usize = @min(buf.len -| tau_max, max_window);
    if (w < tau_max or w < 256) return null; // not enough audio to judge confidently

    // Windows evenly spread over whatever the clip has room for. A short
    // clip gets one, at the head, exactly as before.
    const span = w + tau_max;
    const n = @min(max_windows, 1 + (buf.len - span) / span);
    const stride = if (n > 1) (buf.len - span) / (n - 1) else 0;

    var votes: [max_windows]f32 = undefined;
    var voted: usize = 0;
    for (0..n) |i| {
        if (analyzeWindow(buf[i * stride ..][0..span], tau_min, tau_max, sr_f)) |midi_f| {
            votes[voted] = midi_f;
            voted += 1;
        }
    }
    if (voted == 0) return null;

    std.mem.sort(f32, votes[0..voted], {}, std.sort.asc(f32));
    const midi_f = votes[voted / 2];
    // A window that disagrees with the median is not evidence of anything.
    // Percussive material scatters its estimates all over, so require the
    // votes to actually cluster rather than just taking whatever is central.
    var agreeing: usize = 0;
    for (votes[0..voted]) |v| {
        if (@abs(v - midi_f) <= agree_semitones) agreeing += 1;
    }
    if (agreeing * 2 <= voted) return null;

    const note_round = @round(midi_f);
    const note: u7 = @intFromFloat(std.math.clamp(note_round, 0.0, 127.0));
    return .{ .note = note, .cents = (midi_f - note_round) * 100.0 };
}

/// YIN over one window. Returns the fundamental as a fractional MIDI note,
/// or null when the window has no clear single pitch.
fn analyzeWindow(buf: []const f32, tau_min: usize, tau_max: usize, sr_f: f32) ?f32 {
    const w = buf.len - tau_max;

    var d: [max_tau + 1]f32 = undefined;
    d[0] = 1.0;

    var running_sum: f32 = 0.0;
    var tau: usize = 1;
    while (tau <= tau_max) : (tau += 1) {
        var sum: f32 = 0.0;
        var j: usize = 0;
        while (j < w) : (j += 1) {
            const delta = buf[j] - buf[j + tau];
            sum += delta * delta;
        }
        running_sum += sum;
        d[tau] = if (running_sum > 0.0) sum * @as(f32, @floatFromInt(tau)) / running_sum else 1.0;
    }

    // Absolute threshold: the first local minimum under `yin_threshold` at
    // or past tau_min. Searching for a dip rather than the global minimum
    // is what keeps YIN from picking a spurious harmonic.
    var best_tau: usize = 0;
    tau = tau_min;
    while (tau <= tau_max) : (tau += 1) {
        if (d[tau] < yin_threshold) {
            var t = tau;
            while (t + 1 <= tau_max and d[t + 1] < d[t]) : (t += 1) {}
            best_tau = t;
            break;
        }
    }
    if (best_tau == 0) {
        // No confident dip anywhere: fall back to the global minimum, but
        // only accept it if it's still reasonably clean - avoids stamping a
        // random octave on percussive/noisy material.
        var min_val: f32 = d[tau_min];
        var min_tau: usize = tau_min;
        tau = tau_min + 1;
        while (tau <= tau_max) : (tau += 1) {
            if (d[tau] < min_val) {
                min_val = d[tau];
                min_tau = tau;
            }
        }
        if (min_val > no_dip_cutoff) return null;
        best_tau = min_tau;
    }

    // Parabolic interpolation around best_tau for sub-sample precision.
    var interp_tau: f32 = @floatFromInt(best_tau);
    if (best_tau > tau_min and best_tau < tau_max) {
        const s0 = d[best_tau - 1];
        const s1 = d[best_tau];
        const s2 = d[best_tau + 1];
        const denom = 2.0 * (s0 - 2.0 * s1 + s2);
        if (@abs(denom) > 1e-9) interp_tau += (s0 - s2) / denom;
    }

    const freq = sr_f / interp_tau;
    const midi_f = 69.0 + 12.0 * std.math.log2(freq / 440.0);
    if (!std.math.isFinite(midi_f) or midi_f < 0.0 or midi_f > 127.0) return null;
    return midi_f;
}

// -----------------------------------------------------------------------
// Tests

fn sineClip(buf: []f32, freq: f32, sample_rate: u32) void {
    const sr_f: f32 = @floatFromInt(sample_rate);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr_f;
        s.* = @sin(2.0 * std.math.pi * freq * t);
    }
}

test "detects A4 (440Hz) sine" {
    var buf: [24_000]f32 = undefined; // 0.5s @ 48kHz
    sineClip(&buf, 440.0, 48_000);
    const r = detect(&buf, 48_000) orelse return error.NoPitchDetected;
    try std.testing.expectEqual(@as(u7, 69), r.note);
    try std.testing.expect(@abs(r.cents) < 5.0);
}

test "detects a low C2 (65.4Hz) sine" {
    var buf: [48_000]f32 = undefined; // 1s @ 48kHz, low notes need more cycles
    sineClip(&buf, 65.406, 48_000);
    const r = detect(&buf, 48_000) orelse return error.NoPitchDetected;
    try std.testing.expectEqual(@as(u7, 36), r.note);
}

test "detects a high C6 (1046.5Hz) sine" {
    var buf: [24_000]f32 = undefined;
    sineClip(&buf, 1046.502, 48_000);
    const r = detect(&buf, 48_000) orelse return error.NoPitchDetected;
    try std.testing.expectEqual(@as(u7, 84), r.note);
}

test "finds the note under an attack too long to skip" {
    const sr: u32 = 48_000;
    var buf: [sr]f32 = undefined; // 1s: 300ms of noise, then the note
    var prng = std.Random.DefaultPrng.init(9);
    const noise_len = sr * 3 / 10;
    for (buf[0..noise_len]) |*s| s.* = prng.random().float(f32) * 2.0 - 1.0;
    sineClip(buf[noise_len..], 440.0, sr);

    const r = detect(&buf, sr) orelse return error.NoPitchDetected;
    try std.testing.expectEqual(@as(u7, 69), r.note);
}

test "takes the note the clip mostly holds, not the one it opens on" {
    const sr: u32 = 48_000;
    var buf: [sr]f32 = undefined;
    const lead = sr / 5; // 200ms of C4, then 800ms of G4
    sineClip(buf[0..lead], 261.626, sr);
    sineClip(buf[lead..], 391.995, sr);

    const r = detect(&buf, sr) orelse return error.NoPitchDetected;
    try std.testing.expectEqual(@as(u7, 67), r.note);
}

test "white noise reports no clear pitch" {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var buf: [24_000]f32 = undefined;
    for (&buf) |*s| s.* = rand.float(f32) * 2.0 - 1.0;
    try std.testing.expectEqual(@as(?Result, null), detect(&buf, 48_000));
}

test "silence reports no clear pitch" {
    var buf: [24_000]f32 = undefined;
    @memset(&buf, 0.0);
    try std.testing.expectEqual(@as(?Result, null), detect(&buf, 48_000));
}

test "too-short clip reports no clear pitch" {
    var buf: [512]f32 = undefined;
    sineClip(&buf, 440.0, 48_000);
    try std.testing.expectEqual(@as(?Result, null), detect(&buf, 48_000));
}

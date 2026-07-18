//! The shared pad/voice engine: one mono clip plus its sampler params -
//! region trim, pitch (playback transpose), amp ADSR, gain, pan, reverse -
//! and the allocation-free voice renderer that both drum-machine pads
//! (dsp/drum_sampler.zig) and the standalone Sampler (dsp/sampler.zig) play
//! through. The control-side linear resampler used on WAV load lives here too.

const std = @import("std");
const types = @import("../core/types.zig");
const wav = @import("../core/wav.zig");

const Sample = types.Sample;

pub const Pad = struct {
    samples: []f32,
    name: [8]u8 = [_]u8{' '} ** 8,
    /// True when the audio was loaded by the user (`:load-sample`) rather
    /// than shipped/generated - only user audio is exported to the
    /// project's sample sidecar on save.
    user_sample: bool = false,

    // ── Sampler params (audio-thread reads; nudged via adjustParam) ──────────
    /// Output level multiplier (0..2). 1.0 = unity.
    gain: f32 = 1.0,
    /// Stereo balance: -1 hard left, 0 center, +1 hard right.
    pan: f32 = 0.0,
    /// Playback transpose in semitones (-24..+24). rate = 2^(semi/12).
    pitch_semitones: f32 = 0.0,
    /// Region start as a fraction of the clip (0..1).
    start_norm: f32 = 0.0,
    /// Region end as a fraction of the clip (0..1). Must exceed start_norm.
    end_norm: f32 = 1.0,
    /// Play the region back to front when true.
    reverse: bool = false,
    // Amplitude ADSR. For one-shots (no note-off) attack/decay/sustain shape
    // the body and `release_s` fades the tail at the region end (see Voice
    // rendering). Defaults reproduce an unshaped, instant-on one-shot.
    attack_s: f32 = 0.001,
    decay_s: f32 = 0.0,
    sustain: f32 = 1.0,
    release_s: f32 = 0.005,
};

/// Number of shared, continuous per-pad params `adjustParam`/`setParamAbsolute`/
/// `paramValue` cover - start/end/pitch/attack/decay/sustain/release/gain/pan,
/// plus the reverse toggle at id 9. Callers with extra ids of their own
/// (Sampler's root_note/mono, ...) dispatch those separately and fall through
/// to these for 0-9.
pub const param_count: u8 = 10;

/// Nudge shared pad param `id` (0-9) by `steps` (h/l = ±1, H/L = ±10). Shared
/// by Sampler and Slicer, whose per-slice params were previously hand-copied
/// switches over the same fields/ranges.
pub fn adjustParam(pad: *Pad, id: u8, steps: i32) void {
    if (id == 9) {
        if (steps != 0) pad.reverse = !pad.reverse;
        return;
    }
    const value = paramValue(pad, id) orelse return;
    setParamAbsolute(pad, id, value + @as(f32, @floatFromInt(steps)) * paramStep(id));
}

/// Amount a one-step nudge changes each continuous pad parameter. Keeping
/// these increments next to the canonical setter prevents the nudge and
/// restore paths from drifting apart when a parameter range changes.
fn paramStep(id: u8) f32 {
    return switch (id) {
        0, 1, 5, 7 => 0.01,
        2 => 1.0,
        3 => 0.001,
        4, 6 => 0.005,
        8 => 0.05,
        else => 0.0,
    };
}

/// Absolute-value counterpart to `adjustParam`, same id space and clamp
/// ranges - for undo's capture/restore. Toggle (reverse, id 9): >= 0.5 is on.
pub fn setParamAbsolute(pad: *Pad, id: u8, value: f32) void {
    if (!std.math.isFinite(value)) return;
    switch (id) {
        0 => pad.start_norm = std.math.clamp(value, 0.0, pad.end_norm - 0.01),
        // zig fmt: off
        1 => pad.end_norm   = std.math.clamp(value, pad.start_norm + 0.01, 1.0),
        2 => pad.pitch_semitones = std.math.clamp(value, -24.0, 24.0),
        3 => pad.attack_s   = std.math.clamp(value, 0.0, 5.0),
        4 => pad.decay_s    = std.math.clamp(value, 0.0, 5.0),
        5 => pad.sustain    = std.math.clamp(value, 0.0, 1.0),
        6 => pad.release_s  = std.math.clamp(value, 0.001, 5.0),
        7 => pad.gain       = std.math.clamp(value, 0.0, 2.0),
        8 => pad.pan        = std.math.clamp(value, -1.0, 1.0),
        9 => pad.reverse    = value >= 0.5,
        // zig fmt: on
        else => {},
    }
}

test "setParamAbsolute ignores non-finite values for every pad parameter" {
    var pad: Pad = .{ .samples = &.{} };
    for (0..param_count) |id| {
        const before = paramValue(&pad, @intCast(id)).?;
        setParamAbsolute(&pad, @intCast(id), std.math.nan(f32));
        try std.testing.expectEqual(before, paramValue(&pad, @intCast(id)).?);
        setParamAbsolute(&pad, @intCast(id), std.math.inf(f32));
        try std.testing.expectEqual(before, paramValue(&pad, @intCast(id)).?);
    }
}

/// Current value of shared pad param `id`, same unit/encoding
/// `setParamAbsolute` accepts (reverse as 0/1) - the read half of undo's
/// capture/restore pair.
pub fn paramValue(pad: *const Pad, id: u8) ?f32 {
    return switch (id) {
        // zig fmt: off
        0 => pad.start_norm,
        1 => pad.end_norm,
        2 => pad.pitch_semitones,
        3 => pad.attack_s,
        4 => pad.decay_s,
        5 => pad.sustain,
        6 => pad.release_s,
        7 => pad.gain,
        8 => pad.pan,
        9 => if (pad.reverse) 1.0 else 0.0,
        // zig fmt: on
        else => null,
    };
}

pub const Voice = struct {
    active: bool = false,
    /// Source frames consumed since the trigger, as a fractional count that
    /// advances by the pitch rate each output frame. Read position within the
    /// clip is derived from this plus the pad's region start (or end, reversed).
    played: f64 = 0,
    /// Frame offset within the current block where this voice starts.
    /// 0 for voices continuing from a previous block.
    block_start: u32 = 0,
    /// Trigger velocity applied on top of the pad gain. 1.0 = full hit;
    /// sequencer steps fire at their per-step level (DrumMachine.velGain).
    vel: f32 = 1.0,
};

/// Play one pad voice into `buf`: fractional pitched read with linear
/// interpolation, region trim, optional reverse, amp ADSR + release fade,
/// and a linear pan law (center = unity in both channels).
pub fn renderVoice(
    voice: *Voice,
    pad: *const Pad,
    buf: []Sample,
    channels: usize,
    frames: u32,
    sr: f64,
) void {
    const len = pad.samples.len;
    // zig fmt: off
    if (len == 0) { voice.active = false; return; }
    const len_f: f64 = @floatFromInt(len);

    // Resolve the play region in source frames. Guard against an inverted
    // or empty selection.
    const lo = std.math.clamp(@as(f64, pad.start_norm), 0.0, 1.0) * len_f;
    const hi = std.math.clamp(@as(f64, pad.end_norm), 0.0, 1.0) * len_f;
    const region_len = hi - lo;
    if (region_len <= 1.0) { voice.active = false; return; }
    // zig fmt: on

    const rate: f64 = std.math.pow(f64, 2.0, @as(f64, pad.pitch_semitones) / 12.0);

    // Linear pan: center keeps unity in both channels (matches the prior
    // mono-to-both behaviour at pan = 0).
    const gl: f32 = pad.gain * voice.vel * @min(1.0, 1.0 - pad.pan);
    const gr: f32 = pad.gain * voice.vel * @min(1.0, 1.0 + pad.pan);

    const start = voice.block_start;
    var i: usize = start;
    while (i < frames) : (i += 1) {
        // zig fmt: off
        if (voice.played >= region_len) { voice.active = false; break; }
        // zig fmt: on

        // Read position within the clip for this voice's progress.
        const rp: f64 = if (pad.reverse) (hi - 1.0 - voice.played) else (lo + voice.played);
        const s = sampleAt(pad.samples, rp);

        // Envelope (output time): attack/decay/sustain on the body, plus a
        // release fade over the final `release_s` of the region.
        const t_out = voice.played / rate / sr;
        const left_out = (region_len - voice.played) / rate / sr;
        const env = adsrLevel(t_out, pad.attack_s, pad.decay_s, pad.sustain) *
            releaseFade(left_out, pad.release_s);

        const v = s * env;
        buf[i * channels] += v * gl;
        buf[i * channels + 1] += v * gr;

        voice.played += rate;
    }
    voice.block_start = 0;
}

// -----------------------------------------------------------------------
// Voice-render math (audio thread, allocation-free)

/// Linearly interpolate `samples` at fractional position `p`. Returns 0 past
/// the ends so a voice fades out cleanly rather than reading garbage.
fn sampleAt(samples: []const f32, p: f64) f32 {
    if (p < 0.0) return 0.0;
    const idx: usize = @intFromFloat(p);
    if (idx + 1 < samples.len) {
        const frac: f32 = @floatCast(p - @as(f64, @floatFromInt(idx)));
        return samples[idx] * (1.0 - frac) + samples[idx + 1] * frac;
    }
    if (idx < samples.len) return samples[idx];
    return 0.0;
}

/// Attack → decay → sustain level at output time `t` seconds. With the default
/// params (attack≈0, decay 0, sustain 1) this is unity after the first sample.
fn adsrLevel(t: f64, attack_s: f32, decay_s: f32, sustain: f32) f32 {
    const a: f64 = @floatCast(attack_s);
    const d: f64 = @floatCast(decay_s);
    const sus: f64 = @floatCast(sustain);
    if (a > 0.0 and t < a) return @floatCast(t / a);
    const td = t - a;
    if (d > 0.0 and td < d) return @floatCast(1.0 - (1.0 - sus) * (td / d));
    return @floatCast(sus);
}

/// Release fade in the final `release_s` seconds of the region. `left` is the
/// remaining output time. Returns 1 outside the release window.
fn releaseFade(left: f64, release_s: f32) f32 {
    const r: f64 = @floatCast(release_s);
    if (r <= 0.0 or left >= r) return 1.0;
    return @floatCast(std.math.clamp(left / r, 0.0, 1.0));
}

// -----------------------------------------------------------------------
// Linear resampler (control-side, allocates)

pub fn decodeWav(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    sample_rate: u32,
) ![]f32 {
    const result = try wav.parseAlloc(allocator, bytes);
    errdefer allocator.free(result.samples);
    if (result.sample_rate == sample_rate) return result.samples;
    const samples = try resampleLinear(allocator, result.samples, result.sample_rate, sample_rate);
    allocator.free(result.samples);
    return samples;
}

pub fn resampleLinear(
    allocator: std.mem.Allocator,
    src: []const f32,
    src_rate: u32,
    dst_rate: u32,
) ![]f32 {
    if (src_rate == 0 or dst_rate == 0) return error.InvalidSampleRate;
    if (src_rate == dst_rate) return allocator.dupe(f32, src);
    const ratio: f64 = @as(f64, @floatFromInt(src_rate)) / @as(f64, @floatFromInt(dst_rate));
    const scaled_len = @as(u128, src.len) * dst_rate;
    const dst_len_u128 = (scaled_len + src_rate - 1) / src_rate;
    if (dst_len_u128 > std.math.maxInt(usize)) return error.OutputTooLarge;
    const dst_len: usize = @intCast(dst_len_u128);
    const out = try allocator.alloc(f32, dst_len);
    for (out, 0..) |*s, i| {
        const sp: f64 = @as(f64, @floatFromInt(i)) * ratio;
        const si: usize = @intFromFloat(sp);
        const frac: f32 = @floatCast(sp - @as(f64, @floatFromInt(si)));
        if (si + 1 < src.len) {
            s.* = src[si] * (1.0 - frac) + src[si + 1] * frac;
        } else if (si < src.len) {
            s.* = src[si];
        } else {
            s.* = 0.0;
        }
    }
    return out;
}

// -----------------------------------------------------------------------
// Tests

test "resampleLinear preserves amplitude" {
    const src = [_]f32{ 0.0, 0.5, 1.0, 0.5, 0.0 };
    const out = try resampleLinear(std.testing.allocator, &src, 44_100, 48_000);
    defer std.testing.allocator.free(out);
    // Output should be longer and all values in [-1, 1]
    try std.testing.expect(out.len > src.len);
    for (out) |s| try std.testing.expect(@abs(s) <= 1.0 + 1e-6);
}

test "resampleLinear validates rates and rounds output length up" {
    try std.testing.expectError(
        error.InvalidSampleRate,
        resampleLinear(std.testing.allocator, &.{1.0}, 0, 48_000),
    );
    try std.testing.expectError(
        error.InvalidSampleRate,
        resampleLinear(std.testing.allocator, &.{1.0}, 48_000, 0),
    );

    const out = try resampleLinear(std.testing.allocator, &.{ 0.0, 0.5, 1.0 }, 2, 3);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 5), out.len);
}

test "adjustParam uses the same bounds as absolute parameter assignment" {
    const testing = std.testing;
    const initial = Pad{
        .samples = &.{},
        .start_norm = 0.2,
        .end_norm = 0.8,
        .pitch_semitones = 3.0,
        .attack_s = 0.2,
        .decay_s = 0.3,
        .sustain = 0.7,
        .release_s = 0.4,
        .gain = 0.9,
        .pan = -0.2,
    };

    for (0..9) |raw_id| {
        const id: u8 = @intCast(raw_id);
        var nudged = initial;
        var assigned = initial;
        adjustParam(&nudged, id, 3);
        setParamAbsolute(&assigned, id, paramValue(&initial, id).? + 3.0 * paramStep(id));
        try testing.expectApproxEqAbs(paramValue(&assigned, id).?, paramValue(&nudged, id).?, 1e-6);
    }

    var toggled = initial;
    adjustParam(&toggled, 9, 1);
    try testing.expect(toggled.reverse);
    adjustParam(&toggled, 9, 0);
    try testing.expect(toggled.reverse);
}

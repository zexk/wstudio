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
    /// Linear gain ramp over the first `fade_in_s` seconds of playback and
    /// the last `fade_out_s` before the region end. 0 (the default) = off.
    /// Unlike the ADSR - an instrument-shaping envelope - these are edit
    /// fades: declick a rough sample trim or ease an audio clip in/out.
    /// They multiply on top of the ADSR rather than replacing it.
    fade_in_s: f32 = 0.0,
    fade_out_s: f32 = 0.0,
    /// Playback duration multiplier, independent of `pitch_semitones`
    /// (0.25..4.0; 1.0 = today's tied pitch/speed behavior, unchanged).
    /// >1 stretches (plays longer), <1 compresses (plays shorter). A plain
    /// `pitch_semitones` shift alone still changes duration too (rate>1
    /// plays back `rate`-times faster, same as always) - setting
    /// `stretch_ratio` equal to that same rate (2^(semi/12)) cancels it,
    /// composing into a duration-preserving pitch-shift. See
    /// `renderVoiceStretched`.
    stretch_ratio: f32 = 1.0,
};

pub fn fixedName(name: []const u8) [8]u8 {
    var out = [_]u8{' '} ** 8;
    const len = @min(name.len, out.len);
    @memcpy(out[0..len], name[0..len]);
    return out;
}

pub fn trimmedName(name: *const [8]u8) []const u8 {
    var end = name.len;
    while (end > 0 and name[end - 1] == ' ') end -= 1;
    return name[0..end];
}

pub fn emptyPad() *const Pad {
    const holder = struct {
        var pad: Pad = .{ .samples = &[_]f32{} };
    };
    return &holder.pad;
}

/// Number of shared, continuous per-pad params `adjustParam`/`setParamAbsolute`/
/// `paramValue` cover - start/end/pitch/attack/decay/sustain/release/gain/pan,
/// the reverse toggle at id 9, the fade in/out pair at 10/11, and stretch at
/// 12. Callers with extra ids of their own (Sampler's root_note/mono, ...)
/// dispatch those separately and fall through to these for 0-12. The whole
/// space must stay within one nibble - DrumMachine/Slicer pack the param id
/// into `paramId`'s low 4 bits.
pub const param_count: u8 = 13;

/// Nudge shared pad param `id` (0-12) by `steps` (h/l = ±1, H/L = ±10). Shared
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
        4, 6, 10, 11 => 0.005,
        8 => 0.05,
        12 => 0.05,
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
        10 => pad.fade_in_s  = std.math.clamp(value, 0.0, 5.0),
        11 => pad.fade_out_s = std.math.clamp(value, 0.0, 5.0),
        12 => pad.stretch_ratio = std.math.clamp(value, 0.25, 4.0),
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
        10 => pad.fade_in_s,
        11 => pad.fade_out_s,
        12 => pad.stretch_ratio,
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
    /// WSOLA state, touched only when `pad.stretch_ratio != 1.0` - see
    /// `renderVoiceStretched`. Reconstructed from scalars each grain hop
    /// rather than a cached buffer, since `pad.samples` is already fully
    /// buffered and randomly addressable.
    stretch: StretchState = .{},
};

const StretchState = struct {
    /// Current grain's source-frame anchor.
    cur_src: f64 = 0,
    /// Outgoing grain's natural (no-jump) continuation anchor.
    prev_src: f64 = 0,
    has_prev: bool = false,
    /// Output frames produced since the last grain hop.
    out_in_grain: u32 = 0,
    /// Literal output-frame counter since trigger, for envelope timing.
    out_played: f64 = 0,
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

    // WSOLA time-stretch: only when requested and the region holds at least
    // two grains' worth of material - otherwise fall through to the plain
    // path below unchanged (byte-for-byte identical at stretch_ratio == 1.0).
    if (pad.stretch_ratio != 1.0 and region_len >= 2.0 * grainFrames(sr)) {
        renderVoiceStretched(voice, pad, buf, channels, frames, sr, lo, hi, rate, gl, gr);
        return;
    }

    const start = voice.block_start;
    var i: usize = start;
    while (i < frames) : (i += 1) {
        // zig fmt: off
        if (voice.played >= region_len) { voice.active = false; break; }
        // zig fmt: on

        // Read position within the clip for this voice's progress.
        const rp: f64 = if (pad.reverse) (hi - 1.0 - voice.played) else (lo + voice.played);
        const s = sampleAt(pad.samples, rp);

        // Envelope (output time): attack/decay/sustain on the body, a
        // release fade over the final `release_s` of the region, and the
        // edit fades - fade-in over elapsed time, fade-out over remaining
        // time - multiplied on top (see the Pad field doc comment).
        const t_out = voice.played / rate / sr;
        const left_out = (region_len - voice.played) / rate / sr;
        const env = adsrLevel(t_out, pad.attack_s, pad.decay_s, pad.sustain) *
            linearRamp(left_out, pad.release_s) *
            linearRamp(t_out, pad.fade_in_s) *
            linearRamp(left_out, pad.fade_out_s);

        const v = s * env;
        buf[i * channels] += v * gl;
        buf[i * channels + 1] += v * gr;

        voice.played += rate;
    }
    voice.block_start = 0;
}

/// Grain length in frames (~30ms) - long enough to cover a full period down
/// to the lowest note `dsp/pitch.zig` will estimate a fundamental for.
fn grainFrames(sr: f64) f64 {
    return 0.030 * sr;
}

/// Synthesis hop (~15ms, 50% overlap of `grainFrames`). Also the crossfade
/// length: with 50% overlap, hop and overlap are the same length.
fn hopFrames(sr: f64) f64 {
    return 0.015 * sr;
}

/// Correlation search radius (~5ms either side of the nominal jump target).
fn searchRadiusFrames(sr: f64) f64 {
    return 0.005 * sr;
}

/// WSOLA time-stretch path: plays `pad.samples` at the pitch `rate` already
/// implies (same as `renderVoice`), but decouples playback *duration* from
/// it via `pad.stretch_ratio`. Grains advance through source-space at
/// `rate / stretch_ratio` per output hop rather than `rate` per output frame;
/// a bounded correlation search picks each new grain's alignment against the
/// outgoing grain's natural continuation to avoid phase discontinuities, and
/// the two are pairwise-crossfaded over the overlap region. See the module
/// doc comment on `Voice.stretch` and the plan this shipped from for the
/// derivation. Only reads `pad.samples` (already fully buffered) plus O(1)
/// scalar state on `voice.stretch` - no allocation, no cached grain buffer.
fn renderVoiceStretched(
    voice: *Voice,
    pad: *const Pad,
    buf: []Sample,
    channels: usize,
    frames: u32,
    sr: f64,
    lo: f64,
    hi: f64,
    rate: f64,
    gl: f32,
    gr: f32,
) void {
    const dir: f64 = if (pad.reverse) -1.0 else 1.0;
    const ha = hopFrames(sr);
    const ha_i: u32 = @intFromFloat(@max(1.0, @round(ha)));
    const search_r = searchRadiusFrames(sr);
    const stretch_ratio: f64 = @max(0.01, @as(f64, pad.stretch_ratio));

    const st = &voice.stretch;
    if (st.out_played == 0.0) {
        st.cur_src = if (pad.reverse) hi - 1.0 else lo;
    }

    const start = voice.block_start;
    var i: usize = start;
    while (i < frames) : (i += 1) {
        // Start a new grain once the current one has played out its hop.
        if (st.out_in_grain >= ha_i) {
            const advance = dir * ha * rate;
            const prev_src = st.cur_src + advance;
            const nominal_src = st.cur_src + advance / stretch_ratio;
            st.prev_src = prev_src;
            st.cur_src = searchBestAlign(pad.samples, prev_src, nominal_src, search_r, ha, dir, lo, hi);
            st.has_prev = true;
            st.out_in_grain = 0;
        }

        const grain_off = dir * @as(f64, @floatFromInt(st.out_in_grain)) * rate;
        const cur_read = st.cur_src + grain_off;

        // Region exhaustion, derived from the actual read position rather
        // than an accumulated counter - naturally absorbs a grain hop that
        // overshoots the region end.
        const remaining_src: f64 = if (pad.reverse) (cur_read - lo) else (hi - cur_read);
        if (remaining_src <= 0.0) {
            voice.active = false;
            break;
        }

        var s = sampleAt(pad.samples, std.math.clamp(cur_read, lo, hi - 1.0));
        if (st.has_prev and st.out_in_grain < ha_i) {
            const prev_read = st.prev_src + grain_off;
            const old = sampleAt(pad.samples, std.math.clamp(prev_read, lo, hi - 1.0));
            const frac: f32 = @floatCast(@as(f64, @floatFromInt(st.out_in_grain)) / ha);
            s = old * (1.0 - frac) + s * frac;
        }

        // Envelope (output time): `out_played` counts real output frames
        // directly (stretch already folded in, unlike the plain path's
        // `played/rate`), and `left_out` converts the remaining *source*
        // frames back to output seconds via the same stretch factor.
        const t_out = st.out_played / sr;
        const left_out = remaining_src * stretch_ratio / rate / sr;
        const env = adsrLevel(t_out, pad.attack_s, pad.decay_s, pad.sustain) *
            linearRamp(left_out, pad.release_s) *
            linearRamp(t_out, pad.fade_in_s) *
            linearRamp(left_out, pad.fade_out_s);

        const v = s * env;
        buf[i * channels] += v * gl;
        buf[i * channels + 1] += v * gr;

        st.out_in_grain += 1;
        st.out_played += 1.0;
    }
    voice.block_start = 0;
}

/// Search `[-search_r, +search_r]` source frames around `nominal_src` for the
/// offset whose `hop`-length window best matches (highest normalized
/// cross-correlation) `prev_src`'s window - i.e. the new grain that continues
/// most smoothly from where the outgoing one left off. Falls back to
/// `nominal_src` unchanged when `search_r` rounds to zero (degenerate sample
/// rate).
fn searchBestAlign(
    samples: []const f32,
    prev_src: f64,
    nominal_src: f64,
    search_r: f64,
    hop: f64,
    dir: f64,
    lo: f64,
    hi: f64,
) f64 {
    const hop_i: usize = @intFromFloat(@max(1.0, @round(hop)));
    const steps: i64 = @intFromFloat(@round(search_r));
    if (steps <= 0) return nominal_src;

    // Normalized cross-correlation, not raw SSD: a decaying/enveloped source
    // (any one-shot with a release) has systematically lower energy further
    // into the clip, which would otherwise bias a magnitude-sensitive error
    // toward whichever candidate happens to match `prev_src`'s amplitude
    // rather than its waveform shape - pulling the stretch back toward the
    // unstretched continuation. Dividing out each window's own energy keeps
    // the search scale-invariant.
    const score = struct {
        fn at(smp: []const f32, prev: f64, cand: f64, len: usize, direction: f64, lo2: f64, hi2: f64) f64 {
            var dot: f64 = 0.0;
            var ea: f64 = 0.0;
            var eb: f64 = 0.0;
            var j: usize = 0;
            while (j < len) : (j += 1) {
                const off = direction * @as(f64, @floatFromInt(j));
                const a: f64 = sampleAt(smp, std.math.clamp(prev + off, lo2, hi2 - 1.0));
                const b: f64 = sampleAt(smp, std.math.clamp(cand + off, lo2, hi2 - 1.0));
                dot += a * b;
                ea += a * a;
                eb += b * b;
            }
            return dot / @sqrt(ea * eb + 1e-9);
        }
    }.at;

    // Scan outward from the nominal target (k=0) rather than left-to-right,
    // and only displace the current best by a real margin. Strongly
    // periodic material (a sustained tone) can have a search window wider
    // than one pitch period, so a distant candidate can score marginally
    // higher purely by locking onto an adjacent period rather than by being
    // a meaningfully better splice point - which would silently override
    // the requested stretch amount, hop after hop. Preferring the closest
    // near-equally-good match keeps the actual grain drift tracking
    // `stretch_ratio` instead of the source's own periodicity.
    const margin = 0.001;
    var best_k: i64 = 0;
    var best_score = score(samples, prev_src, nominal_src, hop_i, dir, lo, hi);
    var d: i64 = 1;
    while (d <= steps) : (d += 1) {
        const cand_neg = nominal_src - @as(f64, @floatFromInt(d));
        const s_neg = score(samples, prev_src, cand_neg, hop_i, dir, lo, hi);
        if (s_neg > best_score + margin) {
            best_score = s_neg;
            best_k = -d;
        }
        const cand_pos = nominal_src + @as(f64, @floatFromInt(d));
        const s_pos = score(samples, prev_src, cand_pos, hop_i, dir, lo, hi);
        if (s_pos > best_score + margin) {
            best_score = s_pos;
            best_k = d;
        }
    }
    return nominal_src + @as(f64, @floatFromInt(best_k));
}

// -----------------------------------------------------------------------
// Voice-render math (audio thread, allocation-free)

/// Linearly interpolate `samples` at fractional position `p`. Returns 0 past
/// the ends so a voice fades out cleanly rather than reading garbage.
/// Public so soundfont_player.zig's voice render can share it too.
pub fn sampleAt(samples: []const f32, p: f64) f32 {
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

/// Linear 0→1 gain ramp over the first `dur` seconds of `t`; 1 past it (or
/// when the ramp is off, dur = 0). One shape, three uses: the release fade
/// and the fade-out get remaining output time, the fade-in gets elapsed.
fn linearRamp(t: f64, dur: f32) f32 {
    const d: f64 = @floatCast(dur);
    if (d <= 0.0 or t >= d) return 1.0;
    return @floatCast(std.math.clamp(t / d, 0.0, 1.0));
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

test "renderVoice applies fade-in and fade-out ramps on top of the ADSR" {
    const testing = std.testing;
    var samples = [_]f32{1.0} ** 1000; // 1s of DC at unity, 1kHz for readable math
    const p = Pad{
        .samples = &samples,
        .fade_in_s = 0.1,
        .fade_out_s = 0.2,
        .attack_s = 0.0,
        .release_s = 0.001,
    };
    var voice = Voice{ .active = true };
    var buf = [_]Sample{0.0} ** 2000; // 1000 stereo frames
    renderVoice(&voice, &p, &buf, 2, 1000, 1000.0);

    // Halfway through the 100ms fade-in: half level.
    try testing.expectApproxEqAbs(@as(f32, 0.5), buf[50 * 2], 0.02);
    // Past both fades, body plays at unity.
    try testing.expectApproxEqAbs(@as(f32, 1.0), buf[500 * 2], 0.02);
    // 100ms before the region end - halfway through the 200ms fade-out.
    try testing.expectApproxEqAbs(@as(f32, 0.5), buf[900 * 2], 0.02);

    // Defaults (both 0) leave the body untouched: same frame, full level.
    var flat_voice = Voice{ .active = true };
    var flat_buf = [_]Sample{0.0} ** 2000;
    const flat = Pad{ .samples = &samples, .attack_s = 0.0, .release_s = 0.001 };
    renderVoice(&flat_voice, &flat, &flat_buf, 2, 1000, 1000.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), flat_buf[50 * 2], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 1.0), flat_buf[900 * 2], 0.02);
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
        .fade_in_s = 0.1,
        .fade_out_s = 0.2,
    };

    for (0..param_count) |raw_id| {
        if (raw_id == 9) continue; // reverse toggle, asserted below
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

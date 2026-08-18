//! The shared pad/voice engine: one mono clip plus its sampler params -
//! region trim, pitch (playback transpose), amp ADSR, gain, pan, reverse -
//! and the allocation-free voice renderer that both drum-machine pads
//! (dsp/drum_sampler.zig) and the standalone Sampler (dsp/sampler.zig) play
//! through. The control-side rate conversion used on WAV load lives here too.

const std = @import("std");
const types = @import("../core/types.zig");
const wav = @import("../core/wav.zig");

const speex = @cImport(@cInclude("speex/speex_resampler.h"));
const lfo_dsp = @import("lfo.zig");
const dsp = @import("device.zig");
const synth_math = @import("synth_math.zig");
const Lfo = lfo_dsp.Lfo;

const Sample = types.Sample;

pub const Pad = struct {
    samples: []f32,
    name: [8]u8 = [_]u8{' '} ** 8,
    /// True when the audio was loaded by the user (`:load-sample`) rather
    /// than shipped/generated - only user audio is exported to the
    /// project's audio cache on save.
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
    /// Shared ADSR segment curvature: -1 fast, 0 linear, +1 slow.
    env_curve: f32 = 0.0,
    /// Gain ramp over the first `fade_in_s` seconds of playback and
    /// the last `fade_out_s` before the region end. 0 (the default) = off.
    /// Unlike the ADSR - an instrument-shaping envelope - these are edit
    /// fades: declick a rough sample trim or ease an audio clip in/out.
    /// They multiply on top of the ADSR rather than replacing it.
    fade_in_s: f32 = 0.0,
    fade_out_s: f32 = 0.0,
    /// Shared edit-fade curvature: -1 fast, 0 linear, +1 slow.
    fade_curve: f32 = 0.0,
    /// Playback duration multiplier, independent of `pitch_semitones`
    /// (0.25..4.0; 1.0 = today's tied pitch/speed behavior, unchanged).
    /// >1 stretches (plays longer), <1 compresses (plays shorter). A plain
    /// `pitch_semitones` shift alone still changes duration too (rate>1
    /// plays back `rate`-times faster, same as always) - setting
    /// `stretch_ratio` equal to that same rate (2^(semi/12)) cancels it,
    /// composing into a duration-preserving pitch-shift. See
    /// `renderVoiceStretched`.
    stretch_ratio: f32 = 1.0,
    /// Algorithm used when `stretch_ratio` is not 1. Beats uses short grains
    /// for sharp attacks; tones uses long correlation windows for sustain.
    ///
    /// Tones by default, measured over the reference corpus at 1.5x: it keeps
    /// 0.944 of the source's average spectrum against beats' 0.848, and holds
    /// that lead in every category. Beats earns its place on percussive
    /// material instead, where it reproduces the right *number* of transients
    /// - 10% count error against tones' 34% on one-shot percussion, 22%
    /// against 31% on drum loops - because its short grains repeat less of a
    /// hit. On mixed loops that flips (39% against 28%), which is why tones is
    /// the default rather than a per-material guess.
    warp_method: WarpMethod = .tones,
    /// Repeat the play region instead of stopping at its end - see
    /// `LoopMode`. `.off` (the default) is the one-shot behaviour every
    /// existing pad has.
    loop: LoopMode = .off,
    /// Bipolar tone filter (-1..+1), one knob covering both directions the
    /// way a DJ/sampler filter does: negative sweeps a one-pole low-pass down
    /// from 20 kHz to 200 Hz, positive sweeps a one-pole high-pass up from
    /// 20 Hz to 8 kHz. 0 (the default) bypasses the filter entirely, so an
    /// untouched pad renders exactly as before.
    filter: f32 = 0.0,
    /// Gated playback: the voice releases over `release_s` at the end of its
    /// note instead of running to the region end. Off (the default) is the
    /// classic one-shot/latched behaviour - a triggered pad always plays out.
    /// A standalone Sampler's note end is the piano-roll note-off; a
    /// step-sequenced drum pad or slice has no note-off to wait for, so the
    /// sequencer hands it the step's own length as `Voice.hold_frames` (see
    /// `step_grid_ops.scheduleNote`) and the pad stops where its step does.
    gate: bool = false,
    /// Retrigger playback: a one-shot that cuts its own still-ringing voices
    /// when it fires again, so a replayed pad never overlaps itself. Unlike
    /// `gate` this needs nothing from the caller, which is what makes it the
    /// default a drum pad and a fresh chop both opt into. `gate` wins when
    /// both are set - see `playMode`.
    retrig: bool = false,

    /// Free-running per-pad LFO (see `dsp/lfo.zig`). Ticked once per block
    /// by the owning engine's `processBlock` (mutable access - `renderVoice`
    /// only ever borrows `*const Pad`), then read here by `renderVoice` to
    /// offset whichever field `mod_dest` names. Phase alone, not persisted
    /// as meaningful state - a reload resumes at phase 0, same as any FX
    /// unit's own `Lfo` on project load.
    mod_lfo: Lfo = .{},
    /// LFO rate in Hz (0.02..20).
    mod_rate_hz: f32 = 2.0,
    /// LFO depth (0..1), scales the bipolar sample before it's added to
    /// `mod_dest`'s field.
    mod_depth: f32 = 0.0,
    mod_shape: lfo_dsp.Shape = .sine,
    /// Which field the LFO offsets. `.off` (the default) means every
    /// existing pad is unaffected - `renderVoice`/the owning engine's tick
    /// site skip the LFO entirely in that case.
    mod_dest: ModDest = .off,
};

/// How the play region repeats. `forward` restarts at the region start (the
/// classic sampler loop, with whatever discontinuity the two edges imply);
/// `ping_pong` reflects at each edge instead, so the seam is continuous in
/// position and never clicks.
///
/// A loop only takes effect where something can end the voice - a note-off
/// (gate play mode) or a sequenced step's own length. A latched one-shot has
/// neither, so it plays the region once as always rather than ringing
/// forever; see `renderVoice`'s `looping`.
pub const LoopMode = enum { off, forward, ping_pong };
pub const loop_mode_names = [_][]const u8{ "off", "forward", "ping-pong" };

pub const WarpMethod = enum { beats, tones };
pub const warp_method_names = [_][]const u8{ "beats", "tones" };

/// Position within the region, in source frames from its start, for a voice
/// that has consumed `played` source frames. Everything past the first pass
/// only exists for a looping voice - `.off` returns `played` untouched, so
/// the non-looping read position is byte-identical to before loops existed.
pub fn loopPos(played: f64, region_len: f64, mode: LoopMode) f64 {
    return switch (mode) {
        .off => played,
        .forward => @mod(played, region_len),
        // One ping-pong cycle is two passes; the second is the first
        // mirrored, which is why no direction state is needed on the voice.
        .ping_pong => blk: {
            const cycle = 2.0 * region_len;
            const p = @mod(played, cycle);
            break :blk if (p < region_len) p else cycle - p;
        },
    };
}

test "loopPos wraps forward and reflects ping-pong" {
    // Region 100 frames long, sampled either side of the seam at 100.
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), loopPos(90, 100, .forward), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), loopPos(110, 100, .forward), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), loopPos(310, 100, .forward), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), loopPos(110, 100, .ping_pong), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), loopPos(190, 100, .ping_pong), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), loopPos(210, 100, .ping_pong), 1e-9);
    // Continuous across the turn: approaching 100 from either side agrees.
    try std.testing.expectApproxEqAbs(loopPos(99.9, 100, .ping_pong), loopPos(100.1, 100, .ping_pong), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 400.0), loopPos(400, 100, .off), 1e-9);
}

/// Destinations a pad's LFO can offset. Deliberately a single choice, not a
/// matrix - see `dsp/synth.zig`'s `ModRow` for the richer per-voice version
/// this doesn't try to be.
pub const ModDest = enum { off, pitch, gain, pan, filter };
pub const mod_dest_names = [_][]const u8{ "off", "pitch", "gain", "pan", "filter" };

/// The three mutually exclusive things the `gate`/`retrig` pair encodes.
/// Read/write it through `playMode`/`setPlayMode` rather than the raw flags.
pub const PlayMode = enum { one_shot, gate, retrigger };

pub fn playMode(pad: *const Pad) PlayMode {
    if (pad.gate) return .gate;
    return if (pad.retrig) .retrigger else .one_shot;
}

pub fn setPlayMode(pad: *Pad, mode: PlayMode) void {
    pad.gate = mode == .gate;
    pad.retrig = mode == .retrigger;
}

/// Row labels for the play-mode param, in `PlayMode` order. UI-side tables
/// index this with `@intFromEnum(playMode(pad))`.
pub const play_mode_names = [_][]const u8{ "one-shot", "gate", "retrigger" };

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
/// the reverse toggle at id 9, the fade in/out pair at 10/11, stretch at 12,
/// filter at 13, the gate toggle at 14, the per-pad LFO's rate/depth/
/// shape/dest at 15-18, loop mode at 19, and warp method at 20. Callers with extra ids of
/// their own (Sampler's
/// root_note/mono, ...) dispatch those separately and fall through to these
/// for 0-22. The *packed* half of the space must stay within `paramId`'s
/// param field - DrumMachine/Slicer pack the param id into its low 5 bits
/// (32 slots), which 0-22 fits with room to spare; Sampler's own ids past
/// this table are never packed.
pub const param_count: u16 = 23;

/// Ids of the two enum params in this table, so callers that need to treat
/// them differently (undo capture, the automation param picker, the UI's
/// enum rows) name them rather than hardcoding bare numbers. `reverse_id` is
/// a plain on/off; `gate_id` is the three-way `PlayMode` cycle.
pub const reverse_id: u16 = 9;
pub const gate_id: u16 = 14;
/// Playback transpose and duration multiplier, named for the same reason:
/// callers that spread a chop's pitch across pads or fit a loop to the
/// project tempo shouldn't hardcode the indices.
pub const pitch_id: u16 = 2;
pub const stretch_id: u16 = 12;
pub const mod_shape_id: u16 = 17;
pub const mod_dest_id: u16 = 18;
/// The loop-mode cycle (see `LoopMode`), named for the same reason.
pub const loop_id: u16 = 19;
pub const warp_method_id: u16 = 20;
pub const env_curve_id: u16 = 21;
pub const fade_curve_id: u16 = 22;

pub fn playDurationSeconds(pad: *const Pad, sample_rate: u32) f32 {
    if (sample_rate == 0 or pad.samples.len == 0) return 0;
    const region = @max(0, pad.end_norm - pad.start_norm);
    const source_seconds = @as(f32, @floatFromInt(pad.samples.len)) * region / @as(f32, @floatFromInt(sample_rate));
    const rate = std.math.pow(f32, 2, pad.pitch_semitones / 12);
    return @max(0, source_seconds * pad.stretch_ratio / rate);
}

pub fn clampTimeParamsToDuration(pad: *Pad, sample_rate: u32) void {
    if (sample_rate == 0 or pad.samples.len == 0) return;
    const duration = playDurationSeconds(pad, sample_rate);
    pad.attack_s = std.math.clamp(pad.attack_s, 0, duration);
    pad.decay_s = std.math.clamp(pad.decay_s, 0, duration);
    pad.release_s = std.math.clamp(pad.release_s, 0, duration);
    pad.fade_in_s = std.math.clamp(pad.fade_in_s, 0, duration);
    pad.fade_out_s = std.math.clamp(pad.fade_out_s, 0, duration);
}

pub fn affectsTimeRange(id: u16) bool {
    return id == 0 or id == 1 or id == pitch_id or id == 3 or id == 4 or id == 6 or id == 10 or id == 11 or id == stretch_id;
}

test "fade range follows trimmed pitched playback duration" {
    var samples = [_]f32{0} ** 4_800;
    var pad: Pad = .{ .samples = &samples, .end_norm = 0.5, .pitch_semitones = 12, .stretch_ratio = 2, .fade_in_s = 1, .fade_out_s = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), playDurationSeconds(&pad, 48_000), 1e-6);
    clampTimeParamsToDuration(&pad, 48_000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), pad.fade_in_s, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), pad.fade_out_s, 1e-6);
}

/// Nudge shared pad param `id` by `steps` (h/l = ±1, H/L = ±10). Shared
/// by Sampler and Slicer, whose per-slice params were previously hand-copied
/// switches over the same fields/ranges.
pub fn adjustParam(pad: *Pad, id: u16, steps: i32) void {
    if (id == reverse_id) {
        if (steps != 0) pad.reverse = !pad.reverse;
        return;
    }
    if (id == gate_id) {
        if (steps == 0) return;
        const n: i32 = play_mode_names.len;
        const cur: i32 = @intFromEnum(playMode(pad));
        setPlayMode(pad, @enumFromInt(@mod(cur + steps, n)));
        return;
    }
    if (id == mod_shape_id) {
        if (steps == 0) return;
        const n: i32 = @typeInfo(lfo_dsp.Shape).@"enum".fields.len;
        const cur: i32 = @intFromEnum(pad.mod_shape);
        pad.mod_shape = @enumFromInt(@mod(cur + steps, n));
        return;
    }
    if (id == mod_dest_id) {
        if (steps == 0) return;
        const n: i32 = @typeInfo(ModDest).@"enum".fields.len;
        const cur: i32 = @intFromEnum(pad.mod_dest);
        pad.mod_dest = @enumFromInt(@mod(cur + steps, n));
        return;
    }
    if (id == loop_id) {
        if (steps == 0) return;
        const n: i32 = @typeInfo(LoopMode).@"enum".fields.len;
        const cur: i32 = @intFromEnum(pad.loop);
        pad.loop = @enumFromInt(@mod(cur + steps, n));
        return;
    }
    if (id == warp_method_id) {
        if (steps != 0) pad.warp_method = if (pad.warp_method == .beats) .tones else .beats;
        return;
    }
    if (id == 6) {
        pad.release_s = std.math.clamp(pad.release_s * std.math.pow(f32, 2.0, @as(f32, @floatFromInt(steps)) / 12.0), 0.001, 5.0);
        return;
    }
    if (id == 3 or id == 4 or id == 10 or id == 11) {
        const value = paramValue(pad, id).?;
        const t = std.math.cbrt(std.math.clamp(value / 5.0, 0, 1));
        // Cubing back compresses hard near t=0 - at the old 0.01 step, the
        // first 4-5 presses off a zeroed attack/decay/fade landed under half
        // a millisecond and read as "stuck" at the 3-decimal display. 0.05
        // puts the first press at a visible ~0.6ms and clears a full sweep
        // in ~20 presses instead of 100.
        setParamAbsolute(pad, id, 5.0 * std.math.pow(f32, std.math.clamp(t + @as(f32, @floatFromInt(steps)) * 0.05, 0, 1), 3));
        return;
    }
    const value = paramValue(pad, id) orelse return;
    setParamAbsolute(pad, id, value + @as(f32, @floatFromInt(steps)) * paramStep(id));
}

/// Amount a one-step nudge changes each continuous pad parameter. Keeping
/// these increments next to the canonical setter prevents the nudge and
/// restore paths from drifting apart when a parameter range changes.
fn paramStep(id: u16) f32 {
    return switch (id) {
        0, 1, 5, 7 => 0.01,
        2 => 1.0,
        3 => 0.001,
        4, 6, 10, 11 => 0.005,
        8 => 0.05,
        12 => 0.05,
        13 => 0.02,
        15 => 0.1,
        16 => 0.02,
        21 => 0.02,
        22 => 0.02,
        else => 0.0,
    };
}

/// Absolute-value counterpart to `adjustParam`, same id space and clamp
/// ranges - for undo's capture/restore. Toggle (reverse, id 9): >= 0.5 is on.
pub fn setParamAbsolute(pad: *Pad, id: u16, value: f32) void {
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
        13 => pad.filter     = std.math.clamp(value, -1.0, 1.0),
        14 => setPlayMode(pad, @enumFromInt(@as(u8, @intFromFloat(std.math.clamp(@round(value), 0.0, @as(f32, play_mode_names.len - 1)))))),
        15 => pad.mod_rate_hz = std.math.clamp(value, 0.02, 20.0),
        16 => pad.mod_depth  = std.math.clamp(value, 0.0, 1.0),
        17 => pad.mod_shape  = @enumFromInt(@as(u8, @intFromFloat(std.math.clamp(@round(value), 0.0, @as(f32, @typeInfo(lfo_dsp.Shape).@"enum".fields.len - 1))))),
        18 => pad.mod_dest   = @enumFromInt(@as(u8, @intFromFloat(std.math.clamp(@round(value), 0.0, @as(f32, @typeInfo(ModDest).@"enum".fields.len - 1))))),
        19 => pad.loop       = @enumFromInt(@as(u8, @intFromFloat(std.math.clamp(@round(value), 0.0, @as(f32, @typeInfo(LoopMode).@"enum".fields.len - 1))))),
        20 => pad.warp_method = @enumFromInt(@as(u8, @intFromFloat(std.math.clamp(@round(value), 0.0, @as(f32, @typeInfo(WarpMethod).@"enum".fields.len - 1))))),
        21 => pad.env_curve = std.math.clamp(value, -1.0, 1.0),
        22 => pad.fade_curve = std.math.clamp(value, -1.0, 1.0),
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
pub fn paramValue(pad: *const Pad, id: u16) ?f32 {
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
        13 => pad.filter,
        14 => @floatFromInt(@intFromEnum(playMode(pad))),
        15 => pad.mod_rate_hz,
        16 => pad.mod_depth,
        17 => @floatFromInt(@intFromEnum(pad.mod_shape)),
        18 => @floatFromInt(@intFromEnum(pad.mod_dest)),
        19 => @floatFromInt(@intFromEnum(pad.loop)),
        20 => @floatFromInt(@intFromEnum(pad.warp_method)),
        21 => pad.env_curve,
        22 => pad.fade_curve,
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
    /// Per-hit transpose in semitones, on top of the pad's own
    /// `pitch_semitones` - a step's parameter-locked tune (see
    /// `MidiNote.tune`). DrumMachine reaches the same effect by triggering
    /// its pad's Sampler on a different note; a Slicer voice has no note to
    /// shift, so the offset rides on the voice itself.
    tune: i8 = 0,
    /// The sequenced note's own pan/fine-tune/release - see
    /// `dsp.Articulation`. Neutral for a pad hit, a live key, or a drum
    /// step, none of which have a piano-roll note behind them.
    art: dsp.Articulation = .neutral,
    /// WSOLA state, touched only when `pad.stretch_ratio != 1.0` - see
    /// `renderVoiceStretched`. Reconstructed from scalars each grain hop
    /// rather than a cached buffer, since `pad.samples` is already fully
    /// buffered and randomly addressable.
    stretch: StretchState = .{},
    /// One-pole tone-filter state, touched only when `pad.filter != 0`.
    filt: FilterState = .{},
    /// Output frames rendered since this voice's note-off, or -1 while it is
    /// still held. Only consulted for a gated pad (`Pad.gate`); a latched
    /// one-shot leaves it at -1 for its whole life. See `release`.
    release_frames: f64 = -1.0,
    /// Output frames to hold before releasing on the voice's own, or -1 to
    /// hold until an explicit note-off. A step sequencer has no note-off to
    /// send, so a gated hit carries its own length here (the step's, see
    /// `Slicer.scheduleNote`); live/MIDI play leaves it at -1 and waits for
    /// the key. Only consulted for a gated pad, same as `release_frames`.
    hold_frames: f64 = -1.0,
    /// Last stereo pair this voice wrote, kept so whoever steals its slot can
    /// fade the interrupted waveform out instead of dropping it to zero
    /// mid-cycle (an audible click).
    prev_l: f32 = 0,
    prev_r: f32 = 0,
    /// The stolen predecessor's final pair, faded out over ~1ms on top of
    /// this voice's own output - same declick `PolySynth` and
    /// `SoundfontPlayer` voices already do. Seeded by `carryStealTail`.
    steal_tail_l: f32 = 0,
    steal_tail_r: f32 = 0,
    steal_fade: f32 = 0,
};

/// Mark `voice` released, starting the gated fade-out on the next rendered
/// frame. Idempotent: a repeated note-off never restarts the fade.
pub fn release(voice: *Voice) void {
    if (voice.release_frames < 0.0) voice.release_frames = 0.0;
}

/// Hand `fresh` the voice it just displaced, so `renderVoice` fades that
/// interrupted waveform out over ~1ms instead of leaving a step at whatever
/// level the stolen voice was mid-cycle. No-op for a free slot, and for a
/// voice that never wrote a sample.
pub fn carryStealTail(fresh: *Voice, stolen: Voice) void {
    if (!stolen.active) return;
    fresh.steal_tail_l = stolen.prev_l;
    fresh.steal_tail_r = stolen.prev_r;
    fresh.steal_fade = 1.0;
}

/// Release a gated voice that has held for its own `hold_frames`.
/// `out_played` is output frames rendered since the trigger.
fn releaseAtHold(voice: *Voice, out_played: f64) void {
    if (voice.hold_frames >= 0.0 and out_played >= voice.hold_frames) release(voice);
}

const FilterState = struct {
    /// Low-pass accumulator / high-pass previous output.
    z: f32 = 0,
    /// High-pass previous input.
    prev_in: f32 = 0,
};

/// Precomputed per-block filter setting, so the exp/pow cutoff math runs once
/// per voice per block rather than once per frame.
const FilterCoef = struct {
    mode: enum { off, low, high } = .off,
    a: f32 = 0,
};

/// Resolve `Pad.filter` into a one-pole coefficient. Both directions sweep
/// exponentially (musical, not linear-in-Hz) and both collapse to a bypass at
/// the knob's centre, so the transition through 0 is continuous.
fn filterCoef(f: f32, sr: f64) FilterCoef {
    if (@abs(f) < 0.001 or !std.math.isFinite(f)) return .{};
    const amount: f64 = @min(@abs(f), 1.0);
    const dt = 1.0 / @max(sr, 1.0);
    if (f < 0.0) {
        // 20 kHz (open) down to 200 Hz.
        const fc = 20000.0 * std.math.pow(f64, 200.0 / 20000.0, amount);
        const rc = 1.0 / (2.0 * std.math.pi * fc);
        return .{ .mode = .low, .a = @floatCast(dt / (rc + dt)) };
    }
    // 20 Hz (open) up to 8 kHz.
    const fc = 20.0 * std.math.pow(f64, 8000.0 / 20.0, amount);
    const rc = 1.0 / (2.0 * std.math.pi * fc);
    return .{ .mode = .high, .a = @floatCast(rc / (rc + dt)) };
}

/// One-pole filter step. Bypass returns `x` untouched (and leaves the state
/// alone, so flipping the knob back off costs nothing).
fn filterStep(st: *FilterState, c: FilterCoef, x: f32) f32 {
    switch (c.mode) {
        .off => return x,
        .low => {
            st.z += c.a * (x - st.z);
            return st.z;
        },
        .high => {
            st.z = c.a * (st.z + x - st.prev_in);
            st.prev_in = x;
            return st.z;
        },
    }
}

/// Gated note-off gain: a linear fade over `release_s` starting at the
/// note-off, on top of whatever the amp envelope is already doing. Returns 0
/// once the fade has run out, which the render loops treat as end-of-voice.
fn gateLevel(release_frames: f64, sr: f64, release_s: f32, curve: f32) f32 {
    if (release_frames < 0.0) return 1.0;
    const dur: f64 = @max(@as(f64, @floatCast(release_s)), 0.001);
    const t = release_frames / @max(sr, 1.0);
    if (t >= dur) return 0.0;
    return 1.0 - synth_math.bendShape(@floatCast(t / dur), curve);
}

const StretchState = struct {
    active: bool = false,
    /// Current grain's source-frame anchor.
    cur_src: f64 = 0,
    /// Requested-ratio anchor. Correlation searches around this timeline so
    /// alignment offsets cannot accumulate into duration drift.
    ideal_src: f64 = 0,
    /// Outgoing grain's natural (no-jump) continuation anchor.
    prev_src: f64 = 0,
    has_prev: bool = false,
    /// Output frames produced since the last grain hop.
    out_in_grain: u32 = 0,
    /// Literal output-frame counter since trigger, for envelope timing.
    out_played: f64 = 0,
};

/// Advance a pad's shared per-block LFO phase, gated on `mod_dest != .off`
/// exactly like `renderVoice`'s `mod_val` gate. Call once per block, not per
/// voice - see the callers in Sampler.processBlock/Slicer.processBlock for
/// why (keeps simultaneous voices on the same pad in phase).
pub fn tickModLfo(pad: *Pad, sr: f64) void {
    if (pad.mod_dest != .off) pad.mod_lfo.tick(pad.mod_rate_hz / @as(f32, @floatCast(sr)));
}

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
    const sample_rate = @max(sr, 1.0);

    // ~1ms declick for the waveform this voice interrupted by stealing its
    // slot (see `carryStealTail`). Ahead of every early return below, since a
    // pad with nothing to play still owes the stolen voice its fade-out.
    if (voice.steal_fade > 0.0) {
        const step: f32 = 1.0 / @as(f32, @floatCast(@max(sample_rate * 0.001, 1.0)));
        var j: usize = voice.block_start;
        while (j < frames and voice.steal_fade > 0.0) : (j += 1) {
            buf[j * channels] += voice.steal_tail_l * voice.steal_fade;
            buf[j * channels + 1] += voice.steal_tail_r * voice.steal_fade;
            voice.steal_fade -= step;
        }
        if (voice.steal_fade < 0.0) voice.steal_fade = 0.0;
    }
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

    // The per-pad LFO offsets exactly one of pitch/gain/pan/filter - `.off`
    // (every pad's default) keeps `mod_val` at 0, so every line below is
    // byte-identical to before this modulation existed. `mod_lfo.phase` was
    // already advanced for this block by the owning engine's `processBlock`
    // (mutable access `renderVoice` doesn't have); this only reads it.
    const mod_val: f32 = if (pad.mod_dest == .off) 0.0 else pad.mod_lfo.sample(pad.mod_shape) * pad.mod_depth;

    const semis: f64 = @as(f64, pad.pitch_semitones) + @as(f64, @floatFromInt(voice.tune)) +
        @as(f64, voice.art.fine_cents) / 100.0 +
        (if (pad.mod_dest == .pitch) @as(f64, mod_val) * 12.0 else 0.0);
    const rate: f64 = std.math.pow(f64, 2.0, semis / 12.0);

    // Linear pan: center keeps unity in both channels (matches the prior
    // mono-to-both behaviour at pan = 0). Gain modulation is multiplicative
    // (tremolo dips toward silence rather than going negative); pan
    // modulation is additive, same units as the pad's own `pan`.
    const mod_gain_mult: f32 = if (pad.mod_dest == .gain) std.math.clamp(1.0 + mod_val, 0.0, 2.0) else 1.0;
    const pan_base: f32 = std.math.clamp(pad.pan + voice.art.pan, -1.0, 1.0);
    const mod_pan: f32 = if (pad.mod_dest == .pan) std.math.clamp(pan_base + mod_val, -1.0, 1.0) else pan_base;
    const gl: f32 = pad.gain * mod_gain_mult * voice.vel * @min(1.0, 1.0 - mod_pan);
    const gr: f32 = pad.gain * mod_gain_mult * voice.vel * @min(1.0, 1.0 + mod_pan);

    // WSOLA time-stretch: only when requested and the region holds at least
    // two grains' worth of material - otherwise fall through to the plain
    // path below unchanged (byte-for-byte identical at stretch_ratio == 1.0).
    if (pad.stretch_ratio != 1.0 and region_len >= 2.0 * grainFrames(sample_rate, pad.warp_method)) {
        if (!voice.stretch.active) {
            voice.stretch = .{
                .active = true,
                .cur_src = if (pad.reverse) hi - 1.0 - voice.played else lo + voice.played,
                .ideal_src = if (pad.reverse) hi - 1.0 - voice.played else lo + voice.played,
                .out_played = voice.played / rate,
            };
        }
        renderVoiceStretched(voice, pad, buf, channels, frames, sample_rate, lo, hi, rate, gl, gr);
        return;
    }
    voice.stretch.active = false;

    // Stretched playback (above) never reaches this filter application - a
    // pre-existing gap this modulation inherits rather than fixes.
    const mod_filter: f32 = if (pad.mod_dest == .filter) std.math.clamp(pad.filter + mod_val, -1.0, 1.0) else pad.filter;
    const fc = filterCoef(mod_filter, sample_rate);
    // A loop needs something to end the voice: a note-off (gate play mode) or
    // the sequenced step's own length. A latched one-shot has neither, so it
    // ignores the loop mode rather than ringing forever and hogging a voice
    // slot - see `LoopMode`. `gated` follows, since that release path is what
    // ends a looping voice.
    const loop: LoopMode = if (pad.gate or voice.hold_frames >= 0.0) pad.loop else .off;
    const gated = pad.gate or loop != .off;

    const start = voice.block_start;
    var i: usize = start;
    while (i < frames) : (i += 1) {
        // zig fmt: off
        if (loop == .off and voice.played >= region_len) { voice.active = false; break; }
        // zig fmt: on
        if (gated) releaseAtHold(voice, voice.played / rate);
        const gate_g = if (gated) gateLevel(voice.release_frames, sample_rate, pad.release_s * voice.art.release_scale, pad.env_curve) else 1.0;
        // zig fmt: off
        if (gate_g <= 0.0) { voice.active = false; break; }
        // zig fmt: on

        // Read position within the clip for this voice's progress.
        const pos = loopPos(voice.played, region_len, loop);
        const rp: f64 = if (pad.reverse) (hi - 1.0 - pos) else (lo + pos);
        const s = sampleAt(pad.samples, rp);

        // Envelope (output time): attack/decay/sustain on the body, a
        // release fade over the final `release_s` of the region, and the
        // edit fades - fade-in over elapsed time, fade-out over remaining
        // time - multiplied on top (see the Pad field doc comment).
        // The two remaining-time ramps are end-of-region fades, so a looping
        // voice skips them: it has no region end to fade at (and `left_out`
        // goes negative past the first pass). Its fade-out is `gate_g`, from
        // the note-off that actually ends it.
        const t_out = voice.played / rate / sample_rate;
        const left_out = (region_len - voice.played) / rate / sample_rate;
        const env = adsrLevel(t_out, pad.attack_s, pad.decay_s, pad.sustain, pad.env_curve) *
            curvedRamp(t_out, pad.fade_in_s, pad.fade_curve) *
            (if (loop != .off) 1.0 else releaseLevel(left_out, pad.release_s, pad.env_curve) * curvedRamp(left_out, pad.fade_out_s, pad.fade_curve));

        const v = filterStep(&voice.filt, fc, s * env) * gate_g;
        voice.prev_l = v * gl;
        voice.prev_r = v * gr;
        buf[i * channels] += voice.prev_l;
        buf[i * channels + 1] += voice.prev_r;

        voice.played += rate;
        if (voice.release_frames >= 0.0) voice.release_frames += 1.0;
    }
    voice.block_start = 0;
}

fn grainFrames(sr: f64, method: WarpMethod) f64 {
    const seconds: f64 = if (method == .beats) 0.016 else 0.060;
    return seconds * sr;
}

/// 50%-overlap synthesis hop. Also crossfade length.
fn hopFrames(sr: f64, method: WarpMethod) f64 {
    return grainFrames(sr, method) * 0.5;
}

/// Correlation search radius around nominal jump target.
fn searchRadiusFrames(sr: f64, method: WarpMethod) f64 {
    const seconds: f64 = if (method == .beats) 0.003 else 0.010;
    return seconds * sr;
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
    const ha = hopFrames(sr, pad.warp_method);
    const ha_i: u32 = @intFromFloat(@max(1.0, @round(ha)));
    const search_r = searchRadiusFrames(sr, pad.warp_method);
    const stretch_ratio: f64 = @max(0.01, @as(f64, pad.stretch_ratio));

    const st = &voice.stretch;
    if (st.out_played == 0.0) {
        st.cur_src = if (pad.reverse) hi - 1.0 else lo;
        st.ideal_src = st.cur_src;
    }

    const fc = filterCoef(pad.filter, sr);
    // Same "a loop needs an ending" rule the plain path applies - see
    // `renderVoice`. Ping-pong degrades to a forward loop here: reversing
    // `dir` mid-stream would also have to re-anchor the correlation search
    // against a window it has never seen, the same class of gap this path
    // already has for the tone filter.
    const loop: LoopMode = if (pad.gate or voice.hold_frames >= 0.0) pad.loop else .off;
    const gated = pad.gate or loop != .off;

    const start = voice.block_start;
    var i: usize = start;
    while (i < frames) : (i += 1) {
        // Start a new grain once the current one has played out its hop.
        if (st.out_in_grain >= ha_i) {
            const advance = dir * ha * rate;
            const prev_src = st.cur_src + advance;
            st.ideal_src += advance / stretch_ratio;
            const nominal_src = st.ideal_src;
            st.prev_src = prev_src;
            st.cur_src = searchBestAlign(pad.samples, prev_src, nominal_src, search_r, ha, dir, lo, hi, pad.warp_method, sr);
            st.has_prev = true;
            st.out_in_grain = 0;
        }

        const grain_off = dir * @as(f64, @floatFromInt(st.out_in_grain)) * rate;
        var cur_read = st.cur_src + grain_off;

        // Region exhaustion, derived from the actual read position rather
        // than an accumulated counter - naturally absorbs a grain hop that
        // overshoots the region end.
        var remaining_src: f64 = if (pad.reverse) (cur_read - lo) else (hi - cur_read);
        if (remaining_src <= 0.0) {
            if (loop == .off) {
                voice.active = false;
                break;
            }
            // Restart the region as a fresh grain rather than crossfading
            // across the seam - `prev_src` points past the region end, so
            // the outgoing grain has nothing left to fade from.
            st.cur_src = if (pad.reverse) hi - 1.0 else lo;
            st.ideal_src = st.cur_src;
            st.has_prev = false;
            st.out_in_grain = 0;
            cur_read = st.cur_src;
            remaining_src = if (pad.reverse) (cur_read - lo) else (hi - cur_read);
        }
        if (gated) releaseAtHold(voice, st.out_played);
        const gate_g = if (gated) gateLevel(voice.release_frames, sr, pad.release_s * voice.art.release_scale, pad.env_curve) else 1.0;
        if (gate_g <= 0.0) {
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
        // A looping voice skips the two remaining-time ramps for the reason
        // the plain path's envelope spells out - they fade a region end this
        // voice keeps passing straight through.
        const t_out = st.out_played / sr;
        const left_out = remaining_src * stretch_ratio / rate / sr;
        const env = adsrLevel(t_out, pad.attack_s, pad.decay_s, pad.sustain, pad.env_curve) *
            curvedRamp(t_out, pad.fade_in_s, pad.fade_curve) *
            (if (loop != .off) 1.0 else releaseLevel(left_out, pad.release_s, pad.env_curve) * curvedRamp(left_out, pad.fade_out_s, pad.fade_curve));

        const v = filterStep(&voice.filt, fc, s * env) * gate_g;
        voice.prev_l = v * gl;
        voice.prev_r = v * gr;
        buf[i * channels] += voice.prev_l;
        buf[i * channels + 1] += voice.prev_r;

        st.out_in_grain += 1;
        st.out_played += 1.0;
        if (voice.release_frames >= 0.0) voice.release_frames += 1.0;
        const next_read = st.cur_src + dir * @as(f64, @floatFromInt(st.out_in_grain)) * rate;
        voice.played = if (pad.reverse) hi - 1.0 - next_read else next_read - lo;
    }
    voice.block_start = 0;
}

/// Search `[-search_r, +search_r]` source frames around `nominal_src` for the
/// offset whose `hop`-length window best matches (highest normalized
/// cross-correlation) `prev_src`'s window - i.e. the new grain that continues
/// most smoothly from where the outgoing one left off. Falls back to
/// `nominal_src` unchanged when `search_r` rounds to zero (degenerate sample
/// rate).
/// How much louder a millisecond has to be than the one before it to count as
/// an attack rather than ordinary level movement. 6dB per millisecond: a drum
/// hit clears it easily, a bowed or blown note never does.
const transient_energy_ratio: f64 = 4.0;

/// Position of the sharpest attack inside the search window, or null when
/// nothing in there is one. `beats` puts its grain boundary here so the
/// attack is copied whole rather than spliced through the middle - which is
/// the difference between a beats mode and merely short grains.
///
/// Millisecond buckets and one pass, because this runs per grain hop on the
/// audio thread: at the beats hop that is 125 times a second per voice.
fn findTransient(samples: []const f32, nominal_src: f64, search_r: f64, sr: f64, lo: f64, hi: f64) ?f64 {
    const bucket = @max(1.0, 0.001 * sr);
    const first = @max(lo, nominal_src - search_r - bucket);
    const last = @min(hi - 1.0, nominal_src + search_r);
    if (last - first < bucket * 2.0) return null;

    var best_ratio: f64 = transient_energy_ratio;
    var best_at: ?f64 = null;
    var prev_energy: f64 = -1.0;
    var at = first;
    while (at + bucket <= last) : (at += bucket) {
        var energy: f64 = 0;
        var j: f64 = 0;
        while (j < bucket) : (j += 1) {
            const s: f64 = sampleAt(samples, std.math.clamp(at + j, lo, hi - 1.0));
            energy += s * s;
        }
        if (prev_energy >= 0.0) {
            const ratio = energy / (prev_energy + 1e-12);
            // The boundary between the quiet bucket and the loud one is where
            // the attack starts, so that is where the grain begins.
            if (ratio > best_ratio and at >= nominal_src - search_r) {
                best_ratio = ratio;
                best_at = at;
            }
        }
        prev_energy = energy;
    }
    return best_at;
}

fn searchBestAlign(
    samples: []const f32,
    prev_src: f64,
    nominal_src: f64,
    search_r: f64,
    hop: f64,
    dir: f64,
    lo: f64,
    hi: f64,
    method: WarpMethod,
    sr: f64,
) f64 {
    // Beats snaps to an attack when the window holds one. Forward playback
    // only: reversed, the energy step is the tail of a hit rather than its
    // start, and snapping there would cut the decay instead of protecting
    // anything.
    if (method == .beats and dir > 0.0) {
        if (findTransient(samples, nominal_src, search_r, sr, lo, hi)) |at| {
            return std.math.clamp(at, lo, hi - 1.0);
        }
    }
    const hop_i: usize = @intFromFloat(@max(1.0, @round(hop)));
    const steps: i64 = @intFromFloat(@round(search_r));
    // Long tone windows need half-rate correlation to keep audio-thread cost bounded.
    const stride: usize = if (hop_i >= 1000) 2 else 1;
    if (steps <= 0) return std.math.clamp(nominal_src, lo, hi - 1.0);

    // Normalized cross-correlation, not raw SSD: a decaying/enveloped source
    // (any one-shot with a release) has systematically lower energy further
    // into the clip, which would otherwise bias a magnitude-sensitive error
    // toward whichever candidate happens to match `prev_src`'s amplitude
    // rather than its waveform shape - pulling the stretch back toward the
    // unstretched continuation. Dividing out each window's own energy keeps
    // the search scale-invariant.
    const score = struct {
        fn at(smp: []const f32, prev: f64, cand: f64, len: usize, stride2: usize, direction: f64, lo2: f64, hi2: f64) f64 {
            var dot: f64 = 0.0;
            var ea: f64 = 0.0;
            var eb: f64 = 0.0;
            var j: usize = 0;
            while (j < len) : (j += stride2) {
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
    var best_score = score(samples, prev_src, nominal_src, hop_i, stride, dir, lo, hi);
    var d: i64 = @intCast(stride);
    while (d <= steps) : (d += @intCast(stride)) {
        const cand_neg = nominal_src - @as(f64, @floatFromInt(d));
        const s_neg = score(samples, prev_src, cand_neg, hop_i, stride, dir, lo, hi);
        if (s_neg > best_score + margin) {
            best_score = s_neg;
            best_k = -d;
        }
        const cand_pos = nominal_src + @as(f64, @floatFromInt(d));
        const s_pos = score(samples, prev_src, cand_pos, hop_i, stride, dir, lo, hi);
        if (s_pos > best_score + margin) {
            best_score = s_pos;
            best_k = d;
        }
    }
    return std.math.clamp(nominal_src + @as(f64, @floatFromInt(best_k)), lo, hi - 1.0);
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

/// Catmull-Rom interpolation of `samples` at fractional position `p`, falling
/// back to `sampleAt` where the four-point window would run off an end.
/// Used where a sample plays at a fractional rate for its whole length - a
/// bank kept at its recorded rate never lands on integer positions, and
/// linear interpolation there dulls the top octave audibly.
pub fn sampleAtCubic(samples: []const f32, p: f64) f32 {
    if (p < 1.0) return sampleAt(samples, p);
    const idx: usize = @intFromFloat(p);
    if (idx + 2 >= samples.len) return sampleAt(samples, p);
    const t: f32 = @floatCast(p - @as(f64, @floatFromInt(idx)));
    const p0 = samples[idx - 1];
    const p1 = samples[idx];
    const p2 = samples[idx + 1];
    const p3 = samples[idx + 2];
    const a = 2 * p1;
    const b = p2 - p0;
    const c = 2 * p0 - 5 * p1 + 4 * p2 - p3;
    const d = 3 * (p1 - p2) + p3 - p0;
    return 0.5 * (a + t * (b + t * (c + t * d)));
}

/// Attack → decay → sustain level at output time `t` seconds. With the default
/// params (attack≈0, decay 0, sustain 1) this is unity after the first sample.
fn adsrLevel(t: f64, attack_s: f32, decay_s: f32, sustain: f32, curve: f32) f32 {
    const a: f64 = @floatCast(attack_s);
    const d: f64 = @floatCast(decay_s);
    const sus: f64 = @floatCast(sustain);
    if (a > 0.0 and t < a) return synth_math.bendShape(@floatCast(t / a), curve);
    const td = t - a;
    if (d > 0.0 and td < d) return @floatCast(1.0 - (1.0 - sus) * synth_math.bendShape(@floatCast(td / d), curve));
    return @floatCast(sus);
}

fn releaseLevel(left: f64, duration: f32, curve: f32) f32 {
    const d: f64 = @floatCast(duration);
    if (d <= 0.0 or left >= d) return 1.0;
    if (left <= 0.0) return 0.0;
    return 1.0 - synth_math.bendShape(@floatCast(1.0 - left / d), curve);
}

/// Linear 0→1 gain ramp over the first `dur` seconds of `t`; 1 past it (or
/// when the ramp is off, dur = 0). One shape, three uses: the release fade
/// and the fade-out get remaining output time, the fade-in gets elapsed.
pub fn curvedRamp(t: f64, dur: f32, curve: f32) f32 {
    const d: f64 = @floatCast(dur);
    if (d <= 0.0 or t >= d) return 1.0;
    return synth_math.bendShape(@floatCast(std.math.clamp(t / d, 0.0, 1.0)), curve);
}

test "curved ramp reaches full gain over its duration" {
    try std.testing.expectEqual(@as(f32, 0), curvedRamp(0, 0.2, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), curvedRamp(0.1, 0.2, 0), 1e-6);
    try std.testing.expectEqual(@as(f32, 1), curvedRamp(0.2, 0.2, 0));
    try std.testing.expect(curvedRamp(0.1, 0.2, -0.5) > 0.5);
}

test "pad envelope curve bends every timed stage" {
    try std.testing.expect(adsrLevel(0.25, 1, 1, 0.5, -0.5) > adsrLevel(0.25, 1, 1, 0.5, 0));
    try std.testing.expect(adsrLevel(1.25, 1, 1, 0.5, -0.5) < adsrLevel(1.25, 1, 1, 0.5, 0));
    try std.testing.expect(releaseLevel(0.75, 1, -0.5) < releaseLevel(0.75, 1, 0));
}

// -----------------------------------------------------------------------
// Sample-rate conversion (control-side, allocates)

pub fn decodeWav(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    sample_rate: u32,
) ![]f32 {
    const result = try wav.parseAlloc(allocator, bytes);
    errdefer allocator.free(result.samples);
    if (result.sample_rate == sample_rate) return result.samples;
    const samples = try resample(allocator, result.samples, result.sample_rate, sample_rate);
    allocator.free(result.samples);
    return samples;
}

/// Highest quality speex offers (0-10). This runs once per clip on the
/// control thread, so the cheaper settings buy nothing worth having.
const resample_quality: c_int = 10;

/// Mono rate conversion for a whole clip. Band-limited, because this runs on
/// every 44.1k sample dropped into a 48k project and linear interpolation
/// folds that clip's top octave back down as audible aliasing. A windowed
/// sinc can overshoot the source peak slightly - normal for a resampler, and
/// the pad's own gain staging has room for it.
pub fn resample(
    allocator: std.mem.Allocator,
    src: []const f32,
    src_rate: u32,
    dst_rate: u32,
) ![]f32 {
    if (src_rate == 0 or dst_rate == 0) return error.InvalidSampleRate;
    if (src_rate == dst_rate) return allocator.dupe(f32, src);
    const scaled_len = @as(u128, src.len) * dst_rate;
    const dst_len_u128 = (scaled_len + src_rate - 1) / src_rate;
    if (dst_len_u128 > std.math.maxInt(usize)) return error.OutputTooLarge;
    const dst_len: usize = @intCast(dst_len_u128);
    if (src.len > std.math.maxInt(u32) or dst_len > std.math.maxInt(u32)) return error.OutputTooLarge;
    const out = try allocator.alloc(f32, dst_len);
    errdefer allocator.free(out);
    if (src.len == 0) {
        @memset(out, 0.0);
        return out;
    }

    var err: c_int = 0;
    const state = speex.speex_resampler_init(1, src_rate, dst_rate, resample_quality, &err) orelse
        return error.ResampleFailed;
    defer speex.speex_resampler_destroy(state);
    if (err != 0) return error.ResampleFailed;
    // Primes the filter's history so output frame 0 lines up with input frame
    // 0. Without it every loaded sample starts a few frames late, which shows
    // up as a clip whose transient has drifted off the grid it was cut to.
    if (speex.speex_resampler_skip_zeros(state) != 0) return error.ResampleFailed;

    var in_len: c_uint = @intCast(src.len);
    var out_len: c_uint = @intCast(dst_len);
    if (speex.speex_resampler_process_float(state, 0, src.ptr, &in_len, out.ptr, &out_len) != 0)
        return error.ResampleFailed;
    // The converter stops a frame or two short of the rounded-up length.
    const generated: usize = out_len;
    if (generated < dst_len) @memset(out[generated..], 0.0);
    return out;
}

// -----------------------------------------------------------------------
// Tests

test "cubic sample read tracks a sine closer than linear and stays in range" {
    // A 44.1k-recorded sine read back at the 48k playback ratio: exactly what
    // a bundled bank does now that it is no longer resampled at load.
    const rate = 44_100.0;
    const hz = 6_000.0;
    var src: [512]f32 = undefined;
    for (&src, 0..) |*s, i| s.* = @floatCast(@sin(2.0 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / rate));
    var cubic_err: f64 = 0;
    var linear_err: f64 = 0;
    var p: f64 = 1.0;
    while (p < 500.0) : (p += 44_100.0 / 48_000.0) {
        const want = @sin(2.0 * std.math.pi * hz * p / rate);
        cubic_err += @abs(want - sampleAtCubic(&src, p));
        linear_err += @abs(want - sampleAt(&src, p));
        try std.testing.expect(@abs(sampleAtCubic(&src, p)) <= 1.05);
    }
    try std.testing.expect(cubic_err * 4 < linear_err);
}

test "resample preserves amplitude" {
    const src = [_]f32{ 0.0, 0.5, 1.0, 0.5, 0.0 };
    const out = try resample(std.testing.allocator, &src, 44_100, 48_000);
    defer std.testing.allocator.free(out);
    // Output should be longer and all values in [-1, 1]
    try std.testing.expect(out.len > src.len);
    for (out) |s| try std.testing.expect(@abs(s) <= 1.0 + 1e-6);
}

test "resample band-limits instead of folding the top octave down" {
    // 20kHz at 48k has nowhere to go in a 16k stream (8k Nyquist): a
    // band-limited converter throws it away, linear interpolation folds it
    // back in near full scale. This is the whole reason for the C dependency.
    var src: [4800]f32 = undefined;
    for (&src, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        s.* = std.math.sin(2.0 * std.math.pi * 20_000.0 * t);
    }
    const out = try resample(std.testing.allocator, &src, 48_000, 16_000);
    defer std.testing.allocator.free(out);

    var sum_sq: f64 = 0;
    for (out) |s| sum_sq += @as(f64, s) * @as(f64, s);
    const rms = std.math.sqrt(sum_sq / @as(f64, @floatFromInt(out.len)));
    try std.testing.expect(rms < 0.1);
}

test "resample validates rates and rounds output length up" {
    try std.testing.expectError(
        error.InvalidSampleRate,
        resample(std.testing.allocator, &.{1.0}, 0, 48_000),
    );
    try std.testing.expectError(
        error.InvalidSampleRate,
        resample(std.testing.allocator, &.{1.0}, 48_000, 0),
    );

    const out = try resample(std.testing.allocator, &.{ 0.0, 0.5, 1.0 }, 2, 3);
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

test "renderVoice keeps zero-rate plain and stretched output finite" {
    var samples = [_]f32{1.0} ** 64;
    for ([_]f32{ 1.0, 2.0 }) |stretch_ratio| {
        const p = Pad{ .samples = &samples, .stretch_ratio = stretch_ratio };
        var voice = Voice{ .active = true };
        var buf = [_]Sample{0.0} ** 32;
        renderVoice(&voice, &p, &buf, 2, 16, 0.0);
        for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
    }
}

test "renderVoice keeps its cursor when stretch changes during playback" {
    var samples: [100]f32 = undefined;
    for (&samples, 0..) |*sample, i| sample.* = @floatFromInt(i);
    var p = Pad{ .samples = &samples, .attack_s = 0.0, .release_s = 0.001 };
    var voice = Voice{ .active = true };
    var buf = [_]Sample{0.0} ** 20;

    renderVoice(&voice, &p, &buf, 2, 5, 1000.0);
    p.stretch_ratio = 2.0;
    renderVoice(&voice, &p, &buf, 2, 5, 1000.0);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), buf[0], 1e-6);

    @memset(&buf, 0.0);
    p.stretch_ratio = 1.0;
    renderVoice(&voice, &p, &buf, 2, 5, 1000.0);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), buf[0], 1e-6);
}

test "WSOLA alignment stays inside the trimmed sample region" {
    const samples = [_]f32{0.0} ** 100;
    try std.testing.expectEqual(@as(f64, 20.0), searchBestAlign(&samples, 30.0, -10.0, 2.0, 10.0, 1.0, 20.0, 80.0, .tones, 48_000.0));
    try std.testing.expectEqual(@as(f64, 79.0), searchBestAlign(&samples, 30.0, 100.0, 2.0, 10.0, 1.0, 20.0, 80.0, .tones, 48_000.0));
}

test "the per-pad LFO offsets exactly the field mod_dest names; .off changes nothing" {
    const testing = std.testing;
    var samples = [_]f32{1.0} ** 200; // DC at unity

    const neutral = Pad{ .samples = &samples, .attack_s = 0.0, .release_s = 0.001 };
    var neutral_voice = Voice{ .active = true };
    var neutral_buf = [_]Sample{0.0} ** 400;
    renderVoice(&neutral_voice, &neutral, &neutral_buf, 2, 200, 1000.0);

    // Garbage-filled mod fields, but .off: must render identically to the
    // untouched pad above - the destination switch, not the fields
    // themselves, is what gates modulation.
    const off = Pad{
        .samples = &samples,
        .attack_s = 0.0,
        .release_s = 0.001,
        .mod_lfo = .{ .phase = 0.25 },
        .mod_depth = 1.0,
        .mod_dest = .off,
    };
    var off_voice = Voice{ .active = true };
    var off_buf = [_]Sample{0.0} ** 400;
    renderVoice(&off_voice, &off, &off_buf, 2, 200, 1000.0);
    try testing.expectEqualSlices(Sample, &neutral_buf, &off_buf);

    // Gain dest: phase 0.25 -> sine 1.0 -> mod_gain_mult clamps to 2.0, so
    // the block renders at exactly double the neutral gain.
    const gained = Pad{
        .samples = &samples,
        .attack_s = 0.0,
        .release_s = 0.001,
        .mod_lfo = .{ .phase = 0.25 },
        .mod_depth = 1.0,
        .mod_dest = .gain,
    };
    var gained_voice = Voice{ .active = true };
    var gained_buf = [_]Sample{0.0} ** 400;
    renderVoice(&gained_voice, &gained, &gained_buf, 2, 200, 1000.0);
    try testing.expectApproxEqAbs(neutral_buf[100 * 2] * 2.0, gained_buf[100 * 2], 0.02);

    // Filter dest: phase 0.25 -> offset +1.0, pushing the bipolar filter to
    // its high-pass extreme - a steady DC input decays toward zero instead
    // of holding at unity like the unfiltered neutral render.
    const filtered = Pad{
        .samples = &samples,
        .attack_s = 0.0,
        .release_s = 0.001,
        .mod_lfo = .{ .phase = 0.25 },
        .mod_depth = 1.0,
        .mod_dest = .filter,
    };
    var filtered_voice = Voice{ .active = true };
    var filtered_buf = [_]Sample{0.0} ** 400;
    renderVoice(&filtered_voice, &filtered, &filtered_buf, 2, 200, 1000.0);
    try testing.expect(@abs(filtered_buf[190 * 2]) < 0.5);
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
        // Toggles and perceptually-scaled time controls do not use additive
        // `paramStep`; each gets focused assertions below.
        if (raw_id == reverse_id or raw_id == gate_id or raw_id == 3 or raw_id == 4 or raw_id == 6 or raw_id == 10 or raw_id == 11 or raw_id == mod_shape_id or raw_id == mod_dest_id or raw_id == loop_id or raw_id == warp_method_id) continue;
        const id: u8 = @intCast(raw_id);
        var nudged = initial;
        var assigned = initial;
        adjustParam(&nudged, id, 3);
        setParamAbsolute(&assigned, id, paramValue(&initial, id).? + 3.0 * paramStep(id));
        try testing.expectApproxEqAbs(paramValue(&assigned, id).?, paramValue(&nudged, id).?, 1e-6);
    }

    // Starts on `tones` (the default), so a nudge either way lands on beats
    // and comes back.
    var method = initial;
    adjustParam(&method, warp_method_id, 1);
    try testing.expectEqual(WarpMethod.beats, method.warp_method);
    adjustParam(&method, warp_method_id, -1);
    try testing.expectEqual(WarpMethod.tones, method.warp_method);

    var toggled = initial;
    adjustParam(&toggled, reverse_id, 1);
    try testing.expect(toggled.reverse);
    adjustParam(&toggled, reverse_id, 0);
    try testing.expect(toggled.reverse);

    // Play mode is a three-way cycle, not a toggle, and it wraps both ways.
    adjustParam(&toggled, gate_id, 1);
    try testing.expectEqual(PlayMode.gate, playMode(&toggled));
    adjustParam(&toggled, gate_id, 0);
    try testing.expectEqual(PlayMode.gate, playMode(&toggled));
    adjustParam(&toggled, gate_id, 1);
    try testing.expectEqual(PlayMode.retrigger, playMode(&toggled));
    adjustParam(&toggled, gate_id, 1);
    try testing.expectEqual(PlayMode.one_shot, playMode(&toggled));
    adjustParam(&toggled, gate_id, -1);
    try testing.expectEqual(PlayMode.retrigger, playMode(&toggled));
    // An absolute write round-trips through paramValue for every mode.
    for (0..play_mode_names.len) |i| {
        setParamAbsolute(&toggled, gate_id, @floatFromInt(i));
        try testing.expectEqual(@as(f32, @floatFromInt(i)), paramValue(&toggled, gate_id).?);
    }
}

test "time nudges expand short envelope and fade values" {
    var pad: Pad = .{ .samples = &.{} };
    pad.attack_s = 0.005;
    pad.release_s = 0.005;
    adjustParam(&pad, 3, 1);
    adjustParam(&pad, 6, 12);
    try std.testing.expect(pad.attack_s > 0.016 and pad.attack_s < 0.018);
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), pad.release_s, 1e-6);
}

test "the tone filter bypasses at centre and cuts on either side" {
    const sr = 48_000.0;
    // Centre: byte-identical passthrough, state untouched.
    var st: FilterState = .{};
    const off = filterCoef(0.0, sr);
    try std.testing.expectEqual(@as(f32, 0.7), filterStep(&st, off, 0.7));

    // A hard low-pass can't jump to full scale in one sample (it ramps);
    // a hard high-pass strips DC, so a constant input decays toward zero.
    var lp_st: FilterState = .{};
    const lp = filterCoef(-1.0, sr);
    try std.testing.expect(filterStep(&lp_st, lp, 1.0) < 0.5);

    var hp_st: FilterState = .{};
    const hp = filterCoef(1.0, sr);
    const first = filterStep(&hp_st, hp, 1.0);
    var i: usize = 0;
    while (i < 4800) : (i += 1) _ = filterStep(&hp_st, hp, 1.0);
    try std.testing.expect(@abs(filterStep(&hp_st, hp, 1.0)) < first * 0.5);
}

test "a gated voice stops at its release time instead of the region end" {
    var samples = [_]f32{0.5} ** 48_000;
    var pad: Pad = .{ .samples = &samples, .gate = true, .release_s = 0.01 };
    var voice: Voice = .{ .active = true };
    var buf = [_]Sample{0} ** 512;

    // Held: still ringing after a block.
    renderVoice(&voice, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(voice.active);

    // Released: gone within the 10 ms release (480 frames), well before the
    // clip's own 1 s region end.
    release(&voice);
    var blocks: usize = 0;
    while (voice.active and blocks < 8) : (blocks += 1) {
        renderVoice(&voice, &pad, &buf, 2, 256, 48_000.0);
    }
    try std.testing.expect(!voice.active);

    // The same pad with gate off ignores the release entirely.
    pad.gate = false;
    var latched: Voice = .{ .active = true };
    release(&latched);
    blocks = 0;
    while (blocks < 8) : (blocks += 1) {
        renderVoice(&latched, &pad, &buf, 2, 256, 48_000.0);
    }
    try std.testing.expect(latched.active);
}

test "hold_frames releases a gated voice on its own, and only a gated one" {
    var samples = [_]f32{0.5} ** 48_000;
    var pad: Pad = .{ .samples = &samples, .gate = true, .release_s = 0.01 };
    // A 256-frame hold: still held after one block, released after two, and
    // gone once the 10 ms (480-frame) fade past that has run out.
    var voice: Voice = .{ .active = true, .hold_frames = 256 };
    var buf = [_]Sample{0} ** 512;

    renderVoice(&voice, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(voice.release_frames < 0.0);
    renderVoice(&voice, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(voice.release_frames >= 0.0);
    var blocks: usize = 0;
    while (voice.active and blocks < 8) : (blocks += 1) {
        renderVoice(&voice, &pad, &buf, 2, 256, 48_000.0);
    }
    try std.testing.expect(!voice.active);

    // A latched one-shot carrying the same hold plays its region out.
    pad.gate = false;
    var latched: Voice = .{ .active = true, .hold_frames = 256 };
    blocks = 0;
    while (blocks < 8) : (blocks += 1) {
        renderVoice(&latched, &pad, &buf, 2, 256, 48_000.0);
    }
    try std.testing.expect(latched.active);
    try std.testing.expect(latched.release_frames < 0.0);
}

test "a loop replays the region only while something can end the voice" {
    var samples = [_]f32{0.5} ** 4_800;
    var buf = [_]Sample{0} ** 512;

    // Gated + forward loop: still running well past one pass of the region
    // (4800 frames = 19 blocks at this rate), and still audible rather than
    // sitting in an end-of-region fade.
    var pad: Pad = .{ .samples = &samples, .gate = true, .loop = .forward, .release_s = 0.01 };
    var voice: Voice = .{ .active = true };
    var blocks: usize = 0;
    while (blocks < 40) : (blocks += 1) renderVoice(&voice, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(voice.active);
    try std.testing.expect(voice.played > 4_800.0);
    @memset(&buf, 0);
    renderVoice(&voice, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(@abs(buf[0]) > 0.1);

    // The same pad without the loop: one pass and done.
    pad.loop = .off;
    var once: Voice = .{ .active = true };
    blocks = 0;
    while (blocks < 40) : (blocks += 1) renderVoice(&once, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(!once.active);

    // A latched one-shot has no note-off and no step length, so the loop is
    // ignored rather than ringing forever - the same call `gate` makes.
    pad.loop = .ping_pong;
    pad.gate = false;
    var latched: Voice = .{ .active = true };
    blocks = 0;
    while (blocks < 40) : (blocks += 1) renderVoice(&latched, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(!latched.active);

    // ...but the same latched pad on a sequencer step loops for the step's
    // own length, then releases on its own.
    var stepped: Voice = .{ .active = true, .hold_frames = 9_600 };
    blocks = 0;
    while (blocks < 30) : (blocks += 1) renderVoice(&stepped, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(stepped.active); // 7680 frames in: past one pass, still held
    try std.testing.expect(stepped.played > 4_800.0);
    while (stepped.active and blocks < 80) : (blocks += 1) renderVoice(&stepped, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(!stepped.active);

    // Time-stretched playback loops too (ping-pong degrades to forward there).
    pad.stretch_ratio = 2.0;
    pad.gate = true;
    var stretched: Voice = .{ .active = true };
    blocks = 0;
    while (blocks < 60) : (blocks += 1) renderVoice(&stretched, &pad, &buf, 2, 256, 48_000.0);
    try std.testing.expect(stretched.active);
}

test "beats grains start on an attack instead of splicing through it" {
    const sr: f64 = 48_000;
    var samples = [_]f32{0.0} ** 4800;
    // A hit at frame 2400: silence, then a loud burst.
    for (samples[2400..2600], 0..) |*s, i| {
        const d = @as(f32, @floatFromInt(i)) / 200.0;
        s.* = @exp(-d * 6.0) * @sin(@as(f32, @floatFromInt(i)) * 0.4);
    }

    // A nominal target 1ms before the hit, with the hit inside the search
    // window: beats snaps forward onto it, tones follows its correlation.
    const nominal = 2352.0;
    const search_r = 0.003 * sr;
    const snapped = searchBestAlign(&samples, 1000.0, nominal, search_r, 0.016 * sr, 1.0, 0.0, @floatFromInt(samples.len), .beats, sr);
    try std.testing.expectApproxEqAbs(@as(f64, 2400.0), snapped, 48.0);

    // Nothing to snap to in a window with no attack: the correlation search
    // decides, as before.
    const flat = searchBestAlign(&samples, 1000.0, 600.0, search_r, 0.016 * sr, 1.0, 0.0, @floatFromInt(samples.len), .beats, sr);
    try std.testing.expect(@abs(flat - 600.0) <= search_r);
}

test "a stolen voice's tail fades out under the voice that took its slot" {
    const testing = std.testing;
    var samples = [_]f32{1.0} ** 1000;
    const p = Pad{ .samples = &samples, .attack_s = 0.0, .release_s = 0.001 };

    // Run one voice to leave it mid-waveform at unity, then hand its slot to
    // a fresh voice the way Sampler/Slicer stealing does.
    var stolen = Voice{ .active = true };
    var buf = [_]Sample{0.0} ** 2000;
    renderVoice(&stolen, &p, &buf, 2, 1000, 1000.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), stolen.prev_l, 0.02);

    var fresh = Voice{ .active = true };
    carryStealTail(&fresh, stolen);
    try testing.expectApproxEqAbs(@as(f32, 1.0), fresh.steal_fade, 1e-6);

    // 1ms of fade at 1kHz is a single frame: the tail lands on the first
    // frame on top of the new voice's own output, and nothing after it.
    var steal_buf = [_]Sample{0.0} ** 2000;
    renderVoice(&fresh, &p, &steal_buf, 2, 1000, 1000.0);
    try testing.expectApproxEqAbs(@as(f32, 2.0), steal_buf[0], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 1.0), steal_buf[2], 0.02);
    try testing.expectEqual(@as(f32, 0), fresh.steal_fade);

    // A free slot carries nothing, so an untouched voice renders as before.
    var untouched = Voice{ .active = true };
    carryStealTail(&untouched, .{});
    try testing.expectEqual(@as(f32, 0), untouched.steal_fade);
}

//! Pure math helpers for PolySynth's oscillator/envelope/filter/unison/LFO
//! DSP: no `self`, no audio-thread state beyond what's passed in. Split out
//! of synth.zig because these have zero coupling to PolySynth's own fields -
//! synth.zig keeps a file-scope alias for each name (e.g. `const diodeClip =
//! synth_math.diodeClip;`) so its ~30 internal bare call sites (`diodeClip(...)`,
//! `nextNoise(...)`, etc., called from inside PolySynth's own methods) keep
//! resolving unchanged: Zig looks up an unqualified identifier through the
//! enclosing file scope when it isn't a sibling declaration of the struct
//! the caller is nested in.

const std = @import("std");
const types = @import("../core/types.zig");
const synth = @import("synth.zig");
const PolySynth = synth.PolySynth;
const Waveform = synth.Waveform;
const UnisonMode = synth.UnisonMode;
const WarpMode = synth.WarpMode;
const Stage = PolySynth.Stage;
const ChaosState = PolySynth.ChaosState;
const max_unison = PolySynth.max_unison;

const Sample = types.Sample;

// Classic Lorenz parameters (butterfly attractor). x/y roughly range
// ±20 for these constants, hence the /20 normalization in PolySynth.lfoVal.
const lorenz_sigma: f32 = 10.0;
const lorenz_rho: f32 = 28.0;
const lorenz_beta: f32 = 8.0 / 3.0;

/// Euler-integrates the Lorenz system by `dt_total`, split into
/// substeps bounded to `max_step` (Euler-stable for this system) and
/// capped at `max_substeps` so a large block/rate combination can't
/// spend unbounded time on the audio thread - it just under-integrates
/// instead, which is inaudible for a modulation source.
pub fn advanceChaos(state: *ChaosState, dt_total: f32) void {
    const max_step: f32 = 0.005;
    const max_substeps: u32 = 32;
    var remaining = @min(dt_total, max_step * @as(f32, @floatFromInt(max_substeps)));
    while (remaining > 0.0) {
        const step = @min(remaining, max_step);
        const dx = lorenz_sigma * (state.y - state.x);
        const dy = state.x * (lorenz_rho - state.z) - state.y;
        const dz = state.x * state.y - lorenz_beta * state.z;
        state.x += dx * step;
        state.y += dy * step;
        state.z += dz * step;
        remaining -= step;
    }
}

/// Cents offset of unison voice `ui` of `n` (n > 1), per `mode`.
/// spread: symmetric, total width across the outermost voices = `detune`.
/// step: each voice offset by a full `detune`-cent step from its neighbor.
/// harmonic/ratio: voice ui aims at the (ui+1)-th entry of the integer /
/// half-integer harmonic series, scaled by `detune`/100 so the knob morphs
/// from plain unison (0) to the exact series (100). Voice 0 always stays
/// on the fundamental.
pub fn unisonSpreadCents(mode: UnisonMode, ui: usize, n: usize, detune: f32) f32 {
    const ui_f: f32 = @floatFromInt(ui);
    return switch (mode) {
        .spread => blk: {
            const t = ui_f / @as(f32, @floatFromInt(n - 1));
            break :blk (t * 2.0 - 1.0) * detune * 0.5;
        },
        .step => (ui_f - @as(f32, @floatFromInt(n - 1)) * 0.5) * detune,
        .harmonic => 1200.0 * std.math.log2(1.0 + ui_f) * (detune / 100.0),
        .ratio => 1200.0 * std.math.log2(1.0 + 0.5 * ui_f) * (detune / 100.0),
    };
}

/// Constant-power, √2-compensated pan gains for `n` unison voices spread
/// across `spread` (see `unison_spread`) - shared setup for oscillators
/// A/B/C's per-voice pan arrays, which differ only in unison count and
/// which oscillator's arrays they write into. spread=0 (or n<=1) gives
/// the same per-channel amplitude as the original mono path.
pub fn computeUnisonPan(n: usize, spread: f32, pan_l: *[max_unison]f32, pan_r: *[max_unison]f32) void {
    for (0..n) |ui| {
        const raw: f32 = if (n > 1 and spread > 0.0)
            ((@as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(n - 1))) * 2.0 - 1.0) * spread
        else
            0.0;
        const g = panGains(raw);
        pan_l[ui] = g[0];
        pan_r[ui] = g[1];
    }
}

/// One source's `{left, right}` gains at `raw` (-1 hard left .. +1 hard
/// right). Constant power, √2-compensated so centre is unity in both
/// channels rather than -3 dB - the law `computeUnisonPan` has always used,
/// pulled out so a per-note pan lands the same way a spread voice does
/// instead of introducing a second pan law inside one instrument.
pub fn panGains(raw: f32) [2]f32 {
    const angle = (std.math.clamp(raw, -1.0, 1.0) + 1.0) * std.math.pi * 0.25;
    return .{ std.math.sqrt2 * @cos(angle), std.math.sqrt2 * @sin(angle) };
}

test "panGains: centre is unity, ends are constant power" {
    const c = panGains(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c[1], 1e-6);

    const l = panGains(-1.0);
    try std.testing.expectApproxEqAbs(std.math.sqrt2, l[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), l[1], 1e-6);

    // Power is conserved across the sweep: l² + r² holds at 2.
    for ([_]f32{ -1.0, -0.5, 0.0, 0.37, 1.0 }) |p| {
        const g = panGains(p);
        try std.testing.expectApproxEqAbs(@as(f32, 2.0), g[0] * g[0] + g[1] * g[1], 1e-5);
    }
    // Out-of-range input clamps instead of wrapping past hard left/right.
    try std.testing.expectEqual(panGains(1.0), panGains(9.0));
}

/// Advances one ADSR generator by one sample - shared body of the amp,
/// filter, and env3 envelopes (`Voice.stage`/`env`, `stage2`/`env2`,
/// `stage3`/`env3`), which differ only in which stage/level pair and
/// per-stage increments they're driven by. Returns true once `level`
/// has decayed to zero during release; the amp-envelope caller uses
/// that to kill the whole voice, while filter/env3 just let `level`
/// stay parked at zero (this function's own floor already handles it).
pub fn advanceEnv(stage: *Stage, level: *f32, sustain_v: f32, sh: EnvShape) bool {
    switch (stage.*) {
        .attack => {
            if (sh.curve < 0.0)
                level.* += (1.0 + sh.ov - level.*) * sh.ka
            else if (sh.curve > 0.0)
                level.* += (level.* + sh.ov) * sh.ka
            else
                level.* += sh.attack;
            if (level.* >= 1.0) {
                level.* = 1.0;
                stage.* = .decay;
            }
        },
        .decay => {
            if (sh.curve < 0.0)
                level.* += (sustain_v - (1.0 - sustain_v) * sh.ov - level.*) * sh.kd
            else if (sh.curve > 0.0)
                level.* -= (1.0 - level.* + (1.0 - sustain_v) * sh.ov) * sh.kd
            else
                level.* -= sh.decay;
            if (level.* <= sustain_v) {
                level.* = sustain_v;
                stage.* = .sustain;
            }
        },
        .sustain => {},
        .release => {
            if (sh.curve < 0.0)
                level.* -= (level.* + sh.ov) * sh.kr
            else if (sh.curve > 0.0)
                level.* -= (1.0 - level.* + sh.ov) * sh.kr
            else
                level.* -= sh.release;
            if (level.* <= 0.0) {
                level.* = 0.0;
                return true;
            }
        },
    }
    return false;
}

/// Per-sample driving terms for one ADSR's three segments.
const EnvShape = struct {
    attack: f32,
    decay: f32,
    release: f32,
    curve: f32 = 0.0,
    ka: f32 = 0.0,
    kd: f32 = 0.0,
    kr: f32 = 0.0,
    ov: f32 = 0.0,
};

pub fn envShape(attack_inc: f32, decay_inc: f32, release_inc: f32, sustain_v: f32, curve: f32) EnvShape {
    var out: EnvShape = .{ .attack = attack_inc, .decay = decay_inc, .release = release_inc };
    const c = std.math.clamp(curve, -1.0, 1.0);
    if (!(c < 0.0 or c > 0.0)) return out;
    const r = std.math.pow(f32, 0.01, @abs(c));
    const span = 1.0 - sustain_v;
    const decay_step = if (span > 1e-6) decay_inc / span else decay_inc;
    out.curve = c;
    out.ov = r / (1.0 - r);
    if (c < 0.0) {
        out.ka = 1.0 - std.math.pow(f32, r, attack_inc);
        out.kd = 1.0 - std.math.pow(f32, r, decay_step);
        out.kr = 1.0 - std.math.pow(f32, r, release_inc);
    } else {
        out.ka = std.math.pow(f32, r, -attack_inc) - 1.0;
        out.kd = std.math.pow(f32, r, -decay_step) - 1.0;
        out.kr = std.math.pow(f32, r, -release_inc) - 1.0;
    }
    return out;
}

/// Asymmetric soft clip approximating a diode pair's forward-conduction
/// curve: compresses positive swings harder than negative ones. Used by
/// .diode instead of .ladder's symmetric tanh.
pub fn diodeClip(x: f32) f32 {
    return if (x >= 0.0) x / (1.0 + 0.5 * x) else std.math.tanh(x);
}

/// One sample through a Chamberlin state-variable bandpass tuned to
/// `f` (SVF frequency coefficient, from svfCoeff) with damping `damp`
/// (1/Q). `s_lp`/`s_bp` are the resonator's own persistent 2-state
/// history.
pub fn svfBandpass(f: f32, damp: f32, s_lp: *f32, s_bp: *f32, x: f32) f32 {
    s_lp.* += f * s_bp.*;
    const hp = x - s_lp.* - damp * s_bp.*;
    s_bp.* += f * hp;
    return s_bp.*;
}

/// Xorshift32 white noise, returns [-1, 1).
pub fn nextNoise(state: *u32) f32 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 17;
    state.* ^= state.* << 5;
    const i: i32 = @bitCast(state.*);
    return @as(f32, @floatFromInt(i)) * (1.0 / 2147483648.0);
}

/// Scales a drawn LFO segment's -1..1 bend into the exponent of `bendShape`.
/// Picked so a bend of ±0.25 bows a segment into exactly a quarter of a sine
/// at its midpoint (2 * ln(sqrt(2) - 1) = -1.76275, times four) - that is what
/// `synth.lfoWave(.sine)` leans on to rebuild a sine out of four segments.
pub const lfo_bend_scale: f32 = 7.051;

/// Shapes `t` (0..1 progress across one segment of a drawn LFO shape) by that
/// segment's `curve`: 0 is a straight ramp, negative bows the value up early
/// (fast then flat), positive holds it back (flat then fast).
pub fn bendShape(t: f32, curve: f32) f32 {
    const c = std.math.clamp(curve, -1.0, 1.0);
    if (c == 0.0) return t;
    const k = c * lfo_bend_scale;
    return (@exp(k * t) - 1.0) / (@exp(k) - 1.0);
}

/// Wraps `cur` one variant forward (steps > 0) or backward - every
/// `.cycle` `ParamSpec` kind below (and the mod matrix's source
/// stepping) shares this instead of a bespoke forward/backward switch
/// pair per enum: all of those pairs already reduced to a declaration-
/// order wrap once written out, this just does that generically.
pub fn cycleEnum(comptime E: type, cur: E, steps: i32) E {
    const n: i32 = @typeInfo(E).@"enum".fields.len;
    const dir: i32 = if (steps > 0) 1 else -1;
    const ord: i32 = @intFromEnum(cur);
    return @enumFromInt(@as(u8, @intCast(@mod(ord + dir, n))));
}

/// The per-sample step *in warped phase*, which is what `polyBlep` has to
/// size its window against - warping stretches part of the cycle and
/// compresses the rest, so the raw oscillator increment is the wrong
/// scale everywhere but `.none`. Taken as the actual one-sample
/// difference rather than by hand-differentiating each mode, since
/// `.bend`/`.mirror` are piecewise and `.sync` wraps.
///
/// `.mirror` runs the phase *backwards* past its pivot, and a `.sync`
/// wrap at a high multiplier can outrun the window; both land outside a
/// sane step and fall back to the unwarped increment (undercorrecting
/// there rather than injecting a residual at the wrong width).
pub fn warpedInc(mode: WarpMode, phase: f32, inc: f32, amount: f32, warped: f32) f32 {
    if (mode == .none) return inc;
    var d = warpPhase(mode, phase + inc, amount) - warped;
    d -= @floor(d);
    return if (d > 0.0 and d < 0.25) d else inc;
}

/// Remap a read phase before waveform lookup. Keep normalization here as
/// a last audio-thread boundary: extreme pitch/FM can advance by more
/// than one cycle, while malformed runtime state must not produce NaNs.
pub fn warpPhase(mode: WarpMode, phase: f32, amount: f32) f32 {
    const p = if (std.math.isFinite(phase)) phase - @floor(phase) else 0.0;
    const a = if (std.math.isFinite(amount)) std.math.clamp(amount, 0.0, 1.0) else 0.0;
    return switch (mode) {
        .none => p,
        // Pivot the ramp: one side of the cycle covers more phase than
        // the other, same trick classic phase-distortion synths use.
        .bend => blk: {
            const pivot = 0.5 + a * 0.49;
            break :blk if (p < pivot)
                p / pivot * 0.5
            else
                0.5 + (p - pivot) / (1.0 - pivot) * 0.5;
        },
        // Fold the tail of the cycle back on itself instead of letting
        // it run forward past the pivot.
        .mirror => blk: {
            if (a == 0.0) break :blk p;
            const pivot = 1.0 - a * 0.5;
            break :blk if (p < pivot)
                p
            else
                pivot - (p - pivot) / (1.0 - pivot) * pivot;
        },
        // Multiply-and-wrap: each sub-cycle restarts at 0 in lockstep
        // with the fundamental, giving a hard-sync-like buzz with no
        // second phase accumulator needed.
        .sync => blk: {
            const warped = p * (1.0 + a * 7.0);
            break :blk warped - @floor(warped);
        },
    };
}

/// Two-sample polynomial correction around a unit step discontinuity.
pub fn polyBlep(t: f32, dt: f32) f32 {
    if (!(dt > 0.0) or dt >= 0.5) return 0.0;
    if (t < dt) {
        const x = t / dt;
        return x + x - x * x - 1.0;
    }
    if (t > 1.0 - dt) {
        const x = (t - 1.0) / dt;
        return x * x + x + x + 1.0;
    }
    return 0.0;
}

/// Convert frequency to cycles per sample, capped at Nyquist. Above-Nyquist
/// phase motion cannot represent a distinct oscillator and only aliases.
pub fn phaseInc(freq: f32, sample_rate: f32) f32 {
    if (!(freq > 0.0) or !(sample_rate > 0.0)) return 0.0;
    return @min(freq / sample_rate, 0.5);
}

/// Apply an audio-rate FM multiplier without letting final phase motion
/// outrun Nyquist. Negative values retain through-zero FM direction.
pub fn modulatedPhaseInc(base: f32, multiplier: f32) f32 {
    const inc = base * multiplier;
    if (!std.math.isFinite(inc)) return 0.0;
    return std.math.clamp(inc, -0.5, 0.5);
}

test "phaseInc caps oscillator motion at Nyquist" {
    try std.testing.expectEqual(@as(f32, 0.25), phaseInc(12_000.0, 48_000.0));
    try std.testing.expectEqual(@as(f32, 0.5), phaseInc(96_000.0, 48_000.0));
    try std.testing.expectEqual(@as(f32, 0.0), phaseInc(std.math.nan(f32), 48_000.0));
}

test "modulatedPhaseInc caps both FM directions" {
    try std.testing.expectEqual(@as(f32, 0.5), modulatedPhaseInc(0.25, 8.0));
    try std.testing.expectEqual(@as(f32, -0.5), modulatedPhaseInc(0.25, -8.0));
    try std.testing.expectEqual(@as(f32, 0.0), modulatedPhaseInc(0.25, std.math.nan(f32)));
}

/// `dt` sizes polyBLEP correction for saw and square discontinuities.
pub fn oscWave(wf: Waveform, phase: f32, pw: f32, dt: f32) Sample {
    const step = @abs(dt);
    return switch (wf) {
        // zig fmt: off
        .sine     => @sin(2.0 * std.math.pi * phase),
        .saw      => 2.0 * phase - 1.0 - polyBlep(phase, step),
        .triangle => 1.0 - 4.0 * @abs(phase - 0.5),
        // Rising edge at phase 0, falling edge at the duty point.
        .square   => blk: {
            const naive: f32 = if (phase < pw) 1.0 else -1.0;
            const off = phase - pw;
            break :blk naive + polyBlep(phase, step) - polyBlep(off - @floor(off), step);
        },
        // Callers branch to `wavetable.lookup` before reaching here -
        // this arm only exists to keep the switch exhaustive.
        .wavetable => 0.0,
        // zig fmt: on
    };
}

test "bendShape: straight at 0, monotone, and a quarter sine at ±0.25" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), bendShape(0.5, 0.0), 1e-6);
    for ([_]f32{ -1.0, -0.25, 0.0, 0.4, 1.0 }) |curve| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), bendShape(0.0, curve), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), bendShape(1.0, curve), 1e-6);
        var prev = bendShape(0.0, curve);
        for (1..21) |i| {
            const y = bendShape(@as(f32, @floatFromInt(i)) / 20.0, curve);
            try std.testing.expect(y >= prev);
            prev = y;
        }
    }
    // What `synth.lfoWave(.sine)` is built on: a -0.25 bend rises like the
    // first quarter of a sine, +0.25 falls away like the second.
    try std.testing.expectApproxEqAbs(@sin(std.math.pi * 0.25), bendShape(0.5, -0.25), 1e-4);
    try std.testing.expectApproxEqAbs(1.0 - @sin(std.math.pi * 0.25), bendShape(0.5, 0.25), 1e-4);
}

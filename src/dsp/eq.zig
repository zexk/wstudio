const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const num_eq_bands = 8;

/// Initial per-band center frequencies for a freshly inserted EQ - a
/// log-ish spread across low/mid/high. Every band is fully parametric
/// (freq/Q/gain all adjustable) so these are just starting points, not
/// fixed slots the way a graphic EQ's ISO bands were.
pub const default_frequencies = [_]f32{
    60.0, 150.0, 400.0, 1000.0, 2500.0, 6000.0, 10000.0, 16000.0,
};

/// Per-band response type: peaking/shelf/tilt-shelf use gain, lowpass/
/// highpass/notch use `slope` (cascade depth) instead.
pub const BandKind = enum(u8) { peak, lowpass, highpass, lowshelf, highshelf, notch, tiltshelf };

pub fn usesGain(kind: BandKind) bool {
    return switch (kind) {
        .peak, .lowshelf, .highshelf, .tiltshelf => true,
        .lowpass, .highpass, .notch => false,
    };
}

pub fn usesSlope(kind: BandKind) bool {
    return !usesGain(kind);
}

/// Slope cap for the filter kinds, in cascaded second-order sections:
/// each stage adds 12 dB/oct, so 1..4 covers 12/24/36/48 dB/oct. `.notch`
/// reuses the same cascade to deepen its null (multiple notches stacked at
/// the same freq/Q), same reasoning as lowpass/highpass.
pub const max_slope = 4;

const freq_min: f32 = 20.0;
const freq_max: f32 = 20000.0;
const q_min: f32 = 0.1;
const q_max: f32 = 10.0;
const gain_min: f32 = -18.0;
const gain_max: f32 = 18.0;
const dyn_threshold_min: f32 = -60.0;
const dyn_threshold_max: f32 = 0.0;

/// Fixed dynamic-EQ envelope timing - ponytail: a real Pro-Q-style dynamic
/// band exposes attack/release as knobs; this is a deliberately simplified
/// fixed ceiling (same "one fewer axis to learn" tradeoff RETRIGGER's mode
/// pair made). Upgrade path: promote to per-band fields + param rows if a
/// track genuinely needs a faster/slower dynamic response than this.
const dyn_attack_ms: f32 = 10.0;
const dyn_release_ms: f32 = 150.0;

/// Per-band left/right (normal) vs mid/side targeting: `.mid`/`.side`
/// filter only the sum or difference signal, leaving the other untouched.
pub const StereoMode = enum(u8) { stereo, mid, side };

/// One biquad section's delay line. A band keeps a state per cascade
/// stage per channel; the coefficients are shared (identical cascade).
const BiquadState = struct {
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,
};

/// One RBJ-cookbook biquad's normalized coefficients.
const Coeffs = struct {
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,
};

fn biquadStep(c: Coeffs, st: *BiquadState, x: f32) f32 {
    // zig fmt: off
    const y = c.b0 * x + c.b1 * st.x1 + c.b2 * st.x2
            - c.a1 * st.y1 - c.a2 * st.y2;
            // zig fmt: on
    st.x2 = st.x1;
    st.x1 = x;
    st.y2 = st.y1;
    st.y1 = y;
    return y;
}

const EqBand = struct {
    freq: f32,
    enabled: bool = true,
    gain_db: f32 = 0.0,
    q: f32 = 0.7,
    kind: BandKind = .peak,
    /// Cascade depth for .lowpass/.highpass/.notch, 1..max_slope (12 dB/oct
    /// per stage). A .peak/.shelf/.tiltshelf band always runs its own fixed
    /// stage count instead (1, or 2 for tiltshelf).
    slope: u8 = 1,
    /// Isolate just this band's frequency region for auditioning (see
    /// `ParametricEq.processSolo`) - exclusive, enforced by `setSolo`.
    solo: bool = false,
    stereo_mode: StereoMode = .stereo,
    /// Mirrored from `ParametricEq.analog` on every edit, so `recompute` can
    /// stay a band-local call. Not saved per band - the EQ-level flag is.
    analog: bool = false,
    /// Dynamic EQ: above `dyn_threshold_db`, the applied gain moves from
    /// `gain_db` toward `gain_db + dyn_amount_db` (attack/release smoothed,
    /// see `dyn_attack_ms`/`dyn_release_ms`). Only meaningful for the
    /// gain-based kinds (`usesGain`); ignored otherwise.
    dyn_enabled: bool = false,
    dyn_threshold_db: f32 = -24.0,
    dyn_amount_db: f32 = 0.0,
    /// Dynamic detector state: peak-with-decay envelope (same recipe as
    /// `Gate`) measured through this band's own bandpass (`bp_*`), plus the
    /// attack/release-smoothed 0..1 openness factor it drives.
    dyn_env: f32 = 0.0,
    dyn_factor: f32 = 0.0,
    detector_state: BiquadState = .{},

    /// Primary filter coefficients - the whole shape for every kind except
    /// `.tiltshelf`, which also uses `coeffs2` for its second (high-shelf)
    /// stage.
    coeffs: Coeffs = .{},
    coeffs2: Coeffs = .{},
    /// Constant 0dB-peak bandpass at this band's freq/Q, recomputed alongside
    /// `coeffs` - shared by the solo-audition path and the dynamic-EQ
    /// detector, neither of which cares about this band's own kind/gain.
    bp: Coeffs = .{},

    state: [max_slope][2]BiquadState = std.mem.zeroes([max_slope][2]BiquadState),

    /// Recomputes `coeffs`/`coeffs2`/`bp` for the current freq/q/kind, using
    /// `gain_db_for_calc` in place of the stored `gain_db` - the static path
    /// (`recompute`) passes `gain_db` itself; the dynamic path passes the
    /// envelope-modulated effective gain without touching the stored value.
    fn recomputeWithGain(band: *EqBand, sr: f32, gain_db_for_calc: f32) void {
        // A band's own knob clamps to 20 kHz, which is already above Nyquist
        // on any device under 40 kHz - and a project may be loaded at any
        // rate down to 8 kHz. Past Nyquist `w0` wraps, `alpha` can come out
        // negative, and the cookbook biquad turns into an oscillator, so the
        // design frequency is pinned here rather than in each setter.
        const w0 = 2.0 * std.math.pi * @min(band.freq, sr * 0.45) / sr;
        const cos_w0 = std.math.cos(w0);
        const sin_w0 = std.math.sin(w0);
        const alpha = sin_w0 / (2.0 * band.q);

        if (band.analog and band.kind == .peak) {
            band.coeffs = matchedPeakCoeffs(gain_db_for_calc, band.q, w0);
        } else if (band.kind == .tiltshelf) {
            band.coeffs = shelfCoeffs(.lowshelf, -gain_db_for_calc / 2.0, cos_w0, sin_w0, band.q);
            band.coeffs2 = shelfCoeffs(.highshelf, gain_db_for_calc / 2.0, cos_w0, sin_w0, band.q);
        } else {
            band.coeffs = mainCoeffs(band.kind, gain_db_for_calc, band.q, cos_w0, sin_w0, alpha);
        }

        // Constant 0dB-peak bandpass (RBJ cookbook), gain-independent.
        const bp_a0 = 1.0 + alpha;
        band.bp = .{
            .b0 = alpha / bp_a0,
            .b1 = 0.0,
            .b2 = -alpha / bp_a0,
            .a1 = (-2.0 * cos_w0) / bp_a0,
            .a2 = (1.0 - alpha) / bp_a0,
        };
    }

    fn recompute(band: *EqBand, sr: f32) void {
        band.recomputeWithGain(sr, band.gain_db);
    }

    /// How many cascade stages this band runs per sample.
    fn stages(band: *const EqBand) usize {
        return switch (band.kind) {
            .tiltshelf => 2,
            else => if (usesSlope(band.kind)) band.slope else 1,
        };
    }

    fn coeffsForStage(band: *const EqBand, stage: usize) Coeffs {
        if (band.kind == .tiltshelf and stage == 1) return band.coeffs2;
        return band.coeffs;
    }

    fn processStage(band: *EqBand, stage: usize, ch: usize, x: f32) f32 {
        return biquadStep(band.coeffsForStage(stage), &band.state[stage][ch], x);
    }

    fn applySample(band: *EqBand, ch: usize, x: f32) f32 {
        var s = x;
        const n = band.stages();
        for (0..n) |stage| s = band.processStage(stage, ch, s);
        return s;
    }

    /// Scans this block through the band's detector bandpass to update the
    /// peak-with-decay envelope and the attack/release-smoothed openness
    /// factor - same recipe `Gate.processBlock` uses for its own detector,
    /// except the smoothing runs once per block instead of per sample (a
    /// dynamic band's coefficients only get recomputed block-rate anyway),
    /// so the coefficients are scaled by this block's frame count rather
    /// than 1 sample - otherwise a bigger block would converge that many
    /// times slower.
    fn updateDynamicEnvelope(band: *EqBand, sr: f32, buf: []const Sample) void {
        const frames: f32 = @floatFromInt(buf.len / 2);
        const det_decay = @exp(-frames / (0.050 * sr));
        const attack = @exp(-frames / (dyn_attack_ms * 0.001 * sr));
        const release = @exp(-frames / (dyn_release_ms * 0.001 * sr));
        var peak: f32 = 0.0;
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const mono = (buf[i] + buf[i + 1]) * 0.5;
            const y = biquadStep(band.bp, &band.detector_state, mono);
            peak = @max(peak, @abs(y));
        }
        band.dyn_env = @max(peak, band.dyn_env * det_decay);
        const env_db = types.gainToDb(band.dyn_env);
        const target: f32 = if (env_db >= band.dyn_threshold_db) 1.0 else 0.0;
        const coef = if (target > band.dyn_factor) attack else release;
        band.dyn_factor = target + coef * (band.dyn_factor - target);
    }

    fn reset(band: *EqBand) void {
        band.state = std.mem.zeroes([max_slope][2]BiquadState);
        band.detector_state = .{};
        band.dyn_env = 0.0;
        band.dyn_factor = 0.0;
    }
};

/// One conjugate (or real) root pair of the analog prototype, mapped to z by
/// `z = e^(sT)` and written as the `1 + c1·z⁻¹ + c2·z⁻²` it factors into.
/// `w0` is ω0·T, so every exponent below is already in sample time.
fn matchedRoots(w0: f32, damping: f32) struct { c1: f32, c2: f32 } {
    if (damping < 1.0) {
        const decay = @exp(-damping * w0);
        const angle = w0 * @sqrt(1.0 - damping * damping);
        return .{ .c1 = -2.0 * decay * std.math.cos(angle), .c2 = decay * decay };
    }
    // Overdamped: two real roots rather than a conjugate pair.
    const spread = @sqrt(damping * damping - 1.0);
    const r1 = @exp(-w0 * (damping + spread));
    const r2 = @exp(-w0 * (damping - spread));
    return .{ .c1 = -(r1 + r2), .c2 = r1 * r2 };
}

/// Peaking bell designed by mapping the analog prototype's poles and zeros
/// straight onto the unit circle (matched Z-transform) instead of running it
/// through the bilinear transform the RBJ cookbook uses.
///
/// The bilinear transform squeezes the whole analog frequency axis into
/// 0..Nyquist, so a bell near the top of the range comes out narrower and
/// steeper than the one that was drawn - "cramping". It is inaudible at 1 kHz
/// and obvious at 16 kHz, which is where an air band lives. Matched-Z has the
/// opposite trade: it reproduces the analog shape but says nothing about what
/// happens above Nyquist, which is why only `.peak` uses it here. The filter
/// kinds (`.lowpass`/`.highpass`/`.notch`) depend on the bilinear transform's
/// exact zero at Nyquist for their stopband, and the shelves would each need
/// their own prototype factored the same way; both keep the cookbook.
///
/// The analog prototype, with A = 10^(gain/40), so |H(jω0)| = A²:
///
///     H(s) = (s² + (A·ω0/Q)·s + ω0²) / (s² + (ω0/(A·Q))·s + ω0²)
fn matchedPeakCoeffs(gain_db: f32, q: f32, w0: f32) Coeffs {
    const target = std.math.pow(f32, 10.0, gain_db / 20.0);
    var a = std.math.pow(f32, 10.0, gain_db / 40.0);
    var result = matchedPeakFor(a, q, w0);
    // Mapping the roots keeps the shape but not the centre level: near
    // Nyquist the response picks up enough of the prototype's mirror image
    // to overshoot by more than a dB, so a +12 knob would hand back +13.5.
    // Solving for the A that lands the centre where it was asked for costs a
    // handful of iterations at coefficient-recompute rate (never per sample),
    // and |H(ω0)| ≈ A² makes each one very nearly exact.
    for (0..6) |_| {
        const actual = coeffsMagnitudeAt(result, w0);
        if (!std.math.isFinite(actual) or actual <= 1e-9) break;
        if (@abs(actual - target) <= target * 1e-4) break;
        a *= @sqrt(target / actual);
        result = matchedPeakFor(a, q, w0);
    }
    return result;
}

fn matchedPeakFor(a: f32, q: f32, w0: f32) Coeffs {
    const zero = matchedRoots(w0, a / (2.0 * q));
    const pole = matchedRoots(w0, 1.0 / (2.0 * a * q));
    // The mapping preserves shape, not level, so normalize the numerator to
    // the analog prototype's unity DC gain.
    const dc_num = 1.0 + zero.c1 + zero.c2;
    const dc_den = 1.0 + pole.c1 + pole.c2;
    const scale = if (@abs(dc_num) > 1e-12) dc_den / dc_num else 1.0;
    return .{
        .b0 = scale,
        .b1 = scale * zero.c1,
        .b2 = scale * zero.c2,
        .a1 = pole.c1,
        .a2 = pole.c2,
    };
}

/// RBJ-cookbook peak/notch/lowpass/highpass coefficients for `kind` at the
/// given angle - shared by `EqBand.recomputeWithGain` and (for shelves)
/// routed through `shelfCoeffs`.
fn mainCoeffs(kind: BandKind, gain_db: f32, q: f32, cos_w0: f32, sin_w0: f32, alpha: f32) Coeffs {
    switch (kind) {
        .peak => {
            const a = std.math.pow(f32, 10.0, gain_db / 40.0);
            const a0 = 1.0 + alpha / a;
            return .{
                .b0 = (1.0 + alpha * a) / a0,
                .b1 = (-2.0 * cos_w0) / a0,
                .b2 = (1.0 - alpha * a) / a0,
                .a1 = (-2.0 * cos_w0) / a0,
                .a2 = (1.0 - alpha / a) / a0,
            };
        },
        .notch => {
            const a0 = 1.0 + alpha;
            return .{
                .b0 = 1.0 / a0,
                .b1 = (-2.0 * cos_w0) / a0,
                .b2 = 1.0 / a0,
                .a1 = (-2.0 * cos_w0) / a0,
                .a2 = (1.0 - alpha) / a0,
            };
        },
        .lowpass => {
            const a0 = 1.0 + alpha;
            const b0 = (1.0 - cos_w0) / 2.0;
            return .{
                .b0 = b0 / a0,
                .b1 = (1.0 - cos_w0) / a0,
                .b2 = b0 / a0,
                .a1 = (-2.0 * cos_w0) / a0,
                .a2 = (1.0 - alpha) / a0,
            };
        },
        .highpass => {
            const a0 = 1.0 + alpha;
            const b0 = (1.0 + cos_w0) / 2.0;
            return .{
                .b0 = b0 / a0,
                .b1 = -(1.0 + cos_w0) / a0,
                .b2 = b0 / a0,
                .a1 = (-2.0 * cos_w0) / a0,
                .a2 = (1.0 - alpha) / a0,
            };
        },
        .lowshelf => return shelfCoeffs(.lowshelf, gain_db, cos_w0, sin_w0, q),
        .highshelf => return shelfCoeffs(.highshelf, gain_db, cos_w0, sin_w0, q),
        // `.tiltshelf` is composed directly in `recomputeWithGain` (two
        // different stages) - never reaches here.
        .tiltshelf => unreachable,
    }
}

/// RBJ-cookbook shelf coefficients. `.tiltshelf` composes two of these (see
/// `EqBand.recomputeWithGain`): a low-shelf at `-gain/2` feeding a
/// high-shelf at `+gain/2`, unity at the corner frequency - the classic
/// Baxandall tilt shape, built from filters this module already has instead
/// of deriving a dedicated one-biquad tilt prototype.
fn shelfCoeffs(kind: enum { lowshelf, highshelf }, gain_db: f32, cos_w0: f32, sin_w0: f32, q: f32) Coeffs {
    const a = std.math.pow(f32, 10.0, gain_db / 40.0);
    const sqrt_a = std.math.sqrt(a);
    const shelf_alpha = sin_w0 / (2.0 * q);
    const alpha_term = 2.0 * sqrt_a * shelf_alpha;
    if (kind == .lowshelf) {
        const a0 = (a + 1.0) + (a - 1.0) * cos_w0 + alpha_term;
        return .{
            .b0 = (a * ((a + 1.0) - (a - 1.0) * cos_w0 + alpha_term)) / a0,
            .b1 = (2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0)) / a0,
            .b2 = (a * ((a + 1.0) - (a - 1.0) * cos_w0 - alpha_term)) / a0,
            .a1 = (-2.0 * ((a - 1.0) + (a + 1.0) * cos_w0)) / a0,
            .a2 = ((a + 1.0) + (a - 1.0) * cos_w0 - alpha_term) / a0,
        };
    }
    const a0 = (a + 1.0) - (a - 1.0) * cos_w0 + alpha_term;
    return .{
        .b0 = (a * ((a + 1.0) + (a - 1.0) * cos_w0 + alpha_term)) / a0,
        .b1 = (-2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0)) / a0,
        .b2 = (a * ((a + 1.0) + (a - 1.0) * cos_w0 - alpha_term)) / a0,
        .a1 = (2.0 * ((a - 1.0) - (a + 1.0) * cos_w0)) / a0,
        .a2 = ((a + 1.0) - (a - 1.0) * cos_w0 - alpha_term) / a0,
    };
}

pub const ParametricEq = struct {
    sr: f32,
    bands: [num_eq_bands]EqBand,
    bypass: bool = false,
    /// Estimates the combined curve's average dB offset across the audible
    /// range and applies its inverse as output makeup - see
    /// `recomputeAutoGain`. Recomputed on any band edit, not per-block, so
    /// it tracks the static curve (dynamic-EQ movement isn't compensated
    /// for - a known, documented simplification, not a bug).
    auto_gain: bool = false,
    auto_gain_db: f32 = 0.0,
    /// Design the peaking bands by matched Z-transform rather than the RBJ
    /// cookbook's bilinear one, so a bell in the top octave keeps the shape
    /// it was drawn with - see `matchedPeakCoeffs`. Off by default: it only
    /// changes bands that are both `.peak` and high enough for cramping to
    /// matter, and an existing project should sound the way it was mixed.
    analog: bool = false,

    pub fn init(sample_rate: u32) ParametricEq {
        var self: ParametricEq = .{
            .sr = @floatFromInt(@max(sample_rate, 1)),
            .bands = undefined,
        };
        for (&self.bands, &default_frequencies) |*b, f| {
            b.* = .{ .freq = f, .gain_db = 0.0, .q = 0.7 };
            b.recompute(self.sr);
        }
        return self;
    }

    /// Switches every band's design at once - `analog` is one EQ-wide choice
    /// rather than a per-band one, the way an EQ's "analog/digital" mode
    /// normally is.
    pub fn setAnalog(self: *ParametricEq, on: bool) void {
        self.analog = on;
        for (&self.bands) |*b| {
            b.analog = on;
            b.recompute(self.sr);
        }
        self.recomputeAutoGain();
    }

    pub fn setGain(self: *ParametricEq, index: usize, gain_db: f32) void {
        if (index >= num_eq_bands or !std.math.isFinite(gain_db)) return;
        self.bands[index].gain_db = std.math.clamp(gain_db, gain_min, gain_max);
        self.bands[index].recompute(self.sr);
        self.recomputeAutoGain();
    }

    pub fn setEnabled(self: *ParametricEq, index: usize, enabled: bool) void {
        if (index >= num_eq_bands) return;
        self.bands[index].enabled = enabled;
        self.bands[index].reset();
        self.recomputeAutoGain();
    }

    pub fn setFreq(self: *ParametricEq, index: usize, freq_hz: f32) void {
        if (index >= num_eq_bands or !std.math.isFinite(freq_hz)) return;
        self.bands[index].freq = std.math.clamp(freq_hz, freq_min, freq_max);
        self.bands[index].recompute(self.sr);
        self.recomputeAutoGain();
    }

    pub fn setQ(self: *ParametricEq, index: usize, q: f32) void {
        if (index >= num_eq_bands or !std.math.isFinite(q)) return;
        self.bands[index].q = std.math.clamp(q, q_min, q_max);
        self.bands[index].recompute(self.sr);
        self.recomputeAutoGain();
    }

    /// Switch a band's response type and (for the filter kinds) its slope
    /// in cascade stages, clamped to 1..max_slope.
    pub fn setType(self: *ParametricEq, index: usize, kind: BandKind, slope: u8) void {
        if (index >= num_eq_bands) return;
        const band = &self.bands[index];
        band.kind = kind;
        band.slope = std.math.clamp(slope, 1, max_slope);
        if (!usesGain(kind)) {
            band.dyn_enabled = false;
        }
        band.recompute(self.sr);
        self.recomputeAutoGain();
    }

    /// Solo is exclusive - soloing a band clears every other band's solo,
    /// matching a typical single-band "audition this" workflow rather than
    /// Pro-Q's additive multi-solo.
    pub fn setSolo(self: *ParametricEq, index: usize, solo: bool) void {
        if (index >= num_eq_bands) return;
        if (solo) {
            for (&self.bands) |*b| b.solo = false;
            self.bands[index].solo = true;
        } else {
            self.bands[index].solo = false;
        }
    }

    pub fn setStereoMode(self: *ParametricEq, index: usize, mode: StereoMode) void {
        if (index >= num_eq_bands) return;
        self.bands[index].stereo_mode = mode;
    }

    pub fn setDynEnabled(self: *ParametricEq, index: usize, enabled: bool) void {
        if (index >= num_eq_bands) return;
        const band = &self.bands[index];
        band.dyn_enabled = enabled and usesGain(band.kind);
        if (!band.dyn_enabled) {
            // `processBlock` only recomputes coefficients while dynamic is
            // on, so switching it off has to put the static gain back
            // itself - otherwise the band stays stuck wherever the detector
            // last left it, playing a gain the editor no longer shows.
            // Clearing the detector too, so re-enabling starts from silence
            // rather than an envelope frozen from minutes ago.
            band.dyn_env = 0.0;
            band.dyn_factor = 0.0;
            band.recompute(self.sr);
        }
    }

    pub fn setDynThreshold(self: *ParametricEq, index: usize, threshold_db: f32) void {
        if (index >= num_eq_bands or !std.math.isFinite(threshold_db)) return;
        self.bands[index].dyn_threshold_db = std.math.clamp(threshold_db, dyn_threshold_min, dyn_threshold_max);
    }

    pub fn setDynAmount(self: *ParametricEq, index: usize, amount_db: f32) void {
        if (index >= num_eq_bands or !std.math.isFinite(amount_db)) return;
        self.bands[index].dyn_amount_db = std.math.clamp(amount_db, gain_min, gain_max);
    }

    pub fn setAutoGain(self: *ParametricEq, enabled: bool) void {
        self.auto_gain = enabled;
        self.recomputeAutoGain();
    }

    fn anySolo(self: *const ParametricEq) ?usize {
        for (&self.bands, 0..) |*b, i| if (b.enabled and b.solo) return i;
        return null;
    }

    /// Replaces the whole chain's output with just the soloed band's
    /// frequency region (a constant 0dB-peak bandpass at its freq/Q), ignoring
    /// every band's own gain/kind - the point is auditioning what's *there*,
    /// not what the band would do to it.
    fn processSolo(self: *ParametricEq, index: usize, buf: []Sample) void {
        const band = &self.bands[index];
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            inline for (0..2) |ch| {
                buf[i + ch] = biquadStep(band.bp, &band.state[0][ch], buf[i + ch]);
            }
        }
    }

    pub fn processBlock(self: *ParametricEq, buf: []Sample) void {
        if (self.bypass) return;
        if (self.anySolo()) |idx| {
            self.processSolo(idx, buf);
            return;
        }
        for (&self.bands) |*band| {
            if (!band.enabled) continue;
            if (band.dyn_enabled and usesGain(band.kind)) {
                band.updateDynamicEnvelope(self.sr, buf);
                band.recomputeWithGain(self.sr, band.gain_db + band.dyn_amount_db * band.dyn_factor);
            }
            if (band.stereo_mode == .stereo) {
                var i: usize = 0;
                while (i < buf.len) : (i += 2) {
                    inline for (0..2) |ch| buf[i + ch] = band.applySample(ch, buf[i + ch]);
                }
            } else {
                var i: usize = 0;
                while (i + 1 < buf.len) : (i += 2) {
                    const l = buf[i];
                    const r = buf[i + 1];
                    const mid = (l + r) * 0.5;
                    const side = (l - r) * 0.5;
                    const target_in = if (band.stereo_mode == .mid) mid else side;
                    const target_out = band.applySample(0, target_in);
                    const new_mid = if (band.stereo_mode == .mid) target_out else mid;
                    const new_side = if (band.stereo_mode == .side) target_out else side;
                    buf[i] = new_mid + new_side;
                    buf[i + 1] = new_mid - new_side;
                }
            }
        }
        if (self.auto_gain and self.auto_gain_db != 0.0) {
            const g = types.dbToGain(self.auto_gain_db);
            for (buf) |*s| s.* *= g;
        }
    }

    /// ~30 log-spaced points across the audible range - dense enough to
    /// catch every band's bump without being a per-sample cost (this only
    /// runs when a band's params change, not per block).
    const auto_gain_probe_freqs = [_]f32{
        25,   32,   40,   50,   63,   80,   100,   125,   160,   200,
        250,  315,  400,  500,  630,  800,  1000,  1250,  1600,  2000,
        2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
    };

    fn recomputeAutoGain(self: *ParametricEq) void {
        if (!self.auto_gain) {
            self.auto_gain_db = 0.0;
            return;
        }
        var sum_db: f32 = 0.0;
        for (auto_gain_probe_freqs) |f| {
            var mag: f32 = 1.0;
            for (&self.bands) |*b| if (b.enabled) {
                mag *= bandMagnitude(b, f, self.sr);
            };
            sum_db += types.gainToDb(mag);
        }
        const avg = sum_db / @as(f32, @floatFromInt(auto_gain_probe_freqs.len));
        self.auto_gain_db = std.math.clamp(-avg, -18.0, 18.0);
    }

    pub fn reset(self: *ParametricEq) void {
        for (&self.bands) |*b| b.reset();
    }

    pub const device = dsp.deviceOf(@This());
};

fn coeffsMagnitude(c: Coeffs, freq: f32, sample_rate: f32) f32 {
    return coeffsMagnitudeAt(c, 2.0 * std.math.pi * freq / sample_rate);
}

fn coeffsMagnitudeAt(c: Coeffs, omega: f32) f32 {
    const z1_re = std.math.cos(omega);
    const z1_im = -std.math.sin(omega);
    const z2_re = std.math.cos(2.0 * omega);
    const z2_im = -std.math.sin(2.0 * omega);
    const num_re = c.b0 + c.b1 * z1_re + c.b2 * z2_re;
    const num_im = c.b1 * z1_im + c.b2 * z2_im;
    const den_re = 1.0 + c.a1 * z1_re + c.a2 * z2_re;
    const den_im = c.a1 * z1_im + c.a2 * z2_im;
    return std.math.sqrt((num_re * num_re + num_im * num_im) / (den_re * den_re + den_im * den_im));
}

/// This band's full combined magnitude response at `freq`, accounting for
/// its actual stage count (a cascaded slope filter's response is its
/// single-stage magnitude raised to the stage count; `.tiltshelf`'s two
/// stages differ, so it multiplies them directly instead). Shared by
/// `recomputeAutoGain` and the response-curve tests below; frontends
/// wanting the same curve for on-screen drawing can call this too.
pub fn bandMagnitude(band: *const EqBand, freq: f32, sample_rate: f32) f32 {
    if (band.kind == .tiltshelf) {
        return coeffsMagnitude(band.coeffs, freq, sample_rate) * coeffsMagnitude(band.coeffs2, freq, sample_rate);
    }
    const m1 = coeffsMagnitude(band.coeffs, freq, sample_rate);
    const n = band.stages();
    return std.math.pow(f32, m1, @floatFromInt(n));
}

test "analog mode tracks the analog bell where the cookbook one cramps" {
    // A 16 kHz bell at 48 kHz: close enough to Nyquist that the bilinear
    // transform's frequency squeeze is the whole story. Measured against the
    // analog prototype both designs come from, in the skirt above the centre
    // where cramping shows up rather than at the centre, where the cookbook
    // is exact by construction.
    const f0: f32 = 16_000.0;
    const gain_db: f32 = 12.0;
    const q: f32 = 1.0;
    const sr: f32 = 48_000.0;

    // |H(jw)| of (s² + (A·w0/Q)s + w0²) / (s² + (w0/(A·Q))s + w0²).
    const analogMagnitude = struct {
        fn at(w: f32) f32 {
            const a = std.math.pow(f32, 10.0, gain_db / 40.0);
            const w0 = 2.0 * std.math.pi * f0;
            const real = w0 * w0 - w * w;
            const num_imag = a * w0 * w / q;
            const den_imag = w0 * w / (a * q);
            return @sqrt(real * real + num_imag * num_imag) /
                @sqrt(real * real + den_imag * den_imag);
        }
    }.at;

    var cookbook = ParametricEq.init(48_000);
    cookbook.setType(0, .peak, 1);
    cookbook.setFreq(0, f0);
    cookbook.setQ(0, q);
    cookbook.setGain(0, gain_db);

    var analog = ParametricEq.init(48_000);
    analog.setAnalog(true);
    analog.setType(0, .peak, 1);
    analog.setFreq(0, f0);
    analog.setQ(0, q);
    analog.setGain(0, gain_db);

    // 20 kHz: inside the bell's upper skirt, and where the squeeze bites.
    const probe: f32 = 20_000.0;
    const want = analogMagnitude(2.0 * std.math.pi * probe);
    const cookbook_err = @abs(bandMagnitude(&cookbook.bands[0], probe, sr) - want);
    const analog_err = @abs(bandMagnitude(&analog.bands[0], probe, sr) - want);
    try std.testing.expect(analog_err < cookbook_err);

    // Still a bell, not a shelf: unity well below the corner either way.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bandMagnitude(&analog.bands[0], 100.0, sr), 0.05);
    // And still exactly the boost it was asked for at the centre, which is
    // what the solve in `matchedPeakCoeffs` is for.
    try std.testing.expectApproxEqAbs(
        types.dbToGain(gain_db),
        bandMagnitude(&analog.bands[0], f0, sr),
        0.01,
    );
}

test "analog mode leaves the non-peak kinds on the cookbook design" {
    var plain = ParametricEq.init(48_000);
    var analog = ParametricEq.init(48_000);
    analog.setAnalog(true);
    for ([_]BandKind{ .lowpass, .highpass, .notch, .lowshelf, .highshelf, .tiltshelf }) |kind| {
        plain.setType(0, kind, 1);
        analog.setType(0, kind, 1);
        plain.setGain(0, 6.0);
        analog.setGain(0, 6.0);
        try std.testing.expectEqual(plain.bands[0].coeffs, analog.bands[0].coeffs);
    }
}

test "parameter setters ignore non-finite values" {
    var eq = ParametricEq.init(48_000);
    const before = eq.bands[0];
    eq.setGain(0, std.math.nan(f32));
    eq.setFreq(0, std.math.inf(f32));
    eq.setQ(0, -std.math.inf(f32));
    try std.testing.expectEqual(before.gain_db, eq.bands[0].gain_db);
    try std.testing.expectEqual(before.freq, eq.bands[0].freq);
    try std.testing.expectEqual(before.q, eq.bands[0].q);
}

test "shelf bands boost the intended side of the spectrum" {
    var eq = ParametricEq.init(48_000);
    const band = &eq.bands[0];
    eq.setFreq(0, 1000.0);
    eq.setGain(0, 12.0);

    eq.setType(0, .lowshelf, 4);
    const low_shelf_low = bandMagnitude(band, 100.0, eq.sr);
    const low_shelf_high = bandMagnitude(band, 10_000.0, eq.sr);
    try std.testing.expect(low_shelf_low > low_shelf_high * 2.5);
    try std.testing.expectEqual(@as(usize, 1), band.stages());

    eq.setType(0, .highshelf, 4);
    const high_shelf_low = bandMagnitude(band, 100.0, eq.sr);
    const high_shelf_high = bandMagnitude(band, 10_000.0, eq.sr);
    try std.testing.expect(high_shelf_high > high_shelf_low * 2.5);
    try std.testing.expectEqual(@as(usize, 1), band.stages());
}

test "highpass band blocks DC, lowpass band passes it" {
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .highpass, 2);
    eq.setFreq(0, 1000.0);

    var buf: [512]Sample = undefined;
    for (0..40) |_| {
        @memset(&buf, 1.0);
        eq.processBlock(&buf);
    }
    try std.testing.expect(@abs(buf[510]) < 0.01);
    try std.testing.expect(@abs(buf[511]) < 0.01);

    eq.setType(0, .lowpass, 4);
    for (0..40) |_| {
        @memset(&buf, 1.0);
        eq.processBlock(&buf);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), buf[510], 0.05);
}

test "steeper highpass slope attenuates a below-cutoff tone harder" {
    // 200 Hz tone under a 2 kHz highpass: 12 dB/oct should leave far more
    // of it standing than 48 dB/oct.
    var peak_by_slope: [2]f32 = undefined;
    for ([_]u8{ 1, 4 }, 0..) |slope, si| {
        var eq = ParametricEq.init(48_000);
        eq.setType(0, .highpass, slope);
        eq.setFreq(0, 2000.0);

        var buf: [512]Sample = undefined;
        var phase: f32 = 0.0;
        var peak: f32 = 0.0;
        for (0..60) |block| {
            var i: usize = 0;
            while (i < buf.len) : (i += 2) {
                const s = std.math.sin(phase);
                buf[i] = s;
                buf[i + 1] = s;
                phase += 2.0 * std.math.pi * 200.0 / 48_000.0;
            }
            eq.processBlock(&buf);
            // zig fmt: off
            if (block >= 50) for (buf) |s| { peak = @max(peak, @abs(s)); };
            // zig fmt: on
        }
        peak_by_slope[si] = peak;
    }
    try std.testing.expect(peak_by_slope[1] < peak_by_slope[0] / 10.0);
}

test "channels filter independently (no shared biquad state)" {
    // L carries DC, R stays silent; a lowpass must keep R at zero. The
    // old single-state-per-band code smeared L into R here.
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .lowpass, 1);
    eq.setFreq(0, 500.0);

    var buf: [512]Sample = undefined;
    for (0..20) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            buf[i] = 1.0;
            buf[i + 1] = 0.0;
        }
        eq.processBlock(&buf);
    }
    try std.testing.expect(@abs(buf[511]) < 1e-6);
    try std.testing.expect(buf[510] > 0.9);
}

test "notch band deepens with cascade slope" {
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .notch, 1);
    eq.setFreq(0, 1000.0);
    const shallow = bandMagnitude(&eq.bands[0], 1000.0, eq.sr);

    eq.setType(0, .notch, 4);
    const deep = bandMagnitude(&eq.bands[0], 1000.0, eq.sr);

    try std.testing.expect(deep < shallow);
    try std.testing.expect(deep < 0.05);
    // Well away from the notch, a single stage already reads ~flat.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bandMagnitude(&eq.bands[0], 100.0, eq.sr), 0.05);
}

test "tiltshelf is unity at the corner and opposite-signed on each side" {
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .tiltshelf, 1);
    eq.setFreq(0, 1000.0);
    eq.setGain(0, 12.0);
    const band = &eq.bands[0];

    try std.testing.expectEqual(@as(usize, 2), band.stages());
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bandMagnitude(band, 1000.0, eq.sr), 0.05);
    try std.testing.expect(bandMagnitude(band, 50.0, eq.sr) < 0.9);
    try std.testing.expect(bandMagnitude(band, 15_000.0, eq.sr) > 1.1);
}

test "solo isolates one band's region regardless of its gain" {
    var eq = ParametricEq.init(48_000);
    eq.setFreq(0, 1000.0);
    eq.setQ(0, 4.0);
    eq.setGain(0, 0.0); // no boost/cut - solo should still isolate the region
    eq.setSolo(0, true);
    try std.testing.expect(eq.bands[0].solo);

    var buf: [1024]Sample = undefined;
    var phase_in: f32 = 0.0;
    var phase_out: f32 = 0.0;
    var peak_in: f32 = 0.0;
    var peak_out: f32 = 0.0;
    for (0..40) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const in_band = std.math.sin(phase_in);
            const out_band = std.math.sin(phase_out);
            buf[i] = in_band + out_band;
            buf[i + 1] = in_band + out_band;
            phase_in += 2.0 * std.math.pi * 1000.0 / 48_000.0;
            phase_out += 2.0 * std.math.pi * 60.0 / 48_000.0;
        }
        eq.processBlock(&buf);
        if (peak_in == 0.0 and peak_out == 0.0) {} // warm up filter state below
    }
    for (0..40) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const in_band = std.math.sin(phase_in);
            const out_band = std.math.sin(phase_out);
            buf[i] = in_band + out_band;
            buf[i + 1] = in_band + out_band;
            phase_in += 2.0 * std.math.pi * 1000.0 / 48_000.0;
            phase_out += 2.0 * std.math.pi * 60.0 / 48_000.0;
        }
        eq.processBlock(&buf);
        for (buf) |s| peak_out = @max(peak_out, @abs(s));
    }
    _ = &peak_in;
    // The isolated 1kHz tone should dominate; the 60Hz tone (far outside a
    // Q=4 band at 1kHz) should be mostly gone.
    try std.testing.expect(peak_out > 0.5);
    try std.testing.expect(peak_out < 1.3);

    eq.setSolo(0, false);
    try std.testing.expect(!eq.bands[0].solo);
}

test "solo is exclusive across bands" {
    var eq = ParametricEq.init(48_000);
    eq.setSolo(0, true);
    eq.setSolo(2, true);
    try std.testing.expect(!eq.bands[0].solo);
    try std.testing.expect(eq.bands[2].solo);
}

test "dynamic EQ only applies boost once the band's energy crosses threshold" {
    var eq = ParametricEq.init(48_000);
    eq.setFreq(0, 1000.0);
    eq.setQ(0, 1.0);
    eq.setGain(0, 0.0);
    eq.setType(0, .peak, 1);
    eq.setDynEnabled(0, true);
    eq.setDynThreshold(0, -20.0);
    eq.setDynAmount(0, 18.0);

    var buf: [512]Sample = undefined;
    var phase: f32 = 0.0;
    // Quiet input: shouldn't cross threshold, band stays near its base 0dB.
    for (0..80) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const s = 0.001 * std.math.sin(phase);
            buf[i] = s;
            buf[i + 1] = s;
            phase += 2.0 * std.math.pi * 1000.0 / 48_000.0;
        }
        eq.processBlock(&buf);
    }
    try std.testing.expect(eq.bands[0].dyn_factor < 0.1);

    // Loud input: crosses threshold, factor should climb toward 1.
    for (0..200) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const s = 0.5 * std.math.sin(phase);
            buf[i] = s;
            buf[i + 1] = s;
            phase += 2.0 * std.math.pi * 1000.0 / 48_000.0;
        }
        eq.processBlock(&buf);
    }
    try std.testing.expect(eq.bands[0].dyn_factor > 0.8);
}

test "switching dynamic off puts the static gain back" {
    // The detector's boost lives in the band's coefficients, and only the
    // dynamic path in processBlock ever writes them, so turning dynamic off
    // used to leave the band stuck at whatever the detector last drove it to.
    var eq = ParametricEq.init(48_000);
    eq.setFreq(0, 1000.0);
    eq.setQ(0, 1.0);
    eq.setGain(0, 0.0);
    eq.setDynEnabled(0, true);
    eq.setDynThreshold(0, -20.0);
    eq.setDynAmount(0, 18.0);
    const flat = bandMagnitude(&eq.bands[0], 1000.0, eq.sr);

    var buf: [512]Sample = undefined;
    var phase: f32 = 0.0;
    for (0..200) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const s = 0.5 * std.math.sin(phase);
            buf[i] = s;
            buf[i + 1] = s;
            phase += 2.0 * std.math.pi * 1000.0 / 48_000.0;
        }
        eq.processBlock(&buf);
    }
    try std.testing.expect(bandMagnitude(&eq.bands[0], 1000.0, eq.sr) > flat * 4.0);

    eq.setDynEnabled(0, false);
    try std.testing.expectApproxEqAbs(flat, bandMagnitude(&eq.bands[0], 1000.0, eq.sr), 1e-4);
}

test "dynamic EQ leaves non-gain kinds alone" {
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .lowpass, 1);
    eq.setDynEnabled(0, true);
    try std.testing.expect(!eq.bands[0].dyn_enabled);
}

test "mid/side band affects only the targeted channel-sum signal" {
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .lowpass, 4);
    eq.setFreq(0, 300.0);
    eq.setStereoMode(0, .mid);

    // Pure side content (L = -R): a mid-only lowpass must leave it intact.
    var buf: [512]Sample = undefined;
    for (0..20) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            buf[i] = 1.0;
            buf[i + 1] = -1.0;
        }
        eq.processBlock(&buf);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), buf[510], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), buf[511], 0.01);
}

test "auto gain compensates a broadband boost toward unity average" {
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .lowshelf, 1);
    eq.setFreq(0, 20000.0); // shelves the whole band up
    eq.setGain(0, 12.0);
    eq.setAutoGain(true);
    try std.testing.expect(eq.auto_gain_db < -3.0);

    eq.setAutoGain(false);
    try std.testing.expectEqual(@as(f32, 0.0), eq.auto_gain_db);
}

test "disabled EQ bands leave audio unchanged" {
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .lowpass, 4);
    eq.setFreq(0, 200.0);
    for (0..num_eq_bands) |i| eq.setEnabled(i, false);

    var buf = [_]Sample{ 0.25, -0.5, 0.75, -1.0 };
    const input = buf;
    eq.processBlock(&buf);
    try std.testing.expectEqualSlices(Sample, &input, &buf);
}

test "a band above the device's Nyquist does not blow the EQ up" {
    // Band frequencies clamp to 20 kHz, but a project may be loaded at any
    // rate down to 8 kHz, where that is far above Nyquist. Past Nyquist the
    // cookbook design's `alpha` can come out negative and the biquad turns
    // into an oscillator.
    var eq = ParametricEq.init(8_000);
    eq.setFreq(0, 20_000.0);
    eq.setGain(0, 12.0);
    var buf: [512]Sample = undefined;
    for (0..50) |_| {
        for (&buf, 0..) |*s, i| s.* = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
        eq.processBlock(&buf);
        for (buf) |s| try std.testing.expect(std.math.isFinite(s) and @abs(s) < 16.0);
    }
}

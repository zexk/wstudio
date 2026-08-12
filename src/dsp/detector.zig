//! What a dynamics unit listens to, separated from what it does about it.
//!
//! Every unit that reacts to level wants the same three choices - peak or
//! RMS, a detector high-pass, a detector low-pass - and none of them have
//! anything to do with whether the unit compresses, gates or expands. The
//! shaping lives here so those units share one implementation (and one set
//! of defaults that mean "unshaped"), the way LSP's `Sidechain` is a class
//! every dynamics plugin owns rather than a field on each.
//!
//! The params stay on each unit rather than moving in here with the state:
//! they are automatable rows in a flat spec table and positional fields in
//! the save file, both of which want them flat.

const std = @import("std");
const dsp = @import("device.zig");

/// A detector filter under this reads as "off" - a 10 Hz high-pass does
/// nothing a dynamics unit can hear, and the zero value has to mean off so
/// the unshaped path stays the default.
pub const min_filter_hz: f32 = 20.0;

/// RMS averaging window. ponytail: fixed, where LSP exposes it as
/// "reactivity" - attack/release already own how fast a unit moves, and a
/// second timing axis is a knob most users would leave alone. Promote it to
/// a param if material turns up that needs a slower average.
const rms_window_ms: f32 = 10.0;

/// One-pole smoothing coefficient for a cutoff in Hz (0 when the cutoff is
/// unset, which leaves the filter state frozen and the signal untouched).
fn onePoleCoef(hz: f32, sample_rate: f32) f32 {
    if (hz <= 0.0 or sample_rate <= 0.0) return 0.0;
    return 1.0 - @exp(-2.0 * std.math.pi * hz / sample_rate);
}

/// Block-rate coefficients, computed once per `processBlock` rather than per
/// frame. Build with `shapingFor`.
pub const Shaping = struct {
    hp_on: bool = false,
    lp_on: bool = false,
    rms: bool = false,
    hp_a: f32 = 0.0,
    lp_a: f32 = 0.0,
    rms_a: f32 = 0.0,

    /// False means the detector is the plain stereo peak it was before any
    /// of this existed, bit for bit.
    pub fn active(self: Shaping) bool {
        return self.hp_on or self.lp_on or self.rms;
    }
};

/// `hpf_hz`/`lpf_hz`/`rms_on` come from the calling unit's own params, which
/// it has already clamped.
pub fn shapingFor(hpf_hz: f32, lpf_hz: f32, rms_on: bool, sample_rate: f32) Shaping {
    return .{
        .hp_on = hpf_hz >= min_filter_hz,
        .lp_on = lpf_hz >= min_filter_hz and lpf_hz < 20_000.0,
        .rms = rms_on,
        .hp_a = onePoleCoef(hpf_hz, sample_rate),
        .lp_a = onePoleCoef(lpf_hz, sample_rate),
        .rms_a = 1.0 - dsp.smoothingCoefMs(rms_window_ms, sample_rate),
    };
}

/// Filter and rectification state. One set per unit: the detector collapses
/// to mono before shaping, so there is nothing per-channel to keep.
pub const Detector = struct {
    lp: f32 = 0.0,
    hp: f32 = 0.0,
    ms: f32 = 0.0,

    pub fn reset(self: *Detector) void {
        self.* = .{};
    }

    /// The level this frame's pair of detector samples reports.
    pub fn level(self: *Detector, sh: Shaping, dl: f32, dr: f32) f32 {
        if (!sh.active()) return @max(@abs(dl), @abs(dr));
        // Filtering a rectified level is meaningless, so the shaped path
        // sums to mono and filters the waveform, then rectifies.
        var x = (dl + dr) * 0.5;
        if (sh.lp_on) {
            self.lp += sh.lp_a * (x - self.lp);
            x = self.lp;
        }
        if (sh.hp_on) {
            self.hp += sh.hp_a * (x - self.hp);
            x -= self.hp;
        }
        if (!sh.rms) return @abs(x);
        self.ms += sh.rms_a * (x * x - self.ms);
        return @sqrt(@max(self.ms, 0.0));
    }
};

test "an unshaped detector is the plain stereo peak" {
    var det: Detector = .{};
    const sh = shapingFor(0.0, 0.0, false, 48_000.0);
    try std.testing.expect(!sh.active());
    try std.testing.expectEqual(@as(f32, 0.8), det.level(sh, -0.8, 0.3));
}

test "the high-pass keeps a dynamics unit from keying off bass" {
    // The reason the control exists: a loud low tone should stop holding the
    // detector up once it is filtered out.
    var det: Detector = .{};
    const sh = shapingFor(500.0, 0.0, false, 48_000.0);
    var peak: f32 = 0.0;
    for (0..4800) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        const x = @sin(2.0 * std.math.pi * 50.0 * t);
        const l = det.level(sh, x, x);
        if (i > 2400) peak = @max(peak, l);
    }
    try std.testing.expect(peak < 0.2);
}

test "RMS reads a square wave at its amplitude and a sine below it" {
    const sh = shapingFor(0.0, 0.0, true, 48_000.0);
    var square: Detector = .{};
    var sine: Detector = .{};
    var square_peak: f32 = 0.0;
    var sine_peak: f32 = 0.0;
    for (0..48_000) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        const s = @sin(2.0 * std.math.pi * 200.0 * t);
        const sq: f32 = if (s >= 0.0) 1.0 else -1.0;
        const a = square.level(sh, sq, sq);
        const b = sine.level(sh, s, s);
        if (i > 24_000) {
            square_peak = @max(square_peak, a);
            sine_peak = @max(sine_peak, b);
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), square_peak, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 0.707), sine_peak, 0.03);
}

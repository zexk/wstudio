//! Noise gate: attenuates the signal while it stays under the threshold.
//! Stereo-linked peak detector with a short fixed decay drives a smoothed
//! open/close gain; attack sets how fast the gate opens on a transient,
//! release how fast it falls shut after the input drops away. `hold_ms`
//! keeps the gate pinned open for a fixed time after the level drops back
//! under threshold, before release starts - without it, a signal hovering
//! right at the threshold (decaying drum tail, noisy sustain) chatters the
//! gate open/shut instead of falling smoothly.
//!
//! `hysteresis_db` closes the gate at a *lower* level than the one that
//! opened it, which is the structural fix for that same chatter: with a
//! gap between the two thresholds no level can sit on the boundary and
//! flip state every frame. Hold only bounds how long a flip is deferred;
//! hysteresis makes it impossible. Both exist because they solve different
//! halves (hold covers a signal that genuinely dips, hysteresis covers one
//! that hovers). LSP's gate carries the same pair.
//!
//! `range_db` is how far a shut gate attenuates instead of silencing. Full
//! mute is the wrong default for drums (it swallows room tone and cymbal
//! bleed between hits, which is what makes gated kits sound synthetic), so
//! the control exists - but the *default* stays full mute, both to keep
//! saved projects sounding identical and because "gate" reads as "off".

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const detector = @import("detector.zig");

const Sample = types.Sample;

/// `range_db` at or under this reads as full mute rather than -80dB of
/// attenuation, so the default gate is bit-identical to the pre-range one.
pub const mute_range_db: f32 = -80.0;

pub const Gate = struct {
    sample_rate: f32 = 48_000.0,
    threshold_db: f32 = -50.0,
    attack_ms: f32 = 1.0,
    release_ms: f32 = 100.0,
    /// How long the gate stays pinned open after the level falls back under
    /// threshold, before release begins. 0 = old behaviour (release starts
    /// immediately).
    hold_ms: f32 = 0.0,
    /// How far below `threshold_db` the level has to fall before an open
    /// gate closes again. 0 = old behaviour (one threshold both ways).
    hysteresis_db: f32 = 0.0,
    /// Gain a shut gate falls to, in dB. `mute_range_db` (the minimum) is
    /// exact silence, which is the default and the old behaviour.
    range_db: f32 = mute_range_db,
    /// Detector shaping, the same three controls the compressor has - see
    /// `dsp/detector.zig`. 0 = peak, 1 = RMS. The high-pass is what stops a
    /// bass-heavy source from holding a gate open through everything, which
    /// on a drum bus is the difference between gating the snare and gating
    /// nothing at all.
    sc_mode: f32 = 0.0,
    sc_hpf_hz: f32 = 0.0,
    sc_lpf_hz: f32 = 0.0,
    /// Detector filter/RMS state.
    det_state: detector.Detector = .{},
    /// Detector state: stereo peak with a fixed ~50ms decay.
    env: f32 = 0.0,
    /// Current gain: `range` shut ... 1 open. Starts shut so a track that
    /// begins under the threshold doesn't leak its first buffer.
    gain: f32 = 0.0,
    /// Frames left in the current hold window, counted down one per frame.
    hold_left: f32 = 0.0,
    /// Latched detector state - which of the two thresholds applies next.
    /// Only meaningful when `hysteresis_db` > 0.
    open: bool = false,

    pub fn init(sample_rate: u32) Gate {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
    }

    pub const device = dsp.deviceOf(@This());

    /// Gate an interleaved stereo buffer in place.
    pub fn processBlock(self: *Gate, buf: []Sample) void {
        // A negative/zero attack_ms or release_ms flips the exponent
        // positive, giving a decay coefficient >= 1 - the envelope/gain
        // recurrences below then diverge geometrically within one block.
        const threshold_db = dsp.sanitizeParam(self.threshold_db, -80.0, 0.0, -50.0);
        const attack_ms = dsp.sanitizeParam(self.attack_ms, 0.1, 50.0, 1.0);
        const release_ms = dsp.sanitizeParam(self.release_ms, 5.0, 1000.0, 100.0);
        const hold_ms = dsp.sanitizeParam(self.hold_ms, 0.0, 500.0, 0.0);
        const hysteresis_db = dsp.sanitizeParam(self.hysteresis_db, 0.0, 40.0, 0.0);
        const range_db = dsp.sanitizeParam(self.range_db, mute_range_db, 0.0, mute_range_db);
        if (!std.math.isFinite(self.hold_left) or self.hold_left < 0.0) self.hold_left = 0.0;
        // zig fmt: off
        const thresh      = types.dbToGain(threshold_db);
        const close_thresh = types.dbToGain(threshold_db - hysteresis_db);
        const shut         = if (range_db <= mute_range_db) 0.0 else types.dbToGain(range_db);
        const det_decay   = @exp(-1.0 / (0.050 * self.sample_rate));
        const attack      = dsp.smoothingCoefMs(attack_ms, self.sample_rate);
        const release     = dsp.smoothingCoefMs(release_ms, self.sample_rate);
        const hold_frames = hold_ms * 0.001 * self.sample_rate;
        // zig fmt: on
        // Left at its defaults this is the same stereo peak the gate always
        // read, bit for bit.
        const shaping = detector.shapingFor(
            dsp.sanitizeParam(self.sc_hpf_hz, 0.0, 2000.0, 0.0),
            dsp.sanitizeParam(self.sc_lpf_hz, 0.0, 20_000.0, 0.0),
            dsp.sanitizeParam(self.sc_mode, 0.0, 1.0, 0.0) >= 0.5,
            self.sample_rate,
        );
        if (!shaping.active()) self.det_state.reset();
        // zig fmt: off
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const peak = self.det_state.level(shaping, buf[i], buf[i + 1]);
            self.env = @max(peak, self.env * det_decay);
            // Latch: an open gate holds open until the level drops under the
            // lower close threshold, so nothing can sit on the boundary and
            // flip every frame. With hysteresis 0 both thresholds coincide
            // and this reduces exactly to the old single comparison.
            self.open = if (self.open) self.env >= close_thresh else self.env >= thresh;
            const above = self.open;
            if (above) {
                self.hold_left = hold_frames;
            } else if (self.hold_left > 0.0) {
                self.hold_left -= 1.0;
            }
            const target: f32 = if (above or self.hold_left > 0.0) 1.0 else shut;
            const coef = if (target > self.gain) attack else release;
            self.gain = target + coef * (self.gain - target);
            buf[i]     *= self.gain;
            // zig fmt: on
            buf[i + 1] *= self.gain;
        }
    }

    /// Clears detector/gain state without touching `sample_rate` - callers
    /// embedding a `Gate` by value (`rack.FxPayload` holds every unit that
    /// way) must use this instead of `= .{}`, which would reset sample_rate
    /// to the struct default and desync it from the real session rate.
    pub fn reset(self: *Gate) void {
        self.env = 0.0;
        self.det_state.reset();
        self.gain = 0.0;
        self.hold_left = 0.0;
        self.open = false;
    }
};

// ---------------------------------------------------------------------------
// Tests

test "loud input opens the gate to near unity" {
    var gate = Gate.init(48_000);
    var buf: [4096]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = if (i % 4 < 2) 0.5 else -0.5;
    gate.processBlock(&buf);
    try std.testing.expect(gate.gain > 0.99);
    // Past the 1ms attack the signal passes essentially untouched.
    try std.testing.expectApproxEqAbs(@as(Sample, 0.5), @abs(buf[4000]), 1e-2);
}

test "sub-threshold input stays shut" {
    var gate = Gate.init(48_000);
    gate.threshold_db = -20.0;
    var buf: [4096]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = 0.01 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    gate.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
}

test "hold keeps the gate open before release begins" {
    var gate = Gate.init(48_000);
    gate.release_ms = 1.0; // fast, so release-phase decay is easy to see
    gate.hold_ms = 50.0; // 2400 frames
    var loud: [4096]Sample = undefined;
    @memset(&loud, 0.5);
    gate.processBlock(&loud);
    try std.testing.expect(gate.gain > 0.99);

    // Force the detector envelope down immediately so hold's effect, not
    // the detector's own ~50ms decay, is what's under test.
    gate.env = 0.0;

    // 1000 frames of silence: well within the 2400-frame hold window.
    var silence: [2000]Sample = undefined;
    @memset(&silence, 0.0);
    gate.processBlock(&silence);
    try std.testing.expect(gate.gain > 0.99);

    // Push well past the hold window - the fast release should now have
    // pulled gain down close to zero.
    var i: usize = 0;
    while (i < 5) : (i += 1) gate.processBlock(&silence);
    try std.testing.expect(gate.gain < 0.01);
}

test "hysteresis keeps a hovering level from chattering the gate" {
    // A level parked exactly on the threshold: without hysteresis the
    // detector's own decay dips it under and back over, toggling state.
    var gate = Gate.init(48_000);
    gate.threshold_db = -20.0;
    gate.hysteresis_db = 6.0;
    gate.hold_ms = 0.0;

    var buf: [4096]Sample = undefined;
    @memset(&buf, 0.5); // well over -20dB: opens
    gate.processBlock(&buf);
    try std.testing.expect(gate.open);

    // -23dB, under the open threshold but over the -26dB close threshold.
    @memset(&buf, types.dbToGain(-23.0));
    gate.processBlock(&buf);
    try std.testing.expect(gate.open);
    try std.testing.expect(gate.gain > 0.99);

    // -30dB clears the close threshold too, so it finally shuts.
    @memset(&buf, types.dbToGain(-30.0));
    var i: usize = 0;
    while (i < 20) : (i += 1) gate.processBlock(&buf);
    try std.testing.expect(!gate.open);
    try std.testing.expect(gate.gain < 0.01);
}

test "range attenuates instead of muting a shut gate" {
    var gate = Gate.init(48_000);
    gate.threshold_db = -20.0;
    gate.range_db = -12.0;
    gate.release_ms = 5.0;

    var buf: [4096]Sample = undefined;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        @memset(&buf, 0.01); // -40dB, under threshold
        gate.processBlock(&buf);
    }
    // Shut, but at -12dB rather than silent.
    try std.testing.expectApproxEqAbs(types.dbToGain(-12.0), gate.gain, 1e-3);
    try std.testing.expect(@abs(buf[4000]) > 0.0);
}

test "the detector high-pass stops bass from holding the gate open" {
    // A kick under a gated snare: loud low content that should not count as
    // "signal" once the detector is told to ignore it.
    var plain = Gate.init(48_000);
    plain.threshold_db = -20.0;
    var filtered = Gate.init(48_000);
    filtered.threshold_db = -20.0;
    filtered.sc_hpf_hz = 500.0;

    var buf: [4096]Sample = undefined;
    for (0..20) |blk| {
        for (0..buf.len / 2) |f| {
            const n: f32 = @floatFromInt(blk * (buf.len / 2) + f);
            const v = 0.9 * @sin(2.0 * std.math.pi * 50.0 * n / 48_000.0);
            buf[f * 2] = v;
            buf[f * 2 + 1] = v;
        }
        var copy = buf;
        plain.processBlock(&buf);
        filtered.processBlock(&copy);
    }
    try std.testing.expect(plain.open);
    try std.testing.expect(!filtered.open);
}

test "invalid parameters cannot trap or poison output" {
    var gate = Gate.init(48_000);
    gate.threshold_db = std.math.nan(f32);
    gate.attack_ms = -1.0;
    gate.release_ms = std.math.inf(f32);
    var buf: [256]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = if (i % 4 < 2) 0.5 else -0.5;
    gate.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "gate falls shut after the input drops away" {
    var gate = Gate.init(48_000);
    gate.release_ms = 20.0;
    var buf: [4096]Sample = undefined;
    @memset(&buf, 0.5);
    gate.processBlock(&buf);
    try std.testing.expect(gate.gain > 0.99);

    // ~0.5s of silence: detector and gain both decay to nothing.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        @memset(&buf, 0.0);
        gate.processBlock(&buf);
    }
    try std.testing.expect(gate.gain < 1e-3);
}

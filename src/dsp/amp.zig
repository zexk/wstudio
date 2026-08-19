//! Guitar amplifier: the four stages a modelled amp is conventionally split
//! into (preamp, tone stack, power amp, speaker cabinet), each taken at the
//! cheapest form that still behaves like the circuit rather than like a
//! generic distortion box.
//!
//!   preamp     two to four cascaded asymmetric triode-ish stages, each fed
//!              through its own coupling capacitor, run at 2x oversampling.
//!   tone stack the passive Fender/Marshall network in closed form, so BASS,
//!              MID and TREBLE interact the way the circuit does - MID at
//!              zero scoops and pulls the other two with it, which is the
//!              part three independent shelves cannot fake.
//!   power amp  one symmetric soft-clip driven by MASTER, for the
//!              compression that arrives after the tone controls.
//!   cabinet    a fixed filter chain rather than a convolved impulse
//!              response: resonant high-pass at the speaker's own resonance,
//!              a mid notch, a presence bump, and a steep roll-off past the
//!              range a guitar speaker stops radiating in.
//!
//! MODEL picks one voicing of all four at once (see `voicings`), because the
//! stage count, the tone-stack component values and the cabinet are what
//! actually separate a clean amp from a lead amp - not a different curve on
//! one clipper.
//!
//! The coupling capacitor before *every* gain stage is what keeps chords
//! together. A clipper is not linear, so two notes hit at once produce sum
//! and difference tones as well as harmonics, and the difference tones land
//! below both fundamentals where they read as mud. Real amps get away with
//! it because each stage's coupling cap has already thrown the lows away by
//! the time the gain is high; an amp sim that low-cuts only at the cabinet
//! has already generated the mud upstream and is merely filtering it. TIGHT
//! moves that corner, since how much low end belongs in front of the
//! clipper is a taste decision, not a constant.
//!
//! ponytail: the cabinet is filters, not an IR - a real 4x12 has comb
//! structure from the mic position that no five biquads reproduce. Upgrade
//! path is a convolution stage with bundled IRs, which also needs an IR
//! file format and a partitioned convolver; the filter chain is what every
//! analog cab sim did and it lands in the right place.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const oversample = @import("oversample.zig");

const Sample = types.Sample;

/// Largest `Voicing.stages`, and so how much per-channel coupling-cap state
/// every amp carries whether its voicing uses it or not.
const max_stages: usize = 4;

/// Coupling capacitors per channel: one in front of every stage, plus the
/// one between the last stage and the tone stack.
const max_couplings: usize = max_stages + 1;

// ---------------------------------------------------------------------------
// Voicings

/// One amp's worth of choices. The topology is identical across all three -
/// only component values, stage count and cabinet corners move, which is
/// also how the real amps relate to each other.
const Voicing = struct {
    /// Tone-stack components, Yeh & Smith's naming (DAFx-06, fig. 1):
    /// `r1` treble pot, `r2` bass pot, `r3` mid pot, `r4` slope resistor,
    /// `c1` treble cap, `c2` bass cap, `c3` mid cap.
    c1: f64,
    c2: f64,
    c3: f64,
    r1: f64,
    r2: f64,
    r3: f64,
    r4: f64,
    /// Fixed make-up after the tone stack. The network is passive and lossy,
    /// and how lossy depends on the slope resistor, so this is per voicing
    /// rather than one constant: without it MASTER would have to be cranked
    /// before anything reached the power stage.
    makeup_db: f32,
    /// Cascaded gain stages. Two is a classic single-channel amp; four is a
    /// high-gain preamp, where the gain comes from the count and not from
    /// driving one stage harder.
    stages: u8,
    /// Gain into every stage after the first. The first one gets DRIVE.
    stage_gain: f32,
    /// Negative-half gain of a stage. A triode conducts harder on one half
    /// of the swing; this asymmetry is what puts even harmonics in. The side
    /// alternates per stage, as it does down a real cascade.
    asym: f32,
    /// Coupling-cap corner in front of each gain stage, before TIGHT scales
    /// it. Cascaded `stages` times, so a high-gain voicing is steeper below
    /// its corner as well as higher.
    hp_hz: f32,
    cab_hp_hz: f32,
    cab_hp_q: f32,
    notch_hz: f32,
    notch_db: f32,
    presence_hz: f32,
    presence_db: f32,
    lp_hz: f32,
};

/// Indexed by the MODEL param. Names stay generic on purpose: these are
/// voicings, not impressions of a particular badge.
pub const model_names = [_][]const u8{ "clean", "crunch", "lead" };

const voicings = [model_names.len]Voicing{
    // '59 Bassman tone stack (the values Yeh & Smith published), two stages
    // and an open-back combo that keeps more top than a closed 4x12.
    .{
        .c1 = 250e-12,
        .c2 = 20e-9,
        .c3 = 20e-9,
        .r1 = 250e3,
        .r2 = 1e6,
        .r3 = 25e3,
        .r4 = 56e3,
        .makeup_db = 14.0,
        .stages = 2,
        .stage_gain = 2.0,
        .asym = 0.7,
        .hp_hz = 100.0,
        .cab_hp_hz = 90.0,
        .cab_hp_q = 0.9,
        .notch_hz = 1900.0,
        .notch_db = -3.0,
        .presence_hz = 3600.0,
        .presence_db = 3.5,
        .lp_hz = 5500.0,
    },
    // The same network with the British values - 500pF treble cap and a 33k
    // slope resistor, which is most of why that amp has mids where the
    // Fender has a scoop - three stages, closed-back 4x12.
    .{
        .c1 = 500e-12,
        .c2 = 22e-9,
        .c3 = 22e-9,
        .r1 = 220e3,
        .r2 = 1e6,
        .r3 = 25e3,
        .r4 = 33e3,
        .makeup_db = 12.0,
        .stages = 3,
        .stage_gain = 1.9,
        .asym = 0.75,
        .hp_hz = 115.0,
        .cab_hp_hz = 95.0,
        .cab_hp_q = 1.1,
        .notch_hz = 1600.0,
        .notch_db = -5.0,
        .presence_hz = 3200.0,
        .presence_db = 4.0,
        .lp_hz = 4500.0,
    },
    // Modern high-gain: four stages, a 10k mid pot so MID at zero scoops
    // much further, and a coupling corner high enough that the fundamental
    // of a low chord never reaches the clipping stages.
    .{
        .c1 = 470e-12,
        .c2 = 22e-9,
        .c3 = 22e-9,
        .r1 = 220e3,
        .r2 = 1e6,
        .r3 = 10e3,
        .r4 = 33e3,
        .makeup_db = 12.0,
        .stages = 4,
        .stage_gain = 1.8,
        .asym = 0.8,
        .hp_hz = 130.0,
        .cab_hp_hz = 90.0,
        .cab_hp_q = 1.25,
        .notch_hz = 1500.0,
        .notch_db = -6.0,
        .presence_hz = 3400.0,
        .presence_db = 5.0,
        .lp_hz = 4200.0,
    },
};

// ---------------------------------------------------------------------------
// Biquad

/// One RBJ-cookbook biquad section. Same math as `dsp/eq.zig` and
/// `dsp/meter.zig` keep privately; a fifth copy of five lines beats
/// exporting a shared filter type that three call sites would each need a
/// different subset of.
const Biquad = struct {
    b0: f32 = 1,
    b1: f32 = 0,
    b2: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    x1: [2]f32 = .{ 0, 0 },
    x2: [2]f32 = .{ 0, 0 },
    y1: [2]f32 = .{ 0, 0 },
    y2: [2]f32 = .{ 0, 0 },

    const Kind = enum { lowpass, highpass, peak };

    /// A project can be loaded at any rate down to 8 kHz, where this file's
    /// fixed cabinet frequencies sit above Nyquist and the cookbook design
    /// turns into an oscillator - so the design frequency is pinned here
    /// rather than at each call site (same rule `dsp/eq.zig` applies).
    fn set(self: *Biquad, kind: Kind, sr: f32, freq: f32, q: f32, gain_db: f32) void {
        const w0 = 2.0 * std.math.pi * @min(freq, sr * 0.45) / sr;
        const cos_w0 = @cos(w0);
        const alpha = @sin(w0) / (2.0 * q);
        switch (kind) {
            .lowpass => {
                const a0 = 1 + alpha;
                self.b0 = (1 - cos_w0) * 0.5 / a0;
                self.b1 = (1 - cos_w0) / a0;
                self.b2 = self.b0;
                self.a1 = -2 * cos_w0 / a0;
                self.a2 = (1 - alpha) / a0;
            },
            .highpass => {
                const a0 = 1 + alpha;
                self.b0 = (1 + cos_w0) * 0.5 / a0;
                self.b1 = -(1 + cos_w0) / a0;
                self.b2 = self.b0;
                self.a1 = -2 * cos_w0 / a0;
                self.a2 = (1 - alpha) / a0;
            },
            .peak => {
                const amp = std.math.pow(f32, 10.0, gain_db / 40.0);
                const a0 = 1 + alpha / amp;
                self.b0 = (1 + alpha * amp) / a0;
                self.b1 = -2 * cos_w0 / a0;
                self.b2 = (1 - alpha * amp) / a0;
                self.a1 = self.b1;
                self.a2 = (1 - alpha / amp) / a0;
            },
        }
    }

    fn step(self: *Biquad, ch: usize, x: f32) f32 {
        const y = self.b0 * x + self.b1 * self.x1[ch] + self.b2 * self.x2[ch] -
            self.a1 * self.y1[ch] - self.a2 * self.y2[ch];
        self.x2[ch] = self.x1[ch];
        self.x1[ch] = x;
        self.y2[ch] = self.y1[ch];
        self.y1[ch] = y;
        return y;
    }

    fn magDb(self: *const Biquad, w: f32) f32 {
        return sectionDb(&.{ self.b0, self.b1, self.b2 }, &.{ self.a1, self.a2 }, w);
    }

    fn clear(self: *Biquad) void {
        self.x1 = .{ 0, 0 };
        self.x2 = .{ 0, 0 };
        self.y1 = .{ 0, 0 };
        self.y2 = .{ 0, 0 };
    }
};

/// `20*log10 |H(e^jw)|` for a direct-form section whose denominator is
/// `1 + a[0] z^-1 + a[1] z^-2 ...`. Only the GUI's response curve calls
/// this; nothing on the audio thread evaluates a transfer function.
fn sectionDb(b: []const f32, a: []const f32, w: f32) f32 {
    var nr: f32 = 0;
    var ni: f32 = 0;
    for (b, 0..) |c, k| {
        const th = -w * @as(f32, @floatFromInt(k));
        nr += c * @cos(th);
        ni += c * @sin(th);
    }
    var dr: f32 = 1;
    var di: f32 = 0;
    for (a, 0..) |c, k| {
        const th = -w * @as(f32, @floatFromInt(k + 1));
        dr += c * @cos(th);
        di += c * @sin(th);
    }
    const num = @sqrt(nr * nr + ni * ni);
    const den = @max(@sqrt(dr * dr + di * di), 1e-12);
    return types.gainToDb(@max(num / den, 1e-9));
}

// ---------------------------------------------------------------------------
// Tone stack

/// Third-order direct-form-I section, coefficients recomputed per block from
/// the three pot positions and the voicing's components. Held in f64 during
/// design: the `m^2` terms very nearly cancel the `m` terms and the products
/// span 1e-25 to 1e15, which f32 loses.
const ToneStack = struct {
    b: [4]f32 = .{ 1, 0, 0, 0 },
    a: [3]f32 = .{ 0, 0, 0 },
    x: [2][3]f32 = .{.{ 0, 0, 0 }} ** 2,
    y: [2][3]f32 = .{.{ 0, 0, 0 }} ** 2,

    /// `t`/`m`/`l` are the treble, middle and bass wiper fractions, already
    /// tapered by the caller.
    fn design(self: *ToneStack, sr: f32, t_in: f32, m_in: f32, l_in: f32, v: *const Voicing) void {
        const t: f64 = t_in;
        const m: f64 = m_in;
        const l: f64 = l_in;
        const c1 = v.c1;
        const c2 = v.c2;
        const c3 = v.c3;
        const r1 = v.r1;
        const r2 = v.r2;
        const r3 = v.r3;
        const r4 = v.r4;

        // Continuous-time numerator and denominator, eqn. 1 of the paper.
        const b1 = t * c1 * r1 + m * c3 * r3 + l * (c1 * r2 + c2 * r2) + (c1 * r3 + c2 * r3);
        const b2 = t * (c1 * c2 * r1 * r4 + c1 * c3 * r1 * r4) -
            m * m * (c1 * c3 * r3 * r3 + c2 * c3 * r3 * r3) +
            m * (c1 * c3 * r1 * r3 + c1 * c3 * r3 * r3 + c2 * c3 * r3 * r3) +
            l * (c1 * c2 * r1 * r2 + c1 * c2 * r2 * r4 + c1 * c3 * r2 * r4) +
            l * m * (c1 * c3 * r2 * r3 + c2 * c3 * r2 * r3) +
            (c1 * c2 * r1 * r3 + c1 * c2 * r3 * r4 + c1 * c3 * r3 * r4);
        const b3 = l * m * (c1 * c2 * c3 * r1 * r2 * r3 + c1 * c2 * c3 * r2 * r3 * r4) -
            m * m * (c1 * c2 * c3 * r1 * r3 * r3 + c1 * c2 * c3 * r3 * r3 * r4) +
            m * (c1 * c2 * c3 * r1 * r3 * r3 + c1 * c2 * c3 * r3 * r3 * r4) +
            t * c1 * c2 * c3 * r1 * r3 * r4 - t * m * c1 * c2 * c3 * r1 * r3 * r4 +
            t * l * c1 * c2 * c3 * r1 * r2 * r4;

        const a0: f64 = 1;
        const a1 = (c1 * r1 + c1 * r3 + c2 * r3 + c2 * r4 + c3 * r4) +
            m * c3 * r3 + l * (c1 * r2 + c2 * r2);
        const a2 = m * (c1 * c3 * r1 * r3 - c2 * c3 * r3 * r4 + c1 * c3 * r3 * r3 + c2 * c3 * r3 * r3) +
            l * m * (c1 * c3 * r2 * r3 + c2 * c3 * r2 * r3) -
            m * m * (c1 * c3 * r3 * r3 + c2 * c3 * r3 * r3) +
            l * (c1 * c2 * r2 * r4 + c1 * c2 * r1 * r2 + c1 * c3 * r2 * r4 + c2 * c3 * r2 * r4) +
            (c1 * c2 * r1 * r4 + c1 * c3 * r1 * r4 + c1 * c2 * r3 * r4 +
                c1 * c2 * r1 * r3 + c1 * c3 * r3 * r4 + c2 * c3 * r3 * r4);
        const a3 = l * m * (c1 * c2 * c3 * r1 * r2 * r3 + c1 * c2 * c3 * r2 * r3 * r4) -
            m * m * (c1 * c2 * c3 * r1 * r3 * r3 + c1 * c2 * c3 * r3 * r3 * r4) +
            m * (c1 * c2 * c3 * r3 * r3 * r4 + c1 * c2 * c3 * r1 * r3 * r3 - c1 * c2 * c3 * r1 * r3 * r4) +
            l * c1 * c2 * c3 * r1 * r2 * r4 +
            c1 * c2 * c3 * r1 * r3 * r4;

        // Bilinear transform with c = 2/T, eqn. 2. The paper's A/B are the
        // z^-n coefficients before normalisation; A0 is negative, which is
        // why every term below is divided by it rather than by |A0|.
        const c: f64 = 2.0 * @as(f64, sr);
        const c2p = c * c;
        const c3p = c2p * c;
        const bb = [4]f64{
            -b1 * c - b2 * c2p - b3 * c3p,
            -b1 * c + b2 * c2p + 3 * b3 * c3p,
            b1 * c + b2 * c2p - 3 * b3 * c3p,
            b1 * c - b2 * c2p + b3 * c3p,
        };
        const aa = [4]f64{
            -a0 - a1 * c - a2 * c2p - a3 * c3p,
            -3 * a0 - a1 * c + a2 * c2p + 3 * a3 * c3p,
            -3 * a0 + a1 * c + a2 * c2p - 3 * a3 * c3p,
            -a0 + a1 * c - a2 * c2p + a3 * c3p,
        };
        // A0 is a sum of same-sign negatives and cannot reach zero for any
        // pot setting, but a hostile sample rate could still make it tiny.
        if (!(@abs(aa[0]) > 1e-30)) return;
        for (&self.b, bb) |*dst, src| dst.* = @floatCast(src / aa[0]);
        for (&self.a, aa[1..]) |*dst, src| dst.* = @floatCast(src / aa[0]);
        for (self.b) |v2| if (!std.math.isFinite(v2)) return self.bypass();
        for (self.a) |v2| if (!std.math.isFinite(v2)) return self.bypass();
    }

    fn bypass(self: *ToneStack) void {
        self.b = .{ 1, 0, 0, 0 };
        self.a = .{ 0, 0, 0 };
    }

    fn step(self: *ToneStack, ch: usize, input: f32) f32 {
        const x = &self.x[ch];
        const y = &self.y[ch];
        const out = self.b[0] * input + self.b[1] * x[0] + self.b[2] * x[1] + self.b[3] * x[2] -
            self.a[0] * y[0] - self.a[1] * y[1] - self.a[2] * y[2];
        x[2] = x[1];
        x[1] = x[0];
        x[0] = input;
        y[2] = y[1];
        y[1] = y[0];
        y[0] = out;
        return out;
    }

    fn clear(self: *ToneStack) void {
        self.x = .{.{ 0, 0, 0 }} ** 2;
        self.y = .{.{ 0, 0, 0 }} ** 2;
    }
};

// ---------------------------------------------------------------------------
// Amp

pub const Amp = struct {
    sample_rate: f32,
    /// Preamp gain into the first stage. The whole usable range of the
    /// chosen voicing lives here: clean at the bottom, saturated at the top.
    drive_db: f32 = 24.0,
    /// Tone-stack pot positions, 0..1.
    bass: f32 = 0.5,
    mid: f32 = 0.5,
    treble: f32 = 0.6,
    /// Post-tone-stack high shelf, standing in for the negative-feedback
    /// presence control on the power amp.
    presence: f32 = 0.3,
    /// Power-amp drive, after the tone controls.
    master_db: f32 = 6.0,
    /// 0 = cabinet bypassed (feeding a real cab or an external IR),
    /// 1 = cabinet filters engaged.
    cab: f32 = 1.0,
    out_db: f32 = 0.0,
    /// Index into `voicings`, rounded. Changes the preamp, the tone stack
    /// and the cabinet together.
    model: f32 = 0.0,
    /// Scales the voicing's coupling-cap corner, 0.5x at 0 to 2x at 1. Turn
    /// it up when chords smear; turn it down when single notes sound thin.
    tight: f32 = 0.5,

    stage: oversample.Stage2x = .{},
    /// Coupling capacitor in front of each gain stage, per channel.
    hp_x1: [2][max_couplings]f32 = .{[_]f32{0} ** max_couplings} ** 2,
    hp_y1: [2][max_couplings]f32 = .{[_]f32{0} ** max_couplings} ** 2,
    tone: ToneStack = .{},
    shelf: Biquad = .{},
    cab_hp: Biquad = .{},
    cab_notch: Biquad = .{},
    cab_presence: Biquad = .{},
    cab_lp: [2]Biquad = .{ .{}, .{} },

    pub const device = dsp.deviceOf(@This());

    pub fn init(sample_rate: u32) Amp {
        var self: Amp = .{ .sample_rate = @floatFromInt(@max(sample_rate, 1000)) };
        self.designCab(&voicings[0]);
        return self;
    }

    /// The oversampler's filters delay the signal; the engine compensates.
    pub fn latencyFrames(_: *const Amp) u32 {
        return oversample.latency_frames;
    }

    pub fn reset(self: *Amp) void {
        self.stage.reset();
        self.hp_x1 = .{[_]f32{0} ** max_couplings} ** 2;
        self.hp_y1 = .{[_]f32{0} ** max_couplings} ** 2;
        self.tone.clear();
        self.shelf.clear();
        self.cab_hp.clear();
        self.cab_notch.clear();
        self.cab_presence.clear();
        for (&self.cab_lp) |*f| f.clear();
    }

    /// Every param the linear part of the amp is built from, sanitized once
    /// so `processBlock` and `responseDb` cannot drift apart.
    const Settings = struct {
        v: *const Voicing,
        treble: f32,
        mid: f32,
        bass: f32,
        presence: f32,
        cab_on: bool,
        /// Coupling-cap corner after TIGHT, in Hz at the original rate.
        hp_hz: f32,
    };

    fn settings(self: *const Amp) Settings {
        const idx: usize = @intFromFloat(std.math.clamp(@round(dsp.sanitizeParam(self.model, 0.0, @floatFromInt(voicings.len - 1), 0.0)), 0.0, @as(f32, @floatFromInt(voicings.len - 1))));
        const v = &voicings[idx];
        const tight = dsp.sanitizeParam(self.tight, 0.0, 1.0, 0.5);
        // Bass is a log-taper pot, so its knob is mapped to a 20%-at-halfway
        // curve; treble and middle are linear.
        const bass_knob = dsp.sanitizeParam(self.bass, 0.0, 1.0, 0.5);
        return .{
            .v = v,
            .treble = dsp.sanitizeParam(self.treble, 0.0, 1.0, 0.6),
            .mid = dsp.sanitizeParam(self.mid, 0.0, 1.0, 0.5),
            .bass = (std.math.pow(f32, 10.0, 2.0 * bass_knob) - 1.0) / 99.0,
            .presence = dsp.sanitizeParam(self.presence, 0.0, 1.0, 0.3),
            .cab_on = dsp.sanitizeParam(self.cab, 0.0, 1.0, 1.0) >= 0.5,
            .hp_hz = v.hp_hz * std.math.pow(f32, 4.0, tight - 0.5),
        };
    }

    /// One-pole high-pass coefficient at the *doubled* rate, which is where
    /// the preamp runs.
    fn couplingCoeff(self: *const Amp, hz: f32) f32 {
        const sr2 = self.sample_rate * 2.0;
        return @exp(-2.0 * std.math.pi * @min(hz, sr2 * 0.45) / sr2);
    }

    /// Speaker and cabinet, as the analog cab sims built it: a resonant
    /// high-pass at the driver's own resonance (the Q *is* the resonant
    /// bump, so it does not need a second filter), the notch a guitar
    /// driver has between 1 and 2 kHz, a presence bump, and a fourth-order
    /// roll-off past the frequency it stops radiating at.
    fn designCab(self: *Amp, v: *const Voicing) void {
        const sr = self.sample_rate;
        self.cab_hp.set(.highpass, sr, v.cab_hp_hz, v.cab_hp_q, 0);
        self.cab_notch.set(.peak, sr, v.notch_hz, 1.4, v.notch_db);
        self.cab_presence.set(.peak, sr, v.presence_hz, 1.2, v.presence_db);
        for (&self.cab_lp) |*f| f.set(.lowpass, sr, v.lp_hz, 0.707, 0);
    }

    /// The cascaded preamp stages, run once per (doubled-rate) sample.
    const Preamp = struct {
        pre: f32,
        stages: usize,
        stage_gain: f32,
        asym: f32,
        coupling: f32,
        x1: *[max_couplings]f32,
        y1: *[max_couplings]f32,

        fn shape(self: Preamp, x: f32) f32 {
            var v: f32 = x;
            // One coupling capacitor per stage plus one on the way out -
            // every stage in the real circuit is a cap followed by a tube,
            // and the last tube still has a cap in front of the tone stack.
            // The trailing one matters most: it is the only thing that
            // filters what the final stage's own clipping invented, and
            // without it a four-stage voicing came out muddier than a
            // two-stage one however tight the caps in front of it were.
            for (0..self.stages + 1) |i| {
                const blocked = self.coupling * (self.y1[i] + v - self.x1[i]);
                self.x1[i] = v;
                self.y1[i] = blocked;
                if (i == self.stages) return blocked;
                const gain = if (i == 0) self.pre else self.stage_gain;
                // Asymmetric, so the stage makes even harmonics - and the
                // hot half alternates down the cascade the way each stage's
                // phase inversion makes it in the real circuit.
                const positive = blocked >= 0;
                const hot = if (i % 2 == 0) positive else !positive;
                v = std.math.tanh((if (hot) gain else gain * self.asym) * blocked);
            }
            unreachable;
        }
    };

    pub fn processBlock(self: *Amp, buf: []Sample) void {
        const set = self.settings();
        const drive_db = dsp.sanitizeParam(self.drive_db, 0.0, 48.0, 24.0);
        const master_db = dsp.sanitizeParam(self.master_db, 0.0, 24.0, 6.0);
        const out_db = dsp.sanitizeParam(self.out_db, -24.0, 24.0, 0.0);

        self.tone.design(self.sample_rate, set.treble, set.mid, set.bass, set.v);
        // A presence control is a treble lift in the power amp's feedback
        // loop; a high shelf at the same corner is what that comes out as.
        self.shelf.set(.peak, self.sample_rate, 2800.0, 0.8, set.presence * 10.0);
        self.designCab(set.v);

        const pre = types.dbToGain(drive_db);
        const makeup = types.dbToGain(set.v.makeup_db);
        const master = types.dbToGain(master_db);
        const post = types.dbToGain(out_db);
        const coupling = self.couplingCoeff(set.hp_hz);

        for (buf, 0..) |s, i| {
            const ch = i % 2;
            const dry = dsp.sanitizeParam(s, -16, 16, 0);
            const preamp: Preamp = .{
                .pre = pre,
                .stages = set.v.stages,
                .stage_gain = set.v.stage_gain,
                .asym = set.v.asym,
                .coupling = coupling,
                .x1 = &self.hp_x1[ch],
                .y1 = &self.hp_y1[ch],
            };
            var v = self.stage.process(ch, dry, preamp, Preamp.shape);
            v = self.tone.step(ch, v) * makeup;
            v = self.shelf.step(ch, v);
            v = std.math.tanh(v * master);
            if (set.cab_on) {
                v = self.cab_hp.step(ch, v);
                v = self.cab_notch.step(ch, v);
                v = self.cab_presence.step(ch, v);
                for (&self.cab_lp) |*f| v = f.step(ch, v);
            }
            buf[i] = std.math.clamp(v * post, -16, 16);
        }
    }

    /// Magnitude of everything linear in the chain at `hz`, in dB: the
    /// coupling caps, the tone stack and its make-up, the presence shelf and
    /// the cabinet. What the GUI draws - the clipping stages have no
    /// frequency response to plot, and drawing a tanh curve instead told the
    /// user nothing about which model or tone setting they had picked.
    pub fn responseDb(self: *const Amp, hz: f32) f32 {
        const set = self.settings();
        const sr = self.sample_rate;
        const w = 2.0 * std.math.pi * std.math.clamp(hz, 1.0, sr * 0.49) / sr;

        // The preamp runs an octave up, so its corner sits at half this
        // angle on the doubled-rate grid.
        const r = self.couplingCoeff(set.hp_hz);
        var db = @as(f32, @floatFromInt(set.v.stages + 1)) *
            sectionDb(&.{ r, -r }, &.{-r}, w * 0.5);

        var tone: ToneStack = .{};
        tone.design(sr, set.treble, set.mid, set.bass, set.v);
        db += sectionDb(&tone.b, &tone.a, w) + set.v.makeup_db;

        var shelf: Biquad = .{};
        shelf.set(.peak, sr, 2800.0, 0.8, set.presence * 10.0);
        db += shelf.magDb(w);

        if (set.cab_on) {
            var f: Biquad = .{};
            f.set(.highpass, sr, set.v.cab_hp_hz, set.v.cab_hp_q, 0);
            db += f.magDb(w);
            f.set(.peak, sr, set.v.notch_hz, 1.4, set.v.notch_db);
            db += f.magDb(w);
            f.set(.peak, sr, set.v.presence_hz, 1.2, set.v.presence_db);
            db += f.magDb(w);
            f.set(.lowpass, sr, set.v.lp_hz, 0.707, 0);
            db += 2.0 * f.magDb(w);
        }
        return db;
    }
};

// ---------------------------------------------------------------------------
// Tests

/// An amp with both nonlinear stages backed off, so a frequency sweep
/// measures the filters rather than the clipping. Cabinet off by default -
/// the tests that want it turn it back on.
fn linearAmp() Amp {
    var amp = Amp.init(48_000);
    amp.drive_db = 0.0;
    amp.master_db = 0.0;
    amp.cab = 0.0;
    return amp;
}

/// Runs `hz` through `amp` for long enough that every filter has settled and
/// returns the RMS of the last quarter, in dB.
fn toneRms(amp: *Amp, hz: f32, level: f32) f32 {
    var buf: [8192]Sample = undefined;
    for (0..buf.len / 2) |frame| {
        const t = @as(f32, @floatFromInt(frame)) / 48_000.0;
        const v = level * @sin(2.0 * std.math.pi * hz * t);
        buf[frame * 2] = v;
        buf[frame * 2 + 1] = v;
    }
    amp.processBlock(&buf);
    var sum: f64 = 0;
    const from = buf.len * 3 / 4;
    for (buf[from..]) |v| sum += @as(f64, v) * v;
    const rms = @sqrt(sum / @as(f64, @floatFromInt(buf.len - from)));
    return types.gainToDb(@floatCast(rms));
}

test "mid at zero scoops relative to mid wide open" {
    // The interacting tone stack is the whole reason this is not three
    // shelves: with MID down, 500 Hz has to drop much further than the low
    // and high ends do.
    var scooped = linearAmp();
    scooped.mid = 0.0;
    var flat = linearAmp();
    flat.mid = 1.0;

    const mid_delta = toneRms(&flat, 500.0, 0.01) - toneRms(&scooped, 500.0, 0.01);
    const low_delta = toneRms(&flat, 80.0, 0.01) - toneRms(&scooped, 80.0, 0.01);
    try std.testing.expect(mid_delta > 6.0);
    try std.testing.expect(mid_delta > low_delta + 4.0);
}

test "treble control moves the top end" {
    var dark = linearAmp();
    dark.treble = 0.0;
    var bright = linearAmp();
    bright.treble = 1.0;
    try std.testing.expect(toneRms(&bright, 4000.0, 0.01) - toneRms(&dark, 4000.0, 0.01) > 10.0);
}

test "the cabinet rolls off above a guitar speaker's range" {
    var with = linearAmp();
    with.cab = 1.0;
    var without = linearAmp();
    // 10 kHz is well past the corner; 1 kHz is inside the passband.
    const cut = toneRms(&without, 10_000.0, 0.01) - toneRms(&with, 10_000.0, 0.01);
    const pass = toneRms(&without, 1000.0, 0.01) - toneRms(&with, 1000.0, 0.01);
    try std.testing.expect(cut > 20.0);
    try std.testing.expect(cut > pass + 20.0);
}

test "drive adds harmonics rather than just level" {
    // Crest factor: a clean sine keeps ~3 dB of peak over RMS, and squashing
    // it toward a square drops that. Measured on the raw preamp so the
    // cabinet's filtering does not move the peaks.
    var amp = Amp.init(48_000);
    amp.cab = 0.0;
    amp.drive_db = 48.0;
    amp.master_db = 0.0;
    var buf: [8192]Sample = undefined;
    for (0..buf.len / 2) |frame| {
        const t = @as(f32, @floatFromInt(frame)) / 48_000.0;
        const v = 0.5 * @sin(2.0 * std.math.pi * 220.0 * t);
        buf[frame * 2] = v;
        buf[frame * 2 + 1] = v;
    }
    amp.processBlock(&buf);
    var peak: f32 = 0;
    var sum: f64 = 0;
    for (buf[buf.len / 2 ..]) |v| {
        peak = @max(peak, @abs(v));
        sum += @as(f64, v) * v;
    }
    const rms: f32 = @floatCast(@sqrt(sum / @as(f64, @floatFromInt(buf.len / 2))));
    try std.testing.expect(rms > 0.0);
    try std.testing.expect(types.gainToDb(peak / rms) < 2.5);
}

/// Level of the left channel at `hz`, in dB, by direct DFT bin. The chord
/// test picks frequencies that are exact multiples of the analysis rate's
/// own grid, so there is nothing to window.
fn binDb(buf: []const Sample, hz: f32) f32 {
    var re: f64 = 0;
    var im: f64 = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 2) {
        const th = 2.0 * std.math.pi * @as(f64, hz) * @as(f64, @floatFromInt(n)) / 48_000.0;
        re += @as(f64, buf[i]) * @cos(th);
        im -= @as(f64, buf[i]) * @sin(th);
        n += 1;
    }
    const mag = 2.0 * @sqrt(re * re + im * im) / @as(f64, @floatFromInt(n));
    return types.gainToDb(@floatCast(@max(mag, 1e-12)));
}

/// A two-note fifth (80 and 120 Hz, the shape of a low power chord) through
/// a hard-driven amp, returning how far the 40 Hz difference tone the
/// clipping invents sits below the lower note. Higher is cleaner.
/// How much of the amp's output on a two-note chord is intermodulation
/// rather than music, in dB - lower is cleaner.
///
/// 80 and 120 Hz is the shape of a low power chord, and every product a
/// nonlinearity can make from that pair lands on a multiple of 40 Hz. The
/// ones at even multiples, or at multiples of three, are harmonics of a note
/// actually being played; the rest (40, 200, 280, 440 ...) are the sum and
/// difference tones that have no business being there, and are what a chord
/// smearing into mud is made of.
fn chordImdDb(amp: *Amp) f32 {
    // 9600 frames is 8 whole cycles of 40 Hz; the second half, which is what
    // gets analysed, is 4 of them, so every bin lands exactly.
    var buf: [19_200]Sample = undefined;
    for (0..buf.len / 2) |frame| {
        const t = @as(f32, @floatFromInt(frame)) / 48_000.0;
        const v = 0.35 * (@sin(2.0 * std.math.pi * 80.0 * t) + @sin(2.0 * std.math.pi * 120.0 * t));
        buf[frame * 2] = v;
        buf[frame * 2 + 1] = v;
    }
    amp.processBlock(&buf);
    const tail = buf[buf.len / 2 ..];
    var musical: f64 = 0;
    var mud: f64 = 0;
    for (1..51) |k| {
        const g = types.dbToGain(binDb(tail, @as(f32, @floatFromInt(k)) * 40.0));
        const energy = @as(f64, g) * g;
        if (k % 2 == 0 or k % 3 == 0) musical += energy else mud += energy;
    }
    return @floatCast(10.0 * std.math.log10(mud / @max(musical, 1e-30)));
}

/// A hard-driven amp on `model`, which is where a chord has to hold together.
fn crankedAmp(model: f32) Amp {
    var amp = Amp.init(48_000);
    amp.drive_db = 42.0;
    amp.master_db = 12.0;
    amp.model = model;
    return amp;
}

test "a power chord does not collapse into intermodulation" {
    // The reported bug: single notes were fine and two notes at once turned
    // to mud, because nothing kept the fundamentals out of the clipping
    // stages. The same amp measured before the coupling caps went in sat at
    // -8.1 dB here.
    for (0..voicings.len) |model| {
        var amp = crankedAmp(@floatFromInt(model));
        try std.testing.expect(chordImdDb(&amp) < -10.0);
    }

    // And TIGHT is what moves it, so someone who wants more or less low end
    // in front of the clipper is trading against exactly this.
    var loose = crankedAmp(0);
    loose.tight = 0.0;
    var tight = crankedAmp(0);
    tight.tight = 1.0;
    try std.testing.expect(chordImdDb(&tight) < chordImdDb(&loose) - 4.0);
}

test "each voicing is tighter than the one before it" {
    // Not a tone match to any real amp - just that MODEL is wired to all
    // three of the things it claims to change, so picking one is audible.
    for (0..voicings.len) |i| {
        var amp = linearAmp();
        amp.model = @floatFromInt(i);
        amp.cab = 1.0;
        try std.testing.expect(std.math.isFinite(amp.responseDb(1000.0)));
        // Each step up adds a stage and raises the coupling corner, so what
        // reaches the clipper below the guitar's own range drops.
        if (i > 0) {
            var prev = linearAmp();
            prev.model = @floatFromInt(i - 1);
            prev.cab = 1.0;
            try std.testing.expect(amp.responseDb(60.0) < prev.responseDb(60.0) - 3.0);
        }
    }
}

test "the plotted response matches the shape the amp actually has" {
    // The GUI curve is computed from the coefficients rather than measured,
    // so it can drift from the audio path without anything failing. Compared
    // against 1 kHz rather than absolutely: `responseDb` is the linear chain
    // only, and the preamp's asymmetry is a gain the curve deliberately
    // leaves out (it is a constant offset, and DRIVE would otherwise swing
    // the whole plot off the top of the pane).
    var amp = linearAmp();
    amp.cab = 1.0;
    var reference = linearAmp();
    reference.cab = 1.0;
    // -40 dBFS in, so the tone stack's make-up cannot reach the clip.
    const rms_ref = toneRms(&reference, 1000.0, 0.01);
    for ([_]f32{ 100.0, 400.0, 3000.0, 8000.0 }) |hz| {
        var measured = linearAmp();
        measured.cab = 1.0;
        const expected = amp.responseDb(hz) - amp.responseDb(1000.0);
        try std.testing.expectApproxEqAbs(expected, toneRms(&measured, hz, 0.01) - rms_ref, 1.5);
    }
}

test "amp stays finite under hostile input" {
    var amp = Amp.init(0);
    amp.drive_db = std.math.nan(f32);
    amp.bass = std.math.inf(f32);
    amp.mid = -std.math.inf(f32);
    amp.treble = std.math.nan(f32);
    amp.presence = std.math.nan(f32);
    amp.master_db = std.math.inf(f32);
    amp.out_db = std.math.nan(f32);
    amp.cab = std.math.nan(f32);
    amp.model = std.math.nan(f32);
    amp.tight = std.math.inf(f32);
    try dsp.expectBoundedUnderNoise(&amp, 16.1);
}

test "every sample rate the loader accepts designs a stable amp" {
    // The cabinet's fixed corners sit above Nyquist at the bottom of the
    // supported range, and the tone stack's bilinear transform is evaluated
    // at c = 2*fs - both are places a fixed frequency turns into an
    // oscillator if it is not pinned.
    for ([_]u32{ 8_000, 22_050, 44_100, 48_000, 96_000, 384_000 }) |sr| {
        var amp = Amp.init(sr);
        amp.drive_db = 48.0;
        amp.master_db = 24.0;
        for (0..voicings.len) |model| {
            amp.model = @floatFromInt(model);
            for ([_]f32{ 0.0, 0.5, 1.0 }) |pot| {
                amp.bass = pot;
                amp.mid = pot;
                amp.treble = pot;
                amp.tight = pot;
                var buf: [1024]Sample = undefined;
                for (&buf, 0..) |*v, i| v.* = if (i % 7 == 0) 0.9 else -0.3;
                amp.processBlock(&buf);
                for (buf) |v| try std.testing.expect(std.math.isFinite(v));
                try std.testing.expect(std.math.isFinite(amp.responseDb(1000.0)));
            }
        }
    }
}

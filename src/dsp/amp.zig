//! Guitar amplifier: the four stages a modelled amp is conventionally split
//! into (preamp, tone stack, power amp, speaker cabinet), each taken at the
//! cheapest form that still behaves like the circuit rather than like a
//! generic distortion box.
//!
//!   preamp     two cascaded asymmetric triode-ish stages with a DC blocker
//!              between them, run through 2x oversampling.
//!   tone stack the '59 Fender Bassman network in closed form, so BASS, MID
//!              and TREBLE interact the way the passive circuit does - MID
//!              at zero scoops and pulls the other two with it, which is the
//!              part three independent shelves cannot fake.
//!   power amp  one symmetric soft-clip driven by MASTER, for the
//!              compression that arrives after the tone controls.
//!   cabinet    a fixed filter chain rather than a convolved impulse
//!              response: resonant high-pass at the speaker's own resonance,
//!              a mid notch, a presence bump, and a steep roll-off past the
//!              ~4.5 kHz a guitar speaker stops at.
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

/// Fixed make-up applied after the tone stack. The Bassman network is
/// passive and lossy - around -12 dB through its own passband, more when
/// MID is scooped - so without this the amp would need MASTER cranked
/// before anything reached the power stage. Trimmed by measurement rather
/// than by matching that loss exactly: at 20 dB the default patch peaked at
/// +3 dBFS on an ordinary -14 dBFS input, which is a unit that clips the
/// moment it is inserted. 14 dB lands the same input near -3 dBFS.
const tone_makeup_db: f32 = 14.0;

/// Negative-half gain of the first preamp stage. A triode conducts harder on
/// one half of the swing; this is the asymmetry that puts even harmonics in
/// before the tone stack ever sees the signal.
const preamp_asym: f32 = 0.7;

/// Interstage DC-blocker pole, ~38 Hz at 48 kHz - the coupling capacitor
/// between the two gain stages. Without it the first stage's asymmetry
/// offsets the second stage's operating point and the amp collapses into a
/// one-sided buzz at high drive.
const dc_pole: f32 = 0.995;

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

    fn clear(self: *Biquad) void {
        self.x1 = .{ 0, 0 };
        self.x2 = .{ 0, 0 };
        self.y1 = .{ 0, 0 };
        self.y2 = .{ 0, 0 };
    }
};

// ---------------------------------------------------------------------------
// Tone stack

/// '59 Bassman component values (Yeh & Smith, DAFx-06, fig. 1).
const c1: f64 = 0.25e-9;
const c2: f64 = 20e-9;
const c3: f64 = 20e-9;
const r1: f64 = 250e3;
const r2: f64 = 1e6;
const r3: f64 = 25e3;
const r4: f64 = 56e3;

/// Third-order direct-form-I section, coefficients recomputed per block from
/// the three pot positions. Held in f64 during design: the `m^2` terms very
/// nearly cancel the `m` terms and the products span 1e-25 to 1e15, which
/// f32 loses.
const ToneStack = struct {
    b: [4]f32 = .{ 1, 0, 0, 0 },
    a: [3]f32 = .{ 0, 0, 0 },
    x: [2][3]f32 = .{.{ 0, 0, 0 }} ** 2,
    y: [2][3]f32 = .{.{ 0, 0, 0 }} ** 2,

    /// `t`/`m`/`l` are the treble, middle and bass wiper fractions, already
    /// tapered by the caller.
    fn design(self: *ToneStack, sr: f32, t_in: f32, m_in: f32, l_in: f32) void {
        const t: f64 = t_in;
        const m: f64 = m_in;
        const l: f64 = l_in;

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
        for (self.b) |v| if (!std.math.isFinite(v)) return self.bypass();
        for (self.a) |v| if (!std.math.isFinite(v)) return self.bypass();
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
    /// Preamp gain. The whole usable range of an amp lives here: clean at
    /// the bottom, crunch by halfway, saturated at the top.
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

    stage: oversample.Stage2x = .{},
    dc_x1: [2]f32 = .{ 0, 0 },
    dc_y1: [2]f32 = .{ 0, 0 },
    tone: ToneStack = .{},
    shelf: Biquad = .{},
    cab_hp: Biquad = .{},
    cab_notch: Biquad = .{},
    cab_presence: Biquad = .{},
    cab_lp: [2]Biquad = .{ .{}, .{} },

    pub const device = dsp.deviceOf(@This());

    pub fn init(sample_rate: u32) Amp {
        var self: Amp = .{ .sample_rate = @floatFromInt(@max(sample_rate, 1000)) };
        self.designCab();
        return self;
    }

    /// The oversampler's filters delay the signal; the engine compensates.
    pub fn latencyFrames(_: *const Amp) u32 {
        return oversample.latency_frames;
    }

    pub fn reset(self: *Amp) void {
        self.stage.reset();
        self.dc_x1 = .{ 0, 0 };
        self.dc_y1 = .{ 0, 0 };
        self.tone.clear();
        self.shelf.clear();
        self.cab_hp.clear();
        self.cab_notch.clear();
        self.cab_presence.clear();
        for (&self.cab_lp) |*f| f.clear();
    }

    /// Speaker and cabinet, as the analog cab sims built it: a resonant
    /// high-pass at the driver's own resonance (the Q *is* the resonant
    /// bump, so it does not need a second filter), the notch a 12" driver
    /// has between 1 and 2 kHz, a presence bump, and a fourth-order
    /// roll-off past the frequency a guitar speaker stops radiating.
    fn designCab(self: *Amp) void {
        const sr = self.sample_rate;
        self.cab_hp.set(.highpass, sr, 95.0, 1.1, 0);
        self.cab_notch.set(.peak, sr, 1600.0, 1.4, -5.0);
        self.cab_presence.set(.peak, sr, 3200.0, 1.2, 4.0);
        for (&self.cab_lp) |*f| f.set(.lowpass, sr, 4500.0, 0.707, 0);
    }

    /// The two cascaded preamp stages, run once per (doubled-rate) sample.
    const Preamp = struct {
        pre: f32,
        dc_x1: *f32,
        dc_y1: *f32,

        fn shape(self: Preamp, x: f32) f32 {
            // First stage: asymmetric, so it makes even harmonics.
            const g = if (x >= 0) self.pre else self.pre * preamp_asym;
            const first = std.math.tanh(g * x);
            // Coupling capacitor between the stages.
            const blocked = first - self.dc_x1.* + dc_pole * self.dc_y1.*;
            self.dc_x1.* = first;
            self.dc_y1.* = blocked;
            // Second stage: symmetric, and already fed a hot signal, so it
            // only needs a little more gain to fold the peaks over.
            return std.math.tanh(blocked * 2.0);
        }
    };

    pub fn processBlock(self: *Amp, buf: []Sample) void {
        const drive_db = dsp.sanitizeParam(self.drive_db, 0.0, 48.0, 24.0);
        const master_db = dsp.sanitizeParam(self.master_db, 0.0, 24.0, 6.0);
        const out_db = dsp.sanitizeParam(self.out_db, -24.0, 24.0, 0.0);
        const presence = dsp.sanitizeParam(self.presence, 0.0, 1.0, 0.3);
        const cab_on = dsp.sanitizeParam(self.cab, 0.0, 1.0, 1.0) >= 0.5;

        // Wiper fractions. Treble and middle are linear pots; bass is a log
        // taper, so its knob is mapped to a 20%-at-halfway curve.
        const treble = dsp.sanitizeParam(self.treble, 0.0, 1.0, 0.6);
        const mid = dsp.sanitizeParam(self.mid, 0.0, 1.0, 0.5);
        const bass_knob = dsp.sanitizeParam(self.bass, 0.0, 1.0, 0.5);
        const bass = (std.math.pow(f32, 10.0, 2.0 * bass_knob) - 1.0) / 99.0;
        self.tone.design(self.sample_rate, treble, mid, bass);
        // A presence control is a treble lift in the power amp's feedback
        // loop; a high shelf at the same corner is what that comes out as.
        self.shelf.set(.peak, self.sample_rate, 2800.0, 0.8, presence * 10.0);

        const pre = types.dbToGain(drive_db);
        const makeup = types.dbToGain(tone_makeup_db);
        const master = types.dbToGain(master_db);
        const post = types.dbToGain(out_db);

        for (buf, 0..) |s, i| {
            const ch = i % 2;
            const dry = dsp.sanitizeParam(s, -16, 16, 0);
            const preamp: Preamp = .{ .pre = pre, .dc_x1 = &self.dc_x1[ch], .dc_y1 = &self.dc_y1[ch] };
            var v = self.stage.process(ch, dry, preamp, Preamp.shape);
            v = self.tone.step(ch, v) * makeup;
            v = self.shelf.step(ch, v);
            v = std.math.tanh(v * master);
            if (cab_on) {
                v = self.cab_hp.step(ch, v);
                v = self.cab_notch.step(ch, v);
                v = self.cab_presence.step(ch, v);
                for (&self.cab_lp) |*f| v = f.step(ch, v);
            }
            buf[i] = std.math.clamp(v * post, -16, 16);
        }
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
    // 10 kHz is well past the ~4.5 kHz corner; 1 kHz is inside the passband.
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
        for ([_]f32{ 0.0, 0.5, 1.0 }) |pot| {
            amp.bass = pot;
            amp.mid = pot;
            amp.treble = pot;
            var buf: [1024]Sample = undefined;
            for (&buf, 0..) |*v, i| v.* = if (i % 7 == 0) 0.9 else -0.3;
            amp.processBlock(&buf);
            for (buf) |v| try std.testing.expect(std.math.isFinite(v));
        }
    }
}

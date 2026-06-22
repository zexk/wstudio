//! Polyphonic subtractive synth: oscillator per voice with ADSR amplitude
//! and filter envelopes, multiple filter modes, and unison.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Waveform   = enum { sine, saw, triangle, square };
pub const FilterType = enum { lp, hp, bp, notch };

pub const PolySynth = struct {
    sample_rate: f32,

    // ── OSC ─────────────────────────────────────────────────────────────────
    waveform: Waveform = .saw,
    /// Pulse width for square wave (0.01–0.99).
    pulse_width: f32 = 0.5,
    /// Global pitch offset in cents. ±100 = ±1 semitone.
    detune_cents: f32 = 0.0,
    /// Unison oscillator count (1 = off, 2–8 = stacked).
    unison: u8 = 1,
    /// Total spread between the outermost unison voices, in cents.
    unison_detune: f32 = 15.0,

    // ── AMP ENVELOPE ────────────────────────────────────────────────────────
    attack_s:  f32 = 0.005,
    decay_s:   f32 = 0.08,
    sustain:   f32 = 0.7,
    release_s: f32 = 0.25,

    // ── FILTER ──────────────────────────────────────────────────────────────
    filter_type: FilterType = .lp,
    /// Filter cutoff in Hz (20 Hz–Nyquist). Default open (18 kHz).
    filter_cutoff: f32 = 18_000.0,
    /// Filter resonance 0..1 (mapped to Q 0.5..20).
    filter_res: f32 = 0.0,
    /// Filter envelope amount in octaves (–4..+4). 0 = no modulation.
    fenv_amount: f32 = 0.0,

    // ── FILTER ENVELOPE ─────────────────────────────────────────────────────
    fenv_attack_s:  f32 = 0.005,
    fenv_decay_s:   f32 = 0.5,
    fenv_sustain:   f32 = 0.0,
    fenv_release_s: f32 = 0.3,

    // ── OUT ─────────────────────────────────────────────────────────────────
    gain: f32 = 0.35,

    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,

    pub const max_voices = 8;
    pub const max_unison = 8;

    const Stage = enum { attack, decay, sustain, release };

    const FilterCoeffs = struct {
        b0: f32 = 1.0, b1: f32 = 0.0, b2: f32 = 0.0,
        a1: f32 = 0.0, a2: f32 = 0.0,
    };

    const Voice = struct {
        active: bool = false,
        note:   u7   = 0,
        velocity: f32 = 0.0,
        /// One phase accumulator per unison sub-oscillator.
        phases: [max_unison]f32 = [_]f32{0.0} ** max_unison,
        // Amplitude envelope
        env:   f32   = 0.0,
        stage: Stage = .attack,
        // Filter envelope
        env2:   f32   = 0.0,
        stage2: Stage = .attack,
        /// Per-voice DF1 biquad state (x = input history, y = output history).
        x1: f32 = 0.0, x2: f32 = 0.0,
        y1: f32 = 0.0, y2: f32 = 0.0,
    };

    pub fn init(sample_rate: u32) PolySynth {
        return .{ .sample_rate = @floatFromInt(sample_rate) };
    }

    pub fn device(self: *PolySynth) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .event   = eventOpaque,
        .reset   = resetOpaque,
    };

    pub fn noteToFreq(note: u7) f32 {
        const n: f32 = @floatFromInt(note);
        return 440.0 * std.math.pow(f32, 2.0, (n - 69.0) / 12.0);
    }

    pub fn noteOn(self: *PolySynth, note: u7, velocity: f32) void {
        const voice = self.allocVoice();
        voice.* = .{
            .active   = true,
            .note     = note,
            .velocity = velocity,
            .stage    = .attack,
            .stage2   = .attack,
        };
    }

    pub fn noteOff(self: *PolySynth, note: u7) void {
        for (&self.voices) |*v| {
            if (v.active and v.note == note and v.stage != .release) {
                v.stage  = .release;
                v.stage2 = .release;
            }
        }
    }

    fn allocVoice(self: *PolySynth) *Voice {
        var quietest: *Voice = &self.voices[0];
        for (&self.voices) |*v| {
            if (!v.active) return v;
            if (v.env < quietest.env) quietest = v;
        }
        return quietest;
    }

    pub fn processBlock(self: *PolySynth, buf: []Sample) void {
        const frames = buf.len / 2;

        // Precompute per-block envelope increments.
        const attack_inc  = 1.0 / @max(self.attack_s  * self.sample_rate, 1.0);
        const decay_inc   = (1.0 - self.sustain)       / @max(self.decay_s   * self.sample_rate, 1.0);
        const release_inc = 1.0                        / @max(self.release_s  * self.sample_rate, 1.0);

        const fenv_attack_inc  = 1.0 / @max(self.fenv_attack_s  * self.sample_rate, 1.0);
        const fenv_decay_inc   = (1.0 - self.fenv_sustain)       / @max(self.fenv_decay_s   * self.sample_rate, 1.0);
        const fenv_release_inc = 1.0                              / @max(self.fenv_release_s  * self.sample_rate, 1.0);

        for (&self.voices) |*v| {
            if (!v.active) continue;

            // Compute effective cutoff from filter envelope at block start.
            // fenv_amount in octaves: cutoff * 2^(amount * env2).
            const fenv_mod = std.math.pow(f32, 2.0, self.fenv_amount * v.env2);
            const effective_cutoff = std.math.clamp(
                self.filter_cutoff * fenv_mod, 20.0, self.sample_rate * 0.49,
            );
            const fc = self.computeFilterCoeffs(effective_cutoff);

            const base_freq = noteToFreq(v.note) *
                std.math.pow(f32, 2.0, self.detune_cents / 1200.0);
            const n: usize = @min(@max(self.unison, 1), max_unison);

            var phase_incs: [max_unison]f32 = undefined;
            for (0..n) |ui| {
                const spread_cents: f32 = if (n > 1) blk: {
                    const t = @as(f32, @floatFromInt(ui)) /
                              @as(f32, @floatFromInt(n - 1));
                    break :blk (t * 2.0 - 1.0) * self.unison_detune * 0.5;
                } else 0.0;
                const freq = base_freq * std.math.pow(f32, 2.0, spread_cents / 1200.0);
                phase_incs[ui] = freq / self.sample_rate;
            }
            const osc_scale = 1.0 / @sqrt(@as(f32, @floatFromInt(n)));

            for (0..frames) |i| {
                // Sum unison oscillators.
                var osc_sum: f32 = 0.0;
                for (0..n) |ui| {
                    osc_sum += self.oscSample(v.phases[ui]);
                    v.phases[ui] += phase_incs[ui];
                    if (v.phases[ui] >= 1.0) v.phases[ui] -= 1.0;
                }
                const osc = osc_sum * osc_scale;

                // Filter (OSC → FILTER → AMP)
                const filt = fc.b0 * osc
                           + fc.b1 * v.x1 + fc.b2 * v.x2
                           - fc.a1 * v.y1 - fc.a2 * v.y2;
                v.x2 = v.x1; v.x1 = osc;
                v.y2 = v.y1; v.y1 = filt;

                const s = filt * v.env * v.velocity * self.gain;
                buf[i * 2]     += s;
                buf[i * 2 + 1] += s;

                // Amplitude envelope
                switch (v.stage) {
                    .attack => {
                        v.env += attack_inc;
                        if (v.env >= 1.0) { v.env = 1.0; v.stage = .decay; }
                    },
                    .decay => {
                        v.env -= decay_inc;
                        if (v.env <= self.sustain) { v.env = self.sustain; v.stage = .sustain; }
                    },
                    .sustain => {},
                    .release => {
                        v.env -= release_inc;
                        if (v.env <= 0.0) { v.* = .{}; break; }
                    },
                }

                // Filter envelope (voice death is governed by amp env above)
                switch (v.stage2) {
                    .attack => {
                        v.env2 += fenv_attack_inc;
                        if (v.env2 >= 1.0) { v.env2 = 1.0; v.stage2 = .decay; }
                    },
                    .decay => {
                        v.env2 -= fenv_decay_inc;
                        if (v.env2 <= self.fenv_sustain) { v.env2 = self.fenv_sustain; v.stage2 = .sustain; }
                    },
                    .sustain => {},
                    .release => {
                        v.env2 -= fenv_release_inc;
                        if (v.env2 < 0.0) v.env2 = 0.0;
                    },
                }
            }
        }
    }

    fn computeFilterCoeffs(self: *const PolySynth, cutoff: f32) FilterCoeffs {
        const q = 0.5 + self.filter_res * 19.5;
        const c = std.math.clamp(cutoff, 20.0, self.sample_rate * 0.49);
        const w0 = 2.0 * std.math.pi * c / self.sample_rate;
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * q);
        const a0_inv = 1.0 / (1.0 + alpha);
        const neg2cos = -2.0 * cos_w0;

        return switch (self.filter_type) {
            .lp => .{
                .b0 = ((1.0 - cos_w0) * 0.5) * a0_inv,
                .b1 = (1.0 - cos_w0) * a0_inv,
                .b2 = ((1.0 - cos_w0) * 0.5) * a0_inv,
                .a1 = neg2cos * a0_inv,
                .a2 = (1.0 - alpha) * a0_inv,
            },
            .hp => .{
                .b0 = ((1.0 + cos_w0) * 0.5) * a0_inv,
                .b1 = -(1.0 + cos_w0) * a0_inv,
                .b2 = ((1.0 + cos_w0) * 0.5) * a0_inv,
                .a1 = neg2cos * a0_inv,
                .a2 = (1.0 - alpha) * a0_inv,
            },
            .bp => .{
                .b0 = (sin_w0 * 0.5) * a0_inv,
                .b1 = 0.0,
                .b2 = -(sin_w0 * 0.5) * a0_inv,
                .a1 = neg2cos * a0_inv,
                .a2 = (1.0 - alpha) * a0_inv,
            },
            .notch => .{
                .b0 = a0_inv,
                .b1 = neg2cos * a0_inv,
                .b2 = a0_inv,
                .a1 = neg2cos * a0_inv,
                .a2 = (1.0 - alpha) * a0_inv,
            },
        };
    }

    fn oscSample(self: *const PolySynth, phase: f32) Sample {
        return switch (self.waveform) {
            .sine     => @sin(2.0 * std.math.pi * phase),
            .saw      => 2.0 * phase - 1.0,
            .triangle => 1.0 - 4.0 * @abs(phase - 0.5),
            .square   => if (phase < self.pulse_width) 1.0 else -1.0,
        };
    }

    pub fn resetAll(self: *PolySynth) void {
        for (&self.voices) |*v| v.* = .{};
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *PolySynth = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn eventOpaque(ptr: *anyopaque, ev: dsp.Event) void {
        const self: *PolySynth = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .note_on  => |e| self.noteOn(e.note, e.velocity),
            .note_off => |e| self.noteOff(e.note),
            .all_off  => self.resetAll(),
        }
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *PolySynth = @ptrCast(@alignCast(ptr));
        self.resetAll();
    }
};

test "A4 tuning" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), PolySynth.noteToFreq(69), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 261.63), PolySynth.noteToFreq(60), 0.01);
}

test "filter: high-Q sweep near Nyquist stays finite" {
    var synth = PolySynth.init(48_000);
    synth.filter_cutoff = 22_000.0;
    synth.filter_res = 1.0;
    synth.noteOn(60, 1.0);

    var buf: [512]Sample = undefined;
    for (0..32) |_| {
        @memset(&buf, 0.0);
        synth.processBlock(&buf);
        for (buf) |s| {
            try std.testing.expect(!std.math.isNan(s));
            try std.testing.expect(!std.math.isInf(s));
        }
    }
}

test "filter: all types stay finite under resonance" {
    const types_to_test = [_]FilterType{ .lp, .hp, .bp, .notch };
    for (types_to_test) |ft| {
        var synth = PolySynth.init(48_000);
        synth.filter_type = ft;
        synth.filter_cutoff = 1_000.0;
        synth.filter_res = 0.9;
        synth.noteOn(60, 1.0);
        var buf: [512]Sample = undefined;
        for (0..16) |_| {
            @memset(&buf, 0.0);
            synth.processBlock(&buf);
            for (buf) |s| {
                try std.testing.expect(!std.math.isNan(s));
                try std.testing.expect(!std.math.isInf(s));
            }
        }
    }
}

test "filter: closed LP cutoff attenuates high-frequency content" {
    var open = PolySynth.init(48_000);
    open.waveform = .saw;
    open.filter_cutoff = 18_000.0;
    open.filter_res = 0.0;
    open.noteOn(84, 1.0);

    var closed = PolySynth.init(48_000);
    closed.waveform = .saw;
    closed.filter_cutoff = 200.0;
    closed.filter_res = 0.0;
    closed.noteOn(84, 1.0);

    var buf_open: [512]Sample = undefined;
    var buf_closed: [512]Sample = undefined;
    for (0..20) |_| {
        @memset(&buf_open, 0.0);   open.processBlock(&buf_open);
        @memset(&buf_closed, 0.0); closed.processBlock(&buf_closed);
    }

    var rms_open: f32 = 0.0;
    var rms_closed: f32 = 0.0;
    for (buf_open, buf_closed) |o, c| {
        rms_open   += o * o;
        rms_closed += c * c;
    }
    try std.testing.expect(rms_closed < rms_open * 0.1);
}

test "filter envelope modulates cutoff: positive amount brightens" {
    // Two identical synths; one has a filter env with positive amount.
    // After initial attack the envelope-driven one should be louder (more HF content).
    var base_synth = PolySynth.init(48_000);
    base_synth.waveform = .saw;
    base_synth.filter_cutoff = 500.0;
    base_synth.fenv_amount = 0.0;
    base_synth.noteOn(60, 1.0);

    var mod_synth = PolySynth.init(48_000);
    mod_synth.waveform = .saw;
    mod_synth.filter_cutoff = 500.0;
    mod_synth.fenv_amount = 3.0; // +3 octaves when env2 = 1 → 500 Hz * 8 = 4 kHz
    mod_synth.fenv_attack_s = 0.001; // very fast attack
    mod_synth.fenv_sustain = 1.0;    // hold open
    mod_synth.noteOn(60, 1.0);

    var buf_base: [512]Sample = undefined;
    var buf_mod: [512]Sample = undefined;
    for (0..30) |_| {
        @memset(&buf_base, 0.0); base_synth.processBlock(&buf_base);
        @memset(&buf_mod, 0.0);  mod_synth.processBlock(&buf_mod);
    }

    var rms_base: f32 = 0.0;
    var rms_mod:  f32 = 0.0;
    for (buf_base, buf_mod) |b, m| { rms_base += b * b; rms_mod += m * m; }
    try std.testing.expect(rms_mod > rms_base);
}

test "voice lifecycle: silence, sound, release back to silence" {
    var synth = PolySynth.init(48_000);
    var buf: [512]Sample = undefined;

    @memset(&buf, 0.0);
    synth.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);

    synth.noteOn(60, 1.0);
    @memset(&buf, 0.0);
    synth.processBlock(&buf);
    var peak: f32 = 0.0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);

    synth.noteOff(60);
    for (0..60) |_| {
        @memset(&buf, 0.0);
        synth.processBlock(&buf);
    }
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
    for (synth.voices) |v| try std.testing.expect(!v.active);
}

test "polyphony allocates distinct voices" {
    var synth = PolySynth.init(48_000);
    synth.noteOn(60, 1.0);
    synth.noteOn(64, 1.0);
    synth.noteOn(67, 1.0);
    var active: u32 = 0;
    for (synth.voices) |v| {
        if (v.active) active += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), active);
}

test "pulse width: narrow pulse is quieter than 50% duty cycle" {
    var wide = PolySynth.init(48_000);
    wide.waveform = .square;
    wide.pulse_width = 0.5;
    wide.noteOn(60, 1.0);

    var narrow = PolySynth.init(48_000);
    narrow.waveform = .square;
    narrow.pulse_width = 0.1;
    narrow.noteOn(60, 1.0);

    var buf_wide: [512]Sample = undefined;
    var buf_narrow: [512]Sample = undefined;
    for (0..10) |_| {
        @memset(&buf_wide, 0.0);   wide.processBlock(&buf_wide);
        @memset(&buf_narrow, 0.0); narrow.processBlock(&buf_narrow);
    }
    var rms_w: f32 = 0.0;
    var rms_n: f32 = 0.0;
    for (buf_wide, buf_narrow) |w, n| { rms_w += w * w; rms_n += n * n; }
    try std.testing.expect(rms_n < rms_w);
}

//! Polyphonic subtractive synth: oscillator per voice with ADSR amplitude
//! and filter envelopes, multiple filter modes, and unison.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const midi = @import("../midi.zig");

const Sample = types.Sample;

pub const Waveform   = enum { sine, saw, triangle, square };
pub const FilterType = enum { lp, hp, bp, notch };
pub const LfoShape   = enum { sine, triangle, saw, square };
pub const LfoTarget  = enum { none, filter, pitch, amp };
pub const VoiceMode  = enum { poly, mono, legato };
pub const SubShape   = enum { sine, square };
pub const ModMode    = enum { none, ring, am_a_to_b, am_b_to_a, fm_a_to_b, fm_b_to_a };

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
    /// Stereo width: 0 = mono, 1 = full L/R spread across unison voices.
    unison_spread: f32 = 0.0,

    // ── OSC B ────────────────────────────────────────────────────────────────
    osc_b_on:           bool     = false,
    osc_b_waveform:     Waveform = .saw,
    osc_b_pulse_width:  f32      = 0.5,
    /// Coarse pitch offset in semitones (–24..+24). Integer steps in the editor.
    osc_b_semi:         f32      = 0.0,
    /// Fine pitch offset in cents (–100..+100).
    osc_b_detune_cents: f32      = 0.0,
    /// Mix level of OSC B relative to OSC A (0..1).
    osc_b_level:        f32      = 1.0,
    osc_b_unison:       u8       = 1,
    osc_b_unison_detune: f32     = 15.0,

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

    // ── LFO ─────────────────────────────────────────────────────────────────
    lfo_shape:  LfoShape  = .sine,
    /// Rate in Hz (0.01–20 Hz).
    lfo_rate_hz: f32 = 1.0,
    /// Depth 0..1. Modulation range depends on target (see processBlock).
    lfo_depth: f32 = 0.0,
    lfo_target: LfoTarget = .none,
    /// Synth-global LFO phase (0..1). Advanced once per block.
    lfo_phase: f32 = 0.0,

    // ── VOICE ────────────────────────────────────────────────────────────────
    voice_mode: VoiceMode = .poly,
    /// Portamento time in seconds. 0 = off (snap).
    glide_s: f32 = 0.0,
    /// Note stack for mono/legato: last-in, first-out.
    held_notes:      [16]u7  = [_]u7{0}  ** 16,
    held_velocities: [16]f32 = [_]f32{0} ** 16,
    held_count: u8 = 0,

    // ── SUB ─────────────────────────────────────────────────────────────────
    /// Level 0 = off. Sine or square at -1 octave.
    sub_level: f32      = 0.0,
    sub_shape: SubShape = .sine,

    // ── NOISE ────────────────────────────────────────────────────────────────
    /// Level 0 = off.
    noise_level: f32 = 0.0,
    /// Color 0 = dark (heavily LP-filtered), 1 = white (unfiltered).
    noise_color: f32 = 1.0,

    // ── MOD (A←→B) ──────────────────────────────────────────────────────────
    mod_mode: ModMode = .none,
    /// FM modes: modulation index β (0..8). AM / ring: depth 0..1.
    mod_amount: f32 = 0.0,

    // ── PITCH BEND ──────────────────────────────────────────────────────────
    /// Applied to all active voices. Set via midi.applyPitchBend.
    /// Range controlled by the caller (default ±2 semitones at ±1.0).
    pitch_bend_semitones: f32 = 0.0,

    // ── OUT ─────────────────────────────────────────────────────────────────
    gain: f32 = 0.35,

    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,

    pub const max_voices = 16;
    pub const max_unison = 16;
    /// Hard cap on simultaneous oscillators across all active voices.
    /// With e.g. 8 active voices, unison is capped at 4 each → 32 total.
    pub const osc_budget: usize = 32;

    const Stage = enum { attack, decay, sustain, release };

    const FilterCoeffs = struct {
        b0: f32 = 1.0, b1: f32 = 0.0, b2: f32 = 0.0,
        a1: f32 = 0.0, a2: f32 = 0.0,
    };

    const Voice = struct {
        active: bool = false,
        note:   u7   = 0,
        velocity: f32 = 0.0,
        /// Phase accumulators for OSC A and OSC B unison voices.
        phases:   [max_unison]f32 = [_]f32{0.0} ** max_unison,
        phases_b: [max_unison]f32 = [_]f32{0.0} ** max_unison,
        // Amplitude envelope
        env:   f32   = 0.0,
        stage: Stage = .attack,
        // Filter envelope
        env2:   f32   = 0.0,
        stage2: Stage = .attack,
        /// Per-voice DF1 biquad state — left channel.
        x1: f32 = 0.0, x2: f32 = 0.0,
        y1: f32 = 0.0, y2: f32 = 0.0,
        /// Right channel biquad state (same coefficients, independent history).
        x1_r: f32 = 0.0, x2_r: f32 = 0.0,
        y1_r: f32 = 0.0, y2_r: f32 = 0.0,
        // Glide: current log2(freq) sliding toward log2(noteToFreq(note)).
        glide_log_freq: f32 = 0.0,
        /// log2(freq) change per sample. 0 when glide is off or complete.
        glide_rate: f32 = 0.0,
        // Sub oscillator
        sub_phase: f32 = 0.0,
        // Noise oscillator — xorshift32 (must never be 0)
        noise_rand_state: u32 = 1,
        noise_lp: f32 = 0.0,
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
        return midi.noteToFreq(note);
    }

    pub fn noteOn(self: *PolySynth, note: u7, velocity: f32) void {
        switch (self.voice_mode) {
            .poly   => self.noteOnPoly(note, velocity),
            .mono   => { self.pushHeld(note, velocity); self.noteOnMono(note, velocity, true); },
            .legato => {
                const was_active = self.voices[0].active;
                self.pushHeld(note, velocity);
                self.noteOnMono(note, velocity, !was_active);
            },
        }
    }

    pub fn noteOff(self: *PolySynth, note: u7) void {
        switch (self.voice_mode) {
            .poly => {
                for (&self.voices) |*v| {
                    if (v.active and v.note == note and v.stage != .release) {
                        v.stage  = .release;
                        v.stage2 = .release;
                    }
                }
            },
            .mono => {
                self.popHeld(note);
                if (self.held_count > 0) {
                    const i = self.held_count - 1;
                    self.noteOnMono(self.held_notes[i], self.held_velocities[i], true);
                } else {
                    const v = &self.voices[0];
                    if (v.active and v.note == note) { v.stage = .release; v.stage2 = .release; }
                }
            },
            .legato => {
                self.popHeld(note);
                if (self.held_count > 0) {
                    const i = self.held_count - 1;
                    self.noteOnMono(self.held_notes[i], self.held_velocities[i], false);
                } else {
                    const v = &self.voices[0];
                    if (v.active) { v.stage = .release; v.stage2 = .release; }
                }
            },
        }
    }

    fn noteOnPoly(self: *PolySynth, note: u7, velocity: f32) void {
        const v = self.allocVoice();
        const was_active  = v.active;
        const prev_log    = v.glide_log_freq;
        const target_log  = std.math.log2(noteToFreq(note));
        const start_log   = if (was_active and self.glide_s > 0.0) prev_log else target_log;
        v.* = .{
            .active           = true,
            .note             = note,
            .velocity         = velocity,
            .stage            = .attack,
            .stage2           = .attack,
            .glide_log_freq   = start_log,
            .glide_rate       = if (was_active and self.glide_s > 0.0)
                (target_log - start_log) / @max(self.glide_s * self.sample_rate, 1.0)
            else 0.0,
            .noise_rand_state = (@as(u32, note) *% 0x9E3779B9) | 1,
        };
    }

    /// Activate or update the single mono/legato voice.
    /// retrigger=true → reset amplitude envelope from attack.
    fn noteOnMono(self: *PolySynth, note: u7, velocity: f32, retrigger: bool) void {
        const v          = &self.voices[0];
        const was_active = v.active;
        const target_log = std.math.log2(noteToFreq(note));
        if (retrigger or !was_active) {
            const start_log = if (was_active and self.glide_s > 0.0) v.glide_log_freq else target_log;
            v.* = .{
                .active           = true,
                .note             = note,
                .velocity         = velocity,
                .stage            = .attack,
                .stage2           = .attack,
                .glide_log_freq   = start_log,
                .glide_rate       = if (was_active and self.glide_s > 0.0)
                    (target_log - start_log) / @max(self.glide_s * self.sample_rate, 1.0)
                else 0.0,
                .noise_rand_state = (@as(u32, note) *% 0x9E3779B9) | 1,
            };
        } else {
            // Legato: update pitch only, envelope continues.
            v.note = note;
            if (self.glide_s > 0.0) {
                v.glide_rate = (target_log - v.glide_log_freq) /
                    @max(self.glide_s * self.sample_rate, 1.0);
            } else {
                v.glide_log_freq = target_log;
                v.glide_rate     = 0.0;
            }
        }
    }

    fn pushHeld(self: *PolySynth, note: u7, velocity: f32) void {
        for (0..self.held_count) |i| {
            if (self.held_notes[i] == note) {
                self.held_velocities[i] = velocity;
                return;
            }
        }
        if (self.held_count < self.held_notes.len) {
            self.held_notes[self.held_count]      = note;
            self.held_velocities[self.held_count] = velocity;
            self.held_count += 1;
        }
    }

    fn popHeld(self: *PolySynth, note: u7) void {
        for (0..self.held_count) |i| {
            if (self.held_notes[i] == note) {
                self.held_count -= 1;
                for (i..self.held_count) |j| {
                    self.held_notes[j]      = self.held_notes[j + 1];
                    self.held_velocities[j] = self.held_velocities[j + 1];
                }
                return;
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

        // Block-rate LFO: sample once before the voice loop so all voices
        // receive the same value, avoiding inter-voice phase desync.
        const lfo_val = lfoSample(self.lfo_shape, self.lfo_phase);

        // Precompute per-block envelope increments.
        const attack_inc  = 1.0 / @max(self.attack_s  * self.sample_rate, 1.0);
        const decay_inc   = (1.0 - self.sustain)       / @max(self.decay_s   * self.sample_rate, 1.0);
        const release_inc = 1.0                        / @max(self.release_s  * self.sample_rate, 1.0);

        const fenv_attack_inc  = 1.0 / @max(self.fenv_attack_s  * self.sample_rate, 1.0);
        const fenv_decay_inc   = (1.0 - self.fenv_sustain)       / @max(self.fenv_decay_s   * self.sample_rate, 1.0);
        const fenv_release_inc = 1.0                              / @max(self.fenv_release_s  * self.sample_rate, 1.0);

        // osc_budget: split evenly between OSC A and B so total ≤ 32.
        var active_count: usize = 0;
        for (self.voices) |v| if (v.active) { active_count += 1; };
        const osc_count: usize = 1 + @as(usize, if (self.osc_b_on) 1 else 0);
        const per_osc_cap: usize = if (active_count > 0)
            @max(osc_budget / active_count / osc_count, 1)
        else max_unison;

        for (&self.voices) |*v| {
            if (!v.active) continue;

            // Glide: advance current log-freq toward target at block rate.
            const target_log = std.math.log2(noteToFreq(v.note));
            if (self.glide_s > 0.0 and v.glide_rate != 0.0) {
                v.glide_log_freq += v.glide_rate * @as(f32, @floatFromInt(frames));
                const overshot = (v.glide_rate > 0.0 and v.glide_log_freq >= target_log) or
                                 (v.glide_rate < 0.0 and v.glide_log_freq <= target_log);
                if (overshot) { v.glide_log_freq = target_log; v.glide_rate = 0.0; }
            } else {
                v.glide_log_freq = target_log;
                v.glide_rate     = 0.0;
            }

            // Cutoff = base × filter-env mod × LFO (±2 oct at full depth).
            const fenv_mod = std.math.pow(f32, 2.0, self.fenv_amount * v.env2);
            const lfo_filter_mod = if (self.lfo_target == .filter)
                std.math.pow(f32, 2.0, self.lfo_depth * 2.0 * lfo_val)
            else 1.0;
            const effective_cutoff = std.math.clamp(
                self.filter_cutoff * fenv_mod * lfo_filter_mod, 20.0, self.sample_rate * 0.49,
            );
            const fc = self.computeFilterCoeffs(effective_cutoff);

            // Pitch vibrato: ±1 oct at full depth. Glide is in log-freq space.
            const lfo_pitch_log = if (self.lfo_target == .pitch) self.lfo_depth * lfo_val else 0.0;
            const base_freq = std.math.pow(f32, 2.0,
                v.glide_log_freq + self.detune_cents / 1200.0 + lfo_pitch_log +
                self.pitch_bend_semitones / 12.0);

            // Tremolo: LFO converted to [0,1]; depth controls dip depth.
            // At depth=1, lfo trough → amp_mod=0; lfo peak → amp_mod=1.
            const amp_mod: f32 = if (self.lfo_target == .amp) blk: {
                const lfo_uni = (lfo_val + 1.0) * 0.5;
                break :blk 1.0 - self.lfo_depth * (1.0 - lfo_uni);
            } else 1.0;

            const n_a: usize = @min(@min(@as(usize, @max(self.unison,     1)), max_unison), per_osc_cap);
            const n_b: usize = if (self.osc_b_on)
                @min(@min(@as(usize, @max(self.osc_b_unison, 1)), max_unison), per_osc_cap)
            else 0;

            // Precompute per-unison phase increments for OSC A.
            var phase_incs_a: [max_unison]f32 = undefined;
            for (0..n_a) |ui| {
                const spread: f32 = if (n_a > 1) blk: {
                    const t = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(n_a - 1));
                    break :blk (t * 2.0 - 1.0) * self.unison_detune * 0.5;
                } else 0.0;
                phase_incs_a[ui] = base_freq * std.math.pow(f32, 2.0, spread / 1200.0) / self.sample_rate;
            }

            // Precompute per-unison phase increments for OSC B.
            var phase_incs_b: [max_unison]f32 = undefined;
            if (self.osc_b_on) {
                const b_freq = base_freq * std.math.pow(f32, 2.0,
                    self.osc_b_semi / 12.0 + self.osc_b_detune_cents / 1200.0);
                for (0..n_b) |ui| {
                    const spread: f32 = if (n_b > 1) blk: {
                        const t = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(n_b - 1));
                        break :blk (t * 2.0 - 1.0) * self.osc_b_unison_detune * 0.5;
                    } else 0.0;
                    phase_incs_b[ui] = b_freq * std.math.pow(f32, 2.0, spread / 1200.0) / self.sample_rate;
                }
            }

            // Per-voice sub phase increment (half-frequency = one octave below).
            const sub_phase_inc = base_freq * 0.5 / self.sample_rate;

            // Noise color: one-pole LP pole coefficient. color=1 → white, color=0 → dark.
            const noise_lp_a = (1.0 - self.noise_color) * 0.99;

            // Power-preserving normalisation across all sources.
            const scale_a = 1.0 / @sqrt(@as(f32, @floatFromInt(n_a)));
            const scale_b = if (n_b > 0) 1.0 / @sqrt(@as(f32, @floatFromInt(n_b))) else 0.0;
            const b_pow   = self.osc_b_level * self.osc_b_level * @as(f32, if (self.osc_b_on) 1.0 else 0.0);
            const mix_norm = 1.0 / @sqrt(1.0 + b_pow
                + self.sub_level * self.sub_level
                + self.noise_level * self.noise_level);
            // ring_mix_norm: B acts as modulator only, so exclude b_pow.
            const ring_mix_norm = 1.0 / @sqrt(1.0
                + self.sub_level * self.sub_level
                + self.noise_level * self.noise_level);

            // Stereo pan gains per unison voice — constant-power, √2-compensated so
            // spread=0 gives the same per-channel amplitude as the original mono path.
            const pan_scale = std.math.sqrt2;
            var pan_l_a: [max_unison]f32 = undefined;
            var pan_r_a: [max_unison]f32 = undefined;
            for (0..n_a) |ui| {
                const raw: f32 = if (n_a > 1 and self.unison_spread > 0.0)
                    ((@as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(n_a - 1))) * 2.0 - 1.0)
                    * self.unison_spread
                else 0.0;
                const angle = (raw + 1.0) * std.math.pi * 0.25;
                pan_l_a[ui] = pan_scale * @cos(angle);
                pan_r_a[ui] = pan_scale * @sin(angle);
            }
            var pan_l_b: [max_unison]f32 = undefined;
            var pan_r_b: [max_unison]f32 = undefined;
            if (self.osc_b_on) {
                for (0..n_b) |ui| {
                    const raw: f32 = if (n_b > 1 and self.unison_spread > 0.0)
                        ((@as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(n_b - 1))) * 2.0 - 1.0)
                        * self.unison_spread
                    else 0.0;
                    const angle = (raw + 1.0) * std.math.pi * 0.25;
                    pan_l_b[ui] = pan_scale * @cos(angle);
                    pan_r_b[ui] = pan_scale * @sin(angle);
                }
            }

            for (0..frames) |i| {
                var a_l: f32 = 0.0;
                var a_r: f32 = 0.0;
                var a_mono: f32 = 0.0; // arithmetic mean of A voices — used by mod modes
                var b_l: f32 = 0.0;
                var b_r: f32 = 0.0;
                var b_mono: f32 = 0.0;

                // FM B→A: render B first so b_mono is ready when A phases advance.
                if (self.osc_b_on and self.mod_mode == .fm_b_to_a) {
                    for (0..n_b) |ui| {
                        const samp = self.oscSampleB(v.phases_b[ui]);
                        b_l += samp * pan_l_b[ui];
                        b_r += samp * pan_r_b[ui];
                        b_mono += samp;
                        v.phases_b[ui] += phase_incs_b[ui];
                        v.phases_b[ui] -= @floor(v.phases_b[ui]);
                    }
                    b_mono /= @as(f32, @floatFromInt(n_b));
                }

                // OSC A: phase is FM-modulated by b_mono when mod_mode == fm_b_to_a.
                for (0..n_a) |ui| {
                    const samp = self.oscSampleA(v.phases[ui]);
                    a_l += samp * pan_l_a[ui];
                    a_r += samp * pan_r_a[ui];
                    a_mono += samp;
                    const inc: f32 = if (self.mod_mode == .fm_b_to_a)
                        phase_incs_a[ui] * (1.0 + self.mod_amount * b_mono)
                    else
                        phase_incs_a[ui];
                    v.phases[ui] += inc;
                    if (self.mod_mode == .fm_b_to_a) {
                        v.phases[ui] -= @floor(v.phases[ui]);
                    } else {
                        if (v.phases[ui] >= 1.0) v.phases[ui] -= 1.0;
                    }
                }
                a_mono /= @as(f32, @floatFromInt(n_a));

                // OSC B: skip if already rendered above for fm_b_to_a.
                if (self.osc_b_on and self.mod_mode != .fm_b_to_a) {
                    for (0..n_b) |ui| {
                        const samp = self.oscSampleB(v.phases_b[ui]);
                        b_l += samp * pan_l_b[ui];
                        b_r += samp * pan_r_b[ui];
                        b_mono += samp;
                        // FM A→B: advance B's phase modulated by a_mono.
                        const inc: f32 = if (self.mod_mode == .fm_a_to_b)
                            phase_incs_b[ui] * (1.0 + self.mod_amount * a_mono)
                        else
                            phase_incs_b[ui];
                        v.phases_b[ui] += inc;
                        if (self.mod_mode == .fm_a_to_b) {
                            v.phases_b[ui] -= @floor(v.phases_b[ui]);
                        } else {
                            if (v.phases_b[ui] >= 1.0) v.phases_b[ui] -= 1.0;
                        }
                    }
                    b_mono /= @as(f32, @floatFromInt(n_b));
                }

                // AM: post-hoc amplitude scaling — (1 + m·mod) / (1 + m) keeps peak = 1.
                // Clamped to [0,1]: mod_amount up to 8 can drive the formula negative otherwise.
                if (self.osc_b_on) switch (self.mod_mode) {
                    .am_a_to_b => {
                        const g = std.math.clamp((1.0 + self.mod_amount * a_mono) / (1.0 + self.mod_amount), 0.0, 1.0);
                        b_l *= g; b_r *= g;
                    },
                    .am_b_to_a => {
                        const g = std.math.clamp((1.0 + self.mod_amount * b_mono) / (1.0 + self.mod_amount), 0.0, 1.0);
                        a_l *= g; a_r *= g;
                    },
                    else => {},
                };

                // Sub: always centre (mono → both channels).
                var sub_out: f32 = 0.0;
                if (self.sub_level > 0.0) {
                    sub_out = (switch (self.sub_shape) {
                        .sine   => @sin(2.0 * std.math.pi * v.sub_phase),
                        .square => if (v.sub_phase < 0.5) @as(f32, 1.0) else @as(f32, -1.0),
                    }) * self.sub_level;
                    v.sub_phase += sub_phase_inc;
                    if (v.sub_phase >= 1.0) v.sub_phase -= 1.0;
                }

                // Noise: always centre.
                var nse_out: f32 = 0.0;
                if (self.noise_level > 0.0) {
                    const raw = nextNoise(&v.noise_rand_state);
                    v.noise_lp = (1.0 - noise_lp_a) * raw + noise_lp_a * v.noise_lp;
                    nse_out = v.noise_lp * self.noise_level;
                }

                // Stereo mix.
                // Ring: dry↔ring crossfade — depth=0 → A unmodulated; depth=1 → A·b_mono.
                // Formula: (1-d) + d·b_mono stays in [-1,1] for d∈[0,1], b_mono∈[-1,1].
                // FM/AM/none: standard A + B mix (B contribution already modulated above).
                const ring_factor: f32 = if (self.osc_b_on and self.mod_mode == .ring) blk: {
                    const depth = std.math.clamp(self.mod_amount, 0.0, 1.0);
                    break :blk (1.0 - depth) + depth * b_mono;
                } else 0.0;
                const osc_l: f32 = if (self.osc_b_on and self.mod_mode == .ring)
                    (a_l * scale_a * ring_factor + sub_out + nse_out) * ring_mix_norm
                else
                    (a_l * scale_a + b_l * scale_b * self.osc_b_level + sub_out + nse_out) * mix_norm;
                const osc_r: f32 = if (self.osc_b_on and self.mod_mode == .ring)
                    (a_r * scale_a * ring_factor + sub_out + nse_out) * ring_mix_norm
                else
                    (a_r * scale_a + b_r * scale_b * self.osc_b_level + sub_out + nse_out) * mix_norm;

                // Stereo filter: same coefficients, independent L/R biquad histories.
                const filt_l = fc.b0*osc_l + fc.b1*v.x1   + fc.b2*v.x2   - fc.a1*v.y1   - fc.a2*v.y2;
                v.x2 = v.x1; v.x1 = osc_l; v.y2 = v.y1; v.y1 = filt_l;

                const filt_r = fc.b0*osc_r + fc.b1*v.x1_r + fc.b2*v.x2_r - fc.a1*v.y1_r - fc.a2*v.y2_r;
                v.x2_r = v.x1_r; v.x1_r = osc_r; v.y2_r = v.y1_r; v.y1_r = filt_r;

                const sg = v.env * v.velocity * self.gain * amp_mod;
                buf[i * 2]     += filt_l * sg;
                buf[i * 2 + 1] += filt_r * sg;

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

        // Advance LFO once per block after all voices are done.
        self.lfo_phase += self.lfo_rate_hz * @as(f32, @floatFromInt(frames)) / self.sample_rate;
        self.lfo_phase -= @floor(self.lfo_phase);
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

    /// Xorshift32 white noise, returns [-1, 1).
    fn nextNoise(state: *u32) f32 {
        state.* ^= state.* << 13;
        state.* ^= state.* >> 17;
        state.* ^= state.* << 5;
        const i: i32 = @bitCast(state.*);
        return @as(f32, @floatFromInt(i)) * (1.0 / 2147483648.0);
    }

    fn lfoSample(shape: LfoShape, phase: f32) f32 {
        return switch (shape) {
            .sine     => @sin(2.0 * std.math.pi * phase),
            .triangle => 1.0 - 4.0 * @abs(phase - 0.5),
            .saw      => 2.0 * phase - 1.0,
            .square   => if (phase < 0.5) 1.0 else -1.0,
        };
    }

    fn oscSampleA(self: *const PolySynth, phase: f32) Sample {
        return oscWave(self.waveform, phase, self.pulse_width);
    }

    fn oscSampleB(self: *const PolySynth, phase: f32) Sample {
        return oscWave(self.osc_b_waveform, phase, self.osc_b_pulse_width);
    }

    fn oscWave(wf: Waveform, phase: f32, pw: f32) Sample {
        return switch (wf) {
            .sine     => @sin(2.0 * std.math.pi * phase),
            .saw      => 2.0 * phase - 1.0,
            .triangle => 1.0 - 4.0 * @abs(phase - 0.5),
            .square   => if (phase < pw) 1.0 else -1.0,
        };
    }

    pub fn resetAll(self: *PolySynth) void {
        for (&self.voices) |*v| v.* = .{};
        self.held_count = 0;
    }

    /// Apply a raw MIDI CC. Safe to call on the audio thread (field writes only).
    pub fn applyCC(self: *PolySynth, cc: u7, value: u7) void {
        const v01 = @as(f32, @floatFromInt(value)) / 127.0;
        switch (@as(midi.CC, @enumFromInt(cc))) {
            .mod_wheel         => self.lfo_depth = v01,
            .glide_time        => self.glide_s   = v01 * 4.0,
            .gain              => self.gain       = v01,
            .osc_a_waveform    => self.waveform         = ccWaveform(value),
            .osc_a_pulse_width => self.pulse_width       = 0.01 + v01 * 0.98,
            .osc_a_unison      => self.unison            = @intCast(1 + @as(u8, @intFromFloat(@round(v01 * 15.0)))),
            .osc_a_unison_det  => self.unison_detune     = v01 * 100.0,
            .osc_a_spread      => self.unison_spread     = v01,
            .osc_b_on          => self.osc_b_on           = value > 63,
            .osc_b_waveform    => self.osc_b_waveform     = ccWaveform(value),
            .osc_b_semi        => self.osc_b_semi         = v01 * 48.0 - 24.0,
            .osc_b_detune      => self.osc_b_detune_cents = v01 * 200.0 - 100.0,
            .osc_b_level       => self.osc_b_level        = v01,
            .sub_level         => self.sub_level    = v01,
            .noise_level       => self.noise_level  = v01,
            .noise_color       => self.noise_color  = v01,
            .lfo_rate          => self.lfo_rate_hz  = 0.01 * std.math.pow(f32, 2000.0, v01),
            .lfo_depth_cc      => self.lfo_depth    = v01,
            .mod_amount        => self.mod_amount   = v01 * 8.0,
            .filter_res        => self.filter_res    = v01,
            .amp_release       => self.release_s     = v01 * 4.0,
            .amp_attack        => self.attack_s      = v01 * 4.0,
            .filter_cutoff     => self.filter_cutoff = ccCutoff(value),
            .amp_decay         => self.decay_s       = v01 * 4.0,
            .amp_sustain       => self.sustain       = v01,
            .fenv_amount       => self.fenv_amount   = v01 * 8.0 - 4.0,
            .fenv_attack       => self.fenv_attack_s  = v01 * 4.0,
            .fenv_decay        => self.fenv_decay_s   = v01 * 4.0,
            .fenv_sustain      => self.fenv_sustain   = v01,
            .fenv_release      => self.fenv_release_s = v01 * 4.0,
            .all_sound_off     => self.resetAll(),
            .all_notes_off     => { for (0..128) |n| self.noteOff(@intCast(n)); },
            .reset_all_ctrls   => {},
            _                  => {},
        }
    }

    /// Nudge the editor parameter at `id` by `steps` (h/l = ±1, H/L = ±10).
    /// Runs on the audio thread (via the `set_param` event) so it never races
    /// the block reader — the editor sends edits over the command queue rather
    /// than writing these fields directly.
    pub fn adjustParam(self: *PolySynth, id: u8, steps: i32) void {
        const s: f32 = @floatFromInt(steps);
        switch (id) {
            0  => self.waveform = if (steps > 0) switch (self.waveform) {
                .sine => .saw, .saw => .triangle, .triangle => .square, .square => .sine,
            } else switch (self.waveform) {
                .sine => .square, .saw => .sine, .triangle => .saw, .square => .triangle,
            },
            1  => self.pulse_width         = std.math.clamp(self.pulse_width        + s * 0.01,   0.01,   0.99),
            2  => self.detune_cents         = std.math.clamp(self.detune_cents       + s * 1.0,  -100.0, 100.0),
            3  => self.unison               = @intCast(std.math.clamp(@as(i32, self.unison) + steps, 1, 16)),
            4  => self.unison_detune        = std.math.clamp(self.unison_detune      + s * 1.0,    0.0,  100.0),
            5  => self.unison_spread        = std.math.clamp(self.unison_spread      + s * 0.01,   0.0,    1.0),
            6  => self.osc_b_on             = !self.osc_b_on,
            7  => self.osc_b_waveform = if (steps > 0) switch (self.osc_b_waveform) {
                .sine => .saw, .saw => .triangle, .triangle => .square, .square => .sine,
            } else switch (self.osc_b_waveform) {
                .sine => .square, .saw => .sine, .triangle => .saw, .square => .triangle,
            },
            8  => self.osc_b_pulse_width    = std.math.clamp(self.osc_b_pulse_width  + s * 0.01,   0.01,   0.99),
            9  => self.osc_b_semi           = std.math.clamp(self.osc_b_semi         + s * 1.0,  -24.0,   24.0),
            10 => self.osc_b_detune_cents   = std.math.clamp(self.osc_b_detune_cents + s * 1.0, -100.0,  100.0),
            11 => self.osc_b_level          = std.math.clamp(self.osc_b_level        + s * 0.01,   0.0,    1.0),
            12 => self.osc_b_unison         = @intCast(std.math.clamp(@as(i32, self.osc_b_unison) + steps, 1, 16)),
            13 => self.osc_b_unison_detune  = std.math.clamp(self.osc_b_unison_detune + s * 1.0,   0.0,  100.0),
            // MOD (14–15)
            14 => self.mod_mode = if (steps > 0) switch (self.mod_mode) {
                .none => .ring, .ring => .am_a_to_b, .am_a_to_b => .am_b_to_a,
                .am_b_to_a => .fm_a_to_b, .fm_a_to_b => .fm_b_to_a, .fm_b_to_a => .none,
            } else switch (self.mod_mode) {
                .none => .fm_b_to_a, .ring => .none, .am_a_to_b => .ring,
                .am_b_to_a => .am_a_to_b, .fm_a_to_b => .am_b_to_a, .fm_b_to_a => .fm_a_to_b,
            },
            15 => self.mod_amount           = std.math.clamp(self.mod_amount         + s * 0.05,   0.0,    8.0),
            // ENV (16–19)
            16 => self.attack_s             = std.math.clamp(self.attack_s           + s * 0.001, 0.001,   5.0),
            17 => self.decay_s              = std.math.clamp(self.decay_s            + s * 0.005, 0.001,   5.0),
            18 => self.sustain              = std.math.clamp(self.sustain            + s * 0.01,   0.0,    1.0),
            19 => self.release_s            = std.math.clamp(self.release_s          + s * 0.005, 0.001,  10.0),
            // FILTER (20–23)
            20 => self.filter_type = if (steps > 0) switch (self.filter_type) {
                .lp => .hp, .hp => .bp, .bp => .notch, .notch => .lp,
            } else switch (self.filter_type) {
                .lp => .notch, .hp => .lp, .bp => .hp, .notch => .bp,
            },
            // Log-scale cutoff: 1 semitone per step (h/l), ~minor-7th per H/L.
            21 => self.filter_cutoff        = std.math.clamp(
                self.filter_cutoff * std.math.pow(f32, 2.0, s / 12.0), 20.0, 20_000.0),
            22 => self.filter_res           = std.math.clamp(self.filter_res         + s * 0.01,   0.0,    1.0),
            23 => self.fenv_amount          = std.math.clamp(self.fenv_amount        + s * 0.1,   -4.0,    4.0),
            // FENV (24–27)
            24 => self.fenv_attack_s        = std.math.clamp(self.fenv_attack_s      + s * 0.001, 0.001,   5.0),
            25 => self.fenv_decay_s         = std.math.clamp(self.fenv_decay_s       + s * 0.005, 0.001,   5.0),
            26 => self.fenv_sustain         = std.math.clamp(self.fenv_sustain       + s * 0.01,   0.0,    1.0),
            27 => self.fenv_release_s       = std.math.clamp(self.fenv_release_s     + s * 0.005, 0.001,  10.0),
            // LFO (28–31)
            28 => self.lfo_shape = if (steps > 0) switch (self.lfo_shape) {
                .sine => .triangle, .triangle => .saw, .saw => .square, .square => .sine,
            } else switch (self.lfo_shape) {
                .sine => .square, .triangle => .sine, .saw => .triangle, .square => .saw,
            },
            29 => self.lfo_rate_hz          = std.math.clamp(self.lfo_rate_hz        + s * 0.1,   0.01,   20.0),
            30 => self.lfo_depth            = std.math.clamp(self.lfo_depth          + s * 0.01,   0.0,    1.0),
            31 => self.lfo_target = if (steps > 0) switch (self.lfo_target) {
                .none => .filter, .filter => .pitch, .pitch => .amp, .amp => .none,
            } else switch (self.lfo_target) {
                .none => .amp, .filter => .none, .pitch => .filter, .amp => .pitch,
            },
            // VOICE (32–33)
            32 => self.voice_mode = if (steps > 0) switch (self.voice_mode) {
                .poly => .mono, .mono => .legato, .legato => .poly,
            } else switch (self.voice_mode) {
                .poly => .legato, .mono => .poly, .legato => .mono,
            },
            33 => self.glide_s              = std.math.clamp(self.glide_s            + s * 0.01,   0.0,   10.0),
            // SUB (34–35)
            34 => self.sub_level            = std.math.clamp(self.sub_level          + s * 0.01,   0.0,    1.0),
            35 => self.sub_shape = if (steps > 0) switch (self.sub_shape) {
                .sine => .square, .square => .sine,
            } else switch (self.sub_shape) {
                .sine => .square, .square => .sine,
            },
            // NOISE (36–37)
            36 => self.noise_level          = std.math.clamp(self.noise_level        + s * 0.01,   0.0,    1.0),
            37 => self.noise_color          = std.math.clamp(self.noise_color        + s * 0.01,   0.0,    1.0),
            // OUT (38)
            38 => self.gain                 = std.math.clamp(self.gain               + s * 0.01,  0.01,    1.0),
            else => {},
        }
    }

    /// Apply a MIDI pitch bend. `bend` is −8192..+8191; `range_semitones` = ±range.
    pub fn applyPitchBend(self: *PolySynth, bend: i16, range_semitones: f32) void {
        self.pitch_bend_semitones = @as(f32, @floatFromInt(bend)) / 8192.0 * range_semitones;
    }

    fn ccWaveform(value: u7) Waveform {
        return @enumFromInt(@min(3, value >> 5));
    }

    fn ccCutoff(value: u7) f32 {
        // Logarithmic: 0 → 20 Hz, 127 → 18 000 Hz.
        return 20.0 * std.math.pow(f32, 900.0, @as(f32, @floatFromInt(value)) / 127.0);
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *PolySynth = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn eventOpaque(ptr: *anyopaque, ev: dsp.Event) void {
        const self: *PolySynth = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .note_on    => |e| self.noteOn(e.note, e.velocity),
            .note_off   => |e| self.noteOff(e.note),
            .all_off    => self.resetAll(),
            .cc         => |e| self.applyCC(e.cc, e.value),
            .pitch_bend => |e| self.applyPitchBend(e.bend, 2.0),
            .set_param  => |e| self.adjustParam(e.id, e.steps),
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

test "LFO: phase advances by rate×frames/sr each block" {
    var synth = PolySynth.init(48_000);
    synth.lfo_rate_hz = 10.0;
    synth.noteOn(60, 1.0);
    var buf: [256]Sample = undefined;
    @memset(&buf, 0.0);
    synth.processBlock(&buf); // 128 frames
    const expected_phase = 10.0 * 128.0 / 48_000.0;
    try std.testing.expectApproxEqAbs(expected_phase, synth.lfo_phase, 1e-5);
}

test "LFO tremolo: square wave at 0 Hz halves amplitude at depth=1 (trough)" {
    // LFO square at phase=0.75 → value = -1 (trough). Trough + depth=1 → amp_mod=0.
    // To get trough reliably: start phase at 0.5 (square goes low) so first block sees val=-1.
    var with_lfo = PolySynth.init(48_000);
    with_lfo.lfo_shape  = .square;
    with_lfo.lfo_rate_hz = 0.0; // frozen
    with_lfo.lfo_depth  = 1.0;
    with_lfo.lfo_target = .amp;
    with_lfo.lfo_phase  = 0.75; // square trough → lfo_val = -1 → amp_mod = 0
    with_lfo.noteOn(60, 1.0);

    var without_lfo = PolySynth.init(48_000);
    without_lfo.lfo_target = .none;
    without_lfo.noteOn(60, 1.0);

    var buf_lfo: [256]Sample = undefined;
    var buf_dry: [256]Sample = undefined;
    // Warm up past attack
    for (0..20) |_| {
        @memset(&buf_lfo, 0.0); with_lfo.processBlock(&buf_lfo);
        @memset(&buf_dry, 0.0); without_lfo.processBlock(&buf_dry);
    }
    var rms_lfo: f32 = 0.0;
    for (buf_lfo) |s| rms_lfo += s * s;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rms_lfo, 1e-6);
}

test "polyphony: up to max_voices voices" {
    var synth = PolySynth.init(48_000);
    for (0..PolySynth.max_voices) |i| synth.noteOn(@intCast(60 + i), 1.0);
    var active: usize = 0;
    for (synth.voices) |v| if (v.active) { active += 1; };
    try std.testing.expectEqual(PolySynth.max_voices, active);
}

test "osc_budget: unison capped when many voices active" {
    var synth = PolySynth.init(48_000);
    synth.unison = 16;
    // With 16 active voices, unison_cap = 32/16 = 2 per voice.
    for (0..16) |i| synth.noteOn(@intCast(48 + i), 1.0);
    var buf: [512]Sample = undefined;
    for (0..4) |_| { @memset(&buf, 0.0); synth.processBlock(&buf); }
    for (buf) |s| {
        try std.testing.expect(!std.math.isNan(s));
        try std.testing.expect(!std.math.isInf(s));
    }
}

test "glide: pitch slides over time (log-linear)" {
    var synth = PolySynth.init(48_000);
    synth.voice_mode = .mono;
    synth.glide_s    = 0.5; // half-second glide
    synth.noteOn(60, 1.0); // C4
    // Trigger glide to A4 — voice was active so glide applies.
    synth.noteOn(69, 1.0); // A4
    // glide_log_freq should still be at C4 (not yet advanced)
    const c4_log = std.math.log2(PolySynth.noteToFreq(60));
    try std.testing.expectApproxEqAbs(c4_log, synth.voices[0].glide_log_freq, 1e-4);
    // After processing, frequency should have moved toward A4 but not arrived.
    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0); synth.processBlock(&buf);
    const a4_log = std.math.log2(PolySynth.noteToFreq(69));
    try std.testing.expect(synth.voices[0].glide_log_freq > c4_log);
    try std.testing.expect(synth.voices[0].glide_log_freq < a4_log);
}

test "glide: snaps immediately when glide_s=0" {
    var synth = PolySynth.init(48_000);
    synth.voice_mode = .mono;
    synth.glide_s    = 0.0;
    synth.noteOn(60, 1.0);
    synth.noteOn(69, 1.0);
    const a4_log = std.math.log2(PolySynth.noteToFreq(69));
    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0); synth.processBlock(&buf);
    try std.testing.expectApproxEqAbs(a4_log, synth.voices[0].glide_log_freq, 1e-4);
}

test "mono mode: only one voice active" {
    var synth = PolySynth.init(48_000);
    synth.voice_mode = .mono;
    synth.noteOn(60, 1.0);
    synth.noteOn(64, 1.0);
    synth.noteOn(67, 1.0);
    var active: usize = 0;
    for (synth.voices) |v| if (v.active) { active += 1; };
    try std.testing.expectEqual(@as(usize, 1), active);
    try std.testing.expectEqual(@as(u7, 67), synth.voices[0].note);
}

test "mono mode: note-off retrieves last held note" {
    var synth = PolySynth.init(48_000);
    synth.voice_mode = .mono;
    synth.noteOn(60, 1.0);
    synth.noteOn(64, 1.0);
    synth.noteOff(64);
    try std.testing.expectEqual(@as(u7, 60), synth.voices[0].note);
    try std.testing.expect(synth.voices[0].active);
    try std.testing.expect(synth.voices[0].stage != .release);
}

test "legato mode: no envelope retrigger on second note" {
    var synth = PolySynth.init(48_000);
    synth.voice_mode = .legato;
    synth.noteOn(60, 1.0);
    var buf: [512]Sample = undefined;
    // Warm up past attack so we're in sustain
    for (0..100) |_| { @memset(&buf, 0.0); synth.processBlock(&buf); }
    const env_before = synth.voices[0].env;
    // Second note in legato — should not retrigger (env stays in sustain, not reset to 0)
    synth.noteOn(64, 1.0);
    try std.testing.expectEqual(@as(u7, 64), synth.voices[0].note);
    try std.testing.expect(synth.voices[0].stage != .attack); // still in sustain
    try std.testing.expectApproxEqAbs(env_before, synth.voices[0].env, 0.01);
}

test "LFO: all shapes stay finite under filter modulation" {
    const shapes = [_]LfoShape{ .sine, .triangle, .saw, .square };
    for (shapes) |shape| {
        var synth = PolySynth.init(48_000);
        synth.lfo_shape   = shape;
        synth.lfo_rate_hz = 5.0;
        synth.lfo_depth   = 1.0;
        synth.lfo_target  = .filter;
        synth.filter_cutoff = 2_000.0;
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
}

test "applyCC: cutoff logarithmic scaling" {
    var synth = PolySynth.init(48_000);
    synth.applyCC(@intFromEnum(midi.CC.filter_cutoff), 0);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), synth.filter_cutoff, 1.0);
    synth.applyCC(@intFromEnum(midi.CC.filter_cutoff), 127);
    try std.testing.expect(synth.filter_cutoff > 17_000.0);
}

test "applyCC: waveform steps" {
    var synth = PolySynth.init(48_000);
    synth.applyCC(@intFromEnum(midi.CC.osc_a_waveform), 0);
    try std.testing.expectEqual(Waveform.sine, synth.waveform);
    synth.applyCC(@intFromEnum(midi.CC.osc_a_waveform), 32);
    try std.testing.expectEqual(Waveform.saw, synth.waveform);
    synth.applyCC(@intFromEnum(midi.CC.osc_a_waveform), 127);
    try std.testing.expectEqual(Waveform.square, synth.waveform);
}

test "applyPitchBend: range at ±2 semitones" {
    var synth = PolySynth.init(48_000);
    synth.applyPitchBend(8191, 2.0);
    try std.testing.expect(synth.pitch_bend_semitones > 1.9);
    synth.applyPitchBend(-8192, 2.0);
    try std.testing.expect(synth.pitch_bend_semitones < -1.9);
    synth.applyPitchBend(0, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), synth.pitch_bend_semitones, 1e-4);
}

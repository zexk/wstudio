//! Polyphonic subtractive synth: oscillator per voice with ADSR amplitude
//! and filter envelopes, multiple filter modes, and unison.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const midi = @import("../midi.zig");
const Saturator = @import("saturator.zig").Saturator;
const Crusher = @import("crusher.zig").Crusher;

const Sample = types.Sample;

/// Enum/toggle params cross `paramValue`/`setParamAbsolute` as the
/// variant's 0-based declaration ordinal, rounded and clamped on the way
/// back in. The `> 0.0` guard doubles as the NaN check (a hand-edited
/// automation value could be anything), so a bad value degrades to the
/// first variant instead of tripping @intFromFloat safety.
fn enumToValue(e: anytype) f32 {
    return @floatFromInt(@intFromEnum(e));
}

fn enumFromValue(comptime E: type, value: f32) E {
    const n = @typeInfo(E).@"enum".fields.len;
    if (!(value > 0.0)) return @enumFromInt(0);
    const max: f32 = @floatFromInt(n - 1);
    if (value >= max) return @enumFromInt(n - 1);
    return @enumFromInt(@as(u8, @intFromFloat(@round(value))));
}

// zig fmt: off
pub const Waveform   = enum { sine, saw, triangle, square };
/// lp/hp/bp/notch are 2-pole biquads. `ladder` is a Moog-style 4-pole
/// lowpass (24 dB/oct, tanh-saturated feedback — self-oscillates near full
/// resonance). `comb` is a feedback comb whose fundamental sits at the
/// cutoff frequency (resonance = feedback amount); its delay line bounds
/// the low end at sample_rate/comb_len (~94 Hz at 48 kHz).
pub const FilterType = enum { lp, hp, bp, notch, ladder, comb };
/// How filter 2's output combines with filter 1's when filter 2 is on.
/// `series`: filter 1 feeds filter 2. `parallel`: both filter the dry
/// oscillator mix and their outputs are averaged. Irrelevant (and behaves
/// identically to filter 1 alone) while `filter2_on` is false.
pub const FilterRouting = enum { series, parallel };
/// `sh` is sample & hold: a random level (uniform in [-1, 1)) redrawn each
/// time the LFO's phase wraps — held state lives on PolySynth (`lfo_sh`),
/// not derivable from phase alone like the other shapes.
pub const LfoShape   = enum { sine, triangle, saw, square, sh };
/// Legacy fixed LFO routing, retired when the mod matrix absorbed it.
/// Kept only so pre-matrix patches/projects still parse; `legacyModRows`
/// folds it into matrix rows on load.
pub const LfoTarget  = enum { none, filter, pitch, amp };
/// Modulation source for a mod-matrix row. The LFOs, `wheel`, and the four
/// macro knobs are synth-global; fenv/aenv/velocity/keytrack are per-voice.
/// Macros are plain 0..1 values fanned out through matrix rows — one knob
/// (or one automation lane, ids 99-102) moving many destinations at once.
pub const ModSource  = enum { none, lfo, fenv, aenv, velocity, keytrack, wheel, lfo2, lfo3, mac1, mac2, mac3, mac4 };
pub const VoiceMode  = enum { poly, mono, legato };
pub const SubShape   = enum { sine, square };
pub const ModMode    = enum { none, ring, am_a_to_b, am_b_to_a, fm_a_to_b, fm_b_to_a };
/// Detune curve across unison voices. `spread`: symmetric, total width =
/// unison_detune cents (original behaviour). `step`: each voice offset by
/// a full unison_detune-cents step from its neighbor — a chord/stack-style
/// unison instead of a micro-detune blur. `harmonic`: voices bend upward
/// toward the integer harmonic series (1x, 2x, 3x, ...); `ratio` toward the
/// half-integer series (1x, 1.5x, 2x, ...) — a fifths/octaves power-chord
/// stack. For both, unison_detune is the blend: 0 = all voices at the
/// fundamental, 100 = exact series.
pub const UnisonMode  = enum { spread, step, harmonic, ratio };
/// Phase-warp applied to an oscillator's read phase before waveform lookup.
/// `bend`: pivots the ramp so one half of the cycle races the other (PD-style
/// asymmetry). `mirror`: folds the back part of the cycle backward instead of
/// letting it run forward (adds a fold-back harmonic edge). `sync`: multiplies
/// phase by an integer-ish ratio and wraps, giving the classic hard-sync buzz
/// without a second real oscillator. All three reduce to (near-)identity at
/// `warp_amount = 0`, so switching the mode alone never surprises the sound.
pub const WarpMode    = enum { none, bend, mirror, sync };
// zig fmt: on

/// Fixed-line stereo flanger for the synth's internal FX section. Unlike the
/// master-bus Chorus it owns no heap delay line — PolySynth embeds by value
/// in Rack and Rack.dupe copies it, so all state must be inline (same
/// constraint that sized the comb filter's ring). The 1024-sample ring caps
/// the sweep at ~21 ms at 48 kHz: flanger through light-chorus territory.
/// Params are passed per block (they come from PolySynth's fields plus
/// matrix modulation), only the audio state lives here.
pub const Flanger = struct {
    ring: [2][len]f32 = [_][len]f32{[_]f32{0.0} ** len} ** 2,
    pos: usize = 0,
    phase: f32 = 0.0,

    pub const len: usize = 1024;

    /// depth 0..1 scales the sweep span; feedback 0..0.95; mix 0=dry 1=wet.
    /// The right channel's LFO runs a quarter cycle ahead for stereo width.
    pub fn processBlock(self: *Flanger, buf: []Sample, sample_rate: f32, rate_hz: f32, depth: f32, feedback: f32, mix: f32) void {
        const len_f: f32 = @floatFromInt(len);
        const max_delay: f32 = len_f - 4.0;
        const inc = rate_hz / sample_rate;
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            inline for (0..2) |ch| {
                const ph = self.phase + @as(f32, if (ch == 1) 0.25 else 0.0);
                const lfo = 0.5 + 0.5 * @sin(ph * 2.0 * std.math.pi);
                // >= 1 sample of delay so the fractional read below never
                // touches the frame being written this iteration.
                const delay = 1.0 + lfo * depth * (max_delay - 1.0);
                var rp = @as(f32, @floatFromInt(self.pos)) - delay;
                if (rp < 0.0) rp += len_f;
                const tap_i: usize = @intFromFloat(rp);
                const frac = rp - @floor(rp);
                const tap = self.ring[ch][tap_i % len] * (1.0 - frac) +
                    self.ring[ch][(tap_i + 1) % len] * frac;
                const dry = buf[i + ch];
                self.ring[ch][self.pos] = dry + tap * feedback;
                buf[i + ch] = dry * (1.0 - mix) + tap * mix;
            }
            self.pos = (self.pos + 1) % len;
            self.phase += inc;
            self.phase -= @floor(self.phase);
        }
    }
};

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
    unison_mode: UnisonMode = .spread,
    warp_mode: WarpMode = .none,
    warp_amount: f32 = 0.0,

    // ── OSC B ────────────────────────────────────────────────────────────────
    // zig fmt: off
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
    osc_b_unison_mode:  UnisonMode = .spread,
    osc_b_warp_mode:    WarpMode   = .none,
    osc_b_warp_amount:  f32       = 0.0,

    // ── OSC C ────────────────────────────────────────────────────────────────
    /// Plain additive 3rd oscillator: no MOD A<->B or warp participation,
    /// same shape as OSC B otherwise. Kept simple deliberately — the mod
    /// matrix and warp are per-A/B-slot features, not per-oscillator ones.
    osc_c_on:           bool     = false,
    osc_c_waveform:     Waveform = .saw,
    osc_c_pulse_width:  f32      = 0.5,
    osc_c_semi:         f32      = 0.0,
    osc_c_detune_cents: f32      = 0.0,
    osc_c_level:        f32      = 1.0,
    osc_c_unison:       u8       = 1,
    osc_c_unison_detune: f32     = 15.0,
    osc_c_unison_mode:  UnisonMode = .spread,

    // ── AMP ENVELOPE ────────────────────────────────────────────────────────
    attack_s:  f32 = 0.005,
    decay_s:   f32 = 0.08,
    sustain:   f32 = 0.7,
    // zig fmt: on
    release_s: f32 = 0.25,

    // ── FILTER ──────────────────────────────────────────────────────────────
    filter_type: FilterType = .lp,
    /// Filter cutoff in Hz (20 Hz–Nyquist). Default open (18 kHz).
    filter_cutoff: f32 = 18_000.0,
    /// Filter resonance 0..1 (mapped to Q 0.5..20).
    filter_res: f32 = 0.0,

    // ── FILTER 2 ────────────────────────────────────────────────────────────
    /// Second filter slot. Shares the filter envelope/LFO-target modulation
    /// with filter 1 (its own cutoff as the base instead of a second env),
    /// so this stays a routing/model addition, not a second modulation rig.
    filter2_on: bool = false,
    filter2_type: FilterType = .lp,
    filter2_cutoff: f32 = 18_000.0,
    filter2_res: f32 = 0.0,
    filter_routing: FilterRouting = .series,

    // ── FILTER ENVELOPE ─────────────────────────────────────────────────────
    // zig fmt: off
    fenv_attack_s:  f32 = 0.005,
    fenv_decay_s:   f32 = 0.5,
    fenv_sustain:   f32 = 0.0,
    fenv_release_s: f32 = 0.3,

    // ── LFO ─────────────────────────────────────────────────────────────────
    // A pure mod source since the matrix absorbed its routing: shape + rate
    // here, destination/depth live on matrix rows.
    lfo_shape:  LfoShape  = .sine,
    // zig fmt: on
    /// Rate in Hz (0.01–20 Hz).
    lfo_rate_hz: f32 = 1.0,
    /// Synth-global LFO phase (0..1). Advanced once per block.
    lfo_phase: f32 = 0.0,

    // ── LFO 2 / LFO 3 ───────────────────────────────────────────────────────
    // Two more global LFOs, same shape+rate-only design as LFO 1 (routing
    // lives on matrix rows). Independent phases so different rates stay
    // free-running against each other.
    // zig fmt: off
    lfo2_shape:   LfoShape = .sine,
    lfo2_rate_hz: f32      = 1.0,
    lfo2_phase:   f32      = 0.0,
    lfo3_shape:   LfoShape = .sine,
    lfo3_rate_hz: f32      = 1.0,
    lfo3_phase:   f32      = 0.0,
    /// Held sample & hold level per LFO slot (0=LFO 1), redrawn on phase
    /// wrap. Runtime state like the phases, not part of a Patch.
    lfo_sh:       [3]f32   = .{ 0.0, 0.0, 0.0 },
    lfo_sh_rand:  u32      = 0x9E3779B9,

    // ── MACRO ───────────────────────────────────────────────────────────────
    // Performance knobs with no sound of their own: only matrix rows give
    // them meaning. Automatable (ids 99-102), so one automation lane can
    // ride every destination its rows fan out to.
    macro1: f32 = 0.0,
    macro2: f32 = 0.0,
    macro3: f32 = 0.0,
    macro4: f32 = 0.0,
    // zig fmt: on

    // ── MOD MATRIX ──────────────────────────────────────────────────────────
    /// Free-assign modulation routing: each row sends one source to one
    /// destination (a `mod_dest_ids` entry — an automatable param id or the
    /// virtual pitch/amp dests) with a bipolar depth. Evaluated per voice
    /// at block rate in processBlock; same-dest rows sum.
    mod_matrix: [max_mod_rows]ModRow = [_]ModRow{.{}} ** max_mod_rows,
    /// MIDI mod wheel (CC1), 0..1 — the `.wheel` matrix source.
    mod_wheel: f32 = 0.0,

    // ── VOICE ────────────────────────────────────────────────────────────────
    voice_mode: VoiceMode = .poly,
    /// Portamento time in seconds. 0 = off (snap).
    glide_s: f32 = 0.0,
    /// Note stack for mono/legato: last-in, first-out.
    // zig fmt: off
    held_notes:      [16]u7  = [_]u7{0}  ** 16,
    held_velocities: [16]f32 = [_]f32{0} ** 16,
    held_count: u8 = 0,

    // ── SUB ─────────────────────────────────────────────────────────────────
    /// Level 0 = off. Sine or square at -1 octave.
    sub_level: f32      = 0.0,
    // zig fmt: on
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

    // ── FX ──────────────────────────────────────────────────────────────────
    // Synth-internal insert FX, applied post-mix in fixed order dist →
    // crush → flanger. Base params live here (not on the state structs) so
    // applyPatch/toPatch pick them up by field name; each block writes the
    // effective values (base + matrix modulation) into the state structs.
    // Delay/reverb-class FX stay on the track chain — this section exists
    // for the params the matrix can reach, which the track chain can't be.
    // zig fmt: off
    fx_dist_on:          bool = false,
    fx_dist_drive_db:    f32  = 12.0,
    fx_dist_mix:         f32  = 1.0,
    fx_crush_on:         bool = false,
    fx_crush_bits:       f32  = 8.0,
    fx_crush_rate:       f32  = 4.0,
    fx_crush_mix:        f32  = 1.0,
    fx_flanger_on:       bool = false,
    fx_flanger_rate_hz:  f32  = 0.3,
    fx_flanger_depth:    f32  = 0.7,
    fx_flanger_feedback: f32  = 0.5,
    fx_flanger_mix:      f32  = 0.5,
    // zig fmt: on
    fx_crush_state: Crusher = .{},
    fx_flanger_state: Flanger = .{},
    /// Index of the most recently triggered voice: the FX destinations are
    /// global (post-mix), so their one matrix evaluation per block reads
    /// the per-voice sources (envs, velocity, keytrack) from this voice.
    newest_voice: u8 = 0,

    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,

    pub const max_voices = 16;
    pub const max_unison = 16;
    /// Hard cap on simultaneous oscillators across all active voices.
    /// With e.g. 8 active voices, unison is capped at 4 each → 32 total.
    pub const osc_budget: usize = 32;

    pub const max_mod_rows = 8;
    /// Virtual matrix destinations that aren't editor params: note pitch
    /// (amt = octaves) and voice amplitude (gain factor 1 + amt). Chosen
    /// well above the real param-id space so they can never collide.
    pub const dest_pitch: u8 = 254;
    pub const dest_amp: u8 = 255;

    /// One mod-matrix row. `dest` is a `mod_dest_ids` entry; `depth` is
    /// bipolar, scaled by the dest param's full range (linear params), or
    /// ±4 octaves (cutoffs), ±1 octave (pitch), ±1x gain (amp) at |1|.
    pub const ModRow = struct {
        source: ModSource = .none,
        dest: u8 = 21,
        depth: f32 = 0.0,
    };

    /// Legal matrix destinations: every automatable param that is consumed
    /// per voice (excludes the global LFO rates, the macro knobs, and the
    /// matrix's own depth ids — no self-modulation), the internal FX params
    /// (consumed globally,
    /// once per block — see processBlock's FX pass), plus the two virtual
    /// dests.
    pub const mod_dest_ids = [_]u8{
        // zig fmt: off
        1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19,
        21, 22, 24, 25, 26, 27, 33, 34, 36, 37, 38, 42, 44, 47, 48,
        52, 53, 54, 55, 56, 57,
        84, 85, 87, 88, 89, 91, 92, 93, 94,
        dest_pitch, dest_amp,
        // zig fmt: on
    };

    pub fn modDestLabel(dest: u8) []const u8 {
        return switch (dest) {
            // zig fmt: off
            dest_pitch => "PITCH",
            dest_amp   => "AMP",
            // zig fmt: on
            else => if (findAutomatableParam(dest)) |p| p.label else "?",
        };
    }

    pub fn modDestIndex(dest: u8) ?usize {
        for (mod_dest_ids, 0..) |d, i| if (d == dest) return i;
        return null;
    }

    /// Fold the retired fixed mod routes (filter-env amount, LFO target +
    /// depth) into equivalent matrix rows — the load-time migration for
    /// pre-matrix presets and project files. Depth scales match the old
    /// units: fenv was ±4 oct at ±4, lfo→filter ±2 oct at depth 1 (the
    /// matrix cutoff dest spans ±4 oct at |depth| 1), lfo→pitch ±1 oct at
    /// depth 1, lfo→amp swing d/2 about unity (the old tremolo's swing;
    /// its constant -d/2 level dip is not reproduced).
    pub fn legacyModRows(fenv_amount: f32, lfo_depth: f32, lfo_target: LfoTarget) [2]ModRow {
        return .{
            if (fenv_amount != 0.0)
                .{ .source = .fenv, .dest = 21, .depth = fenv_amount / 4.0 }
            else
                .{},
            switch (lfo_target) {
                .none => .{},
                // zig fmt: off
                .filter => .{ .source = .lfo, .dest = 21,         .depth = lfo_depth * 0.5 },
                .pitch  => .{ .source = .lfo, .dest = dest_pitch, .depth = lfo_depth },
                .amp    => .{ .source = .lfo, .dest = dest_amp,   .depth = lfo_depth * 0.5 },
                // zig fmt: on
            },
        };
    }

    pub fn matrixEmpty(rows: [max_mod_rows]ModRow) bool {
        for (rows) |r| if (r.source != .none) return false;
        return true;
    }

    const Stage = enum { attack, decay, sustain, release };

    /// Comb delay line length per channel per slot. Sets the comb model's
    /// lowest reachable fundamental (sample_rate / comb_len) and dominates
    /// Voice's size — keep it modest, PolySynth is embedded by value in Rack.
    const comb_len: usize = 512;

    const FilterCoeffs = struct {
        // zig fmt: off
        // biquad (lp/hp/bp/notch)
        b0: f32 = 1.0, b1: f32 = 0.0, b2: f32 = 0.0,
        a1: f32 = 0.0, a2: f32 = 0.0,
        // ladder: one-pole coefficient + feedback amount (res*4, self-osc at 4)
        g: f32 = 0.0, k: f32 = 0.0,
        // comb: delay in samples (fractional) + feedback amount
        comb_delay: f32 = 2.0, comb_fb: f32 = 0.0,
        // zig fmt: on
    };

    /// Per-channel state for one filter slot, covering every filter model:
    /// biquad history, the ladder's 4 one-pole stages, and the comb's delay
    /// ring. Only the active model's fields advance; switching models
    /// mid-note picks up whatever stale state the new model left behind,
    /// which decays within a few hundred samples.
    const FilterState = struct {
        // zig fmt: off
        x1: f32 = 0.0, x2: f32 = 0.0,
        y1: f32 = 0.0, y2: f32 = 0.0,
        s1: f32 = 0.0, s2: f32 = 0.0,
        s3: f32 = 0.0, s4: f32 = 0.0,
        // zig fmt: on
        comb: [comb_len]f32 = [_]f32{0.0} ** comb_len,
        comb_pos: usize = 0,
    };

    const Voice = struct {
        // zig fmt: off
        active: bool = false,
        note:   u7   = 0,
        velocity: f32 = 0.0,
        /// Phase accumulators for OSC A and OSC B unison voices.
        phases:   [max_unison]f32 = [_]f32{0.0} ** max_unison,
        phases_b: [max_unison]f32 = [_]f32{0.0} ** max_unison,
        phases_c: [max_unison]f32 = [_]f32{0.0} ** max_unison,
        // Amplitude envelope
        env:   f32   = 0.0,
        stage: Stage = .attack,
        // Filter envelope
        env2:   f32   = 0.0,
        stage2: Stage = .attack,
        // zig fmt: on
        /// Filter state per slot per channel (same coefficients L/R,
        /// independent histories). Filter 2 keeps its own state even in
        /// series mode, since it filters filter 1's output.
        f1_l: FilterState = .{},
        f1_r: FilterState = .{},
        f2_l: FilterState = .{},
        f2_r: FilterState = .{},
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
        // zig fmt: off
        .event   = eventOpaque,
        .reset   = resetOpaque,
        // zig fmt: on
    };

    pub fn noteToFreq(note: u7) f32 {
        return midi.noteToFreq(note);
    }

    /// A full synth patch: every parameter `adjustParam`/`applyCC` can touch,
    /// minus per-instance state (sample_rate, voices, held-note stack, pitch
    /// bend, LFO phase). Presets in `synth_presets.zig` are just values of
    /// this type — no audio is rendered or embedded to define one.
    pub const Patch = struct {
        waveform: Waveform = .saw,
        pulse_width: f32 = 0.5,
        detune_cents: f32 = 0.0,
        unison: u8 = 1,
        unison_detune: f32 = 15.0,
        unison_spread: f32 = 0.0,
        unison_mode: UnisonMode = .spread,
        warp_mode: WarpMode = .none,
        warp_amount: f32 = 0.0,

        osc_b_on: bool = false,
        osc_b_waveform: Waveform = .saw,
        osc_b_pulse_width: f32 = 0.5,
        osc_b_semi: f32 = 0.0,
        osc_b_detune_cents: f32 = 0.0,
        osc_b_level: f32 = 1.0,
        osc_b_unison: u8 = 1,
        osc_b_unison_detune: f32 = 15.0,
        osc_b_unison_mode: UnisonMode = .spread,
        osc_b_warp_mode: WarpMode = .none,
        osc_b_warp_amount: f32 = 0.0,

        osc_c_on: bool = false,
        osc_c_waveform: Waveform = .saw,
        osc_c_pulse_width: f32 = 0.5,
        osc_c_semi: f32 = 0.0,
        osc_c_detune_cents: f32 = 0.0,
        osc_c_level: f32 = 1.0,
        osc_c_unison: u8 = 1,
        osc_c_unison_detune: f32 = 15.0,
        osc_c_unison_mode: UnisonMode = .spread,

        attack_s: f32 = 0.005,
        decay_s: f32 = 0.08,
        sustain: f32 = 0.7,
        release_s: f32 = 0.25,

        filter_type: FilterType = .lp,
        filter_cutoff: f32 = 18_000.0,
        filter_res: f32 = 0.0,

        filter2_on: bool = false,
        filter2_type: FilterType = .lp,
        filter2_cutoff: f32 = 18_000.0,
        filter2_res: f32 = 0.0,
        filter_routing: FilterRouting = .series,

        fenv_attack_s: f32 = 0.005,
        fenv_decay_s: f32 = 0.5,
        fenv_sustain: f32 = 0.0,
        fenv_release_s: f32 = 0.3,

        lfo_shape: LfoShape = .sine,
        lfo_rate_hz: f32 = 1.0,

        lfo2_shape: LfoShape = .sine,
        lfo2_rate_hz: f32 = 1.0,
        lfo3_shape: LfoShape = .sine,
        lfo3_rate_hz: f32 = 1.0,

        macro1: f32 = 0.0,
        macro2: f32 = 0.0,
        macro3: f32 = 0.0,
        macro4: f32 = 0.0,

        mod_matrix: [max_mod_rows]ModRow = [_]ModRow{.{}} ** max_mod_rows,

        /// Legacy fixed mod routes, kept as load-only carriers so pre-matrix
        /// presets (factory and user JSON alike) still apply: `applyPatch`
        /// folds them into matrix rows when `mod_matrix` is empty. Not
        /// fields on PolySynth anymore; `toPatch` leaves them at defaults.
        fenv_amount: f32 = 0.0,
        lfo_depth: f32 = 0.0,
        lfo_target: LfoTarget = .none,

        voice_mode: VoiceMode = .poly,
        glide_s: f32 = 0.0,

        sub_level: f32 = 0.0,
        sub_shape: SubShape = .sine,

        noise_level: f32 = 0.0,
        noise_color: f32 = 1.0,

        mod_mode: ModMode = .none,
        mod_amount: f32 = 0.0,

        gain: f32 = 0.35,

        fx_dist_on: bool = false,
        fx_dist_drive_db: f32 = 12.0,
        fx_dist_mix: f32 = 1.0,
        fx_crush_on: bool = false,
        fx_crush_bits: f32 = 8.0,
        fx_crush_rate: f32 = 4.0,
        fx_crush_mix: f32 = 1.0,
        fx_flanger_on: bool = false,
        fx_flanger_rate_hz: f32 = 0.3,
        fx_flanger_depth: f32 = 0.7,
        fx_flanger_feedback: f32 = 0.5,
        fx_flanger_mix: f32 = 0.5,
    };

    /// Load a patch onto this synth. Field-by-field so per-instance state
    /// (sample_rate, voices, glide/held-note tracking) is untouched — notes
    /// already sounding pick up the new params on their next block, same as
    /// a single `adjustParam` nudge. Patch fields without a PolySynth
    /// counterpart are the legacy mod-route carriers, folded into matrix
    /// rows below instead of copied.
    pub fn applyPatch(self: *PolySynth, patch: Patch) void {
        inline for (@typeInfo(Patch).@"struct".fields) |f| {
            if (@hasField(PolySynth, f.name)) {
                @field(self, f.name) = @field(patch, f.name);
            }
        }
        if (matrixEmpty(patch.mod_matrix)) {
            const rows = legacyModRows(patch.fenv_amount, patch.lfo_depth, patch.lfo_target);
            self.mod_matrix[0] = rows[0];
            self.mod_matrix[1] = rows[1];
        }
    }

    /// The inverse of `applyPatch`: snapshot this synth's current params into
    /// a `Patch` (e.g. to save a hand-tuned sound as a reusable preset — see
    /// `tui/user_presets.zig`). The legacy carrier fields stay at their
    /// defaults, so a round-trip never re-triggers migration.
    pub fn toPatch(self: *const PolySynth) Patch {
        var patch: Patch = .{};
        inline for (@typeInfo(Patch).@"struct".fields) |f| {
            if (@hasField(PolySynth, f.name)) {
                @field(patch, f.name) = @field(self, f.name);
            }
        }
        return patch;
    }

    pub fn noteOn(self: *PolySynth, note: u7, velocity: f32) void {
        switch (self.voice_mode) {
            // zig fmt: off
            .poly   => self.noteOnPoly(note, velocity),
            .mono   => { self.pushHeld(note, velocity); self.noteOnMono(note, velocity, true); },
            // zig fmt: on
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
                        // zig fmt: off
                        v.stage  = .release;
                        // zig fmt: on
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
                    // zig fmt: off
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
        self.newest_voice = self.allocVoice();
        const v = &self.voices[self.newest_voice];
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
        self.newest_voice = 0;
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
                // zig fmt: on
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
                // zig fmt: off
                v.glide_rate     = 0.0;
                // zig fmt: on
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
            // zig fmt: off
            self.held_notes[self.held_count]      = note;
            // zig fmt: on
            self.held_velocities[self.held_count] = velocity;
            self.held_count += 1;
        }
    }

    fn popHeld(self: *PolySynth, note: u7) void {
        for (0..self.held_count) |i| {
            if (self.held_notes[i] == note) {
                self.held_count -= 1;
                for (i..self.held_count) |j| {
                    // zig fmt: off
                    self.held_notes[j]      = self.held_notes[j + 1];
                    // zig fmt: on
                    self.held_velocities[j] = self.held_velocities[j + 1];
                }
                return;
            }
        }
    }

    fn allocVoice(self: *PolySynth) u8 {
        var quietest: u8 = 0;
        for (self.voices, 0..) |v, i| {
            if (!v.active) return @intCast(i);
            if (v.env < self.voices[quietest].env) quietest = @intCast(i);
        }
        return quietest;
    }

    /// Summed matrix modulation per destination for one voice/block:
    /// `amts[i]` = Σ depth×source over the rows targeting `dests[i]`.
    const ModAccum = struct {
        dests: [max_mod_rows]u8 = undefined,
        amts: [max_mod_rows]f32 = undefined,
        count: u8 = 0,

        fn amt(self: *const ModAccum, dest: u8) f32 {
            for (self.dests[0..self.count], self.amts[0..self.count]) |d, a| {
                if (d == dest) return a;
            }
            return 0.0;
        }
    };

    /// Evaluate every active matrix row for one voice at block rate.
    /// `v` is null for the global FX evaluation when no voice is active:
    /// the per-voice sources read as silence, the global ones still run.
    fn evalMatrix(self: *const PolySynth, v: ?*const Voice, lfo_vals: [3]f32) ModAccum {
        var acc: ModAccum = .{};
        for (self.mod_matrix) |row| {
            if (row.source == .none or row.depth == 0.0) continue;
            const src: f32 = switch (row.source) {
                // zig fmt: off
                .none     => unreachable,
                .lfo      => lfo_vals[0],
                .lfo2     => lfo_vals[1],
                .lfo3     => lfo_vals[2],
                .fenv     => if (v) |vv| vv.env2 else 0.0,
                .aenv     => if (v) |vv| vv.env else 0.0,
                .velocity => if (v) |vv| vv.velocity else 0.0,
                .keytrack => if (v) |vv| (@as(f32, @floatFromInt(vv.note)) - 60.0) / 64.0 else 0.0,
                .wheel    => self.mod_wheel,
                .mac1     => self.macro1,
                .mac2     => self.macro2,
                .mac3     => self.macro3,
                .mac4     => self.macro4,
                // zig fmt: on
            };
            const a = row.depth * src;
            for (acc.dests[0..acc.count], 0..) |d, i| {
                if (d == row.dest) {
                    acc.amts[i] += a;
                    break;
                }
            } else {
                acc.dests[acc.count] = row.dest;
                acc.amts[acc.count] = a;
                acc.count += 1;
            }
        }
        return acc;
    }

    /// `base` (a param's live value) shifted by the voice's matrix amount
    /// for that param, scaled to the param's full range and clamped to it.
    /// Cutoffs and the virtual pitch/amp dests are NOT routed through here —
    /// they modulate in octave/gain space at their use sites instead.
    fn eff(acc: *const ModAccum, id: u8, base: f32) f32 {
        const a = acc.amt(id);
        if (a == 0.0) return base;
        const p = findAutomatableParam(id) orelse return base;
        return std.math.clamp(base + a * (p.range[1] - p.range[0]), p.range[0], p.range[1]);
    }

    /// `eff` for the integer unison-count params, rounded back to a count.
    fn effUnison(acc: *const ModAccum, id: u8, base: u8) usize {
        const e = eff(acc, id, @floatFromInt(@max(base, 1)));
        return @intFromFloat(@round(std.math.clamp(e, 1.0, @as(f32, max_unison))));
    }

    pub fn processBlock(self: *PolySynth, buf: []Sample) void {
        const frames = buf.len / 2;

        // Block-rate LFOs: sample once before the voice loop so all voices
        // receive the same values, avoiding inter-voice phase desync.
        const lfo_vals = [3]f32{
            self.lfoVal(0, self.lfo_shape, self.lfo_phase),
            self.lfoVal(1, self.lfo2_shape, self.lfo2_phase),
            self.lfoVal(2, self.lfo3_shape, self.lfo3_phase),
        };

        // zig fmt: off
        // osc_budget: split evenly between active oscillators so total ≤ 32.
        var active_count: usize = 0;
        for (self.voices) |v| if (v.active) { active_count += 1; };
        const osc_count: usize = 1 + @as(usize, if (self.osc_b_on) 1 else 0)
                                   + @as(usize, if (self.osc_c_on) 1 else 0);
        const per_osc_cap: usize = if (active_count > 0)
            @max(osc_budget / active_count / osc_count, 1)
        else max_unison;

        for (&self.voices) |*v| {
            if (!v.active) continue;

            // All matrix modulation below is block-rate per voice — the
            // same rate the retired fixed routes always ran at.
            const mods = self.evalMatrix(v, lfo_vals);

            // Envelope increments are per voice (not hoisted) so matrix
            // rows can modulate times/sustains, e.g. velocity → decay.
            // zig fmt: off
            const sustain_v      = eff(&mods, 18, self.sustain);
            const attack_inc     = 1.0 / @max(eff(&mods, 16, self.attack_s)  * self.sample_rate, 1.0);
            const decay_inc      = (1.0 - sustain_v) / @max(eff(&mods, 17, self.decay_s) * self.sample_rate, 1.0);
            const release_inc    = 1.0 / @max(eff(&mods, 19, self.release_s) * self.sample_rate, 1.0);

            const fenv_sustain_v   = eff(&mods, 26, self.fenv_sustain);
            const fenv_attack_inc  = 1.0 / @max(eff(&mods, 24, self.fenv_attack_s)  * self.sample_rate, 1.0);
            const fenv_decay_inc   = (1.0 - fenv_sustain_v) / @max(eff(&mods, 25, self.fenv_decay_s) * self.sample_rate, 1.0);
            const fenv_release_inc = 1.0 / @max(eff(&mods, 27, self.fenv_release_s) * self.sample_rate, 1.0);
            // zig fmt: on

            // Glide: advance current log-freq toward target at block rate.
            const target_log = std.math.log2(noteToFreq(v.note));
            if (eff(&mods, 33, self.glide_s) > 0.0 and v.glide_rate != 0.0) {
                v.glide_log_freq += v.glide_rate * @as(f32, @floatFromInt(frames));
                // zig fmt: off
                const overshot = (v.glide_rate > 0.0 and v.glide_log_freq >= target_log) or
                                 (v.glide_rate < 0.0 and v.glide_log_freq <= target_log);
                if (overshot) { v.glide_log_freq = target_log; v.glide_rate = 0.0; }
            } else {
                v.glide_log_freq = target_log;
                v.glide_rate     = 0.0;
            }

            // Cutoff = base × 2^(4 × matrix amount): a full-depth row spans
            // ±4 octaves (what the retired fenv_amount spanned at ±4).
            const effective_cutoff = std.math.clamp(
                self.filter_cutoff * std.math.pow(f32, 2.0, 4.0 * mods.amt(21)),
                20.0, self.sample_rate * 0.49,
            );
            const fc = self.computeFilterCoeffs(effective_cutoff, self.filter_type, eff(&mods, 22, self.filter_res));

            // Filter 2: own cutoff/res dests (47/48), same octave scale.
            // Computed unconditionally (cheap) so there's no
            // uninitialized-coeffs case to guard.
            const effective_cutoff2 = std.math.clamp(
                self.filter2_cutoff * std.math.pow(f32, 2.0, 4.0 * mods.amt(47)),
                20.0, self.sample_rate * 0.49,
            );
            const fc2 = self.computeFilterCoeffs(effective_cutoff2, self.filter2_type, eff(&mods, 48, self.filter2_res));

            // Pitch: the virtual dest is in octaves. Glide is log-freq space.
            const base_freq = std.math.pow(f32, 2.0,
                v.glide_log_freq + eff(&mods, 2, self.detune_cents) / 1200.0 + mods.amt(dest_pitch) +
                self.pitch_bend_semitones / 12.0);

            // Amp: virtual dest is a gain factor about unity (tremolo when
            // fed by the LFO, swells from envelopes/wheel).
            const amp_mod: f32 = std.math.clamp(1.0 + mods.amt(dest_amp), 0.0, 2.0);

            const n_a: usize = @min(@min(effUnison(&mods, 3, self.unison), max_unison), per_osc_cap);
            const n_b: usize = if (self.osc_b_on)
                @min(@min(effUnison(&mods, 12, self.osc_b_unison), max_unison), per_osc_cap)
            else 0;
            const n_c: usize = if (self.osc_c_on)
                @min(@min(effUnison(&mods, 56, self.osc_c_unison), max_unison), per_osc_cap)
            else 0;
            // zig fmt: on

            // Per-voice effective values for params consumed inside the
            // per-sample loop (hoisted once per block).
            // zig fmt: off
            const pw_a         = eff(&mods, 1,  self.pulse_width);
            const pw_b         = eff(&mods, 8,  self.osc_b_pulse_width);
            const pw_c         = eff(&mods, 52, self.osc_c_pulse_width);
            const warp_amt_a   = eff(&mods, 42, self.warp_amount);
            const warp_amt_b   = eff(&mods, 44, self.osc_b_warp_amount);
            const mod_amount_v = eff(&mods, 15, self.mod_amount);
            const b_level      = eff(&mods, 11, self.osc_b_level);
            const c_level      = eff(&mods, 55, self.osc_c_level);
            const sub_level_v  = eff(&mods, 34, self.sub_level);
            const noise_lvl_v  = eff(&mods, 36, self.noise_level);
            const gain_v       = eff(&mods, 38, self.gain);
            // zig fmt: on

            // Precompute per-unison phase increments for OSC A.
            const uni_det_a = eff(&mods, 4, self.unison_detune);
            var phase_incs_a: [max_unison]f32 = undefined;
            for (0..n_a) |ui| {
                const spread: f32 = if (n_a > 1) unisonSpreadCents(self.unison_mode, ui, n_a, uni_det_a) else 0.0;
                phase_incs_a[ui] = base_freq * std.math.pow(f32, 2.0, spread / 1200.0) / self.sample_rate;
            }

            // Precompute per-unison phase increments for OSC B.
            var phase_incs_b: [max_unison]f32 = undefined;
            if (self.osc_b_on) {
                // zig fmt: off
                const b_freq = base_freq * std.math.pow(f32, 2.0,
                    eff(&mods, 9, self.osc_b_semi) / 12.0 + eff(&mods, 10, self.osc_b_detune_cents) / 1200.0);
                    // zig fmt: on
                const uni_det_b = eff(&mods, 13, self.osc_b_unison_detune);
                for (0..n_b) |ui| {
                    const spread: f32 = if (n_b > 1) unisonSpreadCents(self.osc_b_unison_mode, ui, n_b, uni_det_b) else 0.0;
                    phase_incs_b[ui] = b_freq * std.math.pow(f32, 2.0, spread / 1200.0) / self.sample_rate;
                }
            }

            // Precompute per-unison phase increments for OSC C.
            var phase_incs_c: [max_unison]f32 = undefined;
            if (self.osc_c_on) {
                // zig fmt: off
                const c_freq = base_freq * std.math.pow(f32, 2.0,
                    eff(&mods, 53, self.osc_c_semi) / 12.0 + eff(&mods, 54, self.osc_c_detune_cents) / 1200.0);
                    // zig fmt: on
                const uni_det_c = eff(&mods, 57, self.osc_c_unison_detune);
                for (0..n_c) |ui| {
                    const spread: f32 = if (n_c > 1) unisonSpreadCents(self.osc_c_unison_mode, ui, n_c, uni_det_c) else 0.0;
                    phase_incs_c[ui] = c_freq * std.math.pow(f32, 2.0, spread / 1200.0) / self.sample_rate;
                }
            }

            // Per-voice sub phase increment (half-frequency = one octave below).
            const sub_phase_inc = base_freq * 0.5 / self.sample_rate;

            // Noise color: one-pole LP pole coefficient. color=1 → white, color=0 → dark.
            const noise_lp_a = (1.0 - eff(&mods, 37, self.noise_color)) * 0.99;

            // Power-preserving normalisation across all sources.
            const scale_a = 1.0 / @sqrt(@as(f32, @floatFromInt(n_a)));
            const scale_b = if (n_b > 0) 1.0 / @sqrt(@as(f32, @floatFromInt(n_b))) else 0.0;
            const scale_c = if (n_c > 0) 1.0 / @sqrt(@as(f32, @floatFromInt(n_c))) else 0.0;
            // zig fmt: off
            const b_pow   = b_level * b_level * @as(f32, if (self.osc_b_on) 1.0 else 0.0);
            const c_pow   = c_level * c_level * @as(f32, if (self.osc_c_on) 1.0 else 0.0);
            const mix_norm = 1.0 / @sqrt(1.0 + b_pow + c_pow
                + sub_level_v * sub_level_v
                + noise_lvl_v * noise_lvl_v);
            // ring_mix_norm: B acts as modulator only, so exclude b_pow. C is
            // a plain additive voice regardless of mod_mode, so it's included.
            const ring_mix_norm = 1.0 / @sqrt(1.0 + c_pow
                + sub_level_v * sub_level_v
                + noise_lvl_v * noise_lvl_v);

            // Stereo pan gains per unison voice — constant-power, √2-compensated so
            // spread=0 gives the same per-channel amplitude as the original mono path.
            const uni_spread = eff(&mods, 5, self.unison_spread);
            const pan_scale = std.math.sqrt2;
            var pan_l_a: [max_unison]f32 = undefined;
            var pan_r_a: [max_unison]f32 = undefined;
            for (0..n_a) |ui| {
                const raw: f32 = if (n_a > 1 and uni_spread > 0.0)
                    ((@as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(n_a - 1))) * 2.0 - 1.0)
                    * uni_spread
                else 0.0;
                const angle = (raw + 1.0) * std.math.pi * 0.25;
                pan_l_a[ui] = pan_scale * @cos(angle);
                pan_r_a[ui] = pan_scale * @sin(angle);
            }
            var pan_l_b: [max_unison]f32 = undefined;
            var pan_r_b: [max_unison]f32 = undefined;
            if (self.osc_b_on) {
                for (0..n_b) |ui| {
                    const raw: f32 = if (n_b > 1 and uni_spread > 0.0)
                        ((@as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(n_b - 1))) * 2.0 - 1.0)
                        * uni_spread
                    else 0.0;
                    // zig fmt: on
                    const angle = (raw + 1.0) * std.math.pi * 0.25;
                    pan_l_b[ui] = pan_scale * @cos(angle);
                    pan_r_b[ui] = pan_scale * @sin(angle);
                }
            }
            var pan_l_c: [max_unison]f32 = undefined;
            var pan_r_c: [max_unison]f32 = undefined;
            if (self.osc_c_on) {
                for (0..n_c) |ui| {
                    const raw: f32 = if (n_c > 1 and uni_spread > 0.0)
                        ((@as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(n_c - 1))) * 2.0 - 1.0) * uni_spread
                    else
                        0.0;
                    const angle = (raw + 1.0) * std.math.pi * 0.25;
                    pan_l_c[ui] = pan_scale * @cos(angle);
                    pan_r_c[ui] = pan_scale * @sin(angle);
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
                        const samp = self.oscSampleB(v.phases_b[ui], pw_b, warp_amt_b);
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
                    const samp = self.oscSampleA(v.phases[ui], pw_a, warp_amt_a);
                    a_l += samp * pan_l_a[ui];
                    a_r += samp * pan_r_a[ui];
                    a_mono += samp;
                    const inc: f32 = if (self.mod_mode == .fm_b_to_a)
                        phase_incs_a[ui] * (1.0 + mod_amount_v * b_mono)
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
                        const samp = self.oscSampleB(v.phases_b[ui], pw_b, warp_amt_b);
                        b_l += samp * pan_l_b[ui];
                        b_r += samp * pan_r_b[ui];
                        b_mono += samp;
                        // FM A→B: advance B's phase modulated by a_mono.
                        const inc: f32 = if (self.mod_mode == .fm_a_to_b)
                            phase_incs_b[ui] * (1.0 + mod_amount_v * a_mono)
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
                        const g = std.math.clamp((1.0 + mod_amount_v * a_mono) / (1.0 + mod_amount_v), 0.0, 1.0);
                        // zig fmt: off
                        b_l *= g; b_r *= g;
                    },
                    .am_b_to_a => {
                        const g = std.math.clamp((1.0 + mod_amount_v * b_mono) / (1.0 + mod_amount_v), 0.0, 1.0);
                        a_l *= g; a_r *= g;
                    },
                    else => {},
                };

                // OSC C: plain additive voice, no MOD A<->B or warp interaction.
                var c_l: f32 = 0.0;
                var c_r: f32 = 0.0;
                if (self.osc_c_on) {
                    for (0..n_c) |ui| {
                        const samp = oscWave(self.osc_c_waveform, v.phases_c[ui], pw_c);
                        c_l += samp * pan_l_c[ui];
                        c_r += samp * pan_r_c[ui];
                        v.phases_c[ui] += phase_incs_c[ui];
                        if (v.phases_c[ui] >= 1.0) v.phases_c[ui] -= 1.0;
                    }
                }

                // Sub: always centre (mono → both channels).
                var sub_out: f32 = 0.0;
                if (sub_level_v > 0.0) {
                    sub_out = (switch (self.sub_shape) {
                        .sine   => @sin(2.0 * std.math.pi * v.sub_phase),
                        // zig fmt: on
                        .square => if (v.sub_phase < 0.5) @as(f32, 1.0) else @as(f32, -1.0),
                    }) * sub_level_v;
                    v.sub_phase += sub_phase_inc;
                    if (v.sub_phase >= 1.0) v.sub_phase -= 1.0;
                }

                // Noise: always centre.
                var nse_out: f32 = 0.0;
                if (noise_lvl_v > 0.0) {
                    const raw = nextNoise(&v.noise_rand_state);
                    v.noise_lp = (1.0 - noise_lp_a) * raw + noise_lp_a * v.noise_lp;
                    nse_out = v.noise_lp * noise_lvl_v;
                }

                // Stereo mix.
                // Ring: dry↔ring crossfade — depth=0 → A unmodulated; depth=1 → A·b_mono.
                // Formula: (1-d) + d·b_mono stays in [-1,1] for d∈[0,1], b_mono∈[-1,1].
                // FM/AM/none: standard A + B mix (B contribution already modulated above).
                const ring_factor: f32 = if (self.osc_b_on and self.mod_mode == .ring) blk: {
                    const depth = std.math.clamp(mod_amount_v, 0.0, 1.0);
                    break :blk (1.0 - depth) + depth * b_mono;
                } else 0.0;
                const osc_l: f32 = if (self.osc_b_on and self.mod_mode == .ring)
                    (a_l * scale_a * ring_factor + c_l * scale_c * c_level + sub_out + nse_out) * ring_mix_norm
                else
                    (a_l * scale_a + b_l * scale_b * b_level + c_l * scale_c * c_level + sub_out + nse_out) * mix_norm;
                const osc_r: f32 = if (self.osc_b_on and self.mod_mode == .ring)
                    (a_r * scale_a * ring_factor + c_r * scale_c * c_level + sub_out + nse_out) * ring_mix_norm
                else
                    (a_r * scale_a + b_r * scale_b * b_level + c_r * scale_c * c_level + sub_out + nse_out) * mix_norm;

                // Stereo filter: same coefficients, independent L/R histories.
                // zig fmt: off
                const filt1_l = filterSample(self.filter_type, fc, &v.f1_l, osc_l);
                const filt1_r = filterSample(self.filter_type, fc, &v.f1_r, osc_r);

                // Filter 2: series chains off filter 1's output; parallel
                // filters the same dry mix and blends with filter 1's output.
                // Both collapse to filter 1 alone when filter2_on is false.
                var filt_l = filt1_l;
                var filt_r = filt1_r;
                if (self.filter2_on) {
                    const in2_l = if (self.filter_routing == .series) filt1_l else osc_l;
                    const in2_r = if (self.filter_routing == .series) filt1_r else osc_r;

                    const filt2_l = filterSample(self.filter2_type, fc2, &v.f2_l, in2_l);
                    const filt2_r = filterSample(self.filter2_type, fc2, &v.f2_r, in2_r);

                    filt_l = if (self.filter_routing == .series) filt2_l else (filt1_l + filt2_l) * 0.5;
                    filt_r = if (self.filter_routing == .series) filt2_r else (filt1_r + filt2_r) * 0.5;
                }

                const sg = v.env * v.velocity * gain_v * amp_mod;
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
                        if (v.env <= sustain_v) { v.env = sustain_v; v.stage = .sustain; }
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
                        if (v.env2 <= fenv_sustain_v) { v.env2 = fenv_sustain_v; v.stage2 = .sustain; }
                        // zig fmt: on
                    },
                    .sustain => {},
                    .release => {
                        v.env2 -= fenv_release_inc;
                        if (v.env2 < 0.0) v.env2 = 0.0;
                    },
                }
            }
        }

        // ── Internal FX (post-mix, fixed order dist → crush → flanger) ──
        // One global matrix evaluation per block: FX params are shared by
        // all voices, so the per-voice sources read from the most recently
        // triggered voice (env/velocity → drive style routes still play).
        if (self.fx_dist_on or self.fx_crush_on or self.fx_flanger_on) {
            const nv = &self.voices[self.newest_voice];
            const mods = self.evalMatrix(if (nv.active) nv else null, lfo_vals);
            if (self.fx_dist_on) {
                // Stateless, so a per-block value with the effective params
                // is all it takes (out_db stays at its 0 dB default).
                var sat = Saturator{
                    .drive_db = eff(&mods, 84, self.fx_dist_drive_db),
                    .mix = eff(&mods, 85, self.fx_dist_mix),
                };
                sat.processBlock(buf);
            }
            if (self.fx_crush_on) {
                // zig fmt: off
                self.fx_crush_state.bits       = eff(&mods, 87, self.fx_crush_bits);
                self.fx_crush_state.downsample = eff(&mods, 88, self.fx_crush_rate);
                self.fx_crush_state.mix        = eff(&mods, 89, self.fx_crush_mix);
                // zig fmt: on
                self.fx_crush_state.processBlock(buf);
            }
            if (self.fx_flanger_on) {
                self.fx_flanger_state.processBlock(
                    buf,
                    self.sample_rate,
                    eff(&mods, 91, self.fx_flanger_rate_hz),
                    eff(&mods, 92, self.fx_flanger_depth),
                    eff(&mods, 93, self.fx_flanger_feedback),
                    eff(&mods, 94, self.fx_flanger_mix),
                );
            }
        }

        // Advance the LFOs once per block after all voices are done.
        const frames_f: f32 = @floatFromInt(frames);
        self.advanceLfo(0, &self.lfo_phase, self.lfo_rate_hz, frames_f);
        self.advanceLfo(1, &self.lfo2_phase, self.lfo2_rate_hz, frames_f);
        self.advanceLfo(2, &self.lfo3_phase, self.lfo3_rate_hz, frames_f);
    }

    /// Block-rate value of the LFO in `slot`: the held random level for
    /// sample & hold, a pure function of phase for every other shape.
    fn lfoVal(self: *const PolySynth, slot: usize, shape: LfoShape, phase: f32) f32 {
        return if (shape == .sh) self.lfo_sh[slot] else lfoSample(shape, phase);
    }

    /// Advance one LFO's phase by a block; a wrap redraws the slot's sample
    /// & hold level (cheap enough to do regardless of the active shape).
    fn advanceLfo(self: *PolySynth, slot: usize, phase: *f32, rate_hz: f32, frames: f32) void {
        phase.* += rate_hz * frames / self.sample_rate;
        if (phase.* >= 1.0) self.lfo_sh[slot] = nextNoise(&self.lfo_sh_rand);
        phase.* -= @floor(phase.*);
    }

    /// Cents offset of unison voice `ui` of `n` (n > 1), per `mode`.
    /// spread: symmetric, total width across the outermost voices = `detune`.
    /// step: each voice offset by a full `detune`-cent step from its neighbor.
    /// harmonic/ratio: voice ui aims at the (ui+1)-th entry of the integer /
    /// half-integer harmonic series, scaled by `detune`/100 so the knob morphs
    /// from plain unison (0) to the exact series (100). Voice 0 always stays
    /// on the fundamental.
    fn unisonSpreadCents(mode: UnisonMode, ui: usize, n: usize, detune: f32) f32 {
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

    /// `filter_type`/`res` are passed explicitly (not read off `self`) so the
    /// same coefficient math serves both filter slots.
    fn computeFilterCoeffs(self: *const PolySynth, cutoff: f32, filter_type: FilterType, res: f32) FilterCoeffs {
        const q = 0.5 + res * 19.5;
        const c = std.math.clamp(cutoff, 20.0, self.sample_rate * 0.49);
        const w0 = 2.0 * std.math.pi * c / self.sample_rate;
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * q);
        const a0_inv = 1.0 / (1.0 + alpha);
        const neg2cos = -2.0 * cos_w0;

        return switch (filter_type) {
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
            .ladder => .{
                .g = 1.0 - @exp(-w0),
                .k = res * 4.0,
            },
            .comb => .{
                .comb_delay = std.math.clamp(self.sample_rate / c, 2.0, @as(f32, @floatFromInt(comb_len)) - 2.0),
                .comb_fb = res * 0.9,
            },
        };
    }

    /// One sample through one filter slot/channel, dispatching on the
    /// slot's model. Static (no self): everything cutoff/res-dependent
    /// lives in the per-block `FilterCoeffs`.
    fn filterSample(ft: FilterType, fc: FilterCoeffs, st: *FilterState, x: f32) f32 {
        switch (ft) {
            .lp, .hp, .bp, .notch => {
                // zig fmt: off
                const y = fc.b0 * x + fc.b1 * st.x1 + fc.b2 * st.x2 - fc.a1 * st.y1 - fc.a2 * st.y2;
                st.x2 = st.x1; st.x1 = x; st.y2 = st.y1; st.y1 = y;
                // zig fmt: on
                return y;
            },
            .ladder => {
                // tanh on the feedback-summed input bounds the loop, so
                // full resonance self-oscillates instead of blowing up.
                const in_sat = std.math.tanh(x - fc.k * st.s4);
                st.s1 += fc.g * (in_sat - st.s1);
                st.s2 += fc.g * (st.s1 - st.s2);
                st.s3 += fc.g * (st.s2 - st.s3);
                st.s4 += fc.g * (st.s3 - st.s4);
                return st.s4;
            },
            .comb => {
                // Fractional read `comb_delay` samples behind the write
                // head (linear interp) so cutoff sweeps stay smooth.
                var rp = @as(f32, @floatFromInt(st.comb_pos)) - fc.comb_delay;
                if (rp < 0.0) rp += @floatFromInt(comb_len);
                const idx: usize = @intFromFloat(rp);
                const frac = rp - @floor(rp);
                const idx_next = (idx + 1) % comb_len;
                const delayed = st.comb[idx] * (1.0 - frac) + st.comb[idx_next] * frac;
                const y = x + fc.comb_fb * delayed;
                st.comb[st.comb_pos] = y;
                st.comb_pos = (st.comb_pos + 1) % comb_len;
                return y;
            },
        }
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
            // zig fmt: off
            .sine     => @sin(2.0 * std.math.pi * phase),
            .triangle => 1.0 - 4.0 * @abs(phase - 0.5),
            .saw      => 2.0 * phase - 1.0,
            .square   => if (phase < 0.5) 1.0 else -1.0,
            // Held level lives on PolySynth.lfo_sh; callers go through
            // lfoVal, which never reaches here for .sh.
            .sh       => 0.0,
            // zig fmt: on
        };
    }

    /// Editor h/l stepping for the three LFO shape params (28/95/97).
    fn cycleLfoShape(shape: LfoShape, steps: i32) LfoShape {
        // zig fmt: off
        return if (steps > 0) switch (shape) {
            .sine => .triangle, .triangle => .saw, .saw => .square, .square => .sh, .sh => .sine,
        } else switch (shape) {
            .sine => .sh, .triangle => .sine, .saw => .triangle, .square => .saw, .sh => .square,
        };
        // zig fmt: on
    }

    /// `pw`/`warp_amount` are passed in (not read off `self`) so the caller
    /// can substitute per-voice matrix-modulated values.
    fn oscSampleA(self: *const PolySynth, phase: f32, pw: f32, warp_amount: f32) Sample {
        return oscWave(self.waveform, warpPhase(self.warp_mode, phase, warp_amount), pw);
    }

    fn oscSampleB(self: *const PolySynth, phase: f32, pw: f32, warp_amount: f32) Sample {
        return oscWave(self.osc_b_waveform, warpPhase(self.osc_b_warp_mode, phase, warp_amount), pw);
    }

    /// Remap a 0..1 read phase before waveform lookup. `amount` is 0..1 and
    /// every mode is (near-)identity at 0, so toggling `warp_mode` alone
    /// (before touching amount) never changes the sound.
    fn warpPhase(mode: WarpMode, phase: f32, amount: f32) f32 {
        return switch (mode) {
            .none => phase,
            // Pivot the ramp: one side of the cycle covers more phase than
            // the other, same trick classic phase-distortion synths use.
            .bend => blk: {
                const pivot = 0.5 + amount * 0.49;
                break :blk if (phase < pivot)
                    phase / pivot * 0.5
                else
                    0.5 + (phase - pivot) / (1.0 - pivot) * 0.5;
            },
            // Fold the tail of the cycle back on itself instead of letting
            // it run forward past the pivot.
            .mirror => blk: {
                const pivot = 1.0 - amount * 0.5;
                break :blk if (phase < pivot)
                    phase
                else
                    pivot - (phase - pivot) / (1.0 - pivot) * pivot;
            },
            // Multiply-and-wrap: each sub-cycle restarts at 0 in lockstep
            // with the fundamental, giving a hard-sync-like buzz with no
            // second phase accumulator needed.
            .sync => blk: {
                const p = phase * (1.0 + amount * 7.0);
                break :blk p - @floor(p);
            },
        };
    }

    fn oscWave(wf: Waveform, phase: f32, pw: f32) Sample {
        return switch (wf) {
            // zig fmt: off
            .sine     => @sin(2.0 * std.math.pi * phase),
            .saw      => 2.0 * phase - 1.0,
            .triangle => 1.0 - 4.0 * @abs(phase - 0.5),
            .square   => if (phase < pw) 1.0 else -1.0,
            // zig fmt: on
        };
    }

    pub fn resetAll(self: *PolySynth) void {
        for (&self.voices) |*v| v.* = .{};
        self.held_count = 0;
        self.fx_crush_state = .{};
        self.fx_flanger_state = .{};
    }

    /// Apply a raw MIDI CC. Safe to call on the audio thread (field writes only).
    pub fn applyCC(self: *PolySynth, cc: u7, value: u7) void {
        const v01 = @as(f32, @floatFromInt(value)) / 127.0;
        switch (@as(midi.CC, @enumFromInt(cc))) {
            // zig fmt: off
            .mod_wheel         => self.mod_wheel = v01,
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
            .lfo_depth_cc      => self.mod_wheel    = v01,
            .mod_amount        => self.mod_amount   = v01 * 8.0,
            .filter_res        => self.filter_res    = v01,
            .amp_release       => self.release_s     = v01 * 4.0,
            .amp_attack        => self.attack_s      = v01 * 4.0,
            .filter_cutoff     => self.filter_cutoff = ccCutoff(value),
            .amp_decay         => self.decay_s       = v01 * 4.0,
            .amp_sustain       => self.sustain       = v01,
            .fenv_amount       => {}, // retired: fenv amount lives on matrix rows now
            .fenv_attack       => self.fenv_attack_s  = v01 * 4.0,
            .fenv_decay        => self.fenv_decay_s   = v01 * 4.0,
            .fenv_sustain      => self.fenv_sustain   = v01,
            .fenv_release      => self.fenv_release_s = v01 * 4.0,
            .all_sound_off     => self.resetAll(),
            .all_notes_off     => { for (0..128) |n| self.noteOff(@intCast(n)); },
            .reset_all_ctrls   => {},
            _                  => {},
            // zig fmt: on
        }
    }

    /// Nudge the editor parameter at `id` by `steps` (h/l = ±1, H/L = ±10).
    /// Runs on the audio thread (via the `set_param` event) so it never races
    /// the block reader — the editor sends edits over the command queue rather
    /// than writing these fields directly.
    pub fn adjustParam(self: *PolySynth, id: u8, steps: i32) void {
        const s: f32 = @floatFromInt(steps);
        switch (id) {
            // zig fmt: off
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
                .lp => .hp, .hp => .bp, .bp => .notch, .notch => .ladder, .ladder => .comb, .comb => .lp,
            } else switch (self.filter_type) {
                .lp => .comb, .hp => .lp, .bp => .hp, .notch => .bp, .ladder => .notch, .comb => .ladder,
            },
            // Log-scale cutoff: 1 semitone per step (h/l), ~minor-7th per H/L.
            21 => self.filter_cutoff        = std.math.clamp(
                self.filter_cutoff * std.math.pow(f32, 2.0, s / 12.0), 20.0, 20_000.0),
            22 => self.filter_res           = std.math.clamp(self.filter_res         + s * 0.01,   0.0,    1.0),
            // 23 (fenv amount) retired — absorbed into the mod matrix.
            // FENV (24–27)
            24 => self.fenv_attack_s        = std.math.clamp(self.fenv_attack_s      + s * 0.001, 0.001,   5.0),
            25 => self.fenv_decay_s         = std.math.clamp(self.fenv_decay_s       + s * 0.005, 0.001,   5.0),
            26 => self.fenv_sustain         = std.math.clamp(self.fenv_sustain       + s * 0.01,   0.0,    1.0),
            27 => self.fenv_release_s       = std.math.clamp(self.fenv_release_s     + s * 0.005, 0.001,  10.0),
            // LFO (28–29; 30/31 depth+target retired into the mod matrix)
            28 => self.lfo_shape            = cycleLfoShape(self.lfo_shape, steps),
            29 => self.lfo_rate_hz          = std.math.clamp(self.lfo_rate_hz        + s * 0.1,   0.01,   20.0),
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
            // UNI MODE (39–40)
            39 => self.unison_mode = if (steps > 0) switch (self.unison_mode) {
                .spread => .step, .step => .harmonic, .harmonic => .ratio, .ratio => .spread,
            } else switch (self.unison_mode) {
                .spread => .ratio, .step => .spread, .harmonic => .step, .ratio => .harmonic,
            },
            40 => self.osc_b_unison_mode = if (steps > 0) switch (self.osc_b_unison_mode) {
                .spread => .step, .step => .harmonic, .harmonic => .ratio, .ratio => .spread,
            } else switch (self.osc_b_unison_mode) {
                .spread => .ratio, .step => .spread, .harmonic => .step, .ratio => .harmonic,
            },
            // WARP (41–44)
            41 => self.warp_mode = if (steps > 0) switch (self.warp_mode) {
                .none => .bend, .bend => .mirror, .mirror => .sync, .sync => .none,
            } else switch (self.warp_mode) {
                .none => .sync, .bend => .none, .mirror => .bend, .sync => .mirror,
            },
            42 => self.warp_amount          = std.math.clamp(self.warp_amount        + s * 0.01,   0.0,    1.0),
            43 => self.osc_b_warp_mode = if (steps > 0) switch (self.osc_b_warp_mode) {
                .none => .bend, .bend => .mirror, .mirror => .sync, .sync => .none,
            } else switch (self.osc_b_warp_mode) {
                .none => .sync, .bend => .none, .mirror => .bend, .sync => .mirror,
            },
            44 => self.osc_b_warp_amount    = std.math.clamp(self.osc_b_warp_amount  + s * 0.01,   0.0,    1.0),
            // FILTER 2 (45–49)
            45 => self.filter2_on           = !self.filter2_on,
            46 => self.filter2_type = if (steps > 0) switch (self.filter2_type) {
                .lp => .hp, .hp => .bp, .bp => .notch, .notch => .ladder, .ladder => .comb, .comb => .lp,
            } else switch (self.filter2_type) {
                .lp => .comb, .hp => .lp, .bp => .hp, .notch => .bp, .ladder => .notch, .comb => .ladder,
            },
            47 => self.filter2_cutoff       = std.math.clamp(
                self.filter2_cutoff * std.math.pow(f32, 2.0, s / 12.0), 20.0, 20_000.0),
            48 => self.filter2_res          = std.math.clamp(self.filter2_res        + s * 0.01,   0.0,    1.0),
            49 => self.filter_routing = switch (self.filter_routing) {
                .series => .parallel, .parallel => .series,
            },
            // OSC C (50–58)
            50 => self.osc_c_on = !self.osc_c_on,
            51 => self.osc_c_waveform = if (steps > 0) switch (self.osc_c_waveform) {
                .sine => .saw, .saw => .triangle, .triangle => .square, .square => .sine,
            } else switch (self.osc_c_waveform) {
                .sine => .square, .saw => .sine, .triangle => .saw, .square => .triangle,
            },
            52 => self.osc_c_pulse_width    = std.math.clamp(self.osc_c_pulse_width  + s * 0.01,   0.01,   0.99),
            53 => self.osc_c_semi           = std.math.clamp(self.osc_c_semi         + s * 1.0,  -24.0,   24.0),
            54 => self.osc_c_detune_cents   = std.math.clamp(self.osc_c_detune_cents + s * 1.0, -100.0,  100.0),
            55 => self.osc_c_level          = std.math.clamp(self.osc_c_level        + s * 0.01,   0.0,    1.0),
            56 => self.osc_c_unison         = @intCast(std.math.clamp(@as(i32, self.osc_c_unison) + steps, 1, 16)),
            57 => self.osc_c_unison_detune  = std.math.clamp(self.osc_c_unison_detune + s * 1.0,   0.0,  100.0),
            58 => self.osc_c_unison_mode = if (steps > 0) switch (self.osc_c_unison_mode) {
                .spread => .step, .step => .harmonic, .harmonic => .ratio, .ratio => .spread,
            } else switch (self.osc_c_unison_mode) {
                .spread => .ratio, .step => .spread, .harmonic => .step, .ratio => .harmonic,
            },
            // FX DIST (83–85)
            83 => self.fx_dist_on           = !self.fx_dist_on,
            84 => self.fx_dist_drive_db     = std.math.clamp(self.fx_dist_drive_db     + s * 0.5,    0.0,   36.0),
            85 => self.fx_dist_mix          = std.math.clamp(self.fx_dist_mix          + s * 0.01,   0.0,    1.0),
            // FX CRUSH (86–89)
            86 => self.fx_crush_on          = !self.fx_crush_on,
            87 => self.fx_crush_bits        = std.math.clamp(self.fx_crush_bits        + s * 1.0,    1.0,   16.0),
            88 => self.fx_crush_rate        = std.math.clamp(self.fx_crush_rate        + s * 1.0,    1.0,   64.0),
            89 => self.fx_crush_mix         = std.math.clamp(self.fx_crush_mix         + s * 0.01,   0.0,    1.0),
            // FX FLANGER (90–94)
            90 => self.fx_flanger_on        = !self.fx_flanger_on,
            91 => self.fx_flanger_rate_hz   = std.math.clamp(self.fx_flanger_rate_hz   + s * 0.05,   0.02,   8.0),
            92 => self.fx_flanger_depth     = std.math.clamp(self.fx_flanger_depth     + s * 0.01,   0.0,    1.0),
            93 => self.fx_flanger_feedback  = std.math.clamp(self.fx_flanger_feedback  + s * 0.01,   0.0,    0.95),
            94 => self.fx_flanger_mix       = std.math.clamp(self.fx_flanger_mix       + s * 0.01,   0.0,    1.0),
            // LFO 2 (95–96) / LFO 3 (97–98)
            95 => self.lfo2_shape           = cycleLfoShape(self.lfo2_shape, steps),
            96 => self.lfo2_rate_hz         = std.math.clamp(self.lfo2_rate_hz         + s * 0.1,    0.01,  20.0),
            97 => self.lfo3_shape           = cycleLfoShape(self.lfo3_shape, steps),
            98 => self.lfo3_rate_hz         = std.math.clamp(self.lfo3_rate_hz         + s * 0.1,    0.01,  20.0),
            // MACRO (99–102)
            99  => self.macro1              = std.math.clamp(self.macro1               + s * 0.01,   0.0,    1.0),
            100 => self.macro2              = std.math.clamp(self.macro2               + s * 0.01,   0.0,    1.0),
            101 => self.macro3              = std.math.clamp(self.macro3               + s * 0.01,   0.0,    1.0),
            102 => self.macro4              = std.math.clamp(self.macro4               + s * 0.01,   0.0,    1.0),
            // zig fmt: on
            // MATRIX (59–82): 3 ids per row — source, dest, depth.
            59...82 => {
                const row = &self.mod_matrix[(id - 59) / 3];
                switch ((id - 59) % 3) {
                    // Source steps one variant per press (matches the other
                    // enum params); wraps.
                    0 => {
                        const n: i32 = @typeInfo(ModSource).@"enum".fields.len;
                        const cur: i32 = @intFromEnum(row.source);
                        const dir: i32 = if (steps > 0) 1 else -1;
                        row.source = @enumFromInt(@as(u8, @intCast(@mod(cur + dir, n))));
                    },
                    // Dest walks the mod_dest_ids table by the full step
                    // count (H/L jump 10 through the ~40 entries); wraps.
                    1 => {
                        const n: i32 = mod_dest_ids.len;
                        const cur: i32 = @intCast(modDestIndex(row.dest) orelse 0);
                        row.dest = mod_dest_ids[@intCast(@mod(cur + steps, n))];
                    },
                    2 => row.depth = std.math.clamp(row.depth + s * 0.01, -1.0, 1.0),
                    else => unreachable,
                }
            },
            else => {},
        }
    }

    /// Absolute-value counterpart to `adjustParam`, for automation curves
    /// (which know the value they want at a beat position directly, not a
    /// delta from wherever the param last was — see `Event.set_param_abs`)
    /// and for undo's capture/restore (`paramValue` is the read half).
    /// Every continuous param `adjustParam` handles is wired here with the
    /// exact same clamp range; enum/toggle ids (waveform 0/7, osc_b_on 6,
    /// mod_mode 14, filter_type 20, lfo_shape 28, voice_mode 32, sub_shape
    /// 35, matrix sources) take the variant's 0-based ordinal (toggles:
    /// >= 0.5 is on) — automation never targets them (they're not in
    /// `automatable_params`), only undo restores them this way.
    pub fn setParamAbsolute(self: *PolySynth, id: u8, value: f32) void {
        switch (id) {
            // zig fmt: off
            0  => self.waveform            = enumFromValue(Waveform, value),
            6  => self.osc_b_on            = value >= 0.5,
            7  => self.osc_b_waveform      = enumFromValue(Waveform, value),
            14 => self.mod_mode            = enumFromValue(ModMode, value),
            20 => self.filter_type         = enumFromValue(FilterType, value),
            28 => self.lfo_shape           = enumFromValue(LfoShape, value),
            32 => self.voice_mode          = enumFromValue(VoiceMode, value),
            35 => self.sub_shape           = enumFromValue(SubShape, value),
            39 => self.unison_mode         = enumFromValue(UnisonMode, value),
            40 => self.osc_b_unison_mode   = enumFromValue(UnisonMode, value),
            41 => self.warp_mode           = enumFromValue(WarpMode, value),
            43 => self.osc_b_warp_mode     = enumFromValue(WarpMode, value),
            45 => self.filter2_on          = value >= 0.5,
            46 => self.filter2_type        = enumFromValue(FilterType, value),
            49 => self.filter_routing      = enumFromValue(FilterRouting, value),
            50 => self.osc_c_on            = value >= 0.5,
            51 => self.osc_c_waveform      = enumFromValue(Waveform, value),
            58 => self.osc_c_unison_mode   = enumFromValue(UnisonMode, value),
            1  => self.pulse_width         = std.math.clamp(value,   0.01,   0.99),
            2  => self.detune_cents        = std.math.clamp(value, -100.0, 100.0),
            3  => self.unison              = @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(value))), 1, 16)),
            4  => self.unison_detune       = std.math.clamp(value,   0.0,  100.0),
            5  => self.unison_spread       = std.math.clamp(value,   0.0,    1.0),
            8  => self.osc_b_pulse_width   = std.math.clamp(value,   0.01,   0.99),
            9  => self.osc_b_semi          = std.math.clamp(value, -24.0,   24.0),
            10 => self.osc_b_detune_cents  = std.math.clamp(value, -100.0,  100.0),
            11 => self.osc_b_level         = std.math.clamp(value,   0.0,    1.0),
            12 => self.osc_b_unison        = @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(value))), 1, 16)),
            13 => self.osc_b_unison_detune = std.math.clamp(value,   0.0,  100.0),
            15 => self.mod_amount          = std.math.clamp(value,   0.0,    8.0),
            16 => self.attack_s            = std.math.clamp(value,   0.001,  5.0),
            17 => self.decay_s             = std.math.clamp(value,   0.001,  5.0),
            18 => self.sustain             = std.math.clamp(value,   0.0,    1.0),
            19 => self.release_s           = std.math.clamp(value,   0.001, 10.0),
            21 => self.filter_cutoff       = std.math.clamp(value,  20.0, 20_000.0),
            22 => self.filter_res          = std.math.clamp(value,   0.0,    1.0),
            24 => self.fenv_attack_s       = std.math.clamp(value,   0.001,  5.0),
            25 => self.fenv_decay_s        = std.math.clamp(value,   0.001,  5.0),
            26 => self.fenv_sustain        = std.math.clamp(value,   0.0,    1.0),
            27 => self.fenv_release_s      = std.math.clamp(value,   0.001, 10.0),
            29 => self.lfo_rate_hz         = std.math.clamp(value,   0.01,  20.0),
            33 => self.glide_s             = std.math.clamp(value,   0.0,   10.0),
            34 => self.sub_level           = std.math.clamp(value,   0.0,    1.0),
            36 => self.noise_level         = std.math.clamp(value,   0.0,    1.0),
            37 => self.noise_color         = std.math.clamp(value,   0.0,    1.0),
            38 => self.gain                = std.math.clamp(value,   0.01,   1.0),
            42 => self.warp_amount         = std.math.clamp(value,   0.0,    1.0),
            44 => self.osc_b_warp_amount   = std.math.clamp(value,   0.0,    1.0),
            47 => self.filter2_cutoff      = std.math.clamp(value,  20.0, 20_000.0),
            48 => self.filter2_res         = std.math.clamp(value,   0.0,    1.0),
            52 => self.osc_c_pulse_width   = std.math.clamp(value,   0.01,   0.99),
            53 => self.osc_c_semi          = std.math.clamp(value, -24.0,   24.0),
            54 => self.osc_c_detune_cents  = std.math.clamp(value, -100.0,  100.0),
            55 => self.osc_c_level         = std.math.clamp(value,   0.0,    1.0),
            56 => self.osc_c_unison        = @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(value))), 1, 16)),
            57 => self.osc_c_unison_detune = std.math.clamp(value,   0.0,  100.0),
            83 => self.fx_dist_on          = value >= 0.5,
            84 => self.fx_dist_drive_db    = std.math.clamp(value,   0.0,   36.0),
            85 => self.fx_dist_mix         = std.math.clamp(value,   0.0,    1.0),
            86 => self.fx_crush_on         = value >= 0.5,
            87 => self.fx_crush_bits       = std.math.clamp(value,   1.0,   16.0),
            88 => self.fx_crush_rate       = std.math.clamp(value,   1.0,   64.0),
            89 => self.fx_crush_mix        = std.math.clamp(value,   0.0,    1.0),
            90 => self.fx_flanger_on       = value >= 0.5,
            91 => self.fx_flanger_rate_hz  = std.math.clamp(value,   0.02,   8.0),
            92 => self.fx_flanger_depth    = std.math.clamp(value,   0.0,    1.0),
            93 => self.fx_flanger_feedback = std.math.clamp(value,   0.0,    0.95),
            94 => self.fx_flanger_mix      = std.math.clamp(value,   0.0,    1.0),
            95 => self.lfo2_shape          = enumFromValue(LfoShape, value),
            96 => self.lfo2_rate_hz        = std.math.clamp(value,   0.01,  20.0),
            97 => self.lfo3_shape          = enumFromValue(LfoShape, value),
            98 => self.lfo3_rate_hz        = std.math.clamp(value,   0.01,  20.0),
            99  => self.macro1             = std.math.clamp(value,   0.0,    1.0),
            100 => self.macro2             = std.math.clamp(value,   0.0,    1.0),
            101 => self.macro3             = std.math.clamp(value,   0.0,    1.0),
            102 => self.macro4             = std.math.clamp(value,   0.0,    1.0),
            // zig fmt: on
            // MATRIX: dest takes the raw param id (falls back to cutoff if
            // the value isn't a legal dest — e.g. a hand-edited curve).
            59...82 => {
                const row = &self.mod_matrix[(id - 59) / 3];
                switch ((id - 59) % 3) {
                    0 => row.source = enumFromValue(ModSource, value),
                    1 => {
                        const d: u8 = if (value > 0.0 and value <= 255.0)
                            @intFromFloat(@round(value))
                        else
                            21;
                        row.dest = if (modDestIndex(d) != null) d else 21;
                    },
                    2 => row.depth = std.math.clamp(value, -1.0, 1.0),
                    else => unreachable,
                }
            },
            else => {},
        }
    }

    /// Current value of editor param `id`, in the same unit/encoding
    /// `setParamAbsolute` accepts (enums/toggles as 0-based ordinals) — the
    /// read half of undo's capture/restore pair. A control-thread read of
    /// live fields, same race-tolerant convention the synth editor's own
    /// row rendering already uses. Null for unknown ids.
    pub fn paramValue(self: *const PolySynth, id: u8) ?f32 {
        return switch (id) {
            // zig fmt: off
            0  => enumToValue(self.waveform),
            1  => self.pulse_width,
            2  => self.detune_cents,
            3  => @floatFromInt(self.unison),
            4  => self.unison_detune,
            5  => self.unison_spread,
            6  => if (self.osc_b_on) 1.0 else 0.0,
            7  => enumToValue(self.osc_b_waveform),
            8  => self.osc_b_pulse_width,
            9  => self.osc_b_semi,
            // zig fmt: on
            10 => self.osc_b_detune_cents,
            11 => self.osc_b_level,
            12 => @floatFromInt(self.osc_b_unison),
            13 => self.osc_b_unison_detune,
            14 => enumToValue(self.mod_mode),
            15 => self.mod_amount,
            16 => self.attack_s,
            17 => self.decay_s,
            18 => self.sustain,
            19 => self.release_s,
            20 => enumToValue(self.filter_type),
            21 => self.filter_cutoff,
            22 => self.filter_res,
            24 => self.fenv_attack_s,
            25 => self.fenv_decay_s,
            26 => self.fenv_sustain,
            27 => self.fenv_release_s,
            28 => enumToValue(self.lfo_shape),
            29 => self.lfo_rate_hz,
            32 => enumToValue(self.voice_mode),
            33 => self.glide_s,
            34 => self.sub_level,
            35 => enumToValue(self.sub_shape),
            36 => self.noise_level,
            37 => self.noise_color,
            38 => self.gain,
            39 => enumToValue(self.unison_mode),
            40 => enumToValue(self.osc_b_unison_mode),
            41 => enumToValue(self.warp_mode),
            42 => self.warp_amount,
            43 => enumToValue(self.osc_b_warp_mode),
            44 => self.osc_b_warp_amount,
            45 => if (self.filter2_on) 1.0 else 0.0,
            46 => enumToValue(self.filter2_type),
            47 => self.filter2_cutoff,
            48 => self.filter2_res,
            49 => enumToValue(self.filter_routing),
            50 => if (self.osc_c_on) 1.0 else 0.0,
            51 => enumToValue(self.osc_c_waveform),
            52 => self.osc_c_pulse_width,
            53 => self.osc_c_semi,
            54 => self.osc_c_detune_cents,
            55 => self.osc_c_level,
            56 => @floatFromInt(self.osc_c_unison),
            57 => self.osc_c_unison_detune,
            58 => enumToValue(self.osc_c_unison_mode),
            // zig fmt: off
            83 => if (self.fx_dist_on) 1.0 else 0.0,
            84 => self.fx_dist_drive_db,
            85 => self.fx_dist_mix,
            86 => if (self.fx_crush_on) 1.0 else 0.0,
            87 => self.fx_crush_bits,
            88 => self.fx_crush_rate,
            89 => self.fx_crush_mix,
            90 => if (self.fx_flanger_on) 1.0 else 0.0,
            91 => self.fx_flanger_rate_hz,
            92 => self.fx_flanger_depth,
            93 => self.fx_flanger_feedback,
            94 => self.fx_flanger_mix,
            95 => enumToValue(self.lfo2_shape),
            96 => self.lfo2_rate_hz,
            97 => enumToValue(self.lfo3_shape),
            98 => self.lfo3_rate_hz,
            99  => self.macro1,
            100 => self.macro2,
            101 => self.macro3,
            102 => self.macro4,
            // zig fmt: on
            59...82 => blk: {
                const row = self.mod_matrix[(id - 59) / 3];
                break :blk switch ((id - 59) % 3) {
                    // zig fmt: off
                    0 => enumToValue(row.source),
                    1 => @floatFromInt(row.dest),
                    2 => row.depth,
                    // zig fmt: on
                    else => unreachable,
                };
            },
            else => null,
        };
    }

    /// One entry per `setParamAbsolute`-handled id — the shared metadata the
    /// automation editor's param picker, curve labels, and h/l nudge step all
    /// need. `label` is the short in-graph tag (matches the synth editor's own
    /// row labels where practical); `section` groups the picker's listing the
    /// same way the synth editor's own KEY/OSC A/OSC B/... rows are grouped.
    /// Shared shape with Sampler's own table — see `dsp.AutomatableParam`.
    pub const AutomatableParam = dsp.AutomatableParam;

    pub const automatable_params = [_]AutomatableParam{
        // zig fmt: off
        .{ .id = 1,  .label = "PW A",       .section = "OSC A",   .range = .{ 0.01,   0.99 },    .step = 0.01 },
        .{ .id = 2,  .label = "DETUNE A",   .section = "OSC A",   .range = .{ -100.0, 100.0 },   .step = 1.0 },
        .{ .id = 3,  .label = "UNISON A",   .section = "OSC A",   .range = .{ 1.0,    16.0 },    .step = 1.0 },
        .{ .id = 4,  .label = "UNI DET A",  .section = "OSC A",   .range = .{ 0.0,    100.0 },   .step = 1.0 },
        .{ .id = 5,  .label = "UNI SPRD A", .section = "OSC A",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 8,  .label = "PW B",       .section = "OSC B",   .range = .{ 0.01,   0.99 },    .step = 0.01 },
        .{ .id = 9,  .label = "SEMI B",     .section = "OSC B",   .range = .{ -24.0,  24.0 },    .step = 1.0 },
        .{ .id = 10, .label = "DETUNE B",   .section = "OSC B",   .range = .{ -100.0, 100.0 },   .step = 1.0 },
        .{ .id = 11, .label = "LEVEL B",    .section = "OSC B",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 12, .label = "UNISON B",   .section = "OSC B",   .range = .{ 1.0,    16.0 },    .step = 1.0 },
        .{ .id = 13, .label = "UNI DET B",  .section = "OSC B",   .range = .{ 0.0,    100.0 },   .step = 1.0 },
        .{ .id = 15, .label = "MOD AMT",    .section = "MOD",     .range = .{ 0.0,    8.0 },     .step = 0.05 },
        .{ .id = 16, .label = "ATTACK",     .section = "ENV",     .range = .{ 0.001,  5.0 },     .step = 0.01 },
        .{ .id = 17, .label = "DECAY",      .section = "ENV",     .range = .{ 0.001,  5.0 },     .step = 0.01 },
        .{ .id = 18, .label = "SUSTAIN",    .section = "ENV",     .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 19, .label = "RELEASE",    .section = "ENV",     .range = .{ 0.001,  10.0 },    .step = 0.01 },
        .{ .id = 21, .label = "CUTOFF",     .section = "FILTER",  .range = .{ 20.0,   20_000.0 },.step = 100.0 },
        .{ .id = 22, .label = "RESONANCE",  .section = "FILTER",  .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 24, .label = "FENV ATK",   .section = "FENV",    .range = .{ 0.001,  5.0 },     .step = 0.01 },
        .{ .id = 25, .label = "FENV DEC",   .section = "FENV",    .range = .{ 0.001,  5.0 },     .step = 0.01 },
        .{ .id = 26, .label = "FENV SUS",   .section = "FENV",    .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 27, .label = "FENV REL",   .section = "FENV",    .range = .{ 0.001,  10.0 },    .step = 0.01 },
        .{ .id = 29, .label = "LFO RATE",   .section = "LFO",     .range = .{ 0.01,   20.0 },    .step = 0.1 },
        .{ .id = 33, .label = "GLIDE",      .section = "VOICE",   .range = .{ 0.0,    10.0 },    .step = 0.01 },
        .{ .id = 34, .label = "SUB LEVEL",  .section = "SUB",     .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 36, .label = "NOISE LVL",  .section = "NOISE",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 37, .label = "NOISE CLR",  .section = "NOISE",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 38, .label = "OUT GAIN",   .section = "OUT",     .range = .{ 0.01,   1.0 },     .step = 0.01 },
        .{ .id = 42, .label = "WARP AMT A", .section = "OSC A",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 44, .label = "WARP AMT B", .section = "OSC B",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 47, .label = "CUTOFF 2",   .section = "FILTER 2",.range = .{ 20.0,   20_000.0 },.step = 100.0 },
        .{ .id = 48, .label = "RESONANCE 2",.section = "FILTER 2",.range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 52, .label = "PW C",       .section = "OSC C",   .range = .{ 0.01,   0.99 },    .step = 0.01 },
        .{ .id = 53, .label = "SEMI C",     .section = "OSC C",   .range = .{ -24.0,  24.0 },    .step = 1.0 },
        .{ .id = 54, .label = "DETUNE C",   .section = "OSC C",   .range = .{ -100.0, 100.0 },   .step = 1.0 },
        .{ .id = 55, .label = "LEVEL C",    .section = "OSC C",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 56, .label = "UNISON C",   .section = "OSC C",   .range = .{ 1.0,    16.0 },    .step = 1.0 },
        .{ .id = 57, .label = "UNI DET C",  .section = "OSC C",   .range = .{ 0.0,    100.0 },   .step = 1.0 },
        // Matrix row depths: automating one wobbles the wobble (the classic
        // dubstep depth ride). Sources/dests stay manual-only.
        .{ .id = 61, .label = "MT1 DEPTH",  .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 64, .label = "MT2 DEPTH",  .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 67, .label = "MT3 DEPTH",  .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 70, .label = "MT4 DEPTH",  .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 73, .label = "MT5 DEPTH",  .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 76, .label = "MT6 DEPTH",  .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 79, .label = "MT7 DEPTH",  .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 82, .label = "MT8 DEPTH",  .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 84, .label = "DIST DRIVE", .section = "FX DIST", .range = .{ 0.0,    36.0 },    .step = 0.5 },
        .{ .id = 85, .label = "DIST MIX",   .section = "FX DIST", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 87, .label = "CRUSH BITS", .section = "FX CRUSH",.range = .{ 1.0,    16.0 },    .step = 1.0 },
        .{ .id = 88, .label = "CRUSH RATE", .section = "FX CRUSH",.range = .{ 1.0,    64.0 },    .step = 1.0 },
        .{ .id = 89, .label = "CRUSH MIX",  .section = "FX CRUSH",.range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 91, .label = "FLNG RATE",  .section = "FX FLNG", .range = .{ 0.02,   8.0 },     .step = 0.05 },
        .{ .id = 92, .label = "FLNG DEPTH", .section = "FX FLNG", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 93, .label = "FLNG FDBK",  .section = "FX FLNG", .range = .{ 0.0,    0.95 },    .step = 0.01 },
        .{ .id = 94, .label = "FLNG MIX",   .section = "FX FLNG", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 96, .label = "LFO2 RATE",  .section = "LFO 2",   .range = .{ 0.01,   20.0 },    .step = 0.1 },
        .{ .id = 98, .label = "LFO3 RATE",  .section = "LFO 3",   .range = .{ 0.01,   20.0 },    .step = 0.1 },
        // Macros: an automation lane on one macro rides every destination
        // its matrix rows fan out to. Not matrix dests themselves (a row
        // reading a matrix-shifted macro would need eval ordering).
        .{ .id = 99,  .label = "MACRO 1",   .section = "MACRO",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 100, .label = "MACRO 2",   .section = "MACRO",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 101, .label = "MACRO 3",   .section = "MACRO",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 102, .label = "MACRO 4",   .section = "MACRO",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        // zig fmt: on
    };

    pub fn findAutomatableParam(id: u8) ?*const AutomatableParam {
        for (&automatable_params) |*p| if (p.id == id) return p;
        return null;
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
            // zig fmt: off
            .note_on    => |e| self.noteOn(e.note, e.velocity),
            .note_off   => |e| self.noteOff(e.note),
            .all_off    => self.resetAll(),
            .cc         => |e| self.applyCC(e.cc, e.value),
            .pitch_bend => |e| self.applyPitchBend(e.bend, 2.0),
            // e.id is u16 (wide enough for DrumMachine's pad-encoded ids);
            // PolySynth's own param space is well under 256, so truncate
            // rather than @intCast — a stray wide id (can't happen in
            // practice, only DrumMachine ever constructs one) silently
            // no-ops here instead of panicking, matching adjustParam's own
            // unknown-id default arm.
            .set_param  => |e| self.adjustParam(@truncate(e.id), e.steps),
            // zig fmt: on
            .set_param_abs => |e| self.setParamAbsolute(@truncate(e.id), e.value),
            .set_sidechain_buf, .capture_pad => {},
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
    const types_to_test = [_]FilterType{ .lp, .hp, .bp, .notch, .ladder, .comb };
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
        // zig fmt: off
        @memset(&buf_open, 0.0);   open.processBlock(&buf_open);
        @memset(&buf_closed, 0.0); closed.processBlock(&buf_closed);
    }

    var rms_open: f32 = 0.0;
    var rms_closed: f32 = 0.0;
    for (buf_open, buf_closed) |o, c| {
        rms_open   += o * o;
        // zig fmt: on
        rms_closed += c * c;
    }
    try std.testing.expect(rms_closed < rms_open * 0.1);
}

test "ladder filter: closed cutoff attenuates like a lowpass" {
    var open = PolySynth.init(48_000);
    open.waveform = .saw;
    open.filter_type = .ladder;
    open.filter_cutoff = 18_000.0;
    open.noteOn(84, 1.0);

    var closed = PolySynth.init(48_000);
    closed.waveform = .saw;
    closed.filter_type = .ladder;
    closed.filter_cutoff = 200.0;
    closed.noteOn(84, 1.0);

    var buf_open: [512]Sample = undefined;
    var buf_closed: [512]Sample = undefined;
    for (0..20) |_| {
        // zig fmt: off
        @memset(&buf_open, 0.0);   open.processBlock(&buf_open);
        @memset(&buf_closed, 0.0); closed.processBlock(&buf_closed);
    }

    var rms_open: f32 = 0.0;
    var rms_closed: f32 = 0.0;
    for (buf_open, buf_closed) |o, c| {
        rms_open   += o * o;
        // zig fmt: on
        rms_closed += c * c;
    }
    try std.testing.expect(rms_closed < rms_open * 0.1);
}

test "comb filter: impulse echoes at the tuned delay" {
    var st: PolySynth.FilterState = .{};
    const fc: PolySynth.FilterCoeffs = .{ .comb_delay = 100.0, .comb_fb = 0.9 };

    // Impulse passes through dry immediately...
    const first = PolySynth.filterSample(.comb, fc, &st, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), first, 1e-6);

    // ...then echoes scaled by the feedback exactly comb_delay samples later,
    // and again one round-trip after that.
    for (1..251) |i| {
        const y = PolySynth.filterSample(.comb, fc, &st, 0.0);
        switch (i) {
            // zig fmt: off
            100  => try std.testing.expectApproxEqAbs(@as(f32, 0.9),  y, 1e-5),
            200  => try std.testing.expectApproxEqAbs(@as(f32, 0.81), y, 1e-5),
            150  => try std.testing.expectApproxEqAbs(@as(f32, 0.0),  y, 1e-5),
            else => {},
            // zig fmt: on
        }
    }
}

test "filter envelope modulates cutoff via matrix row: positive depth brightens" {
    // Two identical synths; one routes fenv → cutoff through the matrix.
    // After initial attack the envelope-driven one should be louder (more HF content).
    var base_synth = PolySynth.init(48_000);
    base_synth.waveform = .saw;
    base_synth.filter_cutoff = 500.0;
    base_synth.noteOn(60, 1.0);

    var mod_synth = PolySynth.init(48_000);
    mod_synth.waveform = .saw;
    mod_synth.filter_cutoff = 500.0;
    // depth 0.75 = +3 octaves when env2 = 1 → 500 Hz * 8 = 4 kHz
    mod_synth.mod_matrix[0] = .{ .source = .fenv, .dest = 21, .depth = 0.75 };
    mod_synth.fenv_attack_s = 0.001; // very fast attack
    // zig fmt: off
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
    // zig fmt: on
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
        // zig fmt: off
        @memset(&buf_wide, 0.0);   wide.processBlock(&buf_wide);
        @memset(&buf_narrow, 0.0); narrow.processBlock(&buf_narrow);
    }
    var rms_w: f32 = 0.0;
    var rms_n: f32 = 0.0;
    for (buf_wide, buf_narrow) |w, n| { rms_w += w * w; rms_n += n * n; }
    try std.testing.expect(rms_n < rms_w);
}

test "unison mode: step and spread produce different detune patterns" {
    var spread = PolySynth.init(48_000);
    spread.unison       = 4;
    spread.unison_detune = 50.0;
    spread.unison_mode  = .spread;
    spread.noteOn(60, 1.0);

    var step = PolySynth.init(48_000);
    step.unison        = 4;
    step.unison_detune  = 50.0;
    step.unison_mode   = .step;
    step.noteOn(60, 1.0);

    var buf_spread: [512]Sample = undefined;
    var buf_step: [512]Sample = undefined;
    for (0..10) |_| {
        @memset(&buf_spread, 0.0); spread.processBlock(&buf_spread);
        @memset(&buf_step, 0.0);   step.processBlock(&buf_step);
        // zig fmt: on
    }
    var diff: f32 = 0.0;
    for (buf_spread, buf_step) |a, b| diff += @abs(a - b);
    try std.testing.expect(diff > 0.01);
}

test "unison mode: harmonic and ratio curves hit exact series at detune=100" {
    const eps = 0.01;
    // Voice 0 stays on the fundamental in both modes, at any detune.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), PolySynth.unisonSpreadCents(.harmonic, 0, 4, 100.0), eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), PolySynth.unisonSpreadCents(.ratio, 0, 4, 100.0), eps);
    // harmonic: voice 1 = 2nd harmonic (octave), voice 3 = 4th (two octaves).
    try std.testing.expectApproxEqAbs(@as(f32, 1200.0), PolySynth.unisonSpreadCents(.harmonic, 1, 4, 100.0), eps);
    try std.testing.expectApproxEqAbs(@as(f32, 2400.0), PolySynth.unisonSpreadCents(.harmonic, 3, 4, 100.0), eps);
    // ratio: voice 1 = 1.5x (just fifth, ~702 ct), voice 2 = 2x (octave).
    try std.testing.expectApproxEqAbs(@as(f32, 701.955), PolySynth.unisonSpreadCents(.ratio, 1, 4, 100.0), eps);
    try std.testing.expectApproxEqAbs(@as(f32, 1200.0), PolySynth.unisonSpreadCents(.ratio, 2, 4, 100.0), eps);
    // detune scales the blend linearly: half detune = half the cents.
    try std.testing.expectApproxEqAbs(@as(f32, 600.0), PolySynth.unisonSpreadCents(.harmonic, 1, 4, 50.0), eps);
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

test "LFO tremolo via matrix: square trough at depth=1 silences the voice" {
    // LFO square at phase=0.75 → value = -1 (trough); a matrix row lfo→amp
    // at depth 1 makes amp_mod = clamp(1 + (-1), 0, 2) = 0.
    var with_lfo = PolySynth.init(48_000);
    // zig fmt: off
    with_lfo.lfo_shape  = .square;
    with_lfo.lfo_rate_hz = 0.0; // frozen
    with_lfo.lfo_phase  = 0.75; // square trough → lfo_val = -1
    // zig fmt: on
    with_lfo.mod_matrix[0] = .{ .source = .lfo, .dest = PolySynth.dest_amp, .depth = 1.0 };
    with_lfo.noteOn(60, 1.0);

    var without_lfo = PolySynth.init(48_000);
    without_lfo.noteOn(60, 1.0);

    var buf_lfo: [256]Sample = undefined;
    var buf_dry: [256]Sample = undefined;
    // Warm up past attack
    for (0..20) |_| {
        // zig fmt: off
        @memset(&buf_lfo, 0.0); with_lfo.processBlock(&buf_lfo);
        @memset(&buf_dry, 0.0); without_lfo.processBlock(&buf_dry);
        // zig fmt: on
    }
    var rms_lfo: f32 = 0.0;
    for (buf_lfo) |s| rms_lfo += s * s;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rms_lfo, 1e-6);
}

test "mod matrix: velocity source scales its dest per voice" {
    var with_vel = PolySynth.init(48_000);
    with_vel.mod_matrix[0] = .{ .source = .velocity, .dest = PolySynth.dest_amp, .depth = 1.0 };
    with_vel.noteOn(60, 1.0); // amp_mod = 1 + 1.0*1.0 = 2

    var without = PolySynth.init(48_000);
    without.noteOn(60, 1.0);

    var buf_vel: [256]Sample = undefined;
    var buf_dry: [256]Sample = undefined;
    for (0..20) |_| {
        // zig fmt: off
        @memset(&buf_vel, 0.0); with_vel.processBlock(&buf_vel);
        @memset(&buf_dry, 0.0); without.processBlock(&buf_dry);
        // zig fmt: on
    }
    var rms_vel: f32 = 0.0;
    var rms_dry: f32 = 0.0;
    // zig fmt: off
    for (buf_vel, buf_dry) |a, b| { rms_vel += a * a; rms_dry += b * b; }
    // zig fmt: on
    try std.testing.expect(rms_vel > rms_dry * 2.0);
}

test "applyPatch: legacy fenv/lfo fields migrate to matrix rows" {
    var s = PolySynth.init(48_000);
    s.applyPatch(.{ .fenv_amount = 2.0, .lfo_depth = 0.5, .lfo_target = .pitch });
    try std.testing.expectEqual(ModSource.fenv, s.mod_matrix[0].source);
    try std.testing.expectEqual(@as(u8, 21), s.mod_matrix[0].dest);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.mod_matrix[0].depth, 1e-6);
    try std.testing.expectEqual(ModSource.lfo, s.mod_matrix[1].source);
    try std.testing.expectEqual(PolySynth.dest_pitch, s.mod_matrix[1].dest);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.mod_matrix[1].depth, 1e-6);

    // A patch that carries its own matrix ignores the legacy fields.
    var rows = [_]PolySynth.ModRow{.{}} ** PolySynth.max_mod_rows;
    rows[0] = .{ .source = .wheel, .dest = 34, .depth = -0.4 };
    s.applyPatch(.{ .fenv_amount = 2.0, .mod_matrix = rows });
    try std.testing.expectEqual(ModSource.wheel, s.mod_matrix[0].source);
    try std.testing.expectEqual(ModSource.none, s.mod_matrix[1].source);
}

test "matrix param ids round-trip through paramValue/setParamAbsolute" {
    var a = PolySynth.init(48_000);
    a.mod_matrix[2] = .{ .source = .wheel, .dest = 34, .depth = -0.4 };
    a.mod_matrix[7] = .{ .source = .keytrack, .dest = PolySynth.dest_pitch, .depth = 1.0 };

    var b = PolySynth.init(48_000);
    var id: u8 = 59;
    while (id <= 82) : (id += 1) {
        if (a.paramValue(id)) |v| b.setParamAbsolute(id, v);
    }
    try std.testing.expectEqual(a.mod_matrix[2], b.mod_matrix[2]);
    try std.testing.expectEqual(a.mod_matrix[7], b.mod_matrix[7]);

    // An illegal dest ordinal (hand-edited automation) falls back to cutoff.
    b.setParamAbsolute(60, 200.0); // row 0 dest; 200 is not a legal dest
    try std.testing.expectEqual(@as(u8, 21), b.mod_matrix[0].dest);
}

test "adjustParam: matrix dest walks the dest table and wraps" {
    var s = PolySynth.init(48_000);
    try std.testing.expectEqual(@as(u8, 21), s.mod_matrix[0].dest);
    s.adjustParam(60, -1); // one step back from cutoff
    const idx_cutoff = PolySynth.modDestIndex(21).?;
    try std.testing.expectEqual(PolySynth.mod_dest_ids[idx_cutoff - 1], s.mod_matrix[0].dest);
    s.adjustParam(60, 1);
    try std.testing.expectEqual(@as(u8, 21), s.mod_matrix[0].dest);
}

test "LFO 2 tremolo via matrix: square trough at depth=1 silences the voice" {
    var s = PolySynth.init(48_000);
    // zig fmt: off
    s.lfo2_shape   = .square;
    s.lfo2_rate_hz = 0.0;  // frozen
    s.lfo2_phase   = 0.75; // square trough → -1
    // zig fmt: on
    s.mod_matrix[0] = .{ .source = .lfo2, .dest = PolySynth.dest_amp, .depth = 1.0 };
    s.noteOn(60, 1.0);
    var buf: [256]Sample = undefined;
    for (0..20) |_| {
        @memset(&buf, 0.0);
        s.processBlock(&buf);
    }
    var rms: f32 = 0.0;
    for (buf) |x| rms += x * x;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rms, 1e-6);
    // A frozen (rate 0) phase survives the per-block advance untouched.
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.lfo2_phase, 1e-6);
}

test "macro source: mac1 at depth 1 to AMP doubles the voice gain" {
    var with_mac = PolySynth.init(48_000);
    with_mac.macro1 = 1.0;
    with_mac.mod_matrix[0] = .{ .source = .mac1, .dest = PolySynth.dest_amp, .depth = 1.0 };
    with_mac.noteOn(60, 1.0);

    var without = PolySynth.init(48_000);
    without.noteOn(60, 1.0);

    var buf_mac: [256]Sample = undefined;
    var buf_dry: [256]Sample = undefined;
    for (0..20) |_| {
        // zig fmt: off
        @memset(&buf_mac, 0.0); with_mac.processBlock(&buf_mac);
        @memset(&buf_dry, 0.0); without.processBlock(&buf_dry);
        // zig fmt: on
    }
    var rms_mac: f32 = 0.0;
    var rms_dry: f32 = 0.0;
    // zig fmt: off
    for (buf_mac, buf_dry) |a, b| { rms_mac += a * a; rms_dry += b * b; }
    // zig fmt: on
    try std.testing.expect(rms_mac > rms_dry * 2.0);
}

test "sample & hold: level redraws on phase wrap and holds between wraps" {
    var s = PolySynth.init(48_000);
    s.lfo_shape = .sh;
    s.lfo_rate_hz = 20.0; // wraps every 2400 frames
    s.noteOn(60, 1.0);
    var buf: [256]Sample = undefined;

    // First blocks stay within one cycle: the held level must not change.
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    const held = s.lfo_sh[0];
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expectEqual(held, s.lfo_sh[0]);

    // Push the phase past a wrap: a new level is drawn (xorshift never
    // repeats within a period, so inequality is deterministic here).
    s.lfo_phase = 0.999;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expect(s.lfo_sh[0] != held);
}

test "LFO 2/3 + macro params round-trip through paramValue/setParamAbsolute and Patch" {
    var a = PolySynth.init(48_000);
    // zig fmt: off
    a.lfo2_shape = .sh;  a.lfo2_rate_hz = 6.5;
    a.lfo3_shape = .saw; a.lfo3_rate_hz = 0.25;
    a.macro1 = 0.1; a.macro2 = 0.4; a.macro3 = 0.7; a.macro4 = 1.0;
    // zig fmt: on

    var b = PolySynth.init(48_000);
    var id: u8 = 95;
    while (id <= 102) : (id += 1) {
        if (a.paramValue(id)) |v| b.setParamAbsolute(id, v);
    }
    try std.testing.expectEqual(a.lfo2_shape, b.lfo2_shape);
    try std.testing.expectEqual(a.lfo3_shape, b.lfo3_shape);
    try std.testing.expectApproxEqAbs(a.lfo2_rate_hz, b.lfo2_rate_hz, 1e-6);
    try std.testing.expectApproxEqAbs(a.lfo3_rate_hz, b.lfo3_rate_hz, 1e-6);
    try std.testing.expectApproxEqAbs(a.macro2, b.macro2, 1e-6);
    try std.testing.expectApproxEqAbs(a.macro4, b.macro4, 1e-6);

    var c = PolySynth.init(48_000);
    c.applyPatch(a.toPatch());
    try std.testing.expectEqual(a.lfo2_shape, c.lfo2_shape);
    try std.testing.expectApproxEqAbs(a.lfo3_rate_hz, c.lfo3_rate_hz, 1e-6);
    try std.testing.expectApproxEqAbs(a.macro3, c.macro3, 1e-6);
}

test "polyphony: up to max_voices voices" {
    var synth = PolySynth.init(48_000);
    for (0..PolySynth.max_voices) |i| synth.noteOn(@intCast(60 + i), 1.0);
    var active: usize = 0;
    // zig fmt: off
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
    // zig fmt: on
    try std.testing.expectApproxEqAbs(a4_log, synth.voices[0].glide_log_freq, 1e-4);
}

test "mono mode: only one voice active" {
    var synth = PolySynth.init(48_000);
    synth.voice_mode = .mono;
    synth.noteOn(60, 1.0);
    synth.noteOn(64, 1.0);
    synth.noteOn(67, 1.0);
    var active: usize = 0;
    // zig fmt: off
    for (synth.voices) |v| if (v.active) { active += 1; };
    // zig fmt: on
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
    // zig fmt: off
    for (0..100) |_| { @memset(&buf, 0.0); synth.processBlock(&buf); }
    // zig fmt: on
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
        // zig fmt: off
        synth.lfo_shape   = shape;
        synth.lfo_rate_hz = 5.0;
        // zig fmt: on
        synth.mod_matrix[0] = .{ .source = .lfo, .dest = 21, .depth = 1.0 };
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

test "setParamAbsolute: sets filter cutoff directly and clamps out-of-range" {
    var synth = PolySynth.init(48_000);
    synth.setParamAbsolute(21, 2_500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 2_500.0), synth.filter_cutoff, 1e-3);

    synth.setParamAbsolute(21, 99_999.0);
    try std.testing.expectApproxEqAbs(@as(f32, 20_000.0), synth.filter_cutoff, 1e-3);
    synth.setParamAbsolute(21, -5.0);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), synth.filter_cutoff, 1e-3);

    // Unhandled ids are a no-op, matching adjustParam's own default arm.
    synth.filter_cutoff = 1_000.0;
    synth.setParamAbsolute(0, 5_000.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1_000.0), synth.filter_cutoff, 1e-3);
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

test "paramValue/setParamAbsolute round-trip continuous, enum, and toggle params" {
    var a = PolySynth.init(48_000);
    a.sustain = 0.37;
    a.filter_type = .bp;
    a.osc_b_on = true;
    a.mod_mode = .fm_a_to_b;

    // Every editor param id survives a value-copy through the pair.
    var b = PolySynth.init(48_000);
    var id: u8 = 0;
    while (id <= 40) : (id += 1) {
        if (a.paramValue(id)) |v| b.setParamAbsolute(id, v);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.37), b.sustain, 1e-6);
    try std.testing.expectEqual(FilterType.bp, b.filter_type);
    try std.testing.expect(b.osc_b_on);
    try std.testing.expectEqual(ModMode.fm_a_to_b, b.mod_mode);

    // A garbage ordinal (hand-edited automation) degrades safely.
    b.setParamAbsolute(20, std.math.nan(f32));
    try std.testing.expectEqual(FilterType.lp, b.filter_type);
    b.setParamAbsolute(20, 1.0e30);
    try std.testing.expectEqual(FilterType.comb, b.filter_type);
}

test "FX param ids round-trip through paramValue/setParamAbsolute" {
    var a = PolySynth.init(48_000);
    a.fx_dist_on = true;
    a.fx_dist_drive_db = 24.0;
    a.fx_crush_bits = 4.0;
    a.fx_flanger_on = true;
    a.fx_flanger_feedback = 0.8;

    var b = PolySynth.init(48_000);
    var id: u8 = 83;
    while (id <= 94) : (id += 1) {
        if (a.paramValue(id)) |v| b.setParamAbsolute(id, v);
    }
    try std.testing.expect(b.fx_dist_on);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), b.fx_dist_drive_db, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), b.fx_crush_bits, 1e-6);
    try std.testing.expect(b.fx_flanger_on);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), b.fx_flanger_feedback, 1e-6);
    try std.testing.expect(!b.fx_crush_on);
}

test "internal FX: flanger at mix 0 passes the synth output untouched" {
    var a = PolySynth.init(48_000);
    var b = PolySynth.init(48_000);
    b.fx_flanger_on = true;
    b.fx_flanger_mix = 0.0;
    b.fx_flanger_feedback = 0.0;
    a.noteOn(60, 1.0);
    b.noteOn(60, 1.0);

    var buf_a: [512]Sample = undefined;
    var buf_b: [512]Sample = undefined;
    for (0..8) |_| {
        @memset(&buf_a, 0.0);
        @memset(&buf_b, 0.0);
        a.processBlock(&buf_a);
        b.processBlock(&buf_b);
        for (buf_a, buf_b) |sa, sb| try std.testing.expectApproxEqAbs(sa, sb, 1e-6);
    }
}

test "internal FX: distortion drives the synth output hotter" {
    var a = PolySynth.init(48_000);
    var b = PolySynth.init(48_000);
    b.fx_dist_on = true;
    b.fx_dist_drive_db = 30.0;
    a.noteOn(60, 0.6);
    b.noteOn(60, 0.6);

    var buf_a: [512]Sample = undefined;
    var buf_b: [512]Sample = undefined;
    var sum_a: f64 = 0.0;
    var sum_b: f64 = 0.0;
    for (0..8) |_| {
        @memset(&buf_a, 0.0);
        @memset(&buf_b, 0.0);
        a.processBlock(&buf_a);
        b.processBlock(&buf_b);
        for (buf_a, buf_b) |sa, sb| {
            sum_a += @abs(sa);
            sum_b += @abs(sb);
            try std.testing.expect(std.math.isFinite(sb));
        }
    }
    try std.testing.expect(sum_b > sum_a * 1.5);
}

test "internal FX: matrix wheel row modulates dist mix globally" {
    // Base mix 1 with a wheel → dist-mix row at depth -1: wheel at 1 nulls
    // the mix, so the driven synth must match a clean one exactly. This
    // exercises the global (post-mix) matrix evaluation path end to end.
    var clean = PolySynth.init(48_000);
    var driven = PolySynth.init(48_000);
    driven.fx_dist_on = true;
    driven.fx_dist_drive_db = 30.0;
    driven.fx_dist_mix = 1.0;
    driven.mod_matrix[0] = .{ .source = .wheel, .dest = 85, .depth = -1.0 };
    driven.mod_wheel = 1.0;
    clean.noteOn(60, 0.6);
    driven.noteOn(60, 0.6);

    var buf_c: [512]Sample = undefined;
    var buf_d: [512]Sample = undefined;
    for (0..4) |_| {
        @memset(&buf_c, 0.0);
        @memset(&buf_d, 0.0);
        clean.processBlock(&buf_c);
        driven.processBlock(&buf_d);
        for (buf_c, buf_d) |sc, sd| try std.testing.expectApproxEqAbs(sc, sd, 1e-6);
    }
}

test "internal FX: flanger stays finite at max feedback and depth" {
    var synth = PolySynth.init(48_000);
    synth.fx_flanger_on = true;
    synth.fx_flanger_depth = 1.0;
    synth.fx_flanger_feedback = 0.95;
    synth.fx_flanger_mix = 1.0;
    synth.fx_flanger_rate_hz = 8.0;
    synth.noteOn(48, 1.0);

    var buf: [512]Sample = undefined;
    for (0..64) |_| {
        @memset(&buf, 0.0);
        synth.processBlock(&buf);
        for (buf) |s| try std.testing.expect(std.math.isFinite(s));
    }
}

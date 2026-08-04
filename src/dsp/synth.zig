//! Polyphonic subtractive synth: oscillator per voice with ADSR amplitude
//! and filter envelopes, multiple filter modes, and unison.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const midi = @import("../midi.zig");
pub const MbStyle = @import("multiband_comp.zig").Style;
const wavetable = @import("wavetable.zig");
const Wavetable = wavetable.Wavetable;
pub const BundledWavetable = wavetable.Bundled;
const Transport = @import("../transport.zig").Transport;
const FxModBus = @import("fx_mod.zig").Bus;

const Sample = types.Sample;

/// Enum/toggle params cross `paramValue`/`setParamAbsolute` as the
/// variant's 0-based declaration ordinal, rounded and clamped on the way
/// back in. The `> 0.0` guard doubles as the NaN check (a hand-edited
/// automation value could be anything), so a bad value degrades to the
/// first variant instead of tripping @intFromFloat safety.
pub fn enumToValue(e: anytype) f32 {
    return @floatFromInt(@intFromEnum(e));
}

pub fn enumFromValue(comptime E: type, value: f32) E {
    const n = @typeInfo(E).@"enum".fields.len;
    if (!(value > 0.0)) return @enumFromInt(0);
    const max: f32 = @floatFromInt(n - 1);
    if (value >= max) return @enumFromInt(n - 1);
    return @enumFromInt(@as(u8, @intFromFloat(@round(value))));
}

// zig fmt: off
pub const Waveform   = enum { sine, saw, triangle, square, wavetable };
/// lp/hp/bp/notch are 2-pole biquads. `ladder` is a Moog-style 4-pole
/// lowpass (24 dB/oct, tanh-saturated feedback - self-oscillates near full
/// resonance). `diode` is the same 4-stage cascade but with an asymmetric
/// diode-style clip at each stage instead of Moog's symmetric tanh - the
/// EMS/TB-303-family "thinner, brighter" resonant character. `comb` is a
/// feedback comb whose fundamental sits at the cutoff frequency (resonance
/// = feedback amount); its delay line bounds the low end at
/// sample_rate/comb_len (~94 Hz at 48 kHz). `formant` reinterprets cutoff
/// as a scan position across a fixed a-e-i-o-u vowel table (3 parallel
/// resonant bandpasses per vowel) instead of a corner frequency; resonance
/// narrows the formant bandwidths for a sharper vowel character.
pub const FilterType = enum { lp, hp, bp, notch, ladder, diode, comb, formant };
/// How filter 2's output combines with filter 1's when filter 2 is on.
/// `series`: filter 1 feeds filter 2. `parallel`: both filter the dry
/// oscillator mix and their outputs are averaged. Irrelevant (and behaves
/// identically to filter 1 alone) while `filter2_on` is false.
pub const FilterRouting = enum { series, parallel };
/// `sh` is sample & hold: a random level (uniform in [-1, 1)) redrawn each
/// time the LFO's phase wraps - held state lives on PolySynth (`lfo_sh`),
/// not derivable from phase alone like the other shapes. `chaos` is a
/// Lorenz-attractor output (x-axis, normalized), continuously integrated
/// every block at a rate set by the LFO's own rate knob - held state lives
/// on PolySynth (`lfo_chaos`), also not derivable from phase alone. `custom`
/// is a user-drawn breakpoint curve - see `LfoShapePoint`/`PolySynth.
/// lfo_custom` and `lfoCustomSample`.
pub const LfoShape   = enum { sine, triangle, saw, square, sh, chaos, custom };
/// One node of a `.custom` LFO shape: `phase` 0..1 (one full LFO cycle),
/// `value` -1..1 (matches every other shape's bipolar output range).
/// `lfoCustomSample` linearly interpolates between consecutive points and
/// holds the first/last value past either edge, same convention as
/// `dsp.automation.interpolate` (deliberately not reused directly: that one
/// is beat/f64-keyed for song timelines, this is phase/f32-keyed for one
/// LFO cycle, and pulling in the beat concept here would be misleading).
pub const LfoShapePoint = struct { phase: f32 = 0, value: f32 = 0 };
/// Capacity of a `.custom` LFO shape - same "small fixed bank, generous for
/// real use" convention as `PolySynth.max_mod_rows` elsewhere. Points are
/// edited one field at a time through ids `lfo_custom_id_base`..+50 (see
/// `PolySynth.adjustParam`/`setParamAbsolute`), the same scheme
/// `mod_matrix` rows already use, so edits only ever reach the synth
/// through the audio-thread command queue - never a direct field write
/// racing `processBlock`.
pub const max_lfo_shape_points: u8 = 8;
/// Flat id space start for `.custom` LFO shape points - see
/// `max_lfo_shape_points`'s doc comment. Slot `s` (0/1/2 = LFO 1/2/3)
/// occupies ids `base + s*17 .. base + s*17 + 15` (point `i`'s phase at
/// `+i*2`, value at `+i*2+1`) plus one count id at `base + s*17 + 16`.
/// Highest id used: 195 + 2*17 + 16 = 245. 246-248 are the three envelope
/// curvature knobs and 249-250 the two filter drives; 251-253 stay free,
/// and 254/255 are `dest_pitch`/`dest_amp`.
pub const lfo_custom_id_base: u16 = 195;
pub const lfo_custom_ids_per_slot: u16 = max_lfo_shape_points * 2 + 1;
const default_lfo_custom_points: [max_lfo_shape_points]LfoShapePoint = blk: {
    var pts: [max_lfo_shape_points]LfoShapePoint = undefined;
    pts[0] = .{ .phase = 0, .value = 0 };
    pts[1] = .{ .phase = 1, .value = 0 };
    for (pts[2..]) |*p| p.* = .{};
    break :blk pts;
};
/// An LFO's (or the arp's) rate source. `off` keeps the slot's plain Hz
/// rate knob; every other variant overrides it with a note division of the
/// project tempo, read off the attached `Transport`. Names are `n<num>_<den>`
/// with a trailing `d`/`t` for dotted/triplet, since Zig identifiers can't
/// start with a digit - `label` maps them back to the "1/8T" form the editor
/// shows. A slot with a sync division but no attached transport (a bare
/// PolySynth in a test, a synth built before the rack heap-allocates) falls
/// back to its Hz rate rather than freezing.
pub const LfoSync = enum {
    off, n4_1, n2_1, n1_1, n1_2d, n1_2, n1_2t, n1_4d, n1_4, n1_4t,
    n1_8d, n1_8, n1_8t, n1_16d, n1_16, n1_16t, n1_32,

    /// Beats (quarter notes) per full LFO cycle / per arp step, or null for
    /// `off`. A dotted division is 1.5x its straight length, a triplet 2/3.
    pub fn beatsPerCycle(self: LfoSync) ?f64 {
        return switch (self) {
            .off => null,
            .n4_1 => 16.0,   .n2_1 => 8.0,     .n1_1 => 4.0,
            .n1_2d => 3.0,   .n1_2 => 2.0,     .n1_2t => 4.0 / 3.0,
            .n1_4d => 1.5,   .n1_4 => 1.0,     .n1_4t => 2.0 / 3.0,
            .n1_8d => 0.75,  .n1_8 => 0.5,     .n1_8t => 1.0 / 3.0,
            .n1_16d => 0.375, .n1_16 => 0.25,  .n1_16t => 1.0 / 6.0,
            .n1_32 => 0.125,
        };
    }

    pub fn label(self: LfoSync) []const u8 {
        return switch (self) {
            .off => "off",
            .n4_1 => "4/1",   .n2_1 => "2/1",   .n1_1 => "1/1",
            .n1_2d => "1/2.", .n1_2 => "1/2",   .n1_2t => "1/2T",
            .n1_4d => "1/4.", .n1_4 => "1/4",   .n1_4t => "1/4T",
            .n1_8d => "1/8.", .n1_8 => "1/8",   .n1_8t => "1/8T",
            .n1_16d => "1/16.", .n1_16 => "1/16", .n1_16t => "1/16T",
            .n1_32 => "1/32",
        };
    }
};

/// How an LFO's phase relates to note-ons. `free` runs continuously - and,
/// while the slot is tempo-synced and the transport is rolling, derives its
/// phase straight from the playhead so the same wobble lands on the same
/// beat every pass. `key` restarts the phase at 0 on each note-on that
/// starts a voice, so every growl begins at the same point in the shape.
/// `one_shot` restarts like `key` but stops at the end of one cycle instead
/// of wrapping, holding whatever the shape reads at phase 1.0 - an LFO used
/// as a drawable extra envelope.
pub const LfoRetrig = enum { free, key, one_shot };

/// Legacy fixed LFO routing, retired when the mod matrix absorbed it.
/// Kept only so pre-matrix patches/projects still parse; `legacyModRows`
/// folds it into matrix rows on load.
pub const LfoTarget  = enum { none, filter, pitch, amp };
/// Modulation source for a mod-matrix row. The LFOs, `wheel`, and the four
/// macro knobs are synth-global; fenv/aenv/velocity/keytrack are per-voice.
/// Macros are plain 0..1 values fanned out through matrix rows - one knob
/// (or one automation lane, ids 99-102) moving many destinations at once.
pub const ModSource  = enum { none, lfo, fenv, aenv, velocity, keytrack, wheel, lfo2, lfo3, mac1, mac2, mac3, mac4, env3, random, alternate,

    /// True for the sources that swing through negative values. The
    /// envelopes, velocity, the wheel, and the macros are all already
    /// 0..1, so `ModRow.unipolar` has nothing to fold for them and is
    /// deliberately a no-op rather than squashing their range into 0.5..1.
    pub fn isBipolar(self: ModSource) bool {
        return switch (self) {
            .lfo, .lfo2, .lfo3, .keytrack, .random, .alternate => true,
            else => false,
        };
    }
};
pub const VoiceMode  = enum { poly, mono, legato };
pub const SubShape   = enum { sine, square };
pub const ModMode    = enum { none, ring, am_a_to_b, am_b_to_a, fm_a_to_b, fm_b_to_a };
/// Detune curve across unison voices. `spread`: symmetric, total width =
/// unison_detune cents (original behaviour). `step`: each voice offset by
/// a full unison_detune-cents step from its neighbor - a chord/stack-style
/// unison instead of a micro-detune blur. `harmonic`: voices bend upward
/// toward the integer harmonic series (1x, 2x, 3x, ...); `ratio` toward the
/// half-integer series (1x, 1.5x, 2x, ...) - a fifths/octaves power-chord
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
/// `updown`/`downup` ping-pong across the built sequence without repeating
/// either endpoint (classic arp behaviour). `played` walks the held-note
/// press order instead of pitch order. `chord` retriggers every held note
/// together each step (ignores `arp_octaves` - see PolySynth.arpFireStep).
pub const ArpMode     = enum { up, down, updown, downup, played, random, chord };
// zig fmt: on

/// Which insert-FX unit occupies each slot of the synth-internal chain's
/// processing order. Every unit stays an always-present by-value field on
/// `PolySynth` (same as before) - this only controls *sequence*, so it adds
/// no heap allocation and doesn't touch the mod-matrix/automation id space
/// (every param keeps its existing stable id regardless of position). See
/// `PolySynth.fx_order`'s own doc comment for the reorder mechanism.
pub const FxUnitKind = enum { gate, eq, comp, mb_comp, ott, dist, crush, chorus, flanger, tape, phaser, freq_shift, delay, reverb };

/// Starting chain order - preserves the relative order the original 6
/// fixed units always ran in, so existing presets/projects sound unchanged
/// on load; each unit added since is slotted in wherever it makes sense in
/// a typical signal chain (gate first, ahead of everything else; comp/
/// mb_comp right after it, dynamics before tone-shaping). Purely a starting
/// point once `fx_order` is user-reorderable.
pub const default_fx_order = [_]FxUnitKind{ .gate, .eq, .comp, .mb_comp, .ott, .dist, .crush, .chorus, .flanger, .tape, .phaser, .freq_shift, .delay, .reverb };

/// Upper bounds for the two `fx_*` params whose range isn't a round number.
/// They were the fixed-array delay line's and chorus ring's own capacity
/// limits back when the synth processed its own effects; nothing plays them
/// now (the rack chain does), but the ids survive as mod destinations, and a
/// destination still needs a range to scale a matrix depth against.
const fx_delay_max_time_s: f32 = 0.6;
const fx_chorus_max_depth_ms: f32 = 10.0;

pub const PolySynth = struct {
    sample_rate: f32,
    /// Owns the three oscillators' wavetable data (`wt_a`/`wt_b`/`wt_c`) -
    /// the one heap allocation PolySynth needs, everything else stays
    /// embedded by value. See `deinit`/`dupe`.
    allocator: std.mem.Allocator,

    // ── OSC ─────────────────────────────────────────────────────────────────
    waveform: Waveform = .saw,
    /// Pulse width for square wave (0.01–0.99).
    pulse_width: f32 = 0.5,
    /// OSC A's `.wavetable` table data. Not part of `Patch` - same as
    /// Sampler's audio clip, table content isn't preset data. No default:
    /// only `init()` constructs a `PolySynth`, and it always sets this.
    wt: Wavetable,
    wt_bundled: ?BundledWavetable = .basic,
    /// True once `wt` holds a `:load-wavetable`-imported table rather than
    /// the bundled default - gates whether persistence sidecars it (same
    /// convention as Sampler's `pad.user_sample`).
    wt_user: bool = false,
    /// OSC A's frame-scan position, 0..1. This one IS a plain `Patch` param.
    wt_pos: f32 = 0.0,
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
    // zig fmt: on
    /// OSC B's `.wavetable` table data - see `wt`'s doc comment.
    osc_b_wt: Wavetable,
    osc_b_wt_bundled: ?BundledWavetable = .basic,
    osc_b_wt_user: bool = false,
    osc_b_wt_pos: f32 = 0.0,
    // zig fmt: off

    // ── OSC C ────────────────────────────────────────────────────────────────
    /// Plain additive 3rd oscillator: no MOD A<->B or warp participation,
    /// same shape as OSC B otherwise. Kept simple deliberately - the mod
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
    // zig fmt: on
    /// OSC C's `.wavetable` table data - see `wt`'s doc comment. Its
    /// position param stays outside the mod matrix, like the rest of OSC C.
    osc_c_wt: Wavetable,
    osc_c_wt_bundled: ?BundledWavetable = .basic,
    osc_c_wt_user: bool = false,
    osc_c_wt_pos: f32 = 0.0,
    // zig fmt: off

    // ── AMP ENVELOPE ────────────────────────────────────────────────────────
    attack_s:  f32 = 0.005,
    decay_s:   f32 = 0.08,
    sustain:   f32 = 0.7,
    // zig fmt: on
    release_s: f32 = 0.25,
    /// Segment curvature: -1 logarithmic, 0 linear, +1 exponential.
    env_curve: f32 = 0.0,

    // ── FILTER ──────────────────────────────────────────────────────────────
    filter_type: FilterType = .lp,
    /// Filter cutoff in Hz (20 Hz–Nyquist). Default open (18 kHz).
    filter_cutoff: f32 = 18_000.0,
    /// Filter resonance 0..1 (mapped to Q 0.5..20).
    filter_res: f32 = 0.0,
    /// Input drive into filter 1. 1 = bypass.
    filter_drive: f32 = 1.0,

    // ── FILTER 2 ────────────────────────────────────────────────────────────
    /// Second filter slot. Shares the filter envelope/LFO-target modulation
    /// with filter 1 (its own cutoff as the base instead of a second env),
    /// so this stays a routing/model addition, not a second modulation rig.
    filter2_on: bool = false,
    filter2_type: FilterType = .lp,
    filter2_cutoff: f32 = 18_000.0,
    filter2_res: f32 = 0.0,
    /// Input drive into filter 2. 1 = bypass.
    filter2_drive: f32 = 1.0,
    filter_routing: FilterRouting = .series,

    // ── FILTER ENVELOPE ─────────────────────────────────────────────────────
    // zig fmt: off
    fenv_attack_s:  f32 = 0.005,
    fenv_decay_s:   f32 = 0.5,
    fenv_sustain:   f32 = 0.0,
    fenv_release_s: f32 = 0.3,
    /// Segment curvature: -1 logarithmic, 0 linear, +1 exponential.
    fenv_curve:     f32 = 0.0,

    // ── LFO ─────────────────────────────────────────────────────────────────
    // A pure mod source since the matrix absorbed its routing: shape + rate
    // here, destination/depth live on matrix rows.
    lfo_shape:  LfoShape  = .sine,
    // zig fmt: on
    /// Rate in Hz (0.01–20 Hz). Ignored while `lfo_sync` names a division.
    lfo_rate_hz: f32 = 1.0,
    /// Tempo division overriding `lfo_rate_hz` - see `LfoSync`.
    lfo_sync: LfoSync = .off,
    /// Phase behaviour across note-ons - see `LfoRetrig`.
    lfo_retrig: LfoRetrig = .free,
    /// Cycles (0..1) added to the phase at read time, so two LFOs on the
    /// same division can sit against each other. Not folded into `lfo_phase`
    /// itself: that would make a live offset edit jump the waveform instead
    /// of sliding it.
    lfo_phase_offset: f32 = 0.0,
    /// One-pole smoothing on the LFO's output, in ms (0 = off). Rounds the
    /// edges off square/S&H/stepped-custom shapes so a hard wobble glides
    /// instead of clicking. Applied at block rate, like the LFOs themselves.
    lfo_slew_ms: f32 = 0.0,
    /// Synth-global LFO phase (0..1). Advanced once per block.
    lfo_phase: f32 = 0.0,

    // ── LFO 2 / LFO 3 ───────────────────────────────────────────────────────
    // Two more global LFOs, same shape+rate-only design as LFO 1 (routing
    // lives on matrix rows). Independent phases so different rates stay
    // free-running against each other.
    // zig fmt: off
    lfo2_shape:   LfoShape  = .sine,
    lfo2_rate_hz: f32       = 1.0,
    lfo2_sync:    LfoSync   = .off,
    lfo2_retrig:  LfoRetrig = .free,
    lfo2_phase_offset: f32  = 0.0,
    lfo2_slew_ms: f32       = 0.0,
    lfo2_phase:   f32       = 0.0,
    lfo3_shape:   LfoShape  = .sine,
    lfo3_rate_hz: f32       = 1.0,
    lfo3_sync:    LfoSync   = .off,
    lfo3_retrig:  LfoRetrig = .free,
    lfo3_phase_offset: f32  = 0.0,
    lfo3_slew_ms: f32       = 0.0,
    lfo3_phase:   f32       = 0.0,
    /// Smoothed LFO output per slot, the state behind `lfo*_slew_ms`.
    /// Runtime state like the phases, not part of a Patch.
    lfo_slew_state: [3]f32 = .{ 0.0, 0.0, 0.0 },
    /// Set once a `.one_shot` slot has run its single cycle; cleared by the
    /// next note-on retrigger. Keeps the phase parked at 1.0 instead of
    /// wrapping. Runtime state, not part of a Patch.
    lfo_oneshot_done: [3]bool = .{ false, false, false },
    /// Held sample & hold level per LFO slot (0=LFO 1), redrawn on phase
    /// wrap. Runtime state like the phases, not part of a Patch.
    lfo_sh:       [3]f32   = .{ 0.0, 0.0, 0.0 },
    lfo_sh_rand:  u32      = 0x9E3779B9,
    /// Lorenz attractor state per LFO slot for the .chaos shape, integrated
    /// every block regardless of which shape is active (same "always
    /// maintain shape-specific state" precedent as lfo_sh). Runtime state,
    /// not part of a Patch. Starts off the origin (an unstable equilibrium
    /// of the Lorenz system) so it diverges into chaotic motion immediately
    /// instead of numerically sitting still.
    lfo_chaos: [3]ChaosState = .{ .{}, .{}, .{} },
    /// `.custom` shape's user-drawn waveform per LFO slot - see
    /// `LfoShapePoint`/`max_lfo_shape_points`. Patch data (persisted, copied
    /// via toPatch/applyPatch like mod_matrix), unlike lfo_sh/lfo_chaos
    /// above. Defaults to a flat line at 0 (silent modulation) so switching
    /// a shape to `.custom` fresh never surprises with unexpected motion.
    lfo_custom: [3][max_lfo_shape_points]LfoShapePoint = .{ default_lfo_custom_points, default_lfo_custom_points, default_lfo_custom_points },
    /// How many of each slot's `lfo_custom` entries are populated; the rest
    /// are unused padding, never read.
    lfo_custom_count: [3]u8 = .{ 2, 2, 2 },

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
    /// destination (a `mod_dest_ids` entry - an automatable param id or the
    /// virtual pitch/amp dests) with a bipolar depth. Evaluated per voice
    /// at block rate in processBlock; same-dest rows sum.
    mod_matrix: [max_mod_rows]ModRow = [_]ModRow{.{}} ** max_mod_rows,
    fx_mod_bus: FxModBus = .{},
    /// MIDI mod wheel (CC1), 0..1 - the `.wheel` matrix source.
    mod_wheel: f32 = 0.0,
    /// Per-trigger modulation state. Values are copied into each voice so
    /// later notes cannot change modulation under notes already sounding.
    mod_rand_state: u32 = 0xA341316C,
    mod_alternate: bool = false,

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
    // Legacy insert-FX params. The synth stopped processing effects when the
    // rack's modular chain took over (see rack.zig): nothing here reaches
    // audio any more. They survive for two reasons - `migrateSynthFx`
    // (persist.zig) turns them into rack units when a pre-chain project or a
    // factory preset loads, and their ids stay legal mod-matrix
    // destinations, which the matrix routes to the *rack* unit that owns the
    // param via `fx_instance_id`. Base values live here (not on any state
    // struct) so applyPatch/toPatch keep picking them up by field name.
    // zig fmt: off
    fx_gate_on:          bool = false,
    fx_gate_threshold_db: f32 = -50.0,
    fx_gate_attack_ms:   f32  = 1.0,
    fx_gate_release_ms:  f32  = 100.0,
    fx_eq_on:            bool = false,
    fx_eq_low_freq:      f32  = 150.0,
    fx_eq_low_gain_db:   f32  = 0.0,
    fx_eq_mid_freq:      f32  = 1000.0,
    fx_eq_mid_gain_db:   f32  = 0.0,
    fx_eq_mid_q:         f32  = 0.7,
    fx_eq_high_freq:     f32  = 6000.0,
    fx_eq_high_gain_db:  f32  = 0.0,
    fx_comp_on:          bool = false,
    fx_comp_threshold_db: f32 = -18.0,
    fx_comp_ratio:       f32  = 4.0,
    fx_comp_attack_ms:   f32  = 10.0,
    fx_comp_release_ms:  f32  = 80.0,
    fx_comp_makeup_db:   f32  = 0.0,
    fx_mb_on:            bool = false,
    fx_mb_xover_lo:      f32  = 200.0,
    fx_mb_xover_hi:      f32  = 2000.0,
    fx_mb_attack_ms:     f32  = 10.0,
    fx_mb_release_ms:    f32  = 80.0,
    fx_mb_style:         MbStyle = .classic,
    fx_mb_mix:           f32  = 1.0,
    fx_mb_low_threshold_db:  f32 = -20.0,
    fx_mb_low_ratio:         f32 = 3.0,
    fx_mb_low_makeup_db:     f32 = 0.0,
    fx_mb_mid_threshold_db:  f32 = -18.0,
    fx_mb_mid_ratio:         f32 = 4.0,
    fx_mb_mid_makeup_db:     f32 = 0.0,
    fx_mb_high_threshold_db: f32 = -16.0,
    fx_mb_high_ratio:        f32 = 3.0,
    fx_mb_high_makeup_db:    f32 = 0.0,
    fx_ott_on:           bool = false,
    fx_ott_depth:        f32  = 1.0,
    fx_ott_time:         f32  = 1.0,
    fx_ott_gain_in_db:   f32  = 0.0,
    fx_ott_gain_out_db:  f32  = 0.0,
    fx_dist_on:          bool = false,
    fx_dist_drive_db:    f32  = 12.0,
    fx_dist_mix:         f32  = 1.0,
    fx_crush_on:         bool = false,
    fx_crush_bits:       f32  = 8.0,
    fx_crush_rate:       f32  = 4.0,
    fx_crush_mix:        f32  = 1.0,
    fx_chorus_on:        bool = false,
    fx_chorus_rate_hz:   f32  = 0.8,
    fx_chorus_depth_ms:  f32  = 4.0,
    fx_chorus_mix:       f32  = 0.5,
    fx_flanger_on:       bool = false,
    fx_flanger_rate_hz:  f32  = 0.3,
    fx_flanger_depth:    f32  = 0.7,
    fx_flanger_feedback: f32  = 0.5,
    fx_flanger_mix:      f32  = 0.5,
    fx_tape_on:            bool = false,
    fx_tape_wow_rate_hz:   f32  = 0.6,
    fx_tape_wow_depth:     f32  = 0.4,
    fx_tape_flutter_rate_hz: f32 = 8.0,
    fx_tape_flutter_depth: f32  = 0.25,
    fx_tape_mix:           f32  = 1.0,
    fx_phaser_on:        bool = false,
    fx_phaser_rate_hz:   f32  = 0.4,
    fx_phaser_depth:     f32  = 0.9,
    fx_phaser_feedback:  f32  = 0.5,
    fx_phaser_mix:       f32  = 0.5,
    fx_freq_shift_on:    bool = false,
    fx_freq_shift_hz:    f32  = 0.0,
    fx_freq_shift_mix:   f32  = 1.0,
    fx_delay_on:         bool = false,
    fx_delay_time_s:     f32  = 0.25,
    fx_delay_feedback:   f32  = 0.3,
    fx_delay_mix:        f32  = 0.3,
    fx_reverb_on:        bool = false,
    fx_reverb_room:      f32  = 0.6,
    fx_reverb_damp:      f32  = 0.4,
    fx_reverb_mix:       f32  = 0.3,
    // zig fmt: on
    /// ids, never written directly by the editor.
    fx_order: [14]FxUnitKind = default_fx_order,
    /// Project transport, for the tempo-synced LFO/arp divisions. Null on a
    /// bare synth (tests, `main.zig`'s standalone instance) - every sync
    /// path falls back to plain Hz then. Set through `attachTransport` after
    /// the synth lands in its heap-allocated Rack, same lifetime rule
    /// DrumMachine and Slicer already rely on. Runtime wiring, not a Patch
    /// field: `dupe` copies the pointer because the Transport outlives every
    /// rack that points at it.
    transport: ?*const Transport = null,

    // ── ARP ─────────────────────────────────────────────────────────────────
    // A step sequencer sitting in front of note triggering, one step per
    // `arp_rate_hz` or per `arp_sync` division of the project tempo.
    // While on, noteOn/noteOff fully bypass voice_mode dispatch - see their
    // own arp branches - and the step engine drives voices itself.
    // zig fmt: off
    arp_on:      bool    = false,
    arp_mode:    ArpMode = .up,
    /// Tempo division for one arp step, overriding `arp_rate_hz` - see
    /// `LfoSync`.
    arp_sync:    LfoSync = .off,
    /// Octave range above the played note(s), 1..max_arp_octaves. Ignored
    /// by `.chord` mode (it always retriggers the held notes as played).
    arp_octaves: u8      = 1,
    /// Steps per second.
    arp_rate_hz: f32     = 8.0,
    /// Fraction of one step a triggered note stays gated on, 0..1.
    arp_gate:    f32     = 0.5,
    /// Keep cycling the last-played notes after every key releases, until a
    /// fresh note (pressed from zero held keys) replaces them.
    arp_hold:    bool    = false,

    // Runtime state only - not part of Patch, same as held_notes/lfo_phase.
    arp_phase:       f32     = 0.0,
    arp_index:       usize   = 0,
    arp_gate_open:   bool    = false,
    arp_rand:        u32     = 0x2545F491,
    /// Notes currently in rotation: mirrors held_notes while any key is
    /// down, frozen at its last value across a release when arp_hold is on.
    arp_latch_notes: [16]u7  = [_]u7{0} ** 16,
    arp_latch_vel:   [16]f32 = [_]f32{0} ** 16,
    arp_latch_count: u8      = 0,
    /// On->off edge detector so turning the arp off mid-note releases
    /// whatever it was sounding instead of leaving it stuck (see
    /// processBlock's arp block).
    arp_was_on:      bool    = false,
    // zig fmt: on

    // ── ENV 3 ───────────────────────────────────────────────────────────────
    // A third ADSR with no fixed destination - a pure mod-matrix source
    // (.env3), same per-voice stage machine as amp/filter envelopes but
    // routed entirely through matrix rows. Trailing ids (122-125, after
    // ARP) per the append-after-the-max rule.
    // zig fmt: off
    env3_attack_s:  f32 = 0.005,
    env3_decay_s:   f32 = 0.3,
    env3_sustain:   f32 = 0.0,
    env3_release_s: f32 = 0.3,
    /// Segment curvature: -1 logarithmic, 0 linear, +1 exponential.
    env3_curve:     f32 = 0.0,
    // zig fmt: on

    /// Index of the most recently triggered voice: the FX destinations are
    /// global (post-mix), so their one matrix evaluation per block reads
    /// the per-voice sources (envs, velocity, keytrack) from this voice.
    newest_voice: u8 = 0,
    next_voice_id: u64 = 0,

    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,

    pub const max_voices = 16;
    pub const max_unison = 16;
    /// Hard cap on simultaneous oscillators across all active voices.
    /// With e.g. 8 active voices, unison is capped at 4 each → 32 total.
    pub const osc_budget: usize = 32;

    pub const max_mod_rows = 32;
    const legacy_mod_rows = 8;
    const legacy_mod_param_base: u16 = 59;
    const extra_mod_param_base: u16 = 301;
    pub const max_arp_octaves = 4;
    /// Virtual matrix destinations that aren't editor params: note pitch
    /// (amt = octaves) and voice amplitude (gain factor 1 + amt). Chosen
    /// well above the real param-id space so they can never collide.
    pub const dest_pitch: u16 = 254;
    pub const dest_amp: u16 = 255;

    /// One mod-matrix row. `dest` is a `mod_dest_ids` entry; `depth` is
    /// bipolar, scaled by the dest param's full range (linear params), or
    /// ±4 octaves (cutoffs), ±1 octave (pitch), ±1x gain (amp) at |1|.
    ///
    /// `unipolar` folds a bipolar source's -1..1 swing into 0..1, so the row
    /// only ever pushes the destination one way from where its knob sits
    /// instead of straddling it - the difference between a cutoff wobble
    /// that sweeps up from 400 Hz and one centred on it. A no-op on sources
    /// that are already unipolar (see `ModSource.isBipolar`), so it's safe
    /// to leave set while auditioning different sources on a row.
    pub const ModRow = struct {
        source: ModSource = .none,
        dest: u16 = 21,
        depth: f32 = 0.0,
        unipolar: bool = false,
        fx_instance_id: u32 = 0,
    };

    /// Flat id space for the per-row `unipolar` toggles: row `k` at
    /// `mod_unipolar_id_base + k`. A separate block rather than a fourth
    /// field inside the 59-82 band, because that band is packed 3-per-row
    /// and widening it in place would renumber every depth id that saved
    /// automation lanes already point at.
    pub const mod_unipolar_id_base: u16 = 269;

    pub const MatrixParamAddr = struct { row: u8, field: u2 };

    pub fn matrixParamId(row: usize, field: u2) u16 {
        std.debug.assert(row < max_mod_rows and field < 3);
        const base = if (row < legacy_mod_rows)
            legacy_mod_param_base + row * 3
        else
            extra_mod_param_base + (row - legacy_mod_rows) * 3;
        return @intCast(base + field);
    }

    pub fn matrixParamAddr(id: u16) ?MatrixParamAddr {
        const rel: usize = if (id >= legacy_mod_param_base and id < legacy_mod_param_base + legacy_mod_rows * 3)
            id - legacy_mod_param_base
        else if (id >= extra_mod_param_base and id < extra_mod_param_base + (max_mod_rows - legacy_mod_rows) * 3)
            legacy_mod_rows * 3 + id - extra_mod_param_base
        else
            return null;
        return .{ .row = @intCast(rel / 3), .field = @intCast(rel % 3) };
    }

    /// Automatable params that aren't legal matrix destinations: the global
    /// LFO rate/phase/slew controls (an LFO's own motion is set on its row,
    /// not modulated - and they're read before `evalMatrix` runs, so a row
    /// targeting one would apply a block late anyway), the matrix's own row
    /// depths (no self-modulation), the macro knobs (already fan out to
    /// every dest their own rows target - automating one would double-apply
    /// through rows that read it), and arp rate/gate (toggle-adjacent
    /// controls, not motion-worthy targets). Automation lanes still reach
    /// all of these; only matrix rows are barred.
    const mod_dest_excluded_ids = [_]u16{
        29,  61,  64,  67,  70,  73,  76, 79, 82, 96, 98, 99, 100, 101, 102, 119, 120,
        262, 263, 264, 265, 266, 267,
    };

    fn isModDestExcluded(id: u16) bool {
        if (matrixParamAddr(id)) |addr| if (addr.field == 2) return true;
        for (mod_dest_excluded_ids) |e| if (e == id) return true;
        return false;
    }

    fn modDestCount() usize {
        @setEvalBranchQuota(20000);
        var n: usize = 2; // dest_pitch, dest_amp
        for (automatable_params) |p| {
            if (!isModDestExcluded(p.id)) n += 1;
        }
        return n;
    }

    /// Legal matrix destinations: every `automatable_params` entry not in
    /// `mod_dest_excluded_ids`, consumed per-voice or once per block by
    /// `processBlock`'s FX pass, plus the two virtual dests. Derived instead
    /// of hand-duplicated - the old hand-kept list once let id 187 (WT POS
    /// C) exist in `automatable_params` but never make it into the matrix,
    /// silently unreachable from the mod-dest picker.
    pub const mod_dest_ids: [modDestCount()]u16 = blk: {
        @setEvalBranchQuota(20000);
        var out: [modDestCount()]u16 = undefined;
        var i: usize = 0;
        for (automatable_params) |p| {
            if (isModDestExcluded(p.id)) continue;
            out[i] = p.id;
            i += 1;
        }
        out[i] = dest_pitch;
        i += 1;
        out[i] = dest_amp;
        i += 1;
        break :blk out;
    };

    pub fn modDestLabel(dest: u16) []const u8 {
        return switch (dest) {
            // zig fmt: off
            dest_pitch => "PITCH",
            dest_amp   => "AMP",
            // zig fmt: on
            else => if (findAutomatableParam(dest)) |p| p.label else "?",
        };
    }

    pub fn modDestIndex(dest: u16) ?usize {
        for (mod_dest_ids, 0..) |d, i| if (d == dest) return i;
        return null;
    }

    /// Fold the retired fixed mod routes (filter-env amount, LFO target +
    /// depth) into equivalent matrix rows - the load-time migration for
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
    /// Voice's size - keep it modest, PolySynth is embedded by value in Rack.
    const comb_len: usize = 512;

    /// One vowel's first 3 formants: center frequency, bandwidth, relative
    /// amplitude (dB, F1 = 0 dB reference). Source: the Csound Book bass-
    /// voice formant appendix (widely reused for musical vowel filters),
    /// via https://pbat.ch/sndkit/vowel/.
    const FormantVowel = struct { f: [3]f32, bw: [3]f32, amp_db: [3]f32 };
    // zig fmt: off
    const formant_table = [5]FormantVowel{
        .{ .f = .{ 600, 1040, 2250 }, .bw = .{ 60, 70, 110 }, .amp_db = .{   0,  -7,  -9 } }, // a
        .{ .f = .{ 400, 1620, 2400 }, .bw = .{ 40, 80, 100 }, .amp_db = .{   0, -12,  -9 } }, // e
        .{ .f = .{ 250, 1750, 2600 }, .bw = .{ 60, 90, 100 }, .amp_db = .{   0, -30, -16 } }, // i
        .{ .f = .{ 400,  750, 2400 }, .bw = .{ 40, 80, 100 }, .amp_db = .{   0, -11, -21 } }, // o
        .{ .f = .{ 350,  600, 2400 }, .bw = .{ 40, 80, 100 }, .amp_db = .{   0, -20, -32 } }, // u
    };
    // zig fmt: on

    /// Per-formant state-variable-filter coefficient: the SVF frequency
    /// coefficient, damping (1/Q), and linear output gain.
    const FormantCoeffs = struct {
        // zig fmt: off
        f1: f32 = 0.0, damp1: f32 = 0.0, gain1: f32 = 0.0,
        f2: f32 = 0.0, damp2: f32 = 0.0, gain2: f32 = 0.0,
        f3: f32 = 0.0, damp3: f32 = 0.0, gain3: f32 = 0.0,
        // zig fmt: on
    };

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
        // formant: 3 parallel resonator coefficients (vowel-interpolated)
        formant: FormantCoeffs = .{},
    };

    /// Per-channel state for one filter slot, covering every filter model:
    /// biquad history, the ladder's 4 one-pole stages, and the comb's delay
    /// ring. `diode` reuses the ladder's s1-s4. `formant` reuses x1/x2,
    /// y1/y2, s1/s2 as 3 independent 2-state SVF resonators (s3/s4 unused).
    /// Only the active model's fields advance; switching models mid-note
    /// picks up whatever stale state the new model left behind, which
    /// decays within a few hundred samples.
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
        // ENV 3: free-assignable, no fixed destination - pure matrix source.
        env3:   f32   = 0.0,
        stage3: Stage = .attack,
        // zig fmt: on
        /// Filter state per slot per channel (same coefficients L/R,
        /// independent histories). Filter 2 keeps its own state even in
        /// series mode, since it filters filter 1's output.
        f1_l: FilterState = .{},
        f1_r: FilterState = .{},
        f2_l: FilterState = .{},
        f2_r: FilterState = .{},
        // Glide: current log2(freq) sliding toward log2(noteToFreq(note)).
        glide_log: f32 = 0.0,
        /// log2(freq) change per sample. 0 when glide is off or complete.
        glide_rate: f32 = 0.0,
        // Sub oscillator
        sub_phase: f32 = 0.0,
        // Noise oscillator - xorshift32 (must never be 0)
        noise_rand_state: u32 = 1,
        random: f32 = 0.0,
        alternate: f32 = -1.0,
        noise_lp: f32 = 0.0,
        /// Per-sample ramps for A, B, C, sub, noise, then final output.
        mix_gain: [5]f32 = @splat(0.0),
        out_gain: f32 = 0.0,
        id: u64 = 0,
    };

    /// Point the tempo-synced LFO/arp divisions at the project transport.
    /// Call once the synth sits in its heap-allocated Rack, like
    /// `ClapPlugin.attachTransport` - before that the synth is still being
    /// moved by value and the pointer would outlive nothing useful. Leaving
    /// it unattached is safe: every sync path falls back to plain Hz.
    pub fn attachTransport(self: *PolySynth, transport: *const Transport) void {
        self.transport = transport;
    }

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !PolySynth {
        var wt = try wavetable.loadDefault(allocator);
        errdefer wavetable.deinit(&wt, allocator);
        var osc_b_wt = try wavetable.loadDefault(allocator);
        errdefer wavetable.deinit(&osc_b_wt, allocator);
        var osc_c_wt = try wavetable.loadDefault(allocator);
        errdefer wavetable.deinit(&osc_c_wt, allocator);
        return .{
            .sample_rate = @floatFromInt(sample_rate),
            .allocator = allocator,
            .wt = wt,
            .osc_b_wt = osc_b_wt,
            .osc_c_wt = osc_c_wt,
        };
    }

    pub fn deinit(self: *PolySynth) void {
        wavetable.deinit(&self.wt, self.allocator);
        wavetable.deinit(&self.osc_b_wt, self.allocator);
        wavetable.deinit(&self.osc_c_wt, self.allocator);
    }

    /// Deep-copies the three owned wavetables; everything else (params,
    /// voices) is plain data and copies fine by value. Same shape as
    /// `Sampler.dupe`.
    pub fn dupe(self: *const PolySynth) !PolySynth {
        var copy = self.*;
        copy.wt = try wavetable.dupe(self.wt, self.allocator);
        errdefer wavetable.deinit(&copy.wt, self.allocator);
        copy.osc_b_wt = try wavetable.dupe(self.osc_b_wt, self.allocator);
        errdefer wavetable.deinit(&copy.osc_b_wt, self.allocator);
        copy.osc_c_wt = try wavetable.dupe(self.osc_c_wt, self.allocator);
        return copy;
    }

    /// Which oscillator's wavetable slot a load/persistence op targets.
    pub const OscSlot = enum { a, b, c };

    /// Replaces one oscillator's wavetable with `wav_bytes` (a whole WAV
    /// file's contents, reshaped into `wavetable.frame_len`-sample frames)
    /// and marks it user-imported so persistence sidecars it. Frees the
    /// slot's previous table only after the new one parses successfully,
    /// so a bad file leaves the old table intact.
    pub fn loadWavetable(self: *PolySynth, slot: OscSlot, wav_bytes: []const u8) !void {
        const new_table = try wavetable.fromWav(self.allocator, wav_bytes);
        switch (slot) {
            .a => {
                wavetable.deinit(&self.wt, self.allocator);
                self.wt = new_table;
                self.wt_user = true;
                self.wt_bundled = null;
            },
            .b => {
                wavetable.deinit(&self.osc_b_wt, self.allocator);
                self.osc_b_wt = new_table;
                self.osc_b_wt_user = true;
                self.osc_b_wt_bundled = null;
            },
            .c => {
                wavetable.deinit(&self.osc_c_wt, self.allocator);
                self.osc_c_wt = new_table;
                self.osc_c_wt_user = true;
                self.osc_c_wt_bundled = null;
            },
        }
    }

    /// Select bundled tables transactionally. Null keeps current slot, which
    /// lets user presets remain independent from imported wavetable audio.
    pub fn selectBundledWavetables(self: *PolySynth, a: ?BundledWavetable, b: ?BundledWavetable, c: ?BundledWavetable) !void {
        var new_a: ?Wavetable = if (a) |kind| try wavetable.loadBundled(self.allocator, kind) else null;
        errdefer if (new_a) |*table| wavetable.deinit(table, self.allocator);
        var new_b: ?Wavetable = if (b) |kind| try wavetable.loadBundled(self.allocator, kind) else null;
        errdefer if (new_b) |*table| wavetable.deinit(table, self.allocator);
        var new_c: ?Wavetable = if (c) |kind| try wavetable.loadBundled(self.allocator, kind) else null;
        errdefer if (new_c) |*table| wavetable.deinit(table, self.allocator);
        if (new_a) |table| {
            wavetable.deinit(&self.wt, self.allocator);
            self.wt = table;
            self.wt_user = false;
            self.wt_bundled = a;
            new_a = null;
        }
        if (new_b) |table| {
            wavetable.deinit(&self.osc_b_wt, self.allocator);
            self.osc_b_wt = table;
            self.osc_b_wt_user = false;
            self.osc_b_wt_bundled = b;
            new_b = null;
        }
        if (new_c) |table| {
            wavetable.deinit(&self.osc_c_wt, self.allocator);
            self.osc_c_wt = table;
            self.osc_c_wt_user = false;
            self.osc_c_wt_bundled = c;
            new_c = null;
        }
    }

    pub const device = dsp.deviceOf(@This());

    pub fn noteToFreq(note: u7) f32 {
        return midi.noteToFreq(note);
    }

    /// A full synth patch: every parameter `adjustParam`/`applyCC` can touch,
    /// minus per-instance state (sample_rate, voices, held-note stack, pitch
    /// bend, LFO phase). Presets in `synth_presets.zig` are just values of
    /// this type - no audio is rendered or embedded to define one.
    pub const Patch = struct {
        waveform: Waveform = .saw,
        /// Optional bundled table choice. Null preserves imported/current audio.
        wt_table: ?BundledWavetable = null,
        pulse_width: f32 = 0.5,
        detune_cents: f32 = 0.0,
        unison: u8 = 1,
        unison_detune: f32 = 15.0,
        unison_spread: f32 = 0.0,
        unison_mode: UnisonMode = .spread,
        warp_mode: WarpMode = .none,
        warp_amount: f32 = 0.0,
        wt_pos: f32 = 0.0,

        osc_b_on: bool = false,
        osc_b_waveform: Waveform = .saw,
        osc_b_wt_table: ?BundledWavetable = null,
        osc_b_pulse_width: f32 = 0.5,
        osc_b_semi: f32 = 0.0,
        osc_b_detune_cents: f32 = 0.0,
        osc_b_level: f32 = 1.0,
        osc_b_unison: u8 = 1,
        osc_b_unison_detune: f32 = 15.0,
        osc_b_unison_mode: UnisonMode = .spread,
        osc_b_warp_mode: WarpMode = .none,
        osc_b_warp_amount: f32 = 0.0,
        osc_b_wt_pos: f32 = 0.0,

        osc_c_on: bool = false,
        osc_c_waveform: Waveform = .saw,
        osc_c_wt_table: ?BundledWavetable = null,
        osc_c_pulse_width: f32 = 0.5,
        osc_c_semi: f32 = 0.0,
        osc_c_detune_cents: f32 = 0.0,
        osc_c_level: f32 = 1.0,
        osc_c_unison: u8 = 1,
        osc_c_unison_detune: f32 = 15.0,
        osc_c_unison_mode: UnisonMode = .spread,
        osc_c_wt_pos: f32 = 0.0,

        attack_s: f32 = 0.005,
        decay_s: f32 = 0.08,
        sustain: f32 = 0.7,
        release_s: f32 = 0.25,
        env_curve: f32 = 0.0,

        filter_type: FilterType = .lp,
        filter_cutoff: f32 = 18_000.0,
        filter_res: f32 = 0.0,
        filter_drive: f32 = 1.0,

        filter2_on: bool = false,
        filter2_type: FilterType = .lp,
        filter2_cutoff: f32 = 18_000.0,
        filter2_res: f32 = 0.0,
        filter2_drive: f32 = 1.0,
        filter_routing: FilterRouting = .series,

        fenv_attack_s: f32 = 0.005,
        fenv_decay_s: f32 = 0.5,
        fenv_sustain: f32 = 0.0,
        fenv_release_s: f32 = 0.3,
        fenv_curve: f32 = 0.0,

        lfo_shape: LfoShape = .sine,
        lfo_rate_hz: f32 = 1.0,
        lfo_sync: LfoSync = .off,
        lfo_retrig: LfoRetrig = .free,
        lfo_phase_offset: f32 = 0.0,
        lfo_slew_ms: f32 = 0.0,

        lfo2_shape: LfoShape = .sine,
        lfo2_rate_hz: f32 = 1.0,
        lfo2_sync: LfoSync = .off,
        lfo2_retrig: LfoRetrig = .free,
        lfo2_phase_offset: f32 = 0.0,
        lfo2_slew_ms: f32 = 0.0,
        lfo3_shape: LfoShape = .sine,
        lfo3_rate_hz: f32 = 1.0,
        lfo3_sync: LfoSync = .off,
        lfo3_retrig: LfoRetrig = .free,
        lfo3_phase_offset: f32 = 0.0,
        lfo3_slew_ms: f32 = 0.0,
        lfo_custom: [3][max_lfo_shape_points]LfoShapePoint = .{ default_lfo_custom_points, default_lfo_custom_points, default_lfo_custom_points },
        lfo_custom_count: [3]u8 = .{ 2, 2, 2 },

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

        fx_gate_on: bool = false,
        fx_gate_threshold_db: f32 = -50.0,
        fx_gate_attack_ms: f32 = 1.0,
        fx_gate_release_ms: f32 = 100.0,
        fx_eq_on: bool = false,
        fx_eq_low_freq: f32 = 150.0,
        fx_eq_low_gain_db: f32 = 0.0,
        fx_eq_mid_freq: f32 = 1000.0,
        fx_eq_mid_gain_db: f32 = 0.0,
        fx_eq_mid_q: f32 = 0.7,
        fx_eq_high_freq: f32 = 6000.0,
        fx_eq_high_gain_db: f32 = 0.0,
        fx_comp_on: bool = false,
        fx_comp_threshold_db: f32 = -18.0,
        fx_comp_ratio: f32 = 4.0,
        fx_comp_attack_ms: f32 = 10.0,
        fx_comp_release_ms: f32 = 80.0,
        fx_comp_makeup_db: f32 = 0.0,
        fx_mb_on: bool = false,
        fx_mb_xover_lo: f32 = 200.0,
        fx_mb_xover_hi: f32 = 2000.0,
        fx_mb_attack_ms: f32 = 10.0,
        fx_mb_release_ms: f32 = 80.0,
        fx_mb_style: MbStyle = .classic,
        fx_mb_mix: f32 = 1.0,
        fx_mb_low_threshold_db: f32 = -20.0,
        fx_mb_low_ratio: f32 = 3.0,
        fx_mb_low_makeup_db: f32 = 0.0,
        fx_mb_mid_threshold_db: f32 = -18.0,
        fx_mb_mid_ratio: f32 = 4.0,
        fx_mb_mid_makeup_db: f32 = 0.0,
        fx_mb_high_threshold_db: f32 = -16.0,
        fx_mb_high_ratio: f32 = 3.0,
        fx_mb_high_makeup_db: f32 = 0.0,
        fx_ott_on: bool = false,
        fx_ott_depth: f32 = 1.0,
        fx_ott_time: f32 = 1.0,
        fx_ott_gain_in_db: f32 = 0.0,
        fx_ott_gain_out_db: f32 = 0.0,
        fx_dist_on: bool = false,
        fx_dist_drive_db: f32 = 12.0,
        fx_dist_mix: f32 = 1.0,
        fx_crush_on: bool = false,
        fx_crush_bits: f32 = 8.0,
        fx_crush_rate: f32 = 4.0,
        fx_crush_mix: f32 = 1.0,
        fx_chorus_on: bool = false,
        fx_chorus_rate_hz: f32 = 0.8,
        fx_chorus_depth_ms: f32 = 4.0,
        fx_chorus_mix: f32 = 0.5,
        fx_flanger_on: bool = false,
        fx_flanger_rate_hz: f32 = 0.3,
        fx_flanger_depth: f32 = 0.7,
        fx_flanger_feedback: f32 = 0.5,
        fx_flanger_mix: f32 = 0.5,
        fx_tape_on: bool = false,
        fx_tape_wow_rate_hz: f32 = 0.6,
        fx_tape_wow_depth: f32 = 0.4,
        fx_tape_flutter_rate_hz: f32 = 8.0,
        fx_tape_flutter_depth: f32 = 0.25,
        fx_tape_mix: f32 = 1.0,
        fx_phaser_on: bool = false,
        fx_phaser_rate_hz: f32 = 0.4,
        fx_phaser_depth: f32 = 0.9,
        fx_phaser_feedback: f32 = 0.5,
        fx_phaser_mix: f32 = 0.5,
        fx_freq_shift_on: bool = false,
        fx_freq_shift_hz: f32 = 0.0,
        fx_freq_shift_mix: f32 = 1.0,
        fx_delay_on: bool = false,
        fx_delay_time_s: f32 = 0.25,
        fx_delay_feedback: f32 = 0.3,
        fx_delay_mix: f32 = 0.3,
        fx_reverb_on: bool = false,
        fx_reverb_room: f32 = 0.6,
        fx_reverb_damp: f32 = 0.4,
        fx_reverb_mix: f32 = 0.3,
        fx_order: [14]FxUnitKind = default_fx_order,

        arp_on: bool = false,
        arp_mode: ArpMode = .up,
        arp_octaves: u8 = 1,
        arp_rate_hz: f32 = 8.0,
        arp_sync: LfoSync = .off,
        arp_gate: f32 = 0.5,
        arp_hold: bool = false,

        env3_attack_s: f32 = 0.005,
        env3_decay_s: f32 = 0.3,
        env3_sustain: f32 = 0.0,
        env3_release_s: f32 = 0.3,
        env3_curve: f32 = 0.0,
    };

    /// Load a patch onto this synth. Field-by-field so per-instance state
    /// (sample_rate, voices, glide/held-note tracking) is untouched - notes
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

    pub fn applyPatchWithWavetables(self: *PolySynth, patch: Patch) !void {
        try self.selectBundledWavetables(patch.wt_table, patch.osc_b_wt_table, patch.osc_c_wt_table);
        self.applyPatch(patch);
    }

    /// The inverse of `applyPatch`: snapshot this synth's current params into
    /// a `Patch` (e.g. to save a hand-tuned sound as a reusable preset - see
    /// `tui/user_presets.zig`). The legacy carrier fields stay at their
    /// defaults, so a round-trip never re-triggers migration.
    pub fn toPatch(self: *const PolySynth) Patch {
        var patch: Patch = .{};
        inline for (@typeInfo(Patch).@"struct".fields) |f| {
            if (@hasField(PolySynth, f.name)) {
                @field(patch, f.name) = @field(self, f.name);
            }
        }
        patch.wt_table = self.wt_bundled;
        patch.osc_b_wt_table = self.osc_b_wt_bundled;
        patch.osc_c_wt_table = self.osc_c_wt_bundled;
        return patch;
    }

    pub fn noteOn(self: *PolySynth, note: u7, velocity: f32) void {
        if (self.arp_on) {
            const was_empty = self.held_count == 0;
            self.pushHeld(note, velocity);
            self.arpUpdateLatch();
            // Fresh press from silence: trigger immediately and restart the
            // step clock, rather than waiting out whatever phase happened
            // to be left over (also how a hold-latched arp gets replaced).
            if (was_empty) {
                self.arp_phase = 0.0;
                self.arp_index = 0;
                self.arpFireStep();
            }
            return;
        }
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
        if (self.arp_on) {
            self.popHeld(note);
            if (self.held_count > 0) {
                self.arpUpdateLatch();
            } else if (!self.arp_hold) {
                self.arpReleaseActive();
                self.arp_latch_count = 0;
                self.arp_index = 0;
            }
            return;
        }
        switch (self.voice_mode) {
            .poly => {
                var oldest: ?*Voice = null;
                for (&self.voices) |*v| {
                    if (!v.active or v.note != note or v.stage == .release) continue;
                    if (oldest == null or v.id < oldest.?.id) oldest = v;
                }
                if (oldest) |v| {
                    v.stage = .release;
                    v.stage2 = .release;
                    v.stage3 = .release;
                }
            },
            .mono => {
                self.popHeld(note);
                if (self.held_count > 0) {
                    const i = self.held_count - 1;
                    self.noteOnMono(self.held_notes[i], self.held_velocities[i], true);
                } else {
                    // Not just voices[0]: mono/legato only ever *trigger*
                    // into slot 0, but switching voice_mode away from .poly
                    // mid-chord (a live param nudge, or auditioning a preset
                    // that sets voice_mode - see PolySynth.applyPatch) can
                    // leave poly-triggered voices sitting in other slots
                    // with no held_notes entry to route their note-off
                    // through. Checking only slot 0 stranded those voices
                    // forever in .attack/.decay/.sustain - a stuck note.
                    for (&self.voices) |*v| {
                        // zig fmt: off
                        if (v.active and v.note == note) { v.stage = .release; v.stage2 = .release; v.stage3 = .release; }
                    }
                }
            },
            .legato => {
                self.popHeld(note);
                if (self.held_count > 0) {
                    const i = self.held_count - 1;
                    self.noteOnMono(self.held_notes[i], self.held_velocities[i], false);
                } else {
                    // Same stray-voice hazard as .mono above. Slot 0 keeps
                    // its original unconditional release (legato's own
                    // voice may be mid-glide away from the exact pitch
                    // being released, so it was never note-matched); any
                    // other active voice is a poly-triggered stray from
                    // before a mid-chord mode switch, released only if it
                    // actually matches this note so an unrelated still-held
                    // poly note doesn't get cut short too.
                    for (&self.voices, 0..) |*v, i| {
                        // zig fmt: off
                        if (v.active and (i == 0 or v.note == note)) { v.stage = .release; v.stage2 = .release; v.stage3 = .release; }
                    }
                }
            },
        }
    }

    /// Builds a freshly-triggered `Voice` for `note`/`velocity`, gliding
    /// from `prev_log` (the outgoing voice's log-freq) if `was_active` and
    /// glide is on, else starting flat at the target pitch - shared by
    /// `noteOnPoly` (always takes this path) and `noteOnMono`'s
    /// retrigger/first-note path (its legato path bypasses this entirely,
    /// updating pitch on the still-running voice instead).
    ///
    /// Also where `.key`/`.one_shot` LFOs restart: this is exactly the set
    /// of note-ons that reset the amplitude envelope, so a legato slide
    /// leaves a running growl alone while every real new note re-arms it.
    fn triggerVoice(self: *PolySynth, note: u7, velocity: f32, was_active: bool, prev_log: f32) Voice {
        self.next_voice_id +%= 1;
        self.retriggerLfos();
        self.mod_alternate = !self.mod_alternate;
        const target_log = std.math.log2(noteToFreq(note));
        const start_log = if (was_active and self.glide_s > 0.0) prev_log else target_log;
        return .{
            .active           = true,
            .note             = note,
            .velocity         = velocity,
            .stage            = .attack,
            .stage2           = .attack,
            .stage3           = .attack,
            .glide_log   = start_log,
            .glide_rate       = if (was_active and self.glide_s > 0.0)
                (target_log - start_log) / @max(self.glide_s * self.sample_rate, 1.0)
            else 0.0,
            .noise_rand_state = (@as(u32, note) *% 0x9E3779B9) | 1,
            .random           = nextNoise(&self.mod_rand_state),
            .alternate        = if (self.mod_alternate) 1.0 else -1.0,
            .id               = self.next_voice_id,
        };
    }

    fn noteOnPoly(self: *PolySynth, note: u7, velocity: f32) void {
        self.newest_voice = self.allocVoice();
        const v = &self.voices[self.newest_voice];
        v.* = self.triggerVoice(note, velocity, v.active, v.glide_log);
    }

    /// Activate or update the single mono/legato voice.
    /// retrigger=true → reset amplitude envelope from attack.
    fn noteOnMono(self: *PolySynth, note: u7, velocity: f32, retrigger: bool) void {
        self.newest_voice = 0;
        const v          = &self.voices[0];
        const was_active = v.active;
        const target_log = std.math.log2(noteToFreq(note));
        if (retrigger or !was_active) {
            v.* = self.triggerVoice(note, velocity, was_active, v.glide_log);
        } else {
            // Legato: update pitch only, envelope continues.
            v.note = note;
            if (self.glide_s > 0.0) {
                v.glide_rate = (target_log - v.glide_log) /
                    @max(self.glide_s * self.sample_rate, 1.0);
            } else {
                v.glide_log = target_log;
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

    fn arpUpdateLatch(self: *PolySynth) void {
        self.arp_latch_count = self.held_count;
        @memcpy(self.arp_latch_notes[0..self.held_count], self.held_notes[0..self.held_count]);
        @memcpy(self.arp_latch_vel[0..self.held_count], self.held_velocities[0..self.held_count]);
    }

    /// Release every currently active voice (there's nothing else sounding
    /// while the arp owns note triggering, so this is always "close the
    /// arp's own gate", never a stray note belonging to something else).
    fn arpReleaseActive(self: *PolySynth) void {
        for (&self.voices) |*v| {
            if (v.active and v.stage != .release) {
                // zig fmt: off
                v.stage  = .release;
                // zig fmt: on
                v.stage2 = .release;
            }
        }
    }

    /// Sort `arp_latch_notes[0..arp_latch_count]` ascending by pitch (unless
    /// `.played`, which keeps press order) and expand across `arp_octaves`,
    /// lowest octave first. Notes that shift past MIDI's range are dropped
    /// rather than clamped, so the sequence's rhythm stays even instead of
    /// piling extra hits on the boundary note.
    fn arpBuildSeq(self: *const PolySynth, seq_notes: *[16 * max_arp_octaves]u7, seq_vels: *[16 * max_arp_octaves]f32) usize {
        const n: usize = self.arp_latch_count;
        var notes: [16]u7 = self.arp_latch_notes;
        var vels: [16]f32 = self.arp_latch_vel;
        if (self.arp_mode != .played) {
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const key = notes[i];
                const key_v = vels[i];
                var j = i;
                while (j > 0 and notes[j - 1] > key) : (j -= 1) {
                    notes[j] = notes[j - 1];
                    vels[j] = vels[j - 1];
                }
                notes[j] = key;
                vels[j] = key_v;
            }
        }
        const octaves: usize = @intCast(std.math.clamp(self.arp_octaves, 1, max_arp_octaves));
        var k: usize = 0;
        for (0..octaves) |oct| {
            for (0..n) |i| {
                const shifted: i32 = @as(i32, notes[i]) + @as(i32, @intCast(oct)) * 12;
                if (shifted < 0 or shifted > 127) continue;
                seq_notes[k] = @intCast(shifted);
                seq_vels[k] = vels[i];
                k += 1;
            }
        }
        return k;
    }

    /// Trigger the next arp step: all held notes at once for `.chord`, one
    /// note from the built sequence otherwise. Called synchronously from
    /// `noteOn` (first press) and from `processBlock`'s step timer.
    fn arpFireStep(self: *PolySynth) void {
        const n = self.arp_latch_count;
        if (n == 0) return;

        if (self.arp_mode == .chord) {
            self.arpReleaseActive();
            for (0..n) |i| self.noteOnPoly(self.arp_latch_notes[i], self.arp_latch_vel[i]);
            self.arp_gate_open = true;
            return;
        }

        var seq_notes: [16 * max_arp_octaves]u7 = undefined;
        var seq_vels: [16 * max_arp_octaves]f32 = undefined;
        const k = self.arpBuildSeq(&seq_notes, &seq_vels);
        if (k == 0) return;

        // zig fmt: off
        const idx: usize = switch (self.arp_mode) {
            .up, .played => blk: { const i = self.arp_index % k; self.arp_index += 1; break :blk i; },
            .down         => blk: { const i = k - 1 - (self.arp_index % k); self.arp_index += 1; break :blk i; },
            .updown       => blk: {
                const pp_len = if (k <= 1) k else 2 * k - 2;
                const p = self.arp_index % pp_len;
                self.arp_index += 1;
                break :blk if (p < k) p else pp_len - p;
            },
            .downup       => blk: {
                const pp_len = if (k <= 1) k else 2 * k - 2;
                const p = self.arp_index % pp_len;
                const mirrored = if (p < k) p else pp_len - p;
                self.arp_index += 1;
                break :blk k - 1 - mirrored;
            },
            .random       => blk: {
                const r01 = nextNoise(&self.arp_rand) * 0.5 + 0.5; // [-1,1) -> [0,1)
                break :blk @min(@as(usize, @intFromFloat(r01 * @as(f32, @floatFromInt(k)))), k - 1);
            },
            .chord        => unreachable,
        };
        // zig fmt: on

        self.arpReleaseActive();
        self.noteOnPoly(seq_notes[idx], seq_vels[idx]);
        self.arp_gate_open = true;
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
        instances: [max_mod_rows]u32 = undefined,
        dests: [max_mod_rows]u16 = undefined,
        amts: [max_mod_rows]f32 = undefined,
        count: u8 = 0,

        fn amt(self: *const ModAccum, dest: u16) f32 {
            for (self.instances[0..self.count], self.dests[0..self.count], self.amts[0..self.count]) |instance, d, a| {
                if (instance == 0 and d == dest) return a;
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
                .env3     => if (v) |vv| vv.env3 else 0.0,
                .random    => if (v) |vv| vv.random else 0.0,
                .alternate => if (v) |vv| vv.alternate else 0.0,
                // zig fmt: on
            };
            const polar = if (row.unipolar and row.source.isBipolar()) src * 0.5 + 0.5 else src;
            const a = row.depth * polar;
            for (acc.instances[0..acc.count], acc.dests[0..acc.count], 0..) |instance, d, i| {
                if (instance == row.fx_instance_id and d == row.dest) {
                    acc.amts[i] += a;
                    break;
                }
            } else {
                acc.instances[acc.count] = row.fx_instance_id;
                acc.dests[acc.count] = row.dest;
                acc.amts[acc.count] = a;
                acc.count += 1;
            }
        }
        return acc;
    }

    /// `base` (a param's live value) shifted by the voice's matrix amount
    /// for that param, scaled to the param's full range and clamped to it.
    /// Cutoffs and the virtual pitch/amp dests are NOT routed through here -
    /// they modulate in octave/gain space at their use sites instead.
    fn eff(acc: *const ModAccum, id: u16, base: f32) f32 {
        const a = acc.amt(id);
        if (a == 0.0) return base;
        const p = findAutomatableParam(id) orelse return base;
        return std.math.clamp(base + a * (p.range[1] - p.range[0]), p.range[0], p.range[1]);
    }

    /// `eff` for the integer unison-count params, rounded back to a count.
    fn effUnison(acc: *const ModAccum, id: u16, base: u8) usize {
        const e = eff(acc, id, @floatFromInt(@max(base, 1)));
        return @intFromFloat(@round(std.math.clamp(e, 1.0, @as(f32, max_unison))));
    }

    pub fn processBlock(self: *PolySynth, buf: []Sample) void {
        const frames = buf.len / 2;
        if (frames == 0) return;

        // Block-rate LFOs: sample once before the voice loop so all voices
        // receive the same values, avoiding inter-voice phase desync.
        var lfo_vals = [3]f32{
            self.lfoVal(0, self.lfo_shape, offsetPhase(self.lfo_phase, self.lfo_phase_offset)),
            self.lfoVal(1, self.lfo2_shape, offsetPhase(self.lfo2_phase, self.lfo2_phase_offset)),
            self.lfoVal(2, self.lfo3_shape, offsetPhase(self.lfo3_phase, self.lfo3_phase_offset)),
        };
        self.slewLfoVals(&lfo_vals, frames);

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

            // All matrix modulation below is block-rate per voice - the
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

            const env3_sustain_v   = eff(&mods, 124, self.env3_sustain);
            const env3_attack_inc  = 1.0 / @max(eff(&mods, 122, self.env3_attack_s)  * self.sample_rate, 1.0);
            const env3_decay_inc   = (1.0 - env3_sustain_v) / @max(eff(&mods, 123, self.env3_decay_s) * self.sample_rate, 1.0);
            const env3_release_inc = 1.0 / @max(eff(&mods, 125, self.env3_release_s) * self.sample_rate, 1.0);

            const amp_shape  = envShape(attack_inc, decay_inc, release_inc, sustain_v, eff(&mods, 246, self.env_curve));
            const fenv_shape = envShape(fenv_attack_inc, fenv_decay_inc, fenv_release_inc, fenv_sustain_v, eff(&mods, 247, self.fenv_curve));
            const env3_shape = envShape(env3_attack_inc, env3_decay_inc, env3_release_inc, env3_sustain_v, eff(&mods, 248, self.env3_curve));

            const drive1_v = eff(&mods, 249, self.filter_drive);
            const drive2_v = eff(&mods, 250, self.filter2_drive);
            // zig fmt: on

            // Glide: advance current log-freq toward target at block rate.
            const target_log = std.math.log2(noteToFreq(v.note));
            if (eff(&mods, 33, self.glide_s) > 0.0 and v.glide_rate != 0.0) {
                v.glide_log += v.glide_rate * @as(f32, @floatFromInt(frames));
                // zig fmt: off
                const overshot = (v.glide_rate > 0.0 and v.glide_log >= target_log) or
                                 (v.glide_rate < 0.0 and v.glide_log <= target_log);
                if (overshot) { v.glide_log = target_log; v.glide_rate = 0.0; }
            } else {
                v.glide_log = target_log;
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
                v.glide_log + eff(&mods, 2, self.detune_cents) / 1200.0 + mods.amt(dest_pitch) +
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
            const wt_pos_a     = eff(&mods, 185, self.wt_pos);
            const wt_pos_b     = eff(&mods, 186, self.osc_b_wt_pos);
            const wt_pos_c     = eff(&mods, 187, self.osc_c_wt_pos);
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
            // zig fmt: on
            const ring = self.osc_b_on and self.mod_mode == .ring;
            const mix_targets: [5]f32 = if (ring)
                .{ scale_a * ring_mix_norm, 0.0, scale_c * c_level * ring_mix_norm, sub_level_v * ring_mix_norm, noise_lvl_v * ring_mix_norm }
            else
                .{ scale_a * mix_norm, scale_b * b_level * mix_norm, scale_c * c_level * mix_norm, sub_level_v * mix_norm, noise_lvl_v * mix_norm };
            var mix_steps: [5]f32 = undefined;
            for (&mix_steps, mix_targets, v.mix_gain) |*step, target, current| step.* = (target - current) / @as(f32, @floatFromInt(frames));
            const out_step = (gain_v - v.out_gain) / @as(f32, @floatFromInt(frames));

            // Stereo pan gains per unison voice - constant-power, √2-compensated so
            // spread=0 gives the same per-channel amplitude as the original mono path.
            const uni_spread = eff(&mods, 5, self.unison_spread);
            var pan_l_a: [max_unison]f32 = undefined;
            var pan_r_a: [max_unison]f32 = undefined;
            computeUnisonPan(n_a, uni_spread, &pan_l_a, &pan_r_a);
            var pan_l_b: [max_unison]f32 = undefined;
            var pan_r_b: [max_unison]f32 = undefined;
            if (self.osc_b_on) computeUnisonPan(n_b, uni_spread, &pan_l_b, &pan_r_b);
            var pan_l_c: [max_unison]f32 = undefined;
            var pan_r_c: [max_unison]f32 = undefined;
            if (self.osc_c_on) computeUnisonPan(n_c, uni_spread, &pan_l_c, &pan_r_c);

            for (0..frames) |i| {
                var a_l: f32 = 0.0;
                var a_r: f32 = 0.0;
                var a_mono: f32 = 0.0; // arithmetic mean of A voices - used by mod modes
                var b_l: f32 = 0.0;
                var b_r: f32 = 0.0;
                var b_mono: f32 = 0.0;

                // FM B→A: render B first so b_mono is ready when A phases advance.
                if (self.osc_b_on and self.mod_mode == .fm_b_to_a) {
                    for (0..n_b) |ui| {
                        const samp = self.oscSampleB(v.phases_b[ui], phase_incs_b[ui], pw_b, warp_amt_b, wt_pos_b);
                        b_l += samp * pan_l_b[ui];
                        b_r += samp * pan_r_b[ui];
                        b_mono += samp;
                        v.phases_b[ui] += phase_incs_b[ui];
                        v.phases_b[ui] -= @floor(v.phases_b[ui]);
                    }
                    b_mono /= @as(f32, @floatFromInt(n_b));
                }

                // OSC A: phase is FM-modulated by b_mono when mod_mode == fm_b_to_a.
                // The step is computed before the sample, not after, because
                // polyBLEP needs to know how fast the phase is moving to size
                // its correction (see `polyBlep`).
                for (0..n_a) |ui| {
                    const inc: f32 = if (self.mod_mode == .fm_b_to_a)
                        phase_incs_a[ui] * (1.0 + mod_amount_v * b_mono)
                    else
                        phase_incs_a[ui];
                    const samp = self.oscSampleA(v.phases[ui], inc, pw_a, warp_amt_a, wt_pos_a);
                    a_l += samp * pan_l_a[ui];
                    a_r += samp * pan_r_a[ui];
                    a_mono += samp;
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
                        // FM A→B: advance B's phase modulated by a_mono.
                        const inc: f32 = if (self.mod_mode == .fm_a_to_b)
                            phase_incs_b[ui] * (1.0 + mod_amount_v * a_mono)
                        else
                            phase_incs_b[ui];
                        const samp = self.oscSampleB(v.phases_b[ui], inc, pw_b, warp_amt_b, wt_pos_b);
                        b_l += samp * pan_l_b[ui];
                        b_r += samp * pan_r_b[ui];
                        b_mono += samp;
                        v.phases_b[ui] += inc;
                        if (self.mod_mode == .fm_a_to_b) {
                            v.phases_b[ui] -= @floor(v.phases_b[ui]);
                        } else {
                            if (v.phases_b[ui] >= 1.0) v.phases_b[ui] -= 1.0;
                        }
                    }
                    b_mono /= @as(f32, @floatFromInt(n_b));
                }

                // AM: post-hoc amplitude scaling - (1 + m·mod) / (1 + m) keeps peak = 1.
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
                        const samp = if (self.osc_c_waveform == .wavetable)
                            wavetable.lookup(self.osc_c_wt, wt_pos_c, v.phases_c[ui], phase_incs_c[ui])
                        else
                            oscWave(self.osc_c_waveform, v.phases_c[ui], pw_c, phase_incs_c[ui]);
                        c_l += samp * pan_l_c[ui];
                        c_r += samp * pan_r_c[ui];
                        v.phases_c[ui] += phase_incs_c[ui];
                        if (v.phases_c[ui] >= 1.0) v.phases_c[ui] -= 1.0;
                    }
                }

                // Sub: always centre (mono → both channels). Routed through
                // oscWave at a fixed 50% duty so the square sub gets the same
                // polyBLEP band-limiting OSC A/B/C do - an octave down still
                // leaves plenty of harmonics above Nyquist to fold back.
                var sub_out: f32 = 0.0;
                if (mix_targets[3] > 0.0 or v.mix_gain[3] > 0.0) {
                    // zig fmt: on
                    const sub_wf: Waveform = if (self.sub_shape == .sine) .sine else .square;
                    sub_out = oscWave(sub_wf, v.sub_phase, 0.5, sub_phase_inc);
                    v.sub_phase += sub_phase_inc;
                    if (v.sub_phase >= 1.0) v.sub_phase -= 1.0;
                }

                // Noise: always centre.
                var nse_out: f32 = 0.0;
                if (mix_targets[4] > 0.0 or v.mix_gain[4] > 0.0) {
                    const raw = nextNoise(&v.noise_rand_state);
                    v.noise_lp = (1.0 - noise_lp_a) * raw + noise_lp_a * v.noise_lp;
                    nse_out = v.noise_lp;
                }

                // Stereo mix.
                // Ring: dry↔ring crossfade - depth=0 → A unmodulated; depth=1 → A·b_mono.
                // Formula: (1-d) + d·b_mono stays in [-1,1] for d∈[0,1], b_mono∈[-1,1].
                // FM/AM/none: standard A + B mix (B contribution already modulated above).
                const ring_factor: f32 = if (ring) blk: {
                    const depth = std.math.clamp(mod_amount_v, 0.0, 1.0);
                    break :blk (1.0 - depth) + depth * b_mono;
                } else 0.0;
                for (&v.mix_gain, mix_steps) |*gain, step| gain.* += step;
                v.out_gain += out_step;
                const osc_l: f32 = if (ring)
                    a_l * v.mix_gain[0] * ring_factor + c_l * v.mix_gain[2] + sub_out * v.mix_gain[3] + nse_out * v.mix_gain[4]
                else
                    a_l * v.mix_gain[0] + b_l * v.mix_gain[1] + c_l * v.mix_gain[2] + sub_out * v.mix_gain[3] + nse_out * v.mix_gain[4];
                const osc_r: f32 = if (ring)
                    a_r * v.mix_gain[0] * ring_factor + c_r * v.mix_gain[2] + sub_out * v.mix_gain[3] + nse_out * v.mix_gain[4]
                else
                    a_r * v.mix_gain[0] + b_r * v.mix_gain[1] + c_r * v.mix_gain[2] + sub_out * v.mix_gain[3] + nse_out * v.mix_gain[4];

                // Stereo filter: same coefficients, independent L/R histories.
                // zig fmt: off
                const filt1_l = filterSample(self.filter_type, fc, &v.f1_l, driveInput(drive1_v, osc_l));
                const filt1_r = filterSample(self.filter_type, fc, &v.f1_r, driveInput(drive1_v, osc_r));

                // Filter 2: series chains off filter 1's output; parallel
                // filters the same dry mix and blends with filter 1's output.
                // Both collapse to filter 1 alone when filter2_on is false.
                var filt_l = filt1_l;
                var filt_r = filt1_r;
                if (self.filter2_on) {
                    const in2_l = if (self.filter_routing == .series) filt1_l else osc_l;
                    const in2_r = if (self.filter_routing == .series) filt1_r else osc_r;

                    const filt2_l = filterSample(self.filter2_type, fc2, &v.f2_l, driveInput(drive2_v, in2_l));
                    const filt2_r = filterSample(self.filter2_type, fc2, &v.f2_r, driveInput(drive2_v, in2_r));

                    filt_l = if (self.filter_routing == .series) filt2_l else (filt1_l + filt2_l) * 0.5;
                    filt_r = if (self.filter_routing == .series) filt2_r else (filt1_r + filt2_r) * 0.5;
                }

                const sg = v.env * v.velocity * v.out_gain * amp_mod;
                buf[i * 2]     += filt_l * sg;
                buf[i * 2 + 1] += filt_r * sg;
                // zig fmt: on

                // Amplitude envelope - hitting zero on release kills the
                // voice outright (unlike the filter/env3 envelopes below).
                if (advanceEnv(&v.stage, &v.env, sustain_v, amp_shape)) {
                    v.* = .{};
                    break;
                }

                // Filter envelope (voice death is governed by amp env above)
                _ = advanceEnv(&v.stage2, &v.env2, fenv_sustain_v, fenv_shape);

                // ENV 3 (free-assign, no fixed destination - voice death is
                // still governed by the amp env above)
                _ = advanceEnv(&v.stage3, &v.env3, env3_sustain_v, env3_shape);
            }
        }

        const mod_voice = &self.voices[self.newest_voice];
        const rack_mods = self.evalMatrix(if (mod_voice.active) mod_voice else null, lfo_vals);
        self.fx_mod_bus.clear();
        for (rack_mods.instances[0..rack_mods.count], rack_mods.dests[0..rack_mods.count], rack_mods.amts[0..rack_mods.count]) |instance, dest, amount| {
            self.fx_mod_bus.add(instance, dest, amount);
        }

        // Advance the LFOs once per block after all voices are done.
        const frames_f: f32 = @floatFromInt(frames);
        self.advanceLfo(0, &self.lfo_phase, self.lfo_sync, self.lfo_rate_hz, self.lfo_retrig, frames_f);
        self.advanceLfo(1, &self.lfo2_phase, self.lfo2_sync, self.lfo2_rate_hz, self.lfo2_retrig, frames_f);
        self.advanceLfo(2, &self.lfo3_phase, self.lfo3_sync, self.lfo3_rate_hz, self.lfo3_retrig, frames_f);

        // Arp step timer: block-rate like the LFOs above. The gate check
        // runs before the wrap loop so a step fired earlier this same block
        // can still close before a later block's wrap retriggers it.
        if (self.arp_on) {
            self.arp_phase += self.syncedRate(self.arp_sync, self.arp_rate_hz) * frames_f / self.sample_rate;
            if (self.arp_gate_open and self.arp_phase >= self.arp_gate) {
                self.arpReleaseActive();
                self.arp_gate_open = false;
            }
            while (self.arp_phase >= 1.0) {
                self.arp_phase -= 1.0;
                self.arpFireStep();
            }
        } else if (self.arp_was_on) {
            // Toggled off mid-note: release whatever it was sounding rather
            // than leaving a voice stuck (its held note may be pitched an
            // octave+ away from anything a normal noteOff would match).
            self.arpReleaseActive();
            self.arp_latch_count = 0;
            self.arp_index = 0;
            self.arp_phase = 0.0;
            self.arp_gate_open = false;
        }
        self.arp_was_on = self.arp_on;
    }

    /// Lorenz attractor state (x, y, z) for one .chaos LFO slot. Defaults
    /// off the origin - see PolySynth.lfo_chaos's doc comment.
    const ChaosState = struct { x: f32 = 0.1, y: f32 = 1.0, z: f32 = 1.0 };

    // Classic Lorenz parameters (butterfly attractor). x/y roughly range
    // ±20 for these constants, hence the /20 normalization in lfoVal.
    const lorenz_sigma: f32 = 10.0;
    const lorenz_rho: f32 = 28.0;
    const lorenz_beta: f32 = 8.0 / 3.0;

    /// `phase` shifted by an `lfo*_phase_offset` and wrapped back into
    /// [0, 1). A non-finite offset (hand-edited file, stray automation)
    /// leaves the phase alone rather than poisoning it.
    fn offsetPhase(phase: f32, offset: f32) f32 {
        if (!std.math.isFinite(offset) or offset == 0.0) return phase;
        const shifted = phase + offset;
        return shifted - @floor(shifted);
    }

    /// One-pole smoothing per slot, per `lfo*_slew_ms`. Runs at block rate
    /// (the rate the LFOs themselves run at), so the coefficient is built
    /// against blocks-per-second rather than the sample rate.
    fn slewLfoVals(self: *PolySynth, vals: *[3]f32, frames: usize) void {
        const ms = [3]f32{ self.lfo_slew_ms, self.lfo2_slew_ms, self.lfo3_slew_ms };
        const blocks_per_s = if (frames > 0) self.sample_rate / @as(f32, @floatFromInt(frames)) else 0.0;
        for (ms, 0..) |slew_ms, slot| {
            if (!(slew_ms > 0.0) or blocks_per_s <= 0.0) {
                self.lfo_slew_state[slot] = vals[slot];
                continue;
            }
            const coef = dsp.smoothingCoefMs(slew_ms, blocks_per_s);
            const prev = if (std.math.isFinite(self.lfo_slew_state[slot])) self.lfo_slew_state[slot] else vals[slot];
            self.lfo_slew_state[slot] = vals[slot] + (prev - vals[slot]) * coef;
            vals[slot] = self.lfo_slew_state[slot];
        }
    }

    /// Block-rate value of the LFO in `slot`: the held random level for
    /// sample & hold, the normalized Lorenz x-axis for chaos, a pure
    /// function of phase for every other shape.
    fn lfoVal(self: *const PolySynth, slot: usize, shape: LfoShape, phase: f32) f32 {
        return switch (shape) {
            .sh => self.lfo_sh[slot],
            .chaos => std.math.clamp(self.lfo_chaos[slot].x / 20.0, -1.0, 1.0),
            .custom => lfoCustomSample(self.lfo_custom[slot][0..self.lfo_custom_count[slot]], phase),
            else => lfoSample(shape, phase),
        };
    }

    /// Linear interpolation across a `.custom` LFO shape's points - see
    /// `LfoShapePoint`'s doc comment for why this doesn't just call
    /// `dsp.automation.interpolate`. Never `null` like that function: an
    /// LFO always has to produce some value, so an empty or corrupt point
    /// list (unreachable via the editor, only via a hand-edited file) reads
    /// as silence rather than propagating an optional through the whole
    /// modulation chain.
    fn lfoCustomSample(points: []const LfoShapePoint, phase: f32) f32 {
        if (points.len == 0) return 0;
        if (phase <= points[0].phase) return points[0].value;
        const last = points[points.len - 1];
        if (phase >= last.phase) return last.value;
        var i: usize = 1;
        while (i < points.len) : (i += 1) {
            if (points[i].phase >= phase) {
                const a = points[i - 1];
                const b = points[i];
                const span = b.phase - a.phase;
                const t: f32 = if (span <= 0) 1.0 else (phase - a.phase) / span;
                return a.value + (b.value - a.value) * t;
            }
        }
        return last.value;
    }

    fn setLfoCustomPhase(self: *PolySynth, slot: usize, index: usize, phase: f32) void {
        var lo: f32 = 0.0;
        var hi: f32 = 1.0;
        const count = self.lfo_custom_count[slot];
        if (index < count) {
            if (index > 0) lo = self.lfo_custom[slot][index - 1].phase;
            if (index + 1 < count) hi = self.lfo_custom[slot][index + 1].phase;
        }
        if (lo <= hi) self.lfo_custom[slot][index].phase = std.math.clamp(phase, lo, hi);
    }

    fn setLfoCustomCount(self: *PolySynth, slot: usize, new_count: u8) void {
        const old_count = self.lfo_custom_count[slot];
        if (new_count > old_count) {
            for (old_count..new_count) |index| {
                if (index > 0) {
                    const previous = self.lfo_custom[slot][index - 1].phase;
                    self.lfo_custom[slot][index].phase = @max(previous, self.lfo_custom[slot][index].phase);
                }
            }
        }
        self.lfo_custom_count[slot] = new_count;
    }

    /// Advance one LFO's phase by a block; a wrap redraws the slot's sample
    /// & hold level, and the slot's chaos attractor always integrates
    /// (cheap enough to do regardless of the active shape, same as sh).
    /// A slot's effective rate in Hz: `rate_hz` unless `sync` names a
    /// division and a Transport is attached, in which case the project
    /// tempo decides. Shared by the LFOs and the arp step clock.
    fn syncedRate(self: *const PolySynth, sync: LfoSync, rate_hz: f32) f32 {
        const beats = sync.beatsPerCycle() orelse return rate_hz;
        const t = self.transport orelse return rate_hz;
        const bpm = if (std.math.isFinite(t.tempo_bpm) and t.tempo_bpm > 0.0) t.tempo_bpm else 120.0;
        return @floatCast(bpm / 60.0 / beats);
    }

    /// Phase the transport itself dictates for a `.free` tempo-synced slot,
    /// or null when the slot has to free-run instead (no division, no
    /// transport, stopped, or a retrigger mode that owns the phase). Locking
    /// to the playhead is what makes a synced wobble land on the same beat
    /// every pass through a loop, rather than wherever the phase drifted to.
    fn gridPhase(self: *const PolySynth, sync: LfoSync, retrig: LfoRetrig) ?f32 {
        if (retrig != .free) return null;
        const beats = sync.beatsPerCycle() orelse return null;
        const t = self.transport orelse return null;
        if (!t.playing) return null;
        const cycles = t.positionBeats() / beats;
        if (!std.math.isFinite(cycles)) return null;
        return @floatCast(cycles - @floor(cycles));
    }

    fn advanceLfo(
        self: *PolySynth,
        slot: usize,
        phase: *f32,
        sync: LfoSync,
        rate_hz: f32,
        retrig: LfoRetrig,
        frames: f32,
    ) void {
        const phase_inc = self.syncedRate(sync, rate_hz) * frames / self.sample_rate;
        if (self.gridPhase(sync, retrig)) |locked| {
            // A jump backwards is a wrap (or a seek) - either way the S&H
            // level is due a fresh draw, same as the free-running branch.
            if (locked < phase.*) self.lfo_sh[slot] = nextNoise(&self.lfo_sh_rand);
            phase.* = locked;
        } else if (retrig == .one_shot and self.lfo_oneshot_done[slot]) {
            phase.* = 1.0;
        } else {
            phase.* += phase_inc;
            if (phase.* >= 1.0) {
                self.lfo_sh[slot] = nextNoise(&self.lfo_sh_rand);
                // One-shot parks at the end of its single cycle instead of
                // wrapping; the next note-on retrigger clears the flag.
                if (retrig == .one_shot) {
                    self.lfo_oneshot_done[slot] = true;
                    phase.* = 1.0;
                    advanceChaos(&self.lfo_chaos[slot], phase_inc);
                    return;
                }
            }
            phase.* -= @floor(phase.*);
        }
        advanceChaos(&self.lfo_chaos[slot], phase_inc);
    }

    /// Restart every `.key`/`.one_shot` LFO from the top. Called from the
    /// note-on paths that actually start a voice, so a legato slide doesn't
    /// re-arm a growl mid-note.
    fn retriggerLfos(self: *PolySynth) void {
        const retrigs = [3]LfoRetrig{ self.lfo_retrig, self.lfo2_retrig, self.lfo3_retrig };
        const phases = [3]*f32{ &self.lfo_phase, &self.lfo2_phase, &self.lfo3_phase };
        for (retrigs, phases, 0..) |retrig, phase, slot| {
            if (retrig == .free) continue;
            phase.* = 0.0;
            self.lfo_oneshot_done[slot] = false;
        }
    }

    /// Euler-integrates the Lorenz system by `dt_total`, split into
    /// substeps bounded to `max_step` (Euler-stable for this system) and
    /// capped at `max_substeps` so a large block/rate combination can't
    /// spend unbounded time on the audio thread - it just under-integrates
    /// instead, which is inaudible for a modulation source.
    fn advanceChaos(state: *ChaosState, dt_total: f32) void {
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
            // Same cascade as .ladder; the diode-vs-Moog difference lives
            // entirely in filterSample's nonlinearity. A slightly hotter
            // feedback scale (4.5 vs 4.0) reaches self-oscillation a touch
            // sooner, matching the diode ladder's reputation for an eager,
            // aggressive resonant peak.
            .diode => .{
                .g = 1.0 - @exp(-w0),
                .k = res * 4.5,
            },
            .comb => .{
                .comb_delay = std.math.clamp(self.sample_rate / c, 2.0, @as(f32, @floatFromInt(comb_len)) - 2.0),
                .comb_fb = res * 0.9,
            },
            .formant => .{ .formant = self.formantCoeffs(c, res) },
        };
    }

    /// Interpolated 3-formant SVF coefficients for the vowel-scan filter.
    /// `c` (already clamped to 20 Hz..Nyquist) doubles as a 0..1 scan
    /// position across the a-e-i-o-u table on a log scale, same "cutoff
    /// means something else per filter type" pattern as .comb/.ladder
    /// above; `res` narrows every formant's bandwidth for a sharper sweep.
    fn formantCoeffs(self: *const PolySynth, c: f32, res: f32) FormantCoeffs {
        const scan = std.math.clamp(@log2(c / 20.0) / @log2(20_000.0 / 20.0), 0.0, 1.0);
        const pos = scan * @as(f32, @floatFromInt(formant_table.len - 1));
        const vi0: usize = @intFromFloat(@floor(pos));
        const vi1 = @min(vi0 + 1, formant_table.len - 1);
        const t = pos - @floor(pos);
        const v0 = formant_table[vi0];
        const v1 = formant_table[vi1];
        const bw_scale = 1.0 - res * 0.8;

        var fc: FormantCoeffs = .{};
        // zig fmt: off
        fc.f1    = self.svfCoeff(std.math.lerp(v0.f[0], v1.f[0], t));
        fc.damp1 = svfDamp(std.math.lerp(v0.f[0], v1.f[0], t), std.math.lerp(v0.bw[0], v1.bw[0], t) * bw_scale);
        fc.gain1 = types.dbToGain(std.math.lerp(v0.amp_db[0], v1.amp_db[0], t));
        fc.f2    = self.svfCoeff(std.math.lerp(v0.f[1], v1.f[1], t));
        fc.damp2 = svfDamp(std.math.lerp(v0.f[1], v1.f[1], t), std.math.lerp(v0.bw[1], v1.bw[1], t) * bw_scale);
        fc.gain2 = types.dbToGain(std.math.lerp(v0.amp_db[1], v1.amp_db[1], t));
        fc.f3    = self.svfCoeff(std.math.lerp(v0.f[2], v1.f[2], t));
        fc.damp3 = svfDamp(std.math.lerp(v0.f[2], v1.f[2], t), std.math.lerp(v0.bw[2], v1.bw[2], t) * bw_scale);
        fc.gain3 = types.dbToGain(std.math.lerp(v0.amp_db[2], v1.amp_db[2], t));
        // zig fmt: on
        return fc;
    }

    fn svfCoeff(self: *const PolySynth, freq: f32) f32 {
        const f = std.math.clamp(freq, 20.0, self.sample_rate * 0.49);
        return 2.0 * @sin(std.math.pi * f / self.sample_rate);
    }

    /// Q clamped to 40 (matches the biquad's own 0.5..20 Q range order of
    /// magnitude) so an extreme res setting narrows the formant sharply
    /// without letting the resonator's peak gain run away.
    fn svfDamp(freq: f32, bw: f32) f32 {
        const q = std.math.clamp(freq / @max(bw, 1.0), 0.5, 40.0);
        return 1.0 / q;
    }

    /// Constant-power, √2-compensated pan gains for `n` unison voices spread
    /// across `spread` (see `unison_spread`) - shared setup for oscillators
    /// A/B/C's per-voice pan arrays, which differ only in unison count and
    /// which oscillator's arrays they write into. spread=0 (or n<=1) gives
    /// the same per-channel amplitude as the original mono path.
    fn computeUnisonPan(n: usize, spread: f32, pan_l: *[max_unison]f32, pan_r: *[max_unison]f32) void {
        const pan_scale = std.math.sqrt2;
        for (0..n) |ui| {
            const raw: f32 = if (n > 1 and spread > 0.0)
                ((@as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(n - 1))) * 2.0 - 1.0) * spread
            else
                0.0;
            const angle = (raw + 1.0) * std.math.pi * 0.25;
            pan_l[ui] = pan_scale * @cos(angle);
            pan_r[ui] = pan_scale * @sin(angle);
        }
    }

    /// Advances one ADSR generator by one sample - shared body of the amp,
    /// filter, and env3 envelopes (`Voice.stage`/`env`, `stage2`/`env2`,
    /// `stage3`/`env3`), which differ only in which stage/level pair and
    /// per-stage increments they're driven by. Returns true once `level`
    /// has decayed to zero during release; the amp-envelope caller uses
    /// that to kill the whole voice, while filter/env3 just let `level`
    /// stay parked at zero (this function's own floor already handles it).
    fn advanceEnv(stage: *Stage, level: *f32, sustain_v: f32, sh: EnvShape) bool {
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

    fn envShape(attack_inc: f32, decay_inc: f32, release_inc: f32, sustain_v: f32, curve: f32) EnvShape {
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

    /// Pre-filter saturation. Drive 1 preserves legacy output exactly.
    fn driveInput(drive: f32, x: f32) f32 {
        if (!(drive > 1.0)) return x;
        return std.math.tanh(x * drive) / std.math.tanh(drive);
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
            .diode => {
                // Same 4-stage one-pole cascade as .ladder, but each stage
                // clips through diodeClip's asymmetric curve instead of a
                // symmetric tanh - the diode pair's forward-conduction
                // curve, and the source of the "thinner/brighter" diode
                // ladder color vs the smoother Moog transistor ladder.
                const in_sat = diodeClip(x - fc.k * st.s4);
                st.s1 += fc.g * (diodeClip(in_sat) - st.s1);
                st.s2 += fc.g * (diodeClip(st.s1) - st.s2);
                st.s3 += fc.g * (diodeClip(st.s2) - st.s3);
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
            .formant => {
                // 3 parallel Chamberlin SVF bandpass resonators, one per
                // formant, summed and weighted by the table's per-formant
                // amplitude. x1/x2, y1/y2, s1/s2 double as the 3 resonators'
                // lp/bp state pairs (see FilterState's doc comment).
                const y1 = svfBandpass(fc.formant.f1, fc.formant.damp1, &st.x1, &st.x2, x) * fc.formant.gain1;
                const y2 = svfBandpass(fc.formant.f2, fc.formant.damp2, &st.y1, &st.y2, x) * fc.formant.gain2;
                const y3 = svfBandpass(fc.formant.f3, fc.formant.damp3, &st.s1, &st.s2, x) * fc.formant.gain3;
                return y1 + y2 + y3;
            },
        }
    }

    /// Asymmetric soft clip approximating a diode pair's forward-conduction
    /// curve: compresses positive swings harder than negative ones. Used by
    /// .diode instead of .ladder's symmetric tanh.
    fn diodeClip(x: f32) f32 {
        return if (x >= 0.0) x / (1.0 + 0.5 * x) else std.math.tanh(x);
    }

    /// One sample through a Chamberlin state-variable bandpass tuned to
    /// `f` (SVF frequency coefficient, from svfCoeff) with damping `damp`
    /// (1/Q). `s_lp`/`s_bp` are the resonator's own persistent 2-state
    /// history.
    fn svfBandpass(f: f32, damp: f32, s_lp: *f32, s_bp: *f32, x: f32) f32 {
        s_lp.* += f * s_bp.*;
        const hp = x - s_lp.* - damp * s_bp.*;
        s_bp.* += f * hp;
        return s_bp.*;
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
            // Held/integrated state lives on PolySynth.lfo_sh/lfo_chaos,
            // user-drawn points on PolySynth.lfo_custom; callers go through
            // lfoVal, which never reaches here for .sh/.chaos/.custom.
            .sh       => 0.0,
            .chaos    => 0.0,
            .custom   => 0.0,
            // zig fmt: on
        };
    }

    /// Wraps `cur` one variant forward (steps > 0) or backward - every
    /// `.cycle` `ParamSpec` kind below (and the mod matrix's source
    /// stepping) shares this instead of a bespoke forward/backward switch
    /// pair per enum: all of those pairs already reduced to a declaration-
    /// order wrap once written out, this just does that generically.
    fn cycleEnum(comptime E: type, cur: E, steps: i32) E {
        const n: i32 = @typeInfo(E).@"enum".fields.len;
        const dir: i32 = if (steps > 0) 1 else -1;
        const ord: i32 = @intFromEnum(cur);
        return @enumFromInt(@as(u8, @intCast(@mod(ord + dir, n))));
    }

    /// Warps `phase` then looks up a wavetable frame or classic waveform
    /// shape - shared body of `oscSampleA`/`oscSampleB`, which differ only
    /// in which of self's oscillator-A/B fields they read. `pw`/
    /// `warp_amount`/`wt_pos` are passed in (not read off `self`) so the
    /// caller can substitute per-voice matrix-modulated values.
    fn oscSample(waveform: Waveform, wt: Wavetable, warp_mode: WarpMode, phase: f32, inc: f32, pw: f32, warp_amount: f32, wt_pos: f32) Sample {
        const p = warpPhase(warp_mode, phase, warp_amount);
        if (waveform == .wavetable) return wavetable.lookup(wt, wt_pos, p, inc);
        return oscWave(waveform, p, pw, warpedInc(warp_mode, phase, inc, warp_amount, p));
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
    fn warpedInc(mode: WarpMode, phase: f32, inc: f32, amount: f32, warped: f32) f32 {
        if (mode == .none) return inc;
        var d = warpPhase(mode, phase + inc, amount) - warped;
        d -= @floor(d);
        return if (d > 0.0 and d < 0.25) d else inc;
    }

    fn oscSampleA(self: *const PolySynth, phase: f32, inc: f32, pw: f32, warp_amount: f32, wt_pos: f32) Sample {
        return oscSample(self.waveform, self.wt, self.warp_mode, phase, inc, pw, warp_amount, wt_pos);
    }

    fn oscSampleB(self: *const PolySynth, phase: f32, inc: f32, pw: f32, warp_amount: f32, wt_pos: f32) Sample {
        return oscSample(self.osc_b_waveform, self.osc_b_wt, self.osc_b_warp_mode, phase, inc, pw, warp_amount, wt_pos);
    }

    /// Remap a read phase before waveform lookup. Keep normalization here as
    /// a last audio-thread boundary: extreme pitch/FM can advance by more
    /// than one cycle, while malformed runtime state must not produce NaNs.
    fn warpPhase(mode: WarpMode, phase: f32, amount: f32) f32 {
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
    fn polyBlep(t: f32, dt: f32) f32 {
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

    /// `dt` sizes polyBLEP correction for saw and square discontinuities.
    fn oscWave(wf: Waveform, phase: f32, pw: f32, dt: f32) Sample {
        return switch (wf) {
            // zig fmt: off
            .sine     => @sin(2.0 * std.math.pi * phase),
            .saw      => 2.0 * phase - 1.0 - polyBlep(phase, dt),
            .triangle => 1.0 - 4.0 * @abs(phase - 0.5),
            // Rising edge at phase 0, falling edge at the duty point.
            .square   => blk: {
                const naive: f32 = if (phase < pw) 1.0 else -1.0;
                const off = phase - pw;
                break :blk naive + polyBlep(phase, dt) - polyBlep(off - @floor(off), dt);
            },
            // Callers branch to `wavetable.lookup` before reaching here -
            // this arm only exists to keep the switch exhaustive.
            .wavetable => 0.0,
            // zig fmt: on
        };
    }

    pub fn resetAll(self: *PolySynth) void {
        for (&self.voices) |*v| v.* = .{};
        self.held_count = 0;
        self.arp_latch_count = 0;
        self.arp_index = 0;
        self.arp_phase = 0.0;
        self.arp_gate_open = false;
        self.arp_was_on = false;
        self.fx_mod_bus.clear();
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
            .all_notes_off, .omni_mode_off, .omni_mode_on, .mono_mode_on, .poly_mode_on => { for (0..128) |n| self.noteOff(@intCast(n)); },
            .local_control     => {},
            // MIDI 1.0 Reset All Controllers resets performance controllers,
            // not program parameters such as volume, pan, or envelope times.
            .reset_all_ctrls   => {
                self.mod_wheel = 0.0;
                self.applyPitchBend(0, 2.0);
            },
            _                  => {},
            // zig fmt: on
        }
    }

    /// Move `kind`'s slot in `fx_order` toward the right (steps > 0) or left
    /// (steps < 0), `|steps|` times, clamping at either end instead of
    /// wrapping (matches a chain strip, not a cyclic enum). Drives the live
    /// `<`/`>` keypress via `adjustParam`'s ids 126-131 - undo/redo instead
    /// goes through `setFxIndex` (see that fn's doc comment for why).
    fn reorderFx(self: *PolySynth, kind: FxUnitKind, steps: i32) void {
        const idx = std.mem.indexOfScalar(FxUnitKind, &self.fx_order, kind) orelse return;
        const target = std.math.clamp(
            @as(i64, @intCast(idx)) + @as(i64, steps),
            0,
            @as(i64, self.fx_order.len - 1),
        );
        self.setFxIndex(kind, @intCast(target));
    }

    /// `kind`'s current slot index in `fx_order`, 0-based - the "value" ids
    /// 126-131 report from `paramValue` and accept in `setParamAbsolute`.
    /// Undo/redo for every other param works by capturing an absolute
    /// before-value and restoring it later (see `history.zig`'s
    /// `param_nudge` entry) - a reorder action needs *some* scalar that
    /// fully captures "where this unit was," and its index in the chain is
    /// exactly that, so the reorder ids piggyback on the same generic
    /// mechanism every other param already uses instead of a bespoke undo
    /// entry.
    fn fxOrderIndex(self: *const PolySynth, kind: FxUnitKind) usize {
        return std.mem.indexOfScalar(FxUnitKind, &self.fx_order, kind) orelse 0;
    }

    /// Move `kind` to absolute slot `idx`, shifting the units between its
    /// old and new position by walking adjacent swaps (same primitive
    /// `reorderFx` uses, just driven to an absolute target instead of a
    /// relative count). This is what undo/redo actually calls, through
    /// `setParamAbsolute`'s ids 126-131 - the live `<`/`>` keypress goes
    /// through `reorderFx`/`adjustParam` instead.
    fn setFxIndex(self: *PolySynth, kind: FxUnitKind, idx: usize) void {
        const cur = std.mem.indexOfScalar(FxUnitKind, &self.fx_order, kind) orelse return;
        const target = @min(idx, self.fx_order.len - 1);
        var i = cur;
        while (i < target) : (i += 1) std.mem.swap(FxUnitKind, &self.fx_order[i], &self.fx_order[i + 1]);
        while (i > target) : (i -= 1) std.mem.swap(FxUnitKind, &self.fx_order[i], &self.fx_order[i - 1]);
    }

    /// Editor-param kind, deciding how `adjustParam`/`setParamAbsolute`/
    /// `paramValue` read and write a `param_specs` entry's field - see
    /// `specAdjust`/`specSetAbs`/`specValue`. The great majority of the
    /// ~190 flat param ids reduce to one of these six shapes; what
    /// doesn't - the mod matrix rows (59-82, banded/cross-field), the FX
    /// reorder handles (`fx_reorder_ids` below), and `fx_mb_style`'s id 149
    /// on the `adjustParam` side only (h/l picks classic/ott by direction,
    /// not a wrap - its `setParamAbsolute`/`paramValue` behavior IS a plain
    /// `.cycle` though, so it still gets a `param_specs` row) - keep their
    /// own switch arms around the table dispatch.
    const ParamKind = enum { cont, log, skew_zero, toggle, cycle, int_cont };

    const ParamSpec = struct {
        id: u16,
        field: []const u8,
        kind: ParamKind = .cont,
        min: f32 = 0,
        max: f32 = 0,
        step: f32 = 0,
        enum_type: type = void,
    };

    fn specAdjust(self: *PolySynth, comptime spec: ParamSpec, steps: i32) void {
        const s: f32 = @floatFromInt(steps);
        switch (spec.kind) {
            .cont => {
                const p = &@field(self.*, spec.field);
                p.* = std.math.clamp(p.* + s * spec.step, spec.min, spec.max);
            },
            .log => {
                const p = &@field(self.*, spec.field);
                p.* = std.math.clamp(p.* * std.math.pow(f32, 2.0, s / 12.0), spec.min, spec.max);
            },
            .skew_zero => {
                const p = &@field(self.*, spec.field);
                const t = std.math.cbrt(std.math.clamp(p.* / spec.max, 0, 1));
                p.* = spec.max * std.math.pow(f32, std.math.clamp(t + s * spec.step, 0, 1), 3);
            },
            .toggle => {
                const p = &@field(self.*, spec.field);
                p.* = !p.*;
            },
            .cycle => {
                const p = &@field(self.*, spec.field);
                p.* = cycleEnum(spec.enum_type, p.*, steps);
            },
            .int_cont => {
                const p = &@field(self.*, spec.field);
                const lo: i64 = @intFromFloat(spec.min);
                const hi: i64 = @intFromFloat(spec.max);
                p.* = @intCast(std.math.clamp(@as(i64, p.*) + @as(i64, steps), lo, hi));
            },
        }
    }

    fn specSetAbs(self: *PolySynth, comptime spec: ParamSpec, value: f32) void {
        switch (spec.kind) {
            .cont, .log, .skew_zero => @field(self.*, spec.field) = std.math.clamp(value, spec.min, spec.max),
            .toggle => @field(self.*, spec.field) = value >= 0.5,
            .cycle => @field(self.*, spec.field) = enumFromValue(spec.enum_type, value),
            .int_cont => {
                const lo: i32 = @intFromFloat(spec.min);
                const hi: i32 = @intFromFloat(spec.max);
                @field(self.*, spec.field) = @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(value))), lo, hi));
            },
        }
    }

    fn specValue(self: *const PolySynth, comptime spec: ParamSpec) f32 {
        return switch (spec.kind) {
            .cont, .log, .skew_zero => @field(self.*, spec.field),
            .toggle => if (@field(self.*, spec.field)) 1.0 else 0.0,
            .cycle => enumToValue(@field(self.*, spec.field)),
            .int_cont => @floatFromInt(@field(self.*, spec.field)),
        };
    }

    /// Copies+clamps every `param_specs` field from `snap` (any struct with
    /// matching field names, typically persist.zig's `SynthSnap`) onto
    /// `self`, applying the same per-kind range `specSetAbs` uses. Lets
    /// file-load validation share the id->field->range table instead of
    /// persist.zig hand-maintaining a fourth parallel copy of it (that copy
    /// had already drifted: ids 188-193's tape fields were missing from it
    /// entirely, so a saved tape setting silently reset to defaults on
    /// reload). Fields on `snap` with no `param_specs` row (`mod_matrix`,
    /// `fx_order`, pattern-player fields, ...) are the caller's job.
    pub fn applyParamSpecs(self: *PolySynth, snap: anytype) void {
        const Snap = @TypeOf(snap.*);
        inline for (param_specs) |spec| {
            if (@hasField(Snap, spec.field)) {
                const val = @field(snap.*, spec.field);
                switch (spec.kind) {
                    .cont, .log, .skew_zero => if (std.math.isFinite(val)) {
                        @field(self.*, spec.field) = std.math.clamp(val, spec.min, spec.max);
                    },
                    .toggle, .cycle => @field(self.*, spec.field) = val,
                    .int_cont => {
                        const lo: i32 = @intFromFloat(spec.min);
                        const hi: i32 = @intFromFloat(spec.max);
                        @field(self.*, spec.field) = @intCast(std.math.clamp(@as(i32, val), lo, hi));
                    },
                }
            }
        }
    }

    /// One row per flat param id `specAdjust`/`specSetAbs`/`specValue`
    /// drive generically - `adjustParam`/`setParamAbsolute`/`paramValue`
    /// used to repeat this id->field->range mapping three times over as
    /// parallel hand-written switches. `.log` nudges by a semitone
    /// ratio per step instead of `.cont`'s linear `+step`, matching the
    /// old cutoff/xover/EQ-freq switch arms. IDs 188-193 (tape) existed in
    /// `automatable_params`/`mod_dest_ids` since the tape FX unit shipped
    /// but were never actually wired into adjust/setAbs/paramValue - h/l,
    /// undo, and automation curves all silently no-op'd on tape params
    /// until this table filled the gap.
    const param_specs = [_]ParamSpec{
        .{ .id = 0, .field = "waveform", .kind = .cycle, .enum_type = Waveform },
        .{ .id = 1, .field = "pulse_width", .min = 0.01, .max = 0.99, .step = 0.01 },
        .{ .id = 2, .field = "detune_cents", .min = -100.0, .max = 100.0, .step = 1.0 },
        .{ .id = 3, .field = "unison", .kind = .int_cont, .min = 1, .max = 16 },
        .{ .id = 4, .field = "unison_detune", .min = 0.0, .max = 100.0, .step = 1.0 },
        .{ .id = 5, .field = "unison_spread", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 6, .field = "osc_b_on", .kind = .toggle },
        .{ .id = 7, .field = "osc_b_waveform", .kind = .cycle, .enum_type = Waveform },
        .{ .id = 8, .field = "osc_b_pulse_width", .min = 0.01, .max = 0.99, .step = 0.01 },
        .{ .id = 9, .field = "osc_b_semi", .min = -24.0, .max = 24.0, .step = 1.0 },
        .{ .id = 10, .field = "osc_b_detune_cents", .min = -100.0, .max = 100.0, .step = 1.0 },
        .{ .id = 11, .field = "osc_b_level", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 12, .field = "osc_b_unison", .kind = .int_cont, .min = 1, .max = 16 },
        .{ .id = 13, .field = "osc_b_unison_detune", .min = 0.0, .max = 100.0, .step = 1.0 },
        .{ .id = 14, .field = "mod_mode", .kind = .cycle, .enum_type = ModMode },
        .{ .id = 15, .field = "mod_amount", .min = 0.0, .max = 8.0, .step = 0.05 },
        .{ .id = 16, .field = "attack_s", .kind = .log, .min = 0.001, .max = 5.0 },
        .{ .id = 17, .field = "decay_s", .kind = .log, .min = 0.001, .max = 5.0 },
        .{ .id = 18, .field = "sustain", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 19, .field = "release_s", .kind = .log, .min = 0.001, .max = 10.0 },
        .{ .id = 246, .field = "env_curve", .min = -1.0, .max = 1.0, .step = 0.01 },
        .{ .id = 20, .field = "filter_type", .kind = .cycle, .enum_type = FilterType },
        .{ .id = 21, .field = "filter_cutoff", .kind = .log, .min = 20.0, .max = 20_000.0 },
        .{ .id = 22, .field = "filter_res", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 249, .field = "filter_drive", .min = 1.0, .max = 16.0, .step = 0.1 },
        // 23 (fenv amount) retired - absorbed into the mod matrix.
        .{ .id = 24, .field = "fenv_attack_s", .kind = .log, .min = 0.001, .max = 5.0 },
        .{ .id = 25, .field = "fenv_decay_s", .kind = .log, .min = 0.001, .max = 5.0 },
        .{ .id = 26, .field = "fenv_sustain", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 27, .field = "fenv_release_s", .kind = .log, .min = 0.001, .max = 10.0 },
        .{ .id = 247, .field = "fenv_curve", .min = -1.0, .max = 1.0, .step = 0.01 },
        .{ .id = 28, .field = "lfo_shape", .kind = .cycle, .enum_type = LfoShape },
        .{ .id = 29, .field = "lfo_rate_hz", .kind = .log, .min = 0.01, .max = 20.0 },
        .{ .id = 256, .field = "lfo_sync", .kind = .cycle, .enum_type = LfoSync },
        .{ .id = 259, .field = "lfo_retrig", .kind = .cycle, .enum_type = LfoRetrig },
        .{ .id = 262, .field = "lfo_phase_offset", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 265, .field = "lfo_slew_ms", .kind = .skew_zero, .min = 0.0, .max = 500.0, .step = 0.01 },
        // 30/31 (LFO depth+target) retired into the mod matrix.
        .{ .id = 32, .field = "voice_mode", .kind = .cycle, .enum_type = VoiceMode },
        .{ .id = 33, .field = "glide_s", .kind = .skew_zero, .min = 0.0, .max = 10.0, .step = 0.01 },
        .{ .id = 34, .field = "sub_level", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 35, .field = "sub_shape", .kind = .cycle, .enum_type = SubShape },
        .{ .id = 36, .field = "noise_level", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 37, .field = "noise_color", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 38, .field = "gain", .min = 0.01, .max = 1.0, .step = 0.01 },
        .{ .id = 39, .field = "unison_mode", .kind = .cycle, .enum_type = UnisonMode },
        .{ .id = 40, .field = "osc_b_unison_mode", .kind = .cycle, .enum_type = UnisonMode },
        .{ .id = 41, .field = "warp_mode", .kind = .cycle, .enum_type = WarpMode },
        .{ .id = 42, .field = "warp_amount", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 43, .field = "osc_b_warp_mode", .kind = .cycle, .enum_type = WarpMode },
        .{ .id = 44, .field = "osc_b_warp_amount", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 45, .field = "filter2_on", .kind = .toggle },
        .{ .id = 46, .field = "filter2_type", .kind = .cycle, .enum_type = FilterType },
        .{ .id = 47, .field = "filter2_cutoff", .kind = .log, .min = 20.0, .max = 20_000.0 },
        .{ .id = 48, .field = "filter2_res", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 250, .field = "filter2_drive", .min = 1.0, .max = 16.0, .step = 0.1 },
        .{ .id = 49, .field = "filter_routing", .kind = .cycle, .enum_type = FilterRouting },
        .{ .id = 50, .field = "osc_c_on", .kind = .toggle },
        .{ .id = 51, .field = "osc_c_waveform", .kind = .cycle, .enum_type = Waveform },
        .{ .id = 52, .field = "osc_c_pulse_width", .min = 0.01, .max = 0.99, .step = 0.01 },
        .{ .id = 53, .field = "osc_c_semi", .min = -24.0, .max = 24.0, .step = 1.0 },
        .{ .id = 54, .field = "osc_c_detune_cents", .min = -100.0, .max = 100.0, .step = 1.0 },
        .{ .id = 55, .field = "osc_c_level", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 56, .field = "osc_c_unison", .kind = .int_cont, .min = 1, .max = 16 },
        .{ .id = 57, .field = "osc_c_unison_detune", .min = 0.0, .max = 100.0, .step = 1.0 },
        .{ .id = 58, .field = "osc_c_unison_mode", .kind = .cycle, .enum_type = UnisonMode },
        // MATRIX (59-82) has its own switch arm below.
        .{ .id = 83, .field = "fx_dist_on", .kind = .toggle },
        .{ .id = 84, .field = "fx_dist_drive_db", .min = 0.0, .max = 36.0, .step = 0.5 },
        .{ .id = 85, .field = "fx_dist_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 86, .field = "fx_crush_on", .kind = .toggle },
        .{ .id = 87, .field = "fx_crush_bits", .min = 1.0, .max = 16.0, .step = 1.0 },
        .{ .id = 88, .field = "fx_crush_rate", .min = 1.0, .max = 64.0, .step = 1.0 },
        .{ .id = 89, .field = "fx_crush_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 90, .field = "fx_flanger_on", .kind = .toggle },
        .{ .id = 91, .field = "fx_flanger_rate_hz", .kind = .log, .min = 0.02, .max = 8.0 },
        .{ .id = 92, .field = "fx_flanger_depth", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 93, .field = "fx_flanger_feedback", .min = 0.0, .max = 0.95, .step = 0.01 },
        .{ .id = 94, .field = "fx_flanger_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 95, .field = "lfo2_shape", .kind = .cycle, .enum_type = LfoShape },
        .{ .id = 96, .field = "lfo2_rate_hz", .kind = .log, .min = 0.01, .max = 20.0 },
        .{ .id = 257, .field = "lfo2_sync", .kind = .cycle, .enum_type = LfoSync },
        .{ .id = 260, .field = "lfo2_retrig", .kind = .cycle, .enum_type = LfoRetrig },
        .{ .id = 263, .field = "lfo2_phase_offset", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 266, .field = "lfo2_slew_ms", .kind = .skew_zero, .min = 0.0, .max = 500.0, .step = 0.01 },
        .{ .id = 97, .field = "lfo3_shape", .kind = .cycle, .enum_type = LfoShape },
        .{ .id = 98, .field = "lfo3_rate_hz", .kind = .log, .min = 0.01, .max = 20.0 },
        .{ .id = 258, .field = "lfo3_sync", .kind = .cycle, .enum_type = LfoSync },
        .{ .id = 261, .field = "lfo3_retrig", .kind = .cycle, .enum_type = LfoRetrig },
        .{ .id = 264, .field = "lfo3_phase_offset", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 267, .field = "lfo3_slew_ms", .kind = .skew_zero, .min = 0.0, .max = 500.0, .step = 0.01 },
        .{ .id = 99, .field = "macro1", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 100, .field = "macro2", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 101, .field = "macro3", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 102, .field = "macro4", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 103, .field = "fx_phaser_on", .kind = .toggle },
        .{ .id = 104, .field = "fx_phaser_rate_hz", .kind = .log, .min = 0.02, .max = 8.0 },
        .{ .id = 105, .field = "fx_phaser_depth", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 106, .field = "fx_phaser_feedback", .min = 0.0, .max = 0.95, .step = 0.01 },
        .{ .id = 107, .field = "fx_phaser_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 108, .field = "fx_delay_on", .kind = .toggle },
        .{ .id = 109, .field = "fx_delay_time_s", .kind = .log, .min = 0.001, .max = fx_delay_max_time_s },
        .{ .id = 110, .field = "fx_delay_feedback", .min = 0.0, .max = 0.95, .step = 0.01 },
        .{ .id = 111, .field = "fx_delay_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 112, .field = "fx_reverb_on", .kind = .toggle },
        .{ .id = 113, .field = "fx_reverb_room", .min = 0.0, .max = 0.98, .step = 0.01 },
        .{ .id = 114, .field = "fx_reverb_damp", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 115, .field = "fx_reverb_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 116, .field = "arp_on", .kind = .toggle },
        .{ .id = 117, .field = "arp_mode", .kind = .cycle, .enum_type = ArpMode },
        .{ .id = 118, .field = "arp_octaves", .kind = .int_cont, .min = 1, .max = max_arp_octaves },
        .{ .id = 119, .field = "arp_rate_hz", .kind = .log, .min = 0.1, .max = 20.0 },
        .{ .id = 268, .field = "arp_sync", .kind = .cycle, .enum_type = LfoSync },
        .{ .id = 120, .field = "arp_gate", .min = 0.02, .max = 1.0, .step = 0.01 },
        .{ .id = 121, .field = "arp_hold", .kind = .toggle },
        .{ .id = 122, .field = "env3_attack_s", .kind = .log, .min = 0.001, .max = 5.0 },
        .{ .id = 123, .field = "env3_decay_s", .kind = .log, .min = 0.001, .max = 5.0 },
        .{ .id = 124, .field = "env3_sustain", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 125, .field = "env3_release_s", .kind = .log, .min = 0.001, .max = 10.0 },
        .{ .id = 248, .field = "env3_curve", .min = -1.0, .max = 1.0, .step = 0.01 },
        // FX reorder handles (126-131, 136, 143, 160, 166, 175, 180, 184,
        // 194) are in `fx_reorder_ids` below, not here.
        .{ .id = 132, .field = "fx_gate_on", .kind = .toggle },
        .{ .id = 133, .field = "fx_gate_threshold_db", .min = -80.0, .max = 0.0, .step = 1.0 },
        .{ .id = 134, .field = "fx_gate_attack_ms", .kind = .log, .min = 0.1, .max = 50.0 },
        .{ .id = 135, .field = "fx_gate_release_ms", .kind = .log, .min = 5.0, .max = 1000.0 },
        .{ .id = 137, .field = "fx_comp_on", .kind = .toggle },
        .{ .id = 138, .field = "fx_comp_threshold_db", .min = -60.0, .max = 0.0, .step = 1.0 },
        .{ .id = 139, .field = "fx_comp_ratio", .min = 1.0, .max = 20.0, .step = 0.1 },
        .{ .id = 140, .field = "fx_comp_attack_ms", .kind = .log, .min = 0.1, .max = 500.0 },
        .{ .id = 141, .field = "fx_comp_release_ms", .kind = .log, .min = 1.0, .max = 2000.0 },
        .{ .id = 142, .field = "fx_comp_makeup_db", .min = -24.0, .max = 24.0, .step = 0.5 },
        .{ .id = 144, .field = "fx_mb_on", .kind = .toggle },
        .{ .id = 145, .field = "fx_mb_xover_lo", .kind = .log, .min = 20.0, .max = 20_000.0 },
        .{ .id = 146, .field = "fx_mb_xover_hi", .kind = .log, .min = 20.0, .max = 20_000.0 },
        .{ .id = 147, .field = "fx_mb_attack_ms", .kind = .log, .min = 0.1, .max = 500.0 },
        .{ .id = 148, .field = "fx_mb_release_ms", .kind = .log, .min = 1.0, .max = 2000.0 },
        .{ .id = 149, .field = "fx_mb_style", .kind = .cycle, .enum_type = MbStyle },
        .{ .id = 150, .field = "fx_mb_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 151, .field = "fx_mb_low_threshold_db", .min = -60.0, .max = 0.0, .step = 1.0 },
        .{ .id = 152, .field = "fx_mb_low_ratio", .min = 1.0, .max = 20.0, .step = 0.1 },
        .{ .id = 153, .field = "fx_mb_low_makeup_db", .min = -24.0, .max = 24.0, .step = 0.5 },
        .{ .id = 154, .field = "fx_mb_mid_threshold_db", .min = -60.0, .max = 0.0, .step = 1.0 },
        .{ .id = 155, .field = "fx_mb_mid_ratio", .min = 1.0, .max = 20.0, .step = 0.1 },
        .{ .id = 156, .field = "fx_mb_mid_makeup_db", .min = -24.0, .max = 24.0, .step = 0.5 },
        .{ .id = 157, .field = "fx_mb_high_threshold_db", .min = -60.0, .max = 0.0, .step = 1.0 },
        .{ .id = 158, .field = "fx_mb_high_ratio", .min = 1.0, .max = 20.0, .step = 0.1 },
        .{ .id = 159, .field = "fx_mb_high_makeup_db", .min = -24.0, .max = 24.0, .step = 0.5 },
        .{ .id = 161, .field = "fx_ott_on", .kind = .toggle },
        .{ .id = 162, .field = "fx_ott_depth", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 163, .field = "fx_ott_time", .min = 0.25, .max = 4.0, .step = 0.05 },
        .{ .id = 164, .field = "fx_ott_gain_in_db", .min = -24.0, .max = 24.0, .step = 0.5 },
        .{ .id = 165, .field = "fx_ott_gain_out_db", .min = -24.0, .max = 24.0, .step = 0.5 },
        .{ .id = 167, .field = "fx_eq_on", .kind = .toggle },
        .{ .id = 168, .field = "fx_eq_low_freq", .kind = .log, .min = 20.0, .max = 20_000.0 },
        .{ .id = 169, .field = "fx_eq_low_gain_db", .min = -18.0, .max = 18.0, .step = 0.5 },
        .{ .id = 170, .field = "fx_eq_mid_freq", .kind = .log, .min = 20.0, .max = 20_000.0 },
        .{ .id = 171, .field = "fx_eq_mid_gain_db", .min = -18.0, .max = 18.0, .step = 0.5 },
        .{ .id = 172, .field = "fx_eq_mid_q", .kind = .log, .min = 0.1, .max = 10.0 },
        .{ .id = 173, .field = "fx_eq_high_freq", .kind = .log, .min = 20.0, .max = 20_000.0 },
        .{ .id = 174, .field = "fx_eq_high_gain_db", .min = -18.0, .max = 18.0, .step = 0.5 },
        .{ .id = 176, .field = "fx_chorus_on", .kind = .toggle },
        .{ .id = 177, .field = "fx_chorus_rate_hz", .kind = .log, .min = 0.05, .max = 5.0 },
        .{ .id = 178, .field = "fx_chorus_depth_ms", .min = 0.0, .max = fx_chorus_max_depth_ms, .step = 0.1 },
        .{ .id = 179, .field = "fx_chorus_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 181, .field = "fx_freq_shift_on", .kind = .toggle },
        .{ .id = 182, .field = "fx_freq_shift_hz", .min = -2000.0, .max = 2000.0, .step = 1.0 },
        .{ .id = 183, .field = "fx_freq_shift_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
        // WAVETABLE frame position, one per oscillator.
        .{ .id = 185, .field = "wt_pos", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 186, .field = "osc_b_wt_pos", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 187, .field = "osc_c_wt_pos", .min = 0.0, .max = 1.0, .step = 0.01 },
        // FX TAPE (188-193), reorder handle 194 in `fx_reorder_ids`.
        .{ .id = 188, .field = "fx_tape_on", .kind = .toggle },
        .{ .id = 189, .field = "fx_tape_wow_rate_hz", .kind = .log, .min = 0.05, .max = 3.0 },
        .{ .id = 190, .field = "fx_tape_wow_depth", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 191, .field = "fx_tape_flutter_rate_hz", .kind = .log, .min = 3.0, .max = 15.0 },
        .{ .id = 192, .field = "fx_tape_flutter_depth", .min = 0.0, .max = 1.0, .step = 0.01 },
        .{ .id = 193, .field = "fx_tape_mix", .min = 0.0, .max = 1.0, .step = 0.01 },
    };

    /// `kind`'s reorder-handle id → the FX unit it walks in `fx_order`; not
    /// real params (no `automatable_params`/`mod_dest_ids` entry, no editor
    /// row of its own - the FX subview's `</>` sends whichever unit's id
    /// the cursor currently sits in). `adjustParam` calls `reorderFx`,
    /// `setParamAbsolute` calls `setFxIndex`, `paramValue` calls
    /// `fxOrderIndex` - this list drives all three instead of repeating the
    /// id->kind mapping three times over.
    const fx_reorder_ids = [_]struct { id: u16, kind: FxUnitKind }{
        .{ .id = 126, .kind = .dist },
        .{ .id = 127, .kind = .crush },
        .{ .id = 128, .kind = .flanger },
        .{ .id = 129, .kind = .phaser },
        .{ .id = 130, .kind = .delay },
        .{ .id = 131, .kind = .reverb },
        .{ .id = 136, .kind = .gate },
        .{ .id = 143, .kind = .comp },
        .{ .id = 160, .kind = .mb_comp },
        .{ .id = 166, .kind = .ott },
        .{ .id = 175, .kind = .eq },
        .{ .id = 180, .kind = .chorus },
        .{ .id = 184, .kind = .freq_shift },
        .{ .id = 194, .kind = .tape },
    };

    const LfoCustomAddr = union(enum) {
        point: struct { slot: u8, index: u8, is_value: bool },
        count: struct { slot: u8 },
    };

    /// Decodes an id already known (by the caller's own `lfo_custom_id_base
    /// ... +50` switch range - mirrors the MATRIX case's `59...82`) into
    /// which `.custom` LFO slot/point/field it addresses. Shared by
    /// `adjustParam`/`setParamAbsolute`/`paramValue` so the id layout is
    /// computed once instead of three times over.
    fn decodeLfoCustomId(id: u16) LfoCustomAddr {
        const rel = id - lfo_custom_id_base;
        const slot: u8 = @intCast(rel / lfo_custom_ids_per_slot);
        const within: u8 = @intCast(rel % lfo_custom_ids_per_slot);
        if (within == max_lfo_shape_points * 2) return .{ .count = .{ .slot = slot } };
        return .{ .point = .{ .slot = slot, .index = within / 2, .is_value = within % 2 == 1 } };
    }

    /// Nudge the editor parameter at `id` by `steps` (h/l = ±1, H/L = ±10).
    /// Runs on the audio thread (via the `set_param` event) so it never races
    /// the block reader - the editor sends edits over the command queue rather
    /// than writing these fields directly.
    pub fn adjustParam(self: *PolySynth, id: u16, steps: i32) void {
        if (matrixParamAddr(id)) |addr| {
            const row = &self.mod_matrix[addr.row];
            switch (addr.field) {
                0 => row.source = cycleEnum(ModSource, row.source, steps),
                1 => {
                    const n: i32 = mod_dest_ids.len;
                    const cur: i32 = @intCast(modDestIndex(row.dest) orelse 0);
                    row.dest = mod_dest_ids[@intCast(@mod(@as(i64, cur) + @as(i64, steps), n))];
                },
                2 => row.depth = std.math.clamp(row.depth + @as(f32, @floatFromInt(steps)) * 0.01, -1.0, 1.0),
                else => unreachable,
            }
            return;
        }
        switch (id) {
            // fx_mb_style: h/l always picks classic/ott by direction, not a
            // wrap (see `param_specs`'s note on id 149).
            149 => {
                self.fx_mb_style = if (steps > 0) .ott else .classic;
                return;
            },
            mod_unipolar_id_base...mod_unipolar_id_base + max_mod_rows - 1 => {
                if (steps != 0) {
                    const row = &self.mod_matrix[id - mod_unipolar_id_base];
                    row.unipolar = !row.unipolar;
                }
                return;
            },
            // `.custom` LFO shape points - see decodeLfoCustomId's doc
            // comment. `count` steps one point per press (H/L jumps 10,
            // clamped to the fixed capacity); phase/value nudge like any
            // other 0..1/-1..1 param.
            lfo_custom_id_base...lfo_custom_id_base + 3 * lfo_custom_ids_per_slot - 1 => {
                switch (decodeLfoCustomId(id)) {
                    .count => |c| {
                        const cur: i64 = self.lfo_custom_count[c.slot];
                        self.setLfoCustomCount(c.slot, @intCast(std.math.clamp(cur + @as(i64, steps), 0, @as(i64, max_lfo_shape_points))));
                    },
                    .point => |p| {
                        const step_amt: f32 = @as(f32, @floatFromInt(steps)) * 0.01;
                        const pt = &self.lfo_custom[p.slot][p.index];
                        if (p.is_value) {
                            pt.value = std.math.clamp(pt.value + step_amt, -1.0, 1.0);
                        } else {
                            self.setLfoCustomPhase(p.slot, p.index, pt.phase + step_amt);
                        }
                    },
                }
                return;
            },
            else => {},
        }
        inline for (param_specs) |spec| {
            if (spec.id == id) return specAdjust(self, spec, steps);
        }
        inline for (fx_reorder_ids) |r| {
            if (r.id == id) return self.reorderFx(r.kind, steps);
        }
    }

    /// Absolute-value counterpart to `adjustParam`, for automation curves
    /// (which know the value they want at a beat position directly, not a
    /// delta from wherever the param last was - see `Event.set_param_abs`)
    /// and for undo's capture/restore (`paramValue` is the read half).
    /// Every continuous param `adjustParam` handles is wired here with the
    /// exact same clamp range; enum/toggle ids take the variant's 0-based
    /// ordinal (toggles: >= 0.5 is on) - automation never targets them
    /// (they're not in `automatable_params`), only undo restores them this
    /// way.
    pub fn setParamAbsolute(self: *PolySynth, id: u16, value: f32) void {
        if (!std.math.isFinite(value)) return;
        if (matrixParamAddr(id)) |addr| {
            const row = &self.mod_matrix[addr.row];
            switch (addr.field) {
                0 => row.source = enumFromValue(ModSource, value),
                1 => {
                    const d: u16 = if (value > 0.0 and value <= 65535.0) @intFromFloat(@round(value)) else 21;
                    row.dest = if (modDestIndex(d) != null) d else 21;
                },
                2 => row.depth = std.math.clamp(value, -1.0, 1.0),
                else => unreachable,
            }
            return;
        }
        switch (id) {
            mod_unipolar_id_base...mod_unipolar_id_base + max_mod_rows - 1 => {
                self.mod_matrix[id - mod_unipolar_id_base].unipolar = value >= 0.5;
                return;
            },
            // `.custom` LFO shape points - see decodeLfoCustomId's doc
            // comment. This is the id range the curve widget's mouse drag/
            // insert/remove edits actually go through (adjustParam's h/l
            // nudge above only matters for keyboard-only editing).
            lfo_custom_id_base...lfo_custom_id_base + 3 * lfo_custom_ids_per_slot - 1 => {
                switch (decodeLfoCustomId(id)) {
                    .count => |c| self.setLfoCustomCount(c.slot, @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(value))), 0, @as(i32, max_lfo_shape_points)))),
                    .point => |p| {
                        const pt = &self.lfo_custom[p.slot][p.index];
                        if (p.is_value) {
                            pt.value = std.math.clamp(value, -1.0, 1.0);
                        } else {
                            self.setLfoCustomPhase(p.slot, p.index, value);
                        }
                    },
                }
                return;
            },
            else => {},
        }
        inline for (param_specs) |spec| {
            if (spec.id == id) return specSetAbs(self, spec, value);
        }
        // FX reorder handles: value is the unit's absolute fx_order slot
        // index; see `setFxIndex`'s doc comment for why undo/redo routes
        // reordering through here instead of `adjustParam`. Only the lower
        // bound is clamped here: `setFxIndex` itself clamps the upper end
        // to the real (growing) slot count.
        inline for (fx_reorder_ids) |r| {
            if (r.id == id) return self.setFxIndex(r.kind, @intFromFloat(@round(@max(value, 0.0))));
        }
    }

    /// Current value of editor param `id`, in the same unit/encoding
    /// `setParamAbsolute` accepts (enums/toggles as 0-based ordinals) - the
    /// read half of undo's capture/restore pair. A control-thread read of
    /// live fields, same race-tolerant convention the synth editor's own
    /// row rendering already uses. Null for unknown ids.
    /// True for boolean on/off params (`param_specs` rows with `.kind =
    /// .toggle`) - lets editors draw these as a single toggle button instead
    /// of a generic -/+ stepper, without hand-keeping a second id list.
    pub fn isToggleParam(id: u16) bool {
        if (id >= mod_unipolar_id_base and id < mod_unipolar_id_base + max_mod_rows) return true;
        inline for (param_specs) |spec| {
            if (spec.id == id) return spec.kind == .toggle;
        }
        return false;
    }

    pub fn paramValue(self: *const PolySynth, id: u16) ?f32 {
        if (matrixParamAddr(id)) |addr| {
            const row = self.mod_matrix[addr.row];
            return switch (addr.field) {
                0 => enumToValue(row.source),
                1 => @floatFromInt(row.dest),
                2 => row.depth,
                else => unreachable,
            };
        }
        switch (id) {
            mod_unipolar_id_base...mod_unipolar_id_base + max_mod_rows - 1 => {
                return if (self.mod_matrix[id - mod_unipolar_id_base].unipolar) 1.0 else 0.0;
            },
            lfo_custom_id_base...lfo_custom_id_base + 3 * lfo_custom_ids_per_slot - 1 => {
                return switch (decodeLfoCustomId(id)) {
                    .count => |c| @floatFromInt(self.lfo_custom_count[c.slot]),
                    .point => |p| if (p.is_value) self.lfo_custom[p.slot][p.index].value else self.lfo_custom[p.slot][p.index].phase,
                };
            },
            else => {},
        }
        inline for (param_specs) |spec| {
            if (spec.id == id) return specValue(self, spec);
        }
        inline for (fx_reorder_ids) |r| {
            if (r.id == id) return @floatFromInt(self.fxOrderIndex(r.kind));
        }
        return null;
    }

    /// One entry per `setParamAbsolute`-handled id - the shared metadata the
    /// automation editor's param picker, curve labels, and h/l nudge step all
    /// need. `label` is the short in-graph tag (matches the synth editor's own
    /// row labels where practical); `section` groups the picker's listing the
    /// same way the synth editor's own KEY/OSC A/OSC B/... rows are grouped.
    /// Shared shape with Sampler's own table - see `dsp.AutomatableParam`.
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
        .{ .id = 246,.label = "ENV CURVE",  .section = "ENV",     .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 21, .label = "CUTOFF",     .section = "FILTER",  .range = .{ 20.0,   20_000.0 },.step = 100.0 },
        .{ .id = 22, .label = "RESONANCE",  .section = "FILTER",  .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 249,.label = "DRIVE",      .section = "FILTER",  .range = .{ 1.0,    16.0 },    .step = 0.1 },
        .{ .id = 24, .label = "FENV ATK",   .section = "FENV",    .range = .{ 0.001,  5.0 },     .step = 0.01 },
        .{ .id = 25, .label = "FENV DEC",   .section = "FENV",    .range = .{ 0.001,  5.0 },     .step = 0.01 },
        .{ .id = 26, .label = "FENV SUS",   .section = "FENV",    .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 27, .label = "FENV REL",   .section = "FENV",    .range = .{ 0.001,  10.0 },    .step = 0.01 },
        .{ .id = 247,.label = "FENV CURVE", .section = "FENV",    .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 29, .label = "LFO RATE",   .section = "LFO",     .range = .{ 0.01,   20.0 },    .step = 0.1 },
        .{ .id = 262,.label = "LFO PHASE",  .section = "LFO",     .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 265,.label = "LFO SLEW",   .section = "LFO",     .range = .{ 0.0,    500.0 },   .step = 5.0 },
        .{ .id = 33, .label = "GLIDE",      .section = "VOICE",   .range = .{ 0.0,    10.0 },    .step = 0.01 },
        .{ .id = 34, .label = "SUB LEVEL",  .section = "SUB",     .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 36, .label = "NOISE LVL",  .section = "NOISE",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 37, .label = "NOISE CLR",  .section = "NOISE",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 38, .label = "OUT GAIN",   .section = "OUT",     .range = .{ 0.01,   1.0 },     .step = 0.01 },
        .{ .id = 42, .label = "WARP AMT A", .section = "OSC A",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 44, .label = "WARP AMT B", .section = "OSC B",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 47, .label = "CUTOFF 2",   .section = "FILTER 2",.range = .{ 20.0,   20_000.0 },.step = 100.0 },
        .{ .id = 48, .label = "RESONANCE 2",.section = "FILTER 2",.range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 250,.label = "DRIVE 2",    .section = "FILTER 2",.range = .{ 1.0,    16.0 },    .step = 0.1 },
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
        .{ .id = 303,.label = "MT9 DEPTH",  .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 306,.label = "MT10 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 309,.label = "MT11 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 312,.label = "MT12 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 315,.label = "MT13 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 318,.label = "MT14 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 321,.label = "MT15 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 324,.label = "MT16 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 327,.label = "MT17 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 330,.label = "MT18 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 333,.label = "MT19 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 336,.label = "MT20 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 339,.label = "MT21 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 342,.label = "MT22 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 345,.label = "MT23 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 348,.label = "MT24 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 351,.label = "MT25 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 354,.label = "MT26 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 357,.label = "MT27 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 360,.label = "MT28 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 363,.label = "MT29 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 366,.label = "MT30 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 369,.label = "MT31 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 372,.label = "MT32 DEPTH", .section = "MATRIX",  .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 84, .label = "DIST DRIVE", .section = "FX DIST", .range = .{ 0.0,    36.0 },    .step = 0.5 },
        .{ .id = 85, .label = "DIST MIX",   .section = "FX DIST", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 87, .label = "CRUSH BITS", .section = "FX CRUSH",.range = .{ 1.0,    16.0 },    .step = 1.0 },
        .{ .id = 88, .label = "CRUSH RATE", .section = "FX CRUSH",.range = .{ 1.0,    64.0 },    .step = 1.0 },
        .{ .id = 89, .label = "CRUSH MIX",  .section = "FX CRUSH",.range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 91, .label = "FLNG RATE",  .section = "FX FLNG", .range = .{ 0.02,   8.0 },     .step = 0.05 },
        .{ .id = 92, .label = "FLNG DEPTH", .section = "FX FLNG", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 93, .label = "FLNG FDBK",  .section = "FX FLNG", .range = .{ 0.0,    0.95 },    .step = 0.01 },
        .{ .id = 94, .label = "FLNG MIX",   .section = "FX FLNG", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 104,.label = "PHSR RATE",  .section = "FX PHSR", .range = .{ 0.02,   8.0 },     .step = 0.05 },
        .{ .id = 105,.label = "PHSR DEPTH", .section = "FX PHSR", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 106,.label = "PHSR FDBK",  .section = "FX PHSR", .range = .{ 0.0,    0.95 },    .step = 0.01 },
        .{ .id = 107,.label = "PHSR MIX",   .section = "FX PHSR", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 109,.label = "DLY TIME",   .section = "FX DELAY",.range = .{ 0.001,  fx_delay_max_time_s },.step = 0.01 },
        .{ .id = 110,.label = "DLY FDBK",   .section = "FX DELAY",.range = .{ 0.0,    0.95 },    .step = 0.01 },
        .{ .id = 111,.label = "DLY MIX",    .section = "FX DELAY",.range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 113,.label = "VRB ROOM",   .section = "FX VERB", .range = .{ 0.0,    0.98 },    .step = 0.01 },
        .{ .id = 114,.label = "VRB DAMP",   .section = "FX VERB", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 115,.label = "VRB MIX",    .section = "FX VERB", .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 96, .label = "LFO2 RATE",  .section = "LFO 2",   .range = .{ 0.01,   20.0 },    .step = 0.1 },
        .{ .id = 263,.label = "LFO2 PHASE", .section = "LFO 2",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 266,.label = "LFO2 SLEW",  .section = "LFO 2",   .range = .{ 0.0,    500.0 },   .step = 5.0 },
        .{ .id = 98, .label = "LFO3 RATE",  .section = "LFO 3",   .range = .{ 0.01,   20.0 },    .step = 0.1 },
        .{ .id = 264,.label = "LFO3 PHASE", .section = "LFO 3",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 267,.label = "LFO3 SLEW",  .section = "LFO 3",   .range = .{ 0.0,    500.0 },   .step = 5.0 },
        // Macros: an automation lane on one macro rides every destination
        // its matrix rows fan out to. Not matrix dests themselves (a row
        // reading a matrix-shifted macro would need eval ordering).
        .{ .id = 99,  .label = "MACRO 1",   .section = "MACRO",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 100, .label = "MACRO 2",   .section = "MACRO",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 101, .label = "MACRO 3",   .section = "MACRO",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 102, .label = "MACRO 4",   .section = "MACRO",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        // Rate/gate only - like the LFO rates, not matrix dests (mode/
        // octaves/on/hold are enum/toggle-only, undo-restore reads them via
        // paramValue but automation curves never target them).
        .{ .id = 119, .label = "ARP RATE",  .section = "ARP",     .range = .{ 0.1,    20.0 },    .step = 0.1 },
        .{ .id = 120, .label = "ARP GATE",  .section = "ARP",     .range = .{ 0.02,   1.0 },     .step = 0.01 },
        .{ .id = 122,.label = "E3 ATTACK",  .section = "ENV 3",   .range = .{ 0.001,  5.0 },     .step = 0.01 },
        .{ .id = 123,.label = "E3 DECAY",   .section = "ENV 3",   .range = .{ 0.001,  5.0 },     .step = 0.01 },
        .{ .id = 124,.label = "E3 SUSTAIN", .section = "ENV 3",   .range = .{ 0.0,    1.0 },     .step = 0.01 },
        .{ .id = 125,.label = "E3 RELEASE", .section = "ENV 3",   .range = .{ 0.001,  10.0 },    .step = 0.01 },
        .{ .id = 248,.label = "E3 CURVE",   .section = "ENV 3",   .range = .{ -1.0,   1.0 },     .step = 0.01 },
        .{ .id = 133,.label = "GATE THRESH",.section = "FX GATE", .range = .{ -80.0,  0.0 },     .step = 1.0 },
        .{ .id = 134,.label = "GATE ATTACK",.section = "FX GATE", .range = .{ 0.1,    50.0 },    .step = 0.1 },
        .{ .id = 135,.label = "GATE RELEASE",.section = "FX GATE",.range = .{ 5.0,    1000.0 },  .step = 10.0 },
        .{ .id = 138,.label = "COMP THRESH", .section = "FX COMP", .range = .{ -60.0,  0.0 },    .step = 1.0 },
        .{ .id = 139,.label = "COMP RATIO",  .section = "FX COMP", .range = .{ 1.0,    20.0 },   .step = 0.5 },
        .{ .id = 140,.label = "COMP ATTACK", .section = "FX COMP", .range = .{ 0.1,    500.0 },  .step = 1.0 },
        .{ .id = 141,.label = "COMP RELEASE",.section = "FX COMP", .range = .{ 1.0,    2000.0 }, .step = 10.0 },
        .{ .id = 142,.label = "COMP MAKEUP", .section = "FX COMP", .range = .{ -24.0,  24.0 },   .step = 0.5 },
        .{ .id = 145,.label = "MB XOVER LO", .section = "FX MB",   .range = .{ 20.0,   20000.0 },.step = 10.0 },
        .{ .id = 146,.label = "MB XOVER HI", .section = "FX MB",   .range = .{ 20.0,   20000.0 },.step = 10.0 },
        .{ .id = 147,.label = "MB ATTACK",   .section = "FX MB",   .range = .{ 0.1,    500.0 },  .step = 1.0 },
        .{ .id = 148,.label = "MB RELEASE",  .section = "FX MB",   .range = .{ 1.0,    2000.0 }, .step = 10.0 },
        .{ .id = 150,.label = "MB MIX",      .section = "FX MB",   .range = .{ 0.0,    1.0 },    .step = 0.01 },
        .{ .id = 151,.label = "MB LO THRESH",.section = "FX MB",   .range = .{ -60.0,  0.0 },    .step = 1.0 },
        .{ .id = 152,.label = "MB LO RATIO", .section = "FX MB",   .range = .{ 1.0,    20.0 },   .step = 0.5 },
        .{ .id = 153,.label = "MB LO MAKEUP",.section = "FX MB",   .range = .{ -24.0,  24.0 },   .step = 0.5 },
        .{ .id = 154,.label = "MB MD THRESH",.section = "FX MB",   .range = .{ -60.0,  0.0 },    .step = 1.0 },
        .{ .id = 155,.label = "MB MD RATIO", .section = "FX MB",   .range = .{ 1.0,    20.0 },   .step = 0.5 },
        .{ .id = 156,.label = "MB MD MAKEUP",.section = "FX MB",   .range = .{ -24.0,  24.0 },   .step = 0.5 },
        .{ .id = 157,.label = "MB HI THRESH",.section = "FX MB",   .range = .{ -60.0,  0.0 },    .step = 1.0 },
        .{ .id = 158,.label = "MB HI RATIO", .section = "FX MB",   .range = .{ 1.0,    20.0 },   .step = 0.5 },
        .{ .id = 159,.label = "MB HI MAKEUP",.section = "FX MB",   .range = .{ -24.0,  24.0 },   .step = 0.5 },
        .{ .id = 162,.label = "OTT DEPTH",   .section = "FX OTT",  .range = .{ 0.0,    1.0 },    .step = 0.01 },
        .{ .id = 163,.label = "OTT TIME",    .section = "FX OTT",  .range = .{ 0.25,   4.0 },    .step = 0.05 },
        .{ .id = 164,.label = "OTT GAIN IN", .section = "FX OTT",  .range = .{ -24.0,  24.0 },   .step = 0.5 },
        .{ .id = 165,.label = "OTT GAIN OUT",.section = "FX OTT",  .range = .{ -24.0,  24.0 },   .step = 0.5 },
        .{ .id = 168,.label = "EQ LO FREQ",  .section = "FX EQ",   .range = .{ 20.0,   20000.0 },.step = 10.0 },
        .{ .id = 169,.label = "EQ LO GAIN",  .section = "FX EQ",   .range = .{ -18.0,  18.0 },   .step = 0.5 },
        .{ .id = 170,.label = "EQ MID FREQ", .section = "FX EQ",   .range = .{ 20.0,   20000.0 },.step = 10.0 },
        .{ .id = 171,.label = "EQ MID GAIN", .section = "FX EQ",   .range = .{ -18.0,  18.0 },   .step = 0.5 },
        .{ .id = 172,.label = "EQ MID Q",    .section = "FX EQ",   .range = .{ 0.1,    10.0 },   .step = 0.05 },
        .{ .id = 173,.label = "EQ HI FREQ",  .section = "FX EQ",   .range = .{ 20.0,   20000.0 },.step = 10.0 },
        .{ .id = 174,.label = "EQ HI GAIN",  .section = "FX EQ",   .range = .{ -18.0,  18.0 },   .step = 0.5 },
        .{ .id = 177,.label = "CHOR RATE",   .section = "FX CHOR", .range = .{ 0.05,   5.0 },    .step = 0.05 },
        .{ .id = 178,.label = "CHOR DEPTH",  .section = "FX CHOR", .range = .{ 0.0,    10.0 },   .step = 0.1 },
        .{ .id = 179,.label = "CHOR MIX",    .section = "FX CHOR", .range = .{ 0.0,    1.0 },    .step = 0.01 },
        .{ .id = 182,.label = "FRQS SHIFT",  .section = "FX FRQS", .range = .{ -2000.0,2000.0 }, .step = 1.0 },
        .{ .id = 183,.label = "FRQS MIX",    .section = "FX FRQS", .range = .{ 0.0,    1.0 },    .step = 0.01 },
        .{ .id = 185,.label = "WT POS A",    .section = "OSC A",   .range = .{ 0.0,    1.0 },    .step = 0.01 },
        .{ .id = 186,.label = "WT POS B",    .section = "OSC B",   .range = .{ 0.0,    1.0 },    .step = 0.01 },
        .{ .id = 187,.label = "WT POS C",    .section = "OSC C",   .range = .{ 0.0,    1.0 },    .step = 0.01 },
        .{ .id = 189,.label = "TAPE WOW RATE",  .section = "FX TAPE", .range = .{ 0.05,  3.0 },  .step = 0.05 },
        .{ .id = 190,.label = "TAPE WOW DEPTH", .section = "FX TAPE", .range = .{ 0.0,   1.0 },  .step = 0.01 },
        .{ .id = 191,.label = "TAPE FLT RATE",  .section = "FX TAPE", .range = .{ 3.0,   15.0 }, .step = 0.1 },
        .{ .id = 192,.label = "TAPE FLT DEPTH", .section = "FX TAPE", .range = .{ 0.0,   1.0 },  .step = 0.01 },
        .{ .id = 193,.label = "TAPE MIX",       .section = "FX TAPE", .range = .{ 0.0,   1.0 },  .step = 0.01 },
        // zig fmt: on
    };

    pub fn findAutomatableParam(id: u16) ?*const AutomatableParam {
        for (&automatable_params) |*p| if (p.id == id) return p;
        return null;
    }

    /// Apply a MIDI pitch bend. `bend` is −8192..+8191; `range_semitones` = ±range.
    pub fn applyPitchBend(self: *PolySynth, bend: i16, range_semitones: f32) void {
        self.pitch_bend_semitones = @as(f32, @floatFromInt(bend)) / 8192.0 * range_semitones;
    }

    fn ccWaveform(value: u7) Waveform {
        const n = @typeInfo(Waveform).@"enum".fields.len;
        return @enumFromInt(@min(n - 1, @as(usize, value) * n / 128));
    }

    fn ccCutoff(value: u7) f32 {
        // Logarithmic: 0 → 20 Hz, 127 → 18 000 Hz.
        return 20.0 * std.math.pow(f32, 900.0, @as(f32, @floatFromInt(value)) / 127.0);
    }

    pub fn handleEvent(self: *PolySynth, ev: dsp.Event) void {
        switch (ev) {
            // zig fmt: off
            .note_on    => |e| self.noteOn(e.note, e.velocity),
            .note_off   => |e| self.noteOff(e.note),
            .all_off    => self.resetAll(),
            .cc         => |e| self.applyCC(e.cc, e.value),
            .pitch_bend => |e| self.applyPitchBend(e.bend, 2.0),
            .set_param  => |e| self.adjustParam(e.id, e.steps),
            // zig fmt: on
            .set_param_abs => |e| self.setParamAbsolute(e.id, e.value),
            .automation_param => |e| if (e.id <= std.math.maxInt(u16)) self.setParamAbsolute(@intCast(e.id), e.value),
            .clap_param, .vst3_param, .set_sidechain_buf, .capture_pad => {},
        }
    }

    /// `deviceOf`'s expected name; forwards to `resetAll`.
    pub fn reset(self: *PolySynth) void {
        self.resetAll();
    }
};

/// Render `blocks` and fail on the first non-finite sample - the standard
/// smoke test for a filter/LFO/oscillator setting that could blow a voice up.
fn expectStaysFinite(synth: *PolySynth, blocks: usize) !void {
    var buf: [512]Sample = undefined;
    for (0..blocks) |_| {
        @memset(&buf, 0.0);
        synth.processBlock(&buf);
        for (buf) |s| try std.testing.expect(std.math.isFinite(s));
    }
}

test "A4 tuning" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), PolySynth.noteToFreq(69), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 261.63), PolySynth.noteToFreq(60), 0.01);
}

test "filter: high-Q sweep near Nyquist stays finite" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.filter_cutoff = 22_000.0;
    synth.filter_res = 1.0;
    synth.noteOn(60, 1.0);

    try expectStaysFinite(&synth, 32);
}

test "filter: all types stay finite under resonance" {
    const types_to_test = [_]FilterType{ .lp, .hp, .bp, .notch, .ladder, .diode, .comb, .formant };
    for (types_to_test) |ft| {
        var synth = try PolySynth.init(std.testing.allocator, 48_000);
        defer synth.deinit();
        synth.filter_type = ft;
        synth.filter_cutoff = 1_000.0;
        synth.filter_res = 0.9;
        synth.noteOn(60, 1.0);
        try expectStaysFinite(&synth, 16);
    }
}

/// Shared body for the "closed cutoff attenuates like a lowpass" test
/// family: a saw at 200 Hz cutoff must carry <10% of the RMS energy the
/// same saw has with the filter wide open.
fn expectClosedCutoffAttenuates(filter_type: FilterType) !void {
    var open = try PolySynth.init(std.testing.allocator, 48_000);
    defer open.deinit();
    open.waveform = .saw;
    open.filter_type = filter_type;
    open.filter_cutoff = 18_000.0;
    open.filter_res = 0.0;
    open.noteOn(84, 1.0);

    var closed = try PolySynth.init(std.testing.allocator, 48_000);
    defer closed.deinit();
    closed.waveform = .saw;
    closed.filter_type = filter_type;
    closed.filter_cutoff = 200.0;
    closed.filter_res = 0.0;
    closed.noteOn(84, 1.0);

    var buf_open: [512]Sample = undefined;
    var buf_closed: [512]Sample = undefined;
    for (0..20) |_| {
        @memset(&buf_open, 0.0);
        open.processBlock(&buf_open);
        @memset(&buf_closed, 0.0);
        closed.processBlock(&buf_closed);
    }

    var rms_open: f32 = 0.0;
    var rms_closed: f32 = 0.0;
    for (buf_open, buf_closed) |o, c| {
        rms_open += o * o;
        rms_closed += c * c;
    }
    try std.testing.expect(rms_closed < rms_open * 0.1);
}

test "filter: closed LP cutoff attenuates high-frequency content" {
    try expectClosedCutoffAttenuates(.lp);
}

test "ladder filter: closed cutoff attenuates like a lowpass" {
    try expectClosedCutoffAttenuates(.ladder);
}

test "diode ladder filter: closed cutoff attenuates like a lowpass" {
    try expectClosedCutoffAttenuates(.diode);
}

test "formant filter: vowel scan produces distinct spectral content" {
    // Low cutoff scans toward vowel "a" (F1=600), high cutoff toward "u"
    // (F1=350, F2=600) - different enough resonant peaks that RMS output
    // should differ meaningfully across the sweep, not just clamp flat.
    var low = try PolySynth.init(std.testing.allocator, 48_000);
    defer low.deinit();
    low.waveform = .saw;
    low.filter_type = .formant;
    low.filter_cutoff = 20.0;
    low.filter_res = 0.3;
    low.noteOn(48, 1.0);

    var high = try PolySynth.init(std.testing.allocator, 48_000);
    defer high.deinit();
    high.waveform = .saw;
    high.filter_type = .formant;
    high.filter_cutoff = 20_000.0;
    high.filter_res = 0.3;
    high.noteOn(48, 1.0);

    var buf_low: [512]Sample = undefined;
    var buf_high: [512]Sample = undefined;
    for (0..20) |_| {
        // zig fmt: off
        @memset(&buf_low, 0.0);  low.processBlock(&buf_low);
        @memset(&buf_high, 0.0); high.processBlock(&buf_high);
        // zig fmt: on
    }

    var rms_low: f32 = 0.0;
    var rms_high: f32 = 0.0;
    for (buf_low, buf_high) |l, h| {
        rms_low += l * l;
        rms_high += h * h;
    }
    try std.testing.expect(@abs(rms_low - rms_high) > 0.001);
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
    var base_synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer base_synth.deinit();
    base_synth.waveform = .saw;
    base_synth.filter_cutoff = 500.0;
    base_synth.noteOn(60, 1.0);

    var mod_synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer mod_synth.deinit();
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
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
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
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.noteOn(60, 1.0);
    synth.noteOn(64, 1.0);
    synth.noteOn(67, 1.0);
    var active: u32 = 0;
    for (synth.voices) |v| {
        if (v.active) active += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), active);
}

test "pulse width changes square output" {
    var wide = try PolySynth.init(std.testing.allocator, 48_000);
    defer wide.deinit();
    wide.waveform = .square;
    wide.pulse_width = 0.5;
    wide.noteOn(60, 1.0);

    var narrow = try PolySynth.init(std.testing.allocator, 48_000);
    defer narrow.deinit();
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
    var difference: f32 = 0.0;
    for (buf_wide, buf_narrow) |w, n| difference += @abs(w - n);
    try std.testing.expect(difference > 1.0);
}

test "unison mode: step and spread produce different detune patterns" {
    var spread = try PolySynth.init(std.testing.allocator, 48_000);
    defer spread.deinit();
    spread.unison       = 4;
    spread.unison_detune = 50.0;
    spread.unison_mode  = .spread;
    spread.noteOn(60, 1.0);

    var step = try PolySynth.init(std.testing.allocator, 48_000);
    defer step.deinit();
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
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
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
    var with_lfo = try PolySynth.init(std.testing.allocator, 48_000);
    defer with_lfo.deinit();
    // zig fmt: off
    with_lfo.lfo_shape  = .square;
    with_lfo.lfo_rate_hz = 0.0; // frozen
    with_lfo.lfo_phase  = 0.75; // square trough → lfo_val = -1
    // zig fmt: on
    with_lfo.mod_matrix[0] = .{ .source = .lfo, .dest = PolySynth.dest_amp, .depth = 1.0 };
    with_lfo.noteOn(60, 1.0);

    var without_lfo = try PolySynth.init(std.testing.allocator, 48_000);
    defer without_lfo.deinit();
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
    var with_vel = try PolySynth.init(std.testing.allocator, 48_000);
    defer with_vel.deinit();
    with_vel.mod_matrix[0] = .{ .source = .velocity, .dest = PolySynth.dest_amp, .depth = 1.0 };
    with_vel.noteOn(60, 1.0); // amp_mod = 1 + 1.0*1.0 = 2

    var without = try PolySynth.init(std.testing.allocator, 48_000);
    defer without.deinit();
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
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
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

test "applyPatchWithWavetables selects bundled audio while null preserves it" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    const basic_sample = s.wt.frames[17];

    try s.applyPatchWithWavetables(.{ .waveform = .wavetable, .wt_table = .metallic });
    try std.testing.expectEqual(BundledWavetable.metallic, s.wt_bundled.?);
    try std.testing.expect(s.wt.frames[17] != basic_sample);

    const metallic_sample = s.wt.frames[17];
    try s.applyPatchWithWavetables(.{ .waveform = .wavetable });
    try std.testing.expectEqual(BundledWavetable.metallic, s.wt_bundled.?);
    try std.testing.expectEqual(metallic_sample, s.wt.frames[17]);
}

test "matrix param ids round-trip through paramValue/setParamAbsolute" {
    var a = try PolySynth.init(std.testing.allocator, 48_000);
    defer a.deinit();
    a.mod_matrix[2] = .{ .source = .wheel, .dest = 34, .depth = -0.4 };
    a.mod_matrix[7] = .{ .source = .keytrack, .dest = PolySynth.dest_pitch, .depth = 1.0 };

    var b = try PolySynth.init(std.testing.allocator, 48_000);
    defer b.deinit();
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
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    try std.testing.expectEqual(@as(u8, 21), s.mod_matrix[0].dest);
    s.adjustParam(60, -1); // one step back from cutoff
    const idx_cutoff = PolySynth.modDestIndex(21).?;
    try std.testing.expectEqual(PolySynth.mod_dest_ids[idx_cutoff - 1], s.mod_matrix[0].dest);
    s.adjustParam(60, 1);
    try std.testing.expectEqual(@as(u8, 21), s.mod_matrix[0].dest);
}

test "mod_dest_ids covers every non-excluded automatable param" {
    for (PolySynth.automatable_params) |p| {
        if (PolySynth.isModDestExcluded(@intCast(p.id))) continue;
        try std.testing.expect(PolySynth.modDestIndex(@intCast(p.id)) != null);
    }
}

test "warpPhase is identity at zero and always returns a normalized finite phase" {
    const modes = [_]WarpMode{ .none, .bend, .mirror, .sync };
    const phases = [_]f32{ -3.25, 0.0, 0.125, 0.5, 0.999_999, 1.0, 9.75 };
    for (modes) |mode| {
        for (phases) |phase| {
            const normalized = phase - @floor(phase);
            try std.testing.expectApproxEqAbs(normalized, PolySynth.warpPhase(mode, phase, 0.0), 1e-6);
        }
        for (phases) |phase| {
            for ([_]f32{ -1.0, 0.0, 0.5, 1.0, 2.0 }) |amount| {
                const warped = PolySynth.warpPhase(mode, phase, amount);
                try std.testing.expect(std.math.isFinite(warped));
                try std.testing.expect(warped >= 0.0 and warped < 1.0);
            }
        }
    }
}

test "warpPhase contains non-finite runtime inputs" {
    const bad = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    for ([_]WarpMode{ .none, .bend, .mirror, .sync }) |mode| {
        for (bad) |value| {
            const bad_phase = PolySynth.warpPhase(mode, value, 0.75);
            const bad_amount = PolySynth.warpPhase(mode, 0.75, value);
            try std.testing.expect(std.math.isFinite(bad_phase));
            try std.testing.expect(std.math.isFinite(bad_amount));
            try std.testing.expect(bad_phase >= 0.0 and bad_phase < 1.0);
            try std.testing.expect(bad_amount >= 0.0 and bad_amount < 1.0);
        }
    }
}

test "LFO 2 tremolo via matrix: square trough at depth=1 silences the voice" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
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

test "unipolar mod row: folds a bipolar source to 0..1, leaves unipolar ones alone" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.lfo_shape = .square;
    s.lfo_rate_hz = 0.0; // frozen
    s.lfo_phase = 0.75; // square trough → -1
    s.mod_matrix[0] = .{ .source = .lfo, .dest = PolySynth.dest_amp, .depth = 1.0 };

    // Bipolar: the trough reads -1, so a depth-1 row subtracts a full unit.
    var acc = s.evalMatrix(null, .{ -1.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), acc.amt(PolySynth.dest_amp), 1e-6);

    // Unipolar: the same trough becomes 0, so the row contributes nothing
    // below the knob - it only ever pushes upward.
    s.mod_matrix[0].unipolar = true;
    acc = s.evalMatrix(null, .{ -1.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), acc.amt(PolySynth.dest_amp), 1e-6);
    // ...and the peak still reaches full depth.
    acc = s.evalMatrix(null, .{ 1.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), acc.amt(PolySynth.dest_amp), 1e-6);

    // An already-unipolar source is untouched: velocity 0.5 stays 0.5, not
    // squashed into 0.75 by a second bipolar-to-unipolar fold.
    var uni = try PolySynth.init(std.testing.allocator, 48_000);
    defer uni.deinit();
    uni.mod_matrix[0] = .{ .source = .velocity, .dest = PolySynth.dest_amp, .depth = 1.0, .unipolar = true };
    uni.noteOn(60, 0.5);
    const voice_acc = uni.evalMatrix(&uni.voices[uni.newest_voice], .{ 0.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), voice_acc.amt(PolySynth.dest_amp), 1e-6);
}

test "random and alternate modulation are stable per triggered voice" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.mod_matrix[0] = .{ .source = .random, .dest = PolySynth.dest_pitch, .depth = 1.0 };
    s.mod_matrix[1] = .{ .source = .alternate, .dest = PolySynth.dest_amp, .depth = 1.0 };

    s.noteOn(60, 1.0);
    const first = &s.voices[s.newest_voice];
    const first_random = first.random;
    const first_alternate = first.alternate;
    s.noteOn(64, 1.0);
    const second = &s.voices[s.newest_voice];

    try std.testing.expect(first_random >= -1.0 and first_random < 1.0);
    try std.testing.expect(first_random != second.random);
    try std.testing.expectEqual(-first_alternate, second.alternate);
    try std.testing.expectApproxEqAbs(first_random, s.evalMatrix(first, .{ 0.0, 0.0, 0.0 }).amt(PolySynth.dest_pitch), 1e-6);
}

test "live mixer gains ramp to each block target" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.noteOn(60, 1.0);
    var buf: [64]Sample = @splat(0.0);
    s.processBlock(&buf);
    const v = &s.voices[s.newest_voice];
    try std.testing.expectApproxEqAbs(s.gain, v.out_gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v.mix_gain[0], 1e-6);

    s.gain = 0.1;
    s.osc_b_on = true;
    s.osc_b_level = 0.5;
    s.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), v.out_gain, 1e-6);
    try std.testing.expect(v.mix_gain[1] > 0.0);
}

test "unipolar mod row: reachable through the flat param id space" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    const id = PolySynth.mod_unipolar_id_base + 3;
    try std.testing.expect(PolySynth.isToggleParam(id));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.paramValue(id).?, 1e-6);
    s.adjustParam(id, 1);
    try std.testing.expect(s.mod_matrix[3].unipolar);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.paramValue(id).?, 1e-6);
    s.setParamAbsolute(id, 0.0);
    try std.testing.expect(!s.mod_matrix[3].unipolar);
    // Rows keep their own polarity - id 272 must not touch row 0.
    try std.testing.expect(!s.mod_matrix[0].unipolar);
}

test "LFO tempo sync: rate follows the transport, not the Hz knob" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.lfo_rate_hz = 1.0;

    // Unattached: the division is inert, the Hz knob still rules.
    s.lfo_sync = .n1_4;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.syncedRate(s.lfo_sync, s.lfo_rate_hz), 1e-6);

    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 140.0 };
    s.attachTransport(&transport);
    // 140 bpm = 2.333 quarter notes/s; one cycle per 1/4 note matches that,
    // per 1/8 is twice as fast, and a 1/8 triplet three times per beat.
    try std.testing.expectApproxEqAbs(@as(f32, 140.0 / 60.0), s.syncedRate(.n1_4, 1.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 140.0 / 30.0), s.syncedRate(.n1_8, 1.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 140.0 / 20.0), s.syncedRate(.n1_8t, 1.0), 1e-4);
    // `.off` always falls back, transport or no transport.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.syncedRate(.off, 1.0), 1e-6);
    // A nonsense tempo degrades to 120 rather than producing inf/NaN.
    transport.tempo_bpm = 0.0;
    try std.testing.expect(std.math.isFinite(s.syncedRate(.n1_4, 1.0)));
}

test "LFO tempo sync: a free-running synced slot locks phase to the playhead" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    s.attachTransport(&transport);
    s.lfo_sync = .n1_1; // one cycle per bar (4 beats)
    s.lfo_phase = 0.9; // stale phase from before the transport rolled

    var buf: [256]Sample = undefined;
    // Stopped: no lock, the phase free-runs off the derived rate.
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expect(s.lfo_phase != 0.0);

    // Rolling, playhead parked one beat in: 1 of 4 beats through the cycle.
    transport.playing = true;
    transport.position_frames = @intFromFloat(transport.framesPerBeat());
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.lfo_phase, 1e-4);

    // Jumping the playhead jumps the LFO with it - that's the point: the
    // same wobble lands on the same beat every pass through a loop.
    transport.position_frames = @intFromFloat(transport.framesPerBeat() * 3.0);
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.lfo_phase, 1e-4);
}

test "LFO retrigger: key restarts the phase, free does not, legato never does" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.lfo_rate_hz = 5.0;
    s.lfo_retrig = .key;
    s.lfo2_retrig = .free;

    var buf: [256]Sample = undefined;
    s.noteOn(60, 1.0);
    for (0..8) |_| {
        @memset(&buf, 0.0);
        s.processBlock(&buf);
    }
    try std.testing.expect(s.lfo_phase > 0.0);
    const free_before = s.lfo2_phase;

    s.noteOn(64, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.lfo_phase, 1e-6);
    try std.testing.expectApproxEqAbs(free_before, s.lfo2_phase, 1e-6);

    // Legato slides update pitch on the running voice without re-triggering
    // the envelope, so they must leave the growl alone too.
    s.voice_mode = .legato;
    s.noteOn(67, 1.0);
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    const legato_phase = s.lfo_phase;
    s.noteOn(69, 1.0);
    try std.testing.expectApproxEqAbs(legato_phase, s.lfo_phase, 1e-6);
}

test "LFO one-shot: runs a single cycle, parks, re-arms on the next note" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.lfo_retrig = .one_shot;
    s.lfo_rate_hz = 20.0; // ~1 cycle per 2400 frames

    var buf: [256]Sample = undefined;
    s.noteOn(60, 1.0);
    for (0..40) |_| {
        @memset(&buf, 0.0);
        s.processBlock(&buf);
    }
    // Well past one cycle: parked at the end, not wrapped back around.
    try std.testing.expect(s.lfo_oneshot_done[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.lfo_phase, 1e-6);

    s.noteOff(60);
    s.noteOn(62, 1.0);
    try std.testing.expect(!s.lfo_oneshot_done[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.lfo_phase, 1e-6);
}

test "LFO slew: smoothing lags a square's jump instead of following it" {
    var sharp = try PolySynth.init(std.testing.allocator, 48_000);
    defer sharp.deinit();
    var smoothed = try PolySynth.init(std.testing.allocator, 48_000);
    defer smoothed.deinit();
    for ([_]*PolySynth{ &sharp, &smoothed }) |s| {
        s.lfo_shape = .square;
        s.lfo_rate_hz = 5.0;
        s.mod_matrix[0] = .{ .source = .lfo, .dest = PolySynth.dest_amp, .depth = 0.5 };
        s.noteOn(60, 1.0);
    }
    smoothed.lfo_slew_ms = 200.0;

    var buf: [256]Sample = undefined;
    for (0..20) |_| {
        @memset(&buf, 0.0);
        sharp.processBlock(&buf);
        @memset(&buf, 0.0);
        smoothed.processBlock(&buf);
    }
    // The square is pinned at ±1 with no slew; smoothing keeps the tracked
    // value strictly inside that, and never leaves it.
    try std.testing.expect(@abs(sharp.lfo_slew_state[0]) > 0.99);
    try std.testing.expect(@abs(smoothed.lfo_slew_state[0]) < 0.99);
    try std.testing.expect(std.math.isFinite(smoothed.lfo_slew_state[0]));
}

test "arp tempo sync: steps follow the transport division" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    s.attachTransport(&transport);
    s.arp_on = true;
    s.arp_rate_hz = 8.0;
    s.arp_sync = .n1_16;
    // 120 bpm: a 16th is 0.125 s, so 8 steps/s - the division decides, and
    // here it happens to match the knob, so drive them apart to be sure.
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), s.syncedRate(s.arp_sync, s.arp_rate_hz), 1e-4);
    transport.tempo_bpm = 60.0;
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), s.syncedRate(s.arp_sync, s.arp_rate_hz), 1e-4);
}

test "macro source: mac1 at depth 1 to AMP doubles the voice gain" {
    var with_mac = try PolySynth.init(std.testing.allocator, 48_000);
    defer with_mac.deinit();
    with_mac.macro1 = 1.0;
    with_mac.mod_matrix[0] = .{ .source = .mac1, .dest = PolySynth.dest_amp, .depth = 1.0 };
    with_mac.noteOn(60, 1.0);

    var without = try PolySynth.init(std.testing.allocator, 48_000);
    defer without.deinit();
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
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
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
    var a = try PolySynth.init(std.testing.allocator, 48_000);
    defer a.deinit();
    // zig fmt: off
    a.lfo2_shape = .sh;  a.lfo2_rate_hz = 6.5;
    a.lfo3_shape = .saw; a.lfo3_rate_hz = 0.25;
    a.macro1 = 0.1; a.macro2 = 0.4; a.macro3 = 0.7; a.macro4 = 1.0;
    // zig fmt: on

    var b = try PolySynth.init(std.testing.allocator, 48_000);
    defer b.deinit();
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

    var c = try PolySynth.init(std.testing.allocator, 48_000);
    defer c.deinit();
    c.applyPatch(a.toPatch());
    try std.testing.expectEqual(a.lfo2_shape, c.lfo2_shape);
    try std.testing.expectApproxEqAbs(a.lfo3_rate_hz, c.lfo3_rate_hz, 1e-6);
    try std.testing.expectApproxEqAbs(a.macro3, c.macro3, 1e-6);
}

test "polyphony: up to max_voices voices" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    for (0..PolySynth.max_voices) |i| synth.noteOn(@intCast(60 + i), 1.0);
    var active: usize = 0;
    // zig fmt: off
    for (synth.voices) |v| if (v.active) { active += 1; };
    try std.testing.expectEqual(PolySynth.max_voices, active);
}

test "osc_budget: unison capped when many voices active" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.unison = 16;
    // With 16 active voices, unison_cap = 32/16 = 2 per voice.
    for (0..16) |i| synth.noteOn(@intCast(48 + i), 1.0);
    try expectStaysFinite(&synth, 4);
}

test "glide: pitch slides over time (log-linear)" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.voice_mode = .mono;
    synth.glide_s    = 0.5; // half-second glide
    synth.noteOn(60, 1.0); // C4
    // Trigger glide to A4 - voice was active so glide applies.
    synth.noteOn(69, 1.0); // A4
    // glide_log should still be at C4 (not yet advanced)
    const c4_log = std.math.log2(PolySynth.noteToFreq(60));
    try std.testing.expectApproxEqAbs(c4_log, synth.voices[0].glide_log, 1e-4);
    // After processing, frequency should have moved toward A4 but not arrived.
    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0); synth.processBlock(&buf);
    const a4_log = std.math.log2(PolySynth.noteToFreq(69));
    try std.testing.expect(synth.voices[0].glide_log > c4_log);
    try std.testing.expect(synth.voices[0].glide_log < a4_log);
}

test "glide: snaps immediately when glide_s=0" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.voice_mode = .mono;
    synth.glide_s    = 0.0;
    synth.noteOn(60, 1.0);
    synth.noteOn(69, 1.0);
    const a4_log = std.math.log2(PolySynth.noteToFreq(69));
    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0); synth.processBlock(&buf);
    // zig fmt: on
    try std.testing.expectApproxEqAbs(a4_log, synth.voices[0].glide_log, 1e-4);
}

test "mono mode: only one voice active" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
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
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.voice_mode = .mono;
    synth.noteOn(60, 1.0);
    synth.noteOn(64, 1.0);
    synth.noteOff(64);
    try std.testing.expectEqual(@as(u7, 60), synth.voices[0].note);
    try std.testing.expect(synth.voices[0].active);
    try std.testing.expect(synth.voices[0].stage != .release);
}

test "switching voice_mode to mono mid-chord doesn't strand the other held notes" {
    // A live voice_mode nudge (or auditioning a mono/legato preset) while a
    // poly chord is still held used to leave every note but the last one
    // permanently stuck: noteOff's mono/legato fallback only ever checked
    // voices[0], but noteOnPoly never populates held_notes, so those other
    // voices had no route to their note-off at all.
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.noteOn(60, 1.0); // -> voices[0]
    synth.noteOn(64, 1.0); // -> voices[1]
    synth.noteOn(67, 1.0); // -> voices[2]
    synth.voice_mode = .mono;

    synth.noteOff(64); // not in voices[0] - the bug's exact trigger
    try std.testing.expect(synth.voices[1].stage == .release);

    synth.noteOff(67);
    try std.testing.expect(synth.voices[2].stage == .release);

    synth.noteOff(60);
    try std.testing.expect(synth.voices[0].stage == .release);
}

test "switching voice_mode to legato mid-chord releases only the matching stray voice" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.noteOn(60, 1.0); // -> voices[0]
    synth.noteOn(64, 1.0); // -> voices[1], still held throughout
    synth.voice_mode = .legato;

    synth.noteOff(60); // voices[0]'s own note - releases unconditionally
    try std.testing.expect(synth.voices[0].stage == .release);
    // The unrelated still-held poly note must not get cut short by the
    // unconditional slot-0 release picking up neighbors too.
    try std.testing.expect(synth.voices[1].active);
    try std.testing.expect(synth.voices[1].stage != .release);
}

test "poly mode note-off releases only oldest same-pitch voice" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.noteOn(60, 1.0);
    const first = synth.newest_voice;
    synth.noteOn(60, 1.0);
    const second = synth.newest_voice;

    synth.noteOff(60);
    try std.testing.expectEqual(.release, synth.voices[first].stage);
    try std.testing.expect(synth.voices[second].stage != .release);

    synth.noteOff(60);
    try std.testing.expectEqual(.release, synth.voices[second].stage);
}

test "legato mode: no envelope retrigger on second note" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.voice_mode = .legato;
    synth.noteOn(60, 1.0);
    var buf: [512]Sample = undefined;
    // Warm up past attack so we're in sustain
    // zig fmt: off
    for (0..100) |_| { @memset(&buf, 0.0); synth.processBlock(&buf); }
    // zig fmt: on
    const env_before = synth.voices[0].env;
    // Second note in legato - should not retrigger (env stays in sustain, not reset to 0)
    synth.noteOn(64, 1.0);
    try std.testing.expectEqual(@as(u7, 64), synth.voices[0].note);
    try std.testing.expect(synth.voices[0].stage != .attack); // still in sustain
    try std.testing.expectApproxEqAbs(env_before, synth.voices[0].env, 0.01);
}

test "LFO: all shapes stay finite under filter modulation" {
    const shapes = [_]LfoShape{ .sine, .triangle, .saw, .square, .chaos, .custom };
    for (shapes) |shape| {
        var synth = try PolySynth.init(std.testing.allocator, 48_000);
        defer synth.deinit();
        // zig fmt: off
        synth.lfo_shape   = shape;
        synth.lfo_rate_hz = 5.0;
        // zig fmt: on
        synth.lfo_custom[0][0] = .{ .phase = 0, .value = 0 };
        synth.lfo_custom[0][1] = .{ .phase = 0.3, .value = 1 };
        synth.lfo_custom[0][2] = .{ .phase = 0.7, .value = -1 };
        synth.lfo_custom[0][3] = .{ .phase = 1, .value = 0 };
        synth.lfo_custom_count[0] = 4;
        synth.mod_matrix[0] = .{ .source = .lfo, .dest = 21, .depth = 1.0 };
        synth.filter_cutoff = 2_000.0;
        synth.noteOn(60, 1.0);
        try expectStaysFinite(&synth, 32);
    }
}

test "LFO: chaos shape evolves and stays bounded" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.lfo_shape = .chaos;
    synth.lfo_rate_hz = 5.0;
    synth.noteOn(60, 1.0);

    var buf: [512]Sample = undefined;
    var prev = synth.lfo_chaos[0].x;
    var moved = false;
    for (0..32) |_| {
        @memset(&buf, 0.0);
        synth.processBlock(&buf);
        const v = synth.lfoVal(0, .chaos, synth.lfo_phase);
        try std.testing.expect(v >= -1.0 and v <= 1.0);
        if (synth.lfo_chaos[0].x != prev) moved = true;
        prev = synth.lfo_chaos[0].x;
    }
    try std.testing.expect(moved);
}

test "LFO custom shape: interpolates between points and holds the edges" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.lfo_custom[0][0] = .{ .phase = 0.0, .value = -1.0 };
    synth.lfo_custom[0][1] = .{ .phase = 0.5, .value = 1.0 };
    synth.lfo_custom[0][2] = .{ .phase = 1.0, .value = -1.0 };
    synth.lfo_custom_count[0] = 3;

    try std.testing.expectApproxEqAbs(@as(f32, -1.0), synth.lfoVal(0, .custom, 0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), synth.lfoVal(0, .custom, 0.25), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), synth.lfoVal(0, .custom, 0.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), synth.lfoVal(0, .custom, 1.0), 1e-6);
    // Past either edge holds the nearest point's value rather than
    // wrapping or extrapolating.
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), synth.lfoVal(0, .custom, -0.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), synth.lfoVal(0, .custom, 1.5), 1e-6);
}

test "LFO custom shape: empty point list reads as silence" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.lfo_custom_count[1] = 0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), synth.lfoVal(1, .custom, 0.3), 1e-6);
}

test "LFO custom shape points round-trip through paramValue/setParamAbsolute and Patch" {
    var a = try PolySynth.init(std.testing.allocator, 48_000);
    defer a.deinit();
    a.lfo_custom[0][0] = .{ .phase = 0.0, .value = -0.5 };
    a.lfo_custom[0][1] = .{ .phase = 0.2, .value = 0.9 };
    a.lfo_custom[0][2] = .{ .phase = 1.0, .value = 0.1 };
    a.lfo_custom_count[0] = 3;
    a.lfo_custom[2][0] = .{ .phase = 0.0, .value = 1.0 };
    a.lfo_custom[2][1] = .{ .phase = 1.0, .value = -1.0 };
    a.lfo_custom_count[2] = 2;

    var b = try PolySynth.init(std.testing.allocator, 48_000);
    defer b.deinit();
    var id: u16 = lfo_custom_id_base;
    while (id <= lfo_custom_id_base + 3 * lfo_custom_ids_per_slot - 1) : (id += 1) {
        if (a.paramValue(@intCast(id))) |v| b.setParamAbsolute(@intCast(id), v);
    }
    try std.testing.expectEqual(a.lfo_custom_count[0], b.lfo_custom_count[0]);
    try std.testing.expectEqual(a.lfo_custom_count[2], b.lfo_custom_count[2]);
    for (a.lfo_custom[0][0..3], b.lfo_custom[0][0..3]) |ap, bp| {
        try std.testing.expectApproxEqAbs(ap.phase, bp.phase, 1e-6);
        try std.testing.expectApproxEqAbs(ap.value, bp.value, 1e-6);
    }

    var c = try PolySynth.init(std.testing.allocator, 48_000);
    defer c.deinit();
    c.applyPatch(a.toPatch());
    try std.testing.expectEqual(a.lfo_custom_count[0], c.lfo_custom_count[0]);
    try std.testing.expectApproxEqAbs(a.lfo_custom[0][1].value, c.lfo_custom[0][1].value, 1e-6);
}

test "adjustParam nudges a custom LFO point's phase/value and count" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    const phase_id = lfo_custom_id_base; // slot 0, point 0, phase
    const value_id = lfo_custom_id_base + 1; // slot 0, point 0, value
    const count_id = lfo_custom_id_base + max_lfo_shape_points * 2; // slot 0

    synth.adjustParam(phase_id, 5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), synth.lfo_custom[0][0].phase, 1e-6);
    synth.adjustParam(value_id, -10);
    try std.testing.expectApproxEqAbs(@as(f32, -0.1), synth.lfo_custom[0][0].value, 1e-6);
    try std.testing.expectEqual(@as(u8, 2), synth.lfo_custom_count[0]);
    synth.adjustParam(count_id, 1);
    try std.testing.expectEqual(@as(u8, 3), synth.lfo_custom_count[0]);
    try std.testing.expect(synth.lfo_custom[0][2].phase >= synth.lfo_custom[0][1].phase);
    synth.adjustParam(count_id, 100);
    try std.testing.expectEqual(max_lfo_shape_points, synth.lfo_custom_count[0]);
    synth.adjustParam(count_id, -100);
    try std.testing.expectEqual(@as(u8, 0), synth.lfo_custom_count[0]);
}

test "adjustParam clamps extreme step counts without integer overflow" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    const count_id = lfo_custom_id_base + max_lfo_shape_points * 2;
    const dest_id = PolySynth.matrixParamId(0, 1);

    synth.adjustParam(3, std.math.maxInt(i32));
    try std.testing.expectEqual(@as(u8, 16), synth.unison);
    synth.adjustParam(3, std.math.minInt(i32));
    try std.testing.expectEqual(@as(u8, 1), synth.unison);
    synth.adjustParam(count_id, std.math.maxInt(i32));
    try std.testing.expectEqual(max_lfo_shape_points, synth.lfo_custom_count[0]);
    synth.adjustParam(count_id, std.math.minInt(i32));
    try std.testing.expectEqual(@as(u8, 0), synth.lfo_custom_count[0]);

    synth.adjustParam(dest_id, std.math.maxInt(i32));
    try std.testing.expect(PolySynth.modDestIndex(synth.mod_matrix[0].dest) != null);
    synth.adjustParam(126, std.math.maxInt(i32));
    try std.testing.expectEqual(synth.fx_order.len - 1, synth.fxOrderIndex(.dist));
    synth.adjustParam(126, std.math.minInt(i32));
    try std.testing.expectEqual(@as(usize, 0), synth.fxOrderIndex(.dist));
}

test "custom LFO phase edits cannot reorder points" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.lfo_custom_count[0] = 3;
    synth.lfo_custom[0][0].phase = 0.0;
    synth.lfo_custom[0][1].phase = 0.4;
    synth.lfo_custom[0][2].phase = 0.8;
    const middle_phase_id = lfo_custom_id_base + 2;

    synth.setParamAbsolute(middle_phase_id, 1.0);
    try std.testing.expectEqual(@as(f32, 0.8), synth.lfo_custom[0][1].phase);
    synth.adjustParam(middle_phase_id, -100);
    try std.testing.expectEqual(@as(f32, 0.0), synth.lfo_custom[0][1].phase);
}

test "applyCC: cutoff logarithmic scaling" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.applyCC(@intFromEnum(midi.CC.filter_cutoff), 0);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), synth.filter_cutoff, 1.0);
    synth.applyCC(@intFromEnum(midi.CC.filter_cutoff), 127);
    try std.testing.expect(synth.filter_cutoff > 17_000.0);
}

test "time parameters nudge by ratio and glide keeps explicit zero" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();

    synth.attack_s = 0.005;
    synth.adjustParam(16, 12);
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), synth.attack_s, 1e-6);

    synth.glide_s = 0;
    synth.adjustParam(33, 1);
    try std.testing.expect(synth.glide_s > 0 and synth.glide_s < 0.001);
    synth.adjustParam(33, -1);
    try std.testing.expectEqual(@as(f32, 0), synth.glide_s);
}

test "applyCC: reset all controllers restores transient performance controls only" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.mod_wheel = 0.75;
    synth.applyPitchBend(4096, 2.0);
    synth.gain = 0.42;
    synth.filter_cutoff = 3_000.0;

    synth.applyCC(@intFromEnum(midi.CC.reset_all_ctrls), 0);

    try std.testing.expectEqual(@as(f32, 0.0), synth.mod_wheel);
    try std.testing.expectEqual(@as(f32, 0.0), synth.pitch_bend_semitones);
    try std.testing.expectEqual(@as(f32, 0.42), synth.gain);
    try std.testing.expectEqual(@as(f32, 3_000.0), synth.filter_cutoff);
}

test "setParamAbsolute: sets filter cutoff directly and clamps out-of-range" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
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

test "setParamAbsolute ignores non-finite values for every table-driven parameter" {
    @setEvalBranchQuota(100_000);
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    inline for (PolySynth.param_specs) |spec| {
        const before = synth.paramValue(spec.id).?;
        synth.setParamAbsolute(spec.id, nan);
        try std.testing.expectEqual(before, synth.paramValue(spec.id).?);
        synth.setParamAbsolute(spec.id, inf);
        try std.testing.expectEqual(before, synth.paramValue(spec.id).?);
    }

    inline for ([_]u8{ 59, 60, 61, 126, 149, 194 }) |id| {
        const before = synth.paramValue(id).?;
        synth.setParamAbsolute(id, std.math.nan(f32));
        try std.testing.expectEqual(before, synth.paramValue(id).?);
        synth.setParamAbsolute(id, -std.math.inf(f32));
        try std.testing.expectEqual(before, synth.paramValue(id).?);
    }
}

test "matrix parameter IDs preserve legacy rows and address row 32" {
    try std.testing.expectEqual(@as(u16, 59), PolySynth.matrixParamId(0, 0));
    try std.testing.expectEqual(@as(u16, 82), PolySynth.matrixParamId(7, 2));
    try std.testing.expectEqual(@as(u16, 370), PolySynth.matrixParamId(31, 0));

    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.adjustParam(PolySynth.matrixParamId(31, 0), 1);
    synth.setParamAbsolute(PolySynth.matrixParamId(31, 2), 0.75);
    try std.testing.expectEqual(ModSource.lfo, synth.mod_matrix[31].source);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), synth.mod_matrix[31].depth, 1e-6);
}

test "applyParamSpecs ignores non-finite continuous snapshot fields" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    const pulse_width = synth.pulse_width;
    const cutoff = synth.filter_cutoff;
    const snap = .{
        .pulse_width = std.math.nan(f32),
        .filter_cutoff = std.math.inf(f32),
    };
    synth.applyParamSpecs(&snap);
    try std.testing.expectEqual(pulse_width, synth.pulse_width);
    try std.testing.expectEqual(cutoff, synth.filter_cutoff);
}

test "applyCC: waveform steps" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.applyCC(@intFromEnum(midi.CC.osc_a_waveform), 0);
    try std.testing.expectEqual(Waveform.sine, synth.waveform);
    synth.applyCC(@intFromEnum(midi.CC.osc_a_waveform), 32);
    try std.testing.expectEqual(Waveform.saw, synth.waveform);
    synth.applyCC(@intFromEnum(midi.CC.osc_a_waveform), 127);
    try std.testing.expectEqual(Waveform.wavetable, synth.waveform);
}

test "loadWavetable: replaces a slot's table, marks it user-imported, leaves old table intact on parse failure" {
    const wav = @import("../core/wav.zig");
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    try std.testing.expectEqual(false, synth.osc_b_wt_user);

    var samples: [wavetable.frame_len * 2]f32 = undefined;
    @memset(samples[0..wavetable.frame_len], -1.0);
    @memset(samples[wavetable.frame_len..], 1.0);
    var buf: [wavetable.frame_len * 2 * 4 + 64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try wav.write(&writer, 48_000, 1, &samples, .pcm16);

    try synth.loadWavetable(.b, writer.buffered());
    try std.testing.expectEqual(true, synth.osc_b_wt_user);
    try std.testing.expectEqual(@as(usize, 2), synth.osc_b_wt.frame_count);

    try std.testing.expectError(error.NotWav, synth.loadWavetable(.b, "not a wav at all!!"));
    try std.testing.expectEqual(@as(usize, 2), synth.osc_b_wt.frame_count);
}

test "applyPitchBend: range at ±2 semitones" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.applyPitchBend(8191, 2.0);
    try std.testing.expect(synth.pitch_bend_semitones > 1.9);
    synth.applyPitchBend(-8192, 2.0);
    try std.testing.expect(synth.pitch_bend_semitones < -1.9);
    synth.applyPitchBend(0, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), synth.pitch_bend_semitones, 1e-4);
}

test "paramValue/setParamAbsolute round-trip continuous, enum, and toggle params" {
    var a = try PolySynth.init(std.testing.allocator, 48_000);
    defer a.deinit();
    a.sustain = 0.37;
    a.filter_type = .bp;
    a.osc_b_on = true;
    a.mod_mode = .fm_a_to_b;

    // Every editor param id survives a value-copy through the pair.
    var b = try PolySynth.init(std.testing.allocator, 48_000);
    defer b.deinit();
    var id: u8 = 0;
    while (id <= 40) : (id += 1) {
        if (a.paramValue(id)) |v| b.setParamAbsolute(id, v);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.37), b.sustain, 1e-6);
    try std.testing.expectEqual(FilterType.bp, b.filter_type);
    try std.testing.expect(b.osc_b_on);
    try std.testing.expectEqual(ModMode.fm_a_to_b, b.mod_mode);

    // A non-finite ordinal is ignored; a huge finite one clamps safely.
    const filter_before = b.filter_type;
    b.setParamAbsolute(20, std.math.nan(f32));
    try std.testing.expectEqual(filter_before, b.filter_type);
    b.setParamAbsolute(20, 1.0e30);
    try std.testing.expectEqual(FilterType.formant, b.filter_type);
}

test "FX param ids round-trip through paramValue/setParamAbsolute" {
    var a = try PolySynth.init(std.testing.allocator, 48_000);
    defer a.deinit();
    a.fx_dist_on = true;
    a.fx_dist_drive_db = 24.0;
    a.fx_crush_bits = 4.0;
    a.fx_flanger_on = true;
    a.fx_flanger_feedback = 0.8;

    var b = try PolySynth.init(std.testing.allocator, 48_000);
    defer b.deinit();
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

test "FX phaser param ids round-trip through paramValue/setParamAbsolute" {
    var a = try PolySynth.init(std.testing.allocator, 48_000);
    defer a.deinit();
    a.fx_phaser_on = true;
    a.fx_phaser_rate_hz = 2.5;
    a.fx_phaser_depth = 0.6;
    a.fx_phaser_feedback = 0.7;
    a.fx_phaser_mix = 0.4;

    var b = try PolySynth.init(std.testing.allocator, 48_000);
    defer b.deinit();
    var id: u8 = 103;
    while (id <= 107) : (id += 1) {
        if (a.paramValue(id)) |v| b.setParamAbsolute(id, v);
    }
    try std.testing.expect(b.fx_phaser_on);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), b.fx_phaser_rate_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), b.fx_phaser_depth, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), b.fx_phaser_feedback, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), b.fx_phaser_mix, 1e-6);
}

test "FX delay/reverb param ids round-trip through paramValue/setParamAbsolute" {
    var a = try PolySynth.init(std.testing.allocator, 48_000);
    defer a.deinit();
    a.fx_delay_on = true;
    a.fx_delay_time_s = 0.4;
    a.fx_delay_feedback = 0.6;
    a.fx_delay_mix = 0.5;
    a.fx_reverb_on = true;
    a.fx_reverb_room = 0.7;
    a.fx_reverb_damp = 0.2;
    a.fx_reverb_mix = 0.8;

    var b = try PolySynth.init(std.testing.allocator, 48_000);
    defer b.deinit();
    var id: u8 = 108;
    while (id <= 115) : (id += 1) {
        if (a.paramValue(id)) |v| b.setParamAbsolute(id, v);
    }
    try std.testing.expect(b.fx_delay_on);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), b.fx_delay_time_s, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), b.fx_delay_feedback, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), b.fx_delay_mix, 1e-6);
    try std.testing.expect(b.fx_reverb_on);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), b.fx_reverb_room, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), b.fx_reverb_damp, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), b.fx_reverb_mix, 1e-6);
}

test "FX tape param ids round-trip through paramValue/setParamAbsolute" {
    var a = try PolySynth.init(std.testing.allocator, 48_000);
    defer a.deinit();
    a.fx_tape_on = true;
    a.fx_tape_wow_rate_hz = 1.2;
    a.fx_tape_wow_depth = 0.6;
    a.fx_tape_flutter_rate_hz = 9.0;
    a.fx_tape_flutter_depth = 0.4;
    a.fx_tape_mix = 0.75;

    var b = try PolySynth.init(std.testing.allocator, 48_000);
    defer b.deinit();
    var id: u8 = 188;
    while (id <= 193) : (id += 1) {
        if (a.paramValue(id)) |v| b.setParamAbsolute(id, v);
    }
    try std.testing.expect(b.fx_tape_on);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), b.fx_tape_wow_rate_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), b.fx_tape_wow_depth, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), b.fx_tape_flutter_rate_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), b.fx_tape_flutter_depth, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), b.fx_tape_mix, 1e-6);
}

test "adjustParam: tape params nudge and toggle (were silently no-op before the param table)" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    const before_on = s.fx_tape_on;
    s.adjustParam(188, 1);
    try std.testing.expect(s.fx_tape_on != before_on);
    const before_rate = s.fx_tape_wow_rate_hz;
    s.adjustParam(189, 1);
    try std.testing.expect(s.fx_tape_wow_rate_hz != before_rate);
    // Reorder handle 194: tape starts last in the default fx_order.
    const before_idx = s.fxOrderIndex(.tape);
    s.adjustParam(194, -1);
    try std.testing.expect(s.fxOrderIndex(.tape) < before_idx);
}

test "adjustParam: fx_mb_style picks classic/ott by direction, not a wrap" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.fx_mb_style = .ott;
    s.adjustParam(149, 1); // forward while already .ott: stays .ott
    try std.testing.expectEqual(MbStyle.ott, s.fx_mb_style);
    s.adjustParam(149, -1);
    try std.testing.expectEqual(MbStyle.classic, s.fx_mb_style);
    s.adjustParam(149, -1); // backward while already .classic: stays .classic
    try std.testing.expectEqual(MbStyle.classic, s.fx_mb_style);
}

/// Directly seeds held/latch state and drives `arpFireStep` (bypassing the
/// block-rate timer) so each mode's note sequence is checked exactly,
/// without needing to reverse-engineer phase-increment arithmetic.
fn arpSeedLatch(synth: *PolySynth, notes: []const u7) void {
    synth.held_count = @intCast(notes.len);
    for (notes, 0..) |n, i| {
        synth.held_notes[i] = n;
        synth.held_velocities[i] = 1.0;
    }
    synth.arpUpdateLatch();
}

fn arpFiredNote(synth: *PolySynth) u7 {
    synth.arpFireStep();
    return synth.voices[synth.newest_voice].note;
}

test "arp up mode ascends through held notes and wraps" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_mode = .up;
    arpSeedLatch(&synth, &.{ 60, 64, 67 });

    try std.testing.expectEqual(@as(u7, 60), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 64), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 67), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 60), arpFiredNote(&synth)); // wraps
}

test "arp down mode descends through held notes and wraps" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_mode = .down;
    arpSeedLatch(&synth, &.{ 60, 64, 67 });

    try std.testing.expectEqual(@as(u7, 67), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 64), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 60), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 67), arpFiredNote(&synth)); // wraps
}

test "arp updown mode ping-pongs without repeating the endpoints" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_mode = .updown;
    arpSeedLatch(&synth, &.{ 60, 64, 67 });

    const expected = [_]u7{ 60, 64, 67, 64, 60, 64, 67 };
    for (expected) |note| {
        try std.testing.expectEqual(note, arpFiredNote(&synth));
    }
}

test "arp played mode keeps press order instead of sorting by pitch" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_mode = .played;
    arpSeedLatch(&synth, &.{ 67, 60, 64 }); // pressed high-low-mid

    try std.testing.expectEqual(@as(u7, 67), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 60), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 64), arpFiredNote(&synth));
}

test "arp octave range expands the sequence, lowest octave first" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_mode = .up;
    synth.arp_octaves = 3;
    arpSeedLatch(&synth, &.{60});

    try std.testing.expectEqual(@as(u7, 60), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 72), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 84), arpFiredNote(&synth));
    try std.testing.expectEqual(@as(u7, 60), arpFiredNote(&synth)); // wraps
}

test "arp chord mode retriggers every held note together, ignoring octaves" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_mode = .chord;
    synth.arp_octaves = 2;
    arpSeedLatch(&synth, &.{ 60, 64, 67 });

    synth.arpFireStep();
    var sounding: [3]bool = .{ false, false, false };
    for (synth.voices) |v| {
        if (!v.active) continue;
        switch (v.note) {
            60 => sounding[0] = true,
            64 => sounding[1] = true,
            67 => sounding[2] = true,
            else => try std.testing.expect(false), // no octave-doubled notes
        }
    }
    try std.testing.expect(sounding[0] and sounding[1] and sounding[2]);
}

test "arp gate closes the voice partway through a step" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_mode = .up;
    synth.arp_gate = 0.5;
    // Exactly half a step per 512-frame block, so the gate-close check
    // (phase >= gate) trips on this call without also wrapping into a
    // same-block retrigger.
    synth.arp_rate_hz = 0.5 * 48_000.0 / 512.0;
    synth.noteOn(60, 1.0); // immediate first step, phase reset to 0

    const idx = synth.newest_voice;
    try std.testing.expect(synth.voices[idx].active);
    try std.testing.expect(synth.voices[idx].stage != .release);

    var buf: [1024]Sample = undefined; // 512 frames
    @memset(&buf, 0.0);
    synth.processBlock(&buf);

    try std.testing.expectEqual(.release, synth.voices[idx].stage);
}

test "arp hold keeps cycling the last chord after every key releases" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_hold = true;
    synth.arp_mode = .up;
    synth.noteOn(60, 1.0);
    synth.noteOff(60);

    try std.testing.expectEqual(@as(u8, 1), synth.arp_latch_count);
    try std.testing.expectEqual(@as(u7, 60), arpFiredNote(&synth));
}

test "arp without hold releases and clears the latch once all keys are up" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_mode = .up;
    synth.noteOn(60, 1.0);
    const idx = synth.newest_voice;
    synth.noteOff(60);

    try std.testing.expectEqual(@as(u8, 0), synth.arp_latch_count);
    try std.testing.expectEqual(.release, synth.voices[idx].stage);
}

test "toggling arp off mid-note releases the stuck voice" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.arp_on = true;
    synth.arp_rate_hz = 0.0; // no steps/gate activity during the setup block
    synth.noteOn(60, 1.0);
    const idx = synth.newest_voice;

    var buf: [64]Sample = undefined;
    @memset(&buf, 0.0);
    synth.processBlock(&buf); // arp_was_on becomes true

    synth.arp_on = false;
    @memset(&buf, 0.0);
    synth.processBlock(&buf); // on->off edge: release whatever was sounding

    try std.testing.expectEqual(.release, synth.voices[idx].stage);
}

test "envelope curve spans logarithmic, linear, and exponential shapes" {
    const curves = [_]f32{ -1.0, 0.0, 1.0 };
    var levels: [3]f32 = @splat(0.0);
    for (curves, 0..) |curve, i| {
        var stage: PolySynth.Stage = .attack;
        const shape = PolySynth.envShape(0.01, 0.005, 0.01, 0.5, curve);
        for (0..25) |_| _ = PolySynth.advanceEnv(&stage, &levels[i], 0.5, shape);
    }
    try std.testing.expect(levels[0] > levels[1]);
    try std.testing.expect(levels[1] > levels[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), levels[1], 1e-6);
}

test "polyBLEP reduces saw discontinuity" {
    const naive_jump = @abs(PolySynth.oscWave(.saw, 0.0, 0.5, 0.0) - PolySynth.oscWave(.saw, 0.99, 0.5, 0.0));
    const blep_jump = @abs(PolySynth.oscWave(.saw, 0.0, 0.5, 0.02) - PolySynth.oscWave(.saw, 0.99, 0.5, 0.02));
    try std.testing.expect(blep_jump < naive_jump);
}

test "filter drive bypasses at unity and saturates above it" {
    try std.testing.expectEqual(@as(f32, 0.25), PolySynth.driveInput(1.0, 0.25));
    try std.testing.expect(@abs(PolySynth.driveInput(8.0, 2.0)) < 2.0);
}

//! Save/load snapshot data types - pure data, no pointers, no atomics,
//! no heap slices matching the live structs. Split out of persist.zig;
//! see that file's header for the round-trip guarantees these serve.

const std = @import("std");
const Session = @import("session.zig").Session;
const wav = @import("core/wav.zig");
const types = @import("core/types.zig");
const theory = @import("theory.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;
const track_color_count = project_mod.track_color_count;
const ws_arrangement = @import("arrangement.zig");
const time_grid = @import("time_grid.zig");
const rack_mod = @import("rack.zig");
const Rack = rack_mod.Rack;
const Fx = rack_mod.Fx;
const engine_mod = @import("audio/engine.zig");
const Engine = engine_mod.Engine;
const Transport = @import("transport.zig").Transport;
const synth_mod = @import("dsp/synth.zig");
const PolySynth = synth_mod.PolySynth;
const wavetable_mod = @import("dsp/wavetable.zig");
const pattern_mod = @import("dsp/pattern.zig");
const PatternPlayer = pattern_mod.PatternPlayer;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const drum_kit = @import("dsp/drum_kit.zig");
const pad_mod = @import("dsp/pad.zig");
const Pad = pad_mod.Pad;
const lfo_mod = @import("dsp/lfo.zig");
const Sampler = @import("dsp/sampler.zig").Sampler;
const Slicer = @import("dsp/slicer.zig").Slicer;
const SoundfontPlayer = @import("dsp/soundfont_player.zig").SoundfontPlayer;
const soundfont_mod = @import("dsp/soundfont.zig");
const Compressor = @import("dsp/compressor.zig").Compressor;
const multiband_comp_mod = @import("dsp/multiband_comp.zig");
const Reverb = @import("dsp/reverb.zig").Reverb;
const eq_mod = @import("dsp/eq.zig");
const Gate = @import("dsp/gate.zig").Gate;
const Saturator = @import("dsp/saturator.zig").Saturator;
const Crusher = @import("dsp/crusher.zig").Crusher;
const Phaser = @import("dsp/phaser.zig").Phaser;
const dsp = @import("dsp/device.zig");
const automation_mod = @import("dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;
const tuning_mod = @import("dsp/tuning.zig");
/// Newest format version this build writes and reads; newer files are
/// hard-rejected on load. The canonical version history (what each bump
/// added and what older files load as) and the bump-vs-additive policy
/// live in FORMAT.md; per-field migration specifics stay as doc comments
/// on the snapshot fields they concern.
pub const file_version: u32 = 36;

/// Mirrors `automation_mod.Curve` as a plain string enum, same JSON-stability
/// reasoning as `EqBandKindSnap`.
pub const AutomationCurveSnap = enum {
    linear,
    hold,
    ease,
    /// A segment shape this build cannot draw; loads as `.linear`, the only
    /// shape a point could have before this field existed.
    unknown,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !AutomationCurveSnap {
        return openEnumParse(AutomationCurveSnap, allocator, source, options);
    }
};

pub const AutomationPointSnap = struct {
    beat: f64,
    value: f32,
    /// Additive: shape of the segment leaving this point. Older files omit
    /// it and land on `.linear`, which is what they played.
    curve: AutomationCurveSnap = .linear,
};

/// One synth-instrument- or FX-unit-param automation lane - see `ClipSnap.
/// synth_param_automation`. `instance_id`: 0 (the default, matching every
/// pre-existing file's implicit meaning) targets the track's own
/// instrument; nonzero targets a specific `FxUnit` by its stable
/// `instance_id` - additive field, no version bump (old files simply never
/// set it, same convention the mod matrix's `fx_instance_id` already uses).
pub const SynthParamAutomationSnap = struct {
    instance_id: u32 = 0,
    param_id: u32,
    points: []const AutomationPointSnap = &.{},
};

// ---------------------------------------------------------------------------
// Snapshot types - plain data, JSON-serialisable
// ---------------------------------------------------------------------------

/// Per-note expression (`dsp.Articulation`) is stored flat rather than as a
/// nested object: three scalars, defaulted to neutral, so a file written
/// before per-note expression existed loads with every note centred, in
/// tune and on the patch's own release. Additive - no `file_version` bump,
/// see FORMAT.md's versioning policy.
pub const NoteSnap = struct {
    pitch: u8,
    start_beat: f64,
    duration_beat: f64,
    velocity: f32 = 0.85,
    pan: f32 = 0.0,
    fine_cents: f32 = 0.0,
    release_scale: f32 = 1.0,
};

pub const SynthSnap = struct {
    // OSC A
    waveform: synth_mod.Waveform = .saw,
    wt_bundled: ?synth_mod.BundledWavetable = .basic,
    pulse_width: f32 = 0.5,
    detune_cents: f32 = 0.0,
    unison: u8 = 1,
    unison_detune: f32 = 15.0,
    unison_spread: f32 = 0.0,
    /// Additive field: never actually wired to this struct/synthToSnap/
    /// applyToSynth when the feature shipped, so saved+reloaded projects
    /// silently lost this setting back to `.spread`. Fixed alongside adding
    /// warp mode below.
    unison_mode: synth_mod.UnisonMode = .spread,
    warp_mode: synth_mod.WarpMode = .none,
    warp_amount: f32 = 0.0,
    // OSC B
    osc_b_on: bool = false,
    osc_b_waveform: synth_mod.Waveform = .saw,
    osc_b_wt_bundled: ?synth_mod.BundledWavetable = .basic,
    osc_b_pulse_width: f32 = 0.5,
    osc_b_semi: f32 = 0.0,
    osc_b_detune_cents: f32 = 0.0,
    osc_b_level: f32 = 1.0,
    osc_b_unison: u8 = 1,
    osc_b_unison_detune: f32 = 15.0,
    osc_b_unison_mode: synth_mod.UnisonMode = .spread,
    osc_b_warp_mode: synth_mod.WarpMode = .none,
    osc_b_warp_amount: f32 = 0.0,
    // OSC C
    osc_c_on: bool = false,
    osc_c_waveform: synth_mod.Waveform = .saw,
    osc_c_wt_bundled: ?synth_mod.BundledWavetable = .basic,
    osc_c_pulse_width: f32 = 0.5,
    osc_c_semi: f32 = 0.0,
    osc_c_detune_cents: f32 = 0.0,
    osc_c_level: f32 = 1.0,
    osc_c_unison: u8 = 1,
    osc_c_unison_detune: f32 = 15.0,
    osc_c_unison_mode: synth_mod.UnisonMode = .spread,
    // Amp envelope
    attack_s: f32 = 0.005,
    decay_s: f32 = 0.08,
    sustain: f32 = 0.7,
    release_s: f32 = 0.25,
    /// Envelope segment curvature and filter input drive (additive
    /// optional-with-default fields, no version bump - absent in every file
    /// predating them, and their defaults are exactly the straight ramps and
    /// bypassed drive those files were saved with).
    env_curve: f32 = 0.0,
    // Filter
    filter_type: synth_mod.FilterType = .lp,
    filter_cutoff: f32 = 18_000.0,
    filter_res: f32 = 0.0,
    filter_drive: f32 = 1.0,
    filter2_on: bool = false,
    filter2_type: synth_mod.FilterType = .lp,
    filter2_cutoff: f32 = 18_000.0,
    filter2_res: f32 = 0.0,
    filter2_drive: f32 = 1.0,
    filter_routing: synth_mod.FilterRouting = .series,
    // Filter envelope
    fenv_attack_s: f32 = 0.005,
    fenv_decay_s: f32 = 0.5,
    fenv_sustain: f32 = 0.0,
    fenv_release_s: f32 = 0.3,
    fenv_curve: f32 = 0.0,
    // LFO
    lfo_shape: synth_mod.LfoShape = .sine,
    lfo_rate_hz: f32 = 1.0,
    /// Tempo sync / retrigger / phase offset / slew, per LFO slot (additive
    /// optional-with-default fields, no version bump - absent in every file
    /// predating them reads as the free-running Hz behaviour those files
    /// were saved with).
    lfo_sync: synth_mod.LfoSync = .off,
    lfo_retrig: synth_mod.LfoRetrig = .free,
    lfo_phase_offset: f32 = 0.0,
    lfo_slew_ms: f32 = 0.0,
    // LFO 2 / LFO 3 + macros (additive optional-with-default fields, no
    // version bump)
    lfo2_shape: synth_mod.LfoShape = .sine,
    lfo2_rate_hz: f32 = 1.0,
    lfo2_sync: synth_mod.LfoSync = .off,
    lfo2_retrig: synth_mod.LfoRetrig = .free,
    lfo2_phase_offset: f32 = 0.0,
    lfo2_slew_ms: f32 = 0.0,
    lfo3_shape: synth_mod.LfoShape = .sine,
    lfo3_rate_hz: f32 = 1.0,
    lfo3_sync: synth_mod.LfoSync = .off,
    lfo3_retrig: synth_mod.LfoRetrig = .free,
    lfo3_phase_offset: f32 = 0.0,
    lfo3_slew_ms: f32 = 0.0,
    /// `.custom` shape points (additive optional-with-default field, no
    /// version bump - a sane backward-compatible default exists and there's
    /// no legacy representation to migrate from, unlike mod_matrix's null-
    /// vs-empty split). Absence (every file predating the feature) reads as
    /// "no custom points saved"; applyToSynth then leaves PolySynth's own
    /// flat-zero default in place. Manual in synthToSnap/applyToSynth:
    /// `lfo_custom` collides by name with PolySynth's fixed-array field of
    /// the same name (different type - slice vs array), so it's excluded
    /// from the generic reflection copy like mod_matrix; lfo2_custom/
    /// lfo3_custom have no PolySynth counterpart at all (PolySynth keys all
    /// three slots off one `[3][max_lfo_shape_points]LfoShapePoint` field).
    lfo_custom: ?[]const synth_mod.LfoShapePoint = null,
    lfo2_custom: ?[]const synth_mod.LfoShapePoint = null,
    lfo3_custom: ?[]const synth_mod.LfoShapePoint = null,
    macro1: f32 = 0.0,
    macro2: f32 = 0.0,
    macro3: f32 = 0.0,
    macro4: f32 = 0.0,
    // Mod matrix (v17). Optional so its absence identifies a pre-matrix
    // file: null triggers the legacy fenv/lfo migration in applyToSynth,
    // while a present-but-empty matrix (a new file with no routing) is
    // honored as-is.
    mod_matrix: ?[]const synth_mod.PolySynth.ModRow = null,
    /// Legacy fixed mod routes (pre-v17), load-only: folded into matrix
    /// rows when `mod_matrix` is null. Written at defaults by new saves.
    fenv_amount: f32 = 0.0,
    lfo_depth: f32 = 0.0,
    lfo_target: synth_mod.LfoTarget = .none,
    // Voice
    voice_mode: synth_mod.VoiceMode = .poly,
    glide_s: f32 = 0.0,
    // Sub
    sub_level: f32 = 0.0,
    sub_shape: synth_mod.SubShape = .sine,
    // Noise
    noise_level: f32 = 0.0,
    noise_color: f32 = 1.0,
    // Mod
    mod_mode: synth_mod.ModMode = .none,
    mod_amount: f32 = 0.0,
    // Output
    gain: f32 = 0.35,
    // Internal FX (additive optional-with-default fields, no version bump)
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
    fx_mb_style: synth_mod.MbStyle = .classic,
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
    /// Additive field: missing since the tape unit shipped (7ab2e3c), so a
    /// synth's own tape settings silently reset to defaults on save/reload
    /// even though the track/master-chain tape unit persisted fine via its
    /// own `FxUnitSnap.tape` variant.
    fx_tape_on: bool = false,
    fx_tape_wow_rate_hz: f32 = 0.6,
    fx_tape_wow_depth: f32 = 0.4,
    fx_tape_flutter_rate_hz: f32 = 8.0,
    fx_tape_flutter_depth: f32 = 0.25,
    fx_tape_mix: f32 = 1.0,
    fx_order: [14]synth_mod.FxUnitKind = synth_mod.default_fx_order,
    // Arpeggiator (additive optional-with-default fields, no version bump)
    arp_on: bool = false,
    arp_mode: synth_mod.ArpMode = .up,
    arp_octaves: u8 = 1,
    arp_rate_hz: f32 = 8.0,
    arp_sync: synth_mod.LfoSync = .off,
    arp_gate: f32 = 0.5,
    arp_hold: bool = false,
    // ENV 3: free-assignable envelope, matrix source only (additive, no
    // version bump)
    env3_attack_s: f32 = 0.005,
    env3_decay_s: f32 = 0.3,
    env3_sustain: f32 = 0.0,
    env3_release_s: f32 = 0.3,
    env3_curve: f32 = 0.0,
    // Wavetable oscillators (v20): frame-scan position is additive, but
    // the sidecar-path fields are a new field *shape* (a path, not a plain
    // value) - bumped file_version for clarity, same call as the OTT unit.
    wt_pos: f32 = 0.0,
    osc_b_wt_pos: f32 = 0.0,
    osc_c_wt_pos: f32 = 0.0,
    /// Relative path to a `:load-wavetable`-imported table's sidecar WAV,
    /// empty for the bundled default (mirrors `PadSnap.sample_file`).
    wt_file: []const u8 = "",
    osc_b_wt_file: []const u8 = "",
    osc_c_wt_file: []const u8 = "",
    // Pattern player
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    /// Pattern swing, 50 (straight) to 75 (hardest shuffle) - see
    /// `dsp.PatternPlayer.swing`. Additive optional-with-default field, no
    /// version bump needed.
    swing: f32 = 50.0,
};

/// Per-pad sampler params. Defaults mirror `dsp.Pad` so projects saved before
/// the sampler existed (no `pads` array) deserialize to the original behaviour.
pub const PadSnap = struct {
    gain: f32 = 1.0,
    pan: f32 = 0.0,
    pitch_semitones: f32 = 0.0,
    start_norm: f32 = 0.0,
    end_norm: f32 = 1.0,
    reverse: bool = false,
    attack_s: f32 = 0.001,
    decay_s: f32 = 0.0,
    sustain: f32 = 1.0,
    release_s: f32 = 0.005,
    /// Edit fades multiplied on top of the ADSR (see `dsp.Pad`). Additive
    /// optional-with-default fields, no version bump needed (same call as
    /// `SynthSnap.swing`).
    fade_in_s: f32 = 0.0,
    fade_out_s: f32 = 0.0,
    /// Playback duration multiplier, independent of pitch (see `dsp.Pad`).
    /// Additive optional-with-default field, no version bump needed.
    stretch_ratio: f32 = 1.0,
    /// Bipolar tone filter and gated-playback flag (see `dsp.Pad`). Additive
    /// optional-with-default fields, no version bump needed - an older file
    /// omits them and loads with the filter bypassed and the pad latched,
    /// which is exactly how it behaved when it was saved.
    filter: f32 = 0.0,
    gate: bool = false,
    /// Retrigger play mode (see `dsp.Pad.retrig`). Additive, no version bump:
    /// an older file omits it and loads one-shot/gated exactly as saved.
    retrig: bool = false,
    /// v5: user-loaded audio, exported to the project's sample sidecar on
    /// save. Path relative to the .wsj; empty = shipped/generated audio.
    sample_file: []const u8 = "",
    /// v5: display name of a user-loaded sample ("" = keep the default).
    name: []const u8 = "",
    /// Additive field: whether this slot has ever had a sample loaded (the
    /// shipped kit's pads, or a user `:load-sample`) - `false` means the live
    /// `DrumMachine.pads[i]` is null (never materialized; see that field's
    /// own doc comment) and every other field here is just the struct
    /// default, not meaningful data. Older files omit it; since a pre-64-pad
    /// file only ever had exactly `DrumMachine.max_pads` (then 8) entries
    /// and all 8 were always loaded (the shipped kit), the load path treats
    /// omitted `used` as `true` for exactly those legacy positions - see
    /// `buildSession`.
    used: bool = false,
    /// Per-pad LFO (see `dsp.Pad.mod_lfo`). Additive optional-with-default
    /// fields, no version bump needed - an older file omits them and loads
    /// with `mod_dest = .off`, silently unmodulated, exactly how it behaved
    /// when it was saved.
    mod_rate_hz: f32 = 2.0,
    mod_depth: f32 = 0.0,
    mod_shape: lfo_mod.Shape = .sine,
    mod_dest: pad_mod.ModDest = .off,
    /// Region loop mode (see `dsp.Pad.loop`). Additive optional-with-default
    /// field, no version bump needed - an older file omits it and loads
    /// one-shot, exactly how it played when it was saved.
    loop: pad_mod.LoopMode = .off,
};

/// v23: one drum-machine note - position, duration, velocity - replacing
/// the old per-pad bitmask+velocity pair for the drum machine.s own step
/// data (see VariantSnap/DrumSnap/ClipSnap.s `notes`/`drum_notes` fields).
pub const DrumNoteSnap = struct {
    pad: u8,
    step: u16,
    duration_steps: u16 = 1,
    velocity: u7 = 127,
    /// Per-step transpose in semitones (see `DrumMachine.MidiNote.tune`).
    /// Additive optional-with-default field, no version bump needed - an
    /// older file omits it and loads untuned, exactly as it sounded.
    tune: i8 = 0,
    /// Trig condition and fire chance (see `DrumMachine.Cond`). Same additive
    /// rule: omitted means "always, 100%", which is how every pre-condition
    /// file played. `cond` is stored as the enum tag; an out-of-range tag
    /// from a hand-edited file falls back to `always` rather than erroring.
    prob: u8 = 100,
    cond: u8 = 0,
    /// Hits packed into the step, 0/1 = a plain single hit (see
    /// `DrumMachine.MidiNote.retrig`). Additive, same rule as the rest.
    retrig: u8 = 0,
    /// Timing offset as a percent of one step (see
    /// `DrumMachine.MidiNote.micro`). Additive, same rule.
    micro: i8 = 0,
};

pub const VariantSnap = struct {
    step_count: u16 = 16,
    /// Native pattern resolution.
    steps_per_beat: u8 = 4,
    /// Sparse per-pad note list - this variant's whole step grid. Slice, not
    /// `[max_pads][max_steps]`, so a hand-edited or truncated file loads by
    /// dropping the out-of-range entries instead of failing to parse.
    notes: []const DrumNoteSnap = &.{},
};

pub const DrumSnap = struct {
    /// Mutable slice (not `[]const`) - `exportSamples` fills in
    /// `sample_file` for user-loaded pads *after* this struct is built, an
    /// in-place mutation a const slice wouldn't allow.
    pads: []PadSnap = &.{},
    /// The whole variant bank, always at least one entry - the active slot's
    /// own step data lives here, not in any mirrored top-level field.
    variants: []const VariantSnap = &.{},
    /// Index of the active variant within `variants`.
    variant: u8 = 0,
    /// Swing percent (50 = straight … 75 = hardest shuffle).
    swing: f32 = 50.0,
    /// Per-pad choke group (0 = none - see DrumMachine.chokeTrigger).
    choke_group: []const u8 = &.{},
    /// Per-pad loop length in steps, 0 = follows the pattern (see
    /// `DrumMachine.pad_len`).
    pad_len: []const u16 = &.{},
    /// Name of the factory kit flavour last applied (`dsp/drum_kit.zig`'s
    /// `variants`), regenerated on load - the generated audio itself is
    /// never written to the sidecar, only user samples are. Additive: an
    /// omitted/unknown name just means no kit to regenerate, leaving the
    /// pads as the file's own `used` flags describe them.
    kit: []const u8 = "",
};

pub const CompSnap = struct {
    threshold_db: f32 = -18.0,
    ratio: f32 = 4.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
    makeup_db: f32 = 0.0,
    /// Additive: soft-knee width, dB. Missing on older files -> 0, the
    /// original hard-knee behaviour.
    knee_db: f32 = 0.0,
    /// Additive field (see FORMAT.md's versioning policy): older files omit
    /// it and load with ordinary self-detecting compression, matching every
    /// compressor's behaviour before sidechain support existed.
    sidechain_source: ?u16 = null,
    /// Additive (like `sidechain_source` itself): which drum pad within
    /// `sidechain_source`'s track to key off, instead of the whole track's
    /// mix - see `Compressor.SidechainSource.pad`. Older files omit it and
    /// load with the original whole-track behaviour; meaningless (and
    /// ignored on load) whenever `sidechain_source` itself is null.
    sidechain_pad: ?u8 = null,
    /// Additive (like `sidechain_source` itself): when true, `sidechain_source`
    /// names a group submix bus index instead of a track index - see
    /// `Compressor.SidechainSource.is_group`. Older files omit it and load
    /// with the original track-indexed meaning.
    sidechain_is_group: bool = false,
};

pub const MultibandCompSnap = struct {
    xover_lo_hz: f32 = 200.0,
    xover_hi_hz: f32 = 2000.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
    /// Additive: soft-knee width, dB, shared across all three bands.
    /// Missing on older files -> 0, the original hard-knee behaviour.
    knee_db: f32 = 0.0,
    /// Mirrors `dsp.multiband_comp.Style` as a bool (only two states) -
    /// older files can't have this field (the kind didn't exist), so
    /// there's no back-compat encoding to preserve, just the plainest shape.
    ott: bool = false,
    mix: f32 = 1.0,
    low_threshold_db: f32 = -20.0,
    low_ratio: f32 = 3.0,
    low_makeup_db: f32 = 0.0,
    mid_threshold_db: f32 = -18.0,
    mid_ratio: f32 = 4.0,
    mid_makeup_db: f32 = 0.0,
    high_threshold_db: f32 = -16.0,
    high_ratio: f32 = 3.0,
    high_makeup_db: f32 = 0.0,
};

/// The OTT unit's four user-facing controls; its multiband internals are
/// fixed tuning (see dsp/ott.zig) and deliberately not persisted - a future
/// retune should reach every saved project, not be frozen per file.
pub const OttSnap = struct {
    depth: f32 = 1.0,
    time: f32 = 1.0,
    gain_in_db: f32 = 0.0,
    gain_out_db: f32 = 0.0,
};

pub const DelaySnap = struct {
    time_s: f32 = 0.375,
    feedback: f32 = 0.35,
    mix: f32 = 0.25,
    /// Missing on any file saved before it landed; 0.0 reduces to the
    /// original unfiltered tap exactly, so old files load with unchanged sound.
    damp: f32 = 0.0,
};

pub const ReverbSnap = struct {
    mix: f32 = 0.3,
    room: f32 = 0.84,
    damp: f32 = 0.25,
    /// Missing on any file saved before these three landed; the defaults
    /// below reduce to the original 3-knob algorithm exactly, so old files
    /// load with unchanged sound.
    predelay_ms: f32 = 0.0,
    width: f32 = 1.0,
    low_cut_hz: f32 = 0.0,
};

/// Mirrors `eq_mod.BandKind` as a plain string enum for JSON stability
/// (numeric enum tags would silently shift meaning if the DSP-side enum's
/// member order ever changes).
pub const EqBandKindSnap = enum {
    peak,
    lowpass,
    highpass,
    lowshelf,
    highshelf,
    notch,
    tiltshelf,
    /// A response type this build has no filter for; loads as `.peak`.
    /// Adding one was a `file_version` bump before `openEnumParse` existed.
    unknown,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !EqBandKindSnap {
        return openEnumParse(EqBandKindSnap, allocator, source, options);
    }
};

/// Mirrors `eq_mod.StereoMode` as a plain string enum, same JSON-stability
/// reasoning as `EqBandKindSnap`.
pub const EqStereoModeSnap = enum { stereo, mid, side };

pub const EqBandSnap = struct {
    freq: f32,
    q: f32 = 0.7,
    gain_db: f32 = 0.0,
    /// Additive (like `CompSnap.sidechain_source`): band response type -
    /// older files omit it and land on the default `.peak`, the only kind
    /// a band could be before lowpass/highpass existed.
    kind: EqBandKindSnap = .peak,
    /// Additive, paired with `kind`: cascade stages for `.lowpass`/
    /// `.highpass`/`.notch` (12 dB/oct each), 1..eq_mod.max_slope. Unused
    /// (but present) for peak/shelf/tiltshelf bands.
    slope: u8 = 1,
    /// Additive: solo/mid-side/dynamic-EQ fields, all missing on older
    /// files and landing on their off/neutral defaults below.
    solo: bool = false,
    stereo_mode: EqStereoModeSnap = .stereo,
    dyn_enabled: bool = false,
    dyn_threshold_db: f32 = -24.0,
    dyn_amount_db: f32 = 0.0,
};

/// Every band at its `ParametricEq.init` frequency, flat - what a file that
/// omits `bands` entirely (a hand edit) loads as.
const default_eq_bands: [eq_mod.num_eq_bands]EqBandSnap = blk: {
    var out: [eq_mod.num_eq_bands]EqBandSnap = undefined;
    for (&out, &eq_mod.default_frequencies) |*band, freq| band.* = .{ .freq = freq };
    break :blk out;
};

pub const EqSnap = struct {
    /// Fully-parametric bands (freq/Q/gain all adjustable). std.json needs an
    /// exact length match to parse a fixed array, so the file's array is
    /// always exactly `eq_mod.num_eq_bands` long.
    bands: [eq_mod.num_eq_bands]EqBandSnap = default_eq_bands,
    bypass: bool = false,
    auto_gain: bool = false,
};

pub const GateSnap = struct {
    threshold_db: f32 = -50.0,
    attack_ms: f32 = 1.0,
    release_ms: f32 = 100.0,
    /// Additive: missing on older files -> 0, matching the original
    /// immediate-release behaviour.
    hold_ms: f32 = 0.0,
};

pub const SatSnap = struct {
    drive_db: f32 = 12.0,
    out_db: f32 = 0.0,
    mix: f32 = 1.0,
    /// Additive: shape select, missing on older files -> soft/tanh (matches
    /// Saturator's own default).
    shape: f32 = 0.0,
};

pub const CrushSnap = struct {
    bits: f32 = 8.0,
    downsample: f32 = 4.0,
    mix: f32 = 1.0,
};

pub const ChorusSnap = struct {
    rate_hz: f32 = 0.8,
    depth_ms: f32 = 4.0,
    mix: f32 = 0.5,
};

pub const PhaserSnap = struct {
    rate_hz: f32 = 0.4,
    depth: f32 = 0.9,
    feedback: f32 = 0.5,
    mix: f32 = 0.5,
};

pub const FlangerSnap = struct {
    rate_hz: f32 = 0.3,
    depth: f32 = 0.7,
    feedback: f32 = 0.5,
    mix: f32 = 0.5,
};

pub const TapeSnap = struct {
    wow_rate_hz: f32 = 0.6,
    wow_depth: f32 = 0.4,
    flutter_rate_hz: f32 = 8.0,
    flutter_depth: f32 = 0.25,
    mix: f32 = 1.0,
};

pub const FreqShiftSnap = struct {
    shift_hz: f32 = 0.0,
    mix: f32 = 1.0,
};

pub const FilterSnap = struct {
    mode: f32 = 0,
    cutoff_hz: f32 = 1000,
    resonance: f32 = 0.7,
    drive_db: f32 = 0,
    mix: f32 = 1,
};

pub const LimiterSnap = struct {
    ceiling: f32 = 0.955,
    release_ms: f32 = 80,
    /// Additive: missing on older files -> 0, the original zero-latency
    /// reactive limiter exactly.
    lookahead_ms: f32 = 0.0,
};

pub const UtilitySnap = struct {
    gain_db: f32 = 0,
    invert: f32 = 0,
    mono: f32 = 0,
    channel: f32 = 0,
    swap: f32 = 0,
};

pub const StereoWidthSnap = struct {
    width: f32 = 1,
    output_db: f32 = 0,
};

pub const AutoPanSnap = struct {
    rate_hz: f32 = 1,
    sync: f32 = 1,
    beats: f32 = 1,
    depth: f32 = 1,
    phase: f32 = 1,
};

pub const TransientShaperSnap = struct {
    attack: f32 = 0,
    sustain: f32 = 0,
    output_db: f32 = 0,
};

/// Legacy (v9 and older) fixed nine-slot rack: one optional per slot, order
/// implied. Read-only on load; v10 files carry `fx_chain` instead.
/// Mirrors rack.zig's FxKind - persist keeps its own copy so snapshots stay
/// pure data, same pattern as `InstrumentKind` below.
pub const FxKind = enum {
    gate,
    comp,
    mb_comp,
    ott,
    limiter,
    transient_shaper,
    eq,
    filter,
    utility,
    stereo_width,
    auto_pan,
    sat,
    crush,
    chorus,
    phaser,
    flanger,
    tape,
    freq_shift,
    delay,
    reverb,
    clap,
    vst3,
    /// A kind this build has no unit for, written by a newer wstudio. The
    /// loader drops the slot; see `openEnumParse`.
    unknown,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !FxKind {
        return openEnumParse(FxKind, allocator, source, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !FxKind {
        _ = allocator;
        _ = options;
        return switch (source) {
            .string => |name| std.meta.stringToEnum(FxKind, name) orelse .unknown,
            else => error.UnexpectedToken,
        };
    }
};

/// `jsonParse` body for a saved kind enum: an unrecognized name decodes as
/// `.unknown` instead of failing the whole load with `InvalidEnumTag`. That
/// is what lets a new FX or instrument kind ship without a `file_version`
/// bump - loads are pinned to one version exactly (see FORMAT.md), so a bump
/// makes every existing project unopenable, and dropping the one slot this
/// build can't build beats refusing the whole file.
fn openEnumParse(comptime E: type, allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !E {
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    defer switch (token) {
        .allocated_number, .allocated_string => |slice| allocator.free(slice),
        else => {},
    };
    return switch (token) {
        inline .number, .allocated_number, .string, .allocated_string => |slice| std.meta.stringToEnum(E, slice) orelse .unknown,
        else => error.UnexpectedToken,
    };
}

pub const ClapSnap = struct {
    path: []const u8 = "",
    plugin_id: []const u8 = "",
    state_base64: []const u8 = "",
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    swing: f32 = 50.0,
};

pub const Vst3Snap = struct {
    path: []const u8 = "",
    class_id: []const u8 = "",
    component_state_base64: []const u8 = "",
    controller_state_base64: []const u8 = "",
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    swing: f32 = 50.0,
};

/// One chain slot (v10): its kind, bypass flag, and the params for that kind
/// in the matching optional (the others stay null). A missing params field
/// loads the unit with its defaults.
pub const FxUnitSnap = struct {
    kind: FxKind,
    instance_id: u32 = 0,
    bypassed: bool = false,
    comp: ?CompSnap = null,
    mb_comp: ?MultibandCompSnap = null,
    ott: ?OttSnap = null,
    delay: ?DelaySnap = null,
    reverb: ?ReverbSnap = null,
    eq: ?EqSnap = null,
    filter: ?FilterSnap = null,
    limiter: ?LimiterSnap = null,
    utility: ?UtilitySnap = null,
    stereo_width: ?StereoWidthSnap = null,
    auto_pan: ?AutoPanSnap = null,
    transient_shaper: ?TransientShaperSnap = null,
    gate: ?GateSnap = null,
    sat: ?SatSnap = null,
    crush: ?CrushSnap = null,
    chorus: ?ChorusSnap = null,
    phaser: ?PhaserSnap = null,
    flanger: ?FlangerSnap = null,
    tape: ?TapeSnap = null,
    freq_shift: ?FreqShiftSnap = null,
    clap: ?ClapSnap = null,
    vst3: ?Vst3Snap = null,
};

pub const InstrumentKind = enum {
    empty,
    poly_synth,
    sampler,
    drum_machine,
    slicer,
    clap,
    vst3,
    soundfont,
    acoustic,
    /// An instrument this build doesn't have, written by a newer wstudio.
    /// The track loads empty; see `openEnumParse`.
    unknown,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !InstrumentKind {
        return openEnumParse(InstrumentKind, allocator, source, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !InstrumentKind {
        _ = allocator;
        _ = options;
        return switch (source) {
            .string => |name| std.meta.stringToEnum(InstrumentKind, name) orelse .unknown,
            else => error.UnexpectedToken,
        };
    }
};

/// A single-clip sampler: the pad's params, its root note, and the piano-roll
/// pattern. User-loaded clip audio rides along via `pad.sample_file` (v5);
/// without it the sampler remains empty on load.
pub const SamplerSnap = struct {
    pad: PadSnap = .{},
    root_note: u8 = 60,
    /// Mono voice mode (see `dsp.Sampler.mono`). Additive optional-with-
    /// default field, no version bump needed - defaults to polyphonic so
    /// older projects load unchanged.
    mono: bool = false,
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    /// Pattern swing, 50 (straight) to 75 (hardest shuffle) - see
    /// `dsp.PatternPlayer.swing`. Additive optional-with-default field, no
    /// version bump needed.
    swing: f32 = 50.0,
};

/// One shared-clip Slicer instrument. `sample_file`/`name` mirror
/// `PadSnap`'s own sample-sidecar fields but live at this top level (not per
/// slice) since every slice shares the ONE clip. `slices` is dense, position
/// IS the slice index (same convention `DrumSnap.pads` uses) - each entry
/// reuses `PadSnap` wholesale for its start/end/gain/pan/pitch/ADSR/reverse,
/// but its own `sample_file`/`name`/`used` fields are unused/always default
/// (the real sample lives at this struct's own `sample_file`/`name`).
pub const SlicerSnap = struct {
    sample_file: []const u8 = "",
    name: []const u8 = "",
    slices: []PadSnap = &.{},
    swing: f32 = 50.0,
    /// The whole variant bank, reusing `VariantSnap` (a slicer variant is the
    /// same 64-row grid a drum variant is, with the same note payload) and
    /// always at least one entry - same rule as `DrumSnap.variants`.
    variants: []const VariantSnap = &.{},
    /// Index of the active variant within `variants`.
    variant: u8 = 0,
    /// Per-slice choke group (0 = none - see `Slicer.chokeTrigger`). Dense,
    /// parallel to `slices`.
    choke_group: []const u8 = &.{},
    /// Per-slice loop length in steps, 0 = follows the pattern (see
    /// `Slicer.slice_len`).
    slice_len: []const u16 = &.{},
};

/// A SoundFont (.sf2) player track: the loaded font's sidecar path, the
/// selected preset (by index into the parsed font - see `SoundfontPlayer.
/// preset_index`'s own doc comment for why an index rather than bank/
/// program), the OUT params, and the piano-roll pattern (v25: soundfont is
/// melodic, gets a PatternPlayer like poly_synth/sampler). `sf2_file` empty
/// means nothing was loaded - the track loads silent, same "no
/// sample_file" convention `SamplerSnap.pad` already follows.
pub const SoundfontSnap = struct {
    sf2_file: []const u8 = "",
    /// Bundled acoustic bank id. Empty means external SF2 or no bank.
    library: []const u8 = "",
    preset_index: u16 = 0,
    gain: f32 = 1.0,
    pan: f32 = 0.0,
    transpose_semitones: f32 = 0.0,
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    swing: f32 = 50.0,
};

pub const RackSnap = struct {
    label: []const u8 = "synth",
    kind: InstrumentKind,
    synth: ?SynthSnap = null,
    sampler: ?SamplerSnap = null,
    drum: ?DrumSnap = null,
    slicer: ?SlicerSnap = null,
    clap: ?ClapSnap = null,
    vst3: ?Vst3Snap = null,
    soundfont: ?SoundfontSnap = null,
    /// The user-built chain in signal-flow order.
    fx_chain: []const FxUnitSnap = &.{},
};

pub const TrackSnap = struct {
    name: []const u8,
    gain_db: f32 = 0.0,
    pan: f32 = 0.0,
    muted: bool = false,
    soloed: bool = false,
    /// Additive field (see FORMAT.md's versioning policy): older files omit
    /// it and load with color 0 ("none"), matching every track's look
    /// before this field existed - no version bump needed.
    color: u8 = 0,
    /// Additive field: older files omit it and load ungrouped, matching
    /// every track's routing before grouping existed. Indexes into
    /// `Snapshot.groups` by position (see that field's own doc comment).
    group: ?u8 = null,
    /// Additive: parallel aux sends (see `project.SendSlot`). Older files
    /// omit it and every track loads with none, matching every track's
    /// routing before sends existed.
    sends: []const SendSnap = &.{},
};

/// One track's aux-send slot. Mirrors `project.SendSlot`. Flat bool+index
/// pair rather than a tagged union (same convention `CompSnap`'s
/// `sidechain_source`/`sidechain_is_group` pair uses) - trivial JSON
/// round-trip, no tag-string handling.
pub const SendSnap = struct {
    is_group: bool = false,
    group: u8 = 0,
    level_db: f32 = -60.0,
};

/// One track-grouping submix bus. Mirrors `Session.Group`. `Snapshot.groups`
/// is always exactly `engine_mod.max_groups` entries, dense - a slot's
/// position in the array IS its index (same convention `TrackSnap.group`
/// and the live `Session.groups`/`Engine.groups` fixed banks already use),
/// so an unused slot is written out as `.{}` (`active = false`) rather than
/// omitted, keeping every later slot's position stable.
pub const GroupSnap = struct {
    active: bool = false,
    name: []const u8 = "",
    fx_chain: []const FxUnitSnap = &.{},
    /// Additive (like `CompSnap.sidechain_source`): older files omit it and
    /// the bus loads at unity, its only possible level before faders existed.
    gain_db: f32 = 0.0,
    /// Additive: tracks-view fold state (see `Session.Group.folded`). Older
    /// files omit it and every group loads unfolded - the prior behaviour.
    folded: bool = false,
    /// Additive: bus mute (see `Session.Group.muted`). Older files omit it
    /// and every group loads unmuted - the prior (mute-had-no-bus-flag)
    /// behaviour.
    muted: bool = false,
    /// Additive: bus solo (see `Session.Group.soloed`), same shape as `muted`.
    soloed: bool = false,
};

pub const ClipKind = enum { melodic, drum };

/// One placed clip. Melodic clips carry a private note copy + loop length; drum
/// clips carry a step-count and per-pad bitmask. Mirrors `arrangement.Clip`.
pub const ClipSnap = struct {
    /// Exact placement at 32 ticks per quarter-note beat.
    start_tick: u32 = 0,
    length_ticks: u32 = time_grid.ticks_per_beat * 4,
    kind: ClipKind = .melodic,
    // melodic
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    // drum
    /// Sparse per-pad note list - the drum clip's whole step grid.
    /// Missing/out-of-range entries are dropped on load (see clipFromSnap).
    drum_notes: []const DrumNoteSnap = &.{},
    step_count: u16 = 16,
    /// Native drum-clip resolution.
    steps_per_beat: u8 = 4,
    /// Variant letter label (index) the clip was stamped from.
    variant: u8 = 0,
    /// Gain (dB) / pan (-1..1) automation breakpoints, clip-relative beats.
    /// Independent of `kind` - either clip type can carry them.
    gain_automation: []const AutomationPointSnap = &.{},
    pan_automation: []const AutomationPointSnap = &.{},
    /// Sparse synth-instrument- and FX-unit-param automation lanes.
    synth_param_automation: []const SynthParamAutomationSnap = &.{},
};

/// One track's lane of clips. Lanes are parallel to `racks`/`tracks`.
pub const LaneSnap = struct {
    clips: []const ClipSnap = &.{},
};

pub const SectionSnap = struct {
    tick: u32,
    name: []const u8,
};

pub const Snapshot = struct {
    version: u32 = file_version,
    tempo_bpm: f64 = 120.0,
    /// Song key for scale tools and sample tuning; null means no key.
    scale: ?theory.Scale = null,
    /// Additive: the temperament pitched instruments play in. Older files
    /// omit it and land on equal temperament, which is what they sounded
    /// like. Stored as the raw cents table rather than a preset name so a
    /// hand-edited or future table still loads as the numbers it is.
    tuning: tuning_mod.Tuning = .{},
    /// Time signature numerator (the unit is always /4).
    beats_per_bar: u8 = 4,
    /// A/B loop region in bars (`loop_end_bar` exclusive).
    loop_enabled: bool = false,
    loop_start_bar: u32 = 0,
    loop_end_bar: u32 = 0,
    sample_rate: u32 = 48_000,
    tracks: []const TrackSnap,
    racks: []const RackSnap,
    /// Song timeline, one lane per track.
    arrangement: []const LaneSnap = &.{},
    /// Named song sections.
    sections: []const SectionSnap = &.{},
    /// Whether the loaded project plays the arrangement (true) or live loops.
    song_mode: bool = false,
    /// The master bus's user-built chain in signal-flow order, applied to the
    /// summed mix before gain/limiter.
    master_fx_chain: []const FxUnitSnap = &.{},
    /// See `GroupSnap`'s own doc comment for the dense fixed-position shape.
    groups: []const GroupSnap = &.{},
};

//! Project save / load.
//!
//! Serialises the live Session to a JSON file (*.wsj).  The snapshot types are
//! pure data - no pointers, no atomics, no heap slices matching the live structs.
//!
//! Round-trip guarantees:
//!   - All 38 PolySynth params + piano-roll notes + loop length
//!   - Drum step-count + per-pad bitmask patterns + per-pad sampler params
//!   - Per-track gain / pan / mute / solo + project tempo
//!   - FX: gate, compressor, multiband compressor (incl. OTT style), EQ,
//!     saturator, crusher, chorus, phaser, flanger, tape, frequency shifter,
//!     delay, reverb
//!   - Rack labels
//!   - User-loaded sample audio (drum pads + sampler clips), exported as mono
//!     WAVs into the "<stem>_samples" sidecar directory next to the .wsj

const std = @import("std");
const Session = @import("session.zig").Session;
const wav = @import("core/wav.zig");
const Project = @import("project.zig").Project;
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
const Pad = @import("dsp/pad.zig").Pad;
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

/// Newest format version this build writes and reads; newer files are
/// hard-rejected on load. The canonical version history (what each bump
/// added and what older files load as) and the bump-vs-additive policy
/// live in FORMAT.md; per-field migration specifics stay as doc comments
/// on the snapshot fields they concern.
pub const file_version: u32 = 25;

/// Slicer.s own step-grid ceiling (mirrors arrangement.zig.s
/// `slicer_max_steps`) - `velToSnap`/`applyVelSnap` only ever see Slicer.s
/// fixed-size vel arrays now that the drum machine.s own step data is the
/// sparse `notes` list (see `DrumNoteSnap`).
const legacy_max_steps: u16 = 64;

pub const AutomationPointSnap = struct {
    beat: f64,
    value: f32,
};

/// One synth-instrument-param automation lane - see `ClipSnap.
/// synth_param_automation`.
pub const SynthParamAutomationSnap = struct {
    param_id: u8,
    points: []const AutomationPointSnap = &.{},
};

// ---------------------------------------------------------------------------
// Snapshot types - plain data, JSON-serialisable
// ---------------------------------------------------------------------------

pub const NoteSnap = struct {
    pitch: u8,
    start_beat: f64,
    duration_beat: f64,
    velocity: f32 = 0.85,
};

pub const SynthSnap = struct {
    // OSC A
    waveform: synth_mod.Waveform = .saw,
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
    // Filter
    filter_type: synth_mod.FilterType = .lp,
    filter_cutoff: f32 = 18_000.0,
    filter_res: f32 = 0.0,
    filter2_on: bool = false,
    filter2_type: synth_mod.FilterType = .lp,
    filter2_cutoff: f32 = 18_000.0,
    filter2_res: f32 = 0.0,
    filter_routing: synth_mod.FilterRouting = .series,
    // Filter envelope
    fenv_attack_s: f32 = 0.005,
    fenv_decay_s: f32 = 0.5,
    fenv_sustain: f32 = 0.0,
    fenv_release_s: f32 = 0.3,
    // LFO
    lfo_shape: synth_mod.LfoShape = .sine,
    lfo_rate_hz: f32 = 1.0,
    // LFO 2 / LFO 3 + macros (additive optional-with-default fields, no
    // version bump)
    lfo2_shape: synth_mod.LfoShape = .sine,
    lfo2_rate_hz: f32 = 1.0,
    lfo3_shape: synth_mod.LfoShape = .sine,
    lfo3_rate_hz: f32 = 1.0,
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
    arp_gate: f32 = 0.5,
    arp_hold: bool = false,
    // ENV 3: free-assignable envelope, matrix source only (additive, no
    // version bump)
    env3_attack_s: f32 = 0.005,
    env3_decay_s: f32 = 0.3,
    env3_sustain: f32 = 0.0,
    env3_release_s: f32 = 0.3,
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
};

/// v23: one drum-machine note - position, duration, velocity - replacing
/// the old per-pad bitmask+velocity pair for the drum machine.s own step
/// data (see VariantSnap/DrumSnap/ClipSnap.s `notes`/`drum_notes` fields).
pub const DrumNoteSnap = struct {
    pad: u8,
    step: u16,
    duration_steps: u16 = 1,
    velocity: u7 = 127,
};

pub const VariantSnap = struct {
    step_count: u16 = 16,
    /// Native pattern resolution. Absent in older files means 1/16 notes.
    steps_per_beat: u8 = 4,
    /// v4, read-only since v12: the old 2-bit velocity bitplanes. Kept only
    /// so `applyVelSnap` can migrate a pre-v12 file.s data; new files never
    /// write these (see `vel`, below). Still written/read by Slicer, whose
    /// own step data stays this fixed-size bitmask+velocity shape.
    pattern: []const u64 = &.{},
    vel_lo: []const u64 = &.{},
    vel_hi: []const u64 = &.{},
    /// v12: per-pad, per-step velocity (0-127; 127 = full), superseding
    /// `vel_lo`/`vel_hi`. Nested slices, not `[max_pads][max_steps]u8` -
    /// same exact-length-match reasoning as every other pad-indexed field
    /// here (see this struct.s own history above). Slicer.only since v23
    /// (see `notes`, below) - new drum-machine saves never write this.
    vel: []const []const u8 = &.{},
    /// v23: sparse per-pad note list, replacing `pattern`/`vel` for the
    /// drum machine.s own step data (Slicer keeps writing the fields
    /// above instead - see `arrangement.Clip.Drum`.s doc comment for why
    /// the two diverged). Read-only convention as usual: a pre-v23 file
    /// has an empty `notes` and migrates from `pattern`/`vel`/`vel_lo`/
    /// `vel_hi` instead (see `legacyPatternVelToMidi`).
    notes: []const DrumNoteSnap = &.{},
};

pub const DrumSnap = struct {
    /// Legacy live-pattern fields: always the active variant.s data, so v2
    /// readers (and hand edits) see a coherent single pattern.
    step_count: u16 = 16,
    steps_per_beat: u8 = 4,
    /// Slice, not a fixed array - see VariantSnap.s doc comment; same
    /// backward-compat reasoning applies to every pad-indexed field below.
    /// Read-only since v23 - see `notes`, below.
    pattern: []const u64 = &.{},
    /// v23: sparse per-pad note list mirroring the active variant, same
    /// role `pattern` played for v2 readers - see `VariantSnap.notes`.
    notes: []const DrumNoteSnap = &.{},
    /// Mutable slice (not `[]const`) - `exportSamples` fills in
    /// `sample_file` for user-loaded pads *after* this struct is built, an
    /// in-place mutation a const slice wouldn't allow.
    pads: []PadSnap = &.{},
    /// v3: the whole variant bank. Empty in v2 files - the machine then gets a
    /// single variant from the legacy fields above.
    variants: []const VariantSnap = &.{},
    /// v3: index of the active variant within `variants`.
    variant: u8 = 0,
    /// v4: swing percent (50 = straight … 75 = hardest shuffle).
    swing: f32 = 50.0,
    /// v8: per-pad choke group (0 = none - see DrumMachine.chokeTrigger).
    choke_group: []const u8 = &.{},
};

pub const CompSnap = struct {
    threshold_db: f32 = -18.0,
    ratio: f32 = 4.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
    makeup_db: f32 = 0.0,
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
};

pub const MultibandCompSnap = struct {
    xover_lo_hz: f32 = 200.0,
    xover_hi_hz: f32 = 2000.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
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
};

pub const ReverbSnap = struct {
    mix: f32 = 0.3,
    room: f32 = 0.84,
    damp: f32 = 0.25,
};

/// Legacy per-band gain array shape (v13 and older): 10 fixed ISO-frequency
/// bands, gain-only. Length is hardcoded - NOT tied to `eq_mod.num_eq_bands`
/// (8 as of v14) - since std.json requires an exact length match to parse a
/// fixed array (same constraint the v11 pad-cap migration hit); an old
/// 10-element file array must keep landing on a 10-element field forever.
const legacy_eq_band_count = 10;

// zig fmt: off
/// Legacy fixed ISO center frequencies (v13 and older) - kept only so
/// `migrateEqBands` can nearest-match an old file's `band_gains` onto
/// v14's parametric bands.
const legacy_iso_frequencies = [legacy_eq_band_count]f32{
    31.25, 62.5,  125.0,  250.0,  500.0,
    1000.0, 2000.0, 4000.0, 8000.0, 16000.0,
};
// zig fmt: on

/// Mirrors `eq_mod.BandKind` as a plain string enum for JSON stability
/// (numeric enum tags would silently shift meaning if the DSP-side enum's
/// member order ever changes).
pub const EqBandKindSnap = enum { peak, lowpass, highpass };

pub const EqBandSnap = struct {
    freq: f32,
    q: f32 = 0.7,
    gain_db: f32 = 0.0,
    /// Additive (like `CompSnap.sidechain_source`): band response type -
    /// older files omit it and land on the default `.peak`, the only kind
    /// a band could be before lowpass/highpass existed.
    kind: EqBandKindSnap = .peak,
    /// Additive, paired with `kind`: cascade stages for `.lowpass`/
    /// `.highpass` (12 dB/oct each), 1..eq_mod.max_slope. Unused (but
    /// present) for `.peak`.
    slope: u8 = 1,
};

pub const EqSnap = struct {
    /// v13 and older, read-only since v14 - see `file_version`'s v14 doc
    /// comment. New saves never write this.
    band_gains: ?[legacy_eq_band_count]f32 = null,
    /// v14: 8 fully-parametric bands (freq/Q/gain all adjustable).
    bands: ?[eq_mod.num_eq_bands]EqBandSnap = null,
    bypass: bool = false,
};

/// Migrate a pre-v14 EqSnap's `band_gains` (10 fixed ISO bands, gain-only)
/// onto v14's 8 parametric bands: each new band's default frequency
/// inherits the nearest legacy ISO band's gain (nearest in log-frequency,
/// matching how the ear perceives spacing); Q defaults to the old fixed
/// 0.7. See `file_version`'s v14 doc comment.
fn migrateEqBands(band_gains: [legacy_eq_band_count]f32) [eq_mod.num_eq_bands]EqBandSnap {
    var out: [eq_mod.num_eq_bands]EqBandSnap = undefined;
    for (&out, &eq_mod.default_frequencies) |*band, freq| {
        var best_idx: usize = 0;
        var best_dist: f32 = std.math.inf(f32);
        for (legacy_iso_frequencies, 0..) |lf, i| {
            const dist = @abs(@log(freq) - @log(lf));
            if (dist < best_dist) {
                best_dist = dist;
                best_idx = i;
            }
        }
        band.* = .{ .freq = freq, .q = 0.7, .gain_db = band_gains[best_idx] };
    }
    return out;
}

pub const GateSnap = struct {
    threshold_db: f32 = -50.0,
    attack_ms: f32 = 1.0,
    release_ms: f32 = 100.0,
};

pub const SatSnap = struct {
    drive_db: f32 = 12.0,
    out_db: f32 = 0.0,
    mix: f32 = 1.0,
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

/// Legacy (v9 and older) fixed nine-slot rack: one optional per slot, order
/// implied. Read-only on load; v10 files carry `fx_chain` instead.
pub const FxSnap = struct {
    comp: ?CompSnap = null,
    delay: ?DelaySnap = null,
    reverb: ?ReverbSnap = null,
    eq: ?EqSnap = null,
    gate: ?GateSnap = null,
    sat: ?SatSnap = null,
    crush: ?CrushSnap = null,
    chorus: ?ChorusSnap = null,
    phaser: ?PhaserSnap = null,
};

/// Mirrors rack.zig's FxKind - persist keeps its own copy so snapshots stay
/// pure data, same pattern as `InstrumentKind` below.
pub const FxKind = enum { gate, comp, mb_comp, ott, eq, sat, crush, chorus, phaser, flanger, tape, freq_shift, delay, reverb, clap };

pub const ClapSnap = struct {
    path: []const u8 = "",
    plugin_id: []const u8 = "",
    state_base64: []const u8 = "",
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    swing: f32 = 50.0,
};

/// One chain slot (v10): its kind, bypass flag, and the params for that kind
/// in the matching optional (the others stay null). A missing params field
/// loads the unit with its defaults.
pub const FxUnitSnap = struct {
    kind: FxKind,
    bypassed: bool = false,
    comp: ?CompSnap = null,
    mb_comp: ?MultibandCompSnap = null,
    ott: ?OttSnap = null,
    delay: ?DelaySnap = null,
    reverb: ?ReverbSnap = null,
    eq: ?EqSnap = null,
    gate: ?GateSnap = null,
    sat: ?SatSnap = null,
    crush: ?CrushSnap = null,
    chorus: ?ChorusSnap = null,
    phaser: ?PhaserSnap = null,
    flanger: ?FlangerSnap = null,
    tape: ?TapeSnap = null,
    freq_shift: ?FreqShiftSnap = null,
    clap: ?ClapSnap = null,
};

pub const InstrumentKind = enum { empty, poly_synth, sampler, drum_machine, slicer, clap, soundfont };

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
    /// Legacy live-pattern fields: always the active variant's data (same
    /// convention as `DrumSnap`'s), so pre-variant readers and hand edits
    /// see a coherent single pattern.
    step_count: u8 = 16,
    /// Dense, parallel to `slices` - same "slice not fixed array" shape
    /// every other pattern-indexed field in this file uses.
    pattern: []const u64 = &.{},
    vel: []const []const u8 = &.{},
    swing: f32 = 50.0,
    /// Additive, no version bump (see FORMAT.md's policy): the whole
    /// variant bank, reusing `VariantSnap` (a slicer variant is the same
    /// 64-row grid a drum variant is). Empty in older files - the slicer
    /// then gets a single variant from the legacy fields above.
    variants: []const VariantSnap = &.{},
    /// Additive: index of the active variant within `variants`.
    variant: u8 = 0,
    /// Additive: per-slice choke group (0 = none - see
    /// `Slicer.chokeTrigger`). Dense, parallel to `slices`.
    choke_group: []const u8 = &.{},
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
    soundfont: ?SoundfontSnap = null,
    /// Legacy fixed rack (v9 and older). Only read when `fx_chain` is null.
    fx: FxSnap = .{},
    /// v10: the user-built chain in signal-flow order.
    fx_chain: ?[]const FxUnitSnap = null,
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
};

pub const ClipKind = enum { melodic, drum };

/// One placed clip. Melodic clips carry a private note copy + loop length; drum
/// clips carry a step-count and per-pad bitmask. Mirrors `arrangement.Clip`.
pub const ClipSnap = struct {
    /// Legacy whole-bar placement, read for files through v21.
    start_bar: u32 = 0,
    length_bars: u32 = 1,
    /// v22 exact placement at 32 ticks per quarter-note beat.
    start_tick: ?u32 = null,
    length_ticks: ?u32 = null,
    kind: ClipKind = .melodic,
    // melodic
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    // drum
    // v11: widened from a [DrumMachine.max_pads]u64 fixed array to a slice -
    // std.json requires exact-length matches for fixed arrays, and max_pads
    // grew 8->64, so old files' 8-element arrays would otherwise fail to
    // parse. Missing/short entries are zero-filled on load (see clipFromSnap).
    drum_pattern: []const u64 = &.{},
    /// v4: per-step velocity bitplanes. Zero (or absent) = full velocity.
    /// v4, read-only since v12 - see `VariantSnap.vel_lo`'s doc comment.
    drum_vel_lo: []const u64 = &.{},
    drum_vel_hi: []const u64 = &.{},
    /// v12: per-pad, per-step velocity - see `VariantSnap.vel`'s doc comment.
    drum_vel: []const []const u8 = &.{},
    /// v23: sparse per-pad note list - the drum-machine.s own step data
    /// (`drum_pattern`/`drum_vel` above stay Slicer.s fixed-size shape;
    /// see `arrangement.Clip.Drum`.s doc comment). Read-only convention:
    /// a pre-v23 file has an empty `drum_notes` and migrates from
    /// `drum_pattern`/`drum_vel`/`drum_vel_lo`/`drum_vel_hi` instead.
    drum_notes: []const DrumNoteSnap = &.{},
    step_count: u16 = 16,
    /// Native drum-clip resolution. Older clips default to 1/16 notes.
    steps_per_beat: u8 = 4,
    /// v3: variant letter label (index) the clip was stamped from.
    variant: u8 = 0,
    /// v7: gain (dB) / pan (-1..1) automation breakpoints, clip-relative
    /// beats. Independent of `kind` - either clip type can carry them.
    gain_automation: []const AutomationPointSnap = &.{},
    pan_automation: []const AutomationPointSnap = &.{},
    /// v13: sparse synth-instrument-param automation lanes - supersedes
    /// `filter_cutoff_automation` below (kept, read-only, for the legacy
    /// remap; see `file_version`'s v13 doc comment). New saves never write
    /// the old field, matching v11/v12's own migration convention.
    synth_param_automation: []const SynthParamAutomationSnap = &.{},
    /// v7, read-only since v13 - see `synth_param_automation`'s doc comment.
    /// Hz, 20..20_000.
    filter_cutoff_automation: []const AutomationPointSnap = &.{},
};

/// One track's lane of clips. Lanes are parallel to `racks`/`tracks`.
pub const LaneSnap = struct {
    clips: []const ClipSnap = &.{},
};

pub const Snapshot = struct {
    version: u32 = file_version,
    tempo_bpm: f64 = 120.0,
    /// v4: time signature numerator (the unit is always /4). Older files
    /// omit it and load as 4/4 - the prior behaviour.
    beats_per_bar: u8 = 4,
    /// v5: A/B loop region in bars (`loop_end_bar` exclusive). Older files
    /// omit it and load with no loop - the prior behaviour.
    loop_enabled: bool = false,
    loop_start_bar: u32 = 0,
    loop_end_bar: u32 = 0,
    sample_rate: u32 = 48_000,
    tracks: []const TrackSnap,
    racks: []const RackSnap,
    /// Song timeline, one lane per track. Empty for v1 files.
    arrangement: []const LaneSnap = &.{},
    /// Whether the loaded project plays the arrangement (true) or live loops.
    song_mode: bool = false,
    /// v6: master bus FX, applied to the summed mix before gain/limiter.
    /// Legacy fixed rack; only read when `master_fx_chain` is null.
    master_fx: FxSnap = .{},
    /// v10: the master bus's user-built chain in signal-flow order.
    master_fx_chain: ?[]const FxUnitSnap = null,
    /// Additive field: older files omit it (empty slice) and load with no
    /// groups - every track's `TrackSnap.group` reference is then
    /// necessarily null too, since a group it could point at never existed.
    /// See `GroupSnap`'s own doc comment for the dense fixed-position shape.
    groups: []const GroupSnap = &.{},
};

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------

/// Serialise `session` as pretty-printed JSON to `path`. Writes to
/// `<path>.tmp` and renames over the target so a crash mid-write never
/// corrupts an existing project file. User-loaded sample audio is exported
/// alongside into the "<stem>_samples" sidecar directory (see
/// `exportSamples`). Safe to call while the audio thread is running.
pub fn save(
    allocator: std.mem.Allocator,
    session: *const Session,
    io: std.Io,
    path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // zig fmt: off
    const tracks = try aa.alloc(TrackSnap, session.project.tracks.items.len);
    for (session.project.tracks.items, tracks) |t, *ts| {
        ts.* = .{
            .name = t.name, .gain_db = t.gain_db, .pan = t.pan, .muted = t.muted,
            .soloed = t.soloed, .color = t.color, .group = t.group,
        };
    }
    // zig fmt: on

    // Dense, always max_groups entries so a slot's position in the array IS
    // its index - TrackSnap.group references that position directly, no
    // separate id field or remapping needed on either side.
    const groups = try aa.alloc(GroupSnap, engine_mod.max_groups);
    for (groups, 0..) |*gs, i| {
        if (session.groups[i]) |*g| {
            gs.* = .{ .active = true, .name = g.name, .fx_chain = try chainToSnap(aa, &g.fx, session.project.sample_rate), .gain_db = g.gain_db, .folded = g.folded };
        } else {
            gs.* = .{};
        }
    }

    const racks = try aa.alloc(RackSnap, session.racks.items.len);
    for (session.racks.items, racks) |rack, *rs| {
        rs.* = try rackToSnap(aa, rack, session.project.sample_rate);
    }
    try exportSamples(aa, session, io, path, racks);

    const lanes = try aa.alloc(LaneSnap, session.arrangement.lanes.items.len);
    for (session.arrangement.lanes.items, lanes) |*lane, *ls| {
        const clips = try aa.alloc(ClipSnap, lane.clips.items.len);
        for (lane.clips.items, clips) |clip, *c| c.* = try clipToSnap(aa, clip);
        ls.* = .{ .clips = clips };
    }

    const snap: Snapshot = .{
        .tempo_bpm = session.project.tempo_bpm,
        .beats_per_bar = session.project.beats_per_bar,
        .loop_enabled = session.project.loop_enabled,
        .loop_start_bar = session.project.loop_start_bar,
        .loop_end_bar = session.project.loop_end_bar,
        .sample_rate = session.project.sample_rate,
        .tracks = tracks,
        .racks = racks,
        .arrangement = lanes,
        .song_mode = session.song_mode,
        .master_fx_chain = try chainToSnap(aa, &session.master_fx, session.project.sample_rate),
        .groups = groups,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(aa, snap, .{ .whitespace = .indent_2 });

    const tmp_path = try std.fmt.allocPrint(aa, "{s}.tmp", .{path});
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(json_bytes);
        try fw.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

fn rackToSnap(aa: std.mem.Allocator, rack: *Rack, sample_rate: u32) !RackSnap {
    var rs: RackSnap = .{ .label = rack.label, .kind = undefined };

    // zig fmt: off
    switch (rack.instrument) {
        .empty => {
            rs.kind = .empty;
        },
        .poly_synth => |*s| {
            rs.kind = .poly_synth;
            var ss = synthToSnap(s);
            if (rack.pattern_player) |*pp| {
                ss.length_beats = pp.length_beats;
                ss.notes = try notesToSnap(aa, pp);
                ss.swing = pp.swing.load(.monotonic);
            }
            rs.synth = ss;
        },
        .sampler => |*s| {
            rs.kind = .sampler;
            var smp: SamplerSnap = .{
                .pad = .{
                    .gain = s.pad.gain, .pan = s.pad.pan, .pitch_semitones = s.pad.pitch_semitones,
                    .start_norm = s.pad.start_norm, .end_norm = s.pad.end_norm, .reverse = s.pad.reverse,
                    .attack_s = s.pad.attack_s, .decay_s = s.pad.decay_s,
                    .sustain = s.pad.sustain, .release_s = s.pad.release_s,
                    // Always saved - see the drum pad loop's comment above.
                    .name = try aa.dupe(u8, s.clipName()),
                },
                .root_note = s.root_note,
                .mono = s.mono,
            };
            if (rack.pattern_player) |*pp| {
                smp.length_beats = pp.length_beats;
                smp.notes = try notesToSnap(aa, pp);
                smp.swing = pp.swing.load(.monotonic);
            }
            rs.sampler = smp;
        },
        .drum_machine => |*dm| {
            rs.kind = .drum_machine;
            var ds: DrumSnap = .{
                .step_count = dm.step_count,
                .steps_per_beat = dm.steps_per_beat,
                .variant = dm.variant,
                .swing = dm.swing.load(.monotonic),
            };
            // Dense, always DrumMachine.max_pads entries - position IS the
            // pad index everywhere below, same "slice for JSON-length
            // safety, but positionally dense" shape VariantSnap's own doc
            // comment explains.
            const choke = try aa.alloc(u8, DrumMachine.max_pads);
            @memcpy(choke, &dm.choke_group);
            ds.choke_group = choke;
            // zig fmt: on

            ds.notes = try midiToNoteSnaps(aa, &dm.midi);

            const variants = try aa.alloc(VariantSnap, dm.variant_count);
            for (variants, 0..) |*vs, vi| {
                // variantData reads the active slot from the live state.
                const v = dm.variantData(@intCast(vi));
                vs.* = .{ .step_count = v.step_count, .steps_per_beat = v.steps_per_beat, .notes = try midiToNoteSnaps(aa, &v.midi) };
            }
            ds.variants = variants;

            // zig fmt: off
            const pads = try aa.alloc(PadSnap, DrumMachine.max_pads);
            for (pads, 0..) |*ps, i| {
                if (dm.pads[i]) |*s| {
                    const p = &s.pad;
                    ps.* = .{
                        .used = true,
                        .gain = p.gain, .pan = p.pan, .pitch_semitones = p.pitch_semitones,
                        .start_norm = p.start_norm, .end_norm = p.end_norm, .reverse = p.reverse,
                        .attack_s = p.attack_s, .decay_s = p.decay_s,
                        .sustain = p.sustain, .release_s = p.release_s,
                        // Always saved (like a track name), independent of
                        // whether the pad has user-loaded audio - a `:pad-rename`
                        // on a shipped-kit pad has no sample_file to carry the
                        // name through otherwise. exportSamples overwrites this
                        // with the same value for user-sample pads.
                        .name = try aa.dupe(u8, s.clipName()),
                    };
                } else {
                    ps.* = .{}; // used = false - unloaded, nothing else here is meaningful
                }
            }
            ds.pads = pads;
            rs.drum = ds;
        },
        .slicer => |*sl| {
            rs.kind = .slicer;
            var sls: SlicerSnap = .{
                .step_count = sl.step_count,
                .swing = sl.swing.load(.monotonic),
                // Always saved - see the drum pad loop's identical comment
                // above (exportSamples overwrites this for user-sample clips).
                .name = try aa.dupe(u8, sl.clipName()),
            };

            const slices = try aa.alloc(PadSnap, sl.slice_count);
            for (slices, 0..) |*ps, i| {
                const p = &sl.slices[i];
                ps.* = .{
                    .gain = p.gain, .pan = p.pan, .pitch_semitones = p.pitch_semitones,
                    .start_norm = p.start_norm, .end_norm = p.end_norm, .reverse = p.reverse,
                    .attack_s = p.attack_s, .decay_s = p.decay_s,
                    .sustain = p.sustain, .release_s = p.release_s,
                };
            }
            sls.slices = slices;
            // zig fmt: on

            const pattern = try aa.alloc(u64, sl.slice_count);
            for (pattern, 0..) |*p, i| p.* = sl.pattern[i].load(.acquire);
            sls.pattern = pattern;

            const vel = try aa.alloc([]const u8, sl.slice_count);
            for (vel, 0..) |*row, i| {
                const r = try aa.alloc(u8, Slicer.max_steps);
                for (r, 0..) |*v, s| v.* = sl.vel[i][s].load(.acquire);
                row.* = r;
            }
            sls.vel = vel;

            // The whole variant bank; the active slot reads through
            // variantData (its bank copy is stale) - mirrors the drum
            // export above. The legacy flat fields above stay the active
            // variant's data for older readers.
            const variants = try aa.alloc(VariantSnap, sl.variant_count);
            for (variants, 0..) |*vs, vi| {
                const v = sl.variantData(@intCast(vi));
                const vp = try aa.alloc(u64, Slicer.max_slices);
                for (vp, v.pattern) |*p, bits| p.* = bits;
                vs.* = .{ .step_count = v.step_count, .pattern = vp, .vel = try velToSnap(aa, &v.vel) };
            }
            sls.variants = variants;
            sls.variant = sl.variant;

            const choke = try aa.alloc(u8, Slicer.max_slices);
            for (choke, sl.choke_group) |*c, g| c.* = g;
            sls.choke_group = choke;

            rs.slicer = sls;
        },
        .clap => |plugin| {
            rs.kind = .clap;
            var cs = try clapToSnap(aa, plugin);
            if (rack.pattern_player) |*pp| {
                cs.length_beats = pp.length_beats;
                cs.notes = try notesToSnap(aa, pp);
                cs.swing = pp.swing.load(.monotonic);
            }
            rs.clap = cs;
        },
        .soundfont => |*sf| {
            rs.kind = .soundfont;
            var sfs: SoundfontSnap = .{
                .preset_index = sf.preset_index,
                .gain = sf.gain,
                .pan = sf.pan,
                .transpose_semitones = sf.transpose_semitones,
            };
            if (rack.pattern_player) |*pp| {
                sfs.length_beats = pp.length_beats;
                sfs.notes = try notesToSnap(aa, pp);
                sfs.swing = pp.swing.load(.monotonic);
            }
            rs.soundfont = sfs;
        },
    }

    rs.fx_chain = try chainToSnap(aa, &rack.fx, sample_rate);

    return rs;
}

fn clapToSnap(aa: std.mem.Allocator, plugin: *rack_mod.ClapPlugin) !ClapSnap {
    var state_base64: []const u8 = "";
    if (try plugin.saveState(aa)) |state| {
        defer aa.free(state);
        const encoded = try aa.alloc(u8, std.base64.standard.Encoder.calcSize(state.len));
        state_base64 = std.base64.standard.Encoder.encode(encoded, state);
    }
    return .{
        .path = try aa.dupe(u8, plugin.pluginPath()),
        .plugin_id = try aa.dupe(u8, plugin.id()),
        .state_base64 = state_base64,
    };
}

/// Copy a device's fields into its Snap type by name - for the FX kinds
/// below where the two structs mirror 1:1 (device just carries extra
/// runtime-state fields the Snap doesn't have). comp/mb_comp/ott/delay/eq
/// keep hand-written cases since they transform or nest fields.
fn snapFromDevice(comptime Snap: type, device: anytype) Snap {
    var out: Snap = .{};
    inline for (std.meta.fields(Snap)) |f| @field(out, f.name) = @field(device, f.name);
    return out;
}

/// Inverse of `snapFromDevice`: write a Snap's fields onto a live device by
/// name, leaving the device's other (runtime-state) fields untouched.
fn applySnapToDevice(device: anytype, snap: anytype) void {
    inline for (std.meta.fields(@TypeOf(snap))) |f| {
        const value = @field(snap, f.name);
        switch (@typeInfo(f.type)) {
            .float => if (std.math.isFinite(value)) {
                @field(device.*, f.name) = value;
            },
            else => @field(device.*, f.name) = value,
        }
    }
}

// zig fmt: off
/// Shared by track racks and the master bus - both hold a user-built `Fx`
/// chain. One FxUnitSnap per slot, in chain order.
fn chainToSnap(aa: std.mem.Allocator, fx: *const Fx, sample_rate: u32) ![]FxUnitSnap {
    const out = try aa.alloc(FxUnitSnap, fx.units.items.len);
    for (fx.units.items, out) |u, *us| {
        us.* = switch (u.payload) {
            .comp => |c| .{ .kind = .comp, .comp = .{
                .threshold_db = c.threshold_db, .ratio = c.ratio,
                .attack_ms = c.attack_ms, .release_ms = c.release_ms, .makeup_db = c.makeup_db,
                .sidechain_source = if (c.sidechain_source) |sc| sc.track else null,
                .sidechain_pad = if (c.sidechain_source) |sc| sc.pad else null,
            } },
            .mb_comp => |m| .{ .kind = .mb_comp, .mb_comp = .{
                .xover_lo_hz = m.xover_lo_hz, .xover_hi_hz = m.xover_hi_hz,
                .attack_ms = m.attack_ms, .release_ms = m.release_ms,
                .ott = m.style == .ott, .mix = m.mix,
                .low_threshold_db = m.bands[0].threshold_db, .low_ratio = m.bands[0].ratio, .low_makeup_db = m.bands[0].makeup_db,
                .mid_threshold_db = m.bands[1].threshold_db, .mid_ratio = m.bands[1].ratio, .mid_makeup_db = m.bands[1].makeup_db,
                .high_threshold_db = m.bands[2].threshold_db, .high_ratio = m.bands[2].ratio, .high_makeup_db = m.bands[2].makeup_db,
            } },
            .ott => |o| .{ .kind = .ott, .ott = .{
                .depth = o.depth(), .time = o.time,
                .gain_in_db = o.gain_in_db, .gain_out_db = o.gain_out_db,
            } },
            .delay => |d| .{ .kind = .delay, .delay = .{
                .time_s = @as(f32, @floatFromInt(d.delay_frames)) / @as(f32, @floatFromInt(sample_rate)),
                .feedback = d.feedback, .mix = d.mix,
            } },
            .reverb => |r| .{ .kind = .reverb, .reverb = snapFromDevice(ReverbSnap, r) },
            .eq => |e| blk: {
                var bands: [eq_mod.num_eq_bands]EqBandSnap = undefined;
                for (&e.bands, 0..) |*b, i| bands[i] = .{
                    .freq = b.freq, .q = b.q, .gain_db = b.gain_db,
                    .kind = switch (b.kind) {
                        .peak => .peak, .lowpass => .lowpass, .highpass => .highpass,
                    },
                    .slope = b.slope,
                };
                break :blk .{ .kind = .eq, .eq = .{ .bands = bands } };
            },
            .gate => |g| .{ .kind = .gate, .gate = snapFromDevice(GateSnap, g) },
            .sat => |s| .{ .kind = .sat, .sat = snapFromDevice(SatSnap, s) },
            .crush => |c| .{ .kind = .crush, .crush = snapFromDevice(CrushSnap, c) },
            .chorus => |c| .{ .kind = .chorus, .chorus = snapFromDevice(ChorusSnap, c) },
            .phaser => |p| .{ .kind = .phaser, .phaser = snapFromDevice(PhaserSnap, p) },
            .flanger => |fl| .{ .kind = .flanger, .flanger = snapFromDevice(FlangerSnap, fl) },
            .tape => |t| .{ .kind = .tape, .tape = snapFromDevice(TapeSnap, t) },
            .freq_shift => |f| .{ .kind = .freq_shift, .freq_shift = snapFromDevice(FreqShiftSnap, f) },
            .clap => |plugin| .{ .kind = .clap, .clap = try clapToSnap(aa, plugin) },
        };
        us.bypassed = u.bypassed;
    }
    return out;
}
// zig fmt: on

// ---------------------------------------------------------------------------
// Sample sidecar - user-loaded audio lives in "<stem>_samples/" next to the
// .wsj as mono 16-bit WAVs; PadSnap.sample_file holds the .wsj-relative path.
// ---------------------------------------------------------------------------

/// Write every user-loaded pad's audio (`Pad.user_sample`) into the sample
/// sidecar directory and point the matching pad snapshots at the files. The
/// directory is only created when the session actually holds user samples.
/// Control thread only: pad buffers are stable while the audio thread runs
/// (they are replaced only by other control-thread calls).
fn exportSamples(
    aa: std.mem.Allocator,
    session: *const Session,
    io: std.Io,
    path: []const u8,
    racks: []RackSnap,
) !void {
    const sidecar = try std.fmt.allocPrint(aa, "{s}_samples", .{std.fs.path.stem(path)});
    const sr = session.project.sample_rate;
    var dir_ready = false;
    // Basenames written this save - anything else already in the sidecar
    // dir is left over from a previous save under different track/pad
    // indices and gets swept below.
    var written: std.StringHashMapUnmanaged(void) = .empty;
    for (session.racks.items, racks, 0..) |rack, *rs, ti| {
        switch (rack.instrument) {
            .drum_machine => |*dm| for (0..DrumMachine.max_pads) |pi| {
                const s = if (dm.pads[pi]) |*sm| sm else continue; // unloaded pad - nothing to export
                const p = &s.pad;
                if (!p.user_sample) continue;
                const base = try std.fmt.allocPrint(aa, "t{d}p{d}.wav", .{ ti, pi });
                const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                try writeSampleWav(aa, io, path, rel, &dir_ready, sr, p.samples);
                rs.drum.?.pads[pi].sample_file = rel;
                try written.put(aa, base, {});
                // .name already set by rackToSnap (unconditionally, for every pad).
            },
            .sampler => |*s| if (s.pad.user_sample) {
                const base = try std.fmt.allocPrint(aa, "t{d}clip.wav", .{ti});
                const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                try writeSampleWav(aa, io, path, rel, &dir_ready, sr, s.pad.samples);
                rs.sampler.?.pad.sample_file = rel;
                try written.put(aa, base, {});
                // .name already set by rackToSnap (unconditionally).
            },
            .slicer => |*sl| if (sl.user_sample) {
                const base = try std.fmt.allocPrint(aa, "t{d}clip.wav", .{ti});
                const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                try writeSampleWav(aa, io, path, rel, &dir_ready, sr, sl.samples);
                rs.slicer.?.sample_file = rel;
                try written.put(aa, base, {});
                // .name already set by rackToSnap (unconditionally).
            },
            .poly_synth => |*s| {
                // zig fmt: off
                if (s.wt_user) {
                    const base = try std.fmt.allocPrint(aa, "t{d}oscA.wav", .{ti});
                    const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                    try writeSampleWav(aa, io, path, rel, &dir_ready, sr, s.wt.frames);
                    rs.synth.?.wt_file = rel;
                    try written.put(aa, base, {});
                }
                if (s.osc_b_wt_user) {
                    const base = try std.fmt.allocPrint(aa, "t{d}oscB.wav", .{ti});
                    const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                    try writeSampleWav(aa, io, path, rel, &dir_ready, sr, s.osc_b_wt.frames);
                    rs.synth.?.osc_b_wt_file = rel;
                    try written.put(aa, base, {});
                }
                if (s.osc_c_wt_user) {
                    const base = try std.fmt.allocPrint(aa, "t{d}oscC.wav", .{ti});
                    const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                    try writeSampleWav(aa, io, path, rel, &dir_ready, sr, s.osc_c_wt.frames);
                    rs.synth.?.osc_c_wt_file = rel;
                    try written.put(aa, base, {});
                }
                // zig fmt: on
            },
            .soundfont => |*sf| if (sf.source_bytes.len > 0) {
                const base = try std.fmt.allocPrint(aa, "t{d}.sf2", .{ti});
                const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                try writeSampleBytes(aa, io, path, rel, &dir_ready, sf.source_bytes);
                rs.soundfont.?.sf2_file = rel;
                try written.put(aa, base, {});
            },
            else => {},
        }
    }
    try pruneOrphanSamples(aa, io, path, sidecar, &written);
}

/// Delete any `.wav`/`.sf2` in the sample sidecar dir that wasn't written
/// this save - leftovers from a track delete/reorder that changed which
/// index each surviving sample's filename is keyed by. No-op if the sidecar
/// dir doesn't exist (never had user samples, or `exportSamples` never
/// created it because this save has none either).
fn pruneOrphanSamples(
    aa: std.mem.Allocator,
    io: std.Io,
    wsj_path: []const u8,
    sidecar: []const u8,
    written: *const std.StringHashMapUnmanaged(void),
) !void {
    const full_dir = try joinWsjRel(aa, wsj_path, sidecar);
    var dir = std.Io.Dir.cwd().openDir(io, full_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var stale: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".wav") and !std.ascii.endsWithIgnoreCase(entry.name, ".sf2")) continue;
        if (written.contains(entry.name)) continue;
        try stale.append(aa, try aa.dupe(u8, entry.name));
    }
    // Delete after the iterator is done - mutating a dir mid-iterate isn't
    // guaranteed safe.
    for (stale.items) |name| dir.deleteFile(io, name) catch {};
}

/// Write one mono clip as a 16-bit WAV at `rel` (a .wsj-relative path),
/// creating the sidecar directory on first use. Same .tmp + rename dance as
/// the project file, so a crash never leaves a truncated sample behind.
fn writeSampleWav(
    aa: std.mem.Allocator,
    io: std.Io,
    wsj_path: []const u8,
    rel: []const u8,
    dir_ready: *bool,
    sample_rate: u32,
    samples: []const f32,
) !void {
    const full = try joinWsjRel(aa, wsj_path, rel);
    if (!dir_ready.*) {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(full).?);
        dir_ready.* = true;
    }
    const tmp = try std.fmt.allocPrint(aa, "{s}.tmp", .{full});
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try wav.write(&fw.interface, sample_rate, 1, samples, .pcm16);
        try fw.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), full, io);
}

/// Write raw bytes verbatim at `rel` - the soundfont sidecar's counterpart
/// to `writeSampleWav`. A loaded .sf2 can't be losslessly reconstructed
/// from the parsed, already-resolved `SoundFont` (see dsp/soundfont.zig's
/// doc comment), so the original file bytes are what gets persisted, not a
/// re-encoding. Same .tmp + rename dance as every other sidecar write.
fn writeSampleBytes(
    aa: std.mem.Allocator,
    io: std.Io,
    wsj_path: []const u8,
    rel: []const u8,
    dir_ready: *bool,
    bytes: []const u8,
) !void {
    const full = try joinWsjRel(aa, wsj_path, rel);
    if (!dir_ready.*) {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(full).?);
        dir_ready.* = true;
    }
    const tmp = try std.fmt.allocPrint(aa, "{s}.tmp", .{full});
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(bytes);
        try fw.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), full, io);
}

/// Resolve a path stored relative to the .wsj against the .wsj's directory.
/// Always returns an owned allocation.
fn joinWsjRel(allocator: std.mem.Allocator, wsj_path: []const u8, rel: []const u8) ![]const u8 {
    if (!isSafeWsjRel(rel)) return error.UnsafeRelativePath;
    if (std.fs.path.dirname(wsj_path)) |d|
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ d, rel });
    return allocator.dupe(u8, rel);
}

fn isSafeWsjRel(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/' or rel[0] == '\\') return false;
    if (rel.len >= 2 and std.ascii.isAlphabetic(rel[0]) and rel[1] == ':') return false;

    var components = std.mem.tokenizeAny(u8, rel, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

test "wsj-relative paths cannot escape the project directory" {
    const allocator = std.testing.allocator;

    const joined = try joinWsjRel(allocator, "songs/demo.wsj", "demo_samples/kick.wav");
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("songs/demo_samples/kick.wav", joined);

    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "../kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "samples/../../kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "samples\\..\\kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "/tmp/kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "\\\\server\\kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "C:\\kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", ""));
}

/// A pad's fixed 8-byte name buffer with the space padding trimmed.
fn trimmedName(name: *const [8]u8) []const u8 {
    var end: usize = name.len;
    while (end > 0 and name[end - 1] == ' ') end -= 1;
    return name[0..end];
}

/// Copy a pattern player's notes into freshly allocated NoteSnaps. Notes are
/// read under the lock into a stack buffer, then the lock is released before
/// the allocator runs - avoids leaking the lock on OOM.
fn notesToSnap(aa: std.mem.Allocator, pp: *PatternPlayer) ![]const NoteSnap {
    var tmp: [pattern_mod.max_notes]NoteSnap = undefined;
    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    const count = pp.note_count;
    for (pp.notes[0..@as(usize, count)], tmp[0..@as(usize, count)]) |n, *ns| {
        ns.* = .{ .pitch = n.pitch, .start_beat = n.start_beat, .duration_beat = n.duration_beat, .velocity = n.velocity };
    }
    pp.notes_lock.unlock();
    return aa.dupe(NoteSnap, tmp[0..@as(usize, count)]);
}

// zig fmt: off
/// Serialise one arrangement clip. Melodic clips duplicate their notes into
/// freshly allocated NoteSnaps; drum clips copy the bitmask by value.
fn clipToSnap(aa: std.mem.Allocator, clip: ws_arrangement.Clip) !ClipSnap {
    var c: ClipSnap = .{ .start_tick = clip.start_tick, .length_ticks = clip.length_ticks };
    switch (clip.content) {
        .melodic => |m| {
            c.kind = .melodic;
            c.length_beats = m.length_beats;
            const ns = try aa.alloc(NoteSnap, m.notes.len);
            for (m.notes, ns) |n, *o| o.* = .{
                .pitch = n.pitch, .start_beat = n.start_beat,
                .duration_beat = n.duration_beat, .velocity = n.velocity,
            };
            c.notes = ns;
        },
        .drum => |d| {
            c.kind = .drum;
            c.drum_pattern = try aa.dupe(u64, &d.pattern);
            c.drum_vel = try velToSnap(aa, &d.vel);
            c.step_count = d.step_count;
            c.steps_per_beat = d.steps_per_beat;
            c.variant = d.variant;
        },
    }
    c.gain_automation = try automationToSnap(aa, clip.automation.gain);
    c.pan_automation = try automationToSnap(aa, clip.automation.pan);
    if (clip.automation.synth_params.items.len > 0) {
        const sps = try aa.alloc(SynthParamAutomationSnap, clip.automation.synth_params.items.len);
        for (clip.automation.synth_params.items, sps) |sp, *o| {
            o.* = .{ .param_id = sp.param_id, .points = try automationToSnap(aa, sp.points) };
        }
        c.synth_param_automation = sps;
    }
    return c;
}
// zig fmt: on

fn automationToSnap(aa: std.mem.Allocator, points: []const AutomationPoint) ![]const AutomationPointSnap {
    const out = try aa.alloc(AutomationPointSnap, points.len);
    for (points, out) |p, *o| o.* = .{ .beat = p.beat, .value = p.value };
    return out;
}

/// Field-by-field via `@hasField`/`@field`, same pattern `PolySynth.toPatch`
/// uses - every SynthSnap field that names a matching PolySynth field is
/// copied automatically, so a newly added field can't be forgotten here the
/// way `unison_mode` and the wavetable save fields once were. `mod_matrix`
/// stays manual: PolySynth holds a fixed array, SynthSnap an optional slice.
/// `wt_file`/`osc_{b,c}_wt_file` have no PolySynth counterpart (`@hasField`
/// skips them) and are filled in by the caller after this returns.
fn synthToSnap(s: *const PolySynth) SynthSnap {
    var snap: SynthSnap = .{};
    inline for (@typeInfo(SynthSnap).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "mod_matrix")) continue;
        if (comptime std.mem.eql(u8, f.name, "lfo_custom")) continue;
        if (@hasField(PolySynth, f.name)) {
            @field(snap, f.name) = @field(s, f.name);
        }
    }
    // Slices the live synth's rows - fine, the snapshot is serialized
    // synchronously in save() while the rack is alive.
    snap.mod_matrix = s.mod_matrix[0..];
    snap.lfo_custom = s.lfo_custom[0][0..s.lfo_custom_count[0]];
    snap.lfo2_custom = s.lfo_custom[1][0..s.lfo_custom_count[1]];
    snap.lfo3_custom = s.lfo_custom[2][0..s.lfo_custom_count[2]];
    return snap;
}

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

/// Parse `path` and build a new Session from it.
/// Must be called before the audio backend starts (the backend captures
/// the engine pointer at init; swapping mid-session is unsafe in v1).
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Session {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(
        Snapshot,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    var session = try buildSession(allocator, &parsed.value);
    restoreSamples(allocator, io, path, &parsed.value, &session);
    return session;
}

/// Load the sidecar WAVs referenced by pad snapshots back into the session's
/// pads. Failures are per-pad and non-fatal: a missing or unreadable sample
/// file leaves that pad on its shipped/generated audio, params intact.
fn restoreSamples(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    snap: *const Snapshot,
    session: *Session,
) void {
    for (snap.racks, session.racks.items) |rs, rack| {
        switch (rack.instrument) {
            .drum_machine => |*dm| {
                const ds = rs.drum orelse continue;
                for (ds.pads, 0..) |ps, pi| {
                    if (pi >= DrumMachine.max_pads) break;
                    if (ps.sample_file.len == 0) {
                        // No user sample to load, but a `:pad-rename` on a
                        // shipped-kit pad still needs its name restored.
                        // Null (unmaterialized) pads have nothing to rename.
                        if (ps.name.len > 0) {
                            if (dm.pads[pi]) |*sm| sm.rename(ps.name);
                        }
                        continue;
                    }
                    const data = readWsjRel(allocator, io, path, ps.sample_file) orelse continue;
                    defer allocator.free(data);
                    // loadPadWav swaps audio + name under the pad lock and
                    // keeps the params already applied by buildSession, and
                    // materializes the pad if it wasn't already.
                    dm.loadPadWav(@intCast(pi), data, sampleName(ps)) catch continue;
                    dm.pads[pi].?.pad.user_sample = true;
                }
            },
            .sampler => |*s| {
                const smp = rs.sampler orelse continue;
                if (smp.pad.sample_file.len == 0) {
                    if (smp.pad.name.len > 0) s.rename(smp.pad.name);
                    continue;
                }
                const data = readWsjRel(allocator, io, path, smp.pad.sample_file) orelse continue;
                defer allocator.free(data);
                // loadWav swaps audio + name under the pad lock and keeps the
                // params applied by buildSession.
                s.loadWav(data, sampleName(smp.pad)) catch continue;
                s.pad.user_sample = true;
            },
            .slicer => |*sl| {
                const sls = rs.slicer orelse continue;
                if (sls.sample_file.len == 0) continue; // empty slicer, nothing to restore
                const data = readWsjRel(allocator, io, path, sls.sample_file) orelse continue;
                defer allocator.free(data);
                const name = if (sls.name.len > 0) sls.name else std.fs.path.stem(sls.sample_file);
                // reset_slices=false: buildSession already applied every
                // slice's saved start/end/etc. from `sls.slices` - this must
                // only swap the audio bytes, not wipe that back out (see
                // Slicer.loadWav's own doc comment).
                sl.loadWav(data, name, false) catch continue;
                sl.user_sample = true;
            },
            .poly_synth => |*s| {
                const ss = rs.synth orelse continue;
                if (ss.wt_file.len > 0) {
                    if (readWsjRel(allocator, io, path, ss.wt_file)) |data| {
                        defer allocator.free(data);
                        s.loadWavetable(.a, data) catch {};
                    }
                }
                if (ss.osc_b_wt_file.len > 0) {
                    if (readWsjRel(allocator, io, path, ss.osc_b_wt_file)) |data| {
                        defer allocator.free(data);
                        s.loadWavetable(.b, data) catch {};
                    }
                }
                if (ss.osc_c_wt_file.len > 0) {
                    if (readWsjRel(allocator, io, path, ss.osc_c_wt_file)) |data| {
                        defer allocator.free(data);
                        s.loadWavetable(.c, data) catch {};
                    }
                }
            },
            .soundfont => |*sf| {
                const sfs = rs.soundfont orelse continue;
                if (sfs.sf2_file.len == 0) continue; // nothing loaded
                const data = readWsjRel(allocator, io, path, sfs.sf2_file) orelse continue;
                defer allocator.free(data);
                // loadSf2 resets preset_index to 0 - re-apply the saved
                // selection only after it succeeds.
                sf.loadSf2(data) catch continue;
                sf.selectPresetIndex(sfs.preset_index);
            },
            else => {},
        }
    }
}

/// Read a sample file stored relative to the .wsj. Null on any error.
/// 512MiB covers every sidecar kind this reads, including a full GM
/// SoundFont bank (real-world ones run tens to a couple hundred MB) - every
/// other sidecar (a WAV clip/pad/wavetable) is far smaller in practice, so
/// raising the ceiling for soundfonts costs nothing for them.
fn readWsjRel(allocator: std.mem.Allocator, io: std.Io, wsj_path: []const u8, rel: []const u8) ?[]u8 {
    const full = joinWsjRel(allocator, wsj_path, rel) catch return null;
    defer allocator.free(full);
    return std.Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(512 * 1024 * 1024)) catch null;
}

/// Display name for a restored sample: the saved name, else the file stem.
fn sampleName(ps: PadSnap) []const u8 {
    return if (ps.name.len > 0) ps.name else std.fs.path.stem(ps.sample_file);
}

fn finiteClamp(comptime T: type, value: T, lo: T, hi: T, fallback: T) T {
    if (!std.math.isFinite(value)) return fallback;
    return std.math.clamp(value, lo, hi);
}

fn buildSession(allocator: std.mem.Allocator, snap: *const Snapshot) !Session {
    // Reject files this build cannot represent; clamp what can be clamped.
    // Racks, tracks, and lanes are parallel arrays everywhere downstream
    // (engine slots, editor indices), so a mismatch is a malformed file.
    if (snap.version > file_version) return error.UnsupportedVersion;
    if (snap.tracks.len != snap.racks.len) return error.MalformedProject;
    if (snap.sample_rate < 8_000 or snap.sample_rate > 384_000) return error.InvalidSampleRate;
    const beats_per_bar = std.math.clamp(snap.beats_per_bar, 1, 16);
    const steps_per_bar = @as(u32, beats_per_bar) * 4;
    const max_song_bars = std.math.maxInt(u32) / steps_per_bar;
    for (snap.arrangement) |lane| {
        for (lane.clips) |clip| {
            if (clip.length_ticks) |length| {
                const start = clip.start_tick orelse 0;
                if (length == 0 or start > std.math.maxInt(u32) - length) return error.MalformedProject;
            } else if (clip.length_bars == 0 or
                clip.start_bar > max_song_bars or
                clip.length_bars > max_song_bars - clip.start_bar)
                return error.MalformedProject;
        }
    }

    var project = Project.init(allocator);
    errdefer project.deinit();
    project.sample_rate = snap.sample_rate;
    project.tempo_bpm = finiteClamp(f64, snap.tempo_bpm, 20.0, 400.0, 120.0);
    project.beats_per_bar = beats_per_bar;
    project.loop_start_bar = snap.loop_start_bar;
    project.loop_end_bar = snap.loop_end_bar;
    project.loop_enabled = snap.loop_enabled and snap.loop_end_bar > snap.loop_start_bar;

    // zig fmt: off
    for (snap.tracks) |t| {
        // Clamped to the palette's actual size (tui/style.zig's
        // track_palette, 7 entries) - the renderer already treats an
        // out-of-range color as "uncolored" gracefully, but clamping here
        // too matches this file's established hand-edited-.wsj hygiene.
        // `group` is only bound-checked here (< max_groups); whether that
        // slot is actually an active group gets swept below, once
        // `snap.groups` itself has been loaded.
        _ = try project.addTrack(.{
            .name = t.name,
            .gain_db = finiteClamp(f32, t.gain_db, -60.0, 12.0, 0.0),
            .pan = finiteClamp(f32, t.pan, -1.0, 1.0, 0.0),
            .muted = t.muted, .soloed = t.soloed, .color = @min(t.color, 7),
            .group = if (t.group) |g| (if (g < engine_mod.max_groups) g else null) else null,
        });
    }
    // zig fmt: on

    const sr = project.sample_rate;

    const engine = try allocator.create(Engine);
    errdefer allocator.destroy(engine);
    try engine.initInPlace(allocator, sr);
    errdefer engine.deinit();
    engine.loadProject(&project);

    // zig fmt: off
    var racks: std.ArrayListUnmanaged(*Rack) = .empty;
    errdefer {
        for (racks.items) |r| { r.deinit(allocator); allocator.destroy(r); }
        racks.deinit(allocator);
    }

    for (snap.racks) |rs| {
        // Start blank so the errdefer below is always safe (empty has no heap).
        const rack = try allocator.create(Rack);
        rack.* = .{
            .instrument = .empty,
            .label = "",
            .owned_label = false,
        };
        errdefer { rack.deinit(allocator); allocator.destroy(rack); }
        // zig fmt: on

        // Duplicate the label; freed by Rack.deinit when owned_label = true.
        rack.label = try allocator.dupe(u8, rs.label);
        rack.owned_label = true;

        // zig fmt: off
        switch (rs.kind) {
            .empty => {},
            .poly_synth => {
                rack.instrument = .{ .poly_synth = try PolySynth.init(allocator, sr) };
                // PatternPlayer holds a pointer into the heap-allocated Rack -
                // must be set AFTER the instrument lands in the rack.
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                if (rs.synth) |ss| {
                    applyToSynth(&rack.instrument.poly_synth, &ss);
                    // Same clamp the clip loader applies: a zero/negative/
                    // non-finite loop length breaks the piano roll's step
                    // math and the playback wrap.
                    rack.pattern_player.?.length_beats = finiteClamp(f64, ss.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                    loadNotes(&rack.pattern_player.?, ss.notes);
                    rack.pattern_player.?.setSwing(ss.swing);
                }
            },
            .sampler => {
                rack.instrument = .{ .sampler = try Sampler.init(allocator, sr) };
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                if (rs.sampler) |smp| {
                    const s = &rack.instrument.sampler;
                    applyPadSnap(&s.pad, smp.pad);
                    s.root_note = @intCast(@min(smp.root_note, 127));
                    s.mono = smp.mono;
                    rack.pattern_player.?.length_beats = finiteClamp(f64, smp.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                    loadNotes(&rack.pattern_player.?, smp.notes);
                    rack.pattern_player.?.setSwing(smp.swing);
                }
            },
            .drum_machine => {
                rack.instrument = .{ .drum_machine = try DrumMachine.init(allocator, sr, &engine.transport) };
                if (rs.drum) |ds| {
                    const dmp = &rack.instrument.drum_machine;
                    if (ds.variants.len > 0) {
                        // v3: restore the bank. init() already gave the
                        // machine one default variant (slot 0's own
                        // allocation) - free it before rebuilding each slot
                        // to the file's own step count.
                        for (dmp.variants[0..dmp.variant_count]) |*slot| DrumMachine.freeMidi(allocator, &slot.midi);
                        const count: u8 = @intCast(@min(ds.variants.len, DrumMachine.max_variants));
                        for (ds.variants[0..count], dmp.variants[0..count]) |vs, *slot| {
                            const sc = std.math.clamp(vs.step_count, 1, DrumMachine.max_steps);
                            slot.step_count = sc;
                            slot.steps_per_beat = std.math.clamp(vs.steps_per_beat, 1, 32);
                            slot.midi = try DrumMachine.allocMidi(allocator, sc);
                            if (snap.version >= 23) {
                                applyNoteSnap(&slot.midi, sc, vs.notes);
                            } else {
                                legacyPatternVelToMidi(&slot.midi, sc, vs.pattern, vs.vel, vs.vel_lo, vs.vel_hi);
                            }
                        }
                        dmp.variant_count = count;
                        dmp.variant = @min(ds.variant, count - 1);
                        // The live pattern mirrors the active variant; the
                        // bank is the source of truth.
                        const active = &dmp.variants[dmp.variant];
                        DrumMachine.freeMidi(allocator, &dmp.midi);
                        dmp.midi = try DrumMachine.dupeMidi(allocator, &active.midi);
                        dmp.step_count = active.step_count;
                        dmp.steps_per_beat = active.steps_per_beat;
                    } else {
                        // v2: one variant from the legacy fields.
                        const sc = std.math.clamp(ds.step_count, 1, DrumMachine.max_steps);
                        DrumMachine.freeMidi(allocator, &dmp.midi);
                        dmp.midi = try DrumMachine.allocMidi(allocator, sc);
                        if (snap.version >= 23) {
                            applyNoteSnap(&dmp.midi, sc, ds.notes);
                        } else {
                            legacyPatternVelToMidi(&dmp.midi, sc, ds.pattern, &.{}, &.{}, &.{});
                        }
                        dmp.step_count = sc;
                        dmp.steps_per_beat = std.math.clamp(ds.steps_per_beat, 1, 32);
                    }
                    dmp.swing.store(
                        std.math.clamp(ds.swing, DrumMachine.swing_min, DrumMachine.swing_max),
                        .monotonic,
                    );
                    // The file is the source of truth even when it says
                    // nothing: a default/legacy DrumSnap has an empty slice
                    // here, which must still clear init()'s default hihat
                    // choke pairing, not leave it standing.
                    for (&dmp.choke_group) |*c| c.* = 0;
                    for (ds.choke_group, 0..) |g, pi| {
                        if (pi >= DrumMachine.max_pads) break;
                        dmp.choke_group[pi] = @min(g, DrumMachine.max_choke_groups);
                    }
                    // Only materialize a pad the file actually marked `used`
                    // (see PadSnap's doc comment) - an omitted/legacy entry
                    // (older files implicitly meant every one of their 8 was
                    // used, see the loop below) or an explicit `used = false`
                    // stays null, matching a pad nobody ever loaded.
                    for (ds.pads, 0..) |ps, pi| {
                        if (pi >= DrumMachine.max_pads) break;
                        // Pre-v11 files predate the "empty pad" concept
                        // entirely (every pad was always materialized, even
                        // an untouched one just carried the generated
                        // default clip) - `used` didn't exist yet, so its
                        // absence there means "was materialized", not the
                        // v11-and-later default of `false`. Version-gated,
                        // not inferred from array length (a v11+ file can
                        // legitimately have exactly 8 real entries with some
                        // genuinely unused).
                        const was_used = ps.used or snap.version < 11;
                        if (!was_used) continue;
                        // init() may have already materialized this pad (the
                        // default kit fills 0-7) - deinit it first so we don't
                        // leak its sample buffer when replacing it.
                        if (dmp.pads[pi]) |*old| old.deinit();
                        dmp.pads[pi] = Sampler.init(allocator, sr) catch continue;
                        applyPadSnap(&dmp.pads[pi].?.pad, ps);
                    }
                }
            },
            .slicer => {
                rack.instrument = .{ .slicer = try Slicer.init(allocator, sr, &engine.transport) };
                if (rs.slicer) |sls| {
                    const sl = &rack.instrument.slicer;
                    const count: u8 = @intCast(@min(sls.slices.len, Slicer.max_slices));
                    sl.slice_count = count;
                    for (sls.slices[0..count], sl.slices[0..count]) |ps, *p| {
                        p.samples = sl.samples; // applyPadSnap never touches .samples
                        applyPadSnap(p, ps);
                    }
                    if (sls.variants.len > 0) {
                        // Variant bank present: same load shape as the
                        // drum's (bound to whichever side is shorter, bits
                        // masked to each slot's own step count).
                        const vcount: u8 = @intCast(@min(sls.variants.len, Slicer.max_variants));
                        for (sls.variants[0..vcount], sl.variants[0..vcount]) |vs, *slot| {
                            const sc: u8 = @intCast(std.math.clamp(vs.step_count, 1, @as(u16, Slicer.max_steps)));
                            slot.step_count = sc;
                            const mask = Slicer.stepMask(sc);
                            const vpn = @min(vs.pattern.len, slot.pattern.len);
                            for (vs.pattern[0..vpn], slot.pattern[0..vpn]) |bits, *p| p.* = bits & mask;
                            applyVelSnap(&slot.vel, vs.vel, vs.vel_lo, vs.vel_hi);
                        }
                        sl.variant_count = vcount;
                        sl.variant = @min(sls.variant, vcount - 1);
                        sl.applyVariant(sl.variants[sl.variant]);
                    } else {
                        // Pre-variant file: one variant from the legacy
                        // flat fields.
                        sl.setStepCount(sls.step_count);
                        const pn = @min(sls.pattern.len, count);
                        for (sls.pattern[0..pn], 0..) |bits, i| {
                            sl.pattern[i].store(bits & Slicer.stepMask(sl.step_count), .monotonic);
                        }
                        const vn = @min(sls.vel.len, count);
                        for (sls.vel[0..vn], 0..) |row, i| {
                            const sn = @min(row.len, Slicer.max_steps);
                            for (row[0..sn], 0..) |v, s| sl.vel[i][s].store(v, .monotonic);
                        }
                    }
                    for (sls.choke_group, 0..) |g, i| {
                        if (i >= Slicer.max_slices) break;
                        sl.choke_group[i] = @min(g, Slicer.max_choke_groups);
                    }
                    sl.setSwing(sls.swing);
                }
            },
            .clap => {
                const cs = rs.clap orelse return error.MalformedProject;
                if (cs.path.len == 0 or cs.plugin_id.len == 0) return error.MalformedProject;
                const plugin = try rack_mod.ClapPlugin.load(allocator, cs.path, cs.plugin_id, sr);
                errdefer plugin.deinit();
                plugin.attachTransport(&engine.transport);
                try loadClapState(allocator, plugin, cs.state_base64);
                rack.instrument = .{ .clap = plugin };
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                rack.pattern_player.?.length_beats = finiteClamp(f64, cs.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                loadNotes(&rack.pattern_player.?, cs.notes);
                rack.pattern_player.?.setSwing(cs.swing);
            },
            .soundfont => {
                rack.instrument = .{ .soundfont = SoundfontPlayer.init(allocator, sr) };
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                if (rs.soundfont) |sfs| {
                    const sf = &rack.instrument.soundfont;
                    sf.gain = finiteClamp(f32, sfs.gain, 0.0, 2.0, 1.0);
                    sf.pan = finiteClamp(f32, sfs.pan, -1.0, 1.0, 0.0);
                    sf.transpose_semitones = finiteClamp(f32, sfs.transpose_semitones, -24.0, 24.0, 0.0);
                    // preset_index is restored by restoreSamples, after the
                    // sidecar .sf2 (if any) has actually loaded - loadSf2
                    // resets it to 0, so setting it here would be wiped.
                    rack.pattern_player.?.length_beats = finiteClamp(f64, sfs.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                    loadNotes(&rack.pattern_player.?, sfs.notes);
                    rack.pattern_player.?.setSwing(sfs.swing);
                }
            },
        }

        if (rs.fx_chain) |fc| try applyFxChain(allocator, &rack.fx, fc, sr, &engine.transport)
        else try applyLegacyFx(allocator, &rack.fx, rs.fx, sr, &engine.transport);
        try racks.append(allocator, rack);
    }
    // zig fmt: on

    // One blank lane per track keeps the arrangement parallel to racks/tracks;
    // clips (if any) are placed below once the Session owns the arrangement.
    var arrangement: ws_arrangement.Arrangement = .{};
    errdefer arrangement.deinit(allocator);
    for (racks.items) |_| try arrangement.addLane(allocator);

    // zig fmt: off
    var self: Session = .{
        .allocator = allocator,
        .project = project,
        .engine = engine,
        .racks = racks,
        .retired_racks = .empty,
        .retired_fx = .empty,
        .arrangement = arrangement,
    };
    for (self.racks.items, 0..) |rack, i| {
        self.syncTrackChain(@intCast(i), rack);
    }

    if (snap.master_fx_chain) |fc| try applyFxChain(allocator, &self.master_fx, fc, sr, &self.engine.transport)
    else try applyLegacyFx(allocator, &self.master_fx, snap.master_fx, sr, &self.engine.transport);
    self.syncMasterChain();
    // zig fmt: on

    // Groups: dense, positional (see GroupSnap's doc comment) - restore
    // exactly the active slots, push each to the engine, then sweep tracks
    // for any `.group` reference that turned out to point at a slot this
    // file never actually marked active (a hand-edited or truncated
    // `groups` array) and null it out, same "clamp on load" hygiene the
    // color/velocity/pad fields already follow.
    const group_count = @min(snap.groups.len, engine_mod.max_groups);
    for (snap.groups[0..group_count], 0..) |gs, i| {
        if (!gs.active) continue;
        const idx: u8 = @intCast(i);
        self.groups[idx] = .{
            .name = try allocator.dupe(u8, gs.name),
            .gain_db = finiteClamp(f32, gs.gain_db, -60.0, 12.0, 0.0),
            .folded = gs.folded,
        };
        try applyFxChain(allocator, &self.groups[idx].?.fx, gs.fx_chain, sr, &self.engine.transport);
        self.syncGroupChain(idx);
    }
    for (self.project.tracks.items) |*t| {
        if (t.group) |g| {
            if (g >= group_count or self.groups[g] == null) t.group = null;
        }
    }

    // Restore placed clips, then the song/pattern mode (setSongMode rebuilds the
    // device song buffers from the clips just placed).
    for (snap.arrangement, 0..) |ls, li| {
        const lane = self.arrangement.lane(li) orelse break;
        for (ls.clips) |cs| try lane.place(allocator, try clipFromSnap(allocator, cs, snap.beats_per_bar, snap.version));
    }
    self.setSongMode(snap.song_mode);

    return self;
}

fn loadClapState(
    allocator: std.mem.Allocator,
    plugin: *rack_mod.ClapPlugin,
    encoded: []const u8,
) !void {
    if (encoded.len == 0) return;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const state = try allocator.alloc(u8, size);
    defer allocator.free(state);
    try std.base64.standard.Decoder.decode(state, encoded);
    if (!try plugin.loadState(state)) return error.PluginStateUnsupported;
}

/// Widen a possibly-short (older/legacy) bitplane slice into a fixed
/// max_pads-length array, zero-filling any pads the slice didn't cover.
fn padBitplane(bits: []const u64) [DrumMachine.max_pads]u64 {
    var out = [_]u64{0} ** DrumMachine.max_pads;
    const n = @min(bits.len, out.len);
    @memcpy(out[0..n], bits[0..n]);
    return out;
}

/// Build a v12 `vel` snapshot (per-pad slice of per-step u8 slices) from a
/// live `[max_pads][legacy_max_steps]u8` velocity array - Slicer.s own
/// fixed-size step data (the drum machine.s own is the sparse `notes`
/// list now; see `DrumNoteSnap`).
fn velToSnap(
    aa: std.mem.Allocator,
    vel: *const [DrumMachine.max_pads][legacy_max_steps]u8,
) ![]const []const u8 {
    const out = try aa.alloc([]const u8, DrumMachine.max_pads);
    for (out, vel) |*row, *src| row.* = try aa.dupe(u8, src);
    return out;
}

/// Apply a velocity snapshot into a live `Variant.vel`/`Clip.Drum.vel`-shaped
/// array. A v12 `vel` (per-pad, per-step 0-127 slices) takes priority when
/// present; a pre-v12 file only carries the old 2-bit `vel_lo`/`vel_hi`
/// bitplanes, remapped onto the new scale via `DrumMachine.legacyVelToNew`.
/// Both absent leaves `dst` at its caller-supplied default (full velocity).
fn applyVelSnap(
    dst: *[DrumMachine.max_pads][legacy_max_steps]u8,
    vel: []const []const u8,
    vel_lo: []const u64,
    vel_hi: []const u64,
) void {
    if (vel.len > 0) {
        const pn = @min(vel.len, dst.len);
        for (vel[0..pn], dst[0..pn]) |row, *dst_row| {
            const sn = @min(row.len, dst_row.len);
            for (row[0..sn], dst_row[0..sn]) |level, *dst_level| dst_level.* = @min(level, DrumMachine.vel_full);
        }
        return;
    }
    const pn = @min(@min(vel_lo.len, vel_hi.len), dst.len);
    for (vel_lo[0..pn], vel_hi[0..pn], dst[0..pn]) |lo, hi, *dst_row| {
        for (dst_row, 0..) |*p, s| {
            const l: u2 = @intCast((lo >> @intCast(s)) & 1);
            const h: u2 = @intCast((hi >> @intCast(s)) & 1);
            p.* = DrumMachine.legacyVelToNew((h << 1) | l);
        }
    }
}

/// Build a v23 sparse note-list snapshot from a live/borrowed `midi` array
/// (see `DrumMachine.dupeMidi`'s doc comment - this only reads, never
/// frees or holds the source past the call).
fn midiToNoteSnaps(aa: std.mem.Allocator, midi: *const [DrumMachine.max_pads][]?DrumMachine.MidiNote) ![]const DrumNoteSnap {
    var count: usize = 0;
    for (midi) |row| for (row) |n| {
        if (n != null) count += 1;
    };
    const out = try aa.alloc(DrumNoteSnap, count);
    var i: usize = 0;
    for (midi, 0..) |row, pad| {
        for (row) |maybe_note| {
            const note = maybe_note orelse continue;
            out[i] = .{ .pad = @intCast(pad), .step = note.step, .duration_steps = note.duration_steps, .velocity = note.velocity };
            i += 1;
        }
    }
    return out;
}

/// Apply a v23 sparse note list into a freshly `allocMidi`'d array (already
/// sized to `step_count`) - out-of-range pad/step entries (a hand-edited or
/// truncated file) are silently dropped rather than erroring the load.
fn applyNoteSnap(midi: *[DrumMachine.max_pads][]?DrumMachine.MidiNote, step_count: u16, notes: []const DrumNoteSnap) void {
    for (notes) |n| {
        if (n.pad >= DrumMachine.max_pads or n.step >= step_count) continue;
        midi[n.pad][n.step] = .{
            .pitch = @intCast(n.pad),
            .step = n.step,
            .duration_steps = @max(1, n.duration_steps),
            .velocity = @min(n.velocity, DrumMachine.vel_full),
        };
    }
}

/// One step's velocity from a pre-v23 file's legacy fields, mirroring
/// `applyVelSnap`'s "v12 `vel` wins, else remap `vel_lo`/`vel_hi`, else full"
/// resolution but per-cell instead of building a whole dense array - the
/// drum machine's own migrated shape is the sparse `midi`, so there's no
/// dense destination to write through here.
fn legacyStepVel(vel: []const []const u8, vel_lo: []const u64, vel_hi: []const u64, pad: usize, step: u16) u8 {
    if (vel.len > 0) {
        if (pad < vel.len and step < vel[pad].len) return @min(vel[pad][step], DrumMachine.vel_full);
        return DrumMachine.vel_full;
    }
    if (pad < vel_lo.len and pad < vel_hi.len and step < 64) {
        const l: u2 = @intCast((vel_lo[pad] >> @intCast(step)) & 1);
        const h: u2 = @intCast((vel_hi[pad] >> @intCast(step)) & 1);
        return DrumMachine.legacyVelToNew((h << 1) | l);
    }
    return DrumMachine.vel_full;
}

/// Pre-v23 migration: reconstruct a freshly `allocMidi`'d `midi` array from
/// the old per-pad `u64` bitmask + velocity - legacy files predate the
/// step-count ceiling growing past 64, so every bit position is safely
/// representable (bounded to `min(step_count, 64)` as defense-in-depth).
fn legacyPatternVelToMidi(
    midi: *[DrumMachine.max_pads][]?DrumMachine.MidiNote,
    step_count: u16,
    pattern: []const u64,
    vel: []const []const u8,
    vel_lo: []const u64,
    vel_hi: []const u64,
) void {
    const pn = @min(pattern.len, DrumMachine.max_pads);
    const limit = @min(step_count, 64);
    for (pattern[0..pn], 0..) |bits, pad| {
        var step: u16 = 0;
        while (step < limit) : (step += 1) {
            if ((bits >> @intCast(step)) & 1 == 0) continue;
            const level = legacyStepVel(vel, vel_lo, vel_hi, pad, step);
            midi[pad][step] = DrumMachine.gridNote(@intCast(pad), step, level);
        }
    }
}

// zig fmt: off
/// Rebuild an arrangement clip from its snapshot. Melodic clips copy notes
/// through a stack buffer into a fresh owned allocation; drum clips are inline.
fn clipFromSnap(allocator: std.mem.Allocator, cs: ClipSnap, beats_per_bar: u8, version: u32) !ws_arrangement.Clip {
    const ticks_per_bar = @as(u32, beats_per_bar) * time_grid.ticks_per_beat;
    const start_tick = cs.start_tick orelse cs.start_bar *| ticks_per_bar;
    const length_ticks = cs.length_ticks orelse cs.length_bars *| ticks_per_bar;
    var out: ws_arrangement.Clip = switch (cs.kind) {
        .melodic => blk: {
            var tmp: [pattern_mod.max_notes]pattern_mod.Note = undefined;
            const count = @min(cs.notes.len, @as(usize, pattern_mod.max_notes));
            for (cs.notes[0..count], tmp[0..count]) |n, *o| o.* = sanitizeNote(n);
            break :blk try ws_arrangement.Clip.initMelodic(
                allocator,
                start_tick,
                length_ticks,
                tmp[0..count],
                finiteClamp(f64, cs.length_beats, 1.0, std.math.floatMax(f64), 1.0),
            );
        },
        .drum => blk2: {
            var d: ws_arrangement.Clip.Drum = .{
                .pattern = padBitplane(cs.drum_pattern),
                .step_count = std.math.clamp(cs.step_count, 1, DrumMachine.max_steps),
                .steps_per_beat = std.math.clamp(cs.steps_per_beat, 1, 32),
                .variant = @min(cs.variant, DrumMachine.max_variants - 1),
            };
            applyVelSnap(&d.vel, cs.drum_vel, cs.drum_vel_lo, cs.drum_vel_hi);
            d.midi = try DrumMachine.allocMidi(allocator, d.step_count);
            if (version >= 23) {
                applyNoteSnap(&d.midi, d.step_count, cs.drum_notes);
            } else {
                legacyPatternVelToMidi(&d.midi, d.step_count, cs.drum_pattern, cs.drum_vel, cs.drum_vel_lo, cs.drum_vel_hi);
            }
            break :blk2 ws_arrangement.Clip.initDrum(start_tick, length_ticks, d);
        },
    };
    errdefer out.deinit(allocator);
    out.automation.gain = try automationFromSnap(allocator, cs.gain_automation, -60.0, 12.0);
    out.automation.pan = try automationFromSnap(allocator, cs.pan_automation, -1.0, 1.0);
    try applySynthParamAutomationSnap(allocator, &out.automation, cs.synth_param_automation, cs.filter_cutoff_automation);
    return out;
}
// zig fmt: on

/// Load a clip's synth-param automation lanes. A v13 `synth_param_automation`
/// takes priority when present; a pre-v13 file only carries the old
/// single-lane `filter_cutoff_automation`, remapped onto param_id 21 - same
/// "new field wins, else remap the old one" convention `applyVelSnap` uses
/// for drum velocity.
fn applySynthParamAutomationSnap(
    allocator: std.mem.Allocator,
    automation: *ws_arrangement.Clip.Automation,
    synth_param_automation: []const SynthParamAutomationSnap,
    legacy_filter_cutoff: []const AutomationPointSnap,
) !void {
    if (synth_param_automation.len > 0) {
        for (synth_param_automation) |sp| {
            const range = if (synth_mod.PolySynth.findAutomatableParam(sp.param_id)) |info|
                info.range
            else
                [2]f32{ -std.math.floatMax(f32), std.math.floatMax(f32) };
            const points = try automationFromSnap(allocator, sp.points, range[0], range[1]);
            const dst = try automation.synthParamPoints(allocator, sp.param_id);
            dst.* = points;
        }
        return;
    }
    if (legacy_filter_cutoff.len > 0) {
        const points = try automationFromSnap(allocator, legacy_filter_cutoff, 20.0, 20_000.0);
        const dst = try automation.synthParamPoints(allocator, 21);
        dst.* = points;
    }
}

/// Load automation breakpoints, clamping values to the same range the live
/// editor will enforce and sorting by beat - a hand-edited file has no
/// guarantee the points arrived in order, and `automation.interpolate` relies
/// on that.
fn automationFromSnap(
    allocator: std.mem.Allocator,
    snaps: []const AutomationPointSnap,
    lo: f32,
    hi: f32,
) ![]AutomationPoint {
    const out = try allocator.alloc(AutomationPoint, snaps.len);
    for (snaps, out) |s, *o| o.* = .{
        .beat = finiteClamp(f64, s.beat, 0.0, std.math.floatMax(f64), 0.0),
        .value = finiteClamp(f32, s.value, lo, hi, std.math.clamp(0.0, lo, hi)),
    };
    std.mem.sort(AutomationPoint, out, {}, struct {
        fn lessThan(_: void, a: AutomationPoint, b: AutomationPoint) bool {
            return a.beat < b.beat;
        }
    }.lessThan);
    return out;
}

// zig fmt: off
/// Apply a pad snapshot onto a live Pad, clamping every field to the same
/// ranges `adjustParam` enforces. Unclamped values from a hand-edited file
/// would otherwise trip adjustParam's clamp bounds (lower > upper) on the
/// audio thread, or index past buffers in the waveform view.
fn applyPadSnap(p: *Pad, ps: PadSnap) void {
    p.gain            = finiteClamp(f32, ps.gain, 0.0, 2.0, 1.0);
    p.pan             = finiteClamp(f32, ps.pan, -1.0, 1.0, 0.0);
    p.pitch_semitones = finiteClamp(f32, ps.pitch_semitones, -24.0, 24.0, 0.0);
    p.start_norm      = finiteClamp(f32, ps.start_norm, 0.0, 0.99, 0.0);
    p.end_norm        = finiteClamp(f32, ps.end_norm, p.start_norm + 0.01, 1.0, 1.0);
    p.reverse         = ps.reverse;
    p.attack_s        = finiteClamp(f32, ps.attack_s, 0.0, 5.0, 0.001);
    p.decay_s         = finiteClamp(f32, ps.decay_s, 0.0, 5.0, 0.0);
    p.sustain         = finiteClamp(f32, ps.sustain, 0.0, 1.0, 1.0);
    p.release_s       = finiteClamp(f32, ps.release_s, 0.001, 5.0, 0.005);
}
// zig fmt: on

/// A NoteSnap with pitch/velocity/times forced into playable ranges.
fn sanitizeNote(n: NoteSnap) pattern_mod.Note {
    return .{
        .pitch = @intCast(@min(n.pitch, 127)),
        .start_beat = finiteClamp(f64, n.start_beat, 0.0, std.math.floatMax(f64), 0.0),
        .duration_beat = finiteClamp(f64, n.duration_beat, 0.0, std.math.floatMax(f64), 0.0),
        .velocity = finiteClamp(f32, n.velocity, 0.0, 1.0, pattern_mod.default_velocity),
    };
}

/// Load saved notes into a pattern player (control thread, before audio runs).
fn loadNotes(pp: *PatternPlayer, notes: []const NoteSnap) void {
    const count = @min(notes.len, @as(usize, pattern_mod.max_notes));
    pp.note_count = @intCast(count);
    for (notes[0..count], 0..) |n, j| {
        pp.notes[j] = sanitizeNote(n);
    }
}

/// `fx_order` needs more than a per-field enum check: `std.json` guarantees
/// every entry is a *legal* `FxUnitKind`, but not that all kinds are
/// present exactly once (a hand-edited file could duplicate one kind and
/// drop another, silently dropping the missing unit from processing).
/// `order.len == FxUnitKind`'s variant count, so "every kind appears at
/// least once" already implies no duplicates (pigeonhole).
fn isValidFxOrder(order: [14]synth_mod.FxUnitKind) bool {
    var seen = [_]bool{false} ** 14;
    for (order) |kind| seen[@intFromEnum(kind)] = true;
    for (seen) |s| if (!s) return false;
    return true;
}

/// Apply a synth snapshot onto a live PolySynth, clamping every numeric
/// field to the same ranges `adjustParam` enforces - mirrors
/// `applyPadSnap`'s reasoning: a hand-edited or corrupted file could
/// otherwise smuggle an out-of-range value (e.g. unison 0 or 255, a
/// negative attack time) straight onto the audio thread. Enum fields
/// (waveform, filter_type, mod_mode, …) need no clamp - `std.json` already
/// rejects any value that isn't one of the declared tags at parse time.
fn applyToSynth(s: *PolySynth, ss: *const SynthSnap) void {
    const clamp = std.math.clamp;
    // Every plain param_specs field (id->field->range, shared with the live
    // h/l-nudge and automation paths) - see PolySynth.applyParamSpecs. What's
    // left below is what param_specs deliberately excludes: the mod matrix
    // (fixed array vs. optional slice, plus pre-v17 legacy migration) and
    // fx_order (needs isValidFxOrder validation, not a plain clamp).
    s.applyParamSpecs(ss);
    if (ss.mod_matrix) |rows| {
        // v17 file: take the rows as saved (clamped; a bad dest falls back
        // to cutoff inside setParamAbsolute's rules - mirror them here).
        for (0..PolySynth.max_mod_rows) |k| {
            if (k < rows.len) {
                var row = rows[k];
                row.depth = clamp(row.depth, -1.0, 1.0);
                if (PolySynth.modDestIndex(row.dest) == null) row.dest = 21;
                s.mod_matrix[k] = row;
            } else {
                s.mod_matrix[k] = .{};
            }
        }
    } else {
        // Pre-v17 file: fold the legacy fixed routes into matrix rows.
        const rows = PolySynth.legacyModRows(
            clamp(ss.fenv_amount, -4.0, 4.0),
            clamp(ss.lfo_depth, 0.0, 1.0),
            ss.lfo_target,
        );
        s.mod_matrix = [_]PolySynth.ModRow{.{}} ** PolySynth.max_mod_rows;
        s.mod_matrix[0] = rows[0];
        s.mod_matrix[1] = rows[1];
    }
    // fx_order needs isValidFxOrder validation (a hand-edited file could
    // repeat or drop a unit kind), not a plain per-field clamp.
    s.fx_order = if (isValidFxOrder(ss.fx_order)) ss.fx_order else synth_mod.default_fx_order;
    applyLfoCustomSnap(&s.lfo_custom[0], &s.lfo_custom_count[0], ss.lfo_custom);
    applyLfoCustomSnap(&s.lfo_custom[1], &s.lfo_custom_count[1], ss.lfo2_custom);
    applyLfoCustomSnap(&s.lfo_custom[2], &s.lfo_custom_count[2], ss.lfo3_custom);
}

/// One `.custom` LFO slot's points from a snap onto the live fixed array +
/// count, clamped to the same phase/value ranges `setParamAbsolute` enforces
/// per-point. `null`/empty/over-capacity all collapse to "however many
/// points fit, in file order" - a hand-edited file overrunning
/// `max_lfo_shape_points` just gets truncated rather than rejected, same
/// spirit as `mod_matrix`'s row cap above.
fn applyLfoCustomSnap(dst_points: *[synth_mod.max_lfo_shape_points]synth_mod.LfoShapePoint, dst_count: *u8, src: ?[]const synth_mod.LfoShapePoint) void {
    const pts = src orelse &.{};
    const n = @min(pts.len, synth_mod.max_lfo_shape_points);
    for (pts[0..n], dst_points[0..n]) |p, *d| {
        d.* = .{
            .phase = std.math.clamp(p.phase, 0.0, 1.0),
            .value = std.math.clamp(p.value, -1.0, 1.0),
        };
    }
    dst_count.* = @intCast(n);
}

// zig fmt: off
/// Rebuild a live chain from v10 unit snaps, in file order. Shared by track
/// racks and the master bus - both hold a user-built `Fx` chain. Snaps past
/// the chain cap are dropped (only reachable by hand-editing the file).
/// A unit whose params field is null keeps its defaults.
fn applyFxChain(
    allocator: std.mem.Allocator,
    fx_out: *Fx,
    chain: []const FxUnitSnap,
    sr: u32,
    transport: ?*const Transport,
) !void {
    for (chain) |us| {
        if (fx_out.units.items.len >= Fx.max_units) break;
        const unit = switch (us.kind) {
            .clap => blk: {
                const cs = us.clap orelse return error.MalformedProject;
                const loaded = try fx_out.insertClap(allocator, fx_out.units.items.len, cs.path, cs.plugin_id, sr);
                if (transport) |value| loaded.payload.clap.attachTransport(value);
                try loadClapState(allocator, loaded.payload.clap, cs.state_base64);
                break :blk loaded;
            },
            else => |saved_kind| blk: {
                const kind: rack_mod.FxKind = switch (saved_kind) {
                    .gate => .gate, .comp => .comp, .mb_comp => .mb_comp, .ott => .ott,
                    .eq => .eq, .sat => .sat, .crush => .crush, .chorus => .chorus,
                    .phaser => .phaser, .flanger => .flanger, .tape => .tape,
                    .freq_shift => .freq_shift, .delay => .delay, .reverb => .reverb,
                    .clap => unreachable,
                };
                break :blk try fx_out.insert(allocator, fx_out.units.items.len, kind, sr);
            },
        };
        unit.bypassed = us.bypassed;
        switch (unit.payload) {
            .comp => |*c| if (us.comp) |cs| {
                if (std.math.isFinite(cs.threshold_db)) c.threshold_db = cs.threshold_db;
                if (std.math.isFinite(cs.ratio)) c.ratio = cs.ratio;
                if (std.math.isFinite(cs.attack_ms)) c.attack_ms = cs.attack_ms;
                if (std.math.isFinite(cs.release_ms)) c.release_ms = cs.release_ms;
                if (std.math.isFinite(cs.makeup_db)) c.makeup_db = cs.makeup_db;
                c.sidechain_source = if (cs.sidechain_source) |src| .{
                    .track = @min(src, engine_mod.max_tracks - 1),
                    .pad = if (cs.sidechain_pad) |p| @min(p, DrumMachine.max_pads - 1) else null,
                } else null;
            },
            .mb_comp => |*m| if (us.mb_comp) |ms| {
                m.setXovers(ms.xover_lo_hz, ms.xover_hi_hz);
                if (std.math.isFinite(ms.attack_ms)) m.attack_ms = ms.attack_ms;
                if (std.math.isFinite(ms.release_ms)) m.release_ms = ms.release_ms;
                m.style = if (ms.ott) .ott else .classic;
                if (std.math.isFinite(ms.mix)) m.mix = ms.mix;
                const saved_bands = [_][3]f32{
                    .{ ms.low_threshold_db, ms.low_ratio, ms.low_makeup_db },
                    .{ ms.mid_threshold_db, ms.mid_ratio, ms.mid_makeup_db },
                    .{ ms.high_threshold_db, ms.high_ratio, ms.high_makeup_db },
                };
                for (&m.bands, saved_bands) |*band, saved| {
                    if (std.math.isFinite(saved[0])) band.threshold_db = saved[0];
                    if (std.math.isFinite(saved[1])) band.ratio = saved[1];
                    if (std.math.isFinite(saved[2])) band.makeup_db = saved[2];
                }
            },
            .ott => |*o| if (us.ott) |os| {
                o.setDepth(os.depth);
                o.setTime(os.time);
                o.gain_in_db = finiteClamp(f32, os.gain_in_db, -24.0, 24.0, o.gain_in_db);
                o.gain_out_db = finiteClamp(f32, os.gain_out_db, -24.0, 24.0, o.gain_out_db);
            },
            .delay => |*d| if (us.delay) |ds| {
                d.setTime(ds.time_s);
                if (std.math.isFinite(ds.feedback)) d.feedback = ds.feedback;
                if (std.math.isFinite(ds.mix)) d.mix = ds.mix;
            },
            .reverb => |*r| if (us.reverb) |rs| applySnapToDevice(r, rs),
            .eq => |*e| if (us.eq) |es| {
                const bands = es.bands orelse
                    migrateEqBands(es.band_gains orelse [_]f32{0.0} ** legacy_eq_band_count);
                for (bands, 0..) |b, i| {
                    e.setFreq(i, b.freq);
                    e.setQ(i, b.q);
                    e.setGain(i, b.gain_db);
                    e.setType(i, switch (b.kind) {
                        .peak => .peak, .lowpass => .lowpass, .highpass => .highpass,
                    }, b.slope);
                }
                // Legacy EQ-only bypass maps onto the slot's generic one.
                if (es.bypass) unit.bypassed = true;
            },
            .gate => |*g| if (us.gate) |gs| applySnapToDevice(g, gs),
            .sat => |*s| if (us.sat) |ss| applySnapToDevice(s, ss),
            .crush => |*c| if (us.crush) |cs| applySnapToDevice(c, cs),
            .chorus => |*c| if (us.chorus) |cs| applySnapToDevice(c, cs),
            .phaser => |*p| if (us.phaser) |ps| applySnapToDevice(p, ps),
            .flanger => |*fl| if (us.flanger) |fs| applySnapToDevice(fl, fs),
            .tape => |*t| if (us.tape) |ts| applySnapToDevice(t, ts),
            .freq_shift => |*f| if (us.freq_shift) |fs| applySnapToDevice(f, fs),
            .clap => {},
        }
    }
}

/// v9-and-older fallback: expand the fixed struct-of-optionals rack into
/// unit snaps in the order the old `Fx.chain()` hard-wired, then load them
/// through the same path as v10 chains.
fn applyLegacyFx(allocator: std.mem.Allocator, fx_out: *Fx, fx: FxSnap, sr: u32, transport: ?*const Transport) !void {
    var snaps: [Fx.max_units]FxUnitSnap = undefined;
    var n: usize = 0;
    if (fx.gate)   |gs| { snaps[n] = .{ .kind = .gate, .gate = gs };       n += 1; }
    if (fx.comp)   |cs| { snaps[n] = .{ .kind = .comp, .comp = cs };       n += 1; }
    if (fx.eq)     |es| { snaps[n] = .{ .kind = .eq, .eq = es };           n += 1; }
    if (fx.sat)    |ss| { snaps[n] = .{ .kind = .sat, .sat = ss };         n += 1; }
    if (fx.crush)  |cs| { snaps[n] = .{ .kind = .crush, .crush = cs };     n += 1; }
    if (fx.chorus) |cs| { snaps[n] = .{ .kind = .chorus, .chorus = cs };   n += 1; }
    if (fx.phaser) |ps| { snaps[n] = .{ .kind = .phaser, .phaser = ps };   n += 1; }
    if (fx.delay)  |ds| { snaps[n] = .{ .kind = .delay, .delay = ds };     n += 1; }
    if (fx.reverb) |rs| { snaps[n] = .{ .kind = .reverb, .reverb = rs };   n += 1; }
    try applyFxChain(allocator, fx_out, snaps[0..n], sr, transport);
}
// zig fmt: on

// ---------------------------------------------------------------------------
// Tests - in-memory round-trip (no file I/O; std.Io not needed)
// ---------------------------------------------------------------------------

test "snapshot types: JSON round-trip preserves synth params, notes, drum pattern, tempo" {
    const testing = std.testing;
    const aa = testing.allocator;

    const drum_pattern: [DrumMachine.max_pads]u64 = blk: {
        var p = [_]u64{0} ** DrumMachine.max_pads;
        p[0] = 1 << 5;
        break :blk p;
    };

    const snap_in: Snapshot = .{
        .tempo_bpm = 140.0,
        .sample_rate = 48_000,
        .tracks = &.{
            .{ .name = "lead", .gain_db = -2.5 },
            .{ .name = "drums" },
        },
        .racks = &.{
            .{
                .label = "supersaw",
                .kind = .poly_synth,
                .synth = .{
                    .gain = 0.77,
                    .filter_cutoff = 3_000.0,
                    .voice_mode = .mono,
                    .notes = &.{
                        .{ .pitch = 69, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 0.9 },
                    },
                    .length_beats = 8.0,
                },
            },
            .{
                .label = "drums",
                .kind = .drum_machine,
                .drum = .{ .step_count = 16, .pattern = &drum_pattern },
            },
        },
    };

    const json = try std.json.Stringify.valueAlloc(aa, snap_in, .{ .whitespace = .indent_2 });
    defer aa.free(json);

    var parsed = try std.json.parseFromSlice(Snapshot, aa, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const snap_out = &parsed.value;

    try testing.expectApproxEqAbs(@as(f64, 140.0), snap_out.tempo_bpm, 0.001);
    try testing.expectEqual(@as(usize, 2), snap_out.tracks.len);
    try testing.expectEqualStrings("lead", snap_out.tracks[0].name);
    try testing.expectApproxEqAbs(@as(f32, -2.5), snap_out.tracks[0].gain_db, 1e-4);

    const sr = snap_out.racks[0].synth.?;
    try testing.expectApproxEqAbs(@as(f32, 0.77), sr.gain, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3_000.0), sr.filter_cutoff, 1.0);
    try testing.expectEqual(synth_mod.VoiceMode.mono, sr.voice_mode);
    try testing.expectEqual(@as(usize, 1), sr.notes.len);
    try testing.expectEqual(@as(u8, 69), sr.notes[0].pitch);
    try testing.expectApproxEqAbs(@as(f64, 8.0), sr.length_beats, 1e-9);
    try testing.expectEqualStrings("supersaw", snap_out.racks[0].label);

    const dr = snap_out.racks[1].drum.?;
    try testing.expectEqual(@as(u16, 16), dr.step_count);
    try testing.expectEqual(@as(u64, 1 << 5), dr.pattern[0]);
    try testing.expectEqual(@as(u64, 0), dr.pattern[1]);
}

test "buildSession: constructs valid Session from snapshot" {
    const testing = std.testing;

    const drum_pattern: [DrumMachine.max_pads]u64 = blk: {
        var p = [_]u64{0} ** DrumMachine.max_pads;
        p[0] = 1 << 5;
        break :blk p;
    };
    var pads_snap = [_]PadSnap{.{}} ** DrumMachine.max_pads;
    pads_snap[0] = .{ .used = true, .pitch_semitones = 7.0, .reverse = true, .end_norm = 0.5 };

    const snap: Snapshot = .{
        .version = 22,
        .tempo_bpm = 140.0,
        .sample_rate = 48_000,
        .tracks = &.{
            .{ .name = "lead" },
            .{ .name = "drums" },
        },
        .racks = &.{
            .{
                .label = "supersaw+comp",
                .kind = .poly_synth,
                .synth = .{
                    .gain = 0.77,
                    .filter_cutoff = 3_000.0,
                    .voice_mode = .mono,
                    .notes = &.{
                        .{ .pitch = 69, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 0.9 },
                    },
                    .length_beats = 8.0,
                },
                .fx = .{ .comp = .{ .threshold_db = -24.0, .ratio = 6.0, .attack_ms = 5.0, .release_ms = 60.0, .makeup_db = 3.0 } },
            },
            .{
                .label = "drums",
                .kind = .drum_machine,
                .drum = .{
                    .step_count = 16,
                    .pattern = &drum_pattern,
                    .pads = &pads_snap,
                },
            },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectApproxEqAbs(@as(f64, 140.0), session.project.tempo_bpm, 0.001);
    try testing.expectEqual(@as(usize, 2), session.project.tracks.items.len);
    try testing.expectEqual(@as(usize, 2), session.racks.items.len);

    try testing.expectEqualStrings("supersaw+comp", session.racks.items[0].label);
    try testing.expect(session.racks.items[0].owned_label);

    const s = &session.racks.items[0].instrument.poly_synth;
    try testing.expectApproxEqAbs(@as(f32, 0.77), s.gain, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3_000.0), s.filter_cutoff, 1.0);
    try testing.expectEqual(synth_mod.VoiceMode.mono, s.voice_mode);

    const pp = &session.racks.items[0].pattern_player.?;
    try testing.expectEqual(@as(u16, 1), pp.note_count);
    try testing.expectEqual(@as(u7, 69), pp.notes[0].pitch);
    try testing.expectApproxEqAbs(@as(f64, 8.0), pp.length_beats, 1e-9);

    // Legacy v9 `fx` field: loads as a one-unit chain.
    const comp = &session.racks.items[0].fx.find(.comp).?.payload.comp;
    try testing.expectApproxEqAbs(@as(f32, -24.0), comp.threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6.0), comp.ratio, 1e-4);

    const dm = &session.racks.items[1].instrument.drum_machine;
    try testing.expect(dm.stepActive(0, 5));
    try testing.expect(!dm.stepActive(0, 0));
    try testing.expectApproxEqAbs(@as(f32, 7.0), dm.pads[0].?.pad.pitch_semitones, 1e-4);
    try testing.expect(dm.pads[0].?.pad.reverse);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dm.pads[0].?.pad.end_norm, 1e-4);
}

test "buildSession: legacy master FX loads in the old fixed order" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "lead" }},
        .racks = &.{.{ .label = "lead", .kind = .empty }},
        .master_fx = .{
            .comp = .{ .threshold_db = -12.0, .ratio = 3.0, .attack_ms = 5.0, .release_ms = 60.0, .makeup_db = 1.5 },
            .eq = .{ .band_gains = [_]f32{2.0} ** legacy_eq_band_count, .bypass = false },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    // The v9 rack hard-wired comp before eq - the rebuilt chain keeps that.
    try testing.expectEqual(@as(usize, 2), session.master_fx.units.items.len);
    const comp = &session.master_fx.units.items[0].payload.comp;
    try testing.expectApproxEqAbs(@as(f32, -12.0), comp.threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3.0), comp.ratio, 1e-4);
    const eq = &session.master_fx.units.items[1].payload.eq;
    try testing.expectApproxEqAbs(@as(f32, 2.0), eq.bands[0].gain_db, 1e-4);
    // Both units should have reached the engine's master chain.
    try testing.expectEqual(@as(usize, 2), session.engine.master_chain.slice().len);
}

test "buildSession: v10 fx_chain keeps user order, duplicates, and bypass" {
    const testing = std.testing;

    // Reverb *before* the comp (impossible in the old rack), two saturators,
    // and a bypassed crusher in the middle.
    const snap: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "lead" }},
        .racks = &.{.{ .label = "lead", .kind = .empty }},
        .master_fx_chain = &.{
            .{ .kind = .reverb, .reverb = .{ .mix = 0.6, .room = 0.9, .damp = 0.1 } },
            .{ .kind = .sat, .sat = .{ .drive_db = 6.0, .out_db = 0.0, .mix = 1.0 } },
            .{ .kind = .crush, .bypassed = true },
            .{ .kind = .sat, .sat = .{ .drive_db = 24.0, .out_db = -3.0, .mix = 0.5 } },
            .{ .kind = .comp },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const units = session.master_fx.units.items;
    try testing.expectEqual(@as(usize, 5), units.len);
    try testing.expectApproxEqAbs(@as(f32, 0.6), units[0].payload.reverb.mix, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6.0), units[1].payload.sat.drive_db, 1e-4);
    try testing.expect(units[2].bypassed);
    try testing.expectApproxEqAbs(@as(f32, 24.0), units[3].payload.sat.drive_db, 1e-4);
    // Missing params field (.comp) loads with defaults.
    try testing.expectApproxEqAbs(@as(f32, -18.0), units[4].payload.comp.threshold_db, 1e-4);
    // The bypassed crusher is skipped by chain(): 4 of 5 reach the engine.
    try testing.expectEqual(@as(usize, 4), session.engine.master_chain.slice().len);
}

// zig fmt: off
test "buildSession: a compressor's sidechain_source loads, clamps, and reaches the engine's routing" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "bass" }},
        .racks = &.{.{
            .label = "bass", .kind = .empty,
            .fx_chain = &.{
                .{ .kind = .comp, .comp = .{ .sidechain_source = 3 } },
            },
        }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectEqual(@as(u16, 3), session.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?.track);
    try testing.expectEqual(@as(u16, 3), session.engine.track_sidechain[0][0].?.track); // no instrument -> comp is slot 0

    // A hand-edited out-of-range value clamps to the last valid track index.
    const snap2: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "bass" }},
        .racks = &.{.{
            .label = "bass", .kind = .empty,
            .fx_chain = &.{
                .{ .kind = .comp, .comp = .{ .sidechain_source = 65_000 } },
            },
        }},
    };
    var session2 = try buildSession(testing.allocator, &snap2);
    defer session2.deinit();
    try testing.expectEqual(@as(u16, engine_mod.max_tracks - 1), session2.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?.track);
}

test "buildSession: a compressor's sidechain_pad loads, clamps, and combines with sidechain_source" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .sample_rate = 48_000,
        .tracks = &.{.{ .name = "bass" }},
        .racks = &.{.{
            .label = "bass", .kind = .empty,
            .fx_chain = &.{
                .{ .kind = .comp, .comp = .{ .sidechain_source = 3, .sidechain_pad = 200 } },
            },
        }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    const sc = session.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?;
    try testing.expectEqual(@as(u16, 3), sc.track);
    // A hand-edited out-of-range pad clamps to the last valid pad index.
    try testing.expectEqual(@as(u8, DrumMachine.max_pads - 1), sc.pad.?);
}
// zig fmt: on

test "save/load round-trip persists a compressor's sidechain_source" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/sidechain.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const unit = try session.racks.items[0].fx.insert(testing.allocator, 0, .comp, session.project.sample_rate);
    unit.payload.comp.sidechain_source = .{ .track = 7, .pad = 2 };

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const sc = loaded.racks.items[0].fx.units.items[0].payload.comp.sidechain_source.?;
    try testing.expectEqual(@as(u16, 7), sc.track);
    try testing.expectEqual(@as(?u8, 2), sc.pad);
}

test "save/load round-trip persists a slicer's slices, pattern, and swing" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/slicer.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .slicer);
    {
        const sl = &session.racks.items[0].instrument.slicer;
        sl.sliceInto(4);
        sl.slices[2].gain = 1.5;
        sl.slices[2].pan = -0.3;
        sl.slices[2].reverse = true;
        sl.toggleStep(2, 5);
        sl.setStepVel(2, 5, 90);
        sl.setStepCount(24);
        sl.setSwing(65.0);
    }

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const sl = &loaded.racks.items[0].instrument.slicer;
    try testing.expectEqual(@as(u8, 4), sl.slice_count);
    try testing.expectApproxEqAbs(@as(f32, 1.5), sl.slices[2].gain, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -0.3), sl.slices[2].pan, 1e-4);
    try testing.expect(sl.slices[2].reverse);
    try testing.expectApproxEqAbs(@as(f32, 0.25), sl.slices[1].start_norm, 1e-4);
    try testing.expect(sl.stepActive(2, 5));
    try testing.expectEqual(@as(u8, 90), sl.stepVel(2, 5));
    try testing.expectEqual(@as(u8, 24), sl.step_count);
    try testing.expectApproxEqAbs(@as(f32, 65.0), sl.swing.load(.monotonic), 1e-4);
}

test "save/load round-trip persists a slicer's variant bank and choke groups" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/slvar.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .slicer);
    {
        const sl = &session.racks.items[0].instrument.slicer;
        sl.sliceInto(4);
        sl.toggleStep(0, 0); // variant A: slice 0 on step 0
        try testing.expect(sl.addVariant()); // B active, copy of A
        sl.toggleStep(0, 0); // B diverges: off
        sl.toggleStep(3, 7);
        sl.setStepVel(3, 7, 60);
        sl.choke_group[0] = 1;
        sl.choke_group[1] = 1;
    }

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const sl = &loaded.racks.items[0].instrument.slicer;
    try testing.expectEqual(@as(u8, 2), sl.variant_count);
    try testing.expectEqual(@as(u8, 1), sl.variant); // B was active at save
    try testing.expect(!sl.stepActive(0, 0));
    try testing.expect(sl.stepActive(3, 7));
    try testing.expectEqual(@as(u8, 60), sl.stepVel(3, 7));
    sl.selectVariant(0);
    try testing.expect(sl.stepActive(0, 0)); // A intact through the file
    try testing.expect(!sl.stepActive(3, 7));
    try testing.expectEqual(@as(u8, 1), sl.choke_group[0]);
    try testing.expectEqual(@as(u8, 1), sl.choke_group[1]);
    try testing.expectEqual(@as(u8, 0), sl.choke_group[2]);
}

test "save/load round-trip keeps a slicer lane's stamped clips playable in song mode" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/slsong.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .slicer);
    {
        const sl = &session.racks.items[0].instrument.slicer;
        sl.sliceInto(4);
        sl.toggleStep(2, 0);
    }
    try session.stampClip(0, 0);

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const lane = loaded.arrangement.lane(0).?;
    try testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try testing.expect(lane.clips.items[0].content == .drum);

    loaded.setSongMode(true);
    const sl = &loaded.racks.items[0].instrument.slicer;
    try testing.expect(sl.song_mode);
    try testing.expect(sl.song_clip_count == 1);
    try testing.expectEqual(@as(u64, 1), sl.song_clips[0].pattern[2]);
}

test "save/load round-trip restores a slicer's user-loaded sample audio" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/slicer2.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .slicer);
    const distinct_samples = [_]f32{ 0.25, 0.5, 0.75, 1.0, 0.5, 0.25 };
    {
        const sl = &session.racks.items[0].instrument.slicer;
        testing.allocator.free(sl.samples);
        const owned = try testing.allocator.dupe(f32, &distinct_samples);
        sl.samples = owned;
        for (&sl.slices) |*p| p.samples = owned;
        sl.user_sample = true;
        sl.sliceInto(2);
    }

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const sl = &loaded.racks.items[0].instrument.slicer;
    try testing.expectEqual(distinct_samples.len, sl.samples.len);
    for (distinct_samples, sl.samples) |a, b| try testing.expectApproxEqAbs(a, b, 1e-3);
    try testing.expectEqual(@as(u8, 2), sl.slice_count); // saved slicing survives the audio reload
}

test "save/load round-trip persists master FX" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sr = session.project.sample_rate;
    const alloc = testing.allocator;
    // Deliberately un-rack-like order: sat ahead of the gate, comp last.
    (try session.master_fx.insert(alloc, 0, .sat, sr)).payload.sat.drive_db = 18.0;
    (try session.master_fx.insert(alloc, 1, .gate, sr)).payload.gate.threshold_db = -42.0;
    const crush = try session.master_fx.insert(alloc, 2, .crush, sr);
    crush.payload.crush = .{ .bits = 6.0, .downsample = 8.0 };
    crush.bypassed = true;
    (try session.master_fx.insert(alloc, 3, .chorus, sr)).payload.chorus.rate_hz = 1.5;
    (try session.master_fx.insert(alloc, 4, .phaser, sr)).payload.phaser.feedback = 0.7;
    (try session.master_fx.insert(alloc, 5, .comp, sr)).payload.comp.threshold_db = -9.0;
    session.syncMasterChain();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const units = loaded.master_fx.units.items;
    try testing.expectEqual(@as(usize, 6), units.len);
    try testing.expectApproxEqAbs(@as(f32, 18.0), units[0].payload.sat.drive_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -42.0), units[1].payload.gate.threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6.0), units[2].payload.crush.bits, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 8.0), units[2].payload.crush.downsample, 1e-4);
    try testing.expect(units[2].bypassed);
    try testing.expectApproxEqAbs(@as(f32, 1.5), units[3].payload.chorus.rate_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.7), units[4].payload.phaser.feedback, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -9.0), units[5].payload.comp.threshold_db, 1e-4);
    // The bypassed crusher stays out of the live chain.
    try testing.expectEqual(@as(usize, 5), loaded.engine.master_chain.slice().len);
}

test "save/load round-trip persists a multiband compressor's crossover, style, and per-band params" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sr = session.project.sample_rate;
    const alloc = testing.allocator;

    const mb = try session.master_fx.insert(alloc, 0, .mb_comp, sr);
    // Both above the struct's just-inserted 200/2000 defaults, so a
    // load-order bug that clamps `lo` against a still-default `hi` (see
    // `setXovers`'s doc comment) would corrupt this round-trip.
    mb.payload.mb_comp.setXoverHi(8000.0);
    mb.payload.mb_comp.setXoverLo(2500.0);
    mb.payload.mb_comp.attack_ms = 3.0;
    mb.payload.mb_comp.release_ms = 120.0;
    mb.payload.mb_comp.style = .ott;
    mb.payload.mb_comp.mix = 0.75;
    mb.payload.mb_comp.bands[0] = .{ .threshold_db = -22.0, .ratio = 5.0, .makeup_db = 1.0 };
    mb.payload.mb_comp.bands[1] = .{ .threshold_db = -19.0, .ratio = 6.0, .makeup_db = 2.0 };
    mb.payload.mb_comp.bands[2] = .{ .threshold_db = -15.0, .ratio = 2.5, .makeup_db = 0.5 };
    session.syncMasterChain();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const units = loaded.master_fx.units.items;
    try testing.expectEqual(@as(usize, 1), units.len);
    const m = units[0].payload.mb_comp;
    try testing.expectApproxEqAbs(@as(f32, 2500.0), m.xover_lo_hz, 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 8000.0), m.xover_hi_hz, 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 3.0), m.attack_ms, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 120.0), m.release_ms, 1e-4);
    try testing.expectEqual(multiband_comp_mod.Style.ott, m.style);
    try testing.expectApproxEqAbs(@as(f32, 0.75), m.mix, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -22.0), m.bands[0].threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5.0), m.bands[0].ratio, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), m.bands[0].makeup_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -19.0), m.bands[1].threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6.0), m.bands[1].ratio, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -15.0), m.bands[2].threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2.5), m.bands[2].ratio, 1e-4);
    try testing.expectEqual(@as(usize, 1), loaded.engine.master_chain.slice().len);
}

test "save/load round-trip persists an OTT unit's depth/time/gains and rederives its attack/release" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sr = session.project.sample_rate;
    const alloc = testing.allocator;

    const unit = try session.master_fx.insert(alloc, 0, .ott, sr);
    unit.payload.ott.setDepth(0.6);
    unit.payload.ott.setTime(2.0);
    unit.payload.ott.gain_in_db = 3.0;
    unit.payload.ott.gain_out_db = -4.5;
    session.syncMasterChain();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const units = loaded.master_fx.units.items;
    try testing.expectEqual(@as(usize, 1), units.len);
    const o = units[0].payload.ott;
    try testing.expectApproxEqAbs(@as(f32, 0.6), o.depth(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2.0), o.time, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3.0), o.gain_in_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -4.5), o.gain_out_db, 1e-4);
    // Derived from `time` through setTime on load, not stored in the file.
    try testing.expectApproxEqAbs(unit.payload.ott.mb.attack_ms, o.mb.attack_ms, 1e-4);
    try testing.expectApproxEqAbs(unit.payload.ott.mb.release_ms, o.mb.release_ms, 1e-4);
    try testing.expectEqual(@as(usize, 1), loaded.engine.master_chain.slice().len);
}

test "save/load round-trip persists a frequency shifter's shift and mix" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const sr = session.project.sample_rate;
    const alloc = testing.allocator;

    const unit = try session.master_fx.insert(alloc, 0, .freq_shift, sr);
    unit.payload.freq_shift.shift_hz = -350.0;
    unit.payload.freq_shift.mix = 0.65;
    session.syncMasterChain();

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const units = loaded.master_fx.units.items;
    try testing.expectEqual(@as(usize, 1), units.len);
    const f = units[0].payload.freq_shift;
    try testing.expectApproxEqAbs(@as(f32, -350.0), f.shift_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.65), f.mix, 1e-4);
    try testing.expectEqual(@as(usize, 1), loaded.engine.master_chain.slice().len);
}

test "buildSession: arrangement clips and song_mode round-trip" {
    const testing = std.testing;

    const drum_pattern: [DrumMachine.max_pads]u64 = blk: {
        var p = [_]u64{0} ** DrumMachine.max_pads;
        p[0] = 1;
        break :blk p;
    };

    const snap: Snapshot = .{
        .tracks = &.{ .{ .name = "keys" }, .{ .name = "drums" } },
        .racks = &.{
            .{ .label = "synth", .kind = .poly_synth, .synth = .{} },
            .{ .label = "drums", .kind = .drum_machine, .drum = .{ .step_count = 16, .pattern = &drum_pattern } },
        },
        .song_mode = true,
        .arrangement = &.{
            .{ .clips = &.{
                .{ .start_bar = 2, .length_bars = 1, .kind = .melodic, .length_beats = 4.0, .notes = &.{
                    .{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.5, .velocity = 0.8 },
                } },
            } },
            .{ .clips = &.{
                .{ .start_bar = 0, .length_bars = 1, .kind = .drum, .step_count = 16, .drum_pattern = &drum_pattern },
            } },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expect(session.song_mode);

    // Melodic clip restored on lane 0.
    const lane0 = session.arrangement.lane(0).?;
    try testing.expectEqual(@as(usize, 1), lane0.clips.items.len);
    const c0 = lane0.clips.items[0];
    try testing.expectEqual(@as(u32, 256), c0.start_tick);
    try testing.expectEqual(@as(usize, 1), c0.content.melodic.notes.len);
    try testing.expectEqual(@as(u7, 64), c0.content.melodic.notes[0].pitch);

    // Drum clip restored on lane 1.
    const lane1 = session.arrangement.lane(1).?;
    try testing.expectEqual(@as(usize, 1), lane1.clips.items.len);
    try testing.expectEqual(@as(u64, 1), lane1.clips.items[0].content.drum.pattern[0]);

    // song_mode = true means the devices were handed their song buffers.
    try testing.expect(session.racks.items[0].pattern_player.?.song_mode);
    try testing.expectEqual(@as(u16, 1), session.racks.items[0].pattern_player.?.song_note_count);
    try testing.expect(session.racks.items[1].instrument.drum_machine.song_mode);
    try testing.expectEqual(@as(u16, 1), session.racks.items[1].instrument.drum_machine.song_clip_count);
}

// zig fmt: off
test "clipToSnap/clipFromSnap round-trip gain/pan automation" {
    const testing = std.testing;
    var clip = ws_arrangement.Clip.initDrum(0, 1, .{
        .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16,
    });
    try automation_mod.setPoint(testing.allocator, &clip.automation.gain, 0.0, -6.0);
    try automation_mod.setPoint(testing.allocator, &clip.automation.gain, 2.0, 0.0);
    try automation_mod.setPoint(testing.allocator, &clip.automation.pan, 0.0, -1.0);
    defer clip.deinit(testing.allocator);
    // zig fmt: on

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const snap = try clipToSnap(arena.allocator(), clip);
    try testing.expectEqual(@as(usize, 2), snap.gain_automation.len);
    try testing.expectApproxEqAbs(@as(f32, -6.0), snap.gain_automation[0].value, 1e-6);
    try testing.expectEqual(@as(usize, 1), snap.pan_automation.len);

    var restored = try clipFromSnap(testing.allocator, snap, 4, file_version);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.automation.gain.len);
    try testing.expectApproxEqAbs(@as(f64, 0.0), restored.automation.gain[0].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, -6.0), restored.automation.gain[0].value, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), restored.automation.gain[1].value, 1e-6);
    try testing.expectEqual(@as(usize, 1), restored.automation.pan.len);
    try testing.expectApproxEqAbs(@as(f32, -1.0), restored.automation.pan[0].value, 1e-6);
}

test "automationFromSnap sorts unsorted points and clamps out-of-range values" {
    const testing = std.testing;
    const snaps = [_]AutomationPointSnap{
        .{ .beat = 3.0, .value = 100.0 }, // out of gain range - clamps to 12
        .{ .beat = 1.0, .value = -999.0 }, // clamps to -60
    };
    const pts = try automationFromSnap(testing.allocator, &snaps, -60.0, 12.0);
    defer testing.allocator.free(pts);
    try testing.expectEqual(@as(usize, 2), pts.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), pts[0].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, -60.0), pts[0].value, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 3.0), pts[1].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 12.0), pts[1].value, 1e-6);
}

test "load sanitizes non-finite project, automation, pad, and note fields" {
    const testing = std.testing;
    const nan32 = std.math.nan(f32);
    const nan64 = std.math.nan(f64);

    const snap: Snapshot = .{
        .tempo_bpm = nan64,
        .tracks = &.{.{ .name = "bad", .gain_db = nan32, .pan = nan32 }},
        .racks = &.{.{ .label = "empty", .kind = .empty }},
        .groups = &.{.{ .active = true, .name = "bad", .gain_db = nan32 }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectEqual(@as(f64, 120.0), session.project.tempo_bpm);
    try testing.expectEqual(@as(f32, 0.0), session.project.tracks.items[0].gain_db);
    try testing.expectEqual(@as(f32, 0.0), session.project.tracks.items[0].pan);
    try testing.expectEqual(@as(f32, 0.0), session.groups[0].?.gain_db);

    const points = try automationFromSnap(testing.allocator, &.{.{ .beat = nan64, .value = nan32 }}, -1.0, 1.0);
    defer testing.allocator.free(points);
    try testing.expectEqual(@as(f64, 0.0), points[0].beat);
    try testing.expectEqual(@as(f32, 0.0), points[0].value);

    var pad: Pad = .{ .samples = &.{} };
    applyPadSnap(&pad, .{
        .gain = nan32,
        .pan = nan32,
        .pitch_semitones = nan32,
        .start_norm = nan32,
        .end_norm = nan32,
        .attack_s = nan32,
        .decay_s = nan32,
        .sustain = nan32,
        .release_s = nan32,
    });
    try testing.expectEqual(@as(f32, 1.0), pad.gain);
    try testing.expectEqual(@as(f32, 0.0), pad.pan);
    try testing.expectEqual(@as(f32, 0.0), pad.pitch_semitones);
    try testing.expectEqual(@as(f32, 0.0), pad.start_norm);
    try testing.expectEqual(@as(f32, 1.0), pad.end_norm);
    try testing.expectEqual(@as(f32, 0.001), pad.attack_s);
    try testing.expectEqual(@as(f32, 0.0), pad.decay_s);
    try testing.expectEqual(@as(f32, 1.0), pad.sustain);
    try testing.expectEqual(@as(f32, 0.005), pad.release_s);

    const note = sanitizeNote(.{ .pitch = 60, .start_beat = nan64, .duration_beat = nan64, .velocity = nan32 });
    try testing.expectEqual(@as(f64, 0.0), note.start_beat);
    try testing.expectEqual(@as(f64, 0.0), note.duration_beat);
    try testing.expectEqual(pattern_mod.default_velocity, note.velocity);
}

test "clip load clamps invalid loop, step, and velocity values" {
    const testing = std.testing;
    var melodic = try clipFromSnap(testing.allocator, .{
        .start_bar = 0,
        .length_bars = 1,
        .length_beats = std.math.nan(f64),
    }, 4, file_version);
    defer melodic.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 1.0), melodic.content.melodic.length_beats);

    var drum = try clipFromSnap(testing.allocator, .{
        .start_bar = 0,
        .length_bars = 1,
        .kind = .drum,
        .step_count = 0,
        .drum_vel = &.{&.{255}},
    }, 4, file_version);
    defer drum.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), drum.content.drum.step_count);
    try testing.expectEqual(DrumMachine.vel_full, drum.content.drum.vel[0][0]);
}

// zig fmt: off
test "buildSession: clip automation round-trips (legacy filter_cutoff_automation remaps to param_id 21)" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "keys" }},
        .racks = &.{.{ .label = "synth", .kind = .poly_synth, .synth = .{} }},
        .arrangement = &.{
            .{ .clips = &.{
                .{
                    .start_bar = 0, .length_bars = 1, .kind = .melodic, .length_beats = 4.0,
                    .gain_automation = &.{.{ .beat = 0.0, .value = -6.0 }},
                    .pan_automation = &.{.{ .beat = 0.0, .value = 0.5 }},
                    .filter_cutoff_automation = &.{.{ .beat = 0.0, .value = 2_500.0 }},
                },
            } },
        },
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    const clip = session.arrangement.lane(0).?.clips.items[0];
    try testing.expectEqual(@as(usize, 1), clip.automation.gain.len);
    try testing.expectApproxEqAbs(@as(f32, -6.0), clip.automation.gain[0].value, 1e-6);
    try testing.expectEqual(@as(usize, 1), clip.automation.pan.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), clip.automation.pan[0].value, 1e-6);
    const cutoff = clip.automation.findSynthParam(21).?;
    try testing.expectEqual(@as(usize, 1), cutoff.len);
    try testing.expectApproxEqAbs(@as(f32, 2_500.0), cutoff[0].value, 1e-6);
}

test "buildSession: filter cutoff automation clamps an out-of-range hand-edited value" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "keys" }},
        .racks = &.{.{ .label = "synth", .kind = .poly_synth, .synth = .{} }},
        .arrangement = &.{
            .{ .clips = &.{
                .{
                    .start_bar = 0, .length_bars = 1, .kind = .melodic, .length_beats = 4.0,
                    .filter_cutoff_automation = &.{.{ .beat = 0.0, .value = 99_999.0 }},
                },
            } },
        },
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    const clip = session.arrangement.lane(0).?.clips.items[0];
    try testing.expectApproxEqAbs(@as(f32, 20_000.0), clip.automation.findSynthParam(21).?[0].value, 1e-6);
}
// zig fmt: on

test "buildSession: drum variant bank round-trips; v2 files get one variant" {
    const testing = std.testing;

    // zig fmt: off
    // v3: two variants, B active, with stray bits above each step count that
    // the loader must mask off.
    const variants = [_]VariantSnap{
        .{ .step_count = 16, .pattern = blk: {
            var p = [_]u64{0} ** DrumMachine.max_pads;
            p[0] = 1 | (1 << 20); // bit 20 is past 16 steps - stray
            break :blk &p;
        } },
        .{ .step_count = 32, .pattern = blk: {
            var p = [_]u64{0} ** DrumMachine.max_pads;
            p[1] = 1 << 31;
            break :blk &p;
        } },
    };
    const snap: Snapshot = .{
        .version = 22,
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .variants = &variants, .variant = 1 },
        }},
    };
    // zig fmt: on

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 2), dm.variant_count);
    try testing.expectEqual(@as(u8, 1), dm.variant);
    try testing.expectEqual(@as(u16, 32), dm.step_count);
    try testing.expect(dm.stepActive(1, 31)); // live = variant B
    dm.selectVariant(0);
    try testing.expectEqual(@as(u16, 16), dm.step_count);
    try testing.expect(dm.stepActive(0, 0));
    try testing.expect(!dm.stepActive(0, 20)); // stray bit was masked

    // v2 file shape: no `variants` - a single variant from the legacy fields.
    const legacy: Snapshot = .{
        .version = 22,
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .step_count = 16, .pattern = blk: {
                var p = [_]u64{0} ** DrumMachine.max_pads;
                p[0] = 1 << 5;
                break :blk &p;
            } },
        }},
    };
    var old = try buildSession(testing.allocator, &legacy);
    defer old.deinit();
    const odm = &old.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 1), odm.variant_count);
    try testing.expect(odm.stepActive(0, 5));
}

test "buildSession: time signature lands in project and transport" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .beats_per_bar = 3,
        .tracks = &.{.{ .name = "t" }},
        .racks = &.{.{ .label = "t", .kind = .empty }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectEqual(@as(u8, 3), session.project.beats_per_bar);
    try testing.expectEqual(@as(u8, 3), session.engine.transport.time_signature.beats_per_bar);
}

test "buildSession: pre-v12 vel_lo/vel_hi bitplanes migrate onto the new 0-127 scale" {
    const testing = std.testing;

    const variants = [_]VariantSnap{.{
        .step_count = 16,
        .pattern = blk: {
            var p = [_]u64{0} ** DrumMachine.max_pads;
            p[0] = 0b11;
            break :blk &p;
        },
        // Step 1 at legacy level 3 (25%); a stray plane bit above the step count.
        .vel_lo = blk: {
            var p = [_]u64{0} ** DrumMachine.max_pads;
            p[0] = (1 << 1) | (1 << 20);
            break :blk &p;
        },
        .vel_hi = blk: {
            var p = [_]u64{0} ** DrumMachine.max_pads;
            p[0] = 1 << 1;
            break :blk &p;
        },
    }};
    const snap: Snapshot = .{
        .version = 22,
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .variants = &variants, .swing = 62.0 },
        }},
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 127), dm.stepVel(0, 0));
    try testing.expectEqual(@as(u8, 31), dm.stepVel(0, 1));
    try testing.expectEqual(@as(u8, 127), dm.stepVel(0, 20)); // stray bit masked
    try testing.expectApproxEqAbs(@as(f32, 62.0), dm.swing.load(.monotonic), 1e-6);

    // And back out through save-shaped snapshots.
    const v = dm.variantData(0);
    try testing.expectEqual(@as(u8, 31), v.midi[0][1].?.velocity);
}

test "buildSession: v12 vel field round-trips a granular 0-127 value" {
    const testing = std.testing;

    var vel_row = [_]u8{DrumMachine.vel_full} ** 64;
    vel_row[1] = 64;
    const vel_rows = [_][]const u8{&vel_row};
    const variants = [_]VariantSnap{.{
        .step_count = 16,
        .pattern = blk: {
            var p = [_]u64{0} ** DrumMachine.max_pads;
            p[0] = 0b11;
            break :blk &p;
        },
        .vel = &vel_rows,
    }};
    const snap: Snapshot = .{
        .version = 22,
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .variants = &variants },
        }},
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 127), dm.stepVel(0, 0));
    try testing.expectEqual(@as(u8, 64), dm.stepVel(0, 1));
}

test "buildSession: a 64-step pattern round-trips bit 63 without truncation" {
    const testing = std.testing;
    const variants = [_]VariantSnap{.{
        .step_count = 64,
        .pattern = blk: {
            var p = [_]u64{0} ** DrumMachine.max_pads;
            p[0] = @as(u64, 1) << 63;
            break :blk &p;
        },
    }};
    const snap: Snapshot = .{
        .version = 22,
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .variants = &variants, .variant = 0 },
        }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u16, 64), dm.step_count);
    try testing.expect(dm.stepActive(0, 63));
}

test "buildSession: groups round-trip name, FX chain, and track membership" {
    const testing = std.testing;

    var groups: [engine_mod.max_groups]GroupSnap = [_]GroupSnap{.{}} ** engine_mod.max_groups;
    groups[2] = .{
        .active = true,
        .name = "drum bus",
        .fx_chain = &.{.{ .kind = .comp, .comp = .{ .threshold_db = -12.0 } }},
        .gain_db = -6.0206, // linear 0.5
        .folded = true,
    };
    const snap: Snapshot = .{
        .tracks = &.{
            .{ .name = "kick", .group = 2 },
            .{ .name = "lead" }, // ungrouped
        },
        .racks = &.{
            .{ .label = "kick", .kind = .empty },
            .{ .label = "lead", .kind = .empty },
        },
        .groups = &groups,
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectEqualStrings("drum bus", session.groups[2].?.name);
    try testing.expectEqual(@as(usize, 1), session.groups[2].?.fx.units.items.len);
    try testing.expect(session.engine.groups[2].active);
    try testing.expectEqual(@as(usize, 1), session.engine.groups[2].chain.slice().len);

    try testing.expectEqual(@as(?u8, 2), session.project.tracks.items[0].group);
    try testing.expectEqual(@as(?u8, null), session.project.tracks.items[1].group);
    try testing.expectEqual(@as(?u8, 2), session.engine.trackAt(0).*.group);

    // Unused slots (0, 1, 3..) stay unloaded - no phantom groups.
    try testing.expect(session.groups[0] == null);
    try testing.expect(!session.engine.groups[0].active);

    // Tracks-view fold state survives the trip (UI-only, engine never sees it).
    try testing.expect(session.groups[2].?.folded);

    // The bus fader restores too. Engine-side it travels as a queued
    // command (same as track gain), so drain one block first.
    try testing.expectApproxEqAbs(@as(f32, -6.0206), session.groups[2].?.gain_db, 1e-4);
    var block: [256]f32 = undefined;
    session.engine.process(&block);
    try testing.expectApproxEqAbs(@as(f32, 0.5), session.engine.groups[2].gain, 1e-4);
}

test "buildSession: a track referencing a slot the file never marked active loads ungrouped" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "t", .group = 5 }}, // groups is empty - slot 5 was never active
        .racks = &.{.{ .label = "t", .kind = .empty }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expectEqual(@as(?u8, null), session.project.tracks.items[0].group);
}

test "choke groups round-trip through DrumSnap; older files load ungrouped" {
    const testing = std.testing;

    var groups = [_]u8{0} ** DrumMachine.max_pads;
    groups[2] = 1;
    groups[3] = 1;
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .choke_group = &groups },
        }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 1), dm.choke_group[2]);
    try testing.expectEqual(@as(u8, 1), dm.choke_group[3]);
    try testing.expectEqual(@as(u8, 0), dm.choke_group[0]);

    // A pre-v8 snapshot (default DrumSnap, no choke_group field set) must
    // leave every pad ungrouped even though DrumMachine.init seeds a default
    // hihat/open pairing - the load path is the source of truth.
    const legacy: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{ .label = "drums", .kind = .drum_machine, .drum = .{} }},
    };
    var legacy_session = try buildSession(testing.allocator, &legacy);
    defer legacy_session.deinit();
    const legacy_dm = &legacy_session.racks.items[0].instrument.drum_machine;
    for (legacy_dm.choke_group) |g| try testing.expectEqual(@as(u8, 0), g);
}

test "clip snapshots carry the drum variant label" {
    const testing = std.testing;

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;
    _ = dm.addVariant(); // B active
    try session.stampClip(0, 0);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cs = try clipToSnap(arena.allocator(), session.arrangement.lane(0).?.clips.items[0]);
    try testing.expectEqual(@as(u8, 1), cs.variant);

    var clip = try clipFromSnap(testing.allocator, cs, 4, file_version);
    defer clip.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), clip.content.drum.variant);
}

test "buildSession: rejects malformed and future files" {
    const testing = std.testing;

    // Newer file version than this build understands.
    try testing.expectError(error.UnsupportedVersion, buildSession(testing.allocator, &.{
        .version = file_version + 1,
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .kind = .empty }},
    }));

    // Track/rack count mismatch.
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{ .{ .name = "a" }, .{ .name = "b" } },
        .racks = &.{.{ .label = "e", .kind = .empty }},
    }));

    // Nonsense sample rate.
    try testing.expectError(error.InvalidSampleRate, buildSession(testing.allocator, &.{
        .sample_rate = 0,
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .kind = .empty }},
    }));

    // Clip spans must be non-empty and fit the u32 bar timeline.
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .kind = .empty }},
        .arrangement = &.{.{ .clips = &.{.{ .start_bar = 1, .length_bars = 0 }} }},
    }));
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .kind = .empty }},
        .arrangement = &.{.{ .clips = &.{.{ .start_bar = std.math.maxInt(u32), .length_bars = 1 }} }},
    }));
    try testing.expectError(error.MalformedProject, buildSession(testing.allocator, &.{
        .tracks = &.{.{ .name = "a" }},
        .racks = &.{.{ .label = "e", .kind = .empty }},
        .arrangement = &.{.{ .clips = &.{.{
            .start_bar = std.math.maxInt(u32) / 16,
            .length_bars = 2,
        }} }},
    }));
}

test "generic FX snapshot loading ignores non-finite fields" {
    const nan = std.math.nan(f32);

    var gate = Gate.init(48_000);
    const gate_before = gate;
    applySnapToDevice(&gate, GateSnap{ .threshold_db = nan, .attack_ms = nan, .release_ms = nan });
    try std.testing.expectEqual(gate_before.threshold_db, gate.threshold_db);
    try std.testing.expectEqual(gate_before.attack_ms, gate.attack_ms);
    try std.testing.expectEqual(gate_before.release_ms, gate.release_ms);

    var sat: Saturator = .{};
    const sat_before = sat;
    applySnapToDevice(&sat, SatSnap{ .drive_db = nan, .out_db = nan, .mix = nan });
    try std.testing.expectEqual(sat_before.drive_db, sat.drive_db);
    try std.testing.expectEqual(sat_before.out_db, sat.out_db);
    try std.testing.expectEqual(sat_before.mix, sat.mix);

    var crush: Crusher = .{};
    const crush_before = crush;
    applySnapToDevice(&crush, CrushSnap{ .bits = nan, .downsample = nan, .mix = nan });
    try std.testing.expectEqual(crush_before.bits, crush.bits);
    try std.testing.expectEqual(crush_before.downsample, crush.downsample);
    try std.testing.expectEqual(crush_before.mix, crush.mix);

    var phaser = Phaser.init(48_000);
    const phaser_before = phaser;
    applySnapToDevice(&phaser, PhaserSnap{ .rate_hz = nan, .depth = nan, .feedback = nan, .mix = nan });
    try std.testing.expectEqual(phaser_before.rate_hz, phaser.rate_hz);
    try std.testing.expectEqual(phaser_before.depth, phaser.depth);
    try std.testing.expectEqual(phaser_before.feedback, phaser.feedback);
    try std.testing.expectEqual(phaser_before.mix, phaser.mix);
}

test "specialized FX snapshot loading ignores non-finite fields" {
    const testing = std.testing;
    const nan = std.math.nan(f32);
    var fx: Fx = .{};
    defer fx.deinit(testing.allocator);
    try applyFxChain(testing.allocator, &fx, &.{
        .{ .kind = .comp, .comp = .{ .threshold_db = nan, .ratio = nan, .attack_ms = nan, .release_ms = nan, .makeup_db = nan } },
        .{ .kind = .mb_comp, .mb_comp = .{
            .xover_lo_hz = nan,
            .xover_hi_hz = nan,
            .attack_ms = nan,
            .release_ms = nan,
            .mix = nan,
            .low_threshold_db = nan,
            .low_ratio = nan,
            .low_makeup_db = nan,
            .mid_threshold_db = nan,
            .mid_ratio = nan,
            .mid_makeup_db = nan,
            .high_threshold_db = nan,
            .high_ratio = nan,
            .high_makeup_db = nan,
        } },
        .{ .kind = .ott, .ott = .{ .depth = nan, .time = nan, .gain_in_db = nan, .gain_out_db = nan } },
        .{ .kind = .delay, .delay = .{ .time_s = nan, .feedback = nan, .mix = nan } },
    }, 48_000, null);

    const comp = &fx.units.items[0].payload.comp;
    try testing.expect(std.math.isFinite(comp.threshold_db));
    try testing.expect(std.math.isFinite(comp.ratio));
    try testing.expect(std.math.isFinite(comp.attack_ms));
    try testing.expect(std.math.isFinite(comp.release_ms));
    try testing.expect(std.math.isFinite(comp.makeup_db));

    const mb = &fx.units.items[1].payload.mb_comp;
    try testing.expect(std.math.isFinite(mb.xover_lo_hz));
    try testing.expect(std.math.isFinite(mb.xover_hi_hz));
    try testing.expect(std.math.isFinite(mb.attack_ms));
    try testing.expect(std.math.isFinite(mb.release_ms));
    try testing.expect(std.math.isFinite(mb.mix));
    for (mb.bands) |band| {
        try testing.expect(std.math.isFinite(band.threshold_db));
        try testing.expect(std.math.isFinite(band.ratio));
        try testing.expect(std.math.isFinite(band.makeup_db));
    }

    const ott = &fx.units.items[2].payload.ott;
    try testing.expect(std.math.isFinite(ott.depth()));
    try testing.expect(std.math.isFinite(ott.time));
    try testing.expect(std.math.isFinite(ott.gain_in_db));
    try testing.expect(std.math.isFinite(ott.gain_out_db));

    const delay = &fx.units.items[3].payload.delay;
    try testing.expect(std.math.isFinite(delay.timeSeconds()));
    try testing.expect(std.math.isFinite(delay.feedback));
    try testing.expect(std.math.isFinite(delay.mix));
}

test "buildSession: clamps out-of-range pad and note values" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{
                .pads = blk: {
                    var ps = [_]PadSnap{.{}} ** DrumMachine.max_pads;
                    // end < start and both far out of range.
                    ps[0] = .{ .used = true, .start_norm = 7.0, .end_norm = -3.0, .gain = 99.0 };
                    break :blk &ps;
                },
            },
        }},
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const pad = &session.racks.items[0].instrument.drum_machine.pads[0].?.pad;
    try testing.expect(pad.start_norm < pad.end_norm);
    try testing.expect(pad.gain <= 2.0);
    // The invariant adjustParam relies on: clamp bounds stay ordered.
    session.racks.items[0].instrument.drum_machine.adjustParam(DrumMachine.paramId(0, 0), 1);
    session.racks.items[0].instrument.drum_machine.adjustParam(DrumMachine.paramId(0, 1), -1);
}

test "buildSession: clamps a zero or negative pattern loop length" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{ .{ .name = "lead" }, .{ .name = "keys" } },
        .racks = &.{
            .{ .label = "synth", .kind = .poly_synth, .synth = .{ .length_beats = 0.0 } },
            .{ .label = "sampler", .kind = .sampler, .sampler = .{ .length_beats = -8.0 } },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    // A hand-edited zero/negative loop length breaks the piano roll's step
    // math (steps - 1 underflow) and the playback wrap - same clamp the
    // clip loader already applies.
    try testing.expectEqual(@as(f64, 1.0), session.racks.items[0].pattern_player.?.length_beats);
    try testing.expectEqual(@as(f64, 1.0), session.racks.items[1].pattern_player.?.length_beats);
}

test "buildSession: track color round-trips and clamps out-of-range values" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{
            .{ .name = "lead", .color = 3 },
            .{ .name = "bass", .color = 255 }, // hand-edited, past the 7-color palette
        },
        .racks = &.{ .{ .label = "empty", .kind = .empty }, .{ .label = "empty", .kind = .empty } },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectEqual(@as(u8, 3), session.project.tracks.items[0].color);
    try testing.expectEqual(@as(u8, 7), session.project.tracks.items[1].color);
}

test "buildSession: empty and sampler racks round-trip" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{ .{ .name = "blank" }, .{ .name = "keys" } },
        .racks = &.{
            .{ .label = "empty", .kind = .empty },
            .{
                .label = "sampler",
                .kind = .sampler,
                .sampler = .{
                    .pad = .{ .pitch_semitones = 3.0, .gain = 0.8, .reverse = true },
                    .root_note = 48,
                    .mono = true,
                    .notes = &.{
                        .{ .pitch = 64, .start_beat = 0.0, .duration_beat = 0.5, .velocity = 0.7 },
                    },
                    .length_beats = 2.0,
                    .swing = 68.0,
                },
            },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    try testing.expectEqual(std.meta.Tag(@import("rack.zig").Instrument).empty, std.meta.activeTag(session.racks.items[0].instrument));
    try testing.expect(session.racks.items[0].pattern_player == null);

    const smp = &session.racks.items[1].instrument.sampler;
    try testing.expectApproxEqAbs(@as(f32, 3.0), smp.pad.pitch_semitones, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.8), smp.pad.gain, 1e-4);
    try testing.expect(smp.pad.reverse);
    try testing.expectEqual(@as(u7, 48), smp.root_note);
    try testing.expect(smp.mono);

    const pp = &session.racks.items[1].pattern_player.?;
    try testing.expectEqual(@as(u16, 1), pp.note_count);
    try testing.expectEqual(@as(u7, 64), pp.notes[0].pitch);
    try testing.expectApproxEqAbs(@as(f64, 2.0), pp.length_beats, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 68.0), pp.swing.load(.monotonic), 1e-6);
}

test "buildSession clamps malformed synth params from a hand-edited file" {
    const testing = std.testing;

    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "lead" }},
        .racks = &.{
            .{
                .label = "synth",
                .kind = .poly_synth,
                .synth = .{
                    .unison = 255,
                    .osc_b_unison = 0,
                    .gain = 999.0,
                    .filter_cutoff = -500.0,
                    .attack_s = -1.0,
                    .sustain = 5.0,
                    .pulse_width = 0.0,
                    .lfo_rate_hz = 0.0,
                    .swing = 999.0,
                    .fx_tape_wow_rate_hz = 999.0,
                },
            },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const s = &session.racks.items[0].instrument.poly_synth;
    try testing.expect(s.unison >= 1 and s.unison <= 16);
    try testing.expect(s.osc_b_unison >= 1 and s.osc_b_unison <= 16);
    try testing.expect(s.gain >= 0.01 and s.gain <= 1.0);
    try testing.expect(s.filter_cutoff >= 20.0 and s.filter_cutoff <= 20_000.0);
    try testing.expect(s.attack_s >= 0.001);
    try testing.expect(s.sustain <= 1.0);
    try testing.expect(s.pulse_width >= 0.01);
    try testing.expect(s.lfo_rate_hz >= 0.01);
    try testing.expect(s.fx_tape_wow_rate_hz <= 3.0);

    const pp = &session.racks.items[0].pattern_player.?;
    try testing.expectApproxEqAbs(PatternPlayer.swing_max, pp.swing.load(.monotonic), 1e-6);
}

// 16-bit WAV round-trip quantisation error bound.
const wav_eps: f32 = 1.0 / 32768.0 + 1e-6;

test "save/load round-trip persists user-loaded drum pad samples" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;

    // Emulate :load-sample - user audio on pad 3, with a tweaked param.
    const clip = try testing.allocator.dupe(f32, &[_]f32{ 0.5, -0.5, 0.25, -0.125 });
    dm.setPadSamples(3, clip, "usr");
    dm.pads[3].?.pad.user_sample = true;
    dm.pads[3].?.pad.pitch_semitones = 5.0;

    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ldm = &loaded.racks.items[0].instrument.drum_machine;
    const pad = &ldm.pads[3].?.pad;
    try testing.expect(pad.user_sample);
    try testing.expectEqualStrings("usr", ldm.padName(3));
    try testing.expectEqual(@as(usize, 4), pad.samples.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), pad.samples[0], wav_eps);
    try testing.expectApproxEqAbs(@as(f32, -0.125), pad.samples[3], wav_eps);
    // Params applied by buildSession survive loadPadWav's sample swap.
    try testing.expectApproxEqAbs(@as(f32, 5.0), pad.pitch_semitones, 1e-4);
    // Shipped-kit pads stay shipped: no sidecar ref, no flag.
    try testing.expect(!ldm.pads[0].?.pad.user_sample);
}

test "save prunes a sidecar WAV left behind when a sample moves pads" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;

    const clip = try testing.allocator.dupe(f32, &[_]f32{ 0.5, -0.5 });
    dm.setPadSamples(3, clip, "usr");
    dm.pads[3].?.pad.user_sample = true;
    try save(testing.allocator, &session, testing.io, wsj_path);

    const sidecar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}_samples", .{ std.fs.path.dirname(wsj_path).?, std.fs.path.stem(wsj_path) });
    defer testing.allocator.free(sidecar_dir);
    const old_rel = try std.fmt.allocPrint(testing.allocator, "{s}/t0p3.wav", .{sidecar_dir});
    defer testing.allocator.free(old_rel);
    try std.Io.Dir.cwd().access(testing.io, old_rel, .{});

    // Same audio, now loaded onto pad 5 instead - pad 3 no longer exports.
    const clip2 = try testing.allocator.dupe(f32, &[_]f32{ 0.5, -0.5 });
    dm.setPadSamples(5, clip2, "usr");
    dm.pads[5].?.pad.user_sample = true;
    dm.pads[3].?.pad.user_sample = false;
    try save(testing.allocator, &session, testing.io, wsj_path);

    // The stale pad-3 file is gone; pad-5's file exists.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, old_rel, .{}));
    const new_rel = try std.fmt.allocPrint(testing.allocator, "{s}/t0p5.wav", .{sidecar_dir});
    defer testing.allocator.free(new_rel);
    try std.Io.Dir.cwd().access(testing.io, new_rel, .{});
}

test "save/load round-trip persists a pad rename with no sample change" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .drum_machine);
    const dm = &session.racks.items[0].instrument.drum_machine;

    // A plain :pad-rename - no new sample, still the shipped kick sample.
    dm.pads[0].?.rename("808");
    try testing.expectEqualStrings("snare", dm.padName(1)); // untouched pad unaffected

    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ldm = &loaded.racks.items[0].instrument.drum_machine;
    try testing.expectEqualStrings("808", ldm.padName(0));
    try testing.expectEqualStrings("snare", ldm.padName(1));
    // Still the shipped-kit sample - renaming alone doesn't flag user_sample.
    try testing.expect(!ldm.pads[0].?.pad.user_sample);
}

test "save/load round-trip persists a user-loaded sampler clip" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .sampler);
    const s = &session.racks.items[0].instrument.sampler;

    // Emulate :load-sample - swap the generated clip for user audio.
    testing.allocator.free(s.pad.samples);
    s.pad.samples = try testing.allocator.dupe(f32, &[_]f32{ 0.25, -0.25 });
    s.pad.name = [_]u8{ 'v', 'o', 'x', ' ', ' ', ' ', ' ', ' ' };
    s.pad.user_sample = true;
    s.pad.gain = 0.8;

    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ls = &loaded.racks.items[0].instrument.sampler;
    try testing.expect(ls.pad.user_sample);
    try testing.expectEqualStrings("vox", trimmedName(&ls.pad.name));
    try testing.expectEqual(@as(usize, 2), ls.pad.samples.len);
    try testing.expectApproxEqAbs(@as(f32, 0.25), ls.pad.samples[0], wav_eps);
    try testing.expectApproxEqAbs(@as(f32, 0.8), ls.pad.gain, 1e-4);
}

test "save/load round-trip persists a :load-wavetable-imported table, default state writes no sidecar" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .poly_synth);
    const s = &session.racks.items[0].instrument.poly_synth;

    // A synth that never touches wavetables shouldn't produce a sidecar dir.
    try save(testing.allocator, &session, testing.io, wsj_path);
    const sidecar_dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj_samples", .{&tmp.sub_path});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(testing.io, sidecar_dir, .{}));

    // Emulate :load-wavetable on OSC B.
    var samples: [wavetable_mod.frame_len * 2]f32 = undefined;
    @memset(samples[0..wavetable_mod.frame_len], -1.0);
    @memset(samples[wavetable_mod.frame_len..], 1.0);
    var wav_buf: [wavetable_mod.frame_len * 2 * 4 + 64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wav_buf);
    try wav.write(&writer, session.project.sample_rate, 1, &samples, .pcm16);
    try s.loadWavetable(.b, writer.buffered());
    s.waveform = .wavetable;
    s.osc_b_waveform = .wavetable;
    s.osc_b_wt_pos = 0.5;

    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ls = &loaded.racks.items[0].instrument.poly_synth;
    try testing.expectEqual(@as(usize, 2), ls.osc_b_wt.frame_count);
    // Wider tolerance than a single WAV round trip's `wav_eps`: this value
    // passes through pcm16 three times (this test's own synthetic WAV, the
    // sidecar export, then the sidecar reload), compounding quantization.
    try testing.expectApproxEqAbs(@as(f32, -1.0), ls.osc_b_wt.frames[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ls.osc_b_wt.frames[wavetable_mod.frame_len], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ls.osc_b_wt_pos, 1e-4);
    // OSC A never got a `:load-wavetable` call - still the bundled default,
    // no sidecar for it.
    try testing.expect(!ls.wt_user);
}

test "save/load round-trip persists a loaded soundfont, its sidecar .sf2, and the selected preset" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/proj.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    try session.setInstrument(0, .soundfont);
    const sf = &session.racks.items[0].instrument.soundfont;

    const sf2_bytes = try soundfont_mod.buildTestSf2(testing.allocator, true, session.project.sample_rate);
    defer testing.allocator.free(sf2_bytes);
    try sf.loadSf2(sf2_bytes);
    sf.gain = 0.6;
    sf.pan = 0.4;
    sf.transpose_semitones = -5.0;

    try save(testing.allocator, &session, testing.io, wsj_path);
    var sidecar_path_buf: [64]u8 = undefined;
    const sidecar_path = try std.fmt.bufPrint(&sidecar_path_buf, ".zig-cache/tmp/{s}/proj_samples/t0.sf2", .{&tmp.sub_path});
    const sidecar_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, sidecar_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(sidecar_bytes);
    try testing.expectEqualSlices(u8, sf2_bytes, sidecar_bytes);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ls = &loaded.racks.items[0].instrument.soundfont;
    try testing.expectEqual(@as(usize, 1), ls.presetCount());
    try testing.expectEqualStrings("Test Preset", ls.presetName());
    try testing.expectApproxEqAbs(@as(f32, 0.6), ls.gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.4), ls.pan, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -5.0), ls.transpose_semitones, 1e-6);
}

test "buildSession: A/B loop region lands in project and transport" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .loop_enabled = true,
        .loop_start_bar = 2,
        .loop_end_bar = 4,
        .tracks = &.{.{ .name = "t" }},
        .racks = &.{.{ .label = "t", .kind = .empty }},
    };
    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();
    try testing.expect(session.project.loop_enabled);
    try testing.expectEqual(@as(u32, 2), session.project.loop_start_bar);
    // 120 bpm 4/4 @ 48k → 96_000 frames per bar.
    try testing.expect(session.engine.transport.loop_enabled);
    try testing.expectEqual(@as(u64, 192_000), session.engine.transport.loop_start_frames);
    try testing.expectEqual(@as(u64, 384_000), session.engine.transport.loop_end_frames);

    // An inverted region deserialises disabled.
    var bad = try buildSession(testing.allocator, &.{
        .loop_enabled = true,
        .loop_start_bar = 4,
        .loop_end_bar = 2,
        .tracks = &.{.{ .name = "t" }},
        .racks = &.{.{ .label = "t", .kind = .empty }},
    });
    defer bad.deinit();
    try testing.expect(!bad.engine.transport.loop_enabled);
}

test "golden-file corpus: every historical .wsj fixture still loads" {
    const testing = std.testing;
    const dir_path = "test/fixtures/wsj";

    var dir = try std.Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
    defer dir.close(testing.io);

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".wsj")) continue;
        count += 1;

        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });

        var session = load(testing.allocator, testing.io, path) catch |err| {
            std.debug.print("fixture {s} failed to load: {}\n", .{ entry.name, err });
            return err;
        };
        defer session.deinit();

        // Every fixture's Snapshot has parallel tracks/racks/arrangement -
        // buildSession already enforces this, but check it here too so a
        // regression shows up against the fixture name, not just an error.
        try testing.expectEqual(session.project.tracks.items.len, session.racks.items.len);
    }

    // Guards against a misconfigured path silently turning this into a no-op.
    try testing.expectEqual(@as(usize, 24), count);
}

test "golden-file corpus: v25's soundfont rack loads with no font (no sidecar to resolve) but keeps its OUT params" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v25.wsj");
    defer session.deinit();
    const sf = &session.racks.items[0].instrument.soundfont;
    try testing.expectEqual(@as(usize, 0), sf.presetCount());
    try testing.expectApproxEqAbs(@as(f32, 0.8), sf.gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.25), sf.pan, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3.0), sf.transpose_semitones, 1e-6);
    try testing.expect(session.racks.items[0].pattern_player != null);
}

test "golden-file corpus: v23's sparse note list loads directly, no legacy migration" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v23.wsj");
    defer session.deinit();
    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expect(dm.stepActive(0, 0));
    try testing.expectEqual(@as(u8, 127), dm.stepVel(0, 0));
    try testing.expect(dm.stepActive(1, 4));
    try testing.expectEqual(@as(u8, 95), dm.stepVel(1, 4));
    try testing.expect(!dm.stepActive(0, 4));
}

test "golden-file corpus: v17's mod matrix loads its rows" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v17.wsj");
    defer session.deinit();

    const s = &session.racks.items[0].instrument.poly_synth;
    try testing.expectEqual(synth_mod.ModSource.lfo, s.mod_matrix[0].source);
    try testing.expectEqual(@as(u8, 21), s.mod_matrix[0].dest);
    try testing.expectApproxEqAbs(@as(f32, 0.8), s.mod_matrix[0].depth, 1e-6);
    try testing.expectEqual(synth_mod.ModSource.velocity, s.mod_matrix[1].source);
    try testing.expectEqual(PolySynth.dest_amp, s.mod_matrix[1].dest);
    try testing.expectEqual(synth_mod.ModSource.none, s.mod_matrix[2].source);
}

test "applyToSynth: pre-v17 legacy mod fields migrate onto matrix rows" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    const legacy: SynthSnap = .{ .fenv_amount = 2.0, .lfo_depth = 0.8, .lfo_target = .filter };
    applyToSynth(&s, &legacy);
    try std.testing.expectEqual(synth_mod.ModSource.fenv, s.mod_matrix[0].source);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.mod_matrix[0].depth, 1e-6);
    try std.testing.expectEqual(synth_mod.ModSource.lfo, s.mod_matrix[1].source);
    try std.testing.expectEqual(@as(u8, 21), s.mod_matrix[1].dest);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), s.mod_matrix[1].depth, 1e-6);

    // A v17 snapshot with a present-but-empty matrix means "no routing" -
    // the stale legacy fields (written at defaults, but be paranoid) lose.
    const empty: SynthSnap = .{ .mod_matrix = &.{}, .fenv_amount = 2.0 };
    applyToSynth(&s, &empty);
    try std.testing.expectEqual(synth_mod.ModSource.none, s.mod_matrix[0].source);
}

test "save/load round-trip persists LFO 2/3, macros, and their matrix sources" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/lfo23.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    session.racks.items[0].instrument = .{ .poly_synth = try PolySynth.init(testing.allocator, session.project.sample_rate) };
    const s = &session.racks.items[0].instrument.poly_synth;
    // zig fmt: off
    s.lfo2_shape = .sh;  s.lfo2_rate_hz = 6.5;
    s.lfo3_shape = .saw; s.lfo3_rate_hz = 0.25;
    s.macro1 = 0.33; s.macro4 = 0.9;
    s.mod_matrix[0] = .{ .source = .lfo2, .dest = 21,                 .depth = 0.5 };
    s.mod_matrix[1] = .{ .source = .mac1, .dest = PolySynth.dest_amp, .depth = -0.3 };
    // zig fmt: on

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const ls = &loaded.racks.items[0].instrument.poly_synth;
    try testing.expectEqual(synth_mod.LfoShape.sh, ls.lfo2_shape);
    try testing.expectApproxEqAbs(@as(f32, 6.5), ls.lfo2_rate_hz, 1e-6);
    try testing.expectEqual(synth_mod.LfoShape.saw, ls.lfo3_shape);
    try testing.expectApproxEqAbs(@as(f32, 0.25), ls.lfo3_rate_hz, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.33), ls.macro1, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), ls.macro4, 1e-6);
    try testing.expectEqual(synth_mod.ModSource.lfo2, ls.mod_matrix[0].source);
    try testing.expectEqual(synth_mod.ModSource.mac1, ls.mod_matrix[1].source);
    try testing.expectApproxEqAbs(@as(f32, -0.3), ls.mod_matrix[1].depth, 1e-6);
}

test "save/load round-trip persists a custom LFO shape's points" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/lfo_custom.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    session.racks.items[0].instrument = .{ .poly_synth = try PolySynth.init(testing.allocator, session.project.sample_rate) };
    const s = &session.racks.items[0].instrument.poly_synth;
    s.lfo_shape = .custom;
    s.lfo_custom[0][0] = .{ .phase = 0.0, .value = -0.6 };
    s.lfo_custom[0][1] = .{ .phase = 0.4, .value = 0.8 };
    s.lfo_custom[0][2] = .{ .phase = 1.0, .value = -0.6 };
    s.lfo_custom_count[0] = 3;
    s.lfo3_shape = .custom;
    s.lfo_custom[2][0] = .{ .phase = 0.0, .value = 1.0 };
    s.lfo_custom[2][1] = .{ .phase = 1.0, .value = -1.0 };
    s.lfo_custom_count[2] = 2;

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const ls = &loaded.racks.items[0].instrument.poly_synth;
    try testing.expectEqual(synth_mod.LfoShape.custom, ls.lfo_shape);
    try testing.expectEqual(@as(u8, 3), ls.lfo_custom_count[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.4), ls.lfo_custom[0][1].phase, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), ls.lfo_custom[0][1].value, 1e-6);
    try testing.expectEqual(synth_mod.LfoShape.custom, ls.lfo3_shape);
    try testing.expectEqual(@as(u8, 2), ls.lfo_custom_count[2]);
    try testing.expectApproxEqAbs(@as(f32, -1.0), ls.lfo_custom[2][1].value, 1e-6);
    // LFO 2 never got a custom shape - still round-trips its untouched
    // flat-zero default (synthToSnap always serializes whatever's live,
    // customized or not; only a file predating this field entirely hits
    // the null/no-points fallback - see the golden-file test below).
    try testing.expectEqual(@as(u8, 2), ls.lfo_custom_count[1]);
    try testing.expectApproxEqAbs(@as(f32, 0.0), ls.lfo_custom[1][0].value, 1e-6);
}

test "golden-file corpus: pre-lfo-custom files load with no custom points on any LFO slot" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v17.wsj");
    defer session.deinit();
    const s = &session.racks.items[0].instrument.poly_synth;
    try testing.expectEqual(@as(u8, 0), s.lfo_custom_count[0]);
    try testing.expectEqual(@as(u8, 0), s.lfo_custom_count[1]);
    try testing.expectEqual(@as(u8, 0), s.lfo_custom_count[2]);
}

test "golden-file corpus: v14's parametric EQ bands load freq/Q/gain" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v14.wsj");
    defer session.deinit();
    const eq = &session.racks.items[0].fx.find(.eq).?.payload.eq;
    try testing.expectApproxEqAbs(@as(f32, 80.0), eq.bands[0].freq, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.2), eq.bands[0].q, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 3.0), eq.bands[0].gain_db, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1200.0), eq.bands[3].freq, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 2.0), eq.bands[3].q, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 4.5), eq.bands[3].gain_db, 1e-3);
}

test "golden-file corpus: v15's multiband unit and v16's OTT unit load their params" {
    const testing = std.testing;

    var v15 = try load(testing.allocator, testing.io, "test/fixtures/wsj/v15.wsj");
    defer v15.deinit();
    const m = &v15.racks.items[0].fx.find(.mb_comp).?.payload.mb_comp;
    try testing.expectApproxEqAbs(@as(f32, 150.0), m.xover_lo_hz, 1e-3);
    try testing.expectEqual(multiband_comp_mod.Style.ott, m.style);
    try testing.expectApproxEqAbs(@as(f32, -25.0), m.bands[0].threshold_db, 1e-3);

    var v16 = try load(testing.allocator, testing.io, "test/fixtures/wsj/v16.wsj");
    defer v16.deinit();
    const o = &v16.racks.items[0].fx.find(.ott).?.payload.ott;
    try testing.expectApproxEqAbs(@as(f32, 0.7), o.depth(), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.5), o.time, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 2.0), o.gain_in_db, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -3.0), o.gain_out_db, 1e-3);
}

test "golden-file corpus: v18's freq_shift unit loads its params" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v18.wsj");
    defer session.deinit();
    const f = &session.racks.items[0].fx.find(.freq_shift).?.payload.freq_shift;
    try testing.expectApproxEqAbs(@as(f32, 137.0), f.shift_hz, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.8), f.mix, 1e-3);
}

test "golden-file corpus: v19's flanger unit loads its params" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v19.wsj");
    defer session.deinit();
    const fl = &session.racks.items[0].fx.find(.flanger).?.payload.flanger;
    try testing.expectApproxEqAbs(@as(f32, 0.6), fl.rate_hz, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.85), fl.depth, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.4), fl.feedback, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.7), fl.mix, 1e-3);
}

test "golden-file corpus: v20's wavetable oscillator loads its waveform/wt_pos" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v20.wsj");
    defer session.deinit();
    const s = &session.racks.items[0].instrument.poly_synth;
    try testing.expectEqual(synth_mod.Waveform.wavetable, s.waveform);
    try testing.expectApproxEqAbs(@as(f32, 0.35), s.wt_pos, 1e-3);
}

test "golden-file corpus: v21's tape unit loads its params" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v21.wsj");
    defer session.deinit();
    const t = &session.racks.items[0].fx.find(.tape).?.payload.tape;
    try testing.expectApproxEqAbs(@as(f32, 0.5), t.wow_rate_hz, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.6), t.wow_depth, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 7.0), t.flutter_rate_hz, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.3), t.flutter_depth, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.9), t.mix, 1e-3);
}

test "save/load round-trip persists a synth's own tape FX settings" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/synth_tape.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    session.racks.items[0].instrument = .{ .poly_synth = try PolySynth.init(testing.allocator, session.project.sample_rate) };
    const s = &session.racks.items[0].instrument.poly_synth;
    // zig fmt: off
    s.fx_tape_on = true;
    s.fx_tape_wow_rate_hz = 1.1;      s.fx_tape_wow_depth = 0.7;
    s.fx_tape_flutter_rate_hz = 10.0; s.fx_tape_flutter_depth = 0.5;
    s.fx_tape_mix = 0.65;
    // zig fmt: on

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();

    const ls = &loaded.racks.items[0].instrument.poly_synth;
    try testing.expect(ls.fx_tape_on);
    try testing.expectApproxEqAbs(@as(f32, 1.1), ls.fx_tape_wow_rate_hz, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7), ls.fx_tape_wow_depth, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 10.0), ls.fx_tape_flutter_rate_hz, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ls.fx_tape_flutter_depth, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.65), ls.fx_tape_mix, 1e-6);
}

test "save/load round-trip persists an EQ band's lowpass/highpass type and slope" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/eq_type.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const unit = try session.racks.items[0].fx.insert(testing.allocator, 0, .eq, session.project.sample_rate);
    unit.payload.eq.setType(0, .highpass, 3);
    unit.payload.eq.setType(1, .lowpass, 2);

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const eq = &loaded.racks.items[0].fx.units.items[0].payload.eq;
    try testing.expectEqual(eq_mod.BandKind.highpass, eq.bands[0].kind);
    try testing.expectEqual(@as(u8, 3), eq.bands[0].slope);
    try testing.expectEqual(eq_mod.BandKind.lowpass, eq.bands[1].kind);
    try testing.expectEqual(@as(u8, 2), eq.bands[1].slope);
    // Untouched bands keep the default peak type.
    try testing.expectEqual(eq_mod.BandKind.peak, eq.bands[2].kind);
}

test "migrateEqBands: legacy 10-band gains land on sane 8-band defaults" {
    const testing = std.testing;
    var gains = [_]f32{0.0} ** legacy_eq_band_count;
    gains[1] = 5.0; // 62.5Hz - nearest legacy band to the new 60Hz default
    gains[9] = -4.0; // 16000Hz - matches the new top band's default exactly
    const bands = migrateEqBands(gains);
    try testing.expectEqual(@as(usize, eq_mod.num_eq_bands), bands.len);
    try testing.expectApproxEqAbs(@as(f32, 5.0), bands[0].gain_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 60.0), bands[0].freq, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.7), bands[0].q, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -4.0), bands[7].gain_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 16000.0), bands[7].freq, 1e-4);
}

test "golden-file corpus: v13's synth_param_automation loads multiple lanes" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v13.wsj");
    defer session.deinit();
    const clip = session.arrangement.lanes.items[0].clips.items[0];
    const cutoff = clip.automation.findSynthParam(21).?;
    try testing.expectEqual(@as(usize, 2), cutoff.len);
    try testing.expectApproxEqAbs(@as(f32, 2000.0), cutoff[0].value, 1e-3);
    const lfo_rate = clip.automation.findSynthParam(29).?;
    try testing.expectEqual(@as(usize, 1), lfo_rate.len);
    try testing.expectApproxEqAbs(@as(f32, 4.0), lfo_rate[0].value, 1e-3);
}

test "golden-file corpus: v12's vel field loads a granular per-step value" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v12.wsj");
    defer session.deinit();
    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expect(dm.stepActive(0, 0));
    try testing.expectEqual(@as(u8, 127), dm.stepVel(0, 0));
    try testing.expectEqual(@as(u8, 64), dm.stepVel(0, 1));
}

test "golden-file corpus: v11's ninth pad (past the pre-v11 8-pad cap) loads used" {
    const testing = std.testing;
    var session = try load(testing.allocator, testing.io, "test/fixtures/wsj/v11.wsj");
    defer session.deinit();
    const dm = &session.racks.items[1].instrument.drum_machine;
    // Pad 8 (the fixture's only `used: true` entry) got materialized fresh
    // with the file's params, past the pre-v11 8-pad cap.
    try testing.expect(dm.pads[8] != null);
    try testing.expectApproxEqAbs(@as(f32, 0.8), dm.pads[8].?.pad.gain, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -3.0), dm.pads[8].?.pad.pitch_semitones, 1e-4);
    try testing.expect(dm.stepActive(8, 2)); // pattern[8] = 4 = bit 2
    // Pads 0-7 stay whatever init()'s default kit already gave them - a
    // v11 file's `used: false` doesn't retroactively unmaterialize a pad
    // the shipped kit always loads; it only means "the file itself didn't
    // touch this one".
    for (0..8) |i| try testing.expect(dm.pads[i] != null);
}

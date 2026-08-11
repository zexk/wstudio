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
const time_map = @import("time_map.zig");
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
const controller_mod = @import("dsp/controller.zig");
/// Exact format version this build writes and reads. See FORMAT.md.
pub const file_version: u32 = 58;

/// First four bytes of every .wsj. The file is a container, not bare JSON:
/// a 12-byte header, the audio cache (user sample blobs, concatenated), then
/// this `Snapshot` as JSON to EOF. See FORMAT.md for the full layout.
pub const bundle_magic = "WSJ1".*;

/// magic (4 bytes) + u64 LE offset of the JSON section (8).
pub const bundle_header_len: u64 = 12;

/// One blob in the audio cache. `name` is the key `PadSnap.sample_file` and
/// its siblings hold; `offset` and `len` slice the bytes straight out of the
/// .wsj. Blobs are WAV except a SoundFont's, which is its original .sf2.
pub const AudioCacheSnap = struct {
    name: []const u8,
    offset: u64,
    len: u64,
};

/// Mirrors `automation_mod.Curve` as a plain string enum, same JSON-stability
/// reasoning as `EqBandKindSnap`.
pub const AutomationCurveSnap = enum {
    linear,
    hold,
    ease,
};

pub const AutomationPointSnap = struct {
    beat: f64,
    value: f32,
    /// Shape of the segment leaving this point.
    curve: AutomationCurveSnap = .linear,
};

pub const MixAutomationSnap = struct {
    target: automation_mod.MixTarget,
    points: []const AutomationPointSnap = &.{},
};

/// One synth-instrument- or FX-unit-param automation lane - see `ClipSnap.
/// synth_param_automation`. `instance_id` 0 targets the track instrument;
/// nonzero targets a specific `FxUnit` by stable `instance_id`.
pub const SynthParamAutomationSnap = struct {
    instance_id: u32 = 0,
    param_id: u32,
    points: []const AutomationPointSnap = &.{},
};

// ---------------------------------------------------------------------------
// Snapshot types - plain data, JSON-serialisable
// ---------------------------------------------------------------------------

/// Per-note expression (`dsp.Articulation`) stored flat with neutral defaults.
pub const NoteSnap = struct {
    pitch: u8,
    start_beat: f64,
    duration_beat: f64,
    velocity: f32 = 0.85,
    channel: u8 = 0,
    midi_track: u16 = 0,
    pan: f32 = 0.0,
    fine_cents: f32 = 0.0,
    release_scale: f32 = 1.0,
};

pub const PatternSnap = struct {
    notes: []const NoteSnap = &.{},
    midi_events: []const pattern_mod.MidiEvent = &.{},
    length_beats: f64 = 4.0,
    swing: f32 = 50.0,
};

pub const SynthSnap = struct {
    // OSC A
    wt_bundled: ?synth_mod.BundledWavetable = .basic,
    detune_cents: f32 = 0.0,
    unison: u8 = 1,
    unison_detune: f32 = 15.0,
    unison_spread: f32 = 0.0,
    unison_mode: synth_mod.UnisonMode = .spread,
    warp_mode: synth_mod.WarpMode = .none,
    warp_amount: f32 = 0.0,
    // OSC B
    osc_b_on: bool = false,
    osc_b_wt_bundled: ?synth_mod.BundledWavetable = .basic,
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
    osc_c_wt_bundled: ?synth_mod.BundledWavetable = .basic,
    osc_c_semi: f32 = 0.0,
    osc_c_detune_cents: f32 = 0.0,
    osc_c_level: f32 = 1.0,
    osc_c_unison: u8 = 1,
    osc_c_unison_detune: f32 = 15.0,
    osc_c_unison_mode: synth_mod.UnisonMode = .spread,
    osc_c_warp_mode: synth_mod.WarpMode = .none,
    osc_c_warp_amount: f32 = 0.0,
    // Amp envelope
    attack_s: f32 = 0.005,
    decay_s: f32 = 0.08,
    sustain: f32 = 0.7,
    release_s: f32 = 0.25,
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
    lfo_shape: synth_mod.LfoShape = .drawn,
    lfo_rate_hz: f32 = 1.0,
    lfo_sync: synth_mod.LfoSync = .off,
    lfo_retrig: synth_mod.LfoRetrig = .free,
    lfo_phase_offset: f32 = 0.0,
    lfo_slew_ms: f32 = 0.0,
    // LFO 2 / LFO 3 + macros
    lfo2_shape: synth_mod.LfoShape = .drawn,
    lfo2_rate_hz: f32 = 1.0,
    lfo2_sync: synth_mod.LfoSync = .off,
    lfo2_retrig: synth_mod.LfoRetrig = .free,
    lfo2_phase_offset: f32 = 0.0,
    lfo2_slew_ms: f32 = 0.0,
    lfo3_shape: synth_mod.LfoShape = .drawn,
    lfo3_rate_hz: f32 = 1.0,
    lfo3_sync: synth_mod.LfoSync = .off,
    lfo3_retrig: synth_mod.LfoRetrig = .free,
    lfo3_phase_offset: f32 = 0.0,
    lfo3_slew_ms: f32 = 0.0,
    /// Drawn shape points. Manual in synthToSnap/applyToSynth:
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
    mod_matrix: []const synth_mod.PolySynth.ModRow = &.{},
    // Voice
    voice_mode: synth_mod.VoiceMode = .poly,
    glide_s: f32 = 0.0,
    // Sub
    sub_level: f32 = 0.0,
    sub_shape: synth_mod.SubShape = .sine,
    // Noise
    noise_level: f32 = 0.0,
    noise_color: f32 = 1.0,
    // Output
    gain: f32 = 0.35,
    // Arpeggiator
    arp_on: bool = false,
    arp_mode: synth_mod.ArpMode = .up,
    arp_octaves: u8 = 1,
    arp_rate_hz: f32 = 8.0,
    arp_sync: synth_mod.LfoSync = .off,
    arp_gate: f32 = 0.5,
    arp_hold: bool = false,
    // ENV 3: free-assignable envelope, matrix source only
    env3_attack_s: f32 = 0.005,
    env3_decay_s: f32 = 0.3,
    env3_sustain: f32 = 0.0,
    env3_release_s: f32 = 0.3,
    env3_curve: f32 = 0.0,
    // Wavetable oscillators
    wt_pos: f32 = 0.0,
    osc_b_wt_pos: f32 = 0.0,
    osc_c_wt_pos: f32 = 0.0,
    /// Audio cache key of a `:load-wavetable`-imported table's WAV, empty
    /// for the bundled default (mirrors `PadSnap.sample_file`).
    wt_file: []const u8 = "",
    osc_b_wt_file: []const u8 = "",
    osc_c_wt_file: []const u8 = "",
    // Pattern player
    pattern: PatternSnap = .{},
};

/// Per-pad sampler params. Defaults mirror `dsp.Pad`.
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
    env_curve: f32 = 0.0,
    /// Edit fades multiplied on top of ADSR (see `dsp.Pad`).
    fade_in_s: f32 = 0.0,
    fade_out_s: f32 = 0.0,
    fade_curve: f32 = 0.0,
    /// Playback duration multiplier, independent of pitch (see `dsp.Pad`).
    stretch_ratio: f32 = 1.0,
    warp_method: pad_mod.WarpMethod = .tones,
    /// Bipolar tone filter and gated-playback flag (see `dsp.Pad`).
    filter: f32 = 0.0,
    gate: bool = false,
    /// Retrigger play mode (see `dsp.Pad.retrig`).
    retrig: bool = false,
    /// User-loaded audio, exported to the project's audio cache on save.
    /// An `AudioCacheSnap.name`; empty = shipped/generated audio.
    sample_file: []const u8 = "",
    /// Display name of user-loaded sample ("" keeps default).
    name: []const u8 = "",
    /// Whether this slot has ever had a sample loaded (shipped kit or user
    /// `:load-sample`). `false` means live
    /// `DrumMachine.pads[i]` is null (never materialized; see that field's
    /// own doc comment); other fields then hold defaults, not sample data.
    used: bool = false,
    /// Per-pad LFO (see `dsp.Pad.mod_lfo`).
    mod_rate_hz: f32 = 2.0,
    mod_depth: f32 = 0.0,
    mod_shape: lfo_mod.Shape = .sine,
    mod_dest: pad_mod.ModDest = .off,
    /// Region loop mode (see `dsp.Pad.loop`).
    loop: pad_mod.LoopMode = .off,
};

/// One drum-machine note: position, duration, velocity, and performance data.
pub const DrumNoteSnap = struct {
    pad: u8,
    step: u16,
    duration_steps: u16 = 1,
    velocity: u7 = 127,
    /// Per-step transpose in semitones (see `DrumMachine.MidiNote.tune`).
    tune: i8 = 0,
    /// Trigger condition and fire chance (see `DrumMachine.Cond`). `cond` is
    /// stored as enum tag; out-of-range values fall back to `always`.
    prob: u8 = 100,
    cond: u8 = 0,
    /// Hits packed into step; 0/1 means one hit.
    retrig: u8 = 0,
    /// Timing offset as percent of one step.
    micro: i8 = 0,
};

pub const DrumPatternSnap = struct {
    step_count: u16 = 16,
    /// Native pattern resolution.
    steps_per_beat: u8 = 4,
    /// Sparse per-pad note list - this variant's whole step grid. Slice, not
    /// `[max_pads][max_steps]`, so a hand-edited or truncated file loads by
    /// dropping the out-of-range entries instead of failing to parse.
    notes: []const DrumNoteSnap = &.{},
};

pub const VariantSnap = DrumPatternSnap;

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
    /// never cached, only user samples are. Unknown names leave
    /// pads as their `used` flags describe them.
    kit: []const u8 = "",
};

pub const CompSnap = struct {
    threshold_db: f32 = -18.0,
    ratio: f32 = 4.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
    makeup_db: f32 = 0.0,
    /// Soft-knee width in dB; 0 means hard knee.
    knee_db: f32 = 0.0,
    /// How long reduction is held at its deepest before release starts.
    hold_ms: f32 = 0.0,
    /// 0 = downward compression, 1 = upward.
    mode: f32 = 0.0,
    /// Dry/wet blend; below 1 is parallel compression.
    mix: f32 = 1.0,
    /// Detector: 0 = peak, 1 = RMS.
    sc_mode: f32 = 0.0,
    /// Detector high-pass / low-pass in Hz; 0 = off.
    sc_hpf_hz: f32 = 0.0,
    sc_lpf_hz: f32 = 0.0,
    /// Null uses ordinary self-detecting compression.
    sidechain_source: ?u16 = null,
    /// Drum pad within source track to key off; null uses whole track mix.
    /// Ignored when `sidechain_source` is null.
    sidechain_pad: ?u8 = null,
    /// Whether `sidechain_source` names a group bus instead of track.
    sidechain_is_group: bool = false,
};

pub const MultibandCompSnap = struct {
    xover_lo_hz: f32 = 200.0,
    xover_hi_hz: f32 = 2000.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
    /// Soft-knee width in dB, shared across all bands; 0 means hard knee.
    knee_db: f32 = 0.0,
    /// Mirrors two-state `dsp.multiband_comp.Style`.
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
    damp: f32 = 0.0,
};

pub const ReverbSnap = struct {
    mix: f32 = 0.3,
    room: f32 = 0.84,
    damp: f32 = 0.25,
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
};

/// Mirrors `eq_mod.StereoMode` as a plain string enum, same JSON-stability
/// reasoning as `EqBandKindSnap`.
pub const EqStereoModeSnap = enum { stereo, mid, side };

pub const EqBandSnap = struct {
    freq: f32,
    q: f32 = 0.7,
    gain_db: f32 = 0.0,
    /// Band response type.
    kind: EqBandKindSnap = .peak,
    /// Cascade stages for `.lowpass`/
    /// `.highpass`/`.notch` (12 dB/oct each), 1..eq_mod.max_slope. Unused
    /// (but present) for peak/shelf/tiltshelf bands.
    slope: u8 = 1,
    solo: bool = false,
    stereo_mode: EqStereoModeSnap = .stereo,
    dyn_enabled: bool = false,
    dyn_threshold_db: f32 = -24.0,
    dyn_amount_db: f32 = 0.0,
};

/// Every band at its `ParametricEq.init` frequency, flat.
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
    hold_ms: f32 = 0.0,
    /// Gap between the open and close thresholds; 0 gates on one level.
    hysteresis_db: f32 = 0.0,
    /// Attenuation a shut gate falls to; the minimum is full mute.
    range_db: f32 = -80.0,
};

pub const SatSnap = struct {
    drive_db: f32 = 12.0,
    out_db: f32 = 0.0,
    mix: f32 = 1.0,
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

/// Pitch shifter (see `dsp/pitch_shift.zig`).
pub const PitchShiftSnap = struct {
    semitones: f32 = 0.0,
    cents: f32 = 0.0,
    formant: f32 = 0.0,
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
    lookahead_ms: f32 = 0.0,
    /// 0 = sample peak, 1 = true peak (2x inter-sample detection).
    true_peak: f32 = 0.0,
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

pub const ClapSnap = struct {
    path: []const u8 = "",
    plugin_id: []const u8 = "",
    state_base64: []const u8 = "",
    pattern: PatternSnap = .{},
};

pub const Vst3Snap = struct {
    path: []const u8 = "",
    class_id: []const u8 = "",
    component_state_base64: []const u8 = "",
    controller_state_base64: []const u8 = "",
    pattern: PatternSnap = .{},
};

pub const FxContentSnap = union(enum) {
    comp: CompSnap,
    mb_comp: MultibandCompSnap,
    ott: OttSnap,
    delay: DelaySnap,
    reverb: ReverbSnap,
    eq: EqSnap,
    filter: FilterSnap,
    limiter: LimiterSnap,
    utility: UtilitySnap,
    stereo_width: StereoWidthSnap,
    auto_pan: AutoPanSnap,
    transient_shaper: TransientShaperSnap,
    gate: GateSnap,
    sat: SatSnap,
    crush: CrushSnap,
    chorus: ChorusSnap,
    phaser: PhaserSnap,
    flanger: FlangerSnap,
    tape: TapeSnap,
    freq_shift: FreqShiftSnap,
    pitch_shift: PitchShiftSnap,
    clap: ClapSnap,
    vst3: Vst3Snap,
};

pub const FxUnitSnap = struct {
    instance_id: u32 = 0,
    bypassed: bool = false,
    content: FxContentSnap,
};

pub const RackContentSnap = union(enum) {
    empty,
    poly_synth: SynthSnap,
    sampler: SamplerSnap,
    drum_machine: DrumSnap,
    slicer: SlicerSnap,
    clap: ClapSnap,
    vst3: Vst3Snap,
    soundfont: SoundfontSnap,
    acoustic: SoundfontSnap,
};

/// A single-clip sampler: the pad's params, its root note, and the piano-roll
/// pattern. User-loaded clip audio rides along via `pad.sample_file`;
/// without it the sampler remains empty on load.
pub const SamplerSnap = struct {
    pad: PadSnap = .{},
    root_note: u8 = 60,
    /// Mono voice mode (see `dsp.Sampler.mono`).
    mono: bool = false,
    pattern: PatternSnap = .{},
};

/// One shared-clip Slicer instrument. `sample_file`/`name` mirror
/// `PadSnap`'s own audio-cache fields but live at this top level (not per
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

/// A SoundFont (.sf2) player track: the loaded font's audio cache key, the
/// selected preset (by index into the parsed font - see `SoundfontPlayer.
/// preset_index`'s own doc comment for why an index rather than bank/
/// program), OUT params, and piano-roll pattern. `sf2_file` empty
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
    pattern: PatternSnap = .{},
};

pub const RackSnap = struct {
    label: []const u8 = "synth",
    content: RackContentSnap,
    /// The user-built chain in signal-flow order.
    fx_chain: []const FxUnitSnap = &.{},
};

pub const TrackSnap = struct {
    name: []const u8,
    gain_db: f32 = 0.0,
    pan: f32 = 0.0,
    muted: bool = false,
    soloed: bool = false,
    /// Palette index; 0 means no color.
    color: u8 = 0,
    /// Index into `Snapshot.groups`; null means ungrouped.
    group: ?u8 = null,
    /// Parallel aux sends (see `project.SendSlot`).
    sends: []const SendSnap = &.{},
};

/// One track's aux-send slot. Mirrors `project.SendSlot`. Flat bool+index
/// pair rather than a tagged union (same convention `CompSnap`'s
/// `sidechain_source`/`sidechain_is_group` pair uses) - trivial JSON
/// round-trip, no tag-string handling.
pub const SendSnap = struct {
    slot: u8,
    is_group: bool = false,
    group: u8 = 0,
    level_db: f32 = -60.0,
    pre_fader: bool = false,
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
    /// Bus gain in dB.
    gain_db: f32 = 0.0,
    /// Tracks-view fold state (see `Session.Group.folded`).
    folded: bool = false,
    /// Bus mute (see `Session.Group.muted`).
    muted: bool = false,
    /// Bus solo (see `Session.Group.soloed`).
    soloed: bool = false,
};

pub const AudioTakeSnap = struct {
    source_id: u32,
    source_start_frame: u64,
    source_length_frames: u64,
    length_ticks: u32,
};

pub const MelodicClipSnap = struct {
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
};

pub const DrumClipSnap = struct {
    pattern: DrumPatternSnap = .{},
    variant: u8 = 0,
};

pub const AudioClipSnap = struct {
    source_id: u32,
    source_start_frame: u64 = 0,
    source_length_frames: u64,
    gain_db: f32 = 0.0,
    fade_in_frames: u64 = 0,
    fade_out_frames: u64 = 0,
    fade_curve: ws_arrangement.FadeCurve = .linear,
    stretch_ratio: f32 = 1.0,
    reverse: bool = false,
    alternate_takes: []const AudioTakeSnap = &.{},
};

pub const ClipContentSnap = union(enum) {
    melodic: MelodicClipSnap,
    drum: DrumClipSnap,
    audio: AudioClipSnap,
};

/// One placed clip. Melodic and drum clips carry private note copies plus
/// their loop timing. Mirrors `arrangement.Clip`.
pub const ClipSnap = struct {
    /// Exact placement at 32 ticks per quarter-note beat.
    start_tick: u32 = 0,
    length_ticks: u32 = time_grid.ticks_per_beat * 4,
    layer: u8 = 0,
    content: ClipContentSnap = .{ .melodic = .{} },
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

pub const AudioSourceSnap = struct {
    id: u32,
    file: []const u8,
    sample_rate: u32,
    channel_count: u16,
};

/// One modulation-controller target (see `dsp/controller.zig`). `track`
/// indices are re-validated on load, same as every other saved track
/// reference.
pub const ControllerTargetSnap = struct {
    track: u16,
    instance_id: u32 = 0,
    param_id: u32,
    center: f32,
    lo: f32,
    hi: f32,
};

/// One controller slot. `index` is its position in the fixed bank rather
/// than the array order, so a project using only slot 3 stays readable and
/// keeps its number - same dense fixed-position shape as `GroupSnap`.
pub const ControllerSnap = struct {
    index: u8,
    shape: lfo_mod.Shape = .sine,
    beats: f32 = 4.0,
    depth: f32 = 0.5,
    phase: f32 = 0.0,
    targets: []const ControllerTargetSnap = &.{},
};

/// One learned MIDI CC binding (see `dsp/controller.zig`).
pub const CcBindingSnap = struct {
    cc: u8,
    target: ControllerTargetSnap,
};

pub const Snapshot = struct {
    version: u32 = file_version,
    tempo_bpm: f64 = 120.0,
    tempo_points: []const time_map.TempoPoint = &.{},
    /// Song key for scale tools and sample tuning; null means no key.
    scale: ?theory.Scale = null,
    /// Temperament as raw cents rather than preset name.
    tuning: tuning_mod.Tuning = .{},
    beats_per_bar: u8 = 4,
    meter_denominator: u8 = 4,
    meter_points: []const time_map.MeterPoint = &.{},
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
    audio_sources: []const AudioSourceSnap = &.{},
    /// Whether the loaded project plays the arrangement (true) or live loops.
    song_mode: bool = false,
    /// The master bus's user-built chain in signal-flow order, applied to the
    /// summed mix before gain/limiter.
    master_fx_chain: []const FxUnitSnap = &.{},
    /// See `GroupSnap`'s own doc comment for the dense fixed-position shape.
    groups: []const GroupSnap = &.{},
    /// Modulation-controller bank.
    controllers: []const ControllerSnap = &.{},
    /// Learned MIDI CC bindings.
    cc_bindings: []const CcBindingSnap = &.{},
    mix_automation: []const MixAutomationSnap = &.{},
    /// Directory of the audio cache section. Empty for a project holding no
    /// user audio at all.
    audio_cache: []const AudioCacheSnap = &.{},
};

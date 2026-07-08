//! Project save / load.
//!
//! Serialises the live Session to a JSON file (*.wsj).  The snapshot types are
//! pure data — no pointers, no atomics, no heap slices matching the live structs.
//!
//! Round-trip guarantees:
//!   - All 38 PolySynth params + piano-roll notes + loop length
//!   - Drum step-count + per-pad bitmask patterns + per-pad sampler params
//!   - Per-track gain / pan / mute / solo + project tempo
//!   - FX: gate, compressor, EQ, saturator, crusher, chorus, phaser, delay, reverb
//!   - Rack labels
//!   - User-loaded sample audio (drum pads + sampler clips), exported as mono
//!     WAVs into the "<stem>_samples" sidecar directory next to the .wsj

const std = @import("std");
const Session = @import("session.zig").Session;
const wav = @import("core/wav.zig");
const Project = @import("project.zig").Project;
const ws_arrangement = @import("arrangement.zig");
const rack_mod = @import("rack.zig");
const Rack = rack_mod.Rack;
const Fx = rack_mod.Fx;
const engine_mod = @import("audio/engine.zig");
const Engine = engine_mod.Engine;
const synth_mod = @import("dsp/synth.zig");
const PolySynth = synth_mod.PolySynth;
const pattern_mod = @import("dsp/pattern.zig");
const PatternPlayer = pattern_mod.PatternPlayer;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const Pad = @import("dsp/pad.zig").Pad;
const Sampler = @import("dsp/sampler.zig").Sampler;
const Slicer = @import("dsp/slicer.zig").Slicer;
const Compressor = @import("dsp/compressor.zig").Compressor;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const eq_mod = @import("dsp/eq.zig");
const GraphicEq = eq_mod.GraphicEq;
const Gate = @import("dsp/gate.zig").Gate;
const Saturator = @import("dsp/saturator.zig").Saturator;
const Crusher = @import("dsp/crusher.zig").Crusher;
const Chorus = @import("dsp/chorus.zig").Chorus;
const Phaser = @import("dsp/phaser.zig").Phaser;
const dsp = @import("dsp/device.zig");
const automation_mod = @import("dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;

/// v2 adds the arrangement (song timeline) and `song_mode`. v1 files omit both
/// and deserialize to an empty arrangement in pattern mode — the prior behaviour.
/// v3 adds drum pattern variants (`DrumSnap.variants` + active index) and the
/// variant label on drum clips. v2 files omit them and load as a single
/// variant built from the legacy `pattern`/`step_count` fields, which v3 keeps
/// writing (mirroring the active variant) so files stay hand-editable.
/// v4 adds per-step drum velocity (the `vel_lo`/`vel_hi` bitplanes on variants
/// and drum clips), per-machine swing, and the time signature numerator
/// (`beats_per_bar`). Older files omit them and load with every step at full
/// velocity, swing 50 (straight), and 4/4 — the prior behaviour.
/// v5 adds user sample persistence: pads whose audio was loaded by the user
/// carry `sample_file`/`name` refs to mono WAVs exported into the project's
/// sample sidecar directory ("<stem>_samples" next to the .wsj). Older files
/// omit them and keep the shipped kit / generated clip — the prior behaviour.
/// v5 also adds the A/B loop region (`loop_enabled`/`loop_start_bar`/
/// `loop_end_bar`); older files load with no loop.
/// v6 adds the master bus FX rack (`Snapshot.master_fx`, the same `FxSnap`
/// shape as a track's). Older files omit it and load with no master FX —
/// the prior behaviour.
/// v7 adds per-clip gain/pan automation (`ClipSnap.gain_automation`/
/// `pan_automation`, clip-relative-beat breakpoints — see dsp/automation.zig
/// and Session.rebuildSongData). Older files omit them and load with no
/// automation — clips play at the track's manual gain/pan, the prior
/// behaviour.
/// v8 adds per-pad choke groups (`DrumSnap.choke_group`). Older files omit
/// it and every pad loads ungrouped (group 0) — the prior behaviour.
/// v9 adds the five new FX units (`FxSnap.gate`/`sat`/`crush`/`chorus`/
/// `phaser`, see rack.zig's Fx). Older files omit them and load with those
/// slots empty, the prior behaviour.
/// v10 replaces the fixed nine-slot FX rack with a user-built ordered chain
/// (`RackSnap.fx_chain`/`Snapshot.master_fx_chain`, a list of `FxUnitSnap` in
/// signal-flow order — duplicates allowed, per-slot bypass). Older files
/// carry the struct-of-optionals `fx`/`master_fx` instead; they load as a
/// chain in the old hard-wired order (gate → comp → eq → sat → crush →
/// chorus → phaser → delay → reverb), the audible behaviour they had.
///
/// v11 bumps `DrumMachine.max_pads` 8 → 64 with lazy per-pad allocation
/// (`DrumMachine.pads` is now `[64]?Sampler`, not `[8]Sampler`) — genuinely
/// a version bump, not just an additive field, because it changes what an
/// *absent* value means: `PadSnap.used` is new in v11 and defaults to
/// `false`, but every v10-and-older file's 8 pads were ALWAYS materialized
/// (there was no "empty pad" concept before lazy allocation existed), so an
/// absent `used` on a pre-v11 file means `true`, not the v11 default. Also
/// converts DrumSnap/VariantSnap's pad-indexed fields (`pattern`, `vel_lo`,
/// `vel_hi`, `choke_group`, `pads`) from fixed `[DrumMachine.max_pads]T`
/// arrays to slices — std.json requires an exact length match to parse a
/// fixed array, so leaving them tied to the now-64 constant would have
/// broken loading every pre-v11 file's 8-element arrays outright (confirmed
/// with a standalone repro before this landed, not just assumed).
/// v12 widens per-step drum velocity from the old 2-bit `vel_lo`/`vel_hi`
/// bitplanes (4 levels: 100/75/50/25%) to a plain 0-127 byte per step
/// (`VariantSnap.vel`/`ClipSnap.drum_vel`, nested per-pad slices of
/// per-step values — same "slice for JSON-length safety" shape the v11
/// pad-indexed fields already use). Genuinely a version bump, not additive:
/// the old fields aren't just extended, they're superseded, so an older
/// file's `vel_lo`/`vel_hi` (kept, read-only, for exactly this migration)
/// gets remapped through `DrumMachine.legacyVelToNew` onto the new scale
/// instead of being read directly.
/// v13 generalizes the single `filter_cutoff_automation` lane into a sparse
/// list of synth-instrument-param automation lanes (`ClipSnap.
/// synth_param_automation`, one entry per automated `PolySynth.
/// setParamAbsolute` id — see dsp/synth.zig's `automatable_params`).
/// Genuinely a version bump for the same reason v12's velocity change was:
/// the old field is superseded, not extended, so a pre-v13 file's
/// `filter_cutoff_automation` (kept, read-only, for exactly this migration)
/// remaps onto the new list's param_id 21 entry instead of being read
/// directly.
pub const file_version: u32 = 13;

pub const AutomationPointSnap = struct {
    beat: f64,
    value: f32,
};

/// One synth-instrument-param automation lane — see `ClipSnap.
/// synth_param_automation`.
pub const SynthParamAutomationSnap = struct {
    param_id: u8,
    points: []const AutomationPointSnap = &.{},
};

// ---------------------------------------------------------------------------
// Snapshot types — plain data, JSON-serialisable
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
    // OSC B
    osc_b_on: bool = false,
    osc_b_waveform: synth_mod.Waveform = .saw,
    osc_b_pulse_width: f32 = 0.5,
    osc_b_semi: f32 = 0.0,
    osc_b_detune_cents: f32 = 0.0,
    osc_b_level: f32 = 1.0,
    osc_b_unison: u8 = 1,
    osc_b_unison_detune: f32 = 15.0,
    // Amp envelope
    attack_s: f32 = 0.005,
    decay_s: f32 = 0.08,
    sustain: f32 = 0.7,
    release_s: f32 = 0.25,
    // Filter
    filter_type: synth_mod.FilterType = .lp,
    filter_cutoff: f32 = 18_000.0,
    filter_res: f32 = 0.0,
    fenv_amount: f32 = 0.0,
    // Filter envelope
    fenv_attack_s: f32 = 0.005,
    fenv_decay_s: f32 = 0.5,
    fenv_sustain: f32 = 0.0,
    fenv_release_s: f32 = 0.3,
    // LFO
    lfo_shape: synth_mod.LfoShape = .sine,
    lfo_rate_hz: f32 = 1.0,
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
    // Pattern player
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    /// Pattern swing, 50 (straight) to 75 (hardest shuffle) — see
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
    /// shipped kit's pads, or a user `:load-pad`) — `false` means the live
    /// `DrumMachine.pads[i]` is null (never materialized; see that field's
    /// own doc comment) and every other field here is just the struct
    /// default, not meaningful data. Older files omit it; since a pre-64-pad
    /// file only ever had exactly `DrumMachine.max_pads` (then 8) entries
    /// and all 8 were always loaded (the shipped kit), the load path treats
    /// omitted `used` as `true` for exactly those legacy positions — see
    /// `buildSession`.
    used: bool = false,
};

/// One drum pattern variant. Mirrors `DrumMachine.Variant`.
///
/// `pattern`/`vel_lo`/`vel_hi` are slices, not `[DrumMachine.max_pads]u64`
/// fixed arrays: std.json requires an EXACT length match to parse a fixed
/// array, so tying their declared length to `max_pads` would break loading
/// every file saved before pad cap 8->64 (their JSON arrays have exactly 8
/// elements) the moment `max_pads` grew — confirmed by hand before this
/// went further, not just assumed. A slice parses any length; the load path
/// applies `min(len, max_pads)` elements and leaves the rest at the
/// zero-value default, same shape `Snapshot.groups` already uses for the
/// same reason.
pub const VariantSnap = struct {
    step_count: u8 = 16,
    pattern: []const u64 = &.{},
    /// v4, read-only since v12: the old 2-bit velocity bitplanes. Kept only
    /// so `applyVelSnap` can migrate a pre-v12 file's data; new files never
    /// write these (see `vel`, below).
    vel_lo: []const u64 = &.{},
    vel_hi: []const u64 = &.{},
    /// v12: per-pad, per-step velocity (0-127; 127 = full), superseding
    /// `vel_lo`/`vel_hi`. Nested slices, not `[max_pads][max_steps]u8` —
    /// same exact-length-match reasoning as every other pad-indexed field
    /// here (see this struct's own history above).
    vel: []const []const u8 = &.{},
};

pub const DrumSnap = struct {
    /// Legacy live-pattern fields: always the active variant's data, so v2
    /// readers (and hand edits) see a coherent single pattern.
    step_count: u8 = 16,
    /// Slice, not a fixed array — see VariantSnap's doc comment; same
    /// backward-compat reasoning applies to every pad-indexed field below.
    pattern: []const u64 = &.{},
    /// Mutable slice (not `[]const`) — `exportSamples` fills in
    /// `sample_file` for user-loaded pads *after* this struct is built, an
    /// in-place mutation a const slice wouldn't allow.
    pads: []PadSnap = &.{},
    /// v3: the whole variant bank. Empty in v2 files — the machine then gets a
    /// single variant from the legacy fields above.
    variants: []const VariantSnap = &.{},
    /// v3: index of the active variant within `variants`.
    variant: u8 = 0,
    /// v4: swing percent (50 = straight … 75 = hardest shuffle).
    swing: f32 = 50.0,
    /// v8: per-pad choke group (0 = none — see DrumMachine.chokeTrigger).
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

pub const EqSnap = struct {
    band_gains: [eq_mod.num_eq_bands]f32 = [_]f32{0.0} ** eq_mod.num_eq_bands,
    bypass: bool = false,
};

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

/// Mirrors rack.zig's FxKind — persist keeps its own copy so snapshots stay
/// pure data, same pattern as `InstrumentKind` below.
pub const FxKind = enum { gate, comp, eq, sat, crush, chorus, phaser, delay, reverb };

/// One chain slot (v10): its kind, bypass flag, and the params for that kind
/// in the matching optional (the others stay null). A missing params field
/// loads the unit with its defaults.
pub const FxUnitSnap = struct {
    kind: FxKind,
    bypassed: bool = false,
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

pub const InstrumentKind = enum { empty, poly_synth, sampler, drum_machine, slicer };

/// A single-clip sampler: the pad's params, its root note, and the piano-roll
/// pattern. User-loaded clip audio rides along via `pad.sample_file` (v5);
/// without it the default clip is regenerated on load.
pub const SamplerSnap = struct {
    pad: PadSnap = .{},
    root_note: u8 = 60,
    /// Mono voice mode (see `dsp.Sampler.mono`). Additive optional-with-
    /// default field, no version bump needed — defaults to polyphonic so
    /// older projects load unchanged.
    mono: bool = false,
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    /// Pattern swing, 50 (straight) to 75 (hardest shuffle) — see
    /// `dsp.PatternPlayer.swing`. Additive optional-with-default field, no
    /// version bump needed.
    swing: f32 = 50.0,
};

/// One shared-clip Slicer instrument. `sample_file`/`name` mirror
/// `PadSnap`'s own sample-sidecar fields but live at this top level (not per
/// slice) since every slice shares the ONE clip. `slices` is dense, position
/// IS the slice index (same convention `DrumSnap.pads` uses) — each entry
/// reuses `PadSnap` wholesale for its start/end/gain/pan/pitch/ADSR/reverse,
/// but its own `sample_file`/`name`/`used` fields are unused/always default
/// (the real sample lives at this struct's own `sample_file`/`name`).
pub const SlicerSnap = struct {
    sample_file: []const u8 = "",
    name: []const u8 = "",
    slices: []PadSnap = &.{},
    step_count: u8 = 16,
    /// Dense, parallel to `slices` — same "slice not fixed array" shape
    /// every other pattern-indexed field in this file uses.
    pattern: []const u64 = &.{},
    vel: []const []const u8 = &.{},
    swing: f32 = 50.0,
};

pub const RackSnap = struct {
    label: []const u8 = "synth",
    kind: InstrumentKind,
    synth: ?SynthSnap = null,
    sampler: ?SamplerSnap = null,
    drum: ?DrumSnap = null,
    slicer: ?SlicerSnap = null,
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
    /// before this field existed — no version bump needed.
    color: u8 = 0,
    /// Additive field: older files omit it and load ungrouped, matching
    /// every track's routing before grouping existed. Indexes into
    /// `Snapshot.groups` by position (see that field's own doc comment).
    group: ?u8 = null,
};

/// One track-grouping submix bus. Mirrors `Session.Group`. `Snapshot.groups`
/// is always exactly `engine_mod.max_groups` entries, dense — a slot's
/// position in the array IS its index (same convention `TrackSnap.group`
/// and the live `Session.groups`/`Engine.groups` fixed banks already use),
/// so an unused slot is written out as `.{}` (`active = false`) rather than
/// omitted, keeping every later slot's position stable.
pub const GroupSnap = struct {
    active: bool = false,
    name: []const u8 = "",
    fx_chain: []const FxUnitSnap = &.{},
};

pub const ClipKind = enum { melodic, drum };

/// One placed clip. Melodic clips carry a private note copy + loop length; drum
/// clips carry a step-count and per-pad bitmask. Mirrors `arrangement.Clip`.
pub const ClipSnap = struct {
    start_bar: u32,
    length_bars: u32,
    kind: ClipKind = .melodic,
    // melodic
    notes: []const NoteSnap = &.{},
    length_beats: f64 = 4.0,
    // drum
    // v11: widened from a [DrumMachine.max_pads]u64 fixed array to a slice —
    // std.json requires exact-length matches for fixed arrays, and max_pads
    // grew 8->64, so old files' 8-element arrays would otherwise fail to
    // parse. Missing/short entries are zero-filled on load (see clipFromSnap).
    drum_pattern: []const u64 = &.{},
    /// v4: per-step velocity bitplanes. Zero (or absent) = full velocity.
    /// v4, read-only since v12 — see `VariantSnap.vel_lo`'s doc comment.
    drum_vel_lo: []const u64 = &.{},
    drum_vel_hi: []const u64 = &.{},
    /// v12: per-pad, per-step velocity — see `VariantSnap.vel`'s doc comment.
    drum_vel: []const []const u8 = &.{},
    step_count: u8 = 16,
    /// v3: variant letter label (index) the clip was stamped from.
    variant: u8 = 0,
    /// v7: gain (dB) / pan (-1..1) automation breakpoints, clip-relative
    /// beats. Independent of `kind` — either clip type can carry them.
    gain_automation: []const AutomationPointSnap = &.{},
    pan_automation: []const AutomationPointSnap = &.{},
    /// v13: sparse synth-instrument-param automation lanes — supersedes
    /// `filter_cutoff_automation` below (kept, read-only, for the legacy
    /// remap; see `file_version`'s v13 doc comment). New saves never write
    /// the old field, matching v11/v12's own migration convention.
    synth_param_automation: []const SynthParamAutomationSnap = &.{},
    /// v7, read-only since v13 — see `synth_param_automation`'s doc comment.
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
    /// omit it and load as 4/4 — the prior behaviour.
    beats_per_bar: u8 = 4,
    /// v5: A/B loop region in bars (`loop_end_bar` exclusive). Older files
    /// omit it and load with no loop — the prior behaviour.
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
    /// groups — every track's `TrackSnap.group` reference is then
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

    const tracks = try aa.alloc(TrackSnap, session.project.tracks.items.len);
    for (session.project.tracks.items, tracks) |t, *ts| {
        ts.* = .{
            .name = t.name, .gain_db = t.gain_db, .pan = t.pan, .muted = t.muted,
            .soloed = t.soloed, .color = t.color, .group = t.group,
        };
    }

    // Dense, always max_groups entries so a slot's position in the array IS
    // its index — TrackSnap.group references that position directly, no
    // separate id field or remapping needed on either side.
    const groups = try aa.alloc(GroupSnap, engine_mod.max_groups);
    for (groups, 0..) |*gs, i| {
        if (session.groups[i]) |*g| {
            gs.* = .{ .active = true, .name = g.name, .fx_chain = try chainToSnap(aa, &g.fx, session.project.sample_rate) };
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
                    // Always saved — see the drum pad loop's comment above.
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
                .variant = dm.variant,
                .swing = dm.swing.load(.monotonic),
            };
            // Dense, always DrumMachine.max_pads entries — position IS the
            // pad index everywhere below, same "slice for JSON-length
            // safety, but positionally dense" shape VariantSnap's own doc
            // comment explains.
            const choke = try aa.alloc(u8, DrumMachine.max_pads);
            @memcpy(choke, &dm.choke_group);
            ds.choke_group = choke;

            const pattern = try aa.alloc(u64, DrumMachine.max_pads);
            for (pattern, 0..) |*p, i| p.* = dm.pattern[i].load(.acquire);
            ds.pattern = pattern;

            const variants = try aa.alloc(VariantSnap, dm.variant_count);
            for (variants, 0..) |*vs, vi| {
                // variantData reads the active slot from the live atomics.
                const v = dm.variantData(@intCast(vi));
                const vp = try aa.alloc(u64, DrumMachine.max_pads);
                @memcpy(vp, &v.pattern);
                vs.* = .{ .step_count = v.step_count, .pattern = vp, .vel = try velToSnap(aa, &v.vel) };
            }
            ds.variants = variants;

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
                        // whether the pad has user-loaded audio — a `:pad-rename`
                        // on a shipped-kit pad has no sample_file to carry the
                        // name through otherwise. exportSamples overwrites this
                        // with the same value for user-sample pads.
                        .name = try aa.dupe(u8, s.clipName()),
                    };
                } else {
                    ps.* = .{}; // used = false — unloaded, nothing else here is meaningful
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
                // Always saved — see the drum pad loop's identical comment
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

            rs.slicer = sls;
        },
    }

    rs.fx_chain = try chainToSnap(aa, &rack.fx, sample_rate);

    return rs;
}

/// Shared by track racks and the master bus — both hold a user-built `Fx`
/// chain. One FxUnitSnap per slot, in chain order.
fn chainToSnap(aa: std.mem.Allocator, fx: *const Fx, sample_rate: u32) ![]FxUnitSnap {
    const out = try aa.alloc(FxUnitSnap, fx.units.items.len);
    for (fx.units.items, out) |u, *us| {
        us.* = switch (u.payload) {
            .comp => |c| .{ .kind = .comp, .comp = .{
                .threshold_db = c.threshold_db, .ratio = c.ratio,
                .attack_ms = c.attack_ms, .release_ms = c.release_ms, .makeup_db = c.makeup_db,
                .sidechain_source = c.sidechain_source,
            } },
            .delay => |d| .{ .kind = .delay, .delay = .{
                .time_s = @as(f32, @floatFromInt(d.delay_frames)) / @as(f32, @floatFromInt(sample_rate)),
                .feedback = d.feedback, .mix = d.mix,
            } },
            .reverb => |r| .{ .kind = .reverb, .reverb = .{ .mix = r.mix, .room = r.room, .damp = r.damp } },
            .eq => |e| blk: {
                var gains: [eq_mod.num_eq_bands]f32 = undefined;
                for (&e.bands, 0..) |*b, i| gains[i] = b.gain_db;
                break :blk .{ .kind = .eq, .eq = .{ .band_gains = gains } };
            },
            .gate => |g| .{ .kind = .gate, .gate = .{
                .threshold_db = g.threshold_db, .attack_ms = g.attack_ms, .release_ms = g.release_ms,
            } },
            .sat => |s| .{ .kind = .sat, .sat = .{ .drive_db = s.drive_db, .out_db = s.out_db, .mix = s.mix } },
            .crush => |c| .{ .kind = .crush, .crush = .{ .bits = c.bits, .downsample = c.downsample, .mix = c.mix } },
            .chorus => |c| .{ .kind = .chorus, .chorus = .{ .rate_hz = c.rate_hz, .depth_ms = c.depth_ms, .mix = c.mix } },
            .phaser => |p| .{ .kind = .phaser, .phaser = .{
                .rate_hz = p.rate_hz, .depth = p.depth, .feedback = p.feedback, .mix = p.mix,
            } },
        };
        us.bypassed = u.bypassed;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Sample sidecar — user-loaded audio lives in "<stem>_samples/" next to the
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
    for (session.racks.items, racks, 0..) |rack, *rs, ti| {
        switch (rack.instrument) {
            .drum_machine => |*dm| for (0..DrumMachine.max_pads) |pi| {
                const s = if (dm.pads[pi]) |*sm| sm else continue; // unloaded pad — nothing to export
                const p = &s.pad;
                if (!p.user_sample) continue;
                const rel = try std.fmt.allocPrint(aa, "{s}/t{d}p{d}.wav", .{ sidecar, ti, pi });
                try writeSampleWav(aa, io, path, rel, &dir_ready, sr, p.samples);
                rs.drum.?.pads[pi].sample_file = rel;
                // .name already set by rackToSnap (unconditionally, for every pad).
            },
            .sampler => |*s| if (s.pad.user_sample) {
                const rel = try std.fmt.allocPrint(aa, "{s}/t{d}clip.wav", .{ sidecar, ti });
                try writeSampleWav(aa, io, path, rel, &dir_ready, sr, s.pad.samples);
                rs.sampler.?.pad.sample_file = rel;
                // .name already set by rackToSnap (unconditionally).
            },
            .slicer => |*sl| if (sl.user_sample) {
                const rel = try std.fmt.allocPrint(aa, "{s}/t{d}clip.wav", .{ sidecar, ti });
                try writeSampleWav(aa, io, path, rel, &dir_ready, sr, sl.samples);
                rs.slicer.?.sample_file = rel;
                // .name already set by rackToSnap (unconditionally).
            },
            else => {},
        }
    }
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

/// Resolve a path stored relative to the .wsj against the .wsj's directory.
/// Always returns an owned allocation.
fn joinWsjRel(allocator: std.mem.Allocator, wsj_path: []const u8, rel: []const u8) ![]const u8 {
    if (std.fs.path.dirname(wsj_path)) |d|
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ d, rel });
    return allocator.dupe(u8, rel);
}

/// A pad's fixed 8-byte name buffer with the space padding trimmed.
fn trimmedName(name: *const [8]u8) []const u8 {
    var end: usize = name.len;
    while (end > 0 and name[end - 1] == ' ') end -= 1;
    return name[0..end];
}

/// Copy a pattern player's notes into freshly allocated NoteSnaps. Notes are
/// read under the lock into a stack buffer, then the lock is released before
/// the allocator runs — avoids leaking the lock on OOM.
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

/// Serialise one arrangement clip. Melodic clips duplicate their notes into
/// freshly allocated NoteSnaps; drum clips copy the bitmask by value.
fn clipToSnap(aa: std.mem.Allocator, clip: ws_arrangement.Clip) !ClipSnap {
    var c: ClipSnap = .{ .start_bar = clip.start_bar, .length_bars = clip.length_bars };
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

fn automationToSnap(aa: std.mem.Allocator, points: []const AutomationPoint) ![]const AutomationPointSnap {
    const out = try aa.alloc(AutomationPointSnap, points.len);
    for (points, out) |p, *o| o.* = .{ .beat = p.beat, .value = p.value };
    return out;
}

fn synthToSnap(s: *const PolySynth) SynthSnap {
    return .{
        .waveform = s.waveform,
        .pulse_width = s.pulse_width,
        .detune_cents = s.detune_cents,
        .unison = s.unison,
        .unison_detune = s.unison_detune,
        .unison_spread = s.unison_spread,
        .osc_b_on = s.osc_b_on,
        .osc_b_waveform = s.osc_b_waveform,
        .osc_b_pulse_width = s.osc_b_pulse_width,
        .osc_b_semi = s.osc_b_semi,
        .osc_b_detune_cents = s.osc_b_detune_cents,
        .osc_b_level = s.osc_b_level,
        .osc_b_unison = s.osc_b_unison,
        .osc_b_unison_detune = s.osc_b_unison_detune,
        .attack_s = s.attack_s,
        .decay_s = s.decay_s,
        .sustain = s.sustain,
        .release_s = s.release_s,
        .filter_type = s.filter_type,
        .filter_cutoff = s.filter_cutoff,
        .filter_res = s.filter_res,
        .fenv_amount = s.fenv_amount,
        .fenv_attack_s = s.fenv_attack_s,
        .fenv_decay_s = s.fenv_decay_s,
        .fenv_sustain = s.fenv_sustain,
        .fenv_release_s = s.fenv_release_s,
        .lfo_shape = s.lfo_shape,
        .lfo_rate_hz = s.lfo_rate_hz,
        .lfo_depth = s.lfo_depth,
        .lfo_target = s.lfo_target,
        .voice_mode = s.voice_mode,
        .glide_s = s.glide_s,
        .sub_level = s.sub_level,
        .sub_shape = s.sub_shape,
        .noise_level = s.noise_level,
        .noise_color = s.noise_color,
        .mod_mode = s.mod_mode,
        .mod_amount = s.mod_amount,
        .gain = s.gain,
    };
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
                if (sls.sample_file.len == 0) continue; // default clip, nothing to restore
                const data = readWsjRel(allocator, io, path, sls.sample_file) orelse continue;
                defer allocator.free(data);
                const name = if (sls.name.len > 0) sls.name else std.fs.path.stem(sls.sample_file);
                // reset_slices=false: buildSession already applied every
                // slice's saved start/end/etc. from `sls.slices` — this must
                // only swap the audio bytes, not wipe that back out (see
                // Slicer.loadWav's own doc comment).
                sl.loadWav(data, name, false) catch continue;
                sl.user_sample = true;
            },
            else => {},
        }
    }
}

/// Read a sample file stored relative to the .wsj. Null on any error.
fn readWsjRel(allocator: std.mem.Allocator, io: std.Io, wsj_path: []const u8, rel: []const u8) ?[]u8 {
    const full = joinWsjRel(allocator, wsj_path, rel) catch return null;
    defer allocator.free(full);
    return std.Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(64 * 1024 * 1024)) catch null;
}

/// Display name for a restored sample: the saved name, else the file stem.
fn sampleName(ps: PadSnap) []const u8 {
    return if (ps.name.len > 0) ps.name else std.fs.path.stem(ps.sample_file);
}

fn buildSession(allocator: std.mem.Allocator, snap: *const Snapshot) !Session {
    // Reject files this build cannot represent; clamp what can be clamped.
    // Racks, tracks, and lanes are parallel arrays everywhere downstream
    // (engine slots, editor indices), so a mismatch is a malformed file.
    if (snap.version > file_version) return error.UnsupportedVersion;
    if (snap.tracks.len != snap.racks.len) return error.MalformedProject;
    if (snap.sample_rate < 8_000 or snap.sample_rate > 384_000) return error.InvalidSampleRate;

    var project = Project.init(allocator);
    errdefer project.deinit();
    project.sample_rate = snap.sample_rate;
    project.tempo_bpm = std.math.clamp(snap.tempo_bpm, 20.0, 400.0);
    project.beats_per_bar = std.math.clamp(snap.beats_per_bar, 1, 16);
    project.loop_start_bar = snap.loop_start_bar;
    project.loop_end_bar = snap.loop_end_bar;
    project.loop_enabled = snap.loop_enabled and snap.loop_end_bar > snap.loop_start_bar;

    for (snap.tracks) |t| {
        // Clamped to the palette's actual size (tui/style.zig's
        // track_palette, 7 entries) — the renderer already treats an
        // out-of-range color as "uncolored" gracefully, but clamping here
        // too matches this file's established hand-edited-.wsj hygiene.
        // `group` is only bound-checked here (< max_groups); whether that
        // slot is actually an active group gets swept below, once
        // `snap.groups` itself has been loaded.
        _ = try project.addTrack(.{
            .name = t.name, .gain_db = t.gain_db, .pan = t.pan,
            .muted = t.muted, .soloed = t.soloed, .color = @min(t.color, 7),
            .group = if (t.group) |g| (if (g < engine_mod.max_groups) g else null) else null,
        });
    }

    const sr = project.sample_rate;

    const engine = try allocator.create(Engine);
    errdefer allocator.destroy(engine);
    try engine.initInPlace(allocator, sr);
    errdefer engine.deinit();
    engine.loadProject(&project);

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

        // Duplicate the label; freed by Rack.deinit when owned_label = true.
        rack.label = try allocator.dupe(u8, rs.label);
        rack.owned_label = true;

        switch (rs.kind) {
            .empty => {},
            .poly_synth => {
                rack.instrument = .{ .poly_synth = PolySynth.init(sr) };
                // PatternPlayer holds a pointer into the heap-allocated Rack —
                // must be set AFTER the instrument lands in the rack.
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                if (rs.synth) |ss| {
                    applyToSynth(&rack.instrument.poly_synth, &ss);
                    rack.pattern_player.?.length_beats = ss.length_beats;
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
                    rack.pattern_player.?.length_beats = smp.length_beats;
                    loadNotes(&rack.pattern_player.?, smp.notes);
                    rack.pattern_player.?.setSwing(smp.swing);
                }
            },
            .drum_machine => {
                rack.instrument = .{ .drum_machine = try DrumMachine.init(allocator, sr, &engine.transport) };
                if (rs.drum) |ds| {
                    const dmp = &rack.instrument.drum_machine;
                    if (ds.variants.len > 0) {
                        // v3: restore the bank, masking each slot's stray bits
                        // the same way setStepCount does for the live pattern.
                        const count: u8 = @intCast(@min(ds.variants.len, DrumMachine.max_variants));
                        for (ds.variants[0..count], dmp.variants[0..count]) |vs, *slot| {
                            const sc = std.math.clamp(vs.step_count, 1, DrumMachine.max_steps);
                            slot.step_count = sc;
                            const mask = DrumMachine.stepMask(sc);
                            // vs.pattern/vel are slices (any length — see
                            // VariantSnap's doc comment), slot.* are fixed
                            // max_pads arrays: bound to whichever is shorter
                            // rather than zipping (a for-loop zip requires
                            // equal lengths and would panic on an older,
                            // shorter file). Pads past the file's own length
                            // stay at the Variant default (zero pattern,
                            // full velocity).
                            const pn = @min(vs.pattern.len, slot.pattern.len);
                            for (vs.pattern[0..pn], slot.pattern[0..pn]) |bits, *p| p.* = bits & mask;
                            applyVelSnap(&slot.vel, vs.vel, vs.vel_lo, vs.vel_hi);
                        }
                        dmp.variant_count = count;
                        dmp.variant = @min(ds.variant, count - 1);
                        // The legacy pattern/step_count fields mirror the
                        // active variant; the bank is the source of truth.
                        const active = dmp.variants[dmp.variant];
                        for (active.pattern, active.vel, 0..) |bits, vel_row, pi| {
                            dmp.pattern[pi].store(bits, .monotonic);
                            for (vel_row, 0..) |v, s| dmp.vel[pi][s].store(v, .monotonic);
                        }
                        dmp.setStepCount(active.step_count);
                    } else {
                        // v2: one variant from the legacy fields. Bits first:
                        // setStepCount masks off any pattern bits the file
                        // left above its own step count.
                        for (ds.pattern, 0..) |bits, pi| {
                            if (pi >= DrumMachine.max_pads) break;
                            dmp.pattern[pi].store(bits, .monotonic);
                        }
                        dmp.setStepCount(ds.step_count);
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
                    // (see PadSnap's doc comment) — an omitted/legacy entry
                    // (older files implicitly meant every one of their 8 was
                    // used, see the loop below) or an explicit `used = false`
                    // stays null, matching a pad nobody ever loaded.
                    for (ds.pads, 0..) |ps, pi| {
                        if (pi >= DrumMachine.max_pads) break;
                        // Pre-v11 files predate the "empty pad" concept
                        // entirely (every pad was always materialized, even
                        // an untouched one just carried the generated
                        // default clip) — `used` didn't exist yet, so its
                        // absence there means "was materialized", not the
                        // v11-and-later default of `false`. Version-gated,
                        // not inferred from array length (a v11+ file can
                        // legitimately have exactly 8 real entries with some
                        // genuinely unused).
                        const was_used = ps.used or snap.version < 11;
                        if (!was_used) continue;
                        // init() may have already materialized this pad (the
                        // default kit fills 0-7) — deinit it first so we don't
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
                    sl.setSwing(sls.swing);
                }
            },
        }

        if (rs.fx_chain) |fc| try applyFxChain(allocator, &rack.fx, fc, sr)
        else try applyLegacyFx(allocator, &rack.fx, rs.fx, sr);
        try racks.append(allocator, rack);
    }

    // One blank lane per track keeps the arrangement parallel to racks/tracks;
    // clips (if any) are placed below once the Session owns the arrangement.
    var arrangement: ws_arrangement.Arrangement = .{};
    errdefer arrangement.deinit(allocator);
    for (racks.items) |_| try arrangement.addLane(allocator);

    var self: Session = .{
        .allocator = allocator,
        .project = project,
        .engine = engine,
        .racks = racks,
        .retired_racks = .empty,
        .arrangement = arrangement,
    };
    for (self.racks.items, 0..) |rack, i| {
        self.syncTrackChain(@intCast(i), rack);
    }

    if (snap.master_fx_chain) |fc| try applyFxChain(allocator, &self.master_fx, fc, sr)
    else try applyLegacyFx(allocator, &self.master_fx, snap.master_fx, sr);
    self.syncMasterChain();

    // Groups: dense, positional (see GroupSnap's doc comment) — restore
    // exactly the active slots, push each to the engine, then sweep tracks
    // for any `.group` reference that turned out to point at a slot this
    // file never actually marked active (a hand-edited or truncated
    // `groups` array) and null it out, same "clamp on load" hygiene the
    // color/velocity/pad fields already follow.
    const group_count = @min(snap.groups.len, engine_mod.max_groups);
    for (snap.groups[0..group_count], 0..) |gs, i| {
        if (!gs.active) continue;
        const idx: u8 = @intCast(i);
        self.groups[idx] = .{ .name = try allocator.dupe(u8, gs.name) };
        try applyFxChain(allocator, &self.groups[idx].?.fx, gs.fx_chain, sr);
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
        for (ls.clips) |cs| try lane.place(allocator, try clipFromSnap(allocator, cs));
    }
    self.setSongMode(snap.song_mode);

    return self;
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
/// live `[max_pads][max_steps]u8` velocity array.
fn velToSnap(
    aa: std.mem.Allocator,
    vel: *const [DrumMachine.max_pads][DrumMachine.max_steps]u8,
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
    dst: *[DrumMachine.max_pads][DrumMachine.max_steps]u8,
    vel: []const []const u8,
    vel_lo: []const u64,
    vel_hi: []const u64,
) void {
    if (vel.len > 0) {
        const pn = @min(vel.len, dst.len);
        for (vel[0..pn], dst[0..pn]) |row, *dst_row| {
            const sn = @min(row.len, dst_row.len);
            @memcpy(dst_row[0..sn], row[0..sn]);
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

/// Rebuild an arrangement clip from its snapshot. Melodic clips copy notes
/// through a stack buffer into a fresh owned allocation; drum clips are inline.
fn clipFromSnap(allocator: std.mem.Allocator, cs: ClipSnap) !ws_arrangement.Clip {
    var out: ws_arrangement.Clip = switch (cs.kind) {
        .melodic => blk: {
            var tmp: [pattern_mod.max_notes]pattern_mod.Note = undefined;
            const count = @min(cs.notes.len, @as(usize, pattern_mod.max_notes));
            for (cs.notes[0..count], tmp[0..count]) |n, *o| o.* = sanitizeNote(n);
            break :blk try ws_arrangement.Clip.initMelodic(
                allocator, cs.start_bar, cs.length_bars, tmp[0..count], cs.length_beats,
            );
        },
        .drum => blk2: {
            var d: ws_arrangement.Clip.Drum = .{
                .pattern = padBitplane(cs.drum_pattern),
                .step_count = cs.step_count,
                .variant = @min(cs.variant, DrumMachine.max_variants - 1),
            };
            applyVelSnap(&d.vel, cs.drum_vel, cs.drum_vel_lo, cs.drum_vel_hi);
            break :blk2 ws_arrangement.Clip.initDrum(cs.start_bar, cs.length_bars, d);
        },
    };
    errdefer out.deinit(allocator);
    out.automation.gain = try automationFromSnap(allocator, cs.gain_automation, -60.0, 12.0);
    out.automation.pan = try automationFromSnap(allocator, cs.pan_automation, -1.0, 1.0);
    try applySynthParamAutomationSnap(allocator, &out.automation, cs.synth_param_automation, cs.filter_cutoff_automation);
    return out;
}

/// Load a clip's synth-param automation lanes. A v13 `synth_param_automation`
/// takes priority when present; a pre-v13 file only carries the old
/// single-lane `filter_cutoff_automation`, remapped onto param_id 21 — same
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
/// editor will enforce and sorting by beat — a hand-edited file has no
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
        .beat = @max(0.0, s.beat),
        .value = std.math.clamp(s.value, lo, hi),
    };
    std.mem.sort(AutomationPoint, out, {}, struct {
        fn lessThan(_: void, a: AutomationPoint, b: AutomationPoint) bool {
            return a.beat < b.beat;
        }
    }.lessThan);
    return out;
}

/// Apply a pad snapshot onto a live Pad, clamping every field to the same
/// ranges `adjustParam` enforces. Unclamped values from a hand-edited file
/// would otherwise trip adjustParam's clamp bounds (lower > upper) on the
/// audio thread, or index past buffers in the waveform view.
fn applyPadSnap(p: *Pad, ps: PadSnap) void {
    p.gain            = std.math.clamp(ps.gain, 0.0, 2.0);
    p.pan             = std.math.clamp(ps.pan, -1.0, 1.0);
    p.pitch_semitones = std.math.clamp(ps.pitch_semitones, -24.0, 24.0);
    p.start_norm      = std.math.clamp(ps.start_norm, 0.0, 0.99);
    p.end_norm        = std.math.clamp(ps.end_norm, p.start_norm + 0.01, 1.0);
    p.reverse         = ps.reverse;
    p.attack_s        = std.math.clamp(ps.attack_s, 0.0, 5.0);
    p.decay_s         = std.math.clamp(ps.decay_s, 0.0, 5.0);
    p.sustain         = std.math.clamp(ps.sustain, 0.0, 1.0);
    p.release_s       = std.math.clamp(ps.release_s, 0.001, 5.0);
}

/// A NoteSnap with pitch/velocity/times forced into playable ranges.
fn sanitizeNote(n: NoteSnap) pattern_mod.Note {
    return .{
        .pitch = @intCast(@min(n.pitch, 127)),
        .start_beat = @max(0.0, n.start_beat),
        .duration_beat = @max(0.0, n.duration_beat),
        .velocity = std.math.clamp(n.velocity, 0.0, 1.0),
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

/// Apply a synth snapshot onto a live PolySynth, clamping every numeric
/// field to the same ranges `adjustParam` enforces — mirrors
/// `applyPadSnap`'s reasoning: a hand-edited or corrupted file could
/// otherwise smuggle an out-of-range value (e.g. unison 0 or 255, a
/// negative attack time) straight onto the audio thread. Enum fields
/// (waveform, filter_type, mod_mode, …) need no clamp — `std.json` already
/// rejects any value that isn't one of the declared tags at parse time.
fn applyToSynth(s: *PolySynth, ss: *const SynthSnap) void {
    const clamp = std.math.clamp;
    s.waveform = ss.waveform;
    s.pulse_width = clamp(ss.pulse_width, 0.01, 0.99);
    s.detune_cents = clamp(ss.detune_cents, -100.0, 100.0);
    s.unison = @intCast(clamp(@as(i32, ss.unison), 1, 16));
    s.unison_detune = clamp(ss.unison_detune, 0.0, 100.0);
    s.unison_spread = clamp(ss.unison_spread, 0.0, 1.0);
    s.osc_b_on = ss.osc_b_on;
    s.osc_b_waveform = ss.osc_b_waveform;
    s.osc_b_pulse_width = clamp(ss.osc_b_pulse_width, 0.01, 0.99);
    s.osc_b_semi = clamp(ss.osc_b_semi, -24.0, 24.0);
    s.osc_b_detune_cents = clamp(ss.osc_b_detune_cents, -100.0, 100.0);
    s.osc_b_level = clamp(ss.osc_b_level, 0.0, 1.0);
    s.osc_b_unison = @intCast(clamp(@as(i32, ss.osc_b_unison), 1, 16));
    s.osc_b_unison_detune = clamp(ss.osc_b_unison_detune, 0.0, 100.0);
    s.attack_s = clamp(ss.attack_s, 0.001, 5.0);
    s.decay_s = clamp(ss.decay_s, 0.001, 5.0);
    s.sustain = clamp(ss.sustain, 0.0, 1.0);
    s.release_s = clamp(ss.release_s, 0.001, 10.0);
    s.filter_type = ss.filter_type;
    s.filter_cutoff = clamp(ss.filter_cutoff, 20.0, 20_000.0);
    s.filter_res = clamp(ss.filter_res, 0.0, 1.0);
    s.fenv_amount = clamp(ss.fenv_amount, -4.0, 4.0);
    s.fenv_attack_s = clamp(ss.fenv_attack_s, 0.001, 5.0);
    s.fenv_decay_s = clamp(ss.fenv_decay_s, 0.001, 5.0);
    s.fenv_sustain = clamp(ss.fenv_sustain, 0.0, 1.0);
    s.fenv_release_s = clamp(ss.fenv_release_s, 0.001, 10.0);
    s.lfo_shape = ss.lfo_shape;
    s.lfo_rate_hz = clamp(ss.lfo_rate_hz, 0.01, 20.0);
    s.lfo_depth = clamp(ss.lfo_depth, 0.0, 1.0);
    s.lfo_target = ss.lfo_target;
    s.voice_mode = ss.voice_mode;
    s.glide_s = clamp(ss.glide_s, 0.0, 10.0);
    s.sub_level = clamp(ss.sub_level, 0.0, 1.0);
    s.sub_shape = ss.sub_shape;
    s.noise_level = clamp(ss.noise_level, 0.0, 1.0);
    s.noise_color = clamp(ss.noise_color, 0.0, 1.0);
    s.mod_mode = ss.mod_mode;
    s.mod_amount = clamp(ss.mod_amount, 0.0, 8.0);
    s.gain = clamp(ss.gain, 0.01, 1.0);
}

/// Rebuild a live chain from v10 unit snaps, in file order. Shared by track
/// racks and the master bus — both hold a user-built `Fx` chain. Snaps past
/// the chain cap are dropped (only reachable by hand-editing the file).
/// A unit whose params field is null keeps its defaults.
fn applyFxChain(allocator: std.mem.Allocator, fx_out: *Fx, chain: []const FxUnitSnap, sr: u32) !void {
    for (chain) |us| {
        if (fx_out.units.items.len >= Fx.max_units) break;
        const kind: rack_mod.FxKind = switch (us.kind) {
            .gate => .gate, .comp => .comp, .eq => .eq,
            .sat => .sat, .crush => .crush, .chorus => .chorus,
            .phaser => .phaser, .delay => .delay, .reverb => .reverb,
        };
        const unit = try fx_out.insert(allocator, fx_out.units.items.len, kind, sr);
        unit.bypassed = us.bypassed;
        switch (unit.payload) {
            .comp => |*c| if (us.comp) |cs| {
                c.threshold_db = cs.threshold_db;
                c.ratio = cs.ratio;
                c.attack_ms = cs.attack_ms;
                c.release_ms = cs.release_ms;
                c.makeup_db = cs.makeup_db;
                c.sidechain_source = if (cs.sidechain_source) |src|
                    @min(src, engine_mod.max_tracks - 1)
                else
                    null;
            },
            .delay => |*d| if (us.delay) |ds| {
                d.setTime(ds.time_s);
                d.feedback = ds.feedback;
                d.mix = ds.mix;
            },
            .reverb => |*r| if (us.reverb) |rs| {
                r.mix = rs.mix;
                r.room = rs.room;
                r.damp = rs.damp;
            },
            .eq => |*e| if (us.eq) |es| {
                e.setAllBands(es.band_gains);
                // Legacy EQ-only bypass maps onto the slot's generic one.
                if (es.bypass) unit.bypassed = true;
            },
            .gate => |*g| if (us.gate) |gs| {
                g.threshold_db = gs.threshold_db;
                g.attack_ms = gs.attack_ms;
                g.release_ms = gs.release_ms;
            },
            .sat => |*s| if (us.sat) |ss| {
                s.* = .{ .drive_db = ss.drive_db, .out_db = ss.out_db, .mix = ss.mix };
            },
            .crush => |*c| if (us.crush) |cs| {
                c.* = .{ .bits = cs.bits, .downsample = cs.downsample, .mix = cs.mix };
            },
            .chorus => |*c| if (us.chorus) |cs| {
                c.rate_hz = cs.rate_hz;
                c.depth_ms = cs.depth_ms;
                c.mix = cs.mix;
            },
            .phaser => |*p| if (us.phaser) |ps| {
                p.rate_hz = ps.rate_hz;
                p.depth = ps.depth;
                p.feedback = ps.feedback;
                p.mix = ps.mix;
            },
        }
    }
}

/// v9-and-older fallback: expand the fixed struct-of-optionals rack into
/// unit snaps in the order the old `Fx.chain()` hard-wired, then load them
/// through the same path as v10 chains.
fn applyLegacyFx(allocator: std.mem.Allocator, fx_out: *Fx, fx: FxSnap, sr: u32) !void {
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
    try applyFxChain(allocator, fx_out, snaps[0..n], sr);
}

// ---------------------------------------------------------------------------
// Tests — in-memory round-trip (no file I/O; std.Io not needed)
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
    try testing.expectEqual(@as(u8, 16), dr.step_count);
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
            .eq = .{ .band_gains = [_]f32{2.0} ** eq_mod.num_eq_bands, .bypass = false },
        },
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    // The v9 rack hard-wired comp before eq — the rebuilt chain keeps that.
    try testing.expectEqual(@as(usize, 2), session.master_fx.units.items.len);
    const comp = &session.master_fx.units.items[0].payload.comp;
    try testing.expectApproxEqAbs(@as(f32, -12.0), comp.threshold_db, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3.0), comp.ratio, 1e-4);
    const eq = &session.master_fx.units.items[1].payload.eq;
    try testing.expectApproxEqAbs(@as(f32, 2.0), eq.bands[0].gain_db, 1e-4);
    // Both units should have reached the engine's master chain.
    try testing.expectEqual(@as(usize, 2), session.engine.master_chain_len);
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
    try testing.expectEqual(@as(usize, 4), session.engine.master_chain_len);
}

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
    try testing.expectEqual(@as(?u16, 3), session.racks.items[0].fx.units.items[0].payload.comp.sidechain_source);
    try testing.expectEqual(@as(?u16, 3), session.engine.track_sidechain[0][0]); // no instrument -> comp is slot 0

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
    try testing.expectEqual(@as(?u16, engine_mod.max_tracks - 1), session2.racks.items[0].fx.units.items[0].payload.comp.sidechain_source);
}

test "save/load round-trip persists a compressor's sidechain_source" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const wsj_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/sidechain.wsj", .{&tmp.sub_path});

    var session = try Session.initDefault(testing.allocator);
    defer session.deinit();
    const unit = try session.racks.items[0].fx.insert(testing.allocator, 0, .comp, session.project.sample_rate);
    unit.payload.comp.sidechain_source = 7;

    try save(testing.allocator, &session, testing.io, wsj_path);
    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    try testing.expectEqual(@as(?u16, 7), loaded.racks.items[0].fx.units.items[0].payload.comp.sidechain_source);
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
    try testing.expectEqual(@as(usize, 5), loaded.engine.master_chain_len);
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
    try testing.expectEqual(@as(u32, 2), c0.start_bar);
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

test "clipToSnap/clipFromSnap round-trip gain/pan automation" {
    const testing = std.testing;
    var clip = ws_arrangement.Clip.initDrum(0, 1, .{
        .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16,
    });
    try automation_mod.setPoint(testing.allocator, &clip.automation.gain, 0.0, -6.0);
    try automation_mod.setPoint(testing.allocator, &clip.automation.gain, 2.0, 0.0);
    try automation_mod.setPoint(testing.allocator, &clip.automation.pan, 0.0, -1.0);
    defer clip.deinit(testing.allocator);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const snap = try clipToSnap(arena.allocator(), clip);
    try testing.expectEqual(@as(usize, 2), snap.gain_automation.len);
    try testing.expectApproxEqAbs(@as(f32, -6.0), snap.gain_automation[0].value, 1e-6);
    try testing.expectEqual(@as(usize, 1), snap.pan_automation.len);

    var restored = try clipFromSnap(testing.allocator, snap);
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
        .{ .beat = 3.0, .value = 100.0 }, // out of gain range — clamps to 12
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

test "buildSession: drum variant bank round-trips; v2 files get one variant" {
    const testing = std.testing;

    // v3: two variants, B active, with stray bits above each step count that
    // the loader must mask off.
    const variants = [_]VariantSnap{
        .{ .step_count = 16, .pattern = blk: {
            var p = [_]u64{0} ** DrumMachine.max_pads;
            p[0] = 1 | (1 << 20); // bit 20 is past 16 steps — stray
            break :blk &p;
        } },
        .{ .step_count = 32, .pattern = blk: {
            var p = [_]u64{0} ** DrumMachine.max_pads;
            p[1] = 1 << 31;
            break :blk &p;
        } },
    };
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "drums" }},
        .racks = &.{.{
            .label = "drums",
            .kind = .drum_machine,
            .drum = .{ .variants = &variants, .variant = 1 },
        }},
    };

    var session = try buildSession(testing.allocator, &snap);
    defer session.deinit();

    const dm = &session.racks.items[0].instrument.drum_machine;
    try testing.expectEqual(@as(u8, 2), dm.variant_count);
    try testing.expectEqual(@as(u8, 1), dm.variant);
    try testing.expectEqual(@as(u8, 32), dm.step_count);
    try testing.expect(dm.stepActive(1, 31)); // live = variant B
    dm.selectVariant(0);
    try testing.expectEqual(@as(u8, 16), dm.step_count);
    try testing.expect(dm.stepActive(0, 0));
    try testing.expect(!dm.stepActive(0, 20)); // stray bit was masked

    // v2 file shape: no `variants` — a single variant from the legacy fields.
    const legacy: Snapshot = .{
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
    try testing.expectEqual(@as(u8, 31), v.vel[0][1]);
}

test "buildSession: v12 vel field round-trips a granular 0-127 value" {
    const testing = std.testing;

    var vel_row = [_]u8{DrumMachine.vel_full} ** DrumMachine.max_steps;
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
    try testing.expectEqual(@as(u8, 64), dm.step_count);
    try testing.expect(dm.stepActive(0, 63));
    try testing.expectEqual(@as(u64, 1) << 63, dm.pattern[0].load(.monotonic));
}

test "buildSession: groups round-trip name, FX chain, and track membership" {
    const testing = std.testing;

    var groups: [engine_mod.max_groups]GroupSnap = [_]GroupSnap{.{}} ** engine_mod.max_groups;
    groups[2] = .{
        .active = true,
        .name = "drum bus",
        .fx_chain = &.{.{ .kind = .comp, .comp = .{ .threshold_db = -12.0 } }},
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
    try testing.expectEqual(@as(usize, 1), session.engine.groups[2].chain_len);

    try testing.expectEqual(@as(?u8, 2), session.project.tracks.items[0].group);
    try testing.expectEqual(@as(?u8, null), session.project.tracks.items[1].group);
    try testing.expectEqual(@as(?u8, 2), session.engine.tracks[0].group);

    // Unused slots (0, 1, 3..) stay unloaded — no phantom groups.
    try testing.expect(session.groups[0] == null);
    try testing.expect(!session.engine.groups[0].active);
}

test "buildSession: a track referencing a slot the file never marked active loads ungrouped" {
    const testing = std.testing;
    const snap: Snapshot = .{
        .tracks = &.{.{ .name = "t", .group = 5 }}, // groups is empty — slot 5 was never active
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
    // hihat/open pairing — the load path is the source of truth.
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

    var clip = try clipFromSnap(testing.allocator, cs);
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

    // Emulate :load-pad — user audio on pad 3, with a tweaked param.
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

    // A plain :pad-rename — no new sample, still the shipped kick sample.
    dm.pads[0].?.rename("808");
    try testing.expectEqualStrings("snare", dm.padName(1)); // untouched pad unaffected

    try save(testing.allocator, &session, testing.io, wsj_path);

    var loaded = try load(testing.allocator, testing.io, wsj_path);
    defer loaded.deinit();
    const ldm = &loaded.racks.items[0].instrument.drum_machine;
    try testing.expectEqualStrings("808", ldm.padName(0));
    try testing.expectEqualStrings("snare", ldm.padName(1));
    // Still the shipped-kit sample — renaming alone doesn't flag user_sample.
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

    // Emulate :load-sample — swap the generated clip for user audio.
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

        // Every fixture's Snapshot has parallel tracks/racks/arrangement —
        // buildSession already enforces this, but check it here too so a
        // regression shows up against the fixture name, not just an error.
        try testing.expectEqual(session.project.tracks.items.len, session.racks.items.len);
    }

    // Guards against a misconfigured path silently turning this into a no-op.
    try testing.expectEqual(@as(usize, 13), count);
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
    // Pads 0-7 stay whatever init()'s default kit already gave them — a
    // v11 file's `used: false` doesn't retroactively unmaterialize a pad
    // the shipped kit always loads; it only means "the file itself didn't
    // touch this one".
    for (0..8) |i| try testing.expect(dm.pads[i] != null);
}

# .wsj project format

A `.wsj` file is pretty-printed JSON: a `Snapshot` of the session (tracks,
racks/instruments, arrangement, master FX) plus a `version` field. The
authoritative type definitions live in `src/persist.zig`; this doc is the
human-readable map of that file, not a replacement for it.

## Saving

`persist.save` writes to `<path>.tmp` and renames it over the target, so a
crash or power loss mid-write can never corrupt an existing project file:
the rename is the only step that touches the real path, and it's atomic on
every platform wstudio targets.

User-loaded sample audio (a drum pad or sampler clip loaded from a WAV, as
opposed to the shipped/generated kit) is exported alongside the `.wsj` into
a sidecar directory, not embedded in the JSON. See
[Sample sidecar](#sample-sidecar) below.

## Versioning policy

`persist.zig`'s `file_version` (currently 21) is the newest format version
this build can write and read. Loading enforces one rule:

- **A file whose `version` is newer than `file_version` is hard-rejected**
  (`error.UnsupportedVersion`): an older build refuses to guess at a
  newer format rather than silently mis-load it.

Everything older loads, because of how fields are added:

- **Adding an optional field with a sane default requires no version
  bump.** An older file missing the field parses fine against the newer
  `Snapshot` struct (the field just takes its `= default` value), and
  `std.json`'s `ignore_unknown_fields = true` means a newer file's extra
  field is silently skipped by an older build instead of erroring. Most
  fields added since v5 (mono voice mode, pattern swing, per-pad choke
  groups, bounce bit depth, and more) shipped this way, silently, with no
  version bump and no changelog entry needed here. Check the field's own
  doc comment in `persist.zig` for when it was added if it matters.
- **Only bump `file_version` for a breaking or semantic change**: a field
  whose *absence* can't be given a backward-compatible default (the shape
  of a whole sub-structure changes, e.g. v10's FX rack), or where old data
  needs active migration on load rather than just defaulting. Each bump
  gets a row in the table below explaining exactly what older files load
  as instead. That table is the canonical version history; `persist.zig`
  keeps only per-field migration comments and points here.

The v1-v10-in-a-week churn during initial development is done; this policy
is what keeps future additions from needing another bump merely because
they showed up in the same week as one.

## Version history

| Version | Added |
|---|---|
| v1 | Baseline: synth/sampler/drum-machine params, piano-roll notes, drum patterns, per-track gain/pan/mute/solo, tempo. No arrangement (single live pattern per track only). |
| v2 | The arrangement (song timeline, `song_mode`). v1 files load with an empty arrangement, pattern mode. |
| v3 | Drum pattern variants (`DrumSnap.variants` + active index) and the variant label on drum clips. v2 files load as a single variant built from the legacy `pattern`/`step_count` fields (still written on every save, so files stay hand-editable). |
| v4 | Per-step drum velocity (`vel_lo`/`vel_hi` bitplanes), per-machine swing, time signature numerator (`beats_per_bar`). Older files load at full velocity, swing 50 (straight), 4/4. |
| v5 | User sample persistence (`sample_file`/`name` on a pad, exported to the sample sidecar, see below) and the A/B loop region (`loop_enabled`/`loop_start_bar`/`loop_end_bar`). Older files keep the shipped/generated clip and no loop. |
| v6 | Master bus FX rack (`Snapshot.master_fx`). Older files load with no master FX. |
| v7 | Per-clip gain/pan automation (`ClipSnap.gain_automation`/`pan_automation`). Older files load with no automation (clips play at the track's manual gain/pan). |
| v8 | Per-pad choke groups (`DrumSnap.choke_group`). Older files load every pad ungrouped. |
| v9 | Five new FX units: gate, saturator, crusher, chorus, phaser. Older files load with those slots empty. |
| v10 | The fixed nine-slot FX rack (`FxSnap`, one optional per unit kind) becomes a user-built ordered chain (`fx_chain`: a list of `FxUnitSnap` in signal-flow order, duplicates allowed, per-unit bypass). Older files carry the struct-of-optionals shape instead; loading synthesizes a chain in the old hard-wired order (gate → comp → eq → sat → crush → chorus → phaser → delay → reverb), matching the audible behaviour those files always had. |
| v11 | The drum machine's pad cap grew 8→64 (`DrumMachine.max_pads`), MPC-style banks of 8 for the UI. Every pad-indexed field (`DrumSnap`/`VariantSnap`/`ClipSnap`'s `pattern`/`vel_lo`/`vel_hi`/`choke_group`/`pads`) changed from a fixed-length array to a slice, since `std.json` requires exact-length matches for fixed arrays and a fixed 8-element array can't parse against a 64-element one. `PadSnap` gained `used: bool` so a pad can be "never loaded" (null `DrumMachine.pads[i]`, lazily materialized) instead of every pad always existing. Older files, which had no concept of an empty pad, load with every one of their (at most 8) entries treated as used regardless of the field's default - version-gated (`snap.version < 11`), not inferred from array length, since a v11+ file can legitimately have exactly 8 real entries with some genuinely unused. |
| v12 | Per-step drum velocity widened from the old 2-bit `vel_lo`/`vel_hi` bitplanes (4 levels: 100/75/50/25%) to a plain 0-127 byte per step (`VariantSnap.vel`/`ClipSnap.drum_vel`, nested per-pad slices of per-step values). `vel_lo`/`vel_hi` are kept, read-only, purely so an older file's data can be remapped onto the new scale via `DrumMachine.legacyVelToNew` - new saves never write them. |
| v13 | The single `filter_cutoff_automation` clip lane generalizes to a sparse list of synth-instrument-param automation lanes (`ClipSnap.synth_param_automation`, one entry per automated `PolySynth.setParamAbsolute` id - see `dsp/synth.zig`'s `automatable_params`, ~30 continuous params: LFO rate/depth, envelope times, unison, etc., not just cutoff). `filter_cutoff_automation` is kept, read-only, purely so an older file's cutoff lane remaps onto the new list's `param_id = 21` entry - new saves never write it. |
| v14 | The EQ turns from a 10-band graphic EQ (fixed ISO center frequencies, gain-only) into an 8-band parametric one (`EqSnap.bands`: freq/Q/gain; peak/lowpass/highpass kind + slope arrived later as additive fields). `band_gains` (the old 10-element gain array) is kept, read-only, purely so an older file remaps by nearest legacy ISO frequency - new saves never write it. |
| v15 | The multiband compressor FX unit (`FxUnitSnap.mb_comp`: crossovers, shared attack/release, classic/OTT style, mix, per-band thresh/ratio/makeup). Purely additive; the bump makes pre-v15 builds hard-reject a file using the new kind instead of failing on an unknown enum name. |
| v16 | The OTT FX unit (`FxUnitSnap.ott`: depth/time/in/out gain over fixed multiband tuning, see `dsp/ott.zig`). Purely additive, same rationale as v15. |
| v17 | The synth mod matrix (`SynthSnap.mod_matrix`: up to 8 rows of source/dest/depth, see `PolySynth.ModRow`). The old fixed mod routes (`fenv_amount`, `lfo_depth`, `lfo_target`) are kept, read-only, purely so a pre-v17 file's routing migrates onto matrix rows 1-2 via `PolySynth.legacyModRows` - new saves write them at defaults. `mod_matrix` being null (absent) is what marks a file as pre-v17 for that migration; an empty list is honored as "no routing". Automation lanes targeting the retired param ids 23 (fenv amount) / 30 (LFO depth) silently no-op after loading. |
| v18 | The frequency shifter FX unit (`FxUnitSnap.freq_shift`: signed `shift_hz` + `mix`, see `dsp/freq_shift.zig`). Purely additive; the bump makes pre-v18 builds hard-reject a file using the new kind instead of failing on an unknown enum name, same rationale as v15/v16. |
| v19 | The flanger FX unit (`FxUnitSnap.flanger`: `rate_hz`/`depth`/`feedback`/`mix` over a modulated delay line, see `dsp/flanger.zig`). Purely additive, same rationale as v15/v16/v18. |
| v20 | The wavetable oscillator: a new `Waveform.wavetable` variant (`waveform`/`osc_b_waveform`/`osc_c_waveform` can now hold it), same enum-growth rationale as v15/v16/v18/v19 - the bump makes pre-v20 builds hard-reject a file using it instead of failing on an unknown enum name. Frame-scan position (`SynthSnap.wt_pos`/`osc_b_wt_pos`/`osc_c_wt_pos`) and the sidecar path fields (`wt_file`/`osc_b_wt_file`/`osc_c_wt_file`, see below) are purely additive and would not have needed a bump on their own. |
| v21 | The tape FX unit (`FxUnitSnap.tape`: `wow_rate_hz`/`wow_depth`/`flutter_rate_hz`/`flutter_depth`/`mix` over a dual-LFO modulated delay, see `dsp/tape.zig`). Purely additive, same rationale as v15/v16/v18/v19. |

Since v11, every field added has been the additive/no-bump kind described
above (v12/v13/v14 above are the exceptions - genuine semantic changes, not
additive). Check `persist.zig`'s per-field doc comments for specifics (e.g.
`Sampler.mono`, `PatternPlayer.swing`, `:bounce`'s bit-depth option).

`test/fixtures/wsj/v1.wsj` through `v21.wsj` are tiny, hand-written fixtures
of each historical shape (no `variants` for v2, no `master_fx_chain` for v9,
etc.), one per row of the table above. `persist.zig`'s "golden-file corpus"
test loads every file in that directory and fails loudly if one stops
parsing - add a new fixture there alongside any future version bump.

## Sample sidecar

A pad's audio is either the shipped/generated default (nothing written to
disk beyond the params) or **user-loaded**, in which case saving exports it
as a mono 16-bit WAV into `<stem>_samples/` next to the `.wsj` (`<stem>` is
the project filename without its extension, so `song.wsj` becomes
`song_samples/`, created lazily, only once a session actually holds a user
sample). Each file is named by its position: `t<track>p<pad>.wav` for a
drum pad, `t<track>clip.wav` for a standalone sampler clip, `t<track>oscA.wav`/
`oscB.wav`/`oscC.wav` for a synth oscillator's imported wavetable (v20 - same
sidecar directory, since it's the same "variable-size audio blob that
shouldn't live inline in the JSON" problem). All are written through the
same `.tmp` + rename dance as the project file itself, so a crash never
leaves a truncated sample behind.

The pad's `sample_file` field stores a path *relative to the `.wsj`*, never
absolute, so a project directory can be moved or copied as a unit and still
load correctly.

Loading is best-effort per pad: a missing or unreadable sample file leaves
that pad on its shipped/generated audio with every other param (gain, ADSR,
trim, and the rest) still applied from the snapshot. A stale or deleted
sidecar file degrades one pad's sound; it never fails the whole project
load.

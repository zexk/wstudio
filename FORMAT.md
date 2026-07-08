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

`persist.zig`'s `file_version` (currently 10) is the newest format version
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
  gets a `vN adds ...` paragraph in `persist.zig`'s top-of-file doc comment
  explaining exactly what older files load as instead. That comment block
  is the canonical version history; the table below mirrors it.

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

Since v10, every field added has been the additive/no-bump kind described
above. Check `persist.zig`'s per-field doc comments for specifics (e.g.
`Sampler.mono`, `PatternPlayer.swing`, `:bounce`'s bit-depth option).

## Sample sidecar

A pad's audio is either the shipped/generated default (nothing written to
disk beyond the params) or **user-loaded**, in which case saving exports it
as a mono 16-bit WAV into `<stem>_samples/` next to the `.wsj` (`<stem>` is
the project filename without its extension, so `song.wsj` becomes
`song_samples/`, created lazily, only once a session actually holds a user
sample). Each file is named by its position: `t<track>p<pad>.wav` for a
drum pad, `t<track>clip.wav` for a standalone sampler clip. Both are
written through the same `.tmp` + rename dance as the project file itself,
so a crash never leaves a truncated sample behind.

The pad's `sample_file` field stores a path *relative to the `.wsj`*, never
absolute, so a project directory can be moved or copied as a unit and still
load correctly.

Loading is best-effort per pad: a missing or unreadable sample file leaves
that pad on its shipped/generated audio with every other param (gain, ADSR,
trim, and the rest) still applied from the snapshot. A stale or deleted
sidecar file degrades one pad's sound; it never fails the whole project
load.

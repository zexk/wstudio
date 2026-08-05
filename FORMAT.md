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
opposed to a generated kit pad) is exported alongside the `.wsj` into
a sidecar directory, not embedded in the JSON. See
[Sample sidecar](#sample-sidecar) below.

## Versioning policy

`persist.zig`'s `file_version` (currently 36) is the only format version
this build writes or reads. Loading enforces one rule:

- **A file whose `version` is not exactly `file_version` is hard-rejected**
  (`error.UnsupportedVersion`). There are no migration paths: wstudio
  reached 1.0 with no released installs, so every pre-1.0 `.wsj` was a
  dev-only artifact and carrying migrations for them bought nothing.

Fields still evolve without a bump:

- **Adding an optional field with a sane default requires no version
  bump.** A file written by a build predating the field parses fine (the
  field takes its `= default` value), and `std.json`'s
  `ignore_unknown_fields = true` means a newer file's extra field is
  skipped rather than erroring. Most fields (mono voice mode, pattern
  swing, per-pad choke groups, bounce bit depth, and more) shipped this
  way. Check the field's own doc comment in `persist_types.zig` if the
  default matters.
- **Adding an FX kind, instrument kind, or EQ band kind requires no bump
  either.** Those three enums (`FxKind`, `InstrumentKind`,
  `EqBandKindSnap`) decode by name into an `unknown` member instead of
  failing the parse, so a build that predates the kind drops that one FX
  slot, loads that track empty, or falls back to a peak band, and opens
  the rest of the project. Historically each new unit cost a bump purely
  because `std.json` hard-errors on an unrecognized enum name.
- **Bump `file_version` for a breaking or semantic change**: a field whose
  *absence* can't be given a backward-compatible default, or a
  sub-structure changing shape. A bump makes every older file unloadable
  by design - with no migrations left, that is now a destructive act, so
  prefer an additive field or an open enum.

## Snapshot notes

Bundled wavetable identities (`SynthSnap.wt_bundled` and OSC B/C counterparts)
are additive fields; missing values select `basic`.

`SynthParamAutomationSnap.instance_id` selects what a lane automates: 0 (the
default) targets the clip's track's own instrument, so `param_id` indexes
`PolySynth.setParamAbsolute` (see `dsp/synth.zig`'s `automatable_params`); a
nonzero value targets a specific FX unit in the track's chain by its stable
`instance_id`, with `param_id` then indexing that unit's own
`dsp/fx_params.zig` table instead.

`DrumSnap.kit` names the factory kit flavour the machine was last set to
(`dsp/drum_kit.zig`'s `variants`). Its pads are generated on load rather
than stored, so a kit costs a name in the JSON and nothing on disk; only
user-loaded audio reaches the sidecar. A file that omits it - or names a
flavour this build no longer has - loads with whatever the per-pad `used`
flags describe, which for a machine left on the blank `init` kit is
nothing at all.

Drum patterns and drum arrangement clips optionally store `steps_per_beat`.
Its default is 4 (a 1/16-note grid); values through 32 give grids as fine as
1/128 notes.

## Sample sidecar

A pad's audio is either generated from its kit (nothing written to
disk beyond the params and the kit name) or **user-loaded**, in which case saving exports it
as a mono 16-bit WAV into `<stem>_samples/` next to the `.wsj` (`<stem>` is
the project filename without its extension, so `song.wsj` becomes
`song_samples/`, created lazily, only once a session actually holds a user
sample). Each file is named by its position: `t<track>p<pad>.wav` for a
drum pad, `t<track>clip.wav` for a standalone sampler clip, `t<track>oscA.wav`/
`oscB.wav`/`oscC.wav` for a synth oscillator's imported wavetable (same
sidecar directory, since it's the same "variable-size audio blob that
shouldn't live inline in the JSON" problem), and `t<track>.sf2` for a loaded
SoundFont (the one exception written verbatim rather than as a WAV,
since it isn't PCM audio). All are written through the
same `.tmp` + rename dance as the project file itself, so a crash never
leaves a truncated sample behind.

SoundFont snapshots may instead name a bundled `library` id. Bundled SFZ/FLAC
banks are part of the wstudio installation, so they need no project sidecar.

The pad's `sample_file` field stores a path *relative to the `.wsj`*, never
absolute, so a project directory can be moved or copied as a unit and still
load correctly.

Loading is best-effort per pad: a missing or unreadable sample file leaves
that pad on its shipped/generated audio with every other param (gain, ADSR,
trim, and the rest) still applied from the snapshot. A stale or deleted
sidecar file degrades one pad's sound; it never fails the whole project
load.

## External plugin failures

CLAP and VST3 snapshots use transactional hard failure, unlike sample
sidecars. Missing binary, missing saved plugin ID or class ID, malformed state,
or rejected state aborts project loading. Frontends build a replacement session
before touching active session, so failed reload leaves every current track,
automation target, and history entry unchanged.

CLAP identity is binary path plus stable plugin ID. VST3 identity is bundle
path plus 32-character class ID. Empty CLAP state means no state stream. VST3
keeps component and controller streams separate, including when either stream
is empty.

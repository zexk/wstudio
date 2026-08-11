# .wsj project format

A `.wsj` file is pretty-printed JSON: a `Snapshot` of the session (tracks,
racks/instruments, arrangement, master FX) plus a `version` field. The
authoritative type definitions live in `src/persist_types.zig`; this doc is the
human-readable map of that file, not a replacement for it.

## Saving

`persist.save` writes to `<path>.tmp` and renames it over the target, so a
crash or power loss mid-write can never corrupt an existing project file:
the rename is the only step that touches the real path, and it's atomic on
every platform wstudio targets.

User-loaded sample audio (a drum pad, sampler clip, or arrangement audio
source loaded from a WAV, as opposed to a generated kit pad) is exported
alongside the `.wsj` into a sidecar directory, not embedded in the JSON. See
[Sample sidecar](#sample-sidecar) below.

## Versioning policy

`persist.zig`'s `file_version` (currently 55) is the only format version
this build writes or reads. Loading enforces one rule:

- **A file whose `version` is not exactly `file_version` is hard-rejected**
  (`error.UnsupportedVersion`). No migration paths exist.

Current-version JSON uses a strict schema. Unknown fields and enum names fail
parsing instead of silently dropping sound or changing behavior. Numeric clamps
and bounds checks remain because they protect against corrupt and hand-edited
values.

**Bump `file_version` for every schema or semantic change**, including new
fields and enum members.

Version 55 makes synth modulation targets rack-aware. A matrix row with
`fx_instance_id == 0` stores a synth parameter id in `dest`; a nonzero instance
stores that exact FX unit's local `dsp/fx_params.zig` index instead.

## Snapshot notes

Bundled wavetable identities (`SynthSnap.wt_bundled` and OSC B/C counterparts)
select `basic` by default.

Version 54 removes standalone oscillator modulation fields. Ring, AM, and FM
are oscillator warp types, and OSC C gains matching warp controls.

Version 53 removes oscillator `waveform` and pulse-width fields. Every main
oscillator now reads its waveform table. Basic sine, triangle, saw, and square
shapes are frames 0 through 3 of bundled `basic` table and `wt_pos` selects or
morphs between them.

`SynthParamAutomationSnap.instance_id` selects what a lane automates: 0 (the
default) targets the clip's track's own instrument, so `param_id` indexes
`PolySynth.setParamAbsolute` (see `dsp/synth.zig`'s `automatable_params`); a
nonzero value targets a specific FX unit in the track's chain by its stable
`instance_id`, with `param_id` then indexing that unit's own
`dsp/fx_params.zig` table instead.

`DrumSnap.kit` names the factory kit flavour the machine was last set to
(`dsp/drum_kit.zig`'s `variants`). Its pads are generated on load rather
than stored, so a kit costs a name in the JSON and nothing on disk; only
user-loaded audio reaches the sidecar. An unknown name loads with whatever
per-pad `used`
flags describe, which for a machine left on the blank `init` kit is
nothing at all.

Drum patterns and drum arrangement clips optionally store `steps_per_beat`.
Its default is 4 (a 1/16-note grid); values through 32 give grids as fine as
1/128 notes.

## Tempo and meter maps

`tempo_bpm`, `beats_per_bar`, and `meter_denominator` define song defaults.
`tempo_points` stores beat-positioned BPM changes; `ramp_to_next` makes BPM
linear in beat space until next point. `meter_points` stores beat-positioned
numerator and denominator changes. Denominators must be powers of two through
32. Map beats are quarter-note units regardless of active denominator.

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

Arrangement audio sources use `source-<id>.wav` in that same directory.
Regions store stable source ids plus nondestructive source offsets and lengths.

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

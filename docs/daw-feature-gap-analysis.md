# Proprietary DAW feature gap analysis

Research checked 2026-08-31 against current vendor documentation. This is a
product-fit comparison, not a checklist to make wstudio imitate every mature
DAW. A feature ranks well only when several products converge on the workflow,
wstudio cannot already complete it, and it fits a keyboard-centric music DAW.

## Current baseline

wstudio already covers the ordinary song path: audio and MIDI recording,
patterns and linear arrangement, clip editing, alternate audio takes and basic
comping, punch recording, retrospective MIDI capture, editable clip fades and
crossfades, named sections, tempo and meter maps, automation write modes,
collapsible groups and sends, sidechains, modulation, track freeze, audio
consolidation, CLAP and VST3 hosting, plugin crash isolation, master and stem
export, and Lua customization.

This matters because several gaps named during early beta.10 research have
since shipped. Punch recording, clip-boundary fades, tempo and signature
changes, and named sections are no longer gaps. Take storage and `:comp` also
cover basic comp assembly, though there is no mature take-lane editing surface.

Authoritative local evidence is the command registry and help in
`src/ui/commands.zig` and `src/ui/help.zig`, the release record in
`CHANGELOG.md`, and the supported plugin boundary in `README.md`.

## What proprietary DAWs converge on

The comparison set spans different markets so one product's specialty does not
become an assumed requirement.

- Ableton Live 12 combines linear arrangement with clip launching, audio
  warping, audio-to-MIDI conversion, and visible audio or MIDI take lanes with
  comping. Its take lanes support auditioning, rearranging, and copying ranges
  into the main lane. Sources: [Live concepts](https://www.ableton.com/en/live-manual/12/live-concepts/),
  [comping](https://www.ableton.com/en/live-manual/12/comping/), and
  [Arrangement View](https://www.ableton.com/en/live-manual/12/arrangement-view/).
- Logic Pro combines take folders and comps, Flashback Capture, track
  alternatives, Flex Time and Flex Pitch, Live Loops, notation, video sync,
  surround and Dolby Atmos, and stem separation. Sources:
  [Logic Pro user guide](https://support.apple.com/guide/logicpro/welcome/mac),
  [Flex Time and Pitch](https://support.apple.com/guide/logicpro/flex-time-and-pitch-overview-lgcp15968647/mac),
  and [Logic Pro product page](https://www.apple.com/logic-pro/).
- Cubase 15 combines comping, audio pre-record and retrospective MIDI record,
  AudioWarp, VariAudio pitch correction, chord and arranger tracks, expression
  maps, score editing, Control Room monitoring, stem separation, video, and
  Dolby Atmos. Sources: [Cubase features](https://www.steinberg.net/cubase/features/)
  and [Cubase 15 features](https://www.steinberg.net/cubase/new-features/).
- Pro Tools emphasizes loop recording, playlist comping, punch accuracy,
  Elastic Audio, pitch editing, audio-to-MIDI, advanced automation, folder
  tracks, video and timecode, and spatial mixing. Source:
  [Pro Tools features](https://www.avid.com/pro-tools).
- FL Studio combines pattern and linear sequencing with Performance Mode,
  retrospective MIDI capture through its score log, audio warping and pitch
  editing, per-clip audio edits, track consolidation, and stem separation.
  Sources: [recording overview](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/recording.htm),
  [audio recording](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/recording_audio.htm),
  and [FL Studio 2025](https://www.image-line.com/fl-studio-news/fl-studio-2025-whats-new-2).
- Bitwig Studio combines arrangement and clip launching, clip-based comping,
  hybrid audio and instrument tracks, nested devices, pervasive modulators,
  note operators, and a modular sound-design environment. Sources:
  [Bitwig concepts](https://www.bitwig.com/userguide/latest/bitwig_studio_concepts/),
  [Clip Launcher](https://www.bitwig.com/userguide/latest/the_clip_launcher/),
  and [Operators](https://www.bitwig.com/userguide/latest/operators/).
- REAPER 7 combines takes and lanes, elastic audio, multichannel routing,
  surround, video, deep automation, macros, scripting, broad plugin format
  support, multiple open projects, and highly configurable control surfaces.
  Source: [REAPER feature overview](https://www.reaper.fm/about.php).

## Ranked gaps

### Closed: retrospective MIDI capture

Logic, Cubase, and FL Studio preserve a recent unrecorded performance. This is
especially valuable in a keyboard-first DAW because the user's hands can stay
on the instrument and the idea survives a missed record command.

This gap closed with `:capture-midi`. It keeps 30 seconds of external MIDI
note-ons per target track, preserves relative timing while stopped and tempo-map
position while rolling, and commits the recovery as one undoable edit.

Audio pre-record remains separate. It needs a bounded sample buffer, latency
alignment, ownership, and save behavior rather than reusing the lightweight
MIDI path.

### Closed: take audition and active identity

wstudio stores alternate audio takes and can select or bake a comp. Mature DAWs
add visible lanes, fast solo audition, range-based promotion to the main take,
take naming, and loop-recorded pass management. Live, Logic, Cubase, Pro Tools,
Bitwig, and REAPER all expose some form of this workflow.

The existing `:take next|prev` commands provide undoable audition. Audio clips
and both audio editors show the active take number and total. Only add further
range-based comp edits if real vocal or instrument sessions show existing
whole-take selection and `:comp` range promotion are blockers. Full freeform
lanes can wait.

Priority: high for recording users. Cost: medium for audition and identity,
large for editable lanes. Proof: record several loop passes, compare them
without destructive changes, assemble or select result, undo, save/reopen, and
export.

### 3. Elastic audio and corrective pitch editing

Live, Logic, Cubase, Pro Tools, FL Studio, and REAPER all offer timeline-aware
audio warping; most also offer integrated pitch correction. wstudio can stretch
a whole region, shift pitch, detect tempo and pitch, slice audio, and
consolidate edits, but it has no per-transient warp markers or note-level pitch
editor.

Recommended order: per-region warp markers first, using existing Rubber Band
rendering and consolidate path. Corrective pitch editing follows only if vocal
work becomes a target journey. Do not bundle stem separation, pitch correction,
and warping into one subsystem.

Priority: high capability gap, post-1.0. Cost: large. Proof: align a drifting
performance across tempo changes without destructive splits, preserve fades
and automation, and match live playback, consolidate, save/reopen, and export.

### 4. Advanced automation write boundaries

Pro Tools and Cubase expose trim, write-to-boundary, and related automation
workflows. wstudio already has breakpoint editing, write, touch, and latch
modes, live parameter recording, MIDI learn, and project LFO modulation, but
not the full boundary and trim toolset of a mixing console.

Recommended scope: add no more modes until a hardware-controller mixing journey
proves current recording overwrites too much. Defer trim and write-to-boundary
operations until users need post-production mix passes.

Priority: medium. Cost: medium. Proof: write one parameter, release control,
preserve later automation, then verify undo and live/offline agreement.

### 5. Articulation handling

Cubase expression maps and Logic articulation IDs solve orchestral instrument
switching. wstudio now bundles acoustic sounds but intentionally selects one
articulation from each source pack. Program changes reach hosted plugins, yet
there is no clip-level articulation lane or reusable map.

Recommended scope: postpone until one bundled or hosted multi-articulation
instrument is a supported reference. Then add the smallest event lane that can
emit keyswitches or program changes. A notation editor is not required.

Priority: medium for scoring, low for current product. Cost: medium. Proof:
switch articulations inside one phrase, edit them from keyboard, and retain
them through MIDI export and project round trip.

### 6. Clip launching and live performance

Ableton, Bitwig, Logic, and FL Studio pair a linear timeline with clip or scene
launching. wstudio's pattern model already supports reusable musical material,
but playback remains arrangement-oriented.

Recommended scope: no work without a concrete performance journey. A launcher
duplicates transport, recording, quantization, ownership, and frontend UI.
Pattern chaining or section jumps may cover composition with much less state.

Priority: low unless live performance becomes product scope. Cost: very large.

### 7. Nested track folders

Pro Tools, Cubase, Logic, and REAPER separate visual hierarchy from audio
routing. wstudio groups already collapse their member rows and provide routing
and group mix control. Fixed group slots are not nested visual folders.

Recommended scope: no work until one-level group collapse fails a measured
large-session journey. Then decide whether nested groups or an independent
folder tree solves the observed problem with less state.

Priority: low. Cost: large.

### 8. Plugin and routing breadth

Current CLAP and VST3 hosting covers one mono or stereo main bus. Missing
capabilities include plugin sidechain and auxiliary buses, multiple outputs,
surround buses, sample-accurate parameter ramps, CLAP polyphonic modulation,
and platform formats such as Audio Units. REAPER, Logic, Cubase, Pro Tools, and
Bitwig show how broad mature routing can become.

Recommended order: sidechain input and multi-output instruments only after
named compatibility targets fail real sessions. Prefer deeper CLAP and VST3
support over adding another plugin format. Audio Units would improve macOS
compatibility but should wait for native macOS runtime validation.

Priority: medium, driven by compatibility reports. Cost: large. Proof: one real
plugin per added bus shape, sandboxed and in-process, through automation,
save/reopen, live playback, stems, and teardown.

### 9. Post-production, notation, and spatial audio

Video and timecode, notation, surround, Dolby Atmos, advanced sync, and control
room monitoring recur in Logic, Cubase, Pro Tools, and REAPER. They serve
scoring, broadcast, and post-production markets rather than wstudio's current
songwriting baseline.

Priority: explicit non-goal until product scope changes. Cost: very large.
Shipping isolated checkboxes here would not make a credible post workflow.

### 10. AI-assisted separation and generation

Logic, Cubase, and FL Studio advertise stem separation. Logic and Cubase also
ship assisted players, synthesis, or generation features. These depend on
large models, platform acceleration, downloadable assets, or hosted services.

Priority: non-goal. External tools already feed ordinary audio or MIDI into
wstudio. Revisit only when an offline, redistributable dependency solves a
specific user journey without dominating package size and support work.

## Recommended sequence

1. Finish beta.10 and release 1.0 without another subsystem.
2. Run a real multi-take vocal or instrument session and improve existing take
   audition only where that journey fails.
3. Treat elastic audio as the next major subsystem if recording users confirm
   timing correction matters more than clip launching or scoring features.
4. Let compatibility reports select plugin bus work. Keep live performance,
   notation, video, spatial audio, and AI features outside scope until product
   direction changes.

This order deepens an existing recording model, then spends major complexity
only on a gap shared by nearly every comparison DAW.

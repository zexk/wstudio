# Beta.10 final-candidate validation

Run commands from repository root in Nix development shell. Generated files
stay under `.zig-cache/` or isolated screenshot homes.

## Recorded result

2026-08-01 non-hardware frontend journey passed on NixOS Linux x86_64:

- TUI and GUI each created an empty track, selected the built-in synth, added
  a C4 note, undid and redid it, saved the project, replaced the session,
  reopened the saved project, started and stopped playback, and exported a
  four-second PCM WAV.
- Saved projects reopened with the synth identity and C4 note intact. Both
  exports completed as PCM WAV files, with non-silent meter activity.
- Isolated TUI and GUI screenshots showed the reopened two-track project and
  successful export status without clipped or hidden state.
- GUI export exposed and fixed a missing offline-bounce park in its audio
  callback. Both frontends now use `Engine.renderRealtime`, and the park wait
  yields so the backend callback can acknowledge it.
- `zig build test` and native `zig build` passed after the fix.

## Explicit skips

- Physical audio capture, monitoring, and input-device selection need an audio
  input device and source.
- Live MIDI input and MIDI-device selection need a MIDI controller or loopback
  source.
- Native Windows and macOS frontend journeys need those hosts.

These skips do not cover create, edit, undo/redo, save/reopen, transport, or
export. Those paths passed in both Linux frontends above.

## Native Nix package

2026-08-20 `nix build .#default --no-link` passed on NixOS Linux x86_64 from
the beta.10 version commit. The installed binary reports `1.0.0-beta.10`; its
dynamic dependencies resolve; and the output contains the plugin bridge, man
page, desktop and MIME metadata, all nine icon sizes, and the bundled acoustic
library with its licenses. `nix flake check --no-build` also passes, and the
default dev shells evaluate for Linux and macOS on x86_64 and Arm64.

2026-08-20 `nix build .#windows --no-link` and
`nix build .#windows-arm64 --no-link` passed. Both cross-package outputs contain
the main and plugin-bridge PE binaries plus every non-system DLL in their import
closures. The shared derivation now walks transitive imports during install;
previously these public package outputs omitted their required DLLs even though
the release workflow added them later. This proves packaging, not the native
Windows journey listed under explicit skips.

Windows MIDI 2.0 projections no longer live in `third_party/`. Nix fetches the
pinned Windows MIDI Services SDK, C++/WinRT generator, and Windows SDK contracts,
then generates headers before each Windows cross-build. Both Windows package
builds pass with only this generated include tree, and the repository has no
remaining `third_party` path or reference.

The `macos` package output is now exposed only on native Arm64 macOS. It was
previously advertised on every flake system, but its fixed Arm64 target received
Linux or Intel host libraries and could not link. `nix flake show --all-systems`
confirms the narrowed package boundary; native macOS build and runtime remain
unverified here, consistent with the explicit host skip above.

## Release archives

2026-08-20 release-workflow audit found every archive omitted the 345 MiB
bundled acoustic library despite advertising it, and the Linux tarball omitted
the plugin bridge required by default sandboxing. Linux, Windows, and macOS
packaging now copies the installed share tree; Linux also carries the bridge.
Archive verification checks both artifacts, and the runtime library resolver
supports the archives' existing flat executable layout.

A local ReleaseSafe Linux tarball built from this workflow layout, extracted
under `/tmp`, reports `1.0.0-beta.10`, contains the bridge, acoustic SFZs and
licenses, docs, and config template, and renders `demo.wsj` to 16-bit stereo
PCM at 48 kHz. Its TUI also creates an acoustic track and opens `Grand Piano
(1/1)` from the flat archive layout with an empty application log. `actionlint`
passes on the updated workflow. Native Windows and macOS archive runtime checks
remain unverified under the host skips above.

Sandboxed VST3 state saving now uses the same bounded encoder as state loading.
Focused wire coverage proves undersized buffers and state beyond the 1 MiB RPC
ceiling fail before copy, so a large plugin state no longer kills the child.

VST3 host message attributes now reject non-finite and out-of-range float to
integer conversions. Focused host-message coverage feeds both hostile values
through the ABI boundary without panicking the host.

VST3 event lists, parameter queues, and parameter-change lists now return
their real object for both their declared interface and `FUnknown`. Focused
coverage also proves unrelated interface queries fail with a null object.

VST3 editor dimensions now use one checked rectangle conversion across open,
plugin-requested resize, and host resize constraints. Focused boundary coverage
rejects horizontal and vertical `i32` overflow before native window calls.

CLAP embedded editor dimensions now pass through one native-size conversion at
creation and every resize boundary. Focused checks reject zero and values above
`i32` range instead of trapping during plugin-controlled casts.

Audio take comping now checks resampled output against the shared 256 MiB PCM
ceiling and saturates beat-to-frame ranges before integer conversion. Focused
boundary coverage includes a maximum clip length and an overflowing finite beat.

Audio consolidation now applies that same PCM ceiling before allocation and
rendering. Shared audio-edit frame coverage rejects an extreme clip duration,
preventing allocator overcommit from turning into an unbounded UI-thread loop.

Acoustic instrument creation no longer hides a missing-library error behind a
later success status. Focused command coverage forces the load failure and
locks the visible reinstall recovery action.

Interactive source loading now accepts files through 256 MiB, matching the
existing bundled-SFZ sample ceiling instead of rejecting every source above
64 MiB. A sparse-file frontend check proves the old boundary loads and the new
boundary fails with its exact size plus a smaller-source recovery action.
The shared libsndfile decoder separately caps expanded PCM at 256 MiB before
allocation. Focused boundary coverage rejects one sample past that ceiling;
downmix now happens inside the decode buffer, avoiding a second clip-sized
allocation. Resampling enforces the same PCM ceiling after rate conversion,
with a focused extreme-ratio check that fails before allocation.

`:import-midi` now captures retained channel events and the project tempo map
with its melodic undo state. Focused frontend coverage imports distinct values,
then proves one undo and redo restore notes, events, base tempo, and tempo
points together. Parser coverage also caps oversized MIDI tempo maps at the
project's 64-point limit and reports that some MIDI data was capped. A
10,000-note and 10,000-event import under a fixed 192 KiB allocator proves the
parser applies every project cap while reading, without first allocating the
full source count, and still retains earlier events from later MIDI tracks.

## ReleaseSafe CLI render

2026-08-20 native `zig build -Doptimize=ReleaseSafe` passed. Its binary reports
`1.0.0-beta.10`, rendered the 34-second `demo.wsj` master, and rendered all four
stems. Every output is non-silent 16-bit stereo PCM at 48 kHz with 1,632,000
frames; the master peaks at -2.05 dB.

## Valgrind render

2026-08-20 a full `demo.wsj` CLI render passed Memcheck with zero errors and
all 73 allocations freed. Build with `zig build -Dcpu=baseline`; native CPU
selection emits a Zig decompressor instruction LibVEX 3.26 does not recognize.
Run Valgrind with `--max-stackframe=8388608`; `persist.load.buildSession` uses a
4.38 MiB stack frame that otherwise triggers false invalid-stack accesses.
Definite and indirect leaks use `--error-exitcode=1`.

## Playback and persistence soak

2026-08-20 `zig build soak` passed against `demo.wsj`. Debug DSP processed
172,802,048 frames in 42,188 blocks, with repeated transport stop, seek, and
resume transitions. Output stayed finite and audible with a 0.731 peak. Ten
save/load round trips and three PCM exports completed afterward.

Every save had re-encoded every recorded clip's full audio to FLAC from
scratch, even when nothing about that audio had changed - measured at 139ms
to encode 5 minutes of mono audio. `App.maybeAutosave` runs a save every 30s
by default whenever anything is dirty, synchronously on the UI thread, so a
project with several minutes of recorded audio per track could stall input
and redraw for over a second on an unrelated one-note edit. Each
`AudioSource` now caches its encoded bytes and reuses them until that
source's content actually changes - safe with no dirty-tracking since
`AudioSource.samples` is write-once and ids are never reused. Measured
144ms -> 10ms on a repeat save of the same 5-minute source. Re-running
`zig build soak` afterward reproduced the identical frame count, round-trip
count, and peak recorded above.

## Third-party plugin pass

2026-08-14 `zig build plugincheck` hosted the `wstudio-test-plugins` bundle
(LSP, Surge XT, Odin 2, sfizz, CHOW Tape, Uhhyou) on NixOS Linux x86_64: 441
CLAP and VST3 plugins scanned, all 441 loaded, and every one completed load,
process, automation to both ends of its declared parameter ranges, state save,
state reload, re-render, reset, and teardown. The sweep ran twice, once
sandboxed the way a stock session loads plugins and once in-process with
`--direct`. Both runs report zero host faults.

Getting there closed three host defects, all invisible to the bundled fixture
plugins because those fixtures are this repository's own code:

- Host objects answered every `queryInterface` id with themselves, so a plugin
  asking a state stream for `IStreamAttributes` got the stream's own vtable and
  called `read` believing it was `getFileName`. Surge XT, Odin 2 and CHOW Tape
  crashed inside `setState`. Under the sandbox this appeared only as a lost
  bridge child, which is what the recorded `ProcessingStartFailed`-era LSP
  blocker looked like from the outside.
- `IEditController::getState` and `setComponentState` are optional, and JUCE
  plugins answer `kNotImplemented`. The host treated that as failure, so no
  JUCE plugin could be saved or reopened at all.
- `clap_plugin.reset` is `[audio-thread]`, and the host's thread check only
  reported an audio thread from inside `processBlock`. Odin 2 aborted the whole
  process on the violation.

Nine remaining reports are plugin-side and not release blockers: LSP's send and
return utilities (CLAP and VST3, mono and stereo) and Uhhyou's ClangSynth
produce an enormous output level when a parameter is driven to the end of its
own declared range, which is what those ranges mean. They are recorded as
notes and do not fail the run.

2026-08-20 the sandboxed sweep only reported five of those nine: the bridged
VST3 loader populated its automatable-parameter list (`Vst3Plugin.loadBridged`
in `src/vst3/plugin.zig`) only `if (instrument)`, unlike the direct loader,
which has no such gate. Every sandboxed VST3 effect therefore swept zero
parameters in the "automate" step, so the four VST3 LSP send/return notes
never fired there, silently narrowing what the release gate's "automation to
both ends of its declared parameter ranges" claim actually covered. Dropping
the gate makes both loaders symmetric; the sandboxed and `--direct` sweeps now
report the same nine notes.

The check is on-demand rather than part of `zig build test`, since it needs
third-party plugins installed on the machine.

## Ownership and stale state after delete or reorder

2026-08-14 automated coverage locks the four kinds of stored track index
against every operation that shifts one. Deleting an earlier track moves
compressor sidechain sources, LFO controller targets, learned CC bindings, and
send-level automation lanes down with it; deleting the referenced track clears
them outright rather than letting them land on a neighbour; swapping two tracks
carries them along. A shared helper sets all four before each case, so none of
those assertions can pass by testing nothing.

FX units are addressed by a stable instance id rather than a chain slot, and
that is now proven at the boundary that could break it: removing a unit does
not hand its id to the unit that shifts into its slot, automation still
addressed to the removed unit stays inert, and a unit inserted afterwards does
not inherit the dead id. Loading restores saved instance ids and advances the
allocator past them (`persist/load.zig`), so a reopened project cannot mint a
duplicate.

Group slots are fixed and reused, so a reference left behind by a deleted group
does not dangle, it becomes a reference to whatever group is created next. That
is now closed and covered: deleting a group unassigns its member tracks, clears
every aux send aimed at it, and drops its gain-automation lane, and a group
created afterwards in the same slot inherits none of it. Sends clear outright
rather than falling back to master, since rerouting audio is an audible change
the user never asked for.

Clip and plugin-parameter ownership are covered at the same boundary. Removing
a clip withdraws its automation from the flattened curve rather than leaving it
to drive bars that now belong to the neighbouring clip. A replacement FX unit
does not inherit automation addressed to the unit that held its chain slot,
which is the session-level half of the instance-id contract above.

## Transport coherence

2026-08-14 the loop-wrap boundary is covered: arriving at a position by playing
across the loop end selects the same automation value as arriving at the same
position by seeking, at the same transport frame. This is the property that
keeps live playback and an offline render of the same bars in agreement, and
the curve used moves steeply across the bars in question so a wrap that kept
reading the pre-wrap position would read a different value.

Play and stop are covered at the same standard: blocks processed while stopped
do not advance the transport, and a run that stops and resumes lands on the
same position and the same automation value as an uninterrupted run over the
same bars. Seek is covered as the control arm of both that check and the loop
wrap above.

Sample-rate changes are covered by the property that makes a reopened project
sound the same at another rate: automation selects by beat, so the frame count
for a given beat changes with the rate and the value at that beat does not.
Both segments of the curve used hold, so the comparison cannot be decided by
where inside the bar each engine happens to sit.

Recording start and stop are covered by the punch checks below. Project
replacement builds a whole new `Session`, engine included, so no transport or
automation state can survive it; what needed covering was the frontend
bookkeeping that outlives the swap, and a session swap now provably ends the
record pass instead of carrying its target indices into a project where they
name other tracks.

## Punch recording

Automated frontend coverage verifies `:punch` rejects missing bounds and gates
MIDI and audio recording to the enabled A/B frame range. Punch passes disable
loop wrapping while recording, keep playback running after punch-out, and stamp
captured audio at the punch-in bar. Hardware capture remains covered by the
explicit skip above.

## Recorded-audio boundary fades

Recorded Sampler clips receive editable 5 ms fade-in and fade-out values through
the existing sampler model, clamped to short clip duration. Existing sampler
rendering, persistence, undo/redo, TUI controls, and GUI waveform handles expose
the result without a new clip type or format version. Synthetic capture coverage
verifies both fades and their undo/redo restoration.

## Timeline tempo and signature changes

Shipped 2026-08-08, after this section had already recorded it as postponed.
The project carries a tempo map and a meter map (64 points each, `time_map.zig`)
rather than one global value: `:tempo-point <beat> <bpm> [step|ramp]` adds a
tempo change with an optional ramp into the next one, and
`:meter-point <beat> <n>/<d>` changes the signature at a beat.

The maps live on the transport, which both live playback and offline render
read, so there is one set of consumers rather than a parallel timing path.
Coverage: `time_map.zig`'s own beat/seconds round-trip, ramp, clamp and
denominator tests, plus a frontend test that the two commands agree between
`project` and `transport` after a processed block. Loop bounds and song data
resync on every point edit. Persistence carries both maps.

Lua reads the tempo in force at a position through `transport_get` but cannot
add points; that is the one remaining surface, and it is post-1.0 work.

## Frontend polish pass

2026-08-20 `zig build -Dgui-test` followed by
`DISPLAY=:99 zig-out/bin/wstudio --gui` under Xvfb passed all three ImGui test
engine journeys.

Fresh 160x48 and 100x30 TUI captures of blank and `demo.wsj` track views also
passed. Narrow arrangement and populated FX-chain views kept labels, focus,
parameters, status, meters, and hints visible without overlap.
This pass found that the screenshot harness inherited the repository working
directory, so an ignored `project.wsj~` could leak into its supposedly isolated
blank session. The launcher now changes to its temporary home before starting
wstudio; a recapture with that backup still present in the repository showed a
clean blank status line.

2026-08-01 isolated screenshots covered blank and `demo.wsj` track views,
arrangement, and populated FX chains in both frontends. TUI coverage used
160x48 and narrow 100x30 terminals; GUI coverage used its clean Xvfb profile.
Selection, empty-track state, transport and meter chrome, clip boundaries,
track labels, FX slots, parameter labels, and bottom status hints remained
visible without overlap or clipping. No defect appeared in this pass. Captures
remain under `.zig-cache/beta10-polish/`.

## Command and key audit

2026-08-20 a real incompatible workspace project exposed raw Zig error traces
from `render` and `render-stems`, while frontend startup and `:edit` exposed the
same internal error names. All four paths now share a project-load error
boundary that names the path and gives recovery for incompatible, corrupt,
missing, and unreadable files. Focused message and frontend reload coverage,
real incompatible and missing-file invocations, and the full test suite pass.

2026-08-01 command help, completion scopes, and view key handlers passed their
shared registry and frontend integration checks. Audit found one contract gap:
the four `[on|off]` commands silently toggled when given an invalid value.
`:metronome`, `:punch`, `:ghost`, and `:audition` now leave state unchanged and
name both the failed command and accepted values. Automated coverage locks that
behavior; `zig build test` passes.

## Mix safety and effect defaults

2026-08-20 audio export safety now rejects any existing destination carrying
the `.wsj` container magic. This closes project destruction through CLI or
frontend bounce without restricting output extensions. Focused coverage proves
the project bytes remain unchanged.

`:export-midi` now uses the same project-destination guard and writes through a
sibling temporary file before atomic replacement. Frontend coverage proves a
project target is refused and remains byte-identical, and a forced temporary
write failure preserves an existing MIDI destination.

The no-argument `wstudio render` demo now follows the same contract for its
fixed `out.wav` destination. A real CLI invocation against a project stored at
that name refuses the write and preserves the file; a forced temporary-write
failure also preserves an existing audio destination.

2026-08-01 automated checks cover every internal effect default (25 kinds as of
beta.10, up from the 20 this section first counted) with normal
audio: output stays audible, finite, and bounded. Shared chain coverage proves
bypassed effects leave samples bit-identical. Existing focused checks cover
track/master meters, limiter ceiling and recovery, delay echoes, and decaying
reverb tails. Audit corrected rack delay's fresh-instance time from its 2.0 s
allocation ceiling to the established 0.25 s musical default. Fresh rack OTT
depth now starts at 10%; its previous 100% default peaked at 13.39 from a 0.5
input during detector startup. Demo mix review was skipped because the demo
project will be replaced.

## Arrangement markers

Existing named sections satisfy the marker candidate without a new model or
format change. `:section` adds or renames at the arrangement cursor,
`:section-del` removes, `{` and `}` seek to previous and next sections, and
`s` selects the current section. Both frontends route these shared actions and
draw section names on the arrangement timeline. Automated coverage verifies
add, rename, delete, previous/next seek, selection, Lua access, time edits, and
save/reopen persistence.

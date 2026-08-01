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

Postponed until after 1.0. Current tempo and `/4` signature are project-global:
transport frame/beat conversion, loop and recording bounds, live and offline
song scheduling, plugin transport, metronome, arrangement grids, Lua, and
persistence all consume one value. Adding changes at timeline positions would
require a shared tempo map plus migration and boundary tests across every one of
those consumers. That is a new timing subsystem, not bounded release-candidate
polish, and would risk beta.8 compatibility and live/offline coherence.

## Frontend polish pass

2026-08-01 isolated screenshots covered blank and `demo.wsj` track views,
arrangement, and populated FX chains in both frontends. TUI coverage used
160x48 and narrow 100x30 terminals; GUI coverage used its clean Xvfb profile.
Selection, empty-track state, transport and meter chrome, clip boundaries,
track labels, FX slots, parameter labels, and bottom status hints remained
visible without overlap or clipping. No defect appeared in this pass. Captures
remain under `.zig-cache/beta10-polish/`.

## Arrangement markers

Existing named sections satisfy the marker candidate without a new model or
format change. `:section` adds or renames at the arrangement cursor,
`:section-del` removes, `{` and `}` seek to previous and next sections, and
`s` selects the current section. Both frontends route these shared actions and
draw section names on the arrangement timeline. Automated coverage verifies
add, rename, delete, previous/next seek, selection, Lua access, time edits, and
save/reopen persistence.

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

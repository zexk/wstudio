# 1.0.0-beta.5 goals

Beta.5 closes known workflow and platform gaps. It does not add another
instrument, effect, or speculative subsystem.

## Device routing

Status: implemented; physical Windows and macOS device verification remains.

Audio input and output currently use default devices. Linux MIDI requires an
external `aconnect`, macOS connects every current MIDI source, and Windows has
no live MIDI input backend.

Goal:

- Let users select available audio input, audio output, and MIDI input devices.
- Use one selected MIDI source instead of every source on macOS.
- Connect selected MIDI sources without an external `aconnect` step on Linux.
- Add live MIDI input on Windows.
- Keep current default-device behavior when no device is selected.

`wstudio devices` lists backend-native identifiers. Shared Lua options select
audio input, audio output, and live MIDI input for both frontends. PipeWire and
JACK continue to use their server graph for audio routing.

Done when both frontends expose the same saved device choices and each
supported OS can play, capture, and receive MIDI from selected devices.

## Complete undo coverage

History already covers content edits, arrangement edits, rack swaps, FX edits,
and parameter nudges. Plain track creation, swing, and mixer gain and pan remain
explicit exceptions.

Goal:

- Undo and redo track creation.
- Undo and redo drum and slicer swing changes.
- Undo and redo track gain and pan changes, plus group gain changes.
- Preserve existing parameter-nudge coalescing behavior.

Done when every persistent edit reachable from normal editing workflows either
creates a history entry or is documented as intentionally outside history.

## Finish CLAP lifecycle support

The host records plugin restart requests but does not service them. It does not
offer the CLAP thread-pool extension, accepts only one stereo input and one
stereo output, and supports floating rather than embedded plugin GUIs.

Goal:

- Service plugin-requested restarts without corrupting live engine state.
- Support plugin-requested thread pools.
- Define and test supported audio-port layouts beyond the current single
  stereo bus restriction.
- Keep unsupported CLAP capabilities explicit in scan or load errors.

Embedded plugin GUIs and polyphonic modulation remain out of scope unless
required by a plugin used to verify lifecycle work.

Done when integration tests exercise restart, thread-pool, and accepted
audio-port behavior through the bundled CLAP test plugin.

## GUI integration coverage

Shared modal behavior has broad integration coverage through the TUI harness.
GUI-specific behavior mostly has compile checks and narrow unit tests despite
owning drag, viewport, picker, and held-key state.

Goal:

- Add runnable checks for GUI drag history boundaries.
- Add checks for cursor-following and viewport changes.
- Add checks for picker selection and dismissal.
- Add checks for held navigation keys versus edge-triggered edit keys.

Done when those GUI paths can regress without relying on a manual screenshot
pass to find the behavioral failure. Screenshots remain the visual check for
layout, color, and styling.

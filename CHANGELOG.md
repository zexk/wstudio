# Changelog

Notable user-visible changes per release. The `.wsj` format's own version
history lives in [FORMAT.md](FORMAT.md).

## Unreleased

### Added

- Drum grid, Elektron-style: per-step tune, trig conditions, rolls, and
  micro-timing, plus per-pad loop length for polymeter.
- Synth: 32 modulation matrix rows (was 8), per-row unipolar mode,
  tempo-synced retriggerable slewable LFOs, per-note random modulation,
  band-limited wavetable playback, and a module-grid editor layout.
- Instrument presets save their whole FX chain, and rack FX carry stable
  instance IDs so modulation survives a reorder.
- Piano roll: FL-style mouse gestures in both frontends, left-edge note
  resize, velocity-lane dragging, cursor-pitch audition, blockwise visual
  selection, and chord-stamp inversions.
- Note tools: `:invert`, `:double`, `:fit`, `:dedupe`, `:normalize`,
  `:glue`, `:chop-notes`, `:flam`, `:arpeggiate`, `:limit`,
  `:discard-lengths`, `:snap-scale`.
- Sampler and slicer: per-pad tone filter and gated playback,
  `:chop-random`, `:spread`, `:bpm-sync`, waveforms tinted by frequency
  content, and regions drawn on the warped playback timeline.
- File browser: `p` auditions the file under the cursor, `v` bulk-loads a
  range of samples into consecutive pads, and it reopens where the last
  sample came from.
- Groups: mute and solo a whole group from its tracks-view row, with badges
  in the GUI.
- The GUI gained live MIDI input, matching the TUI.
- A blank `init` drum kit, which a fresh drum machine now starts on.

### Fixed

- `:synth-preset` applied stack garbage instead of the saved patch.
- TUI mouse clicks landed one row above the row that was clicked.
- A saved kit reloaded as eight silent named pads instead of audio.
- Undo covered GUI synth, sampler, automation, step-painting, and recorded
  audio edits, all of which previously bypassed it.
- Several panics: a long piano-roll loop, the bottom of the GUI keyboard,
  command history stepped past its newest entry, and a multi-lane undo
  entry after a track delete.
- A project file with no tracks is rejected rather than loaded.
- Assorted GUI viewport, scroll, and cursor-following gaps against the TUI.

## v1.0.0-beta.3 and earlier

See the generated notes on each tagged release:
<https://github.com/zexk/wstudio/releases>.

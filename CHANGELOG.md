# Changelog

Notable user-visible changes per release. The `.wsj` format's own version
history lives in [FORMAT.md](FORMAT.md).

## Unreleased

### Added

- Lua can now write musical content, not just build a project skeleton:
  `notes_get`/`notes_set` and `steps_get`/`steps_set` for piano-roll and
  drum-grid patterns, `fx_list`/`fx_add`/`fx_params`/`fx_param_set` for FX
  chains on any track, the master bus, or a group, and `clip_add`/
  `section_set` for laying the arrangement out. Enough to script euclidean
  rhythms, chord generators, humanize passes, and whole song structures.
  See the worked examples at the end of
  [examples/init.lua](examples/init.lua).
- Drum grid, Elektron-style: per-step tune, trig conditions, rolls, and
  micro-timing, plus per-pad loop length for polymeter.
- Synth: 32 modulation matrix rows (was 8), per-row unipolar mode,
  tempo-synced retriggerable slewable LFOs, per-note random modulation,
  band-limited wavetable playback, and a module-grid editor layout.
- Instrument presets save their whole FX chain, and rack FX carry stable
  instance IDs so modulation survives a reorder. `f` in the tracks view
  opens that preset picker directly, picking synth presets, drum kits, or
  SoundFont presets from the track's own instrument.
- Piano roll: FL-style mouse gestures in both frontends, left-edge note
  resize, velocity-lane dragging, cursor-pitch audition, blockwise visual
  selection, and chord-stamp inversions.
- Note tools: `:invert`, `:double`, `:fit`, `:dedupe`, `:normalize`,
  `:glue`, `:chop-notes`, `:flam`, `:arpeggiate`, `:limit`,
  `:discard-lengths`, `:snap-scale`.
- Sampler and slicer: per-pad tone filter and gated playback,
  `:chop-random`, `:spread`, `:bpm-sync`, waveforms tinted by frequency
  content, and regions drawn on the warped playback timeline.
- File browser: `a` auditions the file under the cursor, `v` bulk-loads a
  range of samples into consecutive pads, and it reopens where the last
  sample came from.
- Arrangement: holding `enter` after stamping a clip keeps the cursor on it
  so `h`/`l` resize it live, mirroring the piano roll's note stamp. The
  GUI's bar cursor is a plain grid cell again instead of a stamp-length
  preview.
- Groups: mute and solo a whole group from its tracks-view row, with badges
  in the GUI.
- The GUI gained live MIDI input, matching the TUI.
- A blank `init` drum kit, which a fresh drum machine now starts on.
- `m` in the synth editor points the first free modulation matrix row at
  the param under the cursor and jumps there, instead of stepping `dest`
  through every automatable param by hand.

### Fixed

- Bookmarks, command history, instrument presets, and drum kits now live in
  the same directory as `init.lua` (`$XDG_CONFIG_HOME/wstudio`, or
  `%APPDATA%\wstudio` on Windows). Files left in the old `~/.config/wstudio`
  location are still read, and move on the next save.
- `/` in the synth editor panicked once the mod matrix grew to 32 rows: the
  candidate buffer was still sized for 8.
- `:synth-preset` applied stack garbage instead of the saved patch.
- TUI mouse clicks landed one row above the row that was clicked.
- A saved kit reloaded as eight silent named pads instead of audio.
- Undo covered GUI synth, sampler, automation, step-painting, and recorded
  audio edits, all of which previously bypassed it.
- Several panics: a long piano-roll loop, the bottom of the GUI keyboard,
  command history stepped past its newest entry, and a multi-lane undo
  entry after a track delete.
- `gui_panel_border = 'square'` now reaches every non-musical GUI element:
  track rows, badges, chips, FX slots, meters, plots, and canvases were
  hardcoded to rounded corners, and frames kept a 2px radius even in square
  mode. Note blocks, clips, and knobs keep their own shape.
- A project file with no tracks is rejected rather than loaded.
- Assorted GUI viewport, scroll, and cursor-following gaps against the TUI.

## v1.0.0-beta.3 and earlier

See the generated notes on each tagged release:
<https://github.com/zexk/wstudio/releases>.

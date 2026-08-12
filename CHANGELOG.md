# Changelog

Notable user-visible changes per release. The `.wsj` format's own version
history lives in [FORMAT.md](FORMAT.md).

## v1.0.0-beta.10

### Added

- CC0 VCSL pianos, harpsichord, pipe organ, concert harp, mallets, and kalimba
  through a shared SFZ sample-bank loader, as their own `Acoustic` instrument
  in the picker. Acoustic tracks start on grand piano and switch bundled
  timbre with `:library` or the `f` preset picker; `SoundFont` is now a
  separate instrument for playing your own `.sf2` banks.
- Internal rack multimode filter with low-pass, high-pass, and band-pass modes,
  cutoff, resonance, drive, and dry/wet mix.
- Internal rack limiter with ceiling and release controls.
- Internal rack utility for gain, polarity, mono, channel selection, and swap.
- Internal rack stereo width with mono-compatible mid/side width and output trim.
- Internal rack auto-pan/tremolo with free or tempo-synced rate.
- Internal rack transient shaper with attack, sustain, and output trim.
- Internal rack pitch shifter with semitone and cent transposition, formant
  and dry/wet mix.
- Project-level modulation controllers: four tempo-synced LFOs, each driving up
  to eight instrument or FX params across any tracks, via `:ctrl` and
  `:ctrl-bind`.
- MIDI learn: `:cc-learn` binds a hardware controller knob to the param under
  the cursor, on any track, and `:cc`/`:cc-clear` list and drop bindings.
- Punch-in/out recording inside existing arrangement A/B bounds via `:punch`.
- Recorded audio clips start with editable 5 ms boundary fades to prevent clicks.
- Piano-roll chord stamping grows beyond triads and 7ths: `o`/`O` cycle chord
  quality (6th, 9th, 11th, 13th, sus2, sus4, add9, dim, aug) and `r`/`R` cycle
  voicing (closed, drop2, open), each re-stamping in place at the cursor.

### Changed

- Pickers and command-name tab completion list fuzzy matches best-first
  instead of in table order, favouring contiguous runs, word starts, and
  matches near the front of a short name. The `/` `n` `N` searches still walk
  the list positionally.
- Sample analysis (slice detection and tempo detection) runs about twice as
  fast per frame, and the whole spectral path (analysis plus the spectrum
  analyser) is more accurate at the quiet end.

- Project files are a fraction of the size. The session inside a `.wsj` is
  now written in a compact binary encoding instead of pretty-printed JSON,
  and then compressed; the bundled demo song went from 151 KB to under 1 KB.
  User-loaded samples are stored as FLAC rather than 16-bit WAV, which is
  lossless against what was stored before and roughly halves the audio a
  sample-heavy project carries. Projects saved by earlier builds are not
  readable (see [FORMAT.md](FORMAT.md)).
- A project is one file again. User-loaded samples, imported wavetables,
  recorded audio, and `.sf2` banks now live in an audio cache section inside
  the `.wsj` itself instead of a `<name>_samples/` directory beside it, so a
  project can be moved, copied, or sent as a single file, and a save can no
  longer leave stale sample files behind. Projects saved by earlier builds
  are not readable (see [FORMAT.md](FORMAT.md)).
- The help view (`?`) reads as a reference instead of a wall of text. In the
  GUI it gained a clickable section index down the left, key chips in an
  aligned column, headings with rules, and a scroll position bar; both
  frontends show which section you are reading in the header and jump between
  sections with `{` and `}`.
- Synth oscillators now use waveform tables for every sound. Sine, triangle,
  saw, and square are frames in bundled `basic` waveform instead of separate
  oscillator modes, so position can morph between them. Separate waveform-mode
  and pulse-width controls are gone.
- Every synth LFO waveform is now one drawn shape. Instead of picking sine,
  triangle, saw, or square from a list, a slot holds breakpoints whose
  segments bend, and those four waveforms are presets you load into it with
  the new `wave` row. Sample & hold and chaos stay their own shapes, since
  neither is a function of phase. A drawn point's `bend` is a new -1..1
  control, editable per point; a fresh LFO starts on a sine.
- The project is now licensed GPL-3.0-or-later instead of MIT. Releases up to
  v1.0.0-beta.9 stay available under MIT. The move opens the door to the GPL
  audio libraries that do this work better than the code here does, starting
  with aubio for tempo/onset/pitch detection and Rubber Band for time-stretch
  and pitch-shift.
- The rack pitch shifter is Rubber Band's live shifter instead of a two-tap
  granular one. Measured on a 220Hz sine taken up 7 semitones, the old one
  landed 38 cents sharp with a third of its energy on the intended partials
  and 9dB of level wobble; the new one is exact, at 99.9%, with 0.4dB. Its
  grain-size control is gone, replaced by formant transposition: 0 keeps the
  source's formants, so a shifted voice stays a voice.
- Sample loads resample with speexdsp's sinc converter instead of linear
  interpolation, so a 44.1k sample in a 48k project no longer folds its top
  octave down as aliasing. Applies to every sample load, SF2 sample pool,
  and SFZ region.
- Audio decoding is libsndfile's, so FLAC, AIFF, CAF, Ogg Vorbis, Opus and MP3
  load anywhere a WAV did, and the file browser offers them. Files with
  trailing metadata chunks or stale RIFF sizes load instead of being refused.
- The integrated loudness reading applies BS.1770's relative gate, so a long
  quiet passage no longer drags it down - it was reading 6 LU low on such
  material against libebur128, and is now within 0.2 LU.
- Time, rate, frequency, Q, and portamento controls use perceptual editor
  scaling, preserving fine control over short and low values.
- The slicer grid's pattern-variant keys are now `[`/`]`, the same pair the
  drum grid uses; the slice-start nudge moves to `(`/`)`.
- `g`/`G` motions become two-key pairs: `gg` jumps to the start and `gG` to
  the end in the piano roll, drum grid, slicer grid, automation, and the
  sampler/synth/soundfont editors. In the arrangement `gs` plays from the
  cursor bar, `gg` jumps to bar 0, and `gG` jumps to the song's end. A user
  Lua keymap on a `g` pair still wins over these builtins.
- Grid zoom is a `z` prefix: `zg`/`zG` choose a finer/coarser timing grid
  in the piano roll, drum grid, slicer grid, and arrangement, mirroring the
  `gg`/`gG` pair grammar.
- The piano roll's chord keys move behind a `c` prefix: `cc` stamps the
  chord (the count still inverts, now `2cc`), `co`/`cO` cycle the quality,
  and `cr`/`cR` the voicing. The single-key `C` still stamps an instant 7th
  and seeds the cycle; `o`/`O`/`r`/`R` on the piano roll are free.

### Fixed

- Live MIDI notes that arrived faster than the recorder drained them were
  dropped without a word; the status bar now says how many did not make it
  into the take.
- Stamping an inverted chord with a drop2 or open voicing moved the wrong
  voices: inverting left the raised notes at their old positions, and the
  voicing picks its notes by position.
- The Werckmeister III and Kirnberger III temperaments played from wrong
  offset tables, so neither sounded like the tuning it named. Just
  intonation's major sixth was 0.3 cents off.
- The limiter's true-peak mode delayed its audio twice as far as the
  detector actually looks back, so it clamped early and reported twice the
  latency it adds (which shifted every other track by that much).
- Toggling an EQ band from dynamic back to static left it stuck at whatever
  boost the detector had last driven it to, while the editor showed the base
  gain.
- Toggling FX bypass could crash the audio thread, through a delay
  compensation subtraction that assumed no chain ever reports more latency
  than the whole graph did a moment earlier.
- Track rows showed a hosted CLAP/VST3 plugin with the same letter as a
  wstudio synth on terminals without the Nerd Font.

## v1.0.0-beta.9

### Added

- GUI track rows now provide live output meters and sliders for volume and
  pan, with matching group and master controls.

## v1.0.0-beta.8

### Changed

- Launching either frontend with an unreadable or invalid project now reports
  the path and reason on stderr and exits nonzero. Earlier builds reported the
  error but opened a blank session, which could hide automation failures.
- CLI commands now reject extra positional arguments instead of ignoring them.

## v1.0.0-beta.4

### Added

- Holding GUI navigation keys now repeats movement, parameter nudges, and
  prompt editing while edit and performance keys remain edge-triggered.
- GUI automation drags rebuild arrangement playback once on release instead
  of once per rendered frame, keeping long arrangements responsive.
- `:recent` opens a picker for the 10 most recently loaded or saved projects.
- Command suggestions and Tab cycling now fuzzy-match command names, so a
  short subsequence such as `rsb` finds `restore-backup`.
- `:clap-gui` opens plugin-owned floating GUI windows for CLAP instruments
  and focused effects from either frontend.
- 18 more `wstudio.o` options: the `:bounce` tail length, bit depth, and
  default output paths; the master limiter's ceiling and release; the step
  count, pattern length, and swing a newly created instrument starts at;
  the terminal columns per piano-roll, drum, and arrangement cell; the
  completion popup height; the spectrum analyser's dB span; the waveform
  band-tint split points; and the GUI piano-roll row height, which now
  scales the roll up to a full 88 keys at small heights.
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

- Sampler fade handles now use conventional fade lines, taper waveform
  previews, and scale time-control ranges to trimmed playback duration.
- Applying a synth preset bound its FX modulation to nothing, so a preset
  whose macro sweeps a reverb or delay parameter (warm-pad, pluck, and
  others) applied with that routing dead.
- Both frontends now title themselves `<project> - wstudio`, from the
  project file's name without its directory or extension. The GUI window
  said "wstudio GUI prototype" and never updated on a blank session, and
  the TUI set no terminal title at all.
- `piano_audition` was settable from `init.lua` but missing from the Nix
  modules, the config template, and the docs. Added, and a test now walks
  the option table against all three so none can drift again.
- The drum grid's `a` pad audition played at a fixed velocity instead of
  honouring `wstudio.o.default_velocity`.
- The GUI command-suggestion popup showed 8 rows where the TUI showed 10;
  both now follow `wstudio.o.completion_popup_rows` (default 10).
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

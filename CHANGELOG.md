# Changelog

Notable user-visible changes per release. The `.wsj` format's own version
history lives in [FORMAT.md](FORMAT.md).

## v1.0.0-beta.10

### Added

- MIDI 2.0 UMP controller input on Linux through ALSA, macOS through CoreMIDI,
  and Windows through Windows MIDI Services, with runtime detection and WinMM
  fallback. Includes 16-bit note
  velocity, 32-bit CC, pitch bend and pressure, per-note pitch bend, program
  and bank changes, MIDI 1.0 UMP compatibility, and legacy-kernel fallback.
  Windows release archives cover x64 and Arm64.
- Retrospective MIDI capture: `:capture-midi` recovers notes played on the
  selected melodic track during the last 30 seconds. Stopped performances keep
  their relative timing, rolling performances keep their tempo-map position,
  and the complete recovery is one undoable edit.
- Audio clips and audio editors show active take number and total. In the audio
  editor, `[` and `]` or GUI buttons audition previous and next takes directly;
  `:comp` keeps those take numbers stable after auditioning.
- CC0 acoustic instruments from VCSL, FreePats and VSCO 2 CE through a shared
  SFZ sample-bank loader, as their own `Acoustic` instrument in the picker:
  pianos, harpsichord, pipe organ, concert harp, mallets, kalimba, harmonica,
  nylon-string guitar, clean electric guitar, tenor ukulele, finger and
  picked bass, honky-tonk piano, tenor saxophone, clarinet, soprano recorder,
  violin, viola and cello sections, pizzicato contrabass, flute, and muted
  trumpet. Acoustic tracks start on grand piano and switch bundled timbre
  with `:library` or the `f` preset picker; `SoundFont` is now a separate
  instrument for playing your own `.sf2` banks.
- Internal rack guitar amp: three voicings (clean, crunch, lead) that switch
  the preamp stage count, the tone-stack component values and the cabinet
  together, drive, a bass/mid/treble tone stack, presence, master, a TIGHT
  control over how much low end reaches the clipping stages, a switchable
  speaker cabinet, and output trim.
- Internal rack multimode filter with low-pass, high-pass, and band-pass modes,
  cutoff, resonance, drive, and dry/wet mix.
- Internal rack limiter with ceiling and release controls.
- Internal rack utility for gain, polarity, mono, channel selection, swap,
  sample-accurate delay, a colored test-noise generator (white, pink, brown,
  blue, violet), and loudness autogain toward a target LUFS.
- Internal rack expander and clipper.
- Internal rack crossover: a three-band Linkwitz-Riley split as its own unit,
  with per-band gain and solo.
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
- On Linux, CLAP and VST3 plugins load out of process by default, so one that
  crashes or hangs degrades to silence in its own slot instead of taking the
  session with it. `wstudio.o.sandbox_plugins = false` hosts them in-process
  instead; other platforms always host in-process.
- A hosted plugin's own editor window opens inside the session
  (`:clap-gui`, `:vst3-gui`) and follows the size the plugin reports.
- Reverb gains an impulse mode that puts a sparse room reflection pattern
  ahead of the algorithmic tail.
- Tempo and time-signature changes on the timeline: `:tempo-point <beat> <bpm>
  [step|ramp]` and `:meter-point <beat> <n>/<d>`, up to 64 of each. A `ramp`
  point glides into the next one instead of stepping. Live playback and offline
  render read the same maps.
- Punch-in/out recording inside existing arrangement A/B bounds via `:punch`.
- Recorded audio clips start with editable 5 ms boundary fades to prevent clicks.
- Piano-roll chord stamping grows beyond triads and 7ths: `o`/`O` cycle chord
  quality (6th, 9th, 11th, 13th, sus2, sus4, add9, dim, aug) and `r`/`R` cycle
  voicing (closed, drop2, open), each re-stamping in place at the cursor.
- The synth editor's related cards are tabs in the TUI too, the way the GUI
  already grouped them: `[` and `]` cycle the group, and moving the cursor
  into a hidden tab brings it forward.
- Seven more icons, and glyphs on the surfaces that had been going without:
  section headings, the two state chips, and every picker's header, which now
  says what it is picking instead of leaving you to infer it.

### Changed

- Factory synth patches were checked one at a time against the instrument each
  one names, and levelled to a common loudness within their category. The
  clavinet rings under the hand and stops dead on release, the string machine
  gets its ensemble instead of a detune, the FM bells and the electric piano
  get the ratios and index envelopes that make them read as bells and tines,
  and a choir spreads the way singers measure.
- The pattern transforms work on a slicer's grid, not only a drum machine's:
  `:clear`, `:humanize`, `:reverse`, `:normalize`, `:vel-ramp`, `:euclid`,
  `:rotate` and `:pad-len` all act on whichever step grid the cursor is on.
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
- Every effect display plots the unit itself instead of a curve drawn from
  knob positions. The amp draws its own magnitude response across 20 Hz to
  20 kHz, so the voicing, tone stack, presence and cabinet are all visible;
  the saturator draws whichever of its five curves is selected; the clipper
  draws where its ceiling sits and how the knee reaches it; the compressor
  runs the same gain computer the audio path does, so a soft knee is a knee
  and upward mode points upward; the crossover draws its summed response with
  the split points, band trims and solo mutes in it, in place of a sentence
  describing itself; utility meters short-term LUFS against its target while
  autogain works; and chorus, phaser, flanger and delay draw a real
  two-second LFO window, so RATE reads in cycles per second.
- Controls that pick between things stopped being knobs. Saturator SHAPE,
  filter MODE and the other lists read by name on a prev/next stepper, and
  the on/off switches (crossover's band solos, reverb's early reflections,
  utility's mono-below, the limiter's ALR, the gate's sidechain) read as
  toggles. A knob's filled arc was saying low-pass is "less" than band-pass.
- Parameters whose stage is switched off are greyed out rather than hidden,
  across the whole rack: the clipper's ODP knee, the limiter's ALR rows,
  utility's noise colour, level and autogain target, and a crossover band's
  gain while a solo has it muted.
- Dropped the ImPlot dependency, which nothing ever plotted.

### Fixed

- Every save re-encoded every track's full recorded audio to FLAC, even when
  nothing about that audio had changed. Autosave runs this every 30 seconds by
  default, on the UI thread, so a project with several minutes of recorded
  audio per track could stall input and redraw for over a second on every tick
  after a single unrelated edit. Each audio source now caches its encoded
  bytes and reuses them until that source's content actually changes. A drum
  pad, standalone Sampler clip, and Slicer clip had the same gap and now cache
  the same way, invalidated whenever a fresh sample is loaded onto them.
- Project-load failures printed Zig error traces from `render`, `render-stems`,
  and frontend startup, while `:edit` only named an internal error. They now
  name the project and give recovery steps for incompatible, corrupt, missing,
  and unreadable files.
- Audio bounce could replace an existing `.wsj` project when given the project
  itself as its output path. All bounce paths now refuse project destinations.
- `:export-midi` wrote directly into its destination, so a failed write could
  truncate existing work and choosing a `.wsj` path destroyed that project. It
  now uses atomic replacement and refuses project destinations.
- The built-in `wstudio render` demo still wrote directly to `out.wav`, unlike
  project bounce. It now gets the same atomic replacement and project guard.
- Release archives omitted the bundled acoustic library, and the Linux tarball
  also omitted the plugin bridge required by default sandboxing. Archives now
  carry both and verify their runtime layout before upload.
- A VST3 could crash its host by storing a non-finite or out-of-range float in
  a host message attribute, then requesting it as an integer. Cross-type
  attribute reads now reject values that cannot be represented by `i64`.
- VST3 processing objects returned null or rejected their own interfaces when
  plugins queried them through `FUnknown`. Event lists, parameter queues, and
  parameter-change lists now expose their declared interfaces correctly.
- A sandboxed VST3 effect exposed no automatable parameters at all: the bridge
  only built that list for instrument plugins, unlike direct hosting. Bridged
  loading now builds it for every plugin with a controller.
- A VST3 could crash its GUI host by returning editor rectangle coordinates
  whose width or height overflowed `i32`. Editor open and resize paths now
  reject invalid dimensions before arithmetic or native-window calls.
- A CLAP could crash its GUI host by returning or requesting a window dimension
  above native `i32` range. Embedded editor creation, adjusted sizes, and
  plugin resize requests now reject unrepresentable dimensions.
- `:comp` could overflow while sizing output from a hand-edited clip length or
  converting a huge finite beat range. It now bounds both conversions to the
  shared decoded-audio ceiling and reports how to recover.
- `:consolidate` could overcommit an enormous output for a maximum-length saved
  clip, then keep the UI busy rendering it. Consolidated audio now follows the
  same decoded-audio ceiling and asks the user to shorten the clip.
- A sandboxed VST3 returning more than 1 MiB of component and controller state
  overflowed the child RPC buffer and killed its host process during save. The
  shared wire encoder now rejects oversized state before copying it, and the
  child reports a normal save failure while staying alive.
- A missing bundled acoustic library briefly reported its load error, then
  replaced it with a false instrument-inserted message. The error now remains
  visible and tells the user to reinstall wstudio.
- Interactive sample, clip, wavetable, and SoundFont loading rejected every
  source above 64 MiB, including ordinary multi-minute audio. The bounded
  source ceiling now matches the existing 256 MiB SFZ sample limit, and an
  oversized source reports the limit and recovery instead of `StreamTooLong`.
- Audio decoding trusted a source's declared frame and channel counts before
  allocating PCM, so a small malformed or highly compressed file could request
  gigabytes. Decoded PCM now has a 256 MiB ceiling, and mono downmix reuses the
  decode buffer instead of briefly holding a second full clip. Sample-rate
  conversion enforces the same ceiling instead of allowing an extreme declared
  source rate to expand a bounded decode into multi-gigabyte output.
- Undo after `:import-midi` restored notes but left imported channel events and
  project tempo changes behind. MIDI import now records and restores all three
  as one undo/redo operation, and caps imported tempo events at the project's
  64-point limit instead of silently building an oversized map. Parser memory
  now stays within project note, event, and tempo limits even when the source
  MIDI file greatly exceeds them.
- A drum pad's play mode had no effect: every hit cut the one before it, so
  setting a pad to one-shot behaved exactly like retrigger and a long crash
  hit twice cut itself instead of overlapping. Slices already honoured the
  same setting.
- Saving a drum kit lost the pad's play mode, and reloading one did not clamp
  its choke group the way loading a project does.
- Duplicating a slicer track lost the tempo and key its clip's file name
  declared, so `:bpm-sync` on the copy fell back to the detector.
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

- The flanger's sweep was measured in frames rather than time, so its depth
  and delay range moved with the project's sample rate.
- The compressor's knee did nothing at all in upward mode: the soft knee was
  applied only on the downward path, so upward compression cornered hard at
  the threshold.
- The reverb's early reflections collapsed into the tail at the top of the
  predelay knob.
- Three stereo processing loops read one frame past the end of a buffer whose
  sample count was odd.
- An SFZ region's own volume stacked on top of the instrument's global volume
  instead of replacing it, so any bank that set both played too loud.
- The synth's noise source changed level with the sample rate, so a patch
  using noise sounded different at 44.1 kHz and 96 kHz.
- An idle pitch shifter reported 65 ms of latency it was not adding, which
  delay compensation then paid for on every track carrying one.
- A big pitch-shift move stayed flat for a whole processing block instead of
  arriving on the frame it was asked for, and utility's autogain stepped at
  every block edge instead of riding smoothly between them.
- Modulating a crossover's two split points ate the base values the knobs
  were set to, so the split walked away and never came back.
- An OTT band's soft knee stepped the gain at the threshold instead of
  easing through it.
- The crossover was the one effect that let a NaN through from a loaded
  project, and the FX picker's kind guard counted its entries rather than
  naming them, so a new unit could go missing from the list without a
  compile error.
- Six more arrangement status lines reported grid cells or raw ticks where
  they said bars: moving a clip to bar 3 announced "bar 9" at the default
  grid, a linewise cut reported four times the bars it removed, stamping
  reported beats, and `e`, `:section` and the clip resize printed ticks.
- Bar numbers shown in the arrangement status line, the automation header in
  both frontends, the `(` and `)` loop braces, `:loop-from-selection`,
  `p` (play from cursor), and the Lua clip API were all worked out by
  dividing by one fixed bar length, so every one of them disagreed with the
  arrangement ruler once a project used a meter change.
- The piano roll linked to an arrangement clip printed the clip's tick where
  it said bar, in both frontends.
- Recording into the piano roll placed the note by the project's base tempo
  rather than its tempo map, so takes past a tempo change landed on the wrong
  beat. The roll's own playhead read the same way, which hid it. `p` in the
  arrangement seeked by the same broken arithmetic.
- `:chop-notes` on a note held past the end of the pattern produced pieces
  beyond the loop end, which playback wrapped back onto beat 0.
- The shipped demo's drum track was silent. `gendemo` was written against an
  older drum machine: it never loaded a kit, its step numbers were sixteenth
  indices from when a beat held four steps rather than thirty-two, and a
  fresh machine's two-bar loop made each of the sixteen per-bar stamps evict
  the one before it, so one clip survived. The drums are back under the whole
  song, with the tom fill on bars 4, 8, 12 and 16.
- Shortening a clip left its trailing automation past the new end, where
  nothing reads it, but reopening the project pulled every one of those
  points onto the clip's last beat. A curve that had been trimmed out of the
  way came back as a jump at the end of the clip, and growing the clip again
  no longer brought the original shape back.
- The metronome clicked quarter notes whatever the time signature said, so a
  6/8 project got three clicks a bar from it and six from the count-in that
  preceded it. It now clicks the signature's own beat unit, and enabling it
  mid-bar no longer fires a click for the beat that already went by.
- Names with CJK or emoji characters were measured at one column each in the
  TUI, so any row carrying one overflowed the terminal and wrapped the frame.
- The finished frame is clamped as a whole now, not just the rows a view
  knows can run long, and the file browser, the FX chain strip, the key hints
  and long track names all stay inside their columns. Narrow cell widths the
  config accepts no longer break the piano, drum and arrangement grids.
- The step grid's bar numbers sat beside the beat lines instead of on them.
- The in-house themes had roles too dim to read, and the terminal's normal
  ANSI tier was being used for track fills.
- The GUI's transport meters were a font size out of step with their labels,
  the dynamics window now runs past full scale where a limiter actually
  works, the delay plot ran both its knobs backwards, dynamics units plot in
  dB where their curves are visible, and two display headings named the
  wrong thing.

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

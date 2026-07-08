# wstudio

A keyboard-centric digital audio workstation written in
[Zig](https://ziglang.org/) (0.16).

## Pitch

Making music without leaving the home row. wstudio borrows the modal
model from vim:

- **normal**: navigate the project, drive the transport (`space`
  play/stop, `hjkl` with counts, `gg`/`G`, ...)
- **insert**: the keyboard becomes a piano, tracker-style layout where
  the z-row is one octave (`z` = C, `s` = C#, `x` = D, ...) and the q-row
  the next; `-`/`=` shift octaves
- **visual**: `v` selects a range (steps in the piano roll/drum grid,
  bars in the arrangement); `y`/`d`/`P` yank, clear, or paste it, `esc`
  cancels
- **command**: ex-style `:` commands

And it ships batteries included: synths, samplers, a drum machine, a
sample-chopping slicer, and a full effects rack (gate, compression, EQ,
saturation, bitcrush, chorus, phaser, delay, reverb) are built in. No
plugin hunting before the first note.

## Status

Early but live, and audible. `wstudio` opens a TUI with a single blank
track; press `enter` to pick an instrument (synth, sampler, or drum
machine) and a per-track FX rack. Vim-style modal control drives it,
with live keyboard playing through ALSA on Linux (PipeWire/PulseAudio
serve its `default` device, so any desktop works) or WASAPI on Windows;
a silent wall-clock backend takes over when no device exists.

- `wstudio`: new, empty session (one blank track)
- `wstudio demo.wsj`: the curated four-track demo (lead, e-piano, bass, drums),
  arranged into a 16-bar song; opens in song mode, so `space` sweeps the
  timeline (press `A`, then `T` to compare with pattern mode)
- `wstudio render`: the offline pipeline demo rendered to a WAV

Tracks start blank: `enter` on a blank track opens the instrument
picker. Synth and sampler tracks are piano-roll sequenceable (`p`);
drum-machine tracks open the step grid (`enter`), where `e` opens the
per-pad sampler editor and `[`/`]`/`N` manage up to 8 pattern variants
(A to H) per machine. `A` opens the arrangement view, where clips
stamped from the live patterns are placed on a bar timeline; on drum
lanes `[`/`]` pick which variant to stamp (clips show their letter),
and `T` toggles between pattern and song playback. `:load-sample
<file>` swaps a sampler's clip; `:load-pad <1-64> <file>` swaps a drum
pad. File paths given to `:load-pad`, `:load-sample`, `:save`/`:w`, and
`:bounce`/`:export`/`:bounce-stems` expand a leading `~` to `$HOME`.
`:bounce`/`:export` take an optional trailing `16`/`24` to pick the WAV
bit depth (default 16) and bounce exactly an armed A/B loop region
instead of the whole song/pattern when one is set; `:bounce-stems
[dir] [16|24]` renders every non-empty track soloed in turn to
`<dir>/<track-name>.wav` (default `stems/`). `:e <file>` opens
a different project without restarting wstudio (refusing on unsaved
changes; `:e!` forces it, and `:e!` alone reverts to the last save);
`:new`/`:new!` start a blank project the same way.

## Architecture

```
src/
├── root.zig            engine library root (public API)
├── main.zig            CLI frontend (imports the library)
├── core/
│   ├── types.zig       sample format, unit conversions (frames/seconds/dB)
│   ├── ring_buffer.zig lock-free SPSC queue (the control <-> audio bridge)
│   └── wav.zig         minimal WAV reader/writer for samples and bounce
├── input/
│   └── modal.zig       vim-style modal input: modes, counts, sequences,
│                       piano key layout; pure state machine, UI-agnostic
├── tui/
│   ├── terminal.zig    raw mode + ANSI frames (POSIX termios)
│   ├── terminal_windows.zig  same, via the Windows Console VT100 mode
│   ├── input_decode.zig  ANSI/VT byte decoding shared by both terminals
│   ├── app.zig         TUI app: action dispatch, run loop
│   ├── commands.zig    the `:command` layer (table-driven via cmd.zig)
│   ├── style.zig       shared palette and output primitives
│   ├── icons.zig       Nerd Font icon glyphs (see assets/fonts/LICENSE)
│   └── views/          one renderer per view: tracks, piano roll, drum
│                       grid, sampler editor, arrangement, spectrum, ...
├── transport.zig       playhead, tempo, musical time
├── project.zig         the document: tracks, settings (control side)
├── session.zig         session factory, track lifecycle, engine wiring
├── arrangement.zig     song mode: per-track clips on a bar timeline
├── persist.zig         project save/load (.wsj JSON snapshots, see FORMAT.md)
├── midi.zig            MIDI protocol types and raw-byte parser
├── dsp/
│   ├── device.zig      Device interface (instruments + effects)
│   ├── synth.zig       polyphonic synth (sine/saw/square, ADSR)
│   ├── sampler.zig     chromatic single-clip sampler
│   ├── drum_sampler.zig step-sequenced 64-pad drum machine (banks of 8)
│   ├── slicer.zig      step-sequenced sample chopper (one clip, up to 64 slices)
│   ├── drum_kit.zig    synthesis factory for the shipped kit samples
│   ├── pattern.zig     piano-roll pattern sequencer
│   ├── eq.zig          3-band EQ
│   ├── compressor.zig  feed-forward stereo-linked compressor
│   ├── gate.zig        noise gate
│   ├── saturator.zig   tanh soft-clip saturator
│   ├── crusher.zig     bitcrusher (bit depth + sample-rate reduce)
│   ├── chorus.zig      LFO-modulated-delay stereo chorus
│   ├── phaser.zig      4-stage allpass stereo phaser
│   ├── delay.zig       stereo feedback delay
│   ├── reverb.zig      Freeverb-style reverb
│   └── spectrum.zig    FFT analyser feeding the spectrum view
└── audio/
    ├── engine.zig      RT engine: command queue, track device chains,
    │                   mixing, metering, atomic UI snapshots
    ├── backend.zig     backend interface, offline renderer,
    │                   real-time-paced null backend
    ├── alsa.zig        ALSA playback backend (device-clock paced)
    ├── wasapi.zig      WASAPI playback backend (Windows, event-driven)
    └── midi_in.zig     ALSA sequencer MIDI input (virtual port)
```

Three rules hold everything together:

1. **The audio thread never blocks.** `Engine.process` is allocation-free
   and lock-free; all mutation arrives via the SPSC command queue.
   Device buffers are allocated up front, never in `process`.
2. **The engine is a library.** Frontends (TUI now, GUI later) import
   `wstudio` and talk to the engine only through its public API.
3. **Input is a pure state machine.** Key to action mapping lives in
   `input/modal.zig` with no UI dependency, so bindings are unit-tested
   and identical across frontends.

## Building

```sh
nix develop          # zig, zls, audio libs
zig build run        # launch the TUI (space = play, i = piano mode, :q = quit)
zig build run -- demo.wsj  # open the curated four-track demo project
zig build run -- render  # offline demo: melody through the chain -> out.wav
zig build test       # all tests
zig build genkit     # re-render the embedded drum kit (after editing drum_kit.zig)
zig build gendemo    # re-write demo.wsj (after editing tools/gendemo.zig)
zig build install-font # install the TUI's icon font (see below)
nix build            # packaged build via zig.hook
zig build -Dtarget=x86_64-windows-gnu  # cross-compile the Windows build
```

### Icons

The TUI decorates a few views — instrument-kind markers, transport
play/stop, loop/help/EQ/timeline titles, an unsaved-changes warning —
with icons from a 16-glyph subset of [Symbols Nerd Font
Mono](https://github.com/ryanoasis/nerd-fonts) (MIT; see
`src/assets/fonts/LICENSE`), embedded in the binary and defined in
`src/tui/icons.zig`. They're additive: every icon sits next to existing
text/ASCII, never replacing it, so the TUI stays fully legible without
the font. To see them rendered, run `zig build install-font` (writes
`wstudio-icons.ttf` to your font directory), then `fc-cache -f` and add
it as a fallback font in your terminal — it only needs to cover a
handful of Private Use Area codepoints, so it layers cleanly under
whatever font you already use.

## Roadmap

Open items, sorted by what most blocks an artist finishing (and keeping)
a full song:

- [ ] Native PipeWire and JACK backends behind the same interface
- [ ] Plugin hosting (CLAP first)

Done:

- [x] Mouse support across every view: click to move the cursor/select a
      row, click-drag to paint drum steps or resize/move arrangement
      clips, scroll to nudge a focused parameter — a second way to trigger
      the same actions the keyboard already does, not a replacement for it
- [x] `/` fuzzy search + `n`/`N` repeat, in the tracks view and the file
      browser: type a pattern, jump to (and cycle through) matching names
- [x] Audio clips: `:load-clip [file.wav]` loads a WAV onto a sampler
      track and stamps it whole into the arrangement at the cursor bar,
      one command instead of hand-placing a piano-roll note and stamping
      it separately
- [x] Windows build: WASAPI playback backend and a Windows Console
      (VT100) terminal, cross-compiled with `-Dtarget=x86_64-windows-gnu`
- [x] Drum pad rename (`R` in the drum grid, `:pad-rename <n> <name>`):
      a shipped-kit pad ("kick") can become "808" without loading a new
      sample — persists independent of the loaded audio
- [x] `g`/`G` jump to the first/last param in the synth and sampler editors
      (and `g` jumps the drum grid's step cursor to the pattern start);
      fixed the sampler's `j`/`k` silently ignoring a typed count (`5j`)
- [x] `:scale` tab-completion (root pitch classes + scale-type names)
- [x] Command Tab-completion/popup hides commands scoped to a different
      instrument than the cursor track's (e.g. `:load-sample` only offered
      on a sampler track) — typing the full name out of scope still runs it
      and gets that command's own error
- [x] `:gain`/`:pan`/`:eq`/`:track-rename` fall back to the cursor track
      when the leading `<track>` number is omitted entirely (an explicit
      number still always means that track, avoiding any "is this a track
      or a value" ambiguity)
- [x] Per-track color (`[`/`]` in the tracks view, a fixed 7-color palette
      + none), persisted, colors the track name in both the tracks view and
      the arrangement's lane/clip rendering (falls back to the generic
      accent when uncolored)
- [x] Tracks view scrolls when there are more tracks than fit the terminal —
      the master row stays pinned at the bottom of the list
- [x] Track grouping: `v` in the tracks view selects a range, `g` creates a
      group and prompts for its name. Each group is a submix bus with its
      own FX chain (`:group-fx <n>`, the same shared chain view a track or
      the master bus uses) — member tracks sum into it before the group's
      FX applies and the result joins the master mix. Up to 8 groups
      (`:group-add`/`:group-rename`/`:group-del`, `:track-group <track>
      <group|none>` for one-off membership changes), persisted
- [x] Automation editor visual mode (`v`), range `y`/`d`/`P`, and `.` repeat —
      parity with the piano roll/drum grid/arrangement
- [x] Piano-roll horizontal zoom (`Z`): toggles between the normal
      3-char-per-step layout and a compact 1-char-per-step one so a long
      pattern's whole loop fits on screen without scrolling
- [x] Triplet grid in the piano roll (`T`): toggles the step grid between
      straight sixteenths (4 steps/beat) and sixteenth-note triplets (6
      steps/beat) — every step<->beat conversion (cursor, notes, resize,
      visual-mode ranges, the ruler) follows the active grid
- [x] Parameter automation on the timeline: track gain/pan, per arrangement
      clip (Ableton-style envelopes, not one project-wide curve) — a new
      breakpoint-grid view opened with `a` on a clip. `h`/`l` move the cursor
      along the clip's own beat axis, `j`/`k` (`J`/`K` coarse) nudge the
      value at the cursor (creating a point if none exists there), `x`
      deletes a point, `tab` cycles gain -> pan -> whichever synth params
      already have a lane on this clip -> gain.
      Playback flattens every clip's points into a whole-song curve per
      track and applies it live in song mode (falls back to the track's
      manual gain/pan in pattern mode; synth params have no "manual" side —
      they're silent until automated). Undo (`u`/`U`), mouse (click to move,
      scroll to nudge), and yank/paste all work — the last two reuse the
      arrangement's existing whole-lane snapshot and clip clipboard, since a
      clip's automation now travels with it wherever the clip goes.
- [x] Synth-param automation (synth tracks): any of `PolySynth`'s ~30
      continuous params (filter cutoff, LFO rate/depth, envelope times,
      unison, oscillator B, sub/noise levels, ...) can be automated per clip
      alongside gain/pan, picked from a grouped picker (`p` in the automation
      editor) — see `dsp/synth.zig`'s `automatable_params`. `setParamAbsolute`
      is the absolute-value counterpart to the synth editor's own relative
      `adjustParam` nudges, pushed into the device every block via the same
      `Event` path note-on/CC already use. Each track carries up to 8
      simultaneously-automated synth params (`Engine`'s per-track sparse
      slot bank) — plenty for any real arrangement.
- [x] Sidechain compression: a compressor's last param (`sidechain`, in any
      chain — track, group, or master) picks another track to detect its
      envelope from instead of its own input (`h`/`l` cycles none/track N) —
      the classic "duck the bass under the kick" trick. Sample-accurate: the
      engine renders every track referenced as a sidechain source first each
      block and captures its exact post-chain signal, so the detector always
      sees real audio, not an approximated per-block level — no instrument is
      ever double-processed in the same block even when a chain both feeds
      and consumes a sidechain source. Persisted per-compressor (additive
      `CompSnap.sidechain_source` field, no version bump).

- [x] Live recording from insert mode: `i` in the piano roll now enters
      insert mode instead of being blocked — while the transport is
      rolling, every note played on the qwerty piano layout is written
      into the pattern at the current playhead, quantized to the same
      16th-note grid as step-edit; stopped, it's pure audition like
      everywhere else `i` works. `esc` drops back to normal without
      leaving the roll.
- [x] Interactive per-track FX rack, and a `MASTER` row in the tracks view:
      a track's spectrum view (`s`) is now an FX rack. Chains start empty —
      `a` opens a picker (gate/comp/EQ/saturator/crusher/chorus/phaser/
      delay/reverb) and inserts the chosen unit after the focused slot, so
      the user decides what runs and in what order, duplicates included;
      `Tab`/`L`/`H` walk slot focus, `x` removes the focused unit, `<`/`>`
      move it along the chain, `b` toggles its bypass (kept in the chain,
      skipped by the audio path). `h`/`l` pick a param within the focused
      unit (EQ: its 10 bands), `j`/`k` (`J`/`K` coarse) nudge it. The tracks
      view gains a `MASTER` row one slot past the last track, sharing this
      exact rack UI against the master bus — non-removable, no pan/mute/
      solo/piano-roll, `-`/`+` steps its gain instead of a track's.
- [x] Procedural synth/drum presets: `:synth-preset [name]` applies a factory
      `PolySynth.Patch` (pad/bass/lead/pluck/FM-bell/etc.) to the cursor
      track's synth; `:drum-kit [name]` regenerates a drum machine's 8 pads
      from an alternate kit flavour (analog/acoustic/industrial) — both are
      plain parameter tables run through the existing synthesis code at
      select time, so extra presets/kits cost no shipped bytes; each preset
      carries a `category` (sound role/character) and `tags` (always
      `wstudio` + a genre) — the no-args listing shows each name's genre
      alongside it, e.g. `acid-bass (acid), wobble-bass (dubstep)`
- [x] Minimal netrw-style file browser: `:e`, `:load-sample`, and `:load-pad`
      open it when called with no path — `j`/`k` move, `enter`/`l` open a
      directory or pick a file, `h`/backspace go up, `~` jumps home
- [x] Master bus FX: the same user-built chain as a track's rack (identical
      `Fx` shape, up to 9 units, insert/remove/reorder/bypass/duplicates)
      applied to the summed mix before the master gain and always-on
      limiter. `M` in the tracks view opens the master EQ's live spectrum +
      band editor (`:master-eq` from the `:` prompt); the compressor is
      `:master-comp on|off|thresh|ratio|attack|release|makeup <value>`.
      Persisted (`Snapshot.master_fx`, .wsj v10)
- [x] Scale highlighting + chord stamp in the piano roll: `:scale [<root>
      [<type>]|off]` dims out-of-scale rows; `c`/`C` stamp a diatonic
      triad/seventh at the cursor, harmonized to the active scale (a plain
      major shape with no scale set)
- [x] `:ghost [on|off]` dims every OTHER melodic track's notes into the piano
      roll's background (e.g. tracing a bassline from a chord track)
- [x] `:humanize [amount]` (0-100%, default 15) jitters the current
      pattern's note timing (± a fraction of one grid step) and velocity,
      undoable like any other pattern edit
- [x] `.` repeats the last compound edit: count-scaled nudges/resizes, the
      piano-roll note grab-and-drag, and visual-mode range delete/paste
- [x] Visual mode (`v`): select a range (steps in the piano roll/drum grid,
      bars in the arrangement) and act on it with `y`/`d`/`P`
- [x] Click track (`c` / `:metronome [on|off]`): a synthesised tick on every
      beat, accented on beat 1 of each bar, mixed straight into the master
      bus in sync with the transport
- [x] Track duplicate (`Y`) and reorder (`J`/`K`): duplicate deep-copies the
      instrument, its params, FX, pattern/pad audio, and arrangement clips
      into a new track appended at the end; reorder swaps two tracks in
      place across the project, engine, and arrangement
- [x] TUI icons: a 16-glyph Nerd Font subset (embedded, `zig build
      install-font` to see them) decorates instrument kinds, transport
      state, and view titles — additive, never replacing the ASCII/text
- [x] UX round: `:q` refuses on unsaved changes (`:q!` discards), vim count
      prefixes in every editor (`3l`, `12h`), clip yank/paste/move in the
      arrangement (`y`/`P`/`<`/`>`), piano-roll note grab-and-drag (`M`),
      A/B loop region (`(`/`)`/`b`, persisted), `:` prompt history recall +
      tab-completion (arrow keys no longer leak into typed text), `~`
      expansion in file paths, `:e`/`:new` to switch or start a project
      mid-session, track rename key (`R`), tap tempo (`t`), and a silent
      `<project>~` autosave backup while there are unsaved changes
- [x] User-loaded sample audio persists across saves: WAVs are exported to a
      `<name>_samples/` directory next to the .wsj and reloaded with the project
      (format details and versioning policy: [FORMAT.md](FORMAT.md))
- [x] Undo/redo (`u`/`U`) for content edits: notes, drum patterns/variants,
      arrangement clips — including clips evicted by a stamp
- [x] Melodic clip editing, Ableton-style: clips own their notes; `e` on a
      clip opens it in the piano roll and edits write back into the clip
- [x] Arrangement clip edge-resize (`-`/`+`, count-scaled): a clip's content
      loops to fill whatever bar span it's given, melodic or drum
- [x] Time signature setting (`:sig <n>`, any /4 meter, persisted)
- [x] Master bus limiter (always on; hot mixes duck instead of clipping)
- [x] Pattern copy/paste across tracks (`y`/`P` in piano roll and drum grid)
- [x] Play-from-cursor in the arrangement view (`g`)
- [x] Drum grid per-step velocity (100/75/50/25%) and swing (50–75%)
- [x] Drum pattern length up to 64 steps (`+`/`-`, was 32); the grid scrolls
      horizontally past whatever fits the terminal width, cursor-follow like
      the arrangement/automation views' own scroll windows
- [x] Per-pad choke groups (`C` in the drum grid) — same-group pads cut each other off
- [x] TUI frontend wiring the modal input layer to a real terminal
- [x] Native audio backend (ALSA; PipeWire serves it on modern systems)
- [x] Song mode: arrangement timeline with per-track clips
- [x] Drum machine pattern variants (A-H), stampable per clip
- [x] Per-track instrument insertion (synth / sampler / drum machine / slicer)
- [x] Slicer: chop one loaded sample into up to 64 slices (`:load-slice`,
      `:slice <n>` equal-divides) and step-sequence the chops in their own
      grid (own step-timing/swing/velocity, mirroring but not sharing
      DrumMachine's — see `dsp/slicer.zig`). Every slice's `Pad.samples`
      aliases the SAME shared clip (a slice is just `{ptr, len}`, no
      per-slice duplication), reusing `dsp/pad.zig`'s existing region-trim/
      pitch/ADSR voice renderer unmodified. `[`/`]`/`{`/`}` nudge a slice's
      start/end, `_`/`=`/`<`/`>`/`r` its gain/pan/reverse. Deliberately out
      of scope for this first pass: mouse support, undo, visual mode, and
      arrangement/song-mode participation (no clip stamping yet)
- [x] More devices: EQ, sampler, drum machine (filters, chorus to come)
- [x] RT-safe parameter changes (device params over the command queue)
- [x] Project save/load, WAV bounce/export
- [x] Track solo/mute, per-note velocity, scrollable help

## License

MIT

`src/assets/fonts/wstudio-icons.ttf` is a subset of Symbols Nerd Font
Mono (MIT); see `src/assets/fonts/LICENSE`.

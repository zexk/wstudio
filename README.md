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
- **visual**: select clips and ranges
- **command**: ex-style `:` commands

And it ships batteries included: synths, samplers, a drum machine, and a
full effects rack (EQ, compression, reverb, delay) are built in. No
plugin hunting before the first note.

## Status

Early but live, and audible. `wstudio` opens a TUI with a single blank
track; press `enter` to pick an instrument (synth, sampler, or drum
machine) and a per-track FX rack. Vim-style modal control drives it,
with live keyboard playing through ALSA (PipeWire/PulseAudio serve its
`default` device, so any desktop works; a silent wall-clock backend
takes over when no device exists).

- `wstudio`: new, empty session (one blank track)
- `wstudio demo.wsj`: the curated four-track demo (lead, e-piano, bass, drums)
- `wstudio song-demo.wsj`: the same tracks arranged into a 16-bar song; opens
  in song mode, so `space` sweeps the timeline (press `A`, then `T` to compare
  with pattern mode)
- `wstudio render`: the offline pipeline demo rendered to a WAV

Tracks start blank: `enter` on a blank track opens the instrument
picker. Synth and sampler tracks are piano-roll sequenceable (`p`);
drum-machine tracks open the step grid (`enter`), where `e` opens the
per-pad sampler editor and `[`/`]`/`N` manage up to 8 pattern variants
(A to H) per machine. `A` opens the arrangement view, where clips
stamped from the live patterns are placed on a bar timeline; on drum
lanes `[`/`]` pick which variant to stamp (clips show their letter),
and `T` toggles between pattern and song playback. `:load-sample
<file>` swaps a sampler's clip; `:load-pad <0-7> <file>` swaps a drum
pad.

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
│   ├── terminal.zig    raw mode, ANSI frames, input decoding (zero deps)
│   ├── app.zig         TUI app: action dispatch, run loop
│   ├── commands.zig    the `:command` layer (table-driven via cmd.zig)
│   ├── style.zig       shared palette and output primitives
│   └── views/          one renderer per view: tracks, piano roll, drum
│                       grid, sampler editor, arrangement, spectrum, ...
├── transport.zig       playhead, tempo, musical time
├── project.zig         the document: tracks, settings (control side)
├── session.zig         session factory, track lifecycle, engine wiring
├── arrangement.zig     song mode: per-track clips on a bar timeline
├── persist.zig         project save/load (.wsj JSON snapshots)
├── midi.zig            MIDI protocol types and raw-byte parser
├── dsp/
│   ├── device.zig      Device interface (instruments + effects)
│   ├── synth.zig       polyphonic synth (sine/saw/square, ADSR)
│   ├── sampler.zig     chromatic single-clip sampler
│   ├── drum_sampler.zig step-sequenced 8-pad drum machine
│   ├── drum_kit.zig    synthesis factory for the shipped kit samples
│   ├── pattern.zig     piano-roll pattern sequencer
│   ├── eq.zig          3-band EQ
│   ├── compressor.zig  feed-forward stereo-linked compressor
│   ├── delay.zig       stereo feedback delay
│   ├── reverb.zig      Freeverb-style reverb
│   └── spectrum.zig    FFT analyser feeding the spectrum view
└── audio/
    ├── engine.zig      RT engine: command queue, track device chains,
    │                   mixing, metering, atomic UI snapshots
    ├── backend.zig     backend interface, offline renderer,
    │                   real-time-paced null backend
    ├── alsa.zig        ALSA playback backend (device-clock paced)
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
zig build gensongdemo # re-write song-demo.wsj (arranges demo.wsj into a song)
nix build            # packaged build via zig.hook
```

## Roadmap

Open items, sorted by what most blocks an artist finishing (and keeping)
a full song:

- [ ] Persist user-loaded sample audio in .wsj (today only the params
      survive a save; projects built on your own WAVs can't be reopened)
- [ ] Melodic pattern variants or clip-to-pattern recall (drums have
      variants A-H; synth/sampler tracks still have a single live
      pattern, and stamped clips can't be edited or pulled back)
- [ ] Master bus compressor/EQ (the limiter is in; glue and tone shaping
      on the mix are not)
- [ ] Undo
- [ ] Live recording from insert mode (play a take into the pattern)
- [ ] Parameter automation on the timeline
- [ ] Time signature setting (everything currently assumes 4/4)
- [ ] Audio clips: WAV clip playback on tracks
- [ ] Native PipeWire and JACK backends behind the same interface
- [ ] Plugin hosting (CLAP first)

Done:

- [x] Master bus limiter (always on; hot mixes duck instead of clipping)
- [x] Pattern copy/paste across tracks (`y`/`P` in piano roll and drum grid)
- [x] Play-from-cursor in the arrangement view (`g`)
- [x] Drum grid per-step velocity (100/75/50/25%) and swing (50–75%)
- [x] TUI frontend wiring the modal input layer to a real terminal
- [x] Native audio backend (ALSA; PipeWire serves it on modern systems)
- [x] Song mode: arrangement timeline with per-track clips
- [x] Drum machine pattern variants (A-H), stampable per clip
- [x] Per-track instrument insertion (synth / sampler / drum machine)
- [x] More devices: EQ, sampler, drum machine (filters, chorus to come)
- [x] RT-safe parameter changes (device params over the command queue)
- [x] Project save/load, WAV bounce/export
- [x] Track solo/mute, per-note velocity, scrollable help

## License

MIT

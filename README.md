# wstudio

A keyboard-centric digital audio workstation written in
[Zig](https://ziglang.org/) (0.16).

## Pitch

Making music without leaving the home row. wstudio borrows the modal
model from vim:

- **normal** — navigate the project, drive the transport (`space`
  play/stop, `hjkl` with counts, `gg`/`G`, …)
- **insert** — the keyboard becomes a piano: tracker-style layout where
  the z-row is one octave (`z` = C, `s` = C#, `x` = D, …) and the q-row
  the next, `-`/`=` shift octaves
- **visual** — select clips and ranges
- **command** — ex-style `:` commands

And it ships batteries included: synths and a full effects rack
(compression, reverb, delay, more to come) are built in — no plugin
hunting before the first note.

## Status

Early but live — and audible. `wstudio` opens a TUI with a single blank
track; press `enter` to pick an instrument (synth, sampler, or drum
machine) and a per-track FX rack. Vim-style modal control drives it,
with live keyboard playing through ALSA (PipeWire/PulseAudio serve its
`default` device, so any desktop works; a silent wall-clock backend
takes over when no device exists).

- `wstudio` — new, empty session (one blank track)
- `wstudio demo.wsj` — the curated four-track demo (lead, e-piano, bass, drums)
- `wstudio render` — the offline pipeline demo rendered to a WAV

Tracks start blank: `enter` on a blank track opens the instrument
picker. Synth and sampler tracks are piano-roll sequenceable (`p`);
drum-machine tracks open the step grid (`enter`), and `e` there opens
the per-pad sampler editor. `:load-sample <file>` swaps a sampler's
clip; `:load-pad <0-7> <file>` swaps a drum pad.

## Architecture

```
src/
├── root.zig            engine library root (public API)
├── main.zig            CLI frontend (imports the library)
├── core/
│   ├── types.zig       sample format, unit conversions (frames/seconds/dB)
│   ├── ring_buffer.zig lock-free SPSC queue (the control ↔ audio bridge)
│   └── wav.zig         minimal WAV writer for bounce/export
├── input/
│   └── modal.zig       vim-style modal input: modes, counts, sequences,
│                       piano key layout — pure state machine, UI-agnostic
├── tui/
│   ├── terminal.zig    raw mode, ANSI frames, input decoding (zero deps)
│   └── app.zig         TUI app: action dispatch, drawing, run loop
├── transport.zig       playhead, tempo, musical time
├── project.zig         the document: tracks, settings (control side)
├── dsp.zig             device rack namespace
├── dsp/
│   ├── device.zig      Device interface (instruments + effects)
│   ├── synth.zig       polyphonic synth (sine/saw/square, ADSR)
│   ├── compressor.zig  feed-forward stereo-linked compressor
│   ├── delay.zig       stereo feedback delay
│   └── reverb.zig      Freeverb-style reverb
└── audio/
    ├── engine.zig      RT engine: command queue, track device chains,
    │                   mixing, metering, atomic UI snapshots
    ├── backend.zig     backend interface, offline renderer,
    │                   real-time-paced null backend
    └── alsa.zig        ALSA playback backend (device-clock paced)
```

Three rules hold everything together:

1. **The audio thread never blocks.** `Engine.process` is allocation-free
   and lock-free; all mutation arrives via the SPSC command queue.
   Device buffers are allocated up front, never in `process`.
2. **The engine is a library.** Frontends (CLI now, TUI/GUI later)
   import `wstudio` and talk to the engine only through its public API.
3. **Input is a pure state machine.** Key → action mapping lives in
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
nix build            # packaged build via zig.hook
```

## Roadmap

- [x] TUI frontend wiring the modal input layer to a real terminal
- [x] Native audio backend (ALSA; PipeWire serves it on modern systems)
- [ ] Native PipeWire and JACK backends behind the same interface
- [ ] Note clips + sequencing on the timeline (record from insert mode)
- [x] Per-track instrument insertion (synth / sampler / drum machine)
- [ ] Audio clips: WAV reading, clip playback on tracks
- [x] More devices: EQ, sampler, drum machine (filters, chorus to come)
- [x] RT-safe parameter changes (device params over the command queue)
- [x] Project save/load
- [ ] Plugin hosting (CLAP first)

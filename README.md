# wstudio

<p align="center">
  <img src="docs/assets/promo/wstudio-github-banner-1500x300.png" alt="wstudio: make music the vim way" width="100%">
</p>

A keyboard-centric digital audio workstation written in
[Zig](https://ziglang.org/) (0.16), for the terminal and as a native GUI.

wstudio borrows vim's modal model instead of a mouse-first workflow:
**normal** mode navigates the project and drives the transport, **insert**
turns the keyboard into a piano, **visual** selects and yanks ranges, and
**command** mode runs `:` commands. It ships with synths, samplers, a drum
machine, a sample-chopping slicer, and a full effects rack (gate,
compression, EQ, saturation, bitcrush, chorus, phaser, delay, reverb) built
in, so there's no plugin hunting before the first note.

## Quickstart

```sh
nix develop                     # zig, zls, audio libs
zig build run                   # launch the TUI on a blank project
zig build run -- demo.wsj       # open the curated four-track demo
zig build run -- --gui demo.wsj # open the GUI instead
```

Without Nix, install Zig 0.16 and ALSA development libraries (Linux only)
and build the same way; see [CONTRIBUTING.md](CONTRIBUTING.md) for the
full development setup. Once running: `enter` on a blank track opens the
instrument picker, `space` plays/stops, and `:help` lists every command.

## CLAP plugins

wstudio hosts stereo CLAP instruments and effects using the
[CLAP 1.2 ABI](https://github.com/free-audio/clap). Discovery follows
`CLAP_PATH` and the platform paths required by the CLAP specification.

```sh
wstudio clap-scan
```

The scan prints `<plugin-id> <name> <path>`. In either frontend, select a
track and use:

```text
:clap-instrument <plugin-id> <path>
:clap-fx <plugin-id> <path>
:clap-param <1-based-index> [plain-value]
```

CLAP audio, notes, MIDI, transport, parameters, opaque state, latency, tails,
logging, and host callbacks are supported. Plugin identity and state are saved in
the `.wsj` project. Native plugin GUI windows, surround buses, polyphonic
modulation, and plugin-requested thread pools are not supported yet.

## Status: beta

The first public beta is live and audible. Expect rough edges, and keep
project-file backups while the `.wsj` format continues to evolve. See
[CONTRIBUTING.md](CONTRIBUTING.md) to report a bug or send a focused
change.

## Configuration

wstudio is scripted with Lua: options, keymaps, custom `:` commands, and
autocmds. On first run it writes a fully documented template to
`~/.config/wstudio/init.lua` (see [examples/init.lua](examples/init.lua));
a broken config never blocks startup. The full API is documented in
[docs/lua-api.md](docs/lua-api.md). Nix users can enable wstudio via
`nixosModules.default` or `homeManagerModules.default`, configuring it
with typed settings or raw Lua:

```nix
programs.wstudio = {
  enable = true;
  settings.default_tempo = 128;
};
```

## Learn more

- [docs/](docs/README.md) - editing grammar, UI conventions, undo/redo,
  and GUI color identity
- [FORMAT.md](FORMAT.md) - the `.wsj` save format and its version history
- [CONTRIBUTING.md](CONTRIBUTING.md) - bug reports and development setup

## License

MIT. `src/assets/fonts/wstudio-icons.ttf` is a subset of Symbols Nerd Font
Mono (MIT); see `src/assets/fonts/LICENSE`.

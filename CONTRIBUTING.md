# Contributing to wstudio

Thanks for helping test or improve the beta. Bug reports, workflow feedback,
documentation fixes, and focused code changes are all useful.

## Reporting a bug

Search existing GitHub issues first, then include:

- wstudio version or commit
- operating system and terminal
- audio stack, interface, sample rate, and MIDI device when relevant
- exact steps to reproduce, expected result, and actual result
- the smallest `.wsj` project that reproduces it, if safe to share
- terminal output or a screenshot for visual problems

For crashes or damaged projects, keep the original `.wsj` and any sidecar
sample directory. Remove private audio before attaching files publicly.

## Development setup

wstudio requires Zig 0.16 and ALSA development libraries on Linux. The Nix
development shell provides the supported toolchain:

```sh
nix develop
zig build check
```

Without Nix, install the dependencies listed in [README.md](README.md) and run
the same Zig commands directly.

Before submitting a change:

```sh
zig fmt build.zig src tools
zig build check
zig build -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows-gnu
```

Run plain `zig build` before interactive verification because the test and
check targets do not refresh `zig-out/bin/wstudio`. For TUI changes, follow
[docs/tui-screenshots.md](docs/tui-screenshots.md) and inspect the rendered
PNG, not only a text capture.

## Code expectations

- Keep the audio processing path allocation-free, lock-free, and non-blocking.
- Add tests for behavior changes and regressions. Persistence format changes
  must follow [FORMAT.md](FORMAT.md), including fixtures when required.
- Preserve `// zig fmt: off` fenced layouts. Add a fence for new deliberately
  compact code when needed, then run `zig fmt` normally.
- Comments should explain non-obvious constraints or decisions, not narrate
  the code.
- Keep changes focused. Do not mix cleanup with a behavioral fix unless the
  cleanup is necessary for that fix.

## Pull requests

Describe the user-visible result, how it was verified, and any known limits.
Include before/after screenshots for TUI changes and mention project-format or
audio-thread implications explicitly. Small pull requests are easier to test
and review.

By contributing, you agree that your contribution is licensed under the
project's [MIT License](LICENSE).

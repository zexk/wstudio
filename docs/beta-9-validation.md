# Beta.9 release-candidate validation

Run commands from repository root in Nix development shell. Generated files
stay under `.zig-cache/` or temporary directories.

## Recorded result

2026-07-29 automated gate passed on NixOS Linux x86_64, kernel 7.1.1, Zig
0.16.0:

- `zig build test` and native `zig build`: passed.
- TUI-only and GUI-only builds: passed.
- Windows x86_64 cross-build: passed.
- Nix Linux, Windows, and macOS packages: built from flake inputs.
- Nix flake and NixOS module evaluation: passed.
- ReleaseSafe Linux archive check: version, executable bit, docs, config
  template, demo project, and 36-second stereo 48 kHz PCM render passed from a
  temporary directory outside source checkout.
- Beta.7 ReleaseSafe soak: 172,802,048 frames in 42,188 blocks, ten save/load
  round trips, three exports, finite peak 0.501.
- Installed Nix binary: reported `1.0.0-beta.9`, rendered `demo.wsj` outside
  source checkout, and completed empty CLAP/VST3 scans.

## Automated gate

```sh
zig build test
zig build
zig build -Dtui=true -Dgui=false
zig build -Dtui=false -Dgui=true
zig build -Dtarget=x86_64-windows-gnu
zig build beta7-soak -Doptimize=ReleaseSafe
nix flake check --no-build
nix build .#default .#windows .#macos --no-link
```

Tag pushes run `.github/workflows/release.yml`. Each native release job builds
an archive containing executable, demo project, license, changelog, format
history, docs, and config template. Native jobs extract their archive into a
temporary directory, check version and contents, then render `demo.wsj` there.
Windows archive integrity is checked on Linux; runtime verification stays on a
Windows host.

## Environment checks still required

- TUI and GUI interactive clean-install journeys need terminal, display, and
  audible manual inspection.
- Physical audio input and MIDI selection need connected hardware activity.
- Third-party CLAP/VST3 compatibility needs installed test plugins. Current
  scans found none; bundled fixture tests passed through `zig build test`.
- Windows runtime journey needs a Windows host.
- macOS native GUI/runtime journey needs macOS hardware and Xcode SDK. Linux
  built the flake's headless aarch64 macOS package only.
- Home Manager module installation needs a Home Manager evaluation host.

# 1.0.0-beta.9 goals

Beta.9 is release-candidate work. Features and compatibility surfaces are
frozen. Work in this phase fixes release blockers, verifies supported builds,
and makes existing release artifacts reproducible from a clean checkout.

## Allowed changes

- Fix crashes, data loss, project corruption, audio corruption, security
  failures, and supported-platform build failures.
- Fix regressions against beta.8 compatibility contracts.
- Fix documentation or packaging defects that prevent installation, launch,
  configuration, project loading, plugin discovery, or export.
- Add focused regression tests and validation tooling for those fixes.

Everything else waits until after 1.0. Cosmetic work, performance work without
a measured release regression, refactors, new creative features, new plugin
capabilities, and compatibility changes are out of scope.

## Clean build and install

- Build and test from a clean checkout on Linux and Windows.
- Build and test on macOS when hardware and SDK are available. Record exact
  unavailable dependency when skipped.
- Verify Nix package, NixOS module, and Home Manager module evaluation and
  installation.
- Verify installed binary reports correct version and finds bundled assets.
- Verify TUI-only, GUI-only, and combined builds where supported.

## Release journeys

- Launch blank TUI and GUI sessions, create a project, save, reopen, edit, and
  save again.
- Open `demo.wsj` in both frontends and complete playback, editing, undo/redo,
  plugin, save/reload, render, and stem-render journeys.
- Verify invalid project paths, unsupported versions, broken config, missing
  sidecars, and missing plugins follow beta.8 error contracts.
- Verify audio and MIDI device listing and explicit device selection on
  available hardware.
- Verify CLAP and VST3 discovery, state round-trip, automation, and teardown
  with available test plugins.

## Release artifacts

- Produce release packages from documented commands without workspace-local
  files or undeclared dependencies.
- Verify archive contents, executable permissions, licenses, docs, demo
  project, and configuration template.
- Run packaged binary outside source checkout.
- Keep signing, notarization, stores, and installers limited to platforms where
  project already has working release infrastructure. Do not invent new
  distribution systems during release-candidate phase.

## Exit gate

Beta.9 exits when:

- `zig build test` and native `zig build` pass.
- Supported cross-builds pass; hardware-only skips name exact environment gap.
- Beta.7 journey and soak validation pass without regression.
- Beta.8 format corpus, Lua/config parity, CLI, command/help, and plugin tests
  pass unchanged.
- Clean-install TUI and GUI launch, open `demo.wsj`, and render valid WAVs.
- No open release blocker remains.
- Changelog, README, man page, version output, package metadata, and release
  notes agree.

After this gate, 1.0 receives no feature batch. Release beta.9 code unchanged
apart from fixes for blockers found during final promotion checks.

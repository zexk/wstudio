# 1.0.0-beta.8 goals

Beta.8 freezes compatibility surfaces before release-candidate work. It audits
what wstudio already exposes, settles accidental or contradictory behavior, and
adds migration guarantees where compatibility cannot be preserved directly. It
does not add instruments, effects, plugin formats, editors, routing models, or
production workflows.

## Freeze boundary

A change belongs in beta.8 when users, projects, scripts, configs, plugins, or
automation can observe it across versions. Make incompatible corrections now,
while migration remains possible. After beta.8, incompatible public changes
wait until after 1.0 unless required to prevent data loss, corruption, crash, or
security failure.

Included:

- `.wsj` schema defaults, validation, migrations, sidecar rules, and errors.
- Lua API names, arguments, return values, indexing, errors, and event timing.
- `wstudio.o` option names, types, ranges, defaults, frontend scope, and Nix
  module parity.
- Built-in command names, argument grammar, aliases, completion, and errors.
- Keyboard grammar shared by TUI and GUI, including counts and history edges.
- CLI commands, flags, exit behavior, output format, and documented paths.
- CLAP/VST3 saved identity, state, parameter ownership, and missing-plugin
  behavior.

Excluded:

- New creative features or broader plugin capability.
- Cosmetic redesign, performance work without measured regression, and broad
  refactors unrelated to a frozen contract.
- Release packaging, signing, installers, store metadata, and clean-install
  verification assigned to beta.9.
- Compatibility promises for undocumented internals that no saved project,
  public command, config, script, or plugin adapter can reach.

## 1. Compatibility inventory

Build one checked inventory from current code and documentation:

1. Saved JSON types and every sidecar path in `src/persist.zig` and `FORMAT.md`.
2. Lua options, API functions, events, keymaps, highlights, and commands in
   `src/config.zig`, `docs/lua-api.md`, `examples/init.lua`, and Nix settings.
3. Built-in `:` commands, aliases, arguments, completion sources, and help.
4. Modal keys by view and frontend, including mouse actions that map to edits.
5. CLI subcommands, flags, stdout/stderr shape, exit status, and man page.
6. CLAP/VST3 identity, parameter IDs, opaque state, and capability errors.

Every surface receives one disposition:

- `freeze`: supported through 1.0 without incompatible change.
- `migrate`: old spelling or shape remains accepted with documented mapping.
- `remove-now`: accidental surface removed before freeze with release note.
- `internal`: not user-visible and receives no compatibility promise.

Done when docs and implementation name same surface, and tests fail when one
copy drifts.

## 2. Project format freeze

- Reconcile `persist.file_version`, `FORMAT.md`, and historical fixtures. One
  authoritative current version must appear everywhere.
- Audit defaults for every optional field. Missing field must reproduce prior
  behavior without depending on current user config or uninitialized state.
- Audit enum growth. Older builds must reject files containing unknown saved
  variants through version bump, not fail with ambiguous JSON errors.
- Keep old read-only migration fields until all pre-1.0 fixtures using them
  load identically. New saves must not revive retired shapes.
- Verify track/rack/lane parallel-array invariants, index remaps, automation
  target ownership, group references, sidechains, and plugin IDs after load.
- Freeze sample, wavetable, SoundFont, CLAP, and VST3 sidecar naming and
  relative-path containment.
- Classify missing sidecars and missing plugins explicitly: recoverable partial
  load or transactional hard failure, with identity and reason.
- Add version only for semantic incompatibility under `FORMAT.md` policy.

Done when every historical fixture loads, current save/reload is stable, future
files reject cleanly, and failed loads leave active session unchanged.

## 3. Lua and configuration freeze

- Compare option spec table, generated template, Lua docs, NixOS module, and
  Home Manager module one-for-one. Freeze names, types, ranges, defaults, and
  enum strings.
- Decide behavior of unknown options, wrong types, invalid ranges, frontend-only
  options, config reload, and broken user/system config. Keep errors actionable.
- Freeze Lua API indexing conventions, table shapes, optional arguments, return
  values, and error messages where scripts reasonably inspect them.
- Verify project lifecycle event order for startup, new, open, save, forced
  replacement, config completion, and quit.
- Verify custom command, autocmd, keymap, highlight, track, transport, pattern,
  arrangement, FX, and project APIs keep stable ownership and mutation rules.
- Rename or remove inconsistent APIs now. Preserve old names as thin aliases
  when migration costs less than permanent ambiguity.
- Publish compatibility rule: additions allowed after beta.8; incompatible
  changes require alias/migration or wait until after 1.0.

Done when representative beta.8 scripts run unchanged against later 1.0 builds,
and automated parity tests cover every documented option and API name.

## 4. Commands and input grammar freeze

- Inventory every built-in command, alias, argument grammar, default path,
  numeric range, completion source, status message, and dirty-state rule.
- Resolve aliases that disagree in behavior. Alias must route through same
  implementation and validation.
- Freeze modal keys per view: counts, operators, motions, visual selection,
  insert/normal transitions, dot-repeat, macros, undo/redo, search, and escape.
- Compare TUI and GUI actions. Same edit must create same history boundary,
  dirty state, event, stale-editor retarget, and error.
- Keep platform shortcuts additive. Do not replace keyboard grammar with
  frontend-specific alternatives.
- Update shared help, man page, Lua command bridge, and completion whenever a
  frozen command changes.

Done when command/help tables and frontend bindings cannot drift silently, and
saved workflows need no frontend-specific workaround.

## 5. Plugin persistence freeze

- Freeze CLAP identity as binary path plus stable plugin ID; freeze VST3
  identity as bundle path plus class ID.
- Freeze opaque state encoding, empty-state meaning, component/controller split,
  parameter ID width, automation ownership, and clone behavior.
- Verify missing binary, missing class/ID, malformed state, rejected state,
  unsupported buses, and incompatible capabilities report plugin identity plus
  reason without corrupting unrelated tracks.
- Verify effect and instrument state survives clone, reorder, undo snapshot,
  save/reload, offline render, and repeated teardown.
- Keep generic parameter editing frozen around stable plugin IDs. Native editor
  windows, new buses, sandboxing, and new formats stay outside beta.8.

Done when current CLAP/VST3 fixture projects remain loadable through 1.0 and a
plugin failure cannot retarget automation or partially replace session.

## 6. CLI and documentation freeze

- Freeze `wstudio`, `--tui`, `--gui`, `-u`, `render`, `render-stems`, scans,
  `devices`, help, and version output.
- Define missing arguments, extra arguments, bad files, unsupported versions,
  output collisions, and device failures through stderr plus nonzero exit.
- Keep headless render and stem filenames stable. Output remains atomic and
  bounded by WAV format limits.
- Reconcile README, man page, help, Lua docs, FORMAT, changelog, examples, and
  Nix modules against actual behavior.
- Add migration notes for every incompatible beta.8 correction.

Done when documented clean-checkout commands match executable behavior on every
supported target and help never advertises unavailable functionality.

## 7. Compatibility corpus and exit gate

Use existing tests and fixtures, not a new framework:

- One `.wsj` fixture per semantic format version plus current round-trip file.
- Lua scripts covering options, API table shapes, lifecycle events, commands,
  keymaps, and deprecated aliases.
- TUI/GUI action tests for shared grammar and history boundaries.
- CLAP/VST3 fixture projects covering identity, state, parameters, automation,
  clone, reorder, missing plugin, and malformed state.
- CLI tests for help, errors, render artifacts, and exit status.
- Linux test/build, Windows cross-build, available macOS build/hardware, and
  beta.7 journey regression.

Beta.8 exits when:

- Every inventory row has `freeze`, `migrate`, `remove-now`, or `internal`.
- Format/docs/version fixtures agree and all historical projects load.
- Lua/config/Nix parity tests pass with no undocumented public name.
- Commands and modal grammar match shared help in both frontends.
- CLAP/VST3 saved projects round-trip with stable identity and automation.
- All incompatible changes have migration note and test.
- No open compatibility blocker remains; hardware/dependency skips name exact
  unavailable environment.

## Explicitly postponed

- New instruments, effects, plugin formats, routing, automation, or editors
- Native embedded VST3 editors and shared plugin-window hosting
- Multi-bus/surround support, plugin sandboxing, and per-note modulation
- New packaging surfaces, installers, signing, stores, and release promotion
- Post-1.0 cleanup that would break frozen beta.8 surfaces

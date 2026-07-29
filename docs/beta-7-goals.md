# 1.0.0-beta.7 goals

Beta.7 proves wstudio can finish real projects. It closes blockers found while
recording, editing, arranging, mixing, saving, reopening, and exporting complete
songs. It does not add another instrument, effect, plugin format, editor, or
general-purpose workflow framework.

## Release boundary

Work starts from reproducible end-to-end project journeys, not feature ideas.
A defect belongs in beta.7 when it prevents completion, loses or corrupts work,
produces wrong audio, or makes a core operation impractical without an external
workaround.

Included:

- Broken links between existing recording, editing, arrangement, automation,
  mixing, plugin, persistence, and export features.
- Data-loss, audio-corruption, crash, hang, and severe workflow defects found
  by complete-project testing.
- Small interaction changes required to finish a journey in both frontends.
- Diagnostics that turn a silent failure into a useful, actionable error.

Excluded:

- New instruments, effects, plugin formats, or native plugin editors.
- New editing modes, routing models, automation models, or project formats
  unless a confirmed blocker cannot be fixed within the current model.
- Cosmetic redesigns, broad refactors, and speculative convenience features.
- Beta.8 public-surface cleanup and beta.9 packaging work unless they block a
  beta.7 journey now.

## 1. Reference project journeys

Maintain a small project set that exercises the existing product as a connected
system:

1. Build song from internal melodic and drum instruments, arrange multiple
   sections, automate instrument and mixer parameters, mix, save, reopen, and
   export stereo master.
2. Record audio and live MIDI, edit resulting material, arrange it, save,
   reopen, and export stems plus master.
3. Build plugin project with one CLAP instrument, one VST3 instrument, and
   CLAP/VST3 effects where compatible plugins are available. Edit parameters,
   automate them, clone tracks and effects, save, reopen, and export.
4. Exercise groups, sidechain routing, mute/solo, loop playback, undo/redo,
   autosave recovery, and project replacement inside those projects rather than
   as isolated demos.

Each journey records exact commands, fixtures or plugin identities, expected
audible result, and artifacts produced. Keep project files small enough for
routine regression use. Do not create a new test framework; use current unit,
integration, TUI, GUI, screenshot, and render checks.

Done when every journey can run from a clean checkout, and unavailable physical
devices or third-party plugins are listed as skipped environment coverage rather
than reported as passing.

## 2. Recording and editing blockers

- Verify count-in, monitoring, arm state, audio capture, live MIDI capture, and
  stop behavior in one continuous session.
- Verify captured material survives undo/redo boundaries, track operations,
  song-mode changes, save/reopen, and export.
- Fix editor state that points at deleted, replaced, regrouped, or reordered
  tracks, clips, pads, slices, FX units, or automation lanes.
- Keep modal grammar and history boundaries consistent across TUI and GUI.
- Preserve explicit device errors. No silent fallback when user selected device
  disappears or cannot open.

Done when recorded audio and MIDI round-trip without missing, duplicated,
shifted, or stale material, and every persistent edit made during the journey
has the expected undo boundary.

## 3. Arrangement and automation blockers

- Verify pattern/song transitions, loop boundaries, clip moves and resizes,
  section edits, tempo, time signature, and playhead behavior across long runs.
- Verify automation before, inside, and after clips, including adjacent clips,
  empty lanes, loop wrap, transport seeks, and project reload.
- Verify internal, CLAP, and VST3 parameter automation uses same saved timing
  resolution and does not target wrong device after cloning or reordering.
- Fix only confirmed timing or ownership bugs. Sample-accurate ramps and new
  curve types remain outside beta.7.

Done when rendered output matches live song playback at tested boundaries and
reopening project does not change automation targets or values.

## 4. Mixing, plugins, and export blockers

- Verify track, group, and master signal flow with gain, pan, mute, solo,
  bypass, reorder, sidechain, and latency-reporting plugins.
- Verify missing, malformed, rejected, and state-incompatible plugins fail with
  plugin identity and reason while leaving previous session intact.
- Verify plugin restart, parameter rescan, clone, undo snapshot, save/reload,
  offline render, and teardown paths under repeated use.
- Compare stereo bounce and stems against live mix for routing, automation,
  tails, limiter ceiling, length, and silence handling.
- Keep unsupported bus layouts and plugin capabilities explicit. Do not widen
  beta.6 plugin scope during workflow stabilization.

Done when exports contain same intended signal flow as live playback, plugin
state survives round trip, and one failing plugin cannot corrupt unrelated
tracks or saved project.

## 5. Persistence and recovery blockers

- Exercise new project, save, save-as, overwrite, reopen, autosave backup,
  recovery, and forced replacement with complete projects.
- Test truncated JSON, malformed plugin state, missing sidecars, missing plugins,
  newer file versions, and interrupted writes.
- Keep load transactional: failure leaves current session playable and
  unchanged, with no partial files, leaked temporary state, or dirty-state loss.
- Add `.wsj` version only for actual semantic incompatibility. Additive fixes
  keep current version under FORMAT.md policy.

Done when fault-injected loads never replace a healthy session and successful
round trips preserve project content, routing, plugin identity/state, and export
settings.

## 6. Performance and soak pass

- Run repeated play/stop/seek, project open/close, plugin load/unload, recording,
  save, and export loops under existing test tools.
- Check audio callback for allocation, locks, unbounded work, stale pointers,
  NaN propagation, and buffer overruns in paths changed during beta.7.
- Measure only journey bottlenecks. Optimize when measured behavior blocks use;
  do not add caches, worker systems, or abstractions in anticipation.

Done when reference projects survive one-hour playback/seek soak, repeated
save/reload/export loops, and sanitizer or allocator checks available on host
without crash, leak, hang, or audio corruption.

## 7. Triage and exit gate

Every beta report receives one disposition:

- `blocker`: must fix before beta.7.
- `regression`: must fix or document why release remains safe.
- `later`: valid but outside production-workflow boundary.
- `cannot reproduce`: exact attempted environment and steps recorded.

Beta.7 exits when:

- All reference journeys pass on Linux plus available Windows/macOS hardware.
- Full Linux build/tests and Windows cross-build pass.
- No open crash, data-loss, audio-corruption, hang, or core-journey blocker
  remains.
- Known skips name missing hardware or third-party dependency.
- README and help describe any user-visible behavior changed while fixing
  blockers.

## Explicitly postponed

- Native embedded VST3 editors and shared plugin-window hosting
- New plugin formats, multi-bus/surround hosting, and plugin sandboxing
- Sample-accurate automation ramps, new curve types, and per-note modulation
- New instruments, effects, routing models, or editor subsystems
- Public API compatibility freeze, release signing, installers, and store work
  assigned to beta.8 or beta.9

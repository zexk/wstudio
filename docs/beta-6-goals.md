# 1.0.0-beta.6 goals

Beta.6 adds one plugin format: VST3. It does not attempt complete VST3 SDK
coverage or build a second plugin UI system.

## Release boundary

VST3 instruments and effects join the existing external plugin catalog and use
the same tracks, FX chains, parameter editor, automation, history, and project
persistence as CLAP plugins.

Supported baseline:

- Discover VST3 bundles in standard Linux, Windows, and macOS locations, plus
  one optional configured search path.
- Identify plugin classes by their 16-byte VST3 class ID. Treat duplicate class
  IDs as one plugin, with standard search-path priority deciding the winner.
- Load instruments with no main audio input and one mono or stereo main output.
- Load effects with one mono or stereo main input and output. Reject other bus
  layouts with a useful error.
- Process 32-bit audio, project and live notes, CC, pitch bend, transport state,
  tempo, and playhead position.
- Enumerate editable parameters, format displayed values, apply GUI and TUI
  edits, and feed existing automation at its current timing resolution.
- Save and restore component and controller state, binary path, and class ID.
- Report latency to the engine and service latency, parameter-value,
  parameter-title, and I/O restart notifications at safe thread boundaries.
- Provide generic parameter editing in both frontends. A plugin without an edit
  controller still processes audio but exposes no editable parameters.

Native custom editor windows are outside beta.6. VST3 views require host-owned
native parent windows and platform event integration, unlike CLAP's current
plugin-owned floating-window path. Add that later only as one shared,
cross-platform window-hosting feature.

## Implementation slices

### 1. ABI and fixture

- Pin Steinberg's MIT-licensed generated VST3 C API instead of translating the
  C++ helper SDK or adding a C++ host layer.
- Add a bundled VST3 test plugin with instrument and effect classes in one
  module.
- Cover COM-style interface queries, reference counts, class IDs, strings, and
  stream adapters with direct tests before loading third-party code.

Done when the fixture builds on Linux and Windows cross targets and a host test
can enumerate both classes.

### 2. Discovery and catalog

- Resolve platform bundle layouts to their native module binary.
- Scan factories and add audio-module classes to `plugin_catalog.Catalog` with
  format, role, class ID, name, vendor, and bundle path.
- Add `vst3_plugin_path` and `wstudio vst3-scan`.
- Render catalog labels from `plugin.format`; remove remaining hardcoded CLAP
  labels and unreachable VST3 picker branches.

Done when both pickers show fixture instrument and effect classes and scan
failures skip one bad module without hiding valid modules.

### 3. Lifecycle and realtime processing

- Instantiate component and controller, connect their connection points when
  present, activate accepted buses, set processing, and tear down in reverse
  order.
- Adapt engine audio, events, parameter queues, and process context without
  allocation or locks on audio thread.
- Keep main-thread callbacks queued for existing service pass.

Done when fixture instrument receives notes, fixture effect transforms mono and
stereo audio, transport context is correct, and repeated start/stop/load/unload
runs cleanly.

### 4. Host integration and persistence

- Add VST3 instrument and effect payloads without duplicating editor behavior.
- Route parameter edits, automation, latency, cloning, undo snapshots, and
  project load/save through format-neutral call sites where CLAP-specific calls
  currently leak upward.
- Bump `.wsj` format once. Persist both opaque state streams and reject malformed
  class IDs or state data without partially loading a project.

Done when fixture projects round-trip instruments, effects, parameters, state,
notes, and automation, and missing plugins produce explicit load errors.

### 5. Compatibility pass

- Test at least one real instrument and one real effect on Linux, Windows, and
  macOS where hardware is available.
- Cross-build full Linux and Windows applications in CI-equivalent commands.
- Document supported buses, state behavior, search paths, and custom-editor
  limitation in README and Lua API docs.

Done when bundled integration tests pass, real plugins complete scan/load/play/
edit/save/reload cycles, and no CLAP workflow regresses.

## Explicitly postponed

- Native custom VST3 editor windows
- Multiple main buses, sidechains, surround, and dynamic bus negotiation
- Sample-accurate parameter ramps beyond current automation timing
- Note expression, per-note modulation, MIDI 2.0, program lists, and unit trees
- Plugin sandboxing, scan subprocesses, compatibility replacement metadata,
  and 32-bit plugin bridging
- VST2

These are not beta.6 exit criteria. Unsupported mandatory behavior must fail
with a named error rather than silently misroute audio or state.

## References

- [Steinberg VST3 C API](https://github.com/steinbergmedia/vst3_c_api)
- [Steinberg plugin locations](https://steinbergmedia.github.io/vst3_dev_portal/pages/Technical%2BDocumentation/Locations%2BFormat/Plugin%2BLocations.html)
- [Steinberg host guidance](https://steinbergmedia.github.io/vst3_dev_portal/pages/FAQ/Hosting.html)

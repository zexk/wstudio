# Beta.8 compatibility inventory

This inventory freezes user-visible surfaces through 1.0. Detailed names live
in executable registries where one exists. A registry row inherits disposition
shown here, so this document does not duplicate hundreds of command and key
names.

## Freeze

- Project JSON types, defaults, and sidecar paths: `Snapshot` and related
  snapshot types in `src/persist_types.zig`, with the version pin and sidecar
  policy in `FORMAT.md`.
- Lua options: `Config` and `option_specs` in `src/config.zig`. Tests require
  every name in Nix schema, `examples/init.lua`, and `docs/lua-api.md`, and
  require Lua and Nix theme enum parity.
- Lua functions and metadata: `api_functions`, `Event`, highlight, view, mode,
  and option registries in `src/config.zig`. `get_api_info()` exposes live
  names and `has()` supports additive feature detection. API level 1 is frozen.
- Built-in commands and aliases: `cmds` in `src/ui/commands.zig`. Dispatch,
  completion, Lua command execution, and help consume same definitions.
- Keyboard grammar and mouse edit mappings: `src/input/modal.zig`, shared
  editors under `src/ui/editors/`, and `src/ui/help.zig`. Frontends translate
  input into these shared actions; frontend tests cover edit and history edges.
- CLI commands and flags: parser and help in `src/main.zig`, man page in
  `docs/wstudio.1`. Output is plain text; errors go to stderr and exit nonzero.
- CLAP identity and state: binary path, stable plugin ID, Base64 opaque state,
  and stable parameter IDs in `ClapSnap` and `src/clap/`.
- VST3 identity and state: bundle path, 32-character class ID, separate Base64
  component/controller streams, and 32-bit parameter IDs in `Vst3Snap` and
  `src/vst3/`.

## Migrate

- Project files load only at the exact current `file_version`; there are no
  migrations. wstudio shipped with no installs in the wild, so every older
  `.wsj` was a dev-only artifact (see `FORMAT.md`).
- Command aliases listed by `cmds` route to same handlers as canonical names.
  They remain accepted through 1.0 but stay out of compact help listings.

## Remove now

- None. Beta.8 audit found no undocumented public spelling whose removal costs
  less than keeping it through 1.0.

## Internal

- Zig types and functions not reachable through project JSON, Lua, commands,
  input, CLI, config, or plugin adapters.
- GUI and TUI rendering details after shared actions resolve.
- DSP implementation details that do not change saved state or parameter IDs.

After beta.8, additions may extend these surfaces. Incompatible changes need
an accepted alias or migration, unless required to prevent data loss,
corruption, crash, or security failure.

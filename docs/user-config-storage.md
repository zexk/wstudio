# User configuration storage

Small pieces of user state live as JSON files in the same directory
`init.lua` does, resolved by `config.userConfigDir`:
`$XDG_CONFIG_HOME/wstudio`, else `%APPDATA%\wstudio` on Windows, else
`~/Library/Application Support/wstudio` on macOS, else `~/.config/wstudio`.

| File | Contents |
| --- | --- |
| `bookmarks.json` | File-browser bookmarks |
| `cmd_history.json` | The last 50 submitted `:` commands |
| `instrument_presets.wspreset` | Versioned synth + ordered FX-chain presets |
| `drum_kits.json` | User-saved drum pad tuning |

These files are optional conveniences, not project content. If no
configuration directory resolves or a file does not exist, startup continues
with an empty list.

They previously resolved through `$HOME` alone (`$USERPROFILE` on Windows),
which put them somewhere other than `init.lua` for anyone with
`$XDG_CONFIG_HOME` or `%APPDATA%` set. macOS also previously used
`~/.config/wstudio`. `load` still reads that older location when the current
one holds nothing, so existing files keep working; `save` only writes the
current location, so the first save after the change migrates the file.

Each store loads once during `App.init`. Changes rewrite the complete
collection because the files are small and this keeps their formats simple.
Callers treat write failures as non-fatal: the in-memory change still applies,
but may not survive the current run.

Writes go to a temporary sibling first and are then renamed over the target.
This prevents an interrupted write from leaving a truncated configuration
file. If an existing file cannot be parsed, it is renamed to a quarantine path
instead of being treated as an ordinary empty collection. A later save can
then create a valid file without destroying the unreadable original.

`src/ui/json_store.zig` implements the shared path, load, quarantine, and
atomic-write operations. Each caller retains its own snapshot type and
allocation logic because entries range from plain strings to structures with
nested owned fields.

## Instrument preset boundary

`instrument_presets.wspreset` is JSON with format marker
`wstudio-instrument-preset` and its own version, independent from `.wsj`.
Each entry contains synth parameters and complete ordered FX chain. Applying
or auditioning one replaces both together. Track name, color, mixer state,
group routing, notes, patterns, clips, and automation remain project content.

On first startup without new file, `synth_presets.json` entries import as
synth-only presets and new file is written. Old user presets never contained
external rack FX, so empty imported chain preserves their full saved state.

## Drum kit boundary

A saved drum kit contains pad tuning only: names, gain, pan, pitch, envelopes,
and choke groups. It carries no sample audio. Applying one layers that tuning
over the samples already loaded on the pads. Factory kits remain separate
because their procedural audio is compiled into the application, while user
sample audio belongs to the project's own `.wsj` audio cache.

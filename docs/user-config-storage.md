# User configuration storage

Small pieces of user state live as JSON files under
`~/.config/wstudio/`:

| File | Contents |
| --- | --- |
| `bookmarks.json` | File-browser bookmarks |
| `cmd_history.json` | The last 50 submitted `:` commands |
| `synth_presets.json` | User-saved synth patches |
| `drum_kits.json` | User-saved drum pad tuning |

These files are optional conveniences, not project content. If the home
directory cannot be resolved or a file does not exist, startup continues with
an empty list. On Windows, the path resolver falls back to `USERPROFILE` when
`HOME` is unavailable.

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

## Drum kit boundary

A saved drum kit contains pad tuning only: names, gain, pan, pitch, envelopes,
and choke groups. It carries no sample audio. Applying one layers that tuning
over the samples already loaded on the pads. Factory kits remain separate
because their procedural audio is compiled into the application, while user
sample audio belongs to a project's `.wsj` sidecar.

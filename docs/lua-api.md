# Lua API design

Design for wstudio's user-facing Lua API. The bootstrap already ships on this
branch: a bundled Lua 5.4 interpreter (built from source in `build.zig`, no
system dependency), `~/.config/wstudio/init.lua` loaded at startup, and a
`wstudio.o` option proxy backed by `src/config.zig`. This document defines
where the API goes from there.

Neovim is the reference. Its API survived a decade of GUIs, plugins, and
embedders because of a few structural decisions, not because of any single
function. Those decisions are what we copy. Sources studied: `runtime/doc/
api.txt` (the api-contract), `runtime/doc/dev.txt` (dev-api guidance and the
naming tables), `runtime/lua/vim/keymap.lua`, `runtime/lua/vim/_options.lua`,
`runtime/lua/vim/ui.lua`.

## What we take from Neovim

**Two layers.** Neovim has a strict core API (`vim.api.nvim_*`: versioned,
frontend-neutral, dumb data in and out) and an ergonomic Lua stdlib on top
(`vim.keymap.set`, `vim.o`, `vim.cmd`) implemented purely as wrappers over
the core. Clients that need stability target the core; humans writing configs
use the sugar. We adopt the same split: `wstudio.api.*` is the contract,
everything else on the `wstudio` table is convenience built on it.

**The contract is additive.** Released `wstudio.api` functions never change
signature. Extension happens by adding fields to an `opts` table, adding new
functions, or adding fields to returned tables. Old configs keep working.
This is the single most valuable rule in Neovim's API and it costs nothing
to adopt from day one.

**Opts tables, not positional flags.** Every function that could ever grow
takes a final optional `opts` table. No mutually exclusive positional
parameters.

**A small verb vocabulary.** From Neovim's dev-naming table, the verbs we
use and their meanings: `get`/`set` (values), `create`/`del` (non-trivial
things with identity), `add` (append to a collection), `has`/`is_enabled`
(predicates), `exec`/`eval` (code), `on_...` (event handler fields). One
noun form per concept: `track` not `channel`, `fx` not `effect`, `cmd` not
`command`.

**Functions take explicit targets.** Neovim regrets APIs that implicitly act
on "the current buffer". Ours take a track index, clip index, etc., with `0`
meaning "the track under the cursor" for convenience (mirroring Neovim's
"0 means current" convention).

**What we skip, for now.** msgpack-RPC and external clients (nothing needs
it yet, but the `wstudio.api` layer is shaped so a future RPC server can
expose it mechanically, the way Neovim generates dispatch from its api/
headers). API metadata introspection. `vim.ui`-style overridable prompts.
Per-scope option variants (`vim.bo`/`vim.wo`): wstudio options are global.

## Architecture

### One core, two frontends

The GUI wraps the TUI `App` as its model (`core: tui_app.App` in
`src/gui/main.zig`), forwards keyboard input into `core.handleKey`, and
renders the same `commands.cmds` table in its own command palette. That
means the entire Lua integration lives in the shared core, and both
frontends get it for free:

- Keymaps hook `App.handleKey`, which both frontends call.
- User commands append to the same dispatch table both frontends consult.
- Events are emitted from core mutation points (`setStatus`, project
  load/save, transport changes), never from frontend draw code.

Frontend-specific surface is namespaced and clearly marked: options that only
affect one frontend carry a `tui_` or `gui_` prefix, and `wstudio.frontend`
(`"tui"` or `"gui"`, known from argv before `init.lua` runs) lets configs
branch. Everything unprefixed must work identically in both.

`main.zig` currently constructs the `Runtime` only on the TUI path; the GUI
path must gain the same call so one `init.lua` configures both.

### Threading

The audio thread is wstudio's equivalent of Neovim's "fast context", with a
harder rule: **Lua never runs on the audio thread, ever**. All Lua executes
on the control thread, in two places only:

1. `init.lua`, once, before the frontend starts.
2. Callbacks (keymaps, user commands, event handlers), invoked from the
   frame loop between input handling and drawing.

API functions that touch engine state route through the existing
`engine.send(Command)` SPSC queue, exactly like every built-in keybinding
already does. Lua gets no new powers and no new races; it is another producer
of the same commands. Reads (`get_tempo`, track state) read the control-side
mirror (`session.project`), same as the UI does.

Consequence: no `schedule`/`defer` machinery is needed. Every callback
already runs in a context where the full API is legal. If we ever add Lua
timers or async, they queue onto the frame loop.

### Lifetime

`config.Runtime` (the `lua_State`) currently dies in `main` after extracting
a `Config` struct. For callbacks it must outlive startup: `App` gains a
`*Runtime` pointer, and the runtime holds its callback registry (keymaps,
commands, autocmds) in the Lua registry, keyed by integer ids handed back to
Zig. Zig never stores Lua values directly, only registry ids.

## The `wstudio` global

```
wstudio.version          -- "1.0.0-beta.1"
wstudio.frontend         -- "tui" | "gui"
wstudio.o                -- option proxy (shipped)
wstudio.keymap           -- keymap.set / keymap.del
wstudio.cmd(...)         -- run a `:` command line
wstudio.notify(msg)      -- status-line message
wstudio.api              -- the core API (the contract)
```

`require` of user modules works out of the box: startup prepends
`~/.config/wstudio/lua/?.lua` (and `?/init.lua`) to `package.path`, mirroring
Neovim's `lua/` runtime directory. That is the whole plugin story for now
and it costs a few lines.

## Options: `wstudio.o`

Shipped shape (Neovim's `vim.o`): a proxy table whose `__index`/`__newindex`
validate in Zig and fail loudly on unknown names or out-of-range values.

Two changes to the implementation, no change to the surface:

1. **Comptime option table.** `src/config.zig` currently validates each
   option in a hand-written if-chain, get and set separately: the exact
   hand-synced pattern this codebase has repeatedly replaced with comptime
   spec tables (`synth_layout.zig`, `param_specs`, `pad.zig`). Replace it
   with one table of `.{ name, field, min, max, scope }` rows; getter,
   setter, validation, and the future `:help` listing all derive from it.
   Adding an option becomes one line.

2. **Scope column.** Each option is marked `core`, `tui`, or `gui`. Scope is
   documentation and naming discipline (prefix enforcement), not access
   control: a TUI session may still set `gui_*` options, they just have no
   effect, so one config file serves both frontends without branching.

Initial option set (current six plus GUI candidates):

| option | scope |
| --- | --- |
| `default_tempo`, `default_sample_rate`, `default_beats_per_bar` | core |
| `audio_block_frames`, `tap_timeout_ms` | core |
| `frame_poll_ms` | tui |
| `gui_font_size`, `gui_vsync` | gui |

Project-level values (tempo of the open project, etc.) are **not** options;
they are engine state, reached through `wstudio.api`. Options are
startup/preference state only. This is the `vim.o` vs buffer-content line.

## Keymaps: `wstudio.keymap`

```lua
wstudio.keymap.set("n", "gp", function() wstudio.api.play() end)
wstudio.keymap.set("n", "<space>", ":toggle-play", { view = "tracks", desc = "play/pause" })
wstudio.keymap.set({ "n", "v" }, "Q", ":q")
wstudio.keymap.del("n", "gp")
```

- `mode`: `"n"`, `"i"`, `"v"` (or a list), matching `input/modal.zig`'s
  `Mode` enum. Command and search modes are not mappable.
- `lhs`: a key chord in Neovim notation (`"g"`, `"<c-p>"`, `"<f5>"`). A
  small parser maps notation to `modal.Key`; multi-key sequences reuse the
  pending-key mechanism the `g`/`d`/`y` prefixes already use.
- `rhs`: a Lua function, or a string starting with `:` dispatched through
  the command layer. Two forms only, no feed-keys remapping: wstudio
  bindings are actions, not macro expansion, so Neovim's noremap/recursive
  distinction (the messiest part of its keymap API) is deliberately absent.
- `opts.view`: restrict to one `AppView` name (`"piano_roll"`, `"tracks"`,
  ...). Omitted means every view.
- `opts.desc`: shown by `:help` next to built-in bindings.

Dispatch: `App.handleKey` consults the user keymap registry first; a match
consumes the key. User maps therefore shadow built-ins, which is the point
(rebinding). There is no way to break `:` (command mode is not mappable), so
`:help` and recovery always work.

## Commands

```lua
wstudio.cmd("bpm 140")                 -- anything the `:` prompt accepts

wstudio.api.create_user_command("swing", function(opts)
  wstudio.notify("swing " .. opts.args)
end, { desc = "<amount>  set swing feel", scope = "drum" })

wstudio.api.del_user_command("swing")
```

`create_user_command` appends a `cmd.Def` to a user-command list consulted
by `cmd.dispatch` after the built-in table (built-ins win on collision).
`desc` and `scope` flow into the existing `:help` view and Tab-completion
popup untouched, because those already render from `cmd.Def`. The GUI's
command palette lists user commands automatically for the same reason.

The handler receives one `opts` table (Neovim's shape): `opts.args` is the
raw tail; future fields (`opts.fargs`, `opts.bang`) can be added without
breaking anyone.

## Events: `wstudio.api.create_autocmd`

Neovim's autocmd shape, minus patterns and groups until something needs
them:

```lua
wstudio.api.create_autocmd("PlaybackStart", {
  callback = function(ev) wstudio.notify("rolling at " .. ev.tempo) end,
})
wstudio.api.create_autocmd({ "ProjectSavePost" }, {
  callback = function(ev) print("saved " .. ev.path) end,
  once = true,
})
wstudio.api.del_autocmd(id)
```

`create_autocmd` returns an integer id. `callback` receives one event table
with `event` (the name) plus per-event fields. Returning `true` from a
callback deletes it (Neovim's convention), `once = true` does the same after
the first fire.

Initial event set, all emitted from core code paths so both frontends fire
them identically:

| event | fields | fires |
| --- | --- | --- |
| `ConfigDone` | | after init.lua finishes, frontend running |
| `ProjectLoadPost` | `path` | after a .wsj loads (open, `:e`) |
| `ProjectSavePre` / `ProjectSavePost` | `path` | around `:w` |
| `PlaybackStart` / `PlaybackStop` | `tempo` | transport start/stop |
| `TrackAdd` / `TrackDel` | `track` | track list changes |
| `ViewEnter` | `view`, `prev` | `AppView` switches |
| `QuitPre` | | before shutdown, project still alive |

Callbacks fire on the frame loop in registration order. An error in one
callback reports to the status line and does not stop the others (Neovim
semantics).

## Scripting the project: `wstudio.api`

The core API. Frontend-neutral, contract-bound, everything above is sugar
over it. Initial surface, grouped by topic:

```lua
-- transport
wstudio.api.play()
wstudio.api.stop()
wstudio.api.is_playing()                  -> boolean
wstudio.api.get_tempo()                   -> number
wstudio.api.set_tempo(bpm)

-- tracks (1-based indices; 0 = track under the cursor)
wstudio.api.track_count()                 -> integer
wstudio.api.track_get(i)                  -> { name, kind, gain_db, pan, muted, soloed, group }
wstudio.api.track_set(i, { gain_db = -3.0, muted = true })
wstudio.api.track_add({ kind = "synth", name = "lead" }) -> integer
wstudio.api.track_del(i)

-- status / prompt
wstudio.api.notify(msg)
wstudio.api.exec(cmdline)                 -- what wstudio.cmd wraps
```

Design decisions:

- **1-based track indices.** Neovim chose 0-based API indexing to match its
  internals and it is a permanent footgun for Lua users. Our API is
  Lua-first and user-facing; track 1 in the API is track 1 on screen. The
  Zig boundary converts once.
- **Indices, not handles.** Tracks have no stable identity today; every
  internal subsystem remaps indices on delete/move, and the 2026-07-11 bug
  hunt showed what stale indices cost. Rather than pretend, the API
  documents Neovim's own cursor-position honesty: an index is valid at call
  time, and `TrackAdd`/`TrackDel` events exist to react to changes. If
  scripting grows heavy use, stable track ids become a core engine change
  first and an API change second (new `track_id` field in `track_get`,
  additive, contract-safe).
- **`track_set` takes a partial table**, not one setter per field. Fields
  map onto existing `engine.send` commands (`set_track_gain`, ...), so each
  named field is applied atomically on the audio thread; unknown fields are
  a loud error.
- **`kind` strings** match the `cmd.Scope` names already user-visible in
  `:help`: `"synth"`, `"drum"`, `"sampler"`, `"slicer"`.
- Deeper surface (clips, notes, FX chains, automation) is deliberately
  deferred. Each will follow the same pattern (`clip_get(track, i)`,
  `fx_add(track, kind)`), but designing them before anyone scripts them
  would be guessing. The contract's additive rule means deferring is free.

## Error handling

- Config errors (`init.lua` fails to parse or run): report the Lua
  traceback to stderr and the status line, then continue with defaults.
  A broken config must never brick the DAW, same as Neovim.
- API misuse (bad option value, unknown field, index out of range): raise a
  Lua error via `luaL_error` with a message naming the argument and the
  valid range, catchable with `pcall`. Already the shipped behavior for
  `wstudio.o`.
- Callback errors: caught at the Zig boundary (`lua_pcall`), shown once in
  the status line, never fatal.

## Implementation phases

1. **Shipped.** Lua runtime, `init.lua` loading, `wstudio.o` with six
   options, Nix modules.
2. **Foundations (shipped).** Comptime option spec table replacing the if-chains;
   config loading on the GUI path; `wstudio.frontend`; `package.path` for
   `~/.config/wstudio/lua/`; `wstudio.notify`; `wstudio.cmd` /
   `wstudio.api.exec` (needs the Runtime threaded into `App`).
3. **Commands.** `create_user_command` / `del_user_command`, `:help` and
   completion integration.
4. **Keymaps.** Notation parser, registry, `handleKey` hook, `keymap.set`/
   `keymap.del`.
5. **Events.** Registry, core emission points, the initial event table.
6. **Project API.** Transport and track functions above.
7. **Parked.** RPC server over `wstudio.api`, API metadata, clips/notes/FX
   surface, stable track ids, timers/async.

Each phase is independently shippable and testable headless through
`Runtime.loadString`, the way the existing option tests already work.

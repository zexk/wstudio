# Lua API design

Design for wstudio's user-facing Lua API. The bootstrap already ships on this
branch: a bundled Lua 5.4 interpreter (built from source in `build.zig`, no
system dependency), the platform user config `init.lua` loaded at startup,
automatic first-run generation from `examples/init.lua`, and a `wstudio.o`
option proxy backed by `src/config.zig`. This document defines
where the API goes from there.

The user-facing reference is [examples/init.lua](../examples/init.lua), the
fully documented template used to generate a missing user config. It covers
every option, keymap notation, event, and API function; this document covers
the design behind it.

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
headers). `vim.ui`-style overridable prompts.
Per-scope option variants (`vim.bo`/`vim.wo`): wstudio options are global.

## Architecture

### One core, two frontends

The frontend-agnostic `App` lives in `src/ui/app.zig`. The GUI wraps it as
its model (`core: app_mod.App` in `src/gui/app.zig`), forwards keyboard
input into `core.handleKey`, and renders the same `commands.cmds` table in
its own command palette. That means the entire Lua integration lives in the
shared core, and both frontends get it for free:

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
wstudio.version          -- "1.0.0-beta.3"
wstudio.frontend         -- "tui" | "gui"
wstudio.o                -- option proxy (shipped)
wstudio.keymap           -- keymap.set / keymap.del
wstudio.cmd(...)         -- run a `:` command line
wstudio.notify(msg)      -- status-line message
wstudio.api              -- the core API (the contract)
```

`require` of user modules works out of the box: startup prepends
the user config directory's `lua/?.lua` (and `?/init.lua`) to `package.path`,
mirroring Neovim's `lua/` runtime directory. That is the whole plugin story
for now and it costs a few lines.

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

Current option set (see examples/init.lua for defaults and ranges):

| option | scope |
| --- | --- |
| `preferred_frontend` | core |
| `default_tempo`, `default_sample_rate`, `default_beats_per_bar` | core |
| `default_octave`, `default_velocity`, `default_master_gain_db`, `autosave_interval_s` | core |
| `audio_block_frames`, `audio_backend`, `tap_timeout_ms` | core |
| `note_preview_ms`, `cmd_history_lines`, `status_message_ms` | core |
| `default_browse_dir`, `default_project_path`, `file_browser_show_hidden` | core |
| `default_drum_grid`, `default_piano_grid`, `default_arrangement_grid` | core |
| `default_piano_triplet_grid`, `default_piano_note_length_steps`, `default_piano_pitch` | core |
| `piano_ghost_notes`, `undo_history_entries`, `default_metronome_enabled` | core |
| `default_song_mode`, `metronome_click_gain` | core |
| `count_in_bars`, `default_midi_velocity_curve` | core |
| `default_automation_gain_step_db`, `default_automation_pan_step` | core |
| `frame_poll_ms`, `tui_mouse`, `tui_theme`, `has_nerdfonts` | tui |
| `gui_font_size`, `gui_vsync`, `gui_theme`, `gui_panel_border` | gui |
| `gui_window_width`, `gui_window_height` | gui |
| `gui_knob_drag_pixels`, `gui_envelope_drag_pixels`, `gui_meter_decay_db_s` | gui |

Enum-typed options (`gui_theme`, `tui_theme`, `preferred_frontend`,
`audio_backend`) read and write as strings; the spec table derives the
valid-name list and its error message from the Zig enum.

### Theming and highlights

One named color identity per built-in theme (`src/theme_identity.zig`: `patina`,
`patina_light`, `graphite`, `graphite_light`, `umbra`), rendered through two different
pipelines - Neovim's `:colorscheme` + highlight-group split, but with the
"one highlight table, many things read it" idea stretched across frontends
instead of across syntax groups. wstudio's own `:colorscheme` (below) picks
one by name at runtime, same as Neovim's.

Theme plugins can layer sparse semantic overrides over that identity, much
like Neovim colorschemes call `nvim_set_hl`:

```lua
wstudio.api.set_hl("bg0", { fg = "#101218" })
wstudio.api.set_hl("focus", { fg = "#89b4fa" })
wstudio.api.set_hl("track1", { fg = "#f38ba8" })
local focus = wstudio.api.get_hl("focus") -- { fg = "#89b4fa" }
wstudio.api.set_hl("focus", {})           -- clear override, reveal base
```

The semantic groups are `bg0` through `bg5`, `fg0` through `fg3`, `line`,
`line_soft`, `focus`, `focus_soft`, `track_cursor`, `modulation`, `danger`,
`rhythm`, `audio`, `blue`, and `track1` through `track7`. Colors are
`#rrggbb`. `set_hl` works while `init.lua` is loading and after startup;
live changes repaint the GUI or reprogram an enabled TUI palette on the next
frame. An empty spec clears that one override. Overrides are reset and then
redeclared when `:reload-config` sources the config again, so a Lua module can
be a complete, repeatable colorscheme:

```lua
-- ~/.config/wstudio/lua/colors/mocha.lua
local api = wstudio.api
api.set_hl("bg0", { fg = "#11111b" })
api.set_hl("bg1", { fg = "#181825" })
api.set_hl("fg0", { fg = "#cdd6f4" })
api.set_hl("focus", { fg = "#89b4fa" })
return true

-- init.lua
require("colors.mocha")
```

Patina remains the default built-in identity, but it is no longer named at
draw sites. GUI code reads a generic active palette, and the same semantic
override table is resolved for the TUI's ANSI slots.

- **GUI** (`gui_theme`, default `"patina"`): the identity's hex values
  become the imgui panel skin's float RGBA (`gui/style.zig`). Applies at
  startup, on `:colorscheme`, and on `:reload-config`.
- **TUI** (`tui_theme`, default `"none"`): the identity is instead pushed
  into the *terminal's* ANSI palette via OSC 4 (16-color slots) and OSC
  10/11 (default fg/bg) - see `src/tui/theme.zig`. This means none of the
  ~30 view files that print `ansi.zig`'s `acc`/`grn`/`yel`/... constants
  needed to change; those stay literal comptime SGR strings (still safe to
  `++`-concatenate with `bold`/`dim` at their existing call sites), and only
  what a given ANSI index *renders as* changes.

  `tui_theme` defaults to `"none"` (the terminal's own palette, untouched)
  rather than mirroring `gui_theme`'s branded default, because OSC 4/10/11
  recolor the whole physical terminal, not a window wstudio owns - under
  tmux/screen (which forward these codes by default) every other pane
  sharing that terminal repaints too, for as long as wstudio runs (it's
  reset via OSC 104/110/111 on quit or when the option changes back to
  `"none"`). That's a call worth making on purpose, not a default to spring
  on someone who already picked their terminal's colors.

### Icons: `has_nerdfonts`

Same idea as yazi's/kickstart.nvim's option of the same shape: a terminal
capability the TUI cannot reliably probe for itself, so it asks. `false`
(the default) makes every icon call site in `src/ui/icons.zig` fall back to
plain ascii - a mnemonic letter or symbol where no adjacent text already
says the same thing (`M`/`S` for mute/solo, `*` for the dirty-flag warning),
otherwise nothing at all (a view's own title text, an instrument's full
name in a picker row, already carries the meaning the icon would have
repeated). `true` renders the real glyphs from wstudio's embedded Nerd Font
subset instead.

This is independent of `zig build install-font`, which writes that same
embedded font to your font directory and is detected automatically
(`icons.detectFontInstalled`) - the two are OR'd together at startup and on
`:reload-config`, so running the installer is still enough on its own.
`has_nerdfonts` exists for everyone else: a system-wide Nerd Font already in
your terminal, a remote/SSH session, or any other setup the filesystem
probe can't see.

`audio_backend` picks the playback backend: `"auto"` (the default) tries
PipeWire, then JACK, then ALSA, falling through to the silent wall-clock
backend; the other names force one backend (still falling back to silence
when it cannot start). On Windows everything except `"none"` means WASAPI.
PipeWire and JACK are loaded at runtime, so a missing library behaves like
a missing server. JACK cannot resample: a server running at a different
rate than the project fails over to ALSA under `"auto"`.

`preferred_frontend` picks the frontend a flagless `wstudio` launch runs
(`--tui`/`--gui` always win, as does a build carrying only one frontend).
Because init.lua itself decides the frontend on such a launch,
`wstudio.frontend` still reads `"tui"` while init.lua runs flagless; it is
corrected before ConfigDone fires.

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
| `TrackMove` | `from`, `to` | a track swaps with its neighbor |
| `ViewEnter` | `view`, `prev` | `AppView` switches |
| `ColorScheme` | `name` | after `:colorscheme` switches the running frontend's theme |
| `QuitPre` | | before shutdown, project still alive |

Callbacks fire on the frame loop in registration order. An error in one
callback reports to the status line and does not stop the others (Neovim
semantics).

## Hot reload: `:reload-config` (alias `:so`)

Neovim's `:source $MYVIMRC`, under a name that doesn't presuppose a path.
Re-runs init.lua (and the same system fallback startup would have used) in
place, with no restart:

1. Every keymap, user command, and autocmd the runtime is currently holding
   is dropped first (`Runtime.reload`, `src/config.zig`) and `wstudio.o`
   resets to build defaults - otherwise a second `:reload-config` would
   only ever *add* keymaps/commands/autocmds rather than replace them.
   Neovim leaves this same problem to user configs (augroups declared with
   `clear = true`); there's no equivalent unit here to ask users to manage,
   so the runtime clears everything itself instead. This means a reload
   really does put the session back to "what init.lua says right now",
   including any option init.lua doesn't set reverting to its default.
2. init.lua runs again.
3. `ConfigDone` fires again - there's no separate "config reloaded" event;
   an autocmd that wants to redo its own setup after a reload should hang
   it off `ConfigDone`, same as at startup.

Applies live: every `core`-scope option, `tui_mouse`, `tui_theme`,
`has_nerdfonts`, `gui_theme`, `gui_vsync`, and of course
keymaps/commands/autocmds. Does
**not** apply live (a message says so; change these and restart instead):
`audio_backend`, `audio_block_frames` (would mean tearing down the running
audio backend from inside the frame loop - the same hazard `:e`'s session
swap already has to special-case), `gui_font_size`, `gui_window_width`,
`gui_window_height` (font atlas / window recreation).

## Colorscheme switching: `:colorscheme` (alias `:colo`)

Neovim's command, name and abbreviation both. `:colorscheme <name>` switches
the *running frontend's* theme immediately - `gui_theme` under the GUI,
`tui_theme` under the TUI (a `wstudio` process is one or the other, never
both, so there's one option to touch and no ambiguity about which). No name
reports the active one instead of switching (`:colorscheme` alone, same as
Neovim).

Unlike `:reload-config`, this is narrow on purpose - matching how Neovim's
own `:colorscheme` only ever touches highlighting: no re-source, no keymap/
user-command/autocmd churn, no other option touched. It just writes the one
field (`rt.config.gui_theme` or `.tui_theme`) and asks the frontend to
repaint from it. Fires `ColorScheme` (see the events table above) with
`name` set to whatever was typed - hook that instead of `ConfigDone` for
setup that should redo itself on a theme switch specifically.

```lua
wstudio.keymap.set("n", "<space>tu", ":colorscheme umbra")
wstudio.api.create_autocmd("ColorScheme", {
  callback = function(ev) wstudio.notify("theme: " .. ev.name) end,
})
```

The TUI accepts `"none"` here too (turns terminal-palette theming back off);
the GUI panel skin has no such state. Built-in names are documented in
[Built-in themes](built-in-themes.md), and Tab completion lists them in the
command line.

## Scripting the project: `wstudio.api`

The core API. Frontend-neutral, contract-bound, everything above is sugar
over it. Initial surface, grouped by topic:

```lua
-- capability and editor context
wstudio.api.has("get_context")             -> boolean
wstudio.api.get_api_info()                 -> capability metadata
wstudio.api.get_context()                  -> { frontend, view, mode, track? }
wstudio.api.get_mode()                     -> "normal" | "insert" | ...
wstudio.api.get_current_view()             -> "tracks" | "piano_roll" | ...
wstudio.api.get_current_track()            -> integer | nil
wstudio.api.set_hl(group, { fg = "#rrggbb" })
wstudio.api.get_hl(group)                  -> { fg? }

-- transport
wstudio.api.transport_get()               -> transport snapshot
wstudio.api.transport_set({               -- validated partial update
  tempo = 128,
  position_beats = 16,
  song_mode = true,
  metronome = true,
  loop = { enabled = true, start_bar = 5, end_bar = 8 },
  playing = true,
})
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
wstudio.api.track_duplicate(i)             -> new integer index
wstudio.api.track_move(i, target)          -> final integer index
wstudio.api.set_current_track(i)

-- project lifecycle
wstudio.api.project_get()                 -> project snapshot
wstudio.api.project_save(path?)           -> saved path
wstudio.api.project_open(path, { force? })
wstudio.api.project_new({ force? })

-- status / prompt
wstudio.api.notify(msg)
wstudio.api.exec(cmdline)                 -- what wstudio.cmd wraps
```

Design decisions:

- **Plugins feature-detect API functions.** `has(name)` checks the live
  `wstudio.api` table, so a plugin can use a newer function when present and
  retain a fallback on older wstudio releases without parsing
  `wstudio.version`.
- **Metadata comes from authoritative registries.** `get_api_info()` is
  available before a session attaches and returns `version`, `api_level`,
  `frontend`, function names, events, highlight groups, views, modes,
  option descriptors, and hard limits. Function registration and the
  reported function list share one table; events, highlights, views, modes,
  and options are derived from their native enums/specs. Plugins can inspect
  capabilities without scraping documentation, while `has()` remains the
  simplest check for one function. `api_level` identifies the contract
  generation; ordinary additive functions do not increment it.
- **Context is a snapshot.** `get_context()` gives a mapping callback one
  consistent table containing the frontend, active view, modal mode, and
  1-based active track. `track` is absent when the tracks cursor is on the
  master row. In a per-track editor it names that editor's track, even if
  the tracks-view cursor points elsewhere. The focused getters expose the
  same values for callers that only need one field.
- **Transport is one coherent state object.** `transport_get()` returns
  `playing`, `tempo`, `position_beats`, `position_seconds`,
  `position_frames`, `sample_rate`, `beats_per_bar`, `song_mode`,
  `metronome`, and `loop = { enabled, start_bar?, end_bar? }`.
  `transport_set()` accepts any subset of the writable fields and validates
  the complete update before applying it. Positions are zero-based beats
  from the project start. Loop bars are 1-based labels matching the UI;
  `end_bar` is inclusive to the user, so `{ start_bar = 5, end_bar = 8 }`
  loops those four bars. Enabling a loop requires a valid region. Disabling
  it retains the region for later re-enabling. The older focused transport
  calls remain stable conveniences rather than aliases plugins must migrate
  away from.

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
- **Track management preserves internal references.** `track_duplicate()`
  uses the same deep-copy path as the UI. `track_move()` performs adjacent
  swaps until the requested 1-based target is reached, so arrangement lanes,
  editor targets, automation links, pending note-offs, sidechains, arm state,
  and undo entries are remapped by the existing central path. It emits one
  `TrackMove` event per adjacent swap. `set_current_track()` changes the
  shared selected track without pretending to retarget an already-open
  instrument editor. `track_set()` also accepts `armed`, and validates the
  complete partial table before applying any field.
- **Project lifecycle is native and guarded.** `project_get()` returns
  `path?`, `dirty`, `track_count`, `sample_rate`, `beats_per_bar`, `tempo`,
  and `song_mode`. `project_save()` synchronously uses the normal `.wsj`
  persistence path, fires `ProjectSavePre`/`ProjectSavePost`, updates the
  remembered path, clears dirty state, and returns the path it wrote.
  `project_open()` and `project_new()` request the same deferred session swap
  as `:edit` and `:new`, because only the frontend loop can safely restart
  the audio backend around a new Engine. They reject dirty sessions unless
  `{ force = true }` is explicit. A successful request means the swap was
  queued; load failures are reported through the normal status path and the
  current session remains intact.
- **`kind` strings** match the `cmd.Scope` names already user-visible in
  `:help`: `"synth"`, `"drum"`, `"sampler"`, `"slicer"`, `"soundfont"`.
- **These functions need a live session.** During init.lua they raise;
  startup scripting belongs in a `ConfigDone` autocmd (or queued
  `wstudio.cmd` lines), after which the full surface is available.
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
3. **Commands (shipped).** `create_user_command` / `del_user_command`,
   `:help` and completion integration.
4. **Keymaps (shipped).** Notation parser, registry, `handleKey` hook,
   `keymap.set`/`keymap.del`. Chords resolve on the next key
   (vim-notimeout-style), never by timeout.
5. **Events (shipped).** Registry, core emission points, the initial event
   table. ViewEnter and PlaybackStart/Stop are watched at the frame
   boundary (`tick`) rather than instrumented at every assignment site.
6. **Project API (shipped).** Transport and track functions above.
7. **Metadata (shipped).** Registry-derived functions, events, highlights,
   views, modes, options, and limits through `get_api_info()`.
8. **Parked.** RPC server over `wstudio.api`, clips/notes/FX
   surface, stable track ids, timers/async.

Each phase is independently shippable and testable headless through
`Runtime.loadString`, the way the existing option tests already work.

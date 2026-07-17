-- wstudio configuration template
--
-- wstudio creates ~/.config/wstudio/init.lua (or
-- $XDG_CONFIG_HOME/wstudio/init.lua) from this template on first startup.
-- Uncomment what you want to change. Every setting below shows its default,
-- so the file as generated changes nothing. A system-wide fallback is read
-- from /etc/xdg/wstudio/init.lua before a user template is generated.
--
-- This is plain Lua 5.4 (bundled, no system dependency). A broken config
-- never blocks startup: the error is reported and wstudio continues with
-- defaults. Extra modules can live in ~/.config/wstudio/lua/, e.g.
-- ~/.config/wstudio/lua/mysetup.lua is loaded with require("mysetup").
--
-- Two values describe the running instance:
--   wstudio.version    -- e.g. "1.0.0-beta.1"
--   wstudio.frontend   -- "tui" or "gui", set before this file runs
--
-- Edited this file mid-session? `:reload-config` (alias `:so`) re-runs it
-- in place - no restart needed. See docs/lua-api.md's "Hot reload" section
-- for exactly what does and doesn't apply live.
--
-- The full API design lives in docs/lua-api.md in the wstudio repo.

-- ---------------------------------------------------------------------------
-- OPTIONS: wstudio.o
-- ---------------------------------------------------------------------------
-- Startup preferences, validated on assignment: an out-of-range value or an
-- unknown name raises an error naming the valid range. Reading them back
-- (print(wstudio.o.default_tempo)) works too. Options marked "tui"/"gui"
-- only affect that frontend; setting them in the other is harmless, so one
-- config serves both.

-- Which frontend `wstudio` (no --tui/--gui flag) launches: "tui" or "gui".
-- An explicit flag always wins. Note this file runs before the frontend is
-- chosen on a flagless launch, so wstudio.frontend still reads "tui" here;
-- it is corrected before ConfigDone fires.
-- wstudio.o.preferred_frontend = "tui"

-- Tempo of new (blank) projects, in BPM. Range 20-999.
-- wstudio.o.default_tempo = 120

-- Sample rate of new projects, in Hz. Range 8000-192000.
-- wstudio.o.default_sample_rate = 48000

-- Beats per bar of new projects (the beat unit is always a quarter).
-- Range 1-16.
-- wstudio.o.default_beats_per_bar = 4

-- Starting octave for the qwerty piano layout ('a' = C of this octave).
-- Range 0-8.
-- wstudio.o.default_octave = 4

-- Velocity for keyboard/step-recorded notes and audition previews.
-- Range 0-1.
-- wstudio.o.default_velocity = 0.85

-- How often unsaved changes are backed up to <project>~, in seconds.
-- 0 disables autosave entirely. Range 0-600.
-- wstudio.o.autosave_interval_s = 30

-- Audio buffer size, in frames. Lower = less latency, higher = safer on
-- slow machines. Range 16-4096.
-- wstudio.o.audio_block_frames = 256

-- Audio backend: "auto", "pipewire", "jack", "alsa", or "none" (silent).
-- "auto" tries PipeWire, then JACK, then ALSA; whatever fails falls back
-- to the next one and finally to silence. On Windows everything except
-- "none" means WASAPI. JACK requires the server to run at the project's
-- sample rate; "auto" falls through to ALSA when it doesn't.
-- wstudio.o.audio_backend = "auto"

-- Multi-key timeout, in milliseconds: how long tap-tempo taps and similar
-- key sequences stay connected. Range 100-10000.
-- wstudio.o.tap_timeout_ms = 2000

-- How long an audition/record-preview note rings before its automatic
-- note-off, in milliseconds. Range 20-2000.
-- wstudio.o.note_preview_ms = 220

-- Max `:` command history entries kept (up/down recall in the command
-- prompt). Range 10-500.
-- wstudio.o.cmd_history_lines = 50

-- How long a status-line message stays up before clearing, in
-- milliseconds. Range 200-10000.
-- wstudio.o.status_message_ms = 3000

-- Starting directory for the file browser (:e, :load-sample, ...) when no
-- project path is known yet - a fresh session's first open. Leading `~`
-- expands to $HOME. Empty (the default) starts in the current directory.
-- wstudio.o.default_browse_dir = ""

-- Filename used by :w and autosave before a project has a known path.
-- Leading `~` expands to $HOME.
-- wstudio.o.default_project_path = "project.wsj"

-- Include dotfiles and dot-directories in the file browser.
-- wstudio.o.file_browser_show_hidden = false

-- Initial grid divisions for the drum grid, piano roll, and arrangement.
-- Values: "quarter", "eighth", "sixteenth", "thirty_second",
-- "sixty_fourth", or "one_twenty_eighth". Each editor can change its grid
-- during the session with [ and ].
-- wstudio.o.default_drum_grid = "sixteenth"
-- wstudio.o.default_piano_grid = "sixteenth"
-- wstudio.o.default_arrangement_grid = "quarter"

-- Start the piano roll on its six-steps-per-beat triplet grid.
-- wstudio.o.default_piano_triplet_grid = false

-- Initial piano-roll note length, measured in current grid steps.
-- Range 1-16.
-- wstudio.o.default_piano_note_length_steps = 1

-- Draw notes from the other tracks behind the active piano roll.
-- wstudio.o.piano_ghost_notes = false

-- [tui] Input poll interval, in milliseconds - effectively the TUI's
-- maximum frame time. Range 5-1000.
-- wstudio.o.frame_poll_ms = 30

-- [tui] Capture the mouse (clicks, scroll, drag). false leaves your
-- terminal's native text selection untouched; all mouse gestures have
-- keyboard equivalents.
-- wstudio.o.tui_mouse = true

-- [tui] Color theme, applied by reprogramming the terminal's own ANSI
-- palette (OSC 4/10/11): "none" (leaves your terminal's colors alone),
-- "patina", "patina_light", "graphite", "graphite_light", or "umbra". Defaults to "none"
-- (unlike gui_theme) because this recolors the whole physical terminal for
-- as long as wstudio runs, not just wstudio's own window - under
-- tmux/screen that means every other pane sharing the terminal too. Reset
-- on quit either way. Try one out without editing this file: `:colorscheme
-- umbra` switches it live, no restart (`:colorscheme` alone reports it).
-- wstudio.o.tui_theme = "none"

-- [gui] Font size, in pixels. Range 8-40.
-- wstudio.o.gui_font_size = 15

-- [gui] Vertical sync. false trades tearing for lower input latency.
-- wstudio.o.gui_vsync = true

-- [gui] Color theme: "patina", "patina_light", "graphite", "graphite_light", or "umbra".
-- `:colorscheme <name>` switches it live too (`:colorscheme` alone reports
-- the active one).
-- wstudio.o.gui_theme = "patina"

-- [gui] Initial window size, in pixels. Width range 960-7680, height
-- range 600-4320 (the window stays freely resizable).
-- wstudio.o.gui_window_width = 1440
-- wstudio.o.gui_window_height = 900

-- ---------------------------------------------------------------------------
-- KEYMAPS: wstudio.keymap
-- ---------------------------------------------------------------------------
-- wstudio.keymap.set(modes, lhs, rhs, opts?)
-- wstudio.keymap.del(modes, lhs, opts?)
--
--   modes  "n" (normal), "i" (insert), "v" (visual), or a list like
--          { "n", "v" }. Command/search prompts are not mappable, so `:`
--          and :help always stay reachable. ctrl-c (quit) and mouse input
--          also bypass keymaps.
--   lhs    Up to 4 keys in Neovim notation. Plain characters stand for
--          themselves; specials go in angle brackets:
--            <cr> <enter> <return>   enter
--            <esc>                   escape
--            <tab>                   tab
--            <bs> <backspace>        backspace
--            <space>                 space
--            <lt>                    a literal <
--            <up> <down> <left> <right>
--            <home> <end>
--            <c-r> <c-w>             the only ctrl keys the terminal decodes
--   rhs    A Lua function (called with no arguments), or a string starting
--          with ":" dispatched exactly like typing that command line.
--   opts   view = "..." restricts the map to one view (see the list below;
--          omitted = everywhere). desc = "..." shows in :help's USER
--          KEYMAPS section.
--
-- User maps win over built-in keys. Multi-key maps resolve on the next
-- keypress with no timeout: mapping "gp" leaves built-in "gg" working, and
-- mapping both "Q" and "Qp" fires "Q" the moment a non-"p" key follows.
-- Setting the same (mode, lhs, view) again replaces the old map, so this
-- file can be reloaded safely.
--
-- Views for opts.view:
--   tracks, piano_roll, drum_grid, slicer_grid, arrangement, automation,
--   synth_editor, sampler_editor, file_browser, help, track_spectrum,
--   master_spectrum, group_spectrum, instrument_picker, fx_picker,
--   synth_fx_picker, automation_param_picker, preset_picker

-- Examples:
-- wstudio.keymap.set("n", "gp", ":bpm 140", { desc = "jump to 140 BPM" })
-- wstudio.keymap.set("n", "<space>", function()
--   if wstudio.api.is_playing() then wstudio.api.stop() else wstudio.api.play() end
-- end, { view = "tracks", desc = "play/pause (tracks only)" })
-- wstudio.keymap.set({ "n", "v" }, "Q", ":q")
-- wstudio.keymap.del("n", "gp")

-- ---------------------------------------------------------------------------
-- USER COMMANDS: wstudio.api.create_user_command
-- ---------------------------------------------------------------------------
-- wstudio.api.create_user_command(name, handler, opts?)
-- wstudio.api.del_user_command(name)
--
--   name     No spaces, at most 32 bytes. A name that collides with a
--            built-in command is shadowed by it (built-ins always win).
--            Re-registering a name replaces its handler.
--   handler  Receives one table; opts.args is the raw text after the
--            command name ("" when none).
--   opts     desc = "..." shows in :help and the Tab-completion popup;
--            the built-in convention is "<args>  what it does".
--            scope = "drum" | "sampler" | "synth" | "slicer" offers the
--            command in completion only while that instrument is selected
--            ("any", the default, means always).
--
-- The command joins `:` dispatch, :help, Tab completion, and the GUI's
-- command palette automatically.

-- Example:
-- wstudio.api.create_user_command("halftime", function(opts)
--   wstudio.api.set_tempo(wstudio.api.get_tempo() / 2)
--   wstudio.notify("halved to " .. wstudio.api.get_tempo() .. " BPM")
-- end, { desc = "halve the current tempo" })

-- ---------------------------------------------------------------------------
-- EVENTS: wstudio.api.create_autocmd
-- ---------------------------------------------------------------------------
-- id = wstudio.api.create_autocmd(event_or_list, { callback, once? })
-- wstudio.api.del_autocmd(id)
--
-- The callback receives one table: ev.event is the event name, plus the
-- fields listed per event. Returning true removes the autocmd (so does
-- once = true, after the first fire). An error in one callback is reported
-- on the status line and the remaining callbacks still run.
--
--   event             fields      fires
--   ConfigDone                    after this file ran and the app started
--   ProjectLoadPost   path        after a .wsj loads (startup, :e, restore)
--   ProjectSavePre    path        before :write touches the disk
--   ProjectSavePost   path        after :write succeeds
--   PlaybackStart     tempo       transport started
--   PlaybackStop      tempo       transport stopped
--   TrackAdd          track       a track was added (1-based index)
--   TrackDel          track       a track was deleted (its former index)
--   ViewEnter         view, prev  the active view changed
--   ColorScheme       name        :colorscheme switched the running theme
--   QuitPre                       right before shutdown, project still open

-- Examples:
-- wstudio.api.create_autocmd("PlaybackStart", { callback = function(ev)
--   wstudio.notify("rolling at " .. ev.tempo .. " BPM")
-- end })
-- wstudio.api.create_autocmd("ProjectSavePost", { callback = function(ev)
--   print("saved " .. ev.path) -- print goes to stderr, notify to the status line
-- end, once = true })

-- ---------------------------------------------------------------------------
-- SCRIPTING THE SESSION: wstudio.api
-- ---------------------------------------------------------------------------
-- Track indices are 1-based, matching what the UI shows; 0 means "the
-- track under the cursor". An index is valid at call time - react to
-- TrackAdd/TrackDel if you hold on to one.
--
-- Transport:
--   wstudio.api.play()
--   wstudio.api.stop()
--   wstudio.api.is_playing()                     -> boolean
--   wstudio.api.get_tempo()                      -> number
--   wstudio.api.set_tempo(bpm)                   -- 20-400, like :bpm
--
-- Tracks:
--   wstudio.api.track_count()                    -> integer
--   wstudio.api.track_get(i)                     -> { name, kind, gain_db,
--                                                     pan, muted, soloed,
--                                                     group }
--   wstudio.api.track_set(i, { ... })            -- any of: name, gain_db
--                                                --   (-60..12), pan (-1..1),
--                                                --   muted, soloed
--   wstudio.api.track_add({ kind?, name? })      -> new index; kind is
--                                                --   "synth" (default),
--                                                --   "drum", "sampler",
--                                                --   or "slicer"
--   wstudio.api.track_del(i)
--
-- Other:
--   wstudio.cmd("bpm 140")   -- run any `:` command line. Called from this
--                            -- file it queues and runs once the app is up.
--   wstudio.notify("hi")     -- status-line message (stderr before startup
--                            -- completes). Also wstudio.api.notify.
--
-- IMPORTANT: this file runs before a session exists, so calling the
-- transport/track functions at the top level here raises an error. Do
-- startup scripting from a ConfigDone autocmd instead:
--
-- wstudio.api.create_autocmd("ConfigDone", { callback = function()
--   local i = wstudio.api.track_add({ kind = "drum", name = "beats" })
--   wstudio.api.track_set(i, { gain_db = -3 })
-- end, once = true })

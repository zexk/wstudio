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
--   wstudio.version    -- e.g. "1.0.0-beta.2"
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

-- Master output gain at session startup, in dB. Range -40 to 6.
-- wstudio.o.default_master_gain_db = 0

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

-- Where to look for CLAP plugins. Empty (the default) scans the standard
-- locations ($CLAP_PATH, ~/.clap, /usr/lib/clap, ...); setting a directory
-- scans only that one. Leading `~` expands to $HOME.
-- wstudio.o.clap_plugin_path = ""

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

-- Initial piano-roll cursor pitch as a MIDI note number. 60 is middle C.
-- Range 0-127.
-- wstudio.o.default_piano_pitch = 60

-- Draw notes from the other tracks behind the active piano roll.
-- wstudio.o.piano_ghost_notes = false

-- Sound the pitch under the piano-roll cursor as it moves, so you hear
-- where you are without placing a note.
-- wstudio.o.piano_audition = false

-- Entries kept on the undo stack before the oldest start dropping off.
-- Range 8-512.
-- wstudio.o.undo_history_entries = 64

-- Start every session with the click track on.
-- wstudio.o.default_metronome_enabled = false

-- Start sessions in arrangement song mode instead of pattern mode.
-- wstudio.o.default_song_mode = false

-- Click track loudness, a multiplier on its built-in accent/regular ratio.
-- Range 0-1.
-- wstudio.o.metronome_click_gain = 1.0

-- Bars the metronome clicks through before playback starts when recording
-- (Enter in insert mode, piano roll or drum grid, while stopped). 0 skips
-- the count-in and starts immediately. Range 0-4.
-- wstudio.o.count_in_bars = 1

-- Raw MIDI note-on velocity (0-127) -> gain mapping: "linear" (straight
-- pass-through), "exponential" (soft touches read quieter, hard hits still
-- reach full), or "fixed" (every hit lands at full velocity regardless of
-- how hard it was struck).
-- wstudio.o.default_midi_velocity_curve = "linear"

-- j/k nudge size for gain (dB) and pan breakpoints in the automation
-- editor. Gain range 0-12, pan range 0-1.
-- wstudio.o.default_automation_gain_step_db = 1.0
-- wstudio.o.default_automation_pan_step = 0.05

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

-- [tui] Whether your terminal renders Nerd Font glyphs, in the
-- yazi/kickstart.nvim mold: false (the default) falls back to plain ascii
-- everywhere the TUI would otherwise draw an icon, so a font-less terminal
-- never shows tofu/placeholder boxes. Set true once you've installed a
-- Nerd Font yourself; `zig build install-font` (wstudio's own embedded
-- icon font) is detected automatically and turns icons on either way.
-- wstudio.o.has_nerdfonts = false

-- [tui] Terminal columns each grid cell is drawn with: one piano-roll or
-- drum step, and one arrangement bar. Wider reads more clearly, narrower
-- fits more of the pattern on screen. Piano/drum range 1-7, arrangement
-- range 2-12. At the narrowest widths there is no room left for the ruler's
-- bar numbers, only its tick marks.
-- wstudio.o.tui_piano_cell_width = 3
-- wstudio.o.tui_drum_cell_width = 3
-- wstudio.o.tui_arrangement_cell_width = 4

-- [tui] Decibel span the spectrum analyser draws, from its top down.
-- Range 20-120. Smaller zooms in on the loud end.
-- wstudio.o.tui_spectrum_db_range = 70

-- [gui] Font size, in pixels. Range 8-40.
-- wstudio.o.gui_font_size = 15

-- [gui] Vertical sync. false trades tearing for lower input latency.
-- wstudio.o.gui_vsync = true

-- [gui] Color theme: "patina", "patina_light", "graphite", "graphite_light", or "umbra".
-- `:colorscheme <name>` switches it live too (`:colorscheme` alone reports
-- the active one).
-- wstudio.o.gui_theme = "patina"

-- [gui] Panel/window corner style: "square" or "rounded". Only affects
-- ImGui's own chrome (windows, panels, popups, buttons) - elements that
-- are rounded by their own nature (piano-roll/step-grid note blocks,
-- knobs) are untouched either way.
-- wstudio.o.gui_panel_border = "square"

-- [gui] Initial window size, in pixels. Width range 960-7680, height
-- range 600-4320 (the window stays freely resizable).
-- wstudio.o.gui_window_width = 1440
-- wstudio.o.gui_window_height = 900

-- [gui] Vertical pixels of mouse travel to sweep a knob, or an envelope
-- node's attack/decay/release leg, across its full range. Lower = more
-- sensitive. Range 40-600.
-- wstudio.o.gui_knob_drag_pixels = 180
-- wstudio.o.gui_envelope_drag_pixels = 140

-- [gui] Master-meter peak-hold fall rate, in dB/s. Higher = the hold
-- indicator drops faster. Range 1-200.
-- wstudio.o.gui_meter_decay_db_s = 24

-- [gui] Pixel height of one piano-roll key row - the roll's vertical zoom.
-- Range 8-48. Smaller fits more of the keyboard on screen (up to a full 88
-- keys); larger gives fatter, easier-to-grab note blocks.
-- wstudio.o.gui_piano_row_height = 18

-- Rows the `:` command's Tab-completion popup may occupy before it stops
-- listing more. Range 1-20. The TUI carves these out of the content area,
-- so a tall popup shortens the view underneath it while it is open.
-- wstudio.o.completion_popup_rows = 10

-- Silence appended past the end of the content by :bounce and
-- :bounce-stems, so reverb tails and long releases ring out instead of
-- being cut off. In seconds, range 0-30.
-- wstudio.o.bounce_tail_seconds = 2

-- Bit depth :bounce writes when the command line has no trailing 16/24:
-- "pcm16" or "pcm24".
-- wstudio.o.bounce_bit_depth = "pcm16"

-- Where a pathless :bounce writes, and the directory a pathless
-- :bounce-stems fills. Leading `~` expands to $HOME.
-- wstudio.o.default_bounce_path = "bounce.wav"
-- wstudio.o.default_stems_dir = "stems"

-- The always-on master limiter, the last thing in the signal path. The
-- ceiling is its output limit in dBFS (range -12 to 0; the default leaves
-- a little headroom for the 16-bit round), and the release is how quickly
-- it lets go after pulling a peak down, in milliseconds (range 1-1000).
-- wstudio.o.master_limiter_ceiling_db = -0.4
-- wstudio.o.master_limiter_release_ms = 80

-- Shape a NEWLY created instrument starts at. A project loaded from disk
-- carries its own and is never affected by these. Drum steps range 1-256,
-- slicer steps 1-64, melodic pattern length 1-64 beats. Swing is a percent
-- (range 50-75); 50 is straight, higher pushes every off-beat later.
-- wstudio.o.default_drum_steps = 32
-- wstudio.o.default_slicer_steps = 16
-- wstudio.o.default_pattern_length_beats = 4
-- wstudio.o.default_swing = 50

-- Split points, in Hz, of the three-way frequency tint waveforms are drawn
-- with (bass/body/air, the read a DJ waveform gives at a glance). Anything
-- below the low split draws as bass, anything above the high split as air.
-- Low range 20-2000, high range 1000-16000.
-- wstudio.o.waveform_low_hz = 200
-- wstudio.o.waveform_high_hz = 4000

-- ---------------------------------------------------------------------------
-- COLORS: wstudio.api.set_hl
-- ---------------------------------------------------------------------------
-- Built-in themes provide a complete base palette. Theme modules can layer
-- semantic colors over that base, in the same spirit as Neovim highlight
-- plugins. Colors are #rrggbb; {} clears an override.
--
-- Groups: bg0..bg5, fg0..fg3, line, line_soft, focus, focus_soft,
-- track_cursor, modulation, danger, rhythm, audio, blue, track1..track7.
-- These calls work here during startup and repaint live when called later.
-- TUI overrides are visible when wstudio.o.tui_theme is not "none".
--
-- wstudio.api.set_hl("bg0", { fg = "#101218" })
-- wstudio.api.set_hl("focus", { fg = "#89b4fa" })
-- wstudio.api.set_hl("track1", { fg = "#f38ba8" })
-- local focus = wstudio.api.get_hl("focus") -- { fg = "#89b4fa" }
-- wstudio.api.set_hl("focus", {})           -- restore built-in color
--
-- A theme plugin can live at lua/colors/mytheme.lua and be loaded with:
-- require("colors.mytheme")

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
--   TrackMove         from, to    a track swapped with its neighbor
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
--   wstudio.api.transport_get()                  -> { playing, tempo,
--                                                     position_beats,
--                                                     position_seconds,
--                                                     position_frames,
--                                                     sample_rate,
--                                                     beats_per_bar,
--                                                     song_mode, metronome,
--                                                     loop = { enabled,
--                                                       start_bar?, end_bar? } }
--   wstudio.api.transport_set({ ... })           -- validated partial update:
--                                                --   playing, tempo,
--                                                --   position_beats (0-based),
--                                                --   song_mode, metronome,
--                                                --   loop = { enabled?,
--                                                --     start_bar?, end_bar? }
-- Loop bars are 1-based like the UI. start_bar=5, end_bar=8 loops bars
-- 5 through 8. Disabling a loop keeps its region for later re-enabling.
--   wstudio.api.play()
--   wstudio.api.stop()
--   wstudio.api.is_playing()                     -> boolean
--   wstudio.api.get_tempo()                      -> number
--   wstudio.api.set_tempo(bpm)                   -- 20-400, like :bpm
--
-- Editor context (useful in conditional mappings and plugins):
--   wstudio.api.has("get_context")               -> feature is available
--   wstudio.api.get_context()                    -> { frontend, view, mode,
--                                                     track? }
--   wstudio.api.get_mode()                       -> "normal", "insert", ...
--   wstudio.api.get_current_view()               -> "tracks", "piano_roll", ...
--   wstudio.api.get_current_track()              -> 1-based index, or nil
-- The active track follows the open per-track editor. It is nil when the
-- tracks-view cursor is on the master row.
--
-- Tracks:
--   wstudio.api.track_count()                    -> integer
--   wstudio.api.track_get(i)                     -> { name, kind, gain_db,
--                                                     pan, muted, soloed,
--                                                     armed, group? }
--   wstudio.api.track_set(i, { ... })            -- any of: name, gain_db
--                                                --   (-60..12), pan (-1..1),
--                                                --   muted, soloed, armed
--   wstudio.api.track_add({ kind?, name? })      -> new index; kind is
--                                                --   "synth" (default),
--                                                --   "drum", "sampler",
--                                                --   or "slicer"
--   wstudio.api.track_del(i)
--   wstudio.api.track_duplicate(i)               -> appended copy's index
--   wstudio.api.track_move(i, target)             -> final index; emits one
--                                                --   TrackMove per swap
--   wstudio.api.set_current_track(i)              -- select without opening
--                                                --   or retargeting an editor
--
-- Pattern content. notes_* works on melodic tracks (synth, sampler,
-- soundfont, CLAP), steps_* on drum tracks; each raises on the other kind.
-- Both replace the pattern wholesale, so build the list in Lua and write it
-- once - that is also one undo entry.
--   wstudio.api.pattern_get(i)                   -> { kind, length_beats,
--                                                     steps_per_beat?,
--                                                     step_count? }
--                                                --   kind: "melodic",
--                                                --   "drum", "slicer",
--                                                --   or "none"
--   wstudio.api.pattern_set(i, { ... })          -- length_beats, and on a
--                                                --   drum track step_count
--                                                --   and steps_per_beat
--   wstudio.api.notes_get(i)                     -> { { pitch, start_beat,
--                                                       duration_beat,
--                                                       velocity }, ... }
--   wstudio.api.notes_set(i, notes)              -- pitch 0-127, beats from
--                                                --   the pattern start,
--                                                --   velocity 0-1
--   wstudio.api.steps_get(i)                     -> { { pad, step, velocity,
--                                                       prob, micro, retrig,
--                                                       cond, tune }, ... }
--   wstudio.api.steps_set(i, steps)              -- pad and step 1-based;
--                                                --   prob 0-100, micro
--                                                --   -50..50, retrig 0-8,
--                                                --   tune -24..24, cond one
--                                                --   of "always", "first",
--                                                --   "not_first", "fill",
--                                                --   "not_fill", "a1b2",
--                                                --   "a2b2", "a1b3", "a1b4",
--                                                --   "a2b4", "a3b4",
--                                                --   "a4b4", "a1b8"
--
-- FX chains. The target is a track index for the common case, or
-- { master = true } / { group = n } for the buses. Slots are 1-based and
-- shift on insert/remove; instance_id is stable if you need to re-find one.
--   wstudio.api.fx_list(target)                  -> { { kind, bypassed,
--                                                       instance_id,
--                                                       param_count }, ... }
--   wstudio.api.fx_add(target, kind, { pos? })   -> slot; kind is one of
--                                                --   "gate", "comp",
--                                                --   "mb_comp", "ott",
--                                                --   "eq", "sat", "crush",
--                                                --   "chorus", "phaser",
--                                                --   "flanger", "tape",
--                                                --   "freq_shift", "delay",
--                                                --   "reverb"
--   wstudio.api.fx_del(target, slot)
--   wstudio.api.fx_move(target, slot, to)        -> final slot
--   wstudio.api.fx_set(target, slot, { bypassed = true })
--   wstudio.api.fx_params(target, slot)          -> { { name, value, min,
--                                                       max, list }, ... }
--   wstudio.api.fx_param_set(target, slot, param, value)
-- param is a 1-based index or a name. Names repeat on "eq" and "mb_comp"
-- (one set per band) and CLAP plugins report their own, so index those by
-- number. Values clamp to the param's range rather than raising.
--
-- Arrangement. clip_add stamps the track's live pattern, exactly like
-- pressing enter in the arrangement view - build the pattern first, then
-- place it. Bars are 1-based; sections sit on the arrangement's own grid,
-- so they are placed in beats.
--   wstudio.api.clip_list(i)                     -> { { start_bar,
--                                                       length_bars,
--                                                       start_tick,
--                                                       length_ticks,
--                                                       kind }, ... }
--   wstudio.api.clip_add(i, start_bar)
--   wstudio.api.clip_del(i, bar)                 -- removes the clip
--                                                --   covering that bar
--   wstudio.api.clip_clear(i)
--   wstudio.api.section_list()                   -> { { name, beat, tick } }
--   wstudio.api.section_set(beat, name)
--   wstudio.api.section_del(beat)
--
-- Project lifecycle:
--   wstudio.api.project_get()                    -> { path?, dirty,
--                                                     track_count,
--                                                     sample_rate,
--                                                     beats_per_bar, tempo,
--                                                     song_mode }
--   wstudio.api.project_save(path?)              -> path actually written
--   wstudio.api.project_open(path, { force? })   -- queued session swap;
--                                                --   rejects dirty by default
--   wstudio.api.project_new({ force? })          -- same dirty guard
-- Open/new run on the next frontend frame so the audio backend can be
-- restarted safely. force=true explicitly discards unsaved changes.
--
-- Other:
--   wstudio.api.get_api_info() -- registry-derived plugin metadata:
--                              --   version, api_level, frontend, functions,
--                              --   events, highlight_groups, views, modes,
--                              --   options, limits
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

-- ---------------------------------------------------------------------------
-- WORKED EXAMPLES
-- ---------------------------------------------------------------------------
-- All of these need a live session, so they go inside a ConfigDone autocmd
-- (or a user command / keymap you trigger later). Uncomment a whole block
-- to try one.

-- A euclidean rhythm generator, as a `:pulses <pad> <hits>` command. Spreads
-- `hits` evenly across the drum grid on `pad`, keeping whatever the other
-- pads already have. (Not named `euclid`: a built-in of that name already
-- exists, and built-ins win name collisions, so the command would never
-- run. `:help` lists every built-in name.)
--
-- wstudio.api.create_user_command("pulses", function(opts)
--   local pad, hits = opts.args:match("^(%d+)%s+(%d+)$")
--   if not pad then return wstudio.notify("usage: pulses <pad> <hits>") end
--   pad, hits = tonumber(pad), tonumber(hits)
--   local steps = wstudio.api.pattern_get(0).step_count
--   local kept = {}
--   for _, s in ipairs(wstudio.api.steps_get(0)) do
--     if s.pad ~= pad then kept[#kept + 1] = s end
--   end
--   for i = 0, hits - 1 do
--     kept[#kept + 1] = { pad = pad, step = math.floor(i * steps / hits) + 1 }
--   end
--   wstudio.api.steps_set(0, kept)
-- end, { desc = "spread N hits evenly over a drum pad", scope = "drum" })

-- A chord progression written straight into the track under the cursor.
-- Each entry is a root note and the beat it lands on; the triad is built
-- from it. One notes_set call, so one press of `u` takes the whole thing
-- back.
--
-- wstudio.api.create_user_command("prog", function()
--   local roots = { { 57, 0 }, { 60, 4 }, { 55, 8 }, { 53, 12 } } -- A C G F
--   local notes = {}
--   for _, r in ipairs(roots) do
--     for _, interval in ipairs({ 0, 4, 7 }) do
--       notes[#notes + 1] = {
--         pitch = r[1] + interval,
--         start_beat = r[2],
--         duration_beat = 3.5,
--         velocity = 0.7,
--       }
--     end
--   end
--   wstudio.api.pattern_set(0, { length_beats = 16 })
--   wstudio.api.notes_set(0, notes)
-- end, { desc = "write a four-chord progression" })

-- A mastering chain on the master bus, built once at startup.
--
-- wstudio.api.create_autocmd("ConfigDone", { callback = function()
--   local master = { master = true }
--   if #wstudio.api.fx_list(master) > 0 then return end
--   local comp = wstudio.api.fx_add(master, "comp")
--   wstudio.api.fx_param_set(master, comp, "thresh", -12)
--   wstudio.api.fx_param_set(master, comp, "ratio", 3)
--   local limiter = wstudio.api.fx_add(master, "sat")
--   wstudio.api.fx_param_set(master, limiter, "drive", 4)
-- end, once = true })

-- Repeat the track's pattern four times down the arrangement and name the
-- sections. A stamped clip is as long as the pattern it captured, so step by
-- that length: placing clips closer together just overwrites the last one.
--
-- wstudio.api.create_user_command("layout", function()
--   wstudio.api.clip_clear(0)
--   wstudio.api.clip_add(0, 1)
--   local span = wstudio.api.clip_list(0)[1].length_bars
--   for n = 1, 3 do wstudio.api.clip_add(0, 1 + n * span) end
--   wstudio.api.section_set(0, "intro")
--   wstudio.api.section_set(8, "verse")
-- end, { desc = "repeat the pattern four times down the arrangement" })

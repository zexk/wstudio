//! The frontend-agnostic application core: view/modal state, key and mouse
//! dispatch, track add/delete, session lifecycle, and the Lua host hooks.
//! Both frontends embed this App - the TUI's terminal loop and frame
//! rendering live in tui/main.zig, the GUI's in gui/gui.zig. Per-view
//! input is in editors/<name>.zig, undo glue in history.zig, the
//! `:command` layer in commands.zig, and the integration tests in
//! tui/app_tests.zig.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const backend_mod = ws.backend;
const modal_mod = ws.input;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const Slicer = ws.dsp.Slicer;
const commands = @import("commands.zig");
const cmd_mod = @import("cmd.zig");
const config_mod = @import("../config.zig");
const undo_mod = @import("undo.zig");
const history = @import("history.zig");
// Per-view input handlers; the render halves live in views/<name>.zig.
const drum_ed = @import("editors/drum.zig");
const slicer_ed = @import("editors/slicer.zig");
const synth_ed = @import("editors/synth.zig");
const sampler_ed = @import("editors/sampler.zig");
const soundfont_ed = @import("editors/soundfont.zig");
const piano_ed = @import("editors/piano.zig");
const spectrum_ed = @import("editors/spectrum.zig");
const arrangement_ed = @import("editors/arrangement.zig");
const automation_ed = @import("editors/automation.zig");
const preset_ed = @import("editors/preset_picker.zig");
const user_presets = @import("user_presets.zig");
const user_drum_kits = @import("user_drum_kits.zig");
const cmd_history_store = @import("cmd_history_store.zig");
const bookmark_store = @import("bookmark_store.zig");
const fuzzy = @import("fuzzy.zig");
const ansi = @import("ansi.zig");
const help = @import("help.zig");

const Engine = engine_mod.Engine;
const Sampler = ws.dsp.Sampler;
const InstrumentKind = ws.InstrumentKind;
const pattern_mod = ws.dsp.pattern;

/// Default note-preview release time (`note_preview_ms` option); the field
/// default below and `tui/app_tests.zig`'s note-off timing test both key off
/// this constant.
pub const note_ms = 220;
/// Rows every view's content starts after in `App.draw`: the header line +
/// the `hr` divider beneath it. Mouse hit-testing subtracts this before
/// handing a row to a view's own handler - see `App.handleMouse`.
pub const content_top: u16 = 2;
/// Big enough for any real filesystem path; mirrors commands.path_buf_len.
const reload_path_buf_len: usize = 1024;
/// A pause longer than this between taps starts a fresh tap-tempo run.
/// Minimum gap between silent `<path>~` backups; see `maybeAutosave`.
const default_autosave_interval_ns: i96 = 30 * std.time.ns_per_s;
pub const AppView = enum { tracks, drum_grid, synth_editor, sampler_editor, help, track_spectrum, master_spectrum, group_spectrum, piano_roll, instrument_picker, fx_picker, synth_fx_picker, arrangement, file_browser, automation, automation_param_picker, slicer_grid, preset_picker, soundfont_editor };

/// Macro machinery bounds (see `App.macroIntercept`): the two-key pending
/// states, per-register key capacity, and the nested-`@` replay cap.
pub const MacroPending = enum { none, record, play };
pub const macro_reg_cap = 200;
const max_macro_depth = 8;

/// One workspace context - which view plus every per-view track binding -
/// as captured for the `` ` `` alternate jump (vim's alternate-file idiom:
/// bounce between the last two places you edited). The bindings are
/// snapshotted wholesale rather than per-view so a jump restores exactly
/// what the user left, even if they changed the same view's binding in
/// between (piano roll of track 2 vs. track 5 are different contexts).
pub const AltContext = struct {
    view: AppView,
    cursor: usize,
    piano_track: u16,
    drum_track: u16,
    slicer_track: u16,
    synth_track: u16,
    soundfont_track: u16,
    automation_track: u16,
    sampler_target: SamplerTarget,
};
pub const GridDivision = ws.time_grid.Division;

/// One tracks-view display row: a real track, or a group's own row (its
/// header when unfolded, the whole group when folded). The pinned master row
/// is not represented - see `App.track_rows_buf`.
pub const TrackRow = union(enum) { track: u16, group: u8 };

/// Which waveform marker a sampler-editor mouse drag is moving - see
/// `App.sampler_drag_marker` and editors/sampler.zig's handleMouse.
pub const SamplerMarker = enum { start, end };

/// What the shared sampler_editor view is currently editing: one pad of a
/// drum machine, a standalone Sampler instrument, or one slice of a Slicer
/// (which pad/slice comes from `drum_cursor[0]`/`slicer_cursor[0]`). Holds
/// the track index.
pub const SamplerTarget = union(enum) {
    drum: u16,
    sampler: u16,
    slice: u16,

    // zig fmt: off
    pub fn track(self: SamplerTarget) u16 {
        return switch (self) { .drum => |t| t, .sampler => |t| t, .slice => |t| t };
    }
};
// zig fmt: on

/// The instruments the picker offers, in display order.
pub const picker_kinds = [_]InstrumentKind{ .poly_synth, .sampler, .drum_machine, .slicer, .soundfont };
pub const picker_labels = [_][]const u8{ "Synth", "Sampler", "Drum Machine", "Slicer", "SoundFont" };

/// What a file picked in the netrw-style file browser (`file_browser` view)
/// resolves to once selected. Set by `App.openBrowser`; read by
/// `App.browserActivate`.
pub const BrowserPurpose = union(enum) {
    open_project,
    load_sample,
    load_pad: u8,
    load_clip,
    load_slice,
    load_wavetable: ws.dsp.PolySynth.OscSlot,
    load_soundfont,

    /// The extension the browser filters non-directory entries to (case
    /// insensitive); directories are always shown regardless.
    pub fn ext(self: BrowserPurpose) []const u8 {
        return switch (self) {
            .open_project => ".wsj",
            .load_sample, .load_pad, .load_clip, .load_slice, .load_wavetable => ".wav",
            .load_soundfont => ".sf2",
        };
    }

    /// Lowercase noun phrase describing what the browser is picking, without
    /// the extension (see `ext`) - shared by the TUI and GUI browser headers,
    /// which each wrap it in their own punctuation/case.
    pub fn label(self: BrowserPurpose, buf: []u8) []const u8 {
        return switch (self) {
            .open_project => "open project",
            .load_sample => "load sample",
            .load_pad => |pad| std.fmt.bufPrint(buf, "load pad {d}", .{pad + 1}) catch "load pad",
            .load_clip => "load clip",
            .load_slice => "load slicer clip",
            .load_wavetable => |slot| std.fmt.bufPrint(buf, "load wavetable, osc {s}", .{@tagName(slot)}) catch "load wavetable",
            .load_soundfont => "load soundfont",
        };
    }
};

/// One directory entry as listed by the file browser. `name` is owned
/// (allocator-dup'd from the raw `Io.Dir.Entry`, which is only valid until
/// the next iterator step).
pub const BrowserEntry = struct {
    name: []u8,
    is_dir: bool,
};

/// One yanked piano-roll pattern: a private copy of the notes + loop length.
pub const PianoClip = struct {
    notes: [pattern_mod.max_notes]pattern_mod.Note,
    count: u16,
    length_beats: f64,
};

/// A visual-mode range yank from the drum grid: one step-range's worth of
/// active/velocity bits across every pad, rebased so the selection's first
/// step becomes bit 0. Paste places it starting at the cursor step.
/// Heap-owned and sized to the yanked range's actual width (word `i / 64`,
/// bit `i % 64` of `active[pad]` is step `lo + i`) - the drum machine's own
/// step storage dropped its 64-step ceiling (see dsp/drum_sampler.zig), so
/// the clipboard no longer clamps range width either (see
/// step_grid.yankRangeDyn/pasteRangeDyn). `SlicerRangeClip` keeps the old
/// fixed 64-bit shape below since the slicer's own storage stays capped at
/// `Slicer.max_steps = 64`.
pub const DrumRangeClip = struct {
    width: u16,
    active: [DrumMachine.max_pads][]u64,
    /// Per-step velocity within the yanked range (index = step - range
    /// start), one heap-owned `width`-long slice per pad.
    vel: [DrumMachine.max_pads][]u8,

    pub fn deinit(self: *const DrumRangeClip, allocator: std.mem.Allocator) void {
        for (self.active) |a| allocator.free(a);
        for (self.vel) |v| allocator.free(v);
    }
};

/// A visual-mode range yank from the slicer grid - same shape as
/// `DrumRangeClip`, one row per slice instead of per pad.
pub const SlicerRangeClip = struct {
    width: u8,
    active: [Slicer.max_slices]u64 = [_]u64{0} ** Slicer.max_slices,
    vel: [Slicer.max_slices][Slicer.max_steps]u8 = [_][Slicer.max_steps]u8{[_]u8{Slicer.vel_full} ** Slicer.max_steps} ** Slicer.max_slices,
};

/// A visual-mode range yank from the arrangement: deep-copied clips from one
/// lane, with start_bar rebased relative to the selection's first bar. Paste
/// re-targets the cursor bar on the same lane it was copied from.
pub const ArrRangeClip = struct {
    clips: []ws.Clip,
};

/// A visual-mode range yank from the automation editor: breakpoints from
/// whichever curve (gain or pan) was selected when `y` was pressed, rebased
/// so the selection's first step becomes beat 0. Paste places them on the
/// curve active at paste time, which may differ if `tab` was pressed since.
pub const AutomationRangeClip = struct {
    points: []ws.dsp.automation.AutomationPoint,
};

/// `.` repeats the last "compound" edit - one where replaying it at a new
/// cursor position is actually worth a shortcut, as opposed to single-key
/// edits (insert note, toggle step, stamp/delete clip) that are already
/// trivially repeatable by pressing the same key again. Each editor only
/// recognizes its own variants; `.` is a no-op ("nothing to repeat") for
/// variants left over from a different editor. See editors/{piano,drum,
/// arrangement}.zig's repeatLastEdit.
pub const RepeatOp = union(enum) {
    none,
    piano_nudge_velocity: struct { delta: f32 },
    piano_resize: struct { delta: f64 },
    piano_drag: struct { dstep: i32, dpitch: i32 },
    piano_range_delete: struct { width: u16 },
    piano_range_paste,
    drum_range_delete: struct { width: u16 },
    drum_range_paste,
    slicer_range_delete: struct { width: u8 },
    slicer_range_paste,
    arr_move_clip: struct { delta: i32 },
    arr_resize_clip: struct { delta: i32 },
    arr_range_delete: struct { width: u32 },
    arr_range_paste,
    automation_range_delete: struct { width: u32 },
    automation_range_paste,
    automation_nudge: struct { delta: i32 },
};

/// Ableton-style clip editing: while set, the piano roll's pattern player
/// holds a working copy of this arrangement clip and every edit is written
/// straight back into it - the clip owns the data. Identified by track +
/// start bar because clip pointers shift as lanes are edited.
const ClipLink = struct { track: u16, start_bar: u32 };

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ws.Session,
    modal: modal_mod.ModalInput = .{},
    /// Tab-cycle state for command-mode completion; see `TabCycle`/`cycleCompletion`.
    tab_cycle: ?TabCycle = null,
    /// Gates the command-name suggestion popup (draw's `suggestion_rows`) on
    /// having pressed Tab at least once this command-mode session, matching
    /// Neovim's wildmenu (typing alone never pops it up, Tab does) rather
    /// than showing it live on every keystroke. Reset on fresh entry into
    /// command mode (applyAction's `.mode_changed`); set by `completeCommand`.
    suggest_popup_open: bool = false,
    /// The Lua scripting runtime, attached by both frontends' run paths
    /// once the app is initialized (null in headless tests without one).
    /// Owned by main.zig; outlives the App.
    lua_runtime: ?*config_mod.Runtime = null,
    /// Combined command table: built-ins first (so dispatch's first-match
    /// rule makes them win name collisions), then Lua user commands. Every
    /// dispatch/completion/help consumer reads `allCmds()`, so user
    /// commands appear everywhere automatically. Rebuilt by
    /// `rebuildCmdTable` at init and when the Lua registry changes.
    all_cmds_buf: [cmds_cap]cmd_mod.Def = undefined,
    all_cmds_len: usize = 0,
    /// Half-typed Lua keymap chord - see `userKeymapIntercept`. Resolved on
    /// the next key (fire, extend, or replay), never by timeout.
    keymap_pending_buf: [config_mod.max_keymap_lhs]modal_mod.Key = undefined,
    keymap_pending_len: usize = 0,
    /// Last states the `tick` event watchers saw - ViewEnter and
    /// PlaybackStart/Stop are detected at the frame boundary rather than
    /// instrumented at every `self.view =` / `engine.send(.play)` site.
    last_view: AppView = .tracks,
    last_playing: bool = false,
    cursor: usize = 0,
    /// Tracks-view display rows: tracks in folder order - a group's row
    /// followed by its (indented) member tracks, folded groups hiding
    /// theirs - plus memberless groups pinned after the last track. The
    /// pinned master row is NOT in the list; `track_row == track_rows_len`
    /// is the master, same "one past the end" convention `cursor ==
    /// tracks.len` used before groups got rows. Rebuilt on demand by
    /// `tracksRowSync` (cheap, so no invalidation bookkeeping).
    track_rows_buf: [@as(usize, engine_mod.max_tracks) + engine_mod.max_groups]TrackRow = undefined,
    track_rows_len: usize = 0,
    /// Tracks-view cursor, in display-row space (`track_rows_buf` index, or
    /// `track_rows_len` for the master row). `cursor` stays the selected
    /// *track index* - the arrangement view, MIDI follow, and the editors
    /// all share it - and the two are kept in sync by `setTrackRow` (row
    /// moved here) / `tracksRowSync` (cursor moved by another view).
    track_row: usize = 0,
    /// `cursor`'s value the last time the two were in sync - when they
    /// differ, some other view moved the selected track and `tracksRowSync`
    /// re-derives `track_row` from it.
    track_row_cursor_snap: usize = 0,
    /// Tracks view vertical scroll - first visible row index. Clamped to
    /// keep `track_row` in view directly in `drawTracks` (exact `rows` is
    /// known there), same pattern as `arr_scroll_bar` in drawArrangement.
    track_scroll: usize = 0,
    /// How many track rows `drawTracks` actually rendered last frame - lets
    /// `tracksMouse` (which isn't handed the row budget) know where the
    /// pinned master row landed on screen.
    track_rows_shown: usize = 0,
    view: AppView = .tracks,
    prev_view: AppView = .tracks,
    drum_cursor: [2]u16 = .{ 0, 0 },
    /// First visible step column - cursor-follow horizontal scroll, same
    /// "clamped at draw" convention as `arr_scroll_bar`/`automation_scroll`
    /// (drawDrumGrid updates it; step_count can exceed a terminal's width
    /// at max_steps = 64).
    drum_step_scroll: u32 = 0,
    drum_grid: GridDivision = .sixteenth,
    /// Track currently shown in the drum_grid view (a drum_machine rack).
    drum_track: u16 = 0,
    /// [slice, step] cursor for the slicer_grid view - same shape as
    /// `drum_cursor`.
    slicer_cursor: [2]u8 = .{ 0, 0 },
    /// First visible step column, cursor-follow - same convention as
    /// `drum_step_scroll`.
    slicer_step_scroll: u32 = 0,
    /// First visible slice row, cursor-follow bank window - same convention
    /// as the drum grid's own pad banking (views/slicer.zig).
    slicer_row_scroll: usize = 0,
    /// Track currently shown in the slicer_grid view (a slicer rack).
    slicer_track: u16 = 0,
    /// What the sampler_editor view edits: a drum pad or a standalone Sampler.
    sampler_target: SamplerTarget = .{ .drum = 0 },
    /// Selected param row in the sampler editor (0..param_count-1). For a drum
    /// pad the edited pad is `drum_cursor[0]`, shared with the drum grid.
    sampler_param: u8 = 0,
    /// Highlighted row in the instrument picker.
    picker_cursor: u8 = 0,
    /// True when the instrument picker was opened on an already-populated
    /// track (`I` in the tracks view) rather than a blank one (`enter`) -
    /// `pickerInsert` branches on this to call `changeInstrumentKind`
    /// (preserving notes where the old/new kinds allow it) instead of
    /// `setInstrument` (which always builds fresh and clears the lane).
    picker_replace: bool = false,
    audio_label: []const u8 = "off",
    master_gain_db: f32 = 0.0,
    should_quit: bool = false,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    /// How long a status message stays up, from `status_message_ms`.
    /// `setStatus` can't compute an absolute deadline (no reliable "now" at
    /// every call site - see `now_ns` below), so it just flags
    /// `status_pending`; `tick` turns that into `status_expire_ns` using its
    /// own real timestamp on the next frame.
    status_message_ns: i96 = 3000 * std.time.ns_per_ms,
    status_expire_ns: i96 = 0,
    status_pending: bool = false,
    note_offs: [32]NoteOff = undefined,
    note_off_len: usize = 0,
    // Last timestamp seen by handleKey; lets sub-view handlers schedule note-offs
    // (e.g. piano-roll preview) without threading now_ns through every signature.
    now_ns: i96 = 0,
    tap_timeout_ns: i96 = 2 * std.time.ns_per_s,
    /// Backup cadence (see maybeAutosave); 0 disables. Set from the
    /// `autosave_interval_s` option by `applyUserConfig`.
    autosave_interval_ns: i96 = default_autosave_interval_ns,
    /// Release delay for an audition/record-preview note, from
    /// `note_preview_ms` - see `playNote`.
    note_preview_ns: i96 = note_ms * std.time.ns_per_ms,
    /// Max `:` command history entries kept, from `cmd_history_lines` - see
    /// the push site in the command-submit path.
    cmd_history_cap: usize = 50,
    /// Velocity for keyboard/step-recorded notes and audition previews, from
    /// `default_velocity`.
    default_velocity: f32 = pattern_mod.default_velocity,
    /// Bars clicked through before a record count-in starts playback, from
    /// `count_in_bars` - see `toggle_play`'s insert-mode recording arm.
    count_in_bars: u8 = 1,
    /// Audio-input capture for record-armed Sampler tracks (see
    /// `Session.isAudioArmed`). Opened only for the duration of a record
    /// pass by `startPendingRecording`, closed by `finishRecording` -
    /// never held open otherwise.
    audio_input: ws.AudioInput = .{},
    /// Audio-armed track indices resolved by `toggle_play` at the moment
    /// `.record` is sent, before the pre-roll count-in even starts. Moved
    /// into `recording_active` once the count-in actually completes (see
    /// `tick`'s playing-edge check) - so a count-in's clicks never bleed
    /// into the captured audio. Fixed buffer + length, same convention as
    /// `note_offs`/`note_off_len` above.
    recording_pending_buf: [32]u16 = undefined,
    recording_pending_len: usize = 0,
    /// Audio-armed track indices actively capturing this record pass -
    /// non-empty only between the count-in finishing and the pass ending.
    recording_active_buf: [32]u16 = undefined,
    recording_active_len: usize = 0,
    /// Mono samples captured so far this record pass, drained from
    /// `audio_input` once per `tick`. Every active target gets an
    /// independent copy of this same take (see `finishRecording`) - no
    /// per-channel/per-track routing, see the capture module's doc comment.
    recording_accum: std.ArrayListUnmanaged(f32) = .empty,
    /// j/k nudge sizes in the automation editor, from
    /// `default_automation_gain_step_db`/`default_automation_pan_step`.
    automation_gain_step_db: f32 = 1.0,
    automation_pan_step: f32 = 0.05,
    /// Fallback starting directory for the file browser when no project
    /// path is known yet, from `default_browse_dir`. Empty means "cwd", the
    /// pre-existing behavior - see `openBrowser`.
    default_browse_dir: config_mod.PathBuf = .{},
    clap_plugin_path: config_mod.PathBuf = .{},
    external_plugins: ws.plugin_catalog.Catalog,
    environ: ?*const std.process.Environ.Map = null,
    /// Where a plain `:w` and a pathless autosave land.
    default_project_path: config_mod.PathBuf = config_mod.PathBuf.init("project.wsj"),
    /// Whether dotfiles and dot-directories appear in the file browser.
    file_browser_show_hidden: bool = false,
    /// An open coalescing batch of synth/sampler param nudges (h/l/H/L),
    /// flushed to `history` once the cursor moves off that param - see
    /// history.zig's noteParamNudge/flushParamNudge.
    pending_param_nudge: ?undo_mod.PendingParamNudge = null,
    /// An open coalescing batch of FX-chain param nudges - see history.zig's
    /// noteFxNudge/flushFxNudge. Owns a heap-allocated "before" chain
    /// snapshot until flushed; freed in `deinit` if a batch is still open.
    pending_fx_nudge: ?undo_mod.PendingFxNudge = null,
    /// Selected param row within the focused FX unit (EQ's are its bands).
    fx_param: usize = 0,
    /// EQ-only submode: true while picking which of the 8 bands is in view
    /// (h/l moves band, enter opens its field submenu); false once inside a
    /// band's submenu (j/k picks kind/freq/q/gain-or-slope, h/l nudges the
    /// value, esc backs out to band-select). Reset to band-select whenever
    /// chain focus changes - see editors/spectrum.zig's setFocus. Cycling
    /// every field of every band just to reach the next band was the actual
    /// complaint this splits the flat 32-entry list's navigation to fix.
    eq_band_select: bool = true,
    /// Chain slot index the FX view is focused on - Tab cycles it. Clamped
    /// by every chain mutation; out of range only while the chain is empty.
    fx_focus: usize = 0,
    /// Highlighted row in the FX picker.
    fx_picker_cursor: u8 = 0,
    /// Chain view the FX picker returns to (track_spectrum/master_spectrum/
    /// group_spectrum).
    fx_picker_return: AppView = .tracks,
    /// Last submitted `/` filter for the FX picker - same "live buffer wins
    /// while typing, else the last submitted pattern" rule as
    /// `preset_filter_buf`; cleared on every open. See `spectrum.activeFilter`.
    fx_picker_filter_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined,
    fx_picker_filter_len: usize = 0,
    /// Highlighted row in the synth-internal FX insert picker (`.fx`
    /// subview's `a`) - always returns to `.synth_editor`, so no return-view
    /// field needed like `fx_picker_return`'s.
    synth_fx_picker_cursor: u8 = 0,
    /// Same filter convention as `fx_picker_filter_buf`, for the
    /// synth-internal FX picker. See `synth_ed.activeFxFilter`.
    synth_fx_picker_filter_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined,
    synth_fx_picker_filter_len: usize = 0,
    eq_track: u16 = 0,
    /// Which group's FX chain is in view when `view == .group_spectrum` -
    /// parallel to `eq_track`.
    eq_group: u8 = 0,
    /// Scroll offset (in lines) of the help view; clamped by tui.drawHelp.
    help_scroll: usize = 0,
    /// Line index of the last `/` search match in the help view (highlighted
    /// by drawHelp, the anchor `n`/`N` continue from); reset on every open.
    help_search_hit: ?usize = null,
    synth_track: u16 = 0,
    synth_cursor: u8 = 0,
    synth_scroll: usize = 0,
    /// Track currently shown in the soundfont_editor view.
    soundfont_track: u16 = 0,
    /// Selected param row in the soundfont editor (GAIN/PAN/TRANSPOSE/PRESET).
    soundfont_param: u8 = 0,
    /// Which of the synth editor's three subviews (osc/env/filter params,
    /// the internal FX section, the mod matrix) is showing - cycled by Tab.
    /// `synth_cursor` stays one flat param-id space across all three; only
    /// which ids are reachable/rendered changes with the subview.
    synth_subview: synth_ed.Subview = .main,
    /// `z` in MAIN/MOD isolates the section containing `synth_cursor`.
    /// Editor-local display state, deliberately not persisted with a project.
    synth_section_focus: bool = false,
    /// Terminal width as of the last `draw()` call. `handleKey` runs outside
    /// `draw`'s call chain with no terminal-size parameter of its own, but
    /// the synth editor's column-grid navigation (`synth_layout.numCols`)
    /// needs to know the current column-count bucket to walk the same
    /// visual order the last frame rendered - cheaper than threading a
    /// `cols` parameter through the whole key-handling dispatch chain for
    /// one view. Defaults to 80 (== `min_cols`) so pre-first-draw nav
    /// (tests) still gets a sane single-column bucket.
    last_cols: u16 = 80,
    piano_track: u16 = 0,
    piano_cursor_step: u16 = 0,
    piano_cursor_pitch: u7 = 60,
    piano_scroll_step: u16 = 0,
    piano_scroll_pitch: u7 = 72,
    piano_note_len: f64 = 0.25,
    /// Piano-roll step grid: straight sixteenths (4 steps/beat) or
    /// sixteenth-note triplets (6 steps/beat), toggled by `T`. Global, not
    /// persisted - a display/editing aid like `piano_scale`.
    piano_grid: enum { straight, triplet } = .straight,
    /// Piano-roll horizontal zoom: `z` enlarges cells and `Z` compacts them.
    /// Global and not persisted, in the same bucket
    /// as `piano_grid`/`piano_scale`.
    piano_division: GridDivision = .sixteenth,
    /// True while `M` holds the piano-roll note under the cursor - h/l/j/k
    /// then drag the note instead of the cursor; esc/M (or any other key)
    /// drop it. See editors/piano.zig.
    piano_grab: bool = false,
    /// True while enter is held on a freshly inserted note (not when it
    /// deletes one) - a live-shaping session mirroring `piano_grab`: j/k
    /// drag the new note's pitch (reusing dragNote), h/l resize its length
    /// (reusing resizeOrLen). Releasing enter drops it (`.enter_release`,
    /// from the GUI and kitty-protocol terminals); legacy terminals have
    /// no key-up event, so there enter/esc (or any other key) drop it
    /// explicitly - see editors/piano.zig.
    piano_stamp: bool = false,
    /// Same idea as `piano_stamp` for the drum grid: enter freshly
    /// activating a step starts a session where j/k live-nudge its
    /// velocity (length has no meaning for a one-shot hit, so there's no
    /// h/l equivalent). See editors/drum.zig.
    drum_stamp: bool = false,
    /// Vim-style macro registers: `q{a-z}` records, `q` stops, `@{a-z}`
    /// replays, `@@` repeats the last replay, a count multiplies (`8@a`).
    /// Registers hold the raw `Key` stream and replay feeds it back
    /// through handleKey, so a macro captures anything typed - motions,
    /// operators, `:` commands, even insert-mode note takes. See
    /// macroIntercept for the state machine.
    macro_regs: [26][macro_reg_cap]modal_mod.Key = undefined,
    macro_reg_lens: [26]u16 = @splat(0),
    /// Register index currently recording into, if any. Shown as a
    /// persistent `rec @x` chip next to the mode badge (state, not a
    /// setStatus message, so it can't time out mid-take).
    macro_recording: ?u8 = null,
    /// Set by a bare `q`/`@` in normal mode: the NEXT key names the
    /// register (vim's two-key forms) and is consumed before any view
    /// handler can see it.
    macro_pending: MacroPending = .none,
    /// Count prefix captured when `@` armed `.play` - the digits were
    /// already consumed by the modal count machinery before `@` arrived.
    macro_pending_count: u32 = 1,
    /// Last register replayed - `@@`'s target.
    macro_last_played: ?u8 = null,
    /// Re-entrancy depth of replayMacro: replayed keys are never
    /// re-recorded, and nesting is capped so a register that (indirectly)
    /// replays itself terminates instead of recursing forever.
    macro_replay_depth: u8 = 0,
    /// The `` ` `` (backtick) alternate: the workspace context the last
    /// view-switching key departed from. Captured by a single hook in
    /// handleKey, so every switch path feeds it - editor keys, `:`
    /// commands, Lua keymaps, replayed macros. Overlay views (pickers,
    /// help, browser, spectrum submenus) never become an alternate.
    alt_context: ?AltContext = null,
    /// Arrangement view: bar cursor and horizontal scroll (lane = `cursor`).
    arr_cursor_bar: u32 = 0,
    arr_scroll_bar: u32 = 0,
    /// Arrangement view: vertical scroll over lanes - first visible lane
    /// index. Clamped directly in drawArrangement against the exact `rows`
    /// budget, same pattern as `arr_scroll_bar`'s horizontal clamp (and
    /// `App.track_scroll` in the tracks view - no pinned row here, since
    /// arrangement lanes have no master-bus equivalent).
    arr_scroll_lane: usize = 0,
    /// Arrangement horizontal zoom: `z` enlarges cells and `Z` compacts them.
    /// Mirrors `App.piano_zoom`. Not persisted - a display aid.
    arr_grid: GridDivision = .quarter,
    /// Pattern clipboards (y yank / P paste), app-wide so patterns can move
    /// between tracks. Whole-pattern granularity; one slot per editor kind.
    piano_clip: ?PianoClip = null,
    drum_clip: ?DrumMachine.Variant = null,
    /// Visual-mode anchors: set to the cursor position when `v` is pressed,
    /// null outside visual mode. The selection is [min(anchor,cursor),
    /// max(anchor,cursor)] on the view's time axis (step / step / bar); see
    /// editors/{piano,drum,arrangement}.zig's handleVisual.
    piano_visual_anchor: ?u16 = null,
    drum_visual_anchor: ?u16 = null,
    slicer_visual_anchor: ?u8 = null,
    arr_visual_anchor: ?u32 = null,
    /// Operator-pending state (normal mode, not `.visual`): set when `d`/`y`
    /// is pressed without entering visual mode first, holding which operator
    /// is armed until the next key. A step/bar motion (h/l/H/L/[g/G]) acts on
    /// the range from the `*_visual_anchor` set at arm-time to wherever the
    /// motion lands - the vim `d3j`/`y2l` grammar - reusing the exact same
    /// range delete/yank visual mode uses, just without its UI. See each
    /// editor's `armOperator`/operator-pending block in handleKey.
    piano_op_pending: ?u8 = null,
    drum_op_pending: ?u8 = null,
    slicer_op_pending: ?u8 = null,
    arr_op_pending: ?u8 = null,
    automation_op_pending: ?u8 = null,
    /// Tracks view: `d` arms, a second `d` (dd) deletes the cursor track
    /// immediately - no confirm prompt, same "operator + same key repeats on
    /// the whole line" grammar piano/drum/arrangement use for their own
    /// dd/yy. Any other key cancels.
    tracks_del_pending: bool = false,
    /// Tracks view visual mode: `v` sets the anchor, `j`/`k` extend a
    /// contiguous range of display rows (master excluded - it can't be
    /// grouped), `g` groups the selection. In `track_row` space, not track
    /// indices. Same anchor-field shape arrangement/drum/automation's own
    /// visual modes already use.
    tracks_visual_anchor: ?usize = null,
    /// Visual-mode range clipboards (y/d/P while `.visual`), separate from
    /// the whole-pattern/single-clip clipboards above.
    piano_range_clip: ?PianoClip = null,
    drum_range_clip: ?DrumRangeClip = null,
    slicer_range_clip: ?SlicerRangeClip = null,
    arr_range_clip: ?ArrRangeClip = null,
    /// Which clipboard the last piano/drum yank filled, so normal-mode p/P
    /// pastes whatever was yanked most recently (vim's unnamed-register
    /// feel): after yy p replaces the whole pattern, after a visual or
    /// operator+motion range yank p pastes the range at the cursor.
    /// Arrangement doesn't need one - its yy fills the same range clipboard.
    piano_last_yank: enum { pattern, range } = .pattern,
    drum_last_yank: enum { pattern, range } = .pattern,
    /// `.` repeat target - the last compound edit, app-wide (see RepeatOp).
    last_edit: RepeatOp = .none,
    /// Cumulative (dstep, dpitch) of the current note-drag session (M grab
    /// or a mouse drag), reset when the grab starts, committed to
    /// `last_edit` when it drops. `moved` distinguishes a mouse drag that
    /// never actually left its starting cell (a plain click) from one that
    /// did - see editors/piano.zig's handleMouse.
    piano_grab_delta: struct { dstep: i32 = 0, dpitch: i32 = 0, moved: bool = false } = .{},
    /// In-progress drum-grid mouse paint stroke: the state being painted
    /// (true = activating, false = clearing). Null when no drag is active.
    /// See editors/drum.zig's handleMouse.
    drum_paint_state: ?bool = null,
    /// In-progress slicer-grid mouse paint stroke - same convention as
    /// `drum_paint_state`. See editors/slicer.zig's handleMouse.
    slicer_paint_state: ?bool = null,
    /// In-progress arrangement clip drag: the bar last reported by the
    /// mouse, so each motion event can compute an incremental delta for
    /// `moveClip`. Null when no drag is active. See editors/arrangement.zig's
    /// handleMouse.
    arr_drag_bar: ?u32 = null,
    /// In-progress sampler-waveform marker drag. Null when no drag is
    /// active. See editors/sampler.zig's handleMouse.
    sampler_drag_marker: ?SamplerMarker = null,
    /// The arrangement clip the piano roll is editing, or null when it edits
    /// the track's live pattern (see `ClipLink`). Set by `e` on a clip in the
    /// arrangement; cleared when the roll opens on a live pattern instead.
    piano_clip_link: ?ClipLink = null,
    /// The arrangement clip the automation view is editing, relocated by
    /// (track, start_bar) the same way `piano_clip_link` is - set by `a` on
    /// a clip in the arrangement view. See editors/automation.zig.
    automation_clip: ?ClipLink = null,
    /// Track shown in the automation view - mirrors `piano_track`/
    /// `drum_track` etc. so `currentTrack()` can find it.
    automation_track: u16 = 0,
    /// Which curve h/l + j/k currently edit; tab cycles, `p` opens a picker
    /// for synth params not yet on this clip. See `automation_ed.
    /// AutomationFocus`.
    automation_focus: automation_ed.AutomationFocus = .gain,
    /// Cursor index into `automation_ed.instrumentAutomatableParams(self)`
    /// (PolySynth's or Sampler's table, whichever the current track holds)
    /// while `.automation_param_picker` is open.
    automation_param_cursor: u8 = 0,
    /// Scroll offset (in printed display rows, headers included) for the
    /// param picker - mirrors `track_scroll`'s "clamped at draw" convention.
    automation_param_scroll: usize = 0,
    /// Last submitted `/` filter for the automation param picker - same
    /// convention as `preset_filter_buf`. See `automation_ed.activeParamFilter`.
    automation_param_filter_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined,
    automation_param_filter_len: usize = 0,
    /// Cursor position within the clip, in 16th-note steps (0 = clip start,
    /// same unit the piano roll/drum grid use - beat = step / 4.0).
    automation_cursor_step: u32 = 0,
    /// Horizontal scroll (in steps), kept in sync with the cursor by
    /// views/automation.zig, mirroring `arr_scroll_bar`.
    automation_scroll: u32 = 0,
    /// Visual-mode step-range selection anchor on the currently-edited curve
    /// (`automation_target`) - mirrors `piano_visual_anchor`/`arr_visual_anchor`.
    automation_visual_anchor: ?u32 = null,
    /// A visual-mode range yank of breakpoints from the current curve,
    /// rebased so the selection's first step becomes beat 0.
    automation_range_clip: ?AutomationRangeClip = null,
    /// Active `:scale` for the piano roll's scale highlighting and `c`/`C`
    /// chord stamp; null = no scale (dims nothing, chord stamp defaults to a
    /// plain major shape). A monitoring/writing aid, not song content - not
    /// persisted, mirroring `Session.metronome_enabled`.
    piano_scale: ?ws.theory.Scale = null,
    /// `:ghost [on|off]` - dims every OTHER melodic track's notes into the
    /// piano roll's empty cells (e.g. tracing a bassline from a chord
    /// track). Same monitoring-aid status as `piano_scale`: not persisted.
    piano_ghost: bool = false,
    /// Undo/redo history for content edits (u / U in the editing views).
    history: undo_mod.History = .{},
    /// User-saved synth presets (`:synth-preset-save <name>`), loaded once
    /// at startup from `~/.config/wstudio/synth_presets.json` and rewritten
    /// wholesale on every save. Complements the compiled-in, read-only
    /// factory list in `dsp/synth_presets.zig`.
    user_synth_presets: std.ArrayListUnmanaged(user_presets.UserPreset) = .empty,
    /// User-saved drum kits (`:drum-kit-save <name>`) - pad tuning only, no
    /// audio (see `tui/user_drum_kits.zig`'s own doc comment for why),
    /// loaded once at startup from `~/.config/wstudio/drum_kits.json` and
    /// rewritten wholesale on every save.
    user_drum_kits: std.ArrayListUnmanaged(user_drum_kits.UserKit) = .empty,
    /// True when the session holds edits the project file doesn't. Set at
    /// every persisted mutation (content edits via history.push, param
    /// nudges, track/mix changes); cleared on save. `:q` refuses while set.
    dirty: bool = false,
    /// Path of the current project file - the default for :w / :wq. Set when
    /// a project is loaded at startup and updated on every successful save.
    project_path_buf: [reload_path_buf_len]u8 = undefined,
    project_path_len: usize = 0,
    /// Submitted `:` commands, oldest first, for up/down recall in the
    /// command prompt. Capped at `cmd_history_cap`; oldest drops when full.
    /// Persisted to `~/.config/wstudio/cmd_history.json` (see
    /// `cmd_history_store.zig`) - loaded once at `init`, rewritten on every
    /// new entry so it survives across runs like a shell's history file.
    cmd_history: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Position while recalling: `cmd_history.items.len` means "not
    /// recalling - the prompt holds a fresh, unsubmitted line".
    cmd_history_pos: usize = 0,
    /// Set by `:e`/`:new` (see `requestReload`) to ask `run()` to swap the
    /// session on the next loop iteration. `run()` - not App - owns the
    /// audio backend handles, and those hold a raw `*Engine` pointer
    /// captured at start, so the swap has to stop the backend, replace
    /// `session.engine`, and restart it; that can't happen from inside a
    /// key handler. Untestable below `run()` itself; the request side
    /// (dirty-flag guard, path expansion) is what App-level tests cover.
    pending_reload: ReloadRequest = .none,
    pending_reload_buf: [reload_path_buf_len]u8 = undefined,
    pending_reload_len: usize = 0,
    /// Set by `:reload-config` to ask `run()` to re-source init.lua on the
    /// next loop iteration. Same reason this can't happen inside the
    /// command handler as `pending_reload` above: only `run()` holds the
    /// live `Terminal`/window a theme change needs to re-paint, and (TUI)
    /// the `user_config` copy its loop reads every frame.
    pending_config_reload: bool = false,
    /// Set by `:colorscheme` to ask `run()` to repaint from the
    /// `gui_theme`/`tui_theme` `cmdColorscheme` already wrote into
    /// `lua_runtime.config` - same "only run() can touch this" reason as
    /// `pending_config_reload`, but lighter: no re-source, no keymap/
    /// command/autocmd churn, just the one field, mirroring how Neovim's
    /// `:colorscheme` only ever touches highlighting.
    pending_colorscheme: bool = false,
    /// Tap-tempo ring (`t` in the tracks view; see `tapTempo`).
    tap_times: [8]i96 = undefined,
    tap_count: u8 = 0,
    /// Wall-clock ns of the last autosave backup attempt (0 = never tried).
    /// See `maybeAutosave`.
    last_autosave_ns: i96 = 0,
    /// Minimal netrw/dired-style file browser: `:e` and `:load`
    /// open it when called with no path. `browser_dir` is the
    /// canonical (realpath'd) directory currently listed in `browser_entries`
    /// - both are owned and freed together (see `closeBrowser`).
    browser_dir: [:0]const u8 = "",
    browser_entries: std.ArrayListUnmanaged(BrowserEntry) = .empty,
    browser_cursor: usize = 0,
    browser_scroll: usize = 0,
    browser_purpose: BrowserPurpose = .load_sample,
    /// `b` toggles the cursor entry in/out. Persisted to
    /// `~/.config/wstudio/bookmarks.json` (see `bookmark_store.zig`) - loaded
    /// once at `init`, rewritten on every add/remove so it survives across
    /// runs like `cmd_history`.
    bookmarks: std.ArrayListUnmanaged(bookmark_store.Bookmark) = .empty,
    /// `B` swaps the browser's listing for `bookmarks` in place - own
    /// cursor/scroll so returning to the directory listing (`esc`/`q`)
    /// doesn't disturb where you were browsing.
    browser_bookmark_mode: bool = false,
    bookmark_cursor: usize = 0,
    bookmark_scroll: usize = 0,
    /// Last submitted `/` search pattern, owned (fixed buffer, same
    /// convention as `project_path_buf`), shared across views the same way
    /// vim's search register is global - `n`/`N` repeat it in whichever view
    /// has something to search (tracks, file browser).
    search_pattern_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined,
    search_pattern_len: usize = 0,
    /// Preset picker (`f` in the synth editor / drum grid - see editors/
    /// preset_picker.zig): which preset system it's browsing, the track an
    /// accepted preset applies to, and the view escape bounces back to.
    preset_picker_kind: preset_ed.Kind = .synth,
    preset_picker_track: u16 = 0,
    preset_picker_return: AppView = .tracks,
    /// Cursor as an ordinal into the *filtered* entries (headers excluded);
    /// scroll is in printed display rows, clamped at draw like
    /// `automation_param_scroll`.
    preset_picker_cursor: usize = 0,
    preset_picker_scroll: usize = 0,
    /// Synth state before the picker opened. Audition applies patches to the
    /// live synth, so cancel restores this snapshot instead of committing the
    /// last sound heard while browsing.
    preset_audition_original: ws.dsp.PolySynth.Patch = .{},
    preset_audition_active: bool = false,
    /// Last submitted `/` filter for the preset picker - separate from the
    /// global search register because it narrows a list rather than jumping
    /// a cursor, and clears on every open. While the prompt is still being
    /// typed the live buffer wins; see `preset_ed.activeFilter`.
    preset_filter_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined,
    preset_filter_len: usize = 0,
    /// Formatted "Bank N" header text for the soundfont picker's `.soundfont`
    /// Kind - owned here (not a `buildDisplayRows` stack local) because the
    /// returned `DisplayRow.header` slices must stay valid after that call
    /// returns, for as long as the caller keeps reading them. One slot per
    /// distinct bank, same 16-bucket cap `buildDisplayRows` already uses for
    /// synth categories.
    soundfont_picker_bank_headers: [16][16]u8 = undefined,

    pub const ReloadRequest = enum { none, blank, load, restore_backup };

    const NoteOff = struct { at_ns: i96, track: u16, note: u7 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !App {
        return initWithSampleRate(allocator, io, ws.types.default_sample_rate);
    }

    pub fn initWithSampleRate(allocator: std.mem.Allocator, io: std.Io, sample_rate: u32) !App {
        const cmd_history = cmd_history_store.load(allocator, io);
        var app: App = .{
            .allocator = allocator,
            .io = io,
            .session = try ws.Session.initDefaultWithSampleRate(allocator, sample_rate),
            .user_synth_presets = user_presets.load(allocator, io),
            .user_drum_kits = user_drum_kits.load(allocator, io),
            .cmd_history = cmd_history,
            .cmd_history_pos = cmd_history.items.len,
            .bookmarks = bookmark_store.load(allocator, io),
            .external_plugins = ws.plugin_catalog.Catalog.init(allocator),
        };
        app.rebuildCmdTable();
        return app;
    }

    pub const cmds_cap = commands.cmds.len + config_mod.max_user_cmds;

    pub fn allCmds(self: *const App) []const cmd_mod.Def {
        return self.all_cmds_buf[0..self.all_cmds_len];
    }

    /// See `all_cmds_buf`. Call after any change to the Lua user-command
    /// registry - entry order and trampoline indices must match it.
    pub fn rebuildCmdTable(self: *App) void {
        @memcpy(self.all_cmds_buf[0..commands.cmds.len], commands.cmds);
        var n: usize = commands.cmds.len;
        if (self.lua_runtime) |rt| {
            for (rt.userCommands(), 0..) |*uc, i| {
                self.all_cmds_buf[n] = .{
                    .name = uc.name(),
                    .desc = uc.desc(),
                    .run = user_cmd_runners[i],
                    .scope = uc.scope,
                };
                n += 1;
            }
        }
        self.all_cmds_len = n;
    }

    pub fn deinit(self: *App) void {
        if (self.audio_input.active != .none) self.audio_input.stop();
        self.recording_accum.deinit(self.allocator);
        self.external_plugins.deinit();
        user_presets.deinit(self.allocator, &self.user_synth_presets);
        user_drum_kits.deinit(self.allocator, &self.user_drum_kits);
        if (self.arr_range_clip) |r| {
            for (r.clips) |*c| c.deinit(self.allocator);
            self.allocator.free(r.clips);
        }
        if (self.automation_range_clip) |r| self.allocator.free(r.points);
        if (self.drum_range_clip) |*c| c.deinit(self.allocator);
        if (self.drum_clip) |*c| DrumMachine.freeMidi(self.allocator, &c.midi);
        if (self.pending_fx_nudge) |*p| p.deinit(self.allocator);
        self.freeBrowserEntries();
        self.browser_entries.deinit(self.allocator);
        if (self.browser_dir.len > 0) self.allocator.free(self.browser_dir);
        bookmark_store.deinit(self.allocator, &self.bookmarks);
        cmd_history_store.deinit(self.allocator, &self.cmd_history);
        self.history.deinit(self.allocator);
        self.session.deinit();
    }

    /// The drum machine currently open in the drum_grid view. Valid only while
    /// `drum_track` points at a drum_machine rack - guaranteed by view entry and
    /// the view-exit guards in `doTrackDel`.
    pub fn drumMachine(self: *App) *DrumMachine {
        return &self.session.racks.items[self.drum_track].instrument.drum_machine;
    }

    /// The slicer currently open in the slicer_grid view. Valid only while
    /// `slicer_track` points at a slicer rack - same guarantee as `drumMachine`.
    pub fn slicerInst(self: *App) *Slicer {
        return &self.session.racks.items[self.slicer_track].instrument.slicer;
    }

    // zig fmt: off
    /// The sampler currently open in the sampler_editor view (when targeting a
    /// standalone Sampler).
    pub fn editingSampler(self: *App) ?*Sampler {
        const t = switch (self.sampler_target) { .sampler => |x| x, .drum, .slice => return null };
        if (t >= self.session.racks.items.len) return null;
        return switch (self.session.racks.items[t].instrument) {
            .sampler => |*s| s, else => null,
        };
    }

    /// The SoundfontPlayer currently open in the soundfont_editor view.
    pub fn editingSoundfont(self: *App) ?*ws.dsp.SoundfontPlayer {
        if (self.soundfont_track >= self.session.racks.items.len) return null;
        return switch (self.session.racks.items[self.soundfont_track].instrument) {
            .soundfont => |*sf| sf, else => null,
        };
    }
    // zig fmt: on

    /// Total content length in beats: the longest piano-roll loop and the
    /// longest drum-machine pattern across all tracks.
    pub fn contentBeats(self: *App) f64 {
        var max_beats: f64 = 0;
        for (self.session.racks.items) |rack| {
            if (rack.pattern_player) |pp| max_beats = @max(max_beats, pp.length_beats);
            switch (rack.instrument) {
                .drum_machine => |*dm| max_beats = @max(max_beats, @as(f64, @floatFromInt(dm.step_count)) / 4.0),
                else => {},
            }
        }
        return max_beats;
    }

    // -----------------------------------------------------------------------
    // Input handling
    // -----------------------------------------------------------------------

    /// Consume the vim-style count prefix typed before the current key
    /// (default 1), clamped to a sane motion size. Editors call this for
    /// their motions; `handleKey` discards any count a handled key left
    /// unused, so a stale prefix never multiplies a later motion.
    pub fn takeCount(self: *App) i32 {
        return @min(self.modal.takeCount(), 4096);
    }

    /// Steps per beat for the piano roll's current grid - 4 (straight
    /// sixteenths) or 6 (sixteenth-note triplets). Every step<->beat
    /// conversion in editors/piano.zig and views/piano.zig goes through
    /// this so `T` can retune the whole grid in one place.
    pub fn pianoStepsPerBeat(self: *const App) u16 {
        return if (self.piano_grid == .triplet) 6 else @as(u16, self.piano_division.denominator()) / 4;
    }

    /// Terminal columns per step under the current zoom: 1, 3, or 5.
    /// and views/piano.zig goes through this.
    pub fn pianoCellWidth(_: *const App) usize {
        return 3;
    }

    pub fn drumCellWidth(_: *const App) usize {
        return 3;
    }

    /// Terminal columns per bar under the current zoom: 2, 4, or 6.
    /// Every column-width computation in editors/arrangement.zig
    /// and views/arrangement.zig goes through this.
    pub fn arrCellWidth(_: *const App) usize {
        return 4;
    }

    pub fn handleKey(self: *App, key_in: modal_mod.Key, now_ns: i96) void {
        self.now_ns = now_ns;
        // Macros hook in ahead of user keymaps (like ctrl-c below: q/@ are
        // not remappable), both to record raw keys - replay then re-expands
        // keymaps identically - and so the register-naming key after q/@
        // can never leak into a view handler.
        if (self.macroIntercept(key_in, now_ns)) return;
        // Any key that lands in a different workspace view leaves the
        // departed context behind as the ` (backtick) alternate - one hook
        // here covers every switch path (see `alt_context`).
        const departing = self.altSnapshot();
        defer if (self.view != departing.view and workspaceView(departing.view) and workspaceView(self.view)) {
            self.alt_context = departing;
        };
        // ctrl-c (the unbreakable quit path), mouse events, and enter's
        // key-up (a hold-gesture signal, not a chord key - buffering it
        // would break pending keymap chords) bypass user keymaps entirely;
        // so do the `:`/`/` prompts (not mappable modes, enforced inside
        // the intercept), keeping :help always reachable.
        if (key_in != .ctrl_c and key_in != .mouse and key_in != .enter_release) {
            if (self.userKeymapIntercept(key_in, now_ns)) return;
        }
        self.handleKeyBuiltin(key_in, now_ns);
    }

    /// The workspace views - the grammar views plus the param editors, as
    /// opposed to transient overlays (pickers, help, browser, spectrum
    /// submenus). Twofold role: only these may anchor the ` alternate
    /// jump, and only here can a bare `q`/`@` start a macro
    /// recording/replay (overlays bind `q` as "close" and keep it - but
    /// once a recording is running, `q` in normal mode stops it from
    /// ANYWHERE, so stopping is always predictable; close overlays with
    /// esc while recording).
    fn workspaceView(view: AppView) bool {
        return switch (view) {
            // zig fmt: off
            .tracks, .piano_roll, .drum_grid, .slicer_grid, .arrangement,
            .automation, .synth_editor, .sampler_editor, .soundfont_editor => true,
            // zig fmt: on
            else => false,
        };
    }

    /// The vim-macro state machine, run on every key before anything else.
    /// Returns true when the key was consumed (register-naming keys, the
    /// stop-`q`, and the `q`/`@` arming keys); a recorded key returns
    /// false so it still executes normally while the take grows.
    fn macroIntercept(self: *App, key: modal_mod.Key, now_ns: i96) bool {
        const replaying = self.macro_replay_depth > 0;
        switch (self.macro_pending) {
            .record => {
                self.macro_pending = .none;
                if (key == .char and key.char >= 'a' and key.char <= 'z') {
                    const reg: u8 = key.char - 'a';
                    self.macro_recording = reg;
                    self.macro_reg_lens[reg] = 0;
                    self.setStatus("recording @{c} - q stops", .{key.char});
                } else {
                    self.setStatus("macro cancelled - register must be a-z", .{});
                }
                return true;
            },
            .play => {
                self.macro_pending = .none;
                const reg: ?u8 = if (key == .char and key.char >= 'a' and key.char <= 'z')
                    key.char - 'a'
                else if (key == .char and key.char == '@')
                    self.macro_last_played
                else
                    null;
                // While recording, the `@x` call itself joins the take (its
                // `@` was appended when it armed .play below); the keys it
                // replays don't - appends are gated on depth 0.
                if (self.macro_recording != null and !replaying) self.macroAppend(key);
                if (reg) |r| {
                    self.replayMacro(r, self.macro_pending_count, now_ns);
                } else {
                    self.setStatus("nothing to replay", .{});
                }
                return true;
            },
            .none => {},
        }
        if (self.macro_recording) |reg| {
            if (!replaying) {
                if (key == .char and key.char == 'q' and self.modal.mode == .normal) {
                    self.macro_recording = null;
                    self.setStatus("recorded @{c} ({d} keys)", .{ 'a' + reg, self.macro_reg_lens[reg] });
                    return true;
                }
                // ctrl-c (quit) and mouse events (coordinates are not a
                // repeatable edit) execute but stay out of the register.
                if (key != .ctrl_c and key != .mouse) self.macroAppend(key);
            }
        }
        if (self.modal.mode == .normal and key == .char and workspaceView(self.view)) {
            if (key.char == 'q' and self.macro_recording == null and !replaying) {
                self.macro_pending = .record;
                self.setStatus("record macro: name it a-z", .{});
                return true;
            }
            if (key.char == '@' and self.macro_replay_depth < max_macro_depth) {
                self.macro_pending = .play;
                self.macro_pending_count = @intCast(@max(1, self.takeCount()));
                return true;
            }
        }
        return false;
    }

    /// Append one key to the recording register; a full register stops the
    /// take (with everything up to the overflow kept) rather than silently
    /// truncating the tail of a macro the user thinks they recorded.
    fn macroAppend(self: *App, key: modal_mod.Key) void {
        const reg = self.macro_recording orelse return;
        if (self.macro_reg_lens[reg] >= macro_reg_cap) {
            self.macro_recording = null;
            self.setStatus("macro register full - recording stopped at {d} keys", .{@as(u32, macro_reg_cap)});
            return;
        }
        self.macro_regs[reg][self.macro_reg_lens[reg]] = key;
        self.macro_reg_lens[reg] += 1;
    }

    /// Feed a register's key stream back through handleKey `count` times.
    /// Registers are stable during replay (macroAppend is gated on depth
    /// 0), so the stream is read in place; nested `@` in a replayed take
    /// works up to max_macro_depth and then goes inert.
    fn replayMacro(self: *App, reg: u8, count: u32, now_ns: i96) void {
        const len = self.macro_reg_lens[reg];
        if (len == 0) {
            self.setStatus("register @{c} is empty", .{'a' + reg});
            return;
        }
        if (self.macro_recording != null and self.macro_recording.? == reg) {
            // Vim's own E223 guard: replaying the register being recorded
            // would read a half-written take.
            self.setStatus("can't replay the register being recorded", .{});
            return;
        }
        self.macro_last_played = reg;
        self.macro_replay_depth += 1;
        defer self.macro_replay_depth -= 1;
        var n: u32 = 0;
        while (n < count) : (n += 1) {
            for (self.macro_regs[reg][0..len]) |k| {
                if (self.should_quit or self.pending_reload != .none) return;
                self.handleKey(k, now_ns);
            }
        }
    }

    /// vim's 'showcmd': the in-flight command prefix as short status text -
    /// a pending operator and/or accumulated count ("d3", "12") in normal
    /// mode, the live selection width ("v8") in visual mode (plus any
    /// count being typed onto it). Empty when nothing is in flight. Both
    /// frontends render it as a status-bar chip next to the view badge, so
    /// a half-typed `12l` or an armed `d` is never invisible state.
    pub fn pendingCmdText(self: *const App, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        if (self.modal.mode == .visual) {
            const width: ?u64 = switch (self.view) {
                .piano_roll => spanOf(self.piano_visual_anchor, self.piano_cursor_step),
                .drum_grid => spanOf(self.drum_visual_anchor, self.drum_cursor[1]),
                .slicer_grid => spanOf(self.slicer_visual_anchor, self.slicer_cursor[1]),
                .arrangement => spanOf(self.arr_visual_anchor, self.arr_cursor_bar),
                .automation => spanOf(self.automation_visual_anchor, self.automation_cursor_step),
                .tracks => spanOf(self.tracks_visual_anchor, self.track_row),
                else => null,
            };
            if (width) |wd| w.print("v{d}", .{wd}) catch {};
        } else if (self.modal.mode == .normal) {
            const op: ?u8 = switch (self.view) {
                .piano_roll => self.piano_op_pending,
                .drum_grid => self.drum_op_pending,
                .slicer_grid => self.slicer_op_pending,
                .arrangement => self.arr_op_pending,
                .automation => self.automation_op_pending,
                else => null,
            };
            if (op) |o| w.print("{c}", .{o}) catch {};
        } else return "";
        if (self.modal.count > 0) w.print("{d}", .{self.modal.count}) catch {};
        return w.buffered();
    }

    /// Inclusive width of a visual selection on one axis, or null when no
    /// anchor is set (pendingCmdText's per-view helper).
    fn spanOf(anchor: anytype, cursor: anytype) ?u64 {
        const a = anchor orelse return null;
        const lo = @min(@as(u64, a), @as(u64, cursor));
        const hi = @max(@as(u64, a), @as(u64, cursor));
        return hi - lo + 1;
    }

    fn altSnapshot(self: *const App) AltContext {
        return .{
            // zig fmt: off
            .view = self.view,
            .cursor = self.cursor,
            .piano_track = self.piano_track,
            .drum_track = self.drum_track,
            .slicer_track = self.slicer_track,
            .synth_track = self.synth_track,
            .soundfont_track = self.soundfont_track,
            .automation_track = self.automation_track,
            .sampler_target = self.sampler_target,
            // zig fmt: on
        };
    }

    /// `` ` `` - jump to the alternate workspace context. The handleKey
    /// hook records the outgoing context as the new alternate, so pressing
    /// ` again bounces straight back: the last two editing spots toggle.
    fn jumpAlternate(self: *App) void {
        const alt = self.alt_context orelse {
            self.setStatus("no alternate view yet", .{});
            return;
        };
        self.view = alt.view;
        self.cursor = alt.cursor;
        self.piano_track = alt.piano_track;
        self.drum_track = alt.drum_track;
        self.slicer_track = alt.slicer_track;
        self.synth_track = alt.synth_track;
        self.soundfont_track = alt.soundfont_track;
        self.automation_track = alt.automation_track;
        self.sampler_target = alt.sampler_target;
        // A track deleted or re-kinded while away can't be jumped into -
        // the same staleness bounce every structural edit already uses.
        self.exitStaleEditors();
    }

    /// Consume `key` when it fires or extends a Lua keymap (docs/lua-api.md
    /// phase 4). A key extending at least one longer chord buffers with no
    /// timeout - the chord resolves on the next key, vim-notimeout-style. A
    /// key breaking a buffered chord first resolves what was buffered (a
    /// complete shorter map fires; otherwise the raw keys replay through
    /// the built-in path), then retries on its own.
    fn userKeymapIntercept(self: *App, key: modal_mod.Key, now_ns: i96) bool {
        const rt = self.lua_runtime orelse return false;
        if (rt.userKeymaps().len == 0 and self.keymap_pending_len == 0) return false;
        const mode = self.modal.mode;
        if (mode != .normal and mode != .insert and mode != .visual) {
            self.keymap_pending_len = 0;
            return false;
        }

        var seq: [config_mod.max_keymap_lhs]modal_mod.Key = undefined;
        const pend = self.keymap_pending_len;
        @memcpy(seq[0..pend], self.keymap_pending_buf[0..pend]);
        seq[pend] = key;
        const len = pend + 1;

        var exact: ?usize = null;
        var has_longer = false;
        for (rt.userKeymaps(), 0..) |*km, i| {
            if (!km.appliesTo(mode, self.view)) continue;
            if (km.lhs_len < len or !config_mod.keysEqual(km.lhs()[0..len], seq[0..len])) continue;
            if (km.lhs_len == len) exact = i else has_longer = true;
        }
        if (has_longer) {
            @memcpy(self.keymap_pending_buf[0..len], seq[0..len]);
            self.keymap_pending_len = len;
            return true;
        }
        if (exact) |i| {
            self.keymap_pending_len = 0;
            rt.runKeymap(i);
            return true;
        }
        if (pend > 0) {
            var replay: [config_mod.max_keymap_lhs]modal_mod.Key = undefined;
            @memcpy(replay[0..pend], self.keymap_pending_buf[0..pend]);
            self.keymap_pending_len = 0;
            if (self.findExactKeymap(replay[0..pend])) |i| {
                rt.runKeymap(i);
            } else {
                for (replay[0..pend]) |k| self.handleKeyBuiltin(k, now_ns);
            }
            // Pending is now empty, so this recursion terminates; the
            // breaking key may itself start (or be) another map.
            return self.userKeymapIntercept(key, now_ns);
        }
        return false;
    }

    fn findExactKeymap(self: *App, seq: []const modal_mod.Key) ?usize {
        const rt = self.lua_runtime orelse return null;
        for (rt.userKeymaps(), 0..) |*km, i| {
            if (!km.appliesTo(self.modal.mode, self.view)) continue;
            if (km.lhs_len == seq.len and config_mod.keysEqual(km.lhs(), seq)) return i;
        }
        return null;
    }

    pub fn userKeymapsSlice(self: *const App) []const config_mod.Keymap {
        return if (self.lua_runtime) |rt| rt.userKeymaps() else &.{};
    }

    /// Fire a Lua autocmd event (no-op without a runtime attached). Every
    /// emission site is core code, so both frontends fire identically.
    pub fn emitEvent(self: *App, data: config_mod.EventData) void {
        if (self.lua_runtime) |rt| rt.emit(data);
    }

    /// Config values both frontends apply identically after App init
    /// (sample rate is the exception: initWithSampleRate needs it at
    /// construction). `blank` = started without a project argument, which
    /// additionally seeds the new-project defaults.
    pub fn applyUserConfig(self: *App, user_config: config_mod.Config, blank: bool) void {
        self.tap_timeout_ns = @as(i96, user_config.tap_timeout_ms) * std.time.ns_per_ms;
        self.autosave_interval_ns = @as(i96, user_config.autosave_interval_s) * std.time.ns_per_s;
        self.note_preview_ns = @as(i96, user_config.note_preview_ms) * std.time.ns_per_ms;
        self.status_message_ns = @as(i96, user_config.status_message_ms) * std.time.ns_per_ms;
        self.cmd_history_cap = user_config.cmd_history_lines;
        self.default_velocity = user_config.default_velocity;
        self.count_in_bars = user_config.count_in_bars;
        self.automation_gain_step_db = user_config.default_automation_gain_step_db;
        self.automation_pan_step = user_config.default_automation_pan_step;
        self.history.cap = user_config.undo_history_entries;
        _ = self.session.engine.send(.{ .set_metronome_gain = user_config.metronome_click_gain });
        // Not gated by `if (blank)`: `Session.metronome_enabled` is never
        // persisted (see its doc comment), so every load - blank or from a
        // project file - starts silent unless this restores the click.
        self.session.setMetronome(user_config.default_metronome_enabled);
        self.default_browse_dir = user_config.default_browse_dir;
        self.clap_plugin_path = user_config.clap_plugin_path;
        var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const project_path = commands.expandHome(&project_path_buf, user_config.default_project_path.slice());
        self.default_project_path = .{};
        @memcpy(self.default_project_path.buf[0..project_path.len], project_path);
        self.default_project_path.len = @intCast(project_path.len);
        self.file_browser_show_hidden = user_config.file_browser_show_hidden;
        self.drum_grid = user_config.default_drum_grid;
        self.piano_division = user_config.default_piano_grid;
        self.piano_grid = if (user_config.default_piano_triplet_grid) .triplet else .straight;
        self.piano_note_len = @as(f64, @floatFromInt(user_config.default_piano_note_length_steps)) /
            @as(f64, @floatFromInt(self.pianoStepsPerBeat()));
        self.arr_grid = user_config.default_arrangement_grid;
        self.piano_ghost = user_config.piano_ghost_notes;
        self.modal.octave = @intCast(user_config.default_octave);
        if (blank) {
            self.session.project.tempo_bpm = user_config.default_tempo;
            self.session.project.beats_per_bar = user_config.default_beats_per_bar;
            _ = self.session.engine.send(.{ .set_tempo = user_config.default_tempo });
            _ = self.session.engine.send(.{ .set_time_signature = user_config.default_beats_per_bar });
            self.session.syncLoop();
        }
    }

    pub fn scanExternalPlugins(self: *App, environ: *const std.process.Environ.Map) void {
        self.environ = environ;
        var expanded_buf: [std.fs.max_path_bytes]u8 = undefined;
        const custom_path = commands.expandHome(&expanded_buf, self.clap_plugin_path.slice());
        var custom = [_][]const u8{custom_path};
        var owned_paths: std.ArrayListUnmanaged([]u8) = .empty;
        const paths: []const []const u8 = if (self.clap_plugin_path.len > 0)
            &custom
        else blk: {
            owned_paths = ws.dsp.clap_scan.searchPaths(self.allocator, environ) catch return;
            break :blk owned_paths.items;
        };
        defer if (self.clap_plugin_path.len == 0)
            ws.dsp.clap_scan.freeSearchPaths(self.allocator, &owned_paths);
        self.external_plugins.scanClap(self.io, paths) catch |err| {
            self.setStatus("plugin scan failed: {s}", .{@errorName(err)});
        };
    }

    /// Frontend-neutral half of `:reload-config` (ui/commands.zig sets
    /// `pending_config_reload`; `run()` calls `runtime.reload()` then this,
    /// once it's back holding the fresh `Config`). Re-fires `ConfigDone` -
    /// there's no dedicated "config was reloaded" event, and treating a
    /// reload as a second config-done moment is the more useful reading for
    /// autocmds that want to redo their own setup after one. Frontend-only
    /// side effects (GUI theme repaint, TUI OSC palette, the frame-loop's
    /// own `user_config` copy) are `run()`'s job, not this one's - see
    /// tui/main.zig and gui/gui.zig's `pending_config_reload` handling.
    pub fn afterConfigReload(self: *App, user_config: config_mod.Config) void {
        self.rebuildCmdTable();
        self.applyUserConfig(user_config, false);
        if (self.environ) |environ| self.scanExternalPlugins(environ);
        self.emitEvent(.ConfigDone);
    }

    // ------------------------------------------------------------------
    // wstudio.api surface (docs/lua-api.md phase 6). Validated entry points
    // for the Lua runtime - each mirrors the exact code path the equivalent
    // UI gesture takes, so scripts and keys can't diverge. Writes go
    // through the same engine.send commands, reads hit the control-side
    // project mirror.

    pub fn apiIsPlaying(self: *App) bool {
        return self.session.engine.uiSnapshot().playing;
    }

    pub fn apiPlay(self: *App) void {
        _ = self.session.engine.send(.play);
    }

    pub fn apiStop(self: *App) void {
        _ = self.session.engine.send(.stop);
    }

    pub fn apiGetTempo(self: *const App) f64 {
        return self.session.project.tempo_bpm;
    }

    /// The editor context exposed to Lua. The active track follows the
    /// open editor rather than the tracks-view cursor, matching the same
    /// resolution used by mute, solo, and note preview.
    pub fn apiCurrentTrack(self: *App) ?usize {
        const idx = self.currentTrack();
        return if (idx < self.session.project.tracks.items.len) idx else null;
    }

    /// False when out of the :bpm command's 20-400 range (or not finite).
    pub fn apiSetTempo(self: *App, bpm: f64) bool {
        if (!std.math.isFinite(bpm) or bpm < 20.0 or bpm > 400.0) return false;
        self.session.project.tempo_bpm = bpm;
        _ = self.session.engine.send(.{ .set_tempo = bpm });
        // The loop region is stored in bars; its frame mirror just moved.
        self.session.syncLoop();
        self.dirty = true;
        return true;
    }

    pub const ApiTrackInfo = struct {
        name: []const u8,
        kind: []const u8,
        gain_db: f32,
        pan: f32,
        muted: bool,
        soloed: bool,
        armed: bool,
        /// 1-based for Lua, like track indices.
        group: ?u8,
    };

    pub fn apiTrackInfo(self: *const App, idx: usize) ApiTrackInfo {
        const t = self.session.project.tracks.items[idx];
        return .{
            .name = t.name,
            .kind = apiKindName(std.meta.activeTag(self.session.racks.items[idx].instrument)),
            .gain_db = t.gain_db,
            .pan = t.pan,
            .muted = t.muted,
            .soloed = t.soloed,
            .armed = self.session.isArmed(idx),
            .group = if (t.group) |g| g + 1 else null,
        };
    }

    pub fn apiSetTrackGainDb(self: *App, idx: usize, db: f32) void {
        const t = &self.session.project.tracks.items[idx];
        t.gain_db = std.math.clamp(db, -60.0, 12.0);
        self.dirty = true;
        _ = self.session.engine.send(.{ .set_track_gain = .{ .track = @intCast(idx), .gain = types.dbToGain(t.gain_db) } });
    }

    pub fn apiSetTrackPan(self: *App, idx: usize, pan: f32) void {
        const t = &self.session.project.tracks.items[idx];
        t.pan = std.math.clamp(pan, -1.0, 1.0);
        self.dirty = true;
        _ = self.session.engine.send(.{ .set_track_pan = .{ .track = @intCast(idx), .pan = t.pan } });
    }

    pub fn apiSetTrackMuted(self: *App, idx: usize, muted: bool) void {
        const t = &self.session.project.tracks.items[idx];
        t.muted = muted;
        self.dirty = true;
        _ = self.session.engine.send(.{ .set_track_mute = .{ .track = @intCast(idx), .muted = muted } });
    }

    pub fn apiSetTrackSoloed(self: *App, idx: usize, soloed: bool) void {
        const t = &self.session.project.tracks.items[idx];
        t.soloed = soloed;
        self.dirty = true;
        _ = self.session.engine.send(.{ .set_track_solo = .{ .track = @intCast(idx), .soloed = soloed } });
    }

    pub fn apiRenameTrack(self: *App, idx: usize, name: []const u8) bool {
        self.session.project.renameTrack(idx, name) catch return false;
        self.dirty = true;
        return true;
    }

    /// Null when the track limit is hit. Reuses doTrackAdd for insert
    /// position, undo remapping, and the TrackAdd event; the instrument is
    /// set right after (so a TrackAdd callback still sees kind "empty").
    pub fn apiTrackAdd(self: *App, kind: ws.InstrumentKind, name: ?[]const u8) ?usize {
        const before = self.session.project.tracks.items.len;
        self.doTrackAdd(name);
        if (self.session.project.tracks.items.len == before) return null;
        const idx = self.cursor;
        if (kind != .empty) self.session.setInstrument(idx, kind) catch {
            self.setStatus("out of memory setting instrument", .{});
        };
        return idx;
    }

    /// False when the delete was refused (the last remaining track).
    pub fn apiTrackDel(self: *App, idx: usize) bool {
        const before = self.session.project.tracks.items.len;
        self.doTrackDel(idx);
        return self.session.project.tracks.items.len < before;
    }

    fn handleKeyBuiltin(self: *App, key_in: modal_mod.Key, now_ns: i96) void {
        self.now_ns = now_ns;
        if (key_in == .ctrl_c) {
            // ctrl-c always exits, even with unsaved changes - but the least
            // deliberate quit path shouldn't have the weakest safety net, so
            // flush a backup first instead of letting up to 30s of edits
            // (the autosave cadence) die with the process.
            if (self.dirty) self.writeBackup();
            self.should_quit = true;
            return;
        }

        // zig fmt: off
        // Command/search mode: up/down recall history (command only - search
        // has no history), tab completes the command name (command only).
        // Left/right/home/end/ctrl-w edit the cmd_buf cursor in place
        // (modal.handle owns that state, shared by both prompts) - passed
        // through as their own variants rather than the hjkl aliasing below,
        // which would insert literal 'h'/'l' characters into the line
        // instead of moving through it.
        if (self.modal.mode == .command or self.modal.mode == .search) {
            switch (key_in) {
                .arrow_up => { if (self.modal.mode == .command) self.commandHistoryPrev(); return; },
                .arrow_down => { if (self.modal.mode == .command) self.commandHistoryNext(); return; },
                .arrow_left, .arrow_right, .home, .end, .ctrl_w => { _ = self.modal.handle(key_in); return; },
                .tab => { if (self.modal.mode == .command) self.completeCommand(); return; },
                else => {},
            }
        }
        // Everywhere else, arrows are a plain hjkl alias (vim convention) -
        // every view already navigates on h/l/j/k, so this is transparent.
        const key: modal_mod.Key = switch (key_in) {
            .arrow_up => .{ .char = 'k' },
            .arrow_down => .{ .char = 'j' },
            .arrow_left => .{ .char = 'h' },
            .arrow_right => .{ .char = 'l' },
            else => key_in,
        };
        // zig fmt: on

        // `?` opens the context-jumping help from ANY view's normal mode -
        // cmdHelp already maps every view to its help section and prev_view
        // brings escape back here. Gated to normal mode so command/search
        // typing and piano-roll insert notes never trigger it.
        if (self.modal.mode == .normal and self.view != .help and key == .char and key.char == '?') {
            commands.cmdHelp(self, "");
            return;
        }

        // `` ` `` jumps to the alternate workspace context from any
        // workspace view's normal mode (same interception spot as `?`
        // above: ahead of the view switch, since no view binds backtick).
        if (self.modal.mode == .normal and key == .char and key.char == '`' and workspaceView(self.view)) {
            self.jumpAlternate();
            return;
        }

        // zig fmt: off
        switch (self.view) {
            .help => {
                // `/` search typing routes to the modal prompt; submit lands
                // in applyAction's `.search_submit` case (same shape as the
                // file browser's own search wiring).
                if (self.modal.mode == .search) {
                    self.applyAction(self.modal.handle(key), now_ns);
                    return;
                }
                switch (key) {
                    .escape => self.view = self.prev_view,
                    // j/k scroll one line, d/u half-page, g/G jump to ends.
                    // draw clamps help_scroll, so over-scrolling just pins to the edge.
                    .char => |c| switch (c) {
                        'j' => self.help_scroll += 1,
                        'k' => self.help_scroll -|= 1,
                        'd' => self.help_scroll += 10,
                        'u' => self.help_scroll -|= 10,
                        'G' => self.help_scroll = std.math.maxInt(usize),
                        'g' => self.help_scroll = 0,
                        '/' => {
                            self.modal.mode = .search;
                            self.modal.cmd_len = 0;
                            self.modal.cmd_cursor = 0;
                        },
                        'n' => self.searchHelp(1),
                        'N' => self.searchHelp(-1),
                        // `?` toggles help closed again, mirroring how it opens.
                        '?', 'q' => self.view = self.prev_view,
                        else => {},
                    },
                    else => {},
                }
            },
            // Editor-handled keys discard any unused count prefix (vim: a
            // count binds to the command it precedes, then dies with it).
            // Normal and visual route through the editor first; command
            // mode bypasses it, and insert mode bypasses the grid switch so
            // qwerty keys trigger pads (see recordNote in editors/drum.zig
            // and docs/editing-grammar.md).
            .drum_grid => {
                if (self.modal.mode == .command or self.modal.mode == .search or self.modal.mode == .insert or !drum_ed.handleKey(self, key)) {
                    self.applyAction(self.modal.handle(key), now_ns);
                } else self.modal.count = 0;
            },
            .slicer_grid => {
                if (self.modal.mode == .command or self.modal.mode == .search or self.modal.mode == .insert or !slicer_ed.handleKey(self, key)) {
                    self.applyAction(self.modal.handle(key), now_ns);
                } else self.modal.count = 0;
            },
            .synth_editor => if (self.modal.mode == .command or self.modal.mode == .search or !synth_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            // `!= .normal` already covers search (and command, insert, visual).
            .sampler_editor => if (self.modal.mode != .normal or !sampler_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .soundfont_editor => if (self.modal.mode != .normal or !soundfont_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .track_spectrum, .master_spectrum, .group_spectrum => if (self.modal.mode == .command or self.modal.mode == .search or !spectrum_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            // Insert mode bypasses the roll's own switch entirely - once
            // inserted, the piano-keyboard layout needs h/j/k/l as notes,
            // not roll navigation, so modal.handle owns every key until
            // escape drops back to normal (see recordNote in editors/piano.zig).
            .piano_roll => if (self.modal.mode == .command or self.modal.mode == .search or self.modal.mode == .insert or !piano_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .instrument_picker => self.handlePickerKey(key),
            // `/` (and the search mode it enters) is routed to the modal
            // prompt so the picker's filter narrows live while typing -
            // submit/cancel land in applyAction's `.search_submit` case.
            // Same shape as `.preset_picker`'s own routing below.
            .fx_picker => if (self.modal.mode == .search or (key == .char and key.char == '/')) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else self.handleFxPickerKey(key),
            .synth_fx_picker => if (self.modal.mode == .search or (key == .char and key.char == '/')) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else self.handleSynthFxPickerKey(key),
            .file_browser => if (self.modal.mode == .search) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else self.handleBrowserKey(key),
            .arrangement => if (self.modal.mode == .command or self.modal.mode == .search or !arrangement_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .automation => if (self.modal.mode == .command or self.modal.mode == .search or !automation_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .automation_param_picker => if (self.modal.mode == .search or (key == .char and key.char == '/')) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else self.handleAutomationParamPickerKey(key),
            .preset_picker => if (self.modal.mode == .search or (key == .char and key.char == '/')) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else preset_ed.handleKey(self, key),
            .tracks => {
                self.tracksRowSync();
                // Visual mode: a contiguous row-range selection, checked
                // first so it can't leak into the normal-mode bindings below
                // (same ordering arrangement.zig's own visual-mode guard uses).
                if (self.modal.mode == .visual) { self.handleTracksVisual(key); return; }

                // The cursor walks display rows: real tracks, group rows,
                // and - one slot past the end, same convention as before
                // groups got rows - the pinned master row. Bus rows (group/
                // master) can't be deleted-as-a-track/duplicated/moved/
                // muted/soloed and have no piano roll or pan.
                const cur_track = self.cursorTrack();
                const cur_group = self.cursorGroup();
                const on_master = self.track_row == self.track_rows_len;
                // `d` arms; a second `d` (dd) deletes the cursor row right
                // away - the track, or on a group row the group itself - no
                // confirm. Checked first so it wins over every other binding
                // below and can't get stuck armed.
                if (self.tracks_del_pending) {
                    self.tracks_del_pending = false;
                    if (key == .char and key.char == 'd') {
                        if (cur_group) |g| self.doGroupDel(g)
                        else if (cur_track) |t| self.doTrackDel(t);
                    } else {
                        self.setStatus("cancelled", .{});
                    }
                    return;
                }
                if (key == .tab and self.modal.mode == .normal) {
                    self.view = .arrangement;
                    self.autoSongMode(true);
                    return;
                }
                if (key == .enter and self.modal.mode == .normal) {
                    if (on_master) spectrum_ed.switchToMaster(self)
                    else if (cur_group) |g| spectrum_ed.switchToGroup(self, g)
                    else if (cur_track) |t| self.openTrack(t);
                    return;
                }
                if (key == .ctrl_r and self.modal.mode == .normal) {
                    history.doRedo(self);
                    return;
                }
                if (key == .char and self.modal.mode == .normal) {
                    switch (key.char) {
                        'n' => { self.searchTracks(1); return; },
                        'N' => { self.searchTracks(-1); return; },
                        'T' => {
                            self.session.setSongMode(!self.session.song_mode);
                            self.dirty = true;
                            self.setStatus("{s} mode", .{if (self.session.song_mode) "song" else "pattern"});
                            return;
                        },
                        else => {},
                    }
                    if (on_master) {
                        switch (key.char) {
                            's', 'M' => { spectrum_ed.switchToMaster(self); return; },
                            'a' => { self.doTrackAdd(null); return; },
                            'c' => { self.toggleMetronome(); return; },
                            '-' => { self.doMasterGainStep(-1.0); return; },
                            '+', '=' => { self.doMasterGainStep(1.0); return; },
                            'u' => { history.doUndo(self); return; },
                            'U' => { history.doRedo(self); return; },
                            't' => { self.tapTempo(now_ns); return; },
                            'l' => { self.session.resetLoudness(); self.setStatus("integrated LUFS reset", .{}); return; },
                            'd', 'Y', 'J', 'K', 'R', 'p', 'I', 'r', '<', '>', '[', ']', 'v', 'z' => {
                                self.setStatus("master bus: n/a", .{});
                                return;
                            },
                            else => {},
                        }
                    } else if (cur_group) |g| {
                        switch (key.char) {
                            's' => { spectrum_ed.switchToGroup(self, g); return; },
                            'z' => { self.doGroupFoldToggle(g); return; },
                            'R' => { self.startGroupRenamePrompt(g); return; },
                            'd' => { self.tracks_del_pending = true; return; },
                            '-' => { self.doGroupGainStep(g, -1.0); return; },
                            '+', '=' => { self.doGroupGainStep(g, 1.0); return; },
                            'M' => { spectrum_ed.switchToMaster(self); self.setTrackRow(self.track_rows_len); return; },
                            'a' => { self.doTrackAdd(null); return; },
                            'c' => { self.toggleMetronome(); return; },
                            'u' => { history.doUndo(self); return; },
                            'U' => { history.doRedo(self); return; },
                            't' => { self.tapTempo(now_ns); return; },
                            'v' => {
                                self.tracks_visual_anchor = self.track_row;
                                self.modal.mode = .visual;
                                self.setStatus("visual: j/k extend, g groups the selection, esc cancels", .{});
                                return;
                            },
                            'Y', 'J', 'K', 'p', 'I', 'r', '<', '>', '[', ']' => {
                                self.setStatus("group row: n/a", .{});
                                return;
                            },
                            else => {},
                        }
                    } else {
                        switch (key.char) {
                            'M' => { spectrum_ed.switchToMaster(self); self.setTrackRow(self.track_rows_len); return; },
                            's' => { spectrum_ed.switchToTrack(self, @intCast(self.cursor)); return; },
                            'p' => {
                                piano_ed.switchTo(self, @intCast(self.cursor));
                                if (self.view == .piano_roll) self.autoSongMode(false);
                                return;
                            },
                            'a' => { self.doTrackAdd(null); return; },
                            'I' => { self.openInstrumentPicker(self.cursor, true); return; },
                            'r' => { self.doTrackArmToggle(self.cursor); return; },
                            'd' => { self.tracks_del_pending = true; return; },
                            'Y' => { self.doTrackDup(self.cursor); return; },
                            'J' => { self.doTrackMove(1); return; },
                            'K' => { self.doTrackMove(-1); return; },
                            '[' => { self.doTrackColorCycle(-1); return; },
                            ']' => { self.doTrackColorCycle(1); return; },
                            'z' => {
                                if (self.session.project.tracks.items[self.cursor].group) |g| {
                                    self.doGroupFoldToggle(g);
                                } else {
                                    self.setStatus("track {d} isn't grouped", .{self.cursor + 1});
                                }
                                return;
                            },
                            'v' => {
                                self.tracks_visual_anchor = self.track_row;
                                self.modal.mode = .visual;
                                self.setStatus("visual: j/k extend, g groups the selection, esc cancels", .{});
                                return;
                            },
                            'c' => { self.toggleMetronome(); return; },
                            '<' => { self.doTrackPan(@intCast(self.cursor), -0.05); return; },
                            '>' => { self.doTrackPan(@intCast(self.cursor), 0.05); return; },
                            '-' => { self.doTrackGainStep(@intCast(self.cursor), -1.0); return; },
                            // + is the canonical "increase" (matches pattern length); = kept as alias.
                            '+', '=' => { self.doTrackGainStep(@intCast(self.cursor), 1.0); return; },
                            'u' => { history.doUndo(self); return; },
                            'U' => { history.doRedo(self); return; },
                            'R' => { self.startRenamePrompt(); return; },
                            't' => { self.tapTempo(now_ns); return; },
                            else => {},
                        }
                    }
                }
                self.applyAction(self.modal.handle(key), now_ns);
            },
        }
    }
    // zig fmt: on

    /// Mouse entry point - routed here directly by `run()` rather than
    /// through `handleKey`/the modal state machine (mouse isn't part of the
    /// vim mode grammar; it's a second way to trigger the same actions keys
    /// already trigger). `cols`/`rows` are the current terminal size, needed
    /// by views whose layout depends on it: `cols` for column math (piano
    /// roll, arrangement, sampler waveform, spectrum bands), `rows` for the
    /// sampler/spectrum views' variable-height waveform/FX panels (mirrors
    /// the `content_rows` App.draw computes for the same views).
    pub fn handleMouse(self: *App, ev: modal_mod.MouseEvent, cols: u16, rows: u16, now_ns: i96) void {
        self.now_ns = now_ns;
        if (ev.y < content_top) return;
        const row: usize = ev.y - content_top;
        const view_rows: usize = @max(rows, 10);
        switch (self.view) {
            .tracks => self.tracksMouse(ev, row),
            .drum_grid => drum_ed.handleMouse(self, ev, row, view_rows),
            .synth_editor => synth_ed.handleMouse(self, ev, row, cols),
            .sampler_editor => sampler_ed.handleMouse(self, ev, row, cols, view_rows),
            .soundfont_editor => soundfont_ed.handleMouse(self, ev, row),
            .piano_roll => piano_ed.handleMouse(self, ev, row, cols),
            .track_spectrum, .master_spectrum, .group_spectrum => spectrum_ed.handleMouse(self, ev, row, cols, view_rows),
            .arrangement => arrangement_ed.handleMouse(self, ev, row, cols),
            .instrument_picker => self.pickerMouse(ev, row),
            .fx_picker => self.fxPickerMouse(ev, row),
            .synth_fx_picker => self.synthFxPickerMouse(ev, row),
            .file_browser => self.browserMouse(ev, row),
            .help => self.helpMouse(ev),
            .automation => automation_ed.handleMouse(self, ev, row),
            .automation_param_picker => self.automationParamPickerMouse(ev, row),
            .preset_picker => preset_ed.handleMouse(self, ev, row),
            .slicer_grid => slicer_ed.handleMouse(self, ev, row, cols, view_rows),
        }
    }

    /// Tracks view: click a row to select + open it (same as Enter - a
    /// group row opens its FX chain); scroll moves the cursor like j/k.
    /// Row-level only: track names are unbounded width (`"{s: <8}"` pads
    /// but never truncates), so a mute/solo column click zone can't be
    /// derived reliably from the track index alone.
    fn tracksMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        switch (ev.kind) {
            .press => {
                self.tracksRowSync();
                // Rows 1..track_rows_shown are the (possibly scrolled)
                // display-row window; the row right after is the pinned
                // master row.
                if (row == 0 or row > self.track_rows_shown + 1) return; // title row / out of range
                if (row - 1 == self.track_rows_shown) {
                    self.setTrackRow(self.track_rows_len);
                    spectrum_ed.switchToMaster(self);
                    return;
                }
                const ri = self.track_scroll + (row - 1);
                if (ri >= self.track_rows_len) return;
                self.setTrackRow(ri);
                switch (self.track_rows_buf[ri]) {
                    .track => |t| self.openTrack(t),
                    .group => |g| spectrum_ed.switchToGroup(self, g),
                }
            },
            .scroll_up => self.applyAction(.{ .move = .{ .dy = -1 } }, self.now_ns),
            .scroll_down => self.applyAction(.{ .move = .{ .dy = 1 } }, self.now_ns),
            else => {},
        }
    }

    // -----------------------------------------------------------------------
    // Tracks-view display rows (tracks + group rows; see TrackRow)
    // -----------------------------------------------------------------------

    /// Rebuild the display-row list from the current tracks/groups/fold
    /// state. Folder order: a group's row sits where its first member (by
    /// track index) sits, the members follow it in index order (hidden
    /// entirely while folded), ungrouped tracks keep their own positions,
    /// and memberless groups trail after the last track so a fresh
    /// `:group-add` is visible immediately.
    pub fn rebuildTrackRows(self: *App) void {
        const tracks = self.session.project.tracks.items;
        var emitted = [_]bool{false} ** engine_mod.max_groups;
        var n: usize = 0;
        for (tracks, 0..) |t, i| {
            const g: u8 = t.group orelse {
                self.track_rows_buf[n] = .{ .track = @intCast(i) };
                n += 1;
                continue;
            };
            if (g >= engine_mod.max_groups or self.session.groups[g] == null) {
                // Stale reference (assignTrackGroup never writes one, but a
                // hand-edited file might) - render as plain ungrouped.
                self.track_rows_buf[n] = .{ .track = @intCast(i) };
                n += 1;
                continue;
            }
            if (emitted[g]) continue; // already listed under its group's row
            emitted[g] = true;
            self.track_rows_buf[n] = .{ .group = g };
            n += 1;
            if (self.session.groups[g].?.folded) continue;
            for (tracks, 0..) |t2, j| {
                const g2 = t2.group orelse continue;
                if (g2 != g) continue;
                self.track_rows_buf[n] = .{ .track = @intCast(j) };
                n += 1;
            }
        }
        for (self.session.groups, 0..) |slot, g| {
            if (slot != null and !emitted[g]) {
                self.track_rows_buf[n] = .{ .group = @intCast(g) };
                n += 1;
            }
        }
        self.track_rows_len = n;
    }

    pub fn trackRows(self: *const App) []const TrackRow {
        return self.track_rows_buf[0..self.track_rows_len];
    }

    /// Rebuild + re-sync the row cursor. When `cursor` moved since the last
    /// sync (another view or a command changed the selected track), the row
    /// cursor follows it - unfolding is NOT forced, so a track hidden in a
    /// fold resolves to its group's row. Call before any row-cursor read.
    pub fn tracksRowSync(self: *App) void {
        self.rebuildTrackRows();
        if (self.cursor != self.track_row_cursor_snap) {
            self.track_row = if (self.cursor >= self.session.project.tracks.items.len)
                self.track_rows_len // master sentinel
            else
                self.rowOfTrack(@intCast(self.cursor));
            self.track_row_cursor_snap = self.cursor;
        }
        if (self.track_row > self.track_rows_len) self.track_row = self.track_rows_len;
    }

    /// Force the next `tracksRowSync` to re-derive `track_row` from
    /// `cursor`. The sync's value-diff heal can't see a structural change
    /// that reshapes the row list while `cursor` keeps its value - e.g.
    /// deleting a track below the cursor when the deleted track was the
    /// first member of a group (the group's row, keyed to its first
    /// member's position, jumps elsewhere in the list).
    pub fn invalidateTrackRow(self: *App) void {
        self.track_row_cursor_snap = std.math.maxInt(usize);
    }

    /// Move the row cursor and mirror it into `cursor`: a track row selects
    /// its track; a group or the master row parks `cursor` one past the last
    /// track - the pre-existing master sentinel every consumer (mute/solo,
    /// MIDI follow, arrangement) already guards - so nothing outside the
    /// tracks view ever targets a bus row.
    pub fn setTrackRow(self: *App, row: usize) void {
        self.track_row = @min(row, self.track_rows_len);
        self.cursor = if (self.rowTrack(self.track_row)) |t| t else self.session.project.tracks.items.len;
        self.track_row_cursor_snap = self.cursor;
    }

    // zig fmt: off
    fn rowTrack(self: *const App, row: usize) ?u16 {
        if (row >= self.track_rows_len) return null;
        return switch (self.track_rows_buf[row]) { .track => |t| t, .group => null };
    }

    /// Track under the row cursor - null on a group or the master row.
    pub fn cursorTrack(self: *const App) ?u16 {
        return self.rowTrack(self.track_row);
    }

    /// Group whose row the cursor is on - null on track/master rows.
    pub fn cursorGroup(self: *const App) ?u8 {
        if (self.track_row >= self.track_rows_len) return null;
        return switch (self.track_rows_buf[self.track_row]) { .group => |g| g, .track => null };
    }
    // zig fmt: on

    /// Row of track `idx` - its group's row when hidden inside a fold.
    fn rowOfTrack(self: *const App, idx: u16) usize {
        var group_row: usize = 0;
        for (self.trackRows(), 0..) |r, ri| switch (r) {
            .track => |t| if (t == idx) return ri,
            .group => |g| {
                const tg = self.session.project.tracks.items[idx].group orelse continue;
                if (tg == g) group_row = ri;
            },
        };
        return group_row;
    }

    fn rowOfGroup(self: *const App, g: u8) ?usize {
        for (self.trackRows(), 0..) |r, ri| switch (r) {
            .group => |gi| if (gi == g) return ri,
            else => {},
        };
        return null;
    }

    /// `z` in the tracks view: fold/unfold the group under (or containing)
    /// the cursor. Folding from a member row lands the cursor on the group's
    /// own row - the rows it could have sat on are gone.
    fn doGroupFoldToggle(self: *App, g: u8) void {
        if (g >= engine_mod.max_groups) return;
        if (self.session.groups[g]) |*grp| {
            grp.folded = !grp.folded;
            self.dirty = true;
            self.rebuildTrackRows();
            self.setTrackRow(self.rowOfGroup(g) orelse self.track_row);
            self.setStatus("\"{s}\" {s}", .{ grp.name, if (grp.folded) "folded" else "unfolded" });
        }
    }

    /// `-`/`+` on a group row: ride the bus fader (session.setGroupGain
    /// clamps to the track-gain range). Mixer-style live state, so - like
    /// track gain/pan - deliberately not undo-tracked.
    fn doGroupGainStep(self: *App, g: u8, delta_db: f32) void {
        if (g >= engine_mod.max_groups) return;
        if (self.session.groups[g]) |*grp| {
            self.session.setGroupGain(g, grp.gain_db + delta_db);
            self.dirty = true;
            const sign: []const u8 = if (grp.gain_db >= 0) "+" else "";
            self.setStatus("group {d} gain: {s}{d:.1}dB", .{ g + 1, sign, grp.gain_db });
        }
    }

    /// `dd` on a group row: delete the group. Members fall back to the
    /// master mix - same semantics as `:group-del`.
    fn doGroupDel(self: *App, g: u8) void {
        if (g >= engine_mod.max_groups or self.session.groups[g] == null) return;
        // Must run before deleteGroup frees the slot - see cmdGroupDel's
        // same call for why.
        _ = history.dropGroupPending(self, g);
        self.session.deleteGroup(g);
        self.dirty = true;
        // `cursor` sat parked on the master sentinel while the group row was
        // selected and doesn't move here, so the value-diff heal never fires
        // - land on whatever shifted into the row's place instead (vim dd
        // semantics), re-mirroring `cursor` from it.
        self.rebuildTrackRows();
        self.setTrackRow(self.track_row);
        self.setStatus("group {d} deleted (members back on the master mix)", .{g + 1});
    }

    // zig fmt: off
    /// Instrument picker: click a row to select + insert it (same as
    /// enter/space); scroll moves the highlight.
    fn pickerMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        const count = picker_kinds.len + self.external_plugins.count(.instrument);
        switch (ev.kind) {
            .press => {
                const item: ?usize = if (row >= 3 and row < 3 + picker_kinds.len)
                    row - 3
                else if (row >= 4 + picker_kinds.len)
                    picker_kinds.len + row - (4 + picker_kinds.len)
                else
                    null;
                if (item == null or item.? >= count) return;
                self.picker_cursor = @intCast(item.?);
                self.pickerInsert();
            },
            .scroll_up => { if (self.picker_cursor > 0) self.picker_cursor -= 1; },
            .scroll_down => { if (self.picker_cursor + 1 < count) self.picker_cursor += 1; },
            else => {},
        }
    }

    /// File browser: click a row to descend into it or activate it (same as
    /// enter/l/space); scroll moves the highlight.
    fn browserMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        if (self.browser_bookmark_mode) return; // keyboard-only overlay
        switch (ev.kind) {
            .press => {
                if (row < 2) return;
                const idx = self.browser_scroll + (row - 2);
                if (idx >= self.browser_entries.items.len) return;
                self.browser_cursor = idx;
                self.browserActivate();
            },
            .scroll_up => { if (self.browser_cursor > 0) self.browser_cursor -= 1; },
            .scroll_down => { if (self.browser_cursor + 1 < self.browser_entries.items.len) self.browser_cursor += 1; },
            else => {},
        }
    }
    // zig fmt: on

    /// Help view: scroll wheel scrolls content (same as j/k). No click behavior.
    fn helpMouse(self: *App, ev: modal_mod.MouseEvent) void {
        switch (ev.kind) {
            .scroll_up => self.help_scroll -|= 1,
            .scroll_down => self.help_scroll += 1,
            else => {},
        }
    }

    /// R opens the command prompt pre-filled with `:rename <n> ` for
    /// the cursor track - type the new name and hit enter (`esc` cancels,
    /// same as any other command-mode entry).
    fn startRenamePrompt(self: *App) void {
        if (self.cursor >= self.session.project.tracks.items.len) return;
        self.modal.mode = .command;
        self.cmd_history_pos = self.cmd_history.items.len;
        const text = std.fmt.bufPrint(&self.modal.cmd_buf, "rename {d} ", .{self.cursor + 1}) catch return;
        self.modal.cmd_len = text.len;
        self.modal.cmd_cursor = text.len;
    }

    // zig fmt: off
    /// Tracks view visual mode's reduced key set: `j`/`k` extend the
    /// selection over display rows (master excluded - the cursor can't
    /// reach it from here since the range never includes it), `g` groups
    /// the selection, `esc` cancels. Everything else is swallowed, matching
    /// the other editors' visual modes.
    fn handleTracksVisual(self: *App, key: modal_mod.Key) void {
        switch (key) {
            .escape => { self.exitTracksVisual(); self.setStatus("selection cancelled", .{}); },
            .char => |c| switch (c) {
                'j' => if (self.track_row + 1 < self.track_rows_len) self.setTrackRow(self.track_row + 1),
                'k' => if (self.track_row > 0) self.setTrackRow(self.track_row - 1),
                'g' => self.groupSelectedTracks(),
                else => {},
            },
            else => {},
        }
    }
    // zig fmt: on

    fn exitTracksVisual(self: *App) void {
        _ = self.modal.setMode(.normal);
        self.tracks_visual_anchor = null;
    }

    /// `g` in tracks-view visual mode: create a new untitled group from the
    /// selected rows. The selection takes what's on screen: track rows join
    /// directly and a *folded*
    /// group row brings its hidden members along; an unfolded group's own
    /// row contributes nothing - its members are rows of their own.
    fn groupSelectedTracks(self: *App) void {
        const anchor = self.tracks_visual_anchor orelse self.track_row;
        const lo = @min(anchor, self.track_row);
        const hi = @max(anchor, self.track_row);
        self.exitTracksVisual();

        // zig fmt: off
        const rows = self.track_rows_buf[lo..@min(hi + 1, self.track_rows_len)];
        var count: usize = 0;
        for (rows) |r| switch (r) {
            .track => count += 1,
            .group => |g| if (self.session.groups[g].?.folded) {
                for (self.session.project.tracks.items) |t| {
                    const tg = t.group orelse continue;
                    if (tg == g) count += 1;
                }
            },
        };
        if (count == 0) { self.setStatus("no tracks selected", .{}); return; }
        // zig fmt: on

        const idx = self.session.addGroup("untitled group") catch |err| {
            self.setStatus("group: {s}", .{switch (err) {
                error.GroupLimitReached => "bank full (8 groups)",
                error.OutOfMemory => "out of memory",
            }});
            return;
        };
        for (rows) |r| switch (r) {
            .track => |t| self.session.assignTrackGroup(t, idx),
            .group => |g| if (self.session.groups[g].?.folded) {
                for (self.session.project.tracks.items, 0..) |t, j| {
                    const tg = t.group orelse continue;
                    if (tg == g) self.session.assignTrackGroup(j, idx);
                }
            },
        };
        self.dirty = true;
        self.rebuildTrackRows();
        self.setTrackRow(self.rowOfGroup(idx) orelse 0);
    }

    /// Same prefill pattern as `startRenamePrompt`, targeting a group row.
    fn startGroupRenamePrompt(self: *App, idx: u8) void {
        self.modal.mode = .command;
        self.cmd_history_pos = self.cmd_history.items.len;
        const text = std.fmt.bufPrint(&self.modal.cmd_buf, "rename {d} ", .{idx + 1}) catch return;
        self.modal.cmd_len = text.len;
        self.modal.cmd_cursor = text.len;
    }

    /// c toggles the click track (also `:metronome [on|off]`).
    fn toggleMetronome(self: *App) void {
        const on = !self.session.metronome_enabled;
        self.session.setMetronome(on);
        self.setStatus("metronome {s}", .{if (on) "on" else "off"});
    }

    /// r toggles record-arm on a track (tracks view). Not persisted, not
    /// undo-tracked - same posture as metronome toggling (a monitoring/
    /// recording aid, not song content). Arming a non-Sampler track is
    /// accepted (so the indicator stays available on every row) but inert:
    /// `Session.isAudioArmed` only turns true for a Sampler instrument, so
    /// nothing else in this codepath changes for other track kinds.
    fn doTrackArmToggle(self: *App, track_idx: usize) void {
        if (track_idx >= self.session.project.tracks.items.len) return;
        self.session.toggleArm(track_idx);
        const armed = self.session.isArmed(track_idx);
        const name = self.session.project.tracks.items[track_idx].name;
        self.setStatus("\"{s}\" {s}", .{ name, if (armed) "armed" else "disarmed" });
    }

    /// The Sampler at `track_idx`, or null if that track isn't one -
    /// same access pattern as `commands.zig`'s `cursorSampler`, just not
    /// limited to the cursor track (recording targets are resolved once at
    /// record-start and may not be wherever the cursor ends up by the time
    /// the pass finishes).
    fn samplerAt(self: *App, track_idx: usize) ?*Sampler {
        if (track_idx >= self.session.racks.items.len) return null;
        return switch (self.session.racks.items[track_idx].instrument) {
            .sampler => |*s| s,
            else => null,
        };
    }

    fn hasArmedAudioTarget(self: *const App) bool {
        for (0..self.session.racks.items.len) |i| if (self.session.isAudioArmed(i)) return true;
        return false;
    }

    /// Snapshots every currently audio-armed track into `recording_pending`
    /// - called from `toggle_play` right before `.record` is sent, so the
    /// set of targets is locked in before the count-in (arming/disarming
    /// mid-pass doesn't retarget an in-flight recording).
    fn resolveArmedAudioTargets(self: *App) void {
        self.recording_pending_len = 0;
        for (0..self.session.racks.items.len) |i| {
            if (self.recording_pending_len >= self.recording_pending_buf.len) break;
            if (self.session.isAudioArmed(i)) {
                self.recording_pending_buf[self.recording_pending_len] = @intCast(i);
                self.recording_pending_len += 1;
            }
        }
    }

    /// Called by `tick` the instant a record pass's count-in finishes and
    /// the transport actually starts (playing false->true) with pending
    /// audio targets queued. Opens the input device for real; a missing
    /// device (or a platform with no capture backend) reports status and
    /// leaves the pass MIDI-only rather than failing the whole record.
    fn startPendingRecording(self: *App) void {
        if (self.recording_pending_len == 0) return;
        if (self.audio_input.start(self.session.project.sample_rate)) |_| {
            self.recording_active_len = self.recording_pending_len;
            @memcpy(
                self.recording_active_buf[0..self.recording_active_len],
                self.recording_pending_buf[0..self.recording_pending_len],
            );
            self.recording_accum.clearRetainingCapacity();
        } else |_| {
            self.setStatus("record: no audio input device", .{});
        }
        self.recording_pending_len = 0;
    }

    /// Drains whatever `audio_input` has queued into `recording_accum` -
    /// called every tick while a pass is active, and once more at the very
    /// end of `finishRecording` to pick up the tail.
    fn drainRecording(self: *App) void {
        while (self.audio_input.pop()) |block| {
            self.recording_accum.appendSlice(self.allocator, block.samples[0..block.frames]) catch break;
        }
    }

    /// Called by `tick` the instant a record pass ends (playing true->false)
    /// with active audio targets. Stops capture, then hands the take to
    /// every active target the same way `commands.loadClipFromPath` hands a
    /// loaded WAV to one: `Sampler.setSamples`, a whole-clip one-shot note,
    /// and a stamp into the arrangement at `arr_cursor_bar` - "an audio clip
    /// is just a Sampler track with one note spanning its own duration,
    /// stamped into the arrangement" applies here exactly as it does there.
    /// `pub` so tests can drive it directly with synthetic
    /// `recording_accum`/`recording_active_*` state, without a real capture
    /// device (mirrors `doTrackAdd`/`doTrackDup` etc. being `pub` for the
    /// same reason).
    pub fn finishRecording(self: *App) void {
        if (self.recording_active_len == 0) return;
        self.audio_input.stop();
        self.drainRecording();

        const targets = self.recording_active_buf[0..self.recording_active_len];
        if (self.recording_accum.items.len == 0) {
            self.setStatus("no audio captured", .{});
            self.recording_active_len = 0;
            return;
        }

        const bpm = @max(self.session.project.tempo_bpm, 1.0);
        const sr_f: f64 = @floatFromInt(self.session.project.sample_rate);
        const beats = @as(f64, @floatFromInt(self.recording_accum.items.len)) * bpm / (sr_f * 60.0);
        const length_beats = @max(beats, 1.0);
        var clip_count: usize = 0;
        for (targets) |track_idx| {
            const s = self.samplerAt(track_idx) orelse continue;
            const copy = self.allocator.dupe(f32, self.recording_accum.items) catch continue;
            s.setSamples(copy, "recorded");
            s.pad.user_sample = true;

            const notes = [_]pattern_mod.Note{.{ .pitch = s.root_note, .start_beat = 0.0, .duration_beat = length_beats }};
            self.session.racks.items[track_idx].pattern_player.?.setNotes(&notes, length_beats);

            history.recordLane(self, @intCast(track_idx));
            self.session.stampClipAtTick(track_idx, self.arr_cursor_bar * self.arr_grid.ticks()) catch continue;
            clip_count += 1;
        }
        if (self.session.song_mode) self.session.rebuildSongData();

        const secs = @as(f64, @floatFromInt(self.recording_accum.items.len)) / sr_f;
        self.setStatus("recorded {d} clip(s) ({d:.1}s)", .{ clip_count, secs });
        if (clip_count > 0) self.dirty = true;
        self.recording_active_len = 0;
    }

    /// t taps the tempo: each tap after the first sets the BPM from the
    /// average interval since the start of the current tap run. A gap
    /// longer than `tap_timeout_ns` starts a fresh run instead of averaging
    /// across it.
    fn tapTempo(self: *App, now_ns: i96) void {
        if (self.tap_count > 0 and now_ns - self.tap_times[self.tap_count - 1] > self.tap_timeout_ns) {
            self.tap_count = 0;
        }
        if (self.tap_count == self.tap_times.len) {
            std.mem.copyForwards(i96, self.tap_times[0 .. self.tap_times.len - 1], self.tap_times[1..]);
            self.tap_count -= 1;
        }
        self.tap_times[self.tap_count] = now_ns;
        self.tap_count += 1;

        if (self.tap_count < 2) {
            self.setStatus("tap tempo: tap again to set bpm", .{});
            return;
        }
        const span_ns = self.tap_times[self.tap_count - 1] - self.tap_times[0];
        const intervals: f64 = @floatFromInt(self.tap_count - 1);
        const avg_s = @as(f64, @floatFromInt(span_ns)) / intervals / @as(f64, std.time.ns_per_s);
        const bpm = std.math.clamp(60.0 / avg_s, 20.0, 400.0);
        self.session.project.tempo_bpm = bpm;
        _ = self.session.engine.send(.{ .set_tempo = bpm });
        self.session.syncLoop(); // loop region is stored in bars; its frame mirror just moved
        self.dirty = true;
        self.setStatus("tap tempo: {d:.1} bpm ({d} taps)", .{ bpm, self.tap_count });
    }

    // zig fmt: off
    /// View->mode soft coupling: entering the arrangement nudges song mode
    /// on; leaving it back to tracks, or entering a live-pattern editor from
    /// tracks, nudges it off. Only while the transport is stopped - switching
    /// views must never yank a playing source (mixing during song playback,
    /// clip-linked editing, sound design against the song). `T` (arrangement
    /// and tracks both) stays the manual override either way.
    pub fn autoSongMode(self: *App, on: bool) void {
        if (self.session.song_mode == on) return;
        if (self.session.engine.uiSnapshot().playing) return;
        self.session.setSongMode(on);
        self.setStatus("{s} mode", .{if (on) "song" else "pattern"});
    }

    /// Open the instrument picker on `cursor`'s track. `replace` selects
    /// which of the two flows in `pickerInsert` accepting a kind runs:
    /// building a fresh instrument (blank track, `enter`) or swapping the
    /// live one via `Session.changeInstrumentKind` (already-populated
    /// track, `I`). Preselects the cursor at the track's current kind when
    /// replacing, so opening the picker shows what's already there.
    fn openInstrumentPicker(self: *App, cursor: usize, replace: bool) void {
        self.picker_replace = replace;
        self.picker_cursor = 0;
        if (cursor < self.session.racks.items.len) {
            const kind = std.meta.activeTag(self.session.racks.items[cursor].instrument);
            for (picker_kinds, 0..) |k, i| {
                if (k == kind) { self.picker_cursor = @intCast(i); break; }
            }
        }
        self.view = .instrument_picker;
    }

    /// Open the editor matching the track's instrument, or the instrument
    /// picker if the track is blank.
    fn openTrack(self: *App, cursor: usize) void {
        if (cursor >= self.session.racks.items.len) return;
        switch (self.session.racks.items[cursor].instrument) {
            .empty => self.openInstrumentPicker(cursor, false),
            .poly_synth => {
                self.synth_track = @intCast(cursor);
                self.synth_cursor = 0;
                self.synth_subview = .main;
                self.synth_section_focus = false;
                self.view = .synth_editor;
            },
            .sampler => {
                self.sampler_target = .{ .sampler = @intCast(cursor) };
                self.sampler_param = 0;
                self.view = .sampler_editor;
            },
            .drum_machine => {
                self.drum_track = @intCast(cursor);
                self.drum_stamp = false;
                self.view = .drum_grid;
                self.autoSongMode(false);
            },
            .slicer => {
                self.slicer_track = @intCast(cursor);
                self.view = .slicer_grid;
                self.autoSongMode(false);
                // An empty slicer can only chop audio it doesn't have yet -
                // skip the empty state and go straight to the one useful
                // action. `openBrowser` captures `.slicer_grid` as the
                // return view, so escape/load both land back here.
                if (!self.session.racks.items[cursor].instrument.slicer.hasAudio()) {
                    self.openBrowser(.load_slice);
                }
            },
            .clap => {
                self.piano_track = @intCast(cursor);
                self.view = .piano_roll;
            },
            .soundfont => {
                self.soundfont_track = @intCast(cursor);
                self.soundfont_param = 0;
                self.view = .soundfont_editor;
            },
        }
    }

    /// Instrument picker: j/k move, g/G jump to ends, enter/space insert the
    /// highlighted kind on the cursor track and jump to its editor, esc
    /// cancels back to tracks.
    fn handlePickerKey(self: *App, key: modal_mod.Key) void {
        const count = picker_kinds.len + self.external_plugins.count(.instrument);
        switch (key) {
            .escape => self.view = .tracks,
            .enter => self.pickerInsert(),
            .char => |c| switch (c) {
                'k' => { if (self.picker_cursor > 0) self.picker_cursor -= 1; },
                'j' => { if (self.picker_cursor + 1 < count) self.picker_cursor += 1; },
                'g' => self.picker_cursor = 0,
                'G' => self.picker_cursor = @intCast(count -| 1),
                ' ' => self.pickerInsert(),
                'q' => self.view = .tracks,
                else => {},
            },
            else => {},
        }
    }
    // zig fmt: on

    fn pickerInsert(self: *App) void {
        if (self.picker_cursor >= picker_kinds.len) {
            const plugin = self.external_plugins.at(.instrument, self.picker_cursor - picker_kinds.len) orelse return;
            switch (plugin.format) {
                .clap => self.session.setClapInstrument(self.cursor, plugin.path, plugin.id) catch |err| {
                    self.setStatus("{s}: {s}", .{ plugin.name, @errorName(err) });
                    return;
                },
                .vst3, .vst2 => unreachable,
            }
            self.dirty = true;
            // CLAP instruments always go through `setClapInstrument`, which
            // (like `setInstrument`) has no note-preserving counterpart - see
            // `Session.changeInstrumentKind`'s doc comment on why a bare
            // kind-to-CLAP swap can't be built without a path/id.
            self.setStatus("{s}  CLAP  {s}", .{ plugin.name, if (self.picker_replace) "(notes cleared)" else "inserted" });
            self.view = .tracks;
            self.openTrack(self.cursor);
            return;
        }
        const kind = picker_kinds[self.picker_cursor];
        if (self.picker_replace) {
            if (std.meta.activeTag(self.session.racks.items[self.cursor].instrument) == kind) {
                self.setStatus("track {d} is already {s}", .{ self.cursor + 1, picker_labels[self.picker_cursor] });
                self.view = .tracks;
                return;
            }
            var backup = history.captureTrackKindSwap(self, self.cursor);
            const preserved = self.session.changeInstrumentKind(self.cursor, kind) catch |err| {
                if (backup) |*b| b.deinit(self.allocator);
                self.setStatus("track-instrument: {s}", .{@errorName(err)});
                self.view = .tracks;
                return;
            };
            history.push(self, backup);
            self.dirty = true;
            if (preserved) {
                self.setStatus("track {d}: now {s} (notes kept)", .{ self.cursor + 1, picker_labels[self.picker_cursor] });
            } else {
                self.setStatus("track {d}: now {s} (no compatible mapping - notes cleared)", .{ self.cursor + 1, picker_labels[self.picker_cursor] });
            }
            self.view = .tracks;
            self.openTrack(self.cursor);
            return;
        }
        self.session.setInstrument(self.cursor, kind) catch {
            self.setStatus("insert failed (out of memory)", .{});
            self.view = .tracks;
            return;
        };
        self.dirty = true;
        const hint: []const u8 = switch (kind) {
            .empty => "?: help",
            .poly_synth => "j/k: move  h/l: adjust  i: play  ?: help",
            .sampler => "j/k: move  h/l: adjust  i: play  ?: help",
            .drum_machine => "enter: step  i: play  space: record  ?: help",
            .slicer => "enter: step  i: play  :load  ?: help",
            .clap => "enter: piano roll  i: play  ?: help",
            .soundfont => "h/l: adjust  :load-soundfont  i: play  ?: help",
        };
        self.setStatus("{s} inserted  {s}", .{ picker_labels[self.picker_cursor], hint });
        self.view = .tracks;
        self.openTrack(self.cursor);
    }

    // zig fmt: off
    /// FX picker: j/k move, g/G jump to ends, `/` filters (see
    /// spectrum_ed.activeFilter), enter/space insert the highlighted effect
    /// after the focused chain slot, esc cancels back to the chain view.
    /// Opened by `a` in the FX chain view (see editors/spectrum.zig's
    /// openPicker). The filter can shrink the list out from under a stale
    /// cursor, so every access re-resolves `kinds` and clamps first.
    fn handleFxPickerKey(self: *App, key: modal_mod.Key) void {
        var buf: [spectrum_ed.picker_kinds.len]ws.FxKind = undefined;
        const kinds = spectrum_ed.filteredPickerKinds(self, &buf);
        const count = kinds.len + spectrum_ed.externalPickerCount(self);
        if (count > 0 and self.fx_picker_cursor >= count) self.fx_picker_cursor = @intCast(count - 1);
        switch (key) {
            .escape => spectrum_ed.cancelPicker(self),
            .enter => self.activateFxPickerItem(kinds),
            .char => |c| switch (c) {
                'k' => { if (self.fx_picker_cursor > 0) self.fx_picker_cursor -= 1; },
                'j' => { if (self.fx_picker_cursor + 1 < count) self.fx_picker_cursor += 1; },
                'g' => self.fx_picker_cursor = 0,
                'G' => self.fx_picker_cursor = @intCast(count -| 1),
                ' ' => self.activateFxPickerItem(kinds),
                'q' => spectrum_ed.cancelPicker(self),
                else => {},
            },
            else => {},
        }
    }

    fn activateFxPickerItem(self: *App, kinds: []const ws.FxKind) void {
        if (self.fx_picker_cursor < kinds.len) {
            spectrum_ed.insertFromPicker(self, kinds[self.fx_picker_cursor]);
        } else if (spectrum_ed.externalPickerAt(self, self.fx_picker_cursor - kinds.len)) |plugin| {
            spectrum_ed.insertExternalFromPicker(self, plugin);
        }
    }

    /// FX picker: click a row to select + insert it (same as enter/space);
    /// scroll moves the highlight.
    fn fxPickerMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        var buf: [spectrum_ed.picker_kinds.len]ws.FxKind = undefined;
        const kinds = spectrum_ed.filteredPickerKinds(self, &buf);
        const external_count = spectrum_ed.externalPickerCount(self);
        switch (ev.kind) {
            .press => {
                const item: ?usize = if (row >= 3 and row < 3 + kinds.len)
                    row - 3
                else if (row >= 4 + kinds.len)
                    kinds.len + row - (4 + kinds.len)
                else
                    null;
                if (item == null or item.? >= kinds.len + external_count) return;
                self.fx_picker_cursor = @intCast(item.?);
                self.activateFxPickerItem(kinds);
            },
            .scroll_up => { if (self.fx_picker_cursor > 0) self.fx_picker_cursor -= 1; },
            .scroll_down => { if (self.fx_picker_cursor + 1 < kinds.len + external_count) self.fx_picker_cursor += 1; },
            else => {},
        }
    }

    /// Synth-internal FX picker: j/k move, g/G jump to ends, `/` filters
    /// (see synth_ed.activeFxFilter), enter/space insert the highlighted
    /// unit, esc cancels back to the `.fx` subview. Opened by `a` there (see
    /// editors/synth.zig's openFxPicker). The list is the currently-off
    /// units narrowed by the filter, so it's recomputed (and re-bounded) on
    /// every call.
    fn handleSynthFxPickerKey(self: *App, key: modal_mod.Key) void {
        var buf: [14]ws.dsp.synth.FxUnitKind = undefined;
        const kinds = synth_ed.filteredSynthFxPickerKinds(self, &buf);
        if (kinds.len > 0 and self.synth_fx_picker_cursor >= kinds.len) self.synth_fx_picker_cursor = @intCast(kinds.len - 1);
        switch (key) {
            .escape => synth_ed.cancelSynthFxPicker(self),
            .enter => if (self.synth_fx_picker_cursor < kinds.len) synth_ed.insertFromSynthFxPicker(self, kinds[self.synth_fx_picker_cursor]),
            .char => |c| switch (c) {
                'k' => { if (self.synth_fx_picker_cursor > 0) self.synth_fx_picker_cursor -= 1; },
                'j' => { if (self.synth_fx_picker_cursor + 1 < kinds.len) self.synth_fx_picker_cursor += 1; },
                'g' => self.synth_fx_picker_cursor = 0,
                'G' => self.synth_fx_picker_cursor = @intCast(kinds.len -| 1),
                ' ' => if (self.synth_fx_picker_cursor < kinds.len) synth_ed.insertFromSynthFxPicker(self, kinds[self.synth_fx_picker_cursor]),
                'q' => synth_ed.cancelSynthFxPicker(self),
                else => {},
            },
            else => {},
        }
    }

    /// Synth-internal FX picker: click a row to select + insert it (same as
    /// enter/space); scroll moves the highlight. Mirrors `fxPickerMouse`.
    fn synthFxPickerMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        var buf: [14]ws.dsp.synth.FxUnitKind = undefined;
        const kinds = synth_ed.filteredSynthFxPickerKinds(self, &buf);
        switch (ev.kind) {
            .press => {
                if (row < 2 or row - 2 >= kinds.len) return;
                self.synth_fx_picker_cursor = @intCast(row - 2);
                synth_ed.insertFromSynthFxPicker(self, kinds[self.synth_fx_picker_cursor]);
            },
            .scroll_up => { if (self.synth_fx_picker_cursor > 0) self.synth_fx_picker_cursor -= 1; },
            .scroll_down => { if (self.synth_fx_picker_cursor + 1 < kinds.len) self.synth_fx_picker_cursor += 1; },
            else => {},
        }
    }

    /// Synth-param automation picker: j/k move (skipping rows the active
    /// `/` filter hides), g/G jump to ends, enter/space start automating the
    /// highlighted param on the current clip, esc cancels back to the
    /// automation view. Opened by `p` in editors/automation.zig.
    fn handleAutomationParamPickerKey(self: *App, key: modal_mod.Key) void {
        switch (key) {
            .escape => self.view = .automation,
            .enter => self.automationParamPick(),
            .char => |c| switch (c) {
                'k' => automation_ed.moveParamCursor(self, -1),
                'j' => automation_ed.moveParamCursor(self, 1),
                'g' => self.automation_param_cursor = automation_ed.firstParamCursor(self),
                'G' => self.automation_param_cursor = automation_ed.lastParamCursor(self),
                ' ' => self.automationParamPick(),
                'q' => self.view = .automation,
                else => {},
            },
            else => {},
        }
    }
    // zig fmt: on

    fn automationParamPick(self: *App) void {
        const params = automation_ed.instrumentAutomatableParams(self);
        if (self.automation_param_cursor >= params.len) return;
        automation_ed.selectParam(self, params[self.automation_param_cursor].id);
    }

    // zig fmt: off
    /// Param picker: click a param row to select + apply it (same as enter/
    /// space); header rows aren't clickable. Scroll moves the highlight.
    /// Row math mirrors `views/automation.zig`'s `drawAutomationParamPicker`
    /// exactly (title(1) + blank(1) before the display-row list starts) -
    /// both build the same list via `automation_ed.buildParamDisplayRows`.
    fn automationParamPickerMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        switch (ev.kind) {
            .press => {
                if (row < 2) return;
                var buf: [automation_ed.max_param_display_rows]automation_ed.ParamDisplayRow = undefined;
                const rows_list = automation_ed.buildParamDisplayRows(automation_ed.instrumentAutomatableParams(self), automation_ed.activeParamFilter(self), &buf);
                const display_row = self.automation_param_scroll + (row - 2);
                if (display_row >= rows_list.len) return;
                switch (rows_list[display_row]) {
                    .header => {},
                    .param => |i| {
                        self.automation_param_cursor = @intCast(i);
                        self.automationParamPick();
                    },
                }
            },
            .scroll_up => automation_ed.moveParamCursor(self, -1),
            .scroll_down => automation_ed.moveParamCursor(self, 1),
            else => {},
        }
    }
    // zig fmt: on

    // -----------------------------------------------------------------------
    // File browser (netrw/dired-style; `:e`, `:load` with
    // no path open it - see commands.zig)
    // -----------------------------------------------------------------------

    /// Enter the browser for `purpose`, starting in the current project's
    /// directory, or `default_browse_dir` (cwd if unset) when no project
    /// path is known yet. Leaves the view untouched if that starting
    /// directory can't be listed.
    pub fn openBrowser(self: *App, purpose: BrowserPurpose) void {
        self.browser_purpose = purpose;
        var expand_buf: [reload_path_buf_len]u8 = undefined;
        const start: []const u8 = if (self.projectPath()) |p|
            (std.fs.path.dirname(p) orelse ".")
        else if (self.default_browse_dir.len > 0)
            commands.expandHome(&expand_buf, self.default_browse_dir.slice())
        else
            ".";
        self.setBrowserDir(start) catch |e| {
            self.setStatus("browse: cannot open '{s}': {s}", .{ start, @errorName(e) });
            return;
        };
        self.prev_view = self.view;
        self.view = .file_browser;
    }

    /// GUI bookmark sidebar jump. Keeps path canonicalization and entry
    /// filtering on the same path as keyboard-driven browser navigation.
    pub fn browserJumpTo(self: *App, path: []const u8) void {
        self.setBrowserDir(path) catch |err| {
            self.setStatus("browse: cannot open '{s}': {s}", .{ path, @errorName(err) });
        };
    }

    /// Free the current entry list's owned names (keeps the list's capacity).
    fn freeBrowserEntries(self: *App) void {
        for (self.browser_entries.items) |e| self.allocator.free(e.name);
        self.browser_entries.clearRetainingCapacity();
    }

    /// Resolve `path` to a canonical absolute directory and (re)list it into
    /// `browser_entries`. Builds the new listing before touching any existing
    /// state, so a bad path (deleted dir, permission error, …) leaves the
    /// browser exactly where it was.
    fn setBrowserDir(self: *App, path: []const u8) !void {
        const canon = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
        errdefer self.allocator.free(canon);

        var dir = try std.Io.Dir.cwd().openDir(self.io, canon, .{ .iterate = true });
        defer dir.close(self.io);

        var new_entries: std.ArrayListUnmanaged(BrowserEntry) = .empty;
        errdefer {
            for (new_entries.items) |e| self.allocator.free(e.name);
            new_entries.deinit(self.allocator);
        }
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.name.len == 0 or (!self.file_browser_show_hidden and entry.name[0] == '.')) continue;
            const is_dir = entry.kind == .directory;
            if (!is_dir and !std.ascii.endsWithIgnoreCase(entry.name, self.browser_purpose.ext())) continue;
            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);
            try new_entries.append(self.allocator, .{ .name = name, .is_dir = is_dir });
        }
        std.mem.sort(BrowserEntry, new_entries.items, {}, browserEntryLess);

        self.freeBrowserEntries();
        self.browser_entries.deinit(self.allocator);
        if (self.browser_dir.len > 0) self.allocator.free(self.browser_dir);
        self.browser_dir = canon;
        self.browser_entries = new_entries;
        self.browser_cursor = 0;
        self.browser_scroll = 0;
    }

    /// Directories first, then alphabetical (case-insensitive) within each
    /// group - matches `ls`/netrw ordering.
    fn browserEntryLess(_: void, a: BrowserEntry, b: BrowserEntry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir;
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    // zig fmt: off
    /// j/k move, enter/l/space descend into a dir or pick a file, h/backspace
    /// go to the parent dir, g/G jump to the list ends, `~` jumps home,
    /// esc/q cancel back to the view that opened the browser.
    fn handleBrowserKey(self: *App, key: modal_mod.Key) void {
        if (self.browser_bookmark_mode) {
            self.handleBookmarkListKey(key);
            return;
        }
        switch (key) {
            .escape => self.closeBrowser(),
            .enter => self.browserActivate(),
            .backspace => self.browserGoUp(),
            .char => |c| switch (c) {
                'j' => { if (self.browser_cursor + 1 < self.browser_entries.items.len) self.browser_cursor += 1; },
                'k' => { if (self.browser_cursor > 0) self.browser_cursor -= 1; },
                'g' => self.browser_cursor = 0,
                'G' => self.browser_cursor = self.browser_entries.items.len -| 1,
                'l', ' ' => self.browserActivate(),
                'h' => self.browserGoUp(),
                '~' => {
                    const home_z = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return;
                    const home = std.mem.sliceTo(home_z, 0);
                    self.setBrowserDir(home) catch |e| self.setStatus("browse: {s}", .{@errorName(e)});
                },
                '/' => {
                    self.modal.mode = .search;
                    self.modal.cmd_len = 0;
                    self.modal.cmd_cursor = 0;
                },
                'n' => self.searchBrowser(1),
                'N' => self.searchBrowser(-1),
                'b' => self.toggleBookmark(),
                'B' => {
                    if (self.bookmarks.items.len == 0) {
                        self.setStatus("no bookmarks yet - b marks the entry under the cursor", .{});
                        return;
                    }
                    self.browser_bookmark_mode = true;
                    self.bookmark_cursor = @min(self.bookmark_cursor, self.bookmarks.items.len - 1);
                },
                'q' => self.closeBrowser(),
                else => {},
            },
            else => {},
        }
    }
    // zig fmt: on

    /// `b`: toggle the entry under the browser cursor in/out of `bookmarks`,
    /// keyed by absolute path so the same file/dir reached two different ways
    /// still dedupes.
    fn toggleBookmark(self: *App) void {
        if (self.browser_cursor >= self.browser_entries.items.len) return;
        const entry = self.browser_entries.items[self.browser_cursor];
        const joined = std.fs.path.join(self.allocator, &.{ self.browser_dir, entry.name }) catch return;
        defer self.allocator.free(joined);

        for (self.bookmarks.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.path, joined)) {
                self.allocator.free(b.path);
                _ = self.bookmarks.swapRemove(i);
                self.setStatus("unbookmarked: {s}", .{entry.name});
                bookmark_store.save(self.allocator, self.io, self.bookmarks.items) catch {};
                return;
            }
        }
        const owned = self.allocator.dupe(u8, joined) catch return;
        self.bookmarks.append(self.allocator, .{ .path = owned, .is_dir = entry.is_dir }) catch {
            self.allocator.free(owned);
            return;
        };
        self.setStatus("bookmarked: {s}", .{entry.name});
        bookmark_store.save(self.allocator, self.io, self.bookmarks.items) catch {};
    }

    // zig fmt: off
    /// Key handling while `browser_bookmark_mode` is showing the bookmark
    /// list instead of the current directory.
    fn handleBookmarkListKey(self: *App, key: modal_mod.Key) void {
        switch (key) {
            .escape => self.browser_bookmark_mode = false,
            .enter => self.jumpToBookmark(),
            .char => |c| switch (c) {
                'j' => { if (self.bookmark_cursor + 1 < self.bookmarks.items.len) self.bookmark_cursor += 1; },
                'k' => { if (self.bookmark_cursor > 0) self.bookmark_cursor -= 1; },
                'g' => self.bookmark_cursor = 0,
                'G' => self.bookmark_cursor = self.bookmarks.items.len -| 1,
                'l', ' ' => self.jumpToBookmark(),
                'd' => {
                    if (self.bookmark_cursor >= self.bookmarks.items.len) return;
                    self.allocator.free(self.bookmarks.items[self.bookmark_cursor].path);
                    _ = self.bookmarks.swapRemove(self.bookmark_cursor);
                    if (self.bookmarks.items.len == 0) self.browser_bookmark_mode = false
                    else self.bookmark_cursor = @min(self.bookmark_cursor, self.bookmarks.items.len - 1);
                    bookmark_store.save(self.allocator, self.io, self.bookmarks.items) catch {};
                },
                'q' => self.browser_bookmark_mode = false,
                else => {},
            },
            else => {},
        }
    }

    /// enter/l/space on a bookmark: directories are opened directly; a
    /// bookmarked file opens its parent directory with the cursor on it if
    /// the current browser purpose's extension filter still shows it (see
    /// setBrowserDir), otherwise the parent directory listing is still a
    /// reasonable landing spot.
    fn jumpToBookmark(self: *App) void {
        if (self.bookmark_cursor >= self.bookmarks.items.len) return;
        const bm = self.bookmarks.items[self.bookmark_cursor];
        const dir = if (bm.is_dir) bm.path else (std.fs.path.dirname(bm.path) orelse bm.path);
        self.setBrowserDir(dir) catch |e| {
            self.setStatus("browse: {s}", .{@errorName(e)});
            return;
        };
        if (!bm.is_dir) {
            const base = std.fs.path.basename(bm.path);
            for (self.browser_entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.name, base)) { self.browser_cursor = i; break; }
            }
        }
        self.browser_bookmark_mode = false;
    }
    // zig fmt: on

    /// Parent of `browser_dir` (root's parent is itself - nothing to go up to).
    fn browserGoUp(self: *App) void {
        const parent = std.fs.path.dirname(self.browser_dir) orelse return;
        self.setBrowserDir(parent) catch |e| self.setStatus("browse: {s}", .{@errorName(e)});
    }

    /// Enter/l/space on the highlighted entry: descend into a directory, or
    /// resolve a file against the browser's purpose and close.
    fn browserActivate(self: *App) void {
        if (self.browser_cursor >= self.browser_entries.items.len) return;
        const entry = self.browser_entries.items[self.browser_cursor];
        const joined = std.fs.path.join(self.allocator, &.{ self.browser_dir, entry.name }) catch return;
        defer self.allocator.free(joined);

        if (entry.is_dir) {
            self.setBrowserDir(joined) catch |e| self.setStatus("browse: {s}", .{@errorName(e)});
            return;
        }
        switch (self.browser_purpose) {
            // Only reachable via a non-forced `:e` (openBrowser's sole
            // .open_project caller, commands.editOrRevert) - the dirty
            // refusal that skips there for a given path belongs here
            // instead, since browsing itself was allowed through regardless.
            .open_project => if (self.dirty) {
                self.setStatus("unsaved changes - :write to save, :edit! to discard", .{});
            } else {
                self.requestReload(joined);
            },
            .load_sample => commands.loadSampleFromPath(self, joined),
            .load_pad => |pad| commands.loadPadFromPath(self, pad, joined),
            .load_clip => commands.loadClipFromPath(self, joined),
            .load_slice => commands.loadSliceFromPath(self, joined),
            .load_wavetable => |slot| commands.loadWavetableFromPath(self, slot, joined),
            .load_soundfont => commands.loadSoundfontFromPath(self, joined),
        }
        self.closeBrowser();
    }

    fn closeBrowser(self: *App) void {
        self.freeBrowserEntries();
        self.browser_bookmark_mode = false;
        self.view = self.prev_view;
    }

    // zig fmt: off
    /// Track that mute/solo/note-preview act on outside the tracks view -
    /// the track whose editor is actually open, not the (possibly stale)
    /// tracks-view cursor. Keep this in sync with every per-track editor;
    /// missing a view here means mute/solo/preview silently hit the wrong
    /// track whenever that view's own track diverges from `self.cursor`.
    fn currentTrack(self: *App) u16 {
        return switch (self.view) {
            .synth_editor   => self.synth_track,
            .piano_roll     => self.piano_track,
            .drum_grid      => self.drum_track,
            .slicer_grid    => self.slicer_track,
            .sampler_editor => self.sampler_target.track(),
            .track_spectrum => self.eq_track,
            .automation     => self.automation_track,
            .preset_picker  => self.preset_picker_track,
            .soundfont_editor => self.soundfont_track,
            else            => @intCast(self.cursor),
        };
    }
    // zig fmt: on

    pub fn applyAction(self: *App, action: modal_mod.Action, now_ns: i96) void {
        switch (action) {
            .none, .octave_up, .octave_down => {},
            .goto_end => {
                const end_frames: u64 = @intFromFloat(self.session.engine.transport.framesPerBeat() * self.contentBeats());
                _ = self.session.engine.send(.{ .seek_frames = end_frames });
            },
            .volume_delta => |delta| {
                self.master_gain_db = std.math.clamp(
                    self.master_gain_db + @as(f32, @floatFromInt(delta)),
                    -40.0,
                    6.0,
                );
                _ = self.session.engine.send(.{ .set_master_gain = types.dbToGain(self.master_gain_db) });
            },
            .mode_changed => |m| {
                self.status_len = 0;
                // Fresh entry into the prompt starts recall from the newest.
                if (m == .command) {
                    self.cmd_history_pos = self.cmd_history.items.len;
                    self.suggest_popup_open = false;
                }
                if (m == .command or m == .search) {
                    // synth/sampler/spectrum have no ':' or '/' arm of their
                    // own, so entering command/search mode from one of
                    // those editors would otherwise never close an open
                    // nudge batch - this is the one place all of them
                    // funnel through. No-op if nothing's pending.
                    history.flushParamNudge(self);
                    history.flushFxNudge(self);
                }
            },
            .move => |m| {
                if (self.view == .tracks) {
                    // Row-space movement: tracks, group rows, and - one
                    // extra slot past the end - the pinned master row.
                    self.tracksRowSync();
                    const target: i64 = @as(i64, @intCast(self.track_row)) + m.dy;
                    const last: i64 = @intCast(self.track_rows_len);
                    self.setTrackRow(@intCast(std.math.clamp(target, 0, last)));
                } else {
                    const count: i64 = @as(i64, @intCast(self.cursor)) + m.dy;
                    // One extra slot past the last real track - the master row.
                    const last: i64 = @intCast(self.session.project.tracks.items.len);
                    self.cursor = @intCast(std.math.clamp(count, 0, last));
                }
            },
            .goto_start => _ = self.session.engine.send(.{ .seek_frames = 0 }),
            .toggle_play => {
                const snap = self.session.engine.uiSnapshot();
                if (snap.pre_rolling) {
                    // A second press while the count-in is clicking cancels
                    // it instead of arming another one on top. The transport
                    // never reaches `playing`, so `tick`'s edge-detector
                    // would never consume `recording_pending` on its own -
                    // clear it here so a later, unrelated plain `.play`
                    // can't pick up this canceled attempt's stale targets.
                    _ = self.session.engine.send(.stop);
                    self.recording_pending_len = 0;
                    self.setStatus("count-in cancelled", .{});
                } else if (!snap.playing and (self.hasArmedAudioTarget() or
                    (self.modal.mode == .insert and (self.view == .piano_roll or self.view == .drum_grid))))
                {
                    // Starting playback to record (insert mode, piano roll or
                    // drum grid, currently stopped) clicks a `count_in_bars`
                    // count-in first so there's a cue to come in on (0 skips
                    // it and starts immediately - see `wstudio.o.count_in_bars`).
                    // Already-rolling playback (jumping into insert mode
                    // mid-song) needs none of this - recordNote just
                    // quantizes to the live playhead. Any audio-armed
                    // Sampler track (`r` in the tracks view) also starts a
                    // record pass this way, regardless of view/mode -
                    // resolved now, before the count-in, so its clicks never
                    // land in the captured audio (see `tick`).
                    self.resolveArmedAudioTargets();
                    _ = self.session.engine.send(.{ .record = self.count_in_bars });
                    if (self.count_in_bars > 0) self.setStatus("count-in...", .{});
                } else {
                    const cmd: engine_mod.Command = if (snap.playing) .stop else .play;
                    _ = self.session.engine.send(cmd);
                }
            },
            .toggle_mute => {
                const track_idx = self.currentTrack();
                // currentTrack() falls back to the tracks-view cursor, which
                // can now be the master row (one past the last real track).
                if (track_idx >= self.session.project.tracks.items.len) {
                    self.setStatus("master bus has no mute", .{});
                    return;
                }
                const track = &self.session.project.tracks.items[track_idx];
                track.muted = !track.muted;
                self.dirty = true;
                _ = self.session.engine.send(.{ .set_track_mute = .{
                    .track = track_idx,
                    .muted = track.muted,
                } });
                self.setStatus("\"{s}\" {s}", .{ track.name, if (track.muted) "muted" else "unmuted" });
            },
            .toggle_solo => {
                const track_idx = self.currentTrack();
                if (track_idx >= self.session.project.tracks.items.len) {
                    self.setStatus("master bus has no solo", .{});
                    return;
                }
                const track = &self.session.project.tracks.items[track_idx];
                track.soloed = !track.soloed;
                self.dirty = true;
                _ = self.session.engine.send(.{ .set_track_solo = .{
                    .track = track_idx,
                    .soloed = track.soloed,
                } });
                self.setStatus("\"{s}\" {s}", .{ track.name, if (track.soloed) "soloed" else "unsoloed" });
            },
            .note => |n| {
                const track_idx = self.currentTrack();
                if (track_idx >= self.session.racks.items.len) return;
                switch (self.session.racks.items[track_idx].instrument) {
                    .drum_machine => {
                        _ = self.session.engine.send(.{ .note_on = .{
                            .track = track_idx,
                            .note = @intCast(n.pitch % DrumMachine.max_pads),
                            .velocity = 0.9,
                        } });
                        if (self.view == .drum_grid) drum_ed.recordNote(self, n.pitch, DrumMachine.vel_full);
                    },
                    .slicer => |*sl| if (sl.slice_count > 0) {
                        _ = self.session.engine.send(.{ .note_on = .{
                            .track = track_idx,
                            .note = n.pitch % @as(u7, @intCast(sl.slice_count)),
                            .velocity = 0.9,
                        } });
                        if (self.view == .slicer_grid) slicer_ed.recordNote(self, n.pitch, Slicer.vel_full);
                    },
                    .poly_synth, .sampler, .clap, .soundfont => {
                        self.playNote(track_idx, n.pitch, now_ns);
                        if (self.view == .piano_roll) piano_ed.recordNote(self, n.pitch, self.default_velocity);
                    },
                    .empty => {},
                }
            },
            .command_submit => |text| {
                self.pushCommandHistory(text);
                commands.run(self, text);
            },
            .search_submit => |text| {
                // Empty pattern (bare `/` + enter) repeats the last search,
                // matching vim's `//` convention.
                if (text.len > 0) self.setSearchPattern(text);
                switch (self.view) {
                    .tracks => self.searchTracks(1),
                    .file_browser => self.searchBrowser(1),
                    .help => self.searchHelp(1),
                    .arrangement => self.searchArrangement(1),
                    .synth_editor => self.searchSynthParams(1),
                    // The picker's `/` is a list filter, not a cursor jump:
                    // submitting commits the pattern (empty clears it) and
                    // rests the cursor on the narrowed list's first entry.
                    .preset_picker => {
                        const len = @min(text.len, self.preset_filter_buf.len);
                        @memcpy(self.preset_filter_buf[0..len], text[0..len]);
                        self.preset_filter_len = len;
                        self.preset_picker_cursor = 0;
                    },
                    .fx_picker => {
                        const len = @min(text.len, self.fx_picker_filter_buf.len);
                        @memcpy(self.fx_picker_filter_buf[0..len], text[0..len]);
                        self.fx_picker_filter_len = len;
                        self.fx_picker_cursor = 0;
                    },
                    .synth_fx_picker => {
                        const len = @min(text.len, self.synth_fx_picker_filter_buf.len);
                        @memcpy(self.synth_fx_picker_filter_buf[0..len], text[0..len]);
                        self.synth_fx_picker_filter_len = len;
                        self.synth_fx_picker_cursor = 0;
                    },
                    .automation_param_picker => {
                        const len = @min(text.len, self.automation_param_filter_buf.len);
                        @memcpy(self.automation_param_filter_buf[0..len], text[0..len]);
                        self.automation_param_filter_len = len;
                        self.automation_param_cursor = automation_ed.firstParamCursor(self);
                    },
                    else => self.setStatus("search not available in this view", .{}),
                }
            },
        }
    }

    /// The last submitted `/` search pattern (persists past the search
    /// itself for `n`/`N` repeat - see searchTracks/searchBrowser - and for
    /// views/browser.zig's match highlighting).
    pub fn searchPattern(self: *App) []const u8 {
        return self.search_pattern_buf[0..self.search_pattern_len];
    }

    /// Shared body of each picker's own `active*Filter` (preset picker, FX
    /// picker, synth FX picker, automation param picker): while that
    /// picker's own search mode is live, the in-progress search buffer
    /// narrows the list; otherwise the last text typed directly into the
    /// picker's filter (`buf[0..len]`) does. Kept as thin per-picker
    /// wrappers at each call site rather than calling this everywhere
    /// directly, so each one's name documents which picker it's for.
    pub fn pickerFilterText(self: *App, view: AppView, buf: []const u8, len: usize) []const u8 {
        if (self.modal.mode == .search and self.view == view)
            return self.modal.cmd_buf[0..self.modal.cmd_len];
        return buf[0..len];
    }

    fn setSearchPattern(self: *App, text: []const u8) void {
        const len = @min(text.len, self.search_pattern_buf.len);
        @memcpy(self.search_pattern_buf[0..len], text[0..len]);
        self.search_pattern_len = len;
    }

    // zig fmt: off
    /// Wrapping scan shared by the list `/` searches: visits every index
    /// once, starting one past `start` in `dir` (+1 for `n`/a fresh `/`,
    /// -1 for `N`) and wrapping around like vim's own search. `items` is
    /// anything indexable whose elements carry a `.name` field.
    fn fuzzyWrapIndex(pattern: []const u8, items: anytype, start: usize, dir: i64) ?usize {
        const n: i64 = @intCast(items.len);
        const anchor: i64 = @min(@as(i64, @intCast(start)), n - 1);
        var step: i64 = 1;
        while (step <= n) : (step += 1) {
            const idx: usize = @intCast(@mod(anchor + dir * step, n));
            if (fuzzy.matches(pattern, items[idx].name)) return idx;
        }
        return null;
    }

    /// `/` search + `n`/`N` repeat over track names. The master row has no
    /// name and is skipped - search only ever lands on a real track.
    pub fn searchTracks(self: *App, dir: i64) void {
        const pattern = self.searchPattern();
        if (pattern.len == 0) { self.setStatus("no previous search pattern", .{}); return; }
        const tracks = self.session.project.tracks.items;
        if (tracks.len == 0) { self.setStatus("no tracks to search", .{}); return; }
        const idx = fuzzyWrapIndex(pattern, tracks, self.cursor, dir) orelse {
            self.setStatus("no match for '{s}'", .{pattern});
            return;
        };
        self.cursor = idx;
        // A hit hidden inside a folded group unfolds it - vim's own
        // open-fold-on-search behaviour - so the cursor can actually
        // land on (and n can cycle past) the matching row.
        if (tracks[idx].group) |g| {
            if (g < engine_mod.max_groups) {
                if (self.session.groups[g]) |*grp| {
                    // The unfold reshapes the row list, and a hit on
                    // the cursor's own track leaves `cursor`'s value
                    // unchanged - force the re-heal explicitly.
                    if (grp.folded) { grp.folded = false; self.dirty = true; self.invalidateTrackRow(); }
                }
            }
        }
        self.setStatus("/{s}  [{d}/{d}]", .{ pattern, idx + 1, tracks.len });
    }

    /// `/` search + `n`/`N` repeat over the help view's rendered lines
    /// (ANSI-stripped), wrapping the same way `searchTracks` does. The hit
    /// line scrolls to the top of the window and stays highlighted.
    pub fn searchHelp(self: *App, dir: i64) void {
        const pattern = self.searchPattern();
        if (pattern.len == 0) { self.setStatus("no previous search pattern", .{}); return; }
        const start = self.help_search_hit orelse self.help_scroll;
        if (help.search(self.allCmds(), self.userKeymapsSlice(), pattern, start, dir)) |idx| {
            self.help_search_hit = idx;
            self.help_scroll = idx;
            self.setStatus("/{s}  [line {d}]", .{ pattern, idx + 1 });
        } else {
            self.setStatus("no match for '{s}'", .{pattern});
        }
    }

    /// `/` search + `n`/`N` repeat over the file browser's current entry
    /// list, wrapping the same way `searchTracks` does.
    pub fn searchBrowser(self: *App, dir: i64) void {
        const pattern = self.searchPattern();
        if (pattern.len == 0) { self.setStatus("no previous search pattern", .{}); return; }
        const entries = self.browser_entries.items;
        if (entries.len == 0) { self.setStatus("no entries to search", .{}); return; }
        const idx = fuzzyWrapIndex(pattern, entries, self.browser_cursor, dir) orelse {
            self.setStatus("no match for '{s}'", .{pattern});
            return;
        };
        self.browser_cursor = idx;
        self.setStatus("/{s}  [{d}/{d}]", .{ pattern, idx + 1, entries.len });
    }

    /// `/` search + `n`/`N` repeat over arrangement lane names, wrapping the
    /// same way `searchTracks` does. Lanes map 1:1 to tracks with no master
    /// row here (unlike the tracks view - see `moveLane`'s own bound), and
    /// arrangement lanes are flat regardless of tracks-view group folding,
    /// so this skips `searchTracks`' group-unfold step entirely.
    pub fn searchArrangement(self: *App, dir: i64) void {
        const pattern = self.searchPattern();
        if (pattern.len == 0) { self.setStatus("no previous search pattern", .{}); return; }
        const tracks = self.session.project.tracks.items;
        if (tracks.len == 0) { self.setStatus("no tracks to search", .{}); return; }
        const idx = fuzzyWrapIndex(pattern, tracks, self.cursor, dir) orelse {
            self.setStatus("no match for '{s}'", .{pattern});
            return;
        };
        self.cursor = idx;
        self.setStatus("/{s}  [{d}/{d}]", .{ pattern, idx + 1, tracks.len });
    }

    /// `/` search + `n`/`N` repeat over every param across all three synth
    /// subviews (`synth_ed.searchCandidates`), wrapping the same way
    /// `searchTracks` does - a hit in a different subview than the current
    /// one switches to it, matching vim's own `/` having no notion of
    /// "current pane" within one buffer.
    pub fn searchSynthParams(self: *App, dir: i64) void {
        const pattern = self.searchPattern();
        if (pattern.len == 0) { self.setStatus("no previous search pattern", .{}); return; }
        var cbuf: [synth_ed.max_search_candidates]synth_ed.SearchCandidate = undefined;
        const candidates = synth_ed.searchCandidates(self, &cbuf);
        const n: i64 = @intCast(candidates.len);
        if (n == 0) { self.setStatus("no params to search", .{}); return; }
        var start: i64 = 0;
        for (candidates, 0..) |cand, i| {
            if (cand.subview == self.synth_subview and cand.id == self.synth_cursor) {
                start = @intCast(i);
                break;
            }
        }
        var lbuf: [24]u8 = undefined;
        var step: i64 = 1;
        while (step <= n) : (step += 1) {
            const idx: usize = @intCast(@mod(start + dir * step, n));
            const cand = candidates[idx];
            if (fuzzy.matches(pattern, synth_ed.paramLabel(cand.id, &lbuf))) {
                history.flushParamNudge(self);
                self.synth_subview = cand.subview;
                self.synth_cursor = cand.id;
                synth_ed.updateScroll(self);
                self.setStatus("/{s}  [{d}/{d}]", .{ pattern, idx + 1, candidates.len });
                return;
            }
        }
        self.setStatus("no match for '{s}'", .{pattern});
    }
    // zig fmt: on

    /// Record a submitted `:` command for later up/down recall. Skips blanks
    /// and immediate repeats (shell-history convention); drops the oldest
    /// entry once at capacity. Persists the updated list to disk (best-
    /// effort - see `cmd_history_store.save`) so it survives across runs.
    fn pushCommandHistory(self: *App, text: []const u8) void {
        if (text.len == 0) return;
        if (self.cmd_history.items.len > 0 and
            std.mem.eql(u8, self.cmd_history.items[self.cmd_history.items.len - 1], text))
        {
            self.cmd_history_pos = self.cmd_history.items.len;
            return;
        }
        const owned = self.allocator.dupe(u8, text) catch return;
        if (self.cmd_history.items.len >= self.cmd_history_cap) {
            self.allocator.free(self.cmd_history.orderedRemove(0));
        }
        self.cmd_history.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return;
        };
        self.cmd_history_pos = self.cmd_history.items.len;
        cmd_history_store.save(self.allocator, self.io, self.cmd_history.items) catch {};
    }

    /// Step back to the previous history entry.
    fn commandHistoryPrev(self: *App) void {
        if (self.cmd_history.items.len == 0 or self.cmd_history_pos == 0) return;
        self.cmd_history_pos -= 1;
        self.loadCommandHistory();
    }

    /// Step forward through history; past the newest entry, blank the
    /// prompt (mirrors shell history - you're back to a fresh line).
    fn commandHistoryNext(self: *App) void {
        if (self.cmd_history_pos >= self.cmd_history.items.len) return;
        self.cmd_history_pos += 1;
        if (self.cmd_history_pos == self.cmd_history.items.len) {
            self.modal.cmd_len = 0;
        } else {
            self.loadCommandHistory();
        }
    }

    fn loadCommandHistory(self: *App) void {
        const text = self.cmd_history.items[self.cmd_history_pos];
        const len = @min(text.len, self.modal.cmd_buf.len);
        @memcpy(self.modal.cmd_buf[0..len], text[0..len]);
        self.modal.cmd_len = len;
        self.modal.cmd_cursor = len;
    }

    /// Remembers a Tab-cycle in progress: which value list was last
    /// filtered (`source`), the exact prefix it was filtered against
    /// (`stem` - the text the user actually typed, *not* whatever
    /// candidate is currently sitting in cmd_buf), where the completed
    /// value starts (`insert_at`), and the exact candidate text last
    /// written there (`last_written`, always a static string from a
    /// command/preset/kit table, so storing the slice directly rather than
    /// copying it is safe across calls). `cycleCompletion` only continues
    /// the cycle - advancing `index` and reusing `stem` - when cmd_buf
    /// still holds exactly `last_written`; any other edit (typing more,
    /// backspacing, moving to a different command) makes the next Tab
    /// press start fresh instead.
    const TabCycle = struct {
        insert_at: usize,
        stem_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined,
        stem_len: usize,
        source: Source,
        index: usize,
        last_written: []const u8,

        const Source = enum { command_name, drum_kit, synth_preset, metronome, scale, colorscheme };

        fn stem(self: *const TabCycle) []const u8 {
            return self.stem_buf[0..self.stem_len];
        }
    };

    /// Tab-completes the command name (before the first space), or - for a
    /// handful of commands whose values come from a small fixed set - the
    /// first argument token after it. Requires the cursor to be at the end
    /// of the buffer: completing a token with more already typed after it
    /// has no obvious insertion point, so mid-line Tab is a no-op.
    fn completeCommand(self: *App) void {
        const buf = self.modal.cmd_buf[0..self.modal.cmd_len];
        if (buf.len == 0 or self.modal.cmd_cursor != self.modal.cmd_len) return;

        if (std.mem.indexOfScalar(u8, buf, ' ')) |sp| {
            self.completeArgument(buf, sp);
            return;
        }

        self.suggest_popup_open = true;
        // Offer the same in-scope, mnemonic names as the popup. Compatibility
        // aliases and force variants remain dispatchable when typed in full.
        const active = commands.activeScope(self);
        var name_buf: [cmds_cap][]const u8 = undefined;
        var n: usize = 0;
        for (self.allCmds()) |c| {
            if (cmd_mod.hiddenFromCompletion(c) or !cmd_mod.visible(c, active)) continue;
            name_buf[n] = c.name;
            n += 1;
        }
        self.cycleCompletion(0, buf, .command_name, name_buf[0..n]);
    }

    /// Tab-completes the argument after `buf[0..name_end]` against a small
    /// fixed value set - drum-kit/synth-preset names, and metronome's
    /// on/off keywords. Only fires for the
    /// *first* argument token (a trailing space means a second argument is
    /// being typed, which has no fixed candidate list here); every other
    /// command's arguments (track numbers, dB values, paths, ...) aren't
    /// completable from a fixed list, so this is a no-op for those.
    fn completeArgument(self: *App, buf: []const u8, name_end: usize) void {
        const name = buf[0..name_end];
        const arg = buf[name_end + 1 ..];
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) return;

        var name_buf: [96][]const u8 = undefined;
        if (std.mem.eql(u8, name, "drum-kit")) {
            var n: usize = 0;
            for (ws.dsp.drum_kit.variants) |v| {
                name_buf[n] = v.name;
                n += 1;
            }
            self.cycleCompletion(name_end + 1, arg, .drum_kit, name_buf[0..n]);
        } else if (std.mem.eql(u8, name, "synth-preset")) {
            var n: usize = 0;
            for (self.user_synth_presets.items) |p| {
                if (n >= name_buf.len) break;
                name_buf[n] = p.name;
                n += 1;
            }
            for (ws.dsp.synth_presets.presets) |p| {
                if (n >= name_buf.len) break;
                name_buf[n] = p.name;
                n += 1;
            }
            self.cycleCompletion(name_end + 1, arg, .synth_preset, name_buf[0..n]);
        } else if (std.mem.eql(u8, name, "metronome")) {
            self.cycleCompletion(name_end + 1, arg, .metronome, &.{ "on", "off" });
        } else if (std.mem.eql(u8, name, "scale")) {
            // First token can be "off", a root pitch class, or a scale-type
            // name (cmdScale accepts either order) - offer all three sets.
            var n: usize = 0;
            name_buf[n] = "off";
            n += 1;
            for (0..12) |pc| {
                name_buf[n] = ws.theory.pitchClassName(@intCast(pc));
                n += 1;
            }
            for (std.meta.tags(ws.theory.ScaleType)) |t| {
                name_buf[n] = t.label();
                n += 1;
            }
            self.cycleCompletion(name_end + 1, arg, .scale, name_buf[0..n]);
        } else if (std.mem.eql(u8, name, "colorscheme") or std.mem.eql(u8, name, "colo")) {
            // TUI also offers "none" (turns the terminal-palette theme back
            // off); the GUI panel skin has no such state.
            const frontend: config_mod.Frontend = if (self.lua_runtime) |rt| rt.frontend else .tui;
            var n: usize = 0;
            if (frontend == .tui) {
                name_buf[n] = "none";
                n += 1;
            }
            for (std.meta.tags(ws.theme_identity.Name)) |t| {
                name_buf[n] = @tagName(t);
                n += 1;
            }
            self.cycleCompletion(name_end + 1, arg, .colorscheme, name_buf[0..n]);
        }
    }

    /// Shared by `completeCommand`/`completeArgument`. `current_text` is
    /// whatever `values`-completable text is in cmd_buf right now (may
    /// already be a candidate from a previous cycle step, not necessarily
    /// what the user typed). If it matches an in-progress cycle's
    /// `last_written` exactly, we're continuing that cycle: keep filtering
    /// on its original `stem` and advance to the next candidate. Otherwise
    /// `current_text` itself is treated as a fresh stem (typing, deleting,
    /// or switching commands all fail that check, so the next Tab starts
    /// over - no separate reset wiring needed). A single match always
    /// completes in full plus a trailing space, cycle or not.
    fn cycleCompletion(self: *App, insert_at: usize, current_text: []const u8, source: TabCycle.Source, values: []const []const u8) void {
        var stem_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined;
        var stem: []const u8 = undefined;
        var prev_index: ?usize = null;

        if (self.tab_cycle) |tc| {
            if (tc.insert_at == insert_at and tc.source == source and std.mem.eql(u8, tc.last_written, current_text)) {
                prev_index = tc.index;
                @memcpy(stem_buf[0..tc.stem_len], tc.stem());
                stem = stem_buf[0..tc.stem_len];
            }
        }
        if (prev_index == null) {
            // Fresh stem - snapshot `current_text` before cmd_buf gets
            // overwritten below (it may alias cmd_buf directly).
            const len = @min(current_text.len, stem_buf.len);
            @memcpy(stem_buf[0..len], current_text[0..len]);
            stem = stem_buf[0..len];
        }

        var match_idx: [64]usize = undefined;
        var match_count: usize = 0;
        for (values, 0..) |v, i| {
            if (!std.mem.startsWith(u8, v, stem)) continue;
            if (match_count < match_idx.len) match_idx[match_count] = i;
            match_count += 1;
        }
        if (match_count == 0) return;

        if (match_count == 1) {
            self.tab_cycle = null;
            const candidate = values[match_idx[0]];
            const new_end = insert_at + candidate.len;
            if (new_end > self.modal.cmd_buf.len) return;
            @memcpy(self.modal.cmd_buf[insert_at..new_end], candidate);
            self.modal.cmd_len = new_end;
            self.modal.cmd_cursor = new_end;
            if (self.modal.cmd_len < self.modal.cmd_buf.len) {
                self.modal.cmd_buf[self.modal.cmd_len] = ' ';
                self.modal.cmd_len += 1;
                self.modal.cmd_cursor += 1;
            }
            return;
        }

        const index = if (prev_index) |pi| (pi + 1) % match_count else 0;
        const candidate = values[match_idx[index]];
        const new_end = insert_at + candidate.len;
        if (new_end > self.modal.cmd_buf.len) return;
        @memcpy(self.modal.cmd_buf[insert_at..new_end], candidate);
        self.modal.cmd_len = new_end;
        self.modal.cmd_cursor = new_end;

        var tc: TabCycle = .{ .insert_at = insert_at, .stem_len = stem.len, .source = source, .index = index, .last_written = candidate };
        @memcpy(tc.stem_buf[0..stem.len], stem);
        self.tab_cycle = tc;
    }

    /// The in-progress command-name Tab-cycle, but only if `cmd_buf` still
    /// holds exactly what that cycle last wrote there (same check
    /// `cycleCompletion` uses to decide whether to continue a cycle vs.
    /// start fresh) - shared by `suggestionSelected`/`suggestionFilterText`.
    /// Returns a pointer into `self.tab_cycle` (not a copy) since
    /// `suggestionFilterText` hands back a slice borrowed from `stem_buf`
    /// that needs to outlive this call.
    fn activeCommandCycle(self: *const App) ?*const TabCycle {
        if (self.tab_cycle) |*tc| {
            if (tc.insert_at == 0 and tc.source == .command_name and
                std.mem.eql(u8, tc.last_written, self.modal.cmd_buf[0..self.modal.cmd_len]))
            {
                return tc;
            }
        }
        return null;
    }

    /// Which match `draw`'s command-name suggestion popup should highlight:
    /// otherwise 0 - the top match, matching Neovim's wildmenu highlighting
    /// the first candidate before Tab has ever been pressed.
    ///
    /// Re-derive the position from the popup's filtered enumeration rather
    /// than coupling rendering to the completion cycle's internal index.
    pub fn suggestionSelected(self: *const App, active: cmd_mod.Scope) usize {
        const tc = self.activeCommandCycle() orelse return 0;
        var idx: usize = 0;
        for (self.allCmds()) |c| {
            if (cmd_mod.hiddenFromCompletion(c) or !cmd_mod.visible(c, active)) continue;
            if (!std.mem.startsWith(u8, c.name, tc.stem())) continue;
            if (std.mem.eql(u8, c.name, tc.last_written)) return idx;
            idx += 1;
        }
        // The completed candidate is itself hidden from the popup (an
        // alias or bang variant) - nothing in the visible list corresponds
        // to it, so fall back to the top row rather than an index that
        // would highlight an unrelated candidate.
        return 0;
    }

    /// Text `draw`'s suggestion popup filters candidates against. Tab
    /// completion overwrites `cmd_buf` with the candidate name itself (so
    /// the buffer is always a valid, submittable command) - filtering the
    /// popup on that literal text would collapse it to a single match the
    /// instant Tab landed on any candidate, hiding the very list Tab was
    /// supposed to reveal. While a cycle is active, filter on its
    /// `stem` (what was actually typed) instead; only fall back to the
    /// live buffer when there's no cycle to track (plain typing).
    pub fn suggestionFilterText(self: *const App) []const u8 {
        if (self.activeCommandCycle()) |tc| return tc.stem();
        return self.modal.cmd_buf[0..self.modal.cmd_len];
    }

    /// Fire a preview note and schedule its release `note_preview_ns` later
    /// (see `tick`). Pub for the editor modules' audition keys.
    pub fn playNote(self: *App, track: u16, pitch: u7, now_ns: i96) void {
        _ = self.session.engine.send(.{ .note_on = .{ .track = track, .note = pitch, .velocity = self.default_velocity } });
        if (self.note_off_len == self.note_offs.len) {
            const oldest = self.note_offs[0];
            _ = self.session.engine.send(.{ .note_off = .{ .track = oldest.track, .note = oldest.note } });
            std.mem.copyForwards(NoteOff, self.note_offs[0 .. self.note_off_len - 1], self.note_offs[1..self.note_off_len]);
            self.note_off_len -= 1;
        }
        self.note_offs[self.note_off_len] = .{
            .at_ns = now_ns + self.note_preview_ns,
            .track = track,
            .note = pitch,
        };
        self.note_off_len += 1;
    }

    pub fn tick(self: *App, now_ns: i96) void {
        // `setStatus` can't stamp an absolute deadline (see `status_pending`'s
        // doc comment); do it here, on the first tick after it fired.
        if (self.status_pending) {
            self.status_expire_ns = now_ns + self.status_message_ns;
            self.status_pending = false;
        }
        if (self.status_expire_ns != 0 and now_ns >= self.status_expire_ns) {
            self.status_len = 0;
            self.status_expire_ns = 0;
        }
        var i: usize = 0;
        while (i < self.note_off_len) {
            const off = self.note_offs[i];
            if (off.at_ns <= now_ns) {
                _ = self.session.engine.send(.{ .note_off = .{ .track = off.track, .note = off.note } });
                std.mem.copyForwards(NoteOff, self.note_offs[i .. self.note_off_len - 1], self.note_offs[i + 1 .. self.note_off_len]);
                self.note_off_len -= 1;
            } else {
                i += 1;
            }
        }
        self.maybeAutosave(now_ns);

        // Frame-boundary Lua event watchers - see the `last_view` field doc.
        if (self.view != self.last_view) {
            const prev = self.last_view;
            self.last_view = self.view;
            self.emitEvent(.{ .ViewEnter = .{ .view = @tagName(self.view), .prev = @tagName(prev) } });
        }
        const playing = self.session.engine.uiSnapshot().playing;
        const was_playing = self.last_playing;
        if (playing != self.last_playing) {
            self.last_playing = playing;
            const tempo = self.session.project.tempo_bpm;
            self.emitEvent(if (playing) .{ .PlaybackStart = .{ .tempo = tempo } } else .{ .PlaybackStop = .{ .tempo = tempo } });
        }
        // Audio-input recording: a count-in's pre-roll must never land in
        // the captured take, so capture only starts on the exact frame
        // playback goes live, not when `.record` was sent (see
        // `resolveArmedAudioTargets`/`toggle_play`). Symmetric on the other
        // edge: the pass ends the instant playback stops.
        if (playing and !was_playing) self.startPendingRecording();
        if (self.recording_active_len > 0) self.drainRecording();
        if (!playing and was_playing) self.finishRecording();
    }

    /// Every `autosave_interval_ns`, if there are unsaved changes, silently
    /// write a `<path>~` backup - a safety net, not a real save: it doesn't
    /// clear `dirty` or touch the primary file, so `:q` still guards the
    /// actual edits. A brand-new project with no path yet backs up next to
    /// `:w`'s own default target (see backupPath). Failures are silent
    /// (best-effort); a status message every 30s would just be noise during
    /// active work.
    fn maybeAutosave(self: *App, now_ns: i96) void {
        if (self.autosave_interval_ns == 0) return; // autosave_interval_s = 0 disables
        if (!self.dirty) return;
        if (now_ns - self.last_autosave_ns < self.autosave_interval_ns) return;
        self.last_autosave_ns = now_ns;
        self.writeBackup();
    }

    /// Write the `<path>~` backup right now - maybeAutosave's write, also
    /// called directly on a dirty ctrl-c so an instant exit can't outrun
    /// the 30s cadence.
    fn writeBackup(self: *App) void {
        var buf: [reload_path_buf_len]u8 = undefined;
        const backup = self.backupPath(&buf) orelse return;
        ws.persist.save(self.allocator, &self.session, self.io, backup) catch {};
    }

    /// Startup recovery: maybeAutosave/ctrl-c leave `<path>~` behind on a
    /// crash or kill - offer it back rather than letting it sit invisible
    /// (the file browser filters to `.wsj`) until someone types the path by
    /// hand. Only when it's newer than the project file itself (or that
    /// file doesn't exist at all); an older backup is just stale.
    pub fn promptIfBackupNewer(self: *App, path: []const u8) void {
        var backup_buf: [reload_path_buf_len]u8 = undefined;
        const backup = std.fmt.bufPrint(&backup_buf, "{s}~", .{path}) catch return;
        const backup_stat = std.Io.Dir.cwd().statFile(self.io, backup, .{}) catch return;
        const project_stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch null;
        if (project_stat) |ps| {
            if (backup_stat.mtime.nanoseconds <= ps.mtime.nanoseconds) return;
            self.setStatus("autosave backup found, newer than '{s}' - :restore-backup to load it", .{path});
        } else {
            self.setStatus("autosave backup '{s}' found - :restore-backup to load it", .{backup});
        }
    }

    // -----------------------------------------------------------------------
    // Track add / delete internals
    // -----------------------------------------------------------------------

    /// Where a new track lands: right after the currently selected track,
    /// or - on a folded group row - right after that group's last member,
    /// so the new track shows up next to the group instead of jumping to
    /// the very bottom. The master row and any view outside `.tracks` (e.g.
    /// `:track-add` run from the synth editor) fall back to `self.cursor`,
    /// which every view keeps pointed at "the" current track; past the
    /// last real track (the master sentinel) that means append at the end.
    /// Re-syncs the row cursor itself rather than trusting the caller to
    /// have done it - same "call before any row-cursor read" rule
    /// `tracksRowSync`'s own doc comment gives.
    fn trackAddInsertIndex(self: *App) u16 {
        const total: u16 = @intCast(self.session.project.tracks.items.len);
        if (self.view == .tracks) {
            self.tracksRowSync();
            if (self.cursorGroup()) |g| {
                var last: ?u16 = null;
                for (self.session.project.tracks.items, 0..) |t, i| {
                    if (t.group == g) last = @intCast(i);
                }
                return if (last) |l| l + 1 else total;
            }
            if (self.cursorTrack()) |t| return t + 1;
            return total;
        }
        if (self.cursor < total) return @as(u16, @intCast(self.cursor)) + 1;
        return total;
    }

    // zig fmt: off
    /// Shift every editor-target/pending-state track index that sits at or
    /// past `idx` up by one, mirroring a track showing up at `idx` (insert,
    /// or undo restoring a deleted track back to its old slot). Nothing is
    /// ever dropped here - an insert can't invalidate a track. Shared by
    /// `doTrackAdd` and history's track-restore apply so the field
    /// checklist can't drift between the two call sites - see
    /// project_bug_hunt_2026_07_11's "any NEW field... must join this list".
    pub fn shiftFieldsForInsert(self: *App, idx: usize) void {
        // A field bounced to the invalid sentinel by shiftFieldsForDelete
        // stays there - it names no track at all, so there's nothing for
        // an insert to shift, and incrementing the sentinel would overflow.
        const shiftIfValid = struct {
            fn f(field: *u16, ins_idx: usize) void {
                if (field.* != std.math.maxInt(u16) and field.* >= ins_idx) field.* += 1;
            }
        }.f;
        shiftIfValid(&self.synth_track, idx);
        shiftIfValid(&self.drum_track, idx);
        shiftIfValid(&self.piano_track, idx);
        shiftIfValid(&self.eq_track, idx);
        shiftIfValid(&self.slicer_track, idx);
        shiftIfValid(&self.automation_track, idx);
        shiftIfValid(&self.preset_picker_track, idx);
        shiftIfValid(&self.soundfont_track, idx);
        switch (self.sampler_target) {
            .drum => |*t| shiftIfValid(t, idx),
            .sampler => |*t| shiftIfValid(t, idx),
            .slice => |*t| shiftIfValid(t, idx),
        }
        if (self.piano_clip_link) |*link| {
            if (link.track >= idx) link.track += 1;
        }
        if (self.automation_clip) |*link| {
            if (link.track >= idx) link.track += 1;
        }
        for (self.note_offs[0..self.note_off_len]) |*off| {
            if (off.track >= idx) off.track += 1;
        }
    }

    /// Shift/drop every editor-target/pending-state track index for a track
    /// removed at `idx` - the mirror of `shiftFieldsForInsert`. Shared by
    /// `doTrackDel` and history's track-delete-redo apply.
    pub fn shiftFieldsForDelete(self: *App, idx: usize) void {
        // A field naming the deleted track exactly must not merely survive
        // unshifted - the slot it names gets reused by whatever track
        // shifts down into it, so leaving the old value in place would
        // silently rebind the field (and any open editor keyed on it) to
        // that unrelated track. Bounce it out of range instead, so the
        // kindIs()/`>= racks.len` checks in exitStaleEditors always treat
        // it as gone, regardless of what the reused slot now holds.
        const shiftOrInvalidate = struct {
            fn f(field: *u16, del_idx: usize) void {
                if (field.* == del_idx) {
                    field.* = std.math.maxInt(u16);
                } else if (del_idx < field.* and field.* > 0) {
                    field.* -= 1;
                }
            }
        }.f;
        shiftOrInvalidate(&self.synth_track, idx);
        shiftOrInvalidate(&self.drum_track, idx);
        shiftOrInvalidate(&self.piano_track, idx);
        shiftOrInvalidate(&self.eq_track, idx);
        shiftOrInvalidate(&self.slicer_track, idx);
        shiftOrInvalidate(&self.automation_track, idx);
        shiftOrInvalidate(&self.preset_picker_track, idx);
        shiftOrInvalidate(&self.soundfont_track, idx);
        if (self.piano_clip_link) |link| {
            if (link.track == idx) {
                self.piano_clip_link = null;
            } else if (link.track > idx) {
                self.piano_clip_link.?.track -= 1;
            }
        }
        if (self.automation_clip) |link| {
            if (link.track == idx) {
                self.automation_clip = null;
            } else if (link.track > idx) {
                self.automation_clip.?.track -= 1;
            }
        }
        // Pending qwerty note-offs name tracks too: drop the deleted
        // track's (its rack is being retired anyway), shift the rest, so a
        // note that outlives the delete is stopped on the track it's
        // actually still sounding on.
        var no_i: usize = 0;
        while (no_i < self.note_off_len) {
            const t = self.note_offs[no_i].track;
            if (t == idx) {
                std.mem.copyForwards(NoteOff, self.note_offs[no_i .. self.note_off_len - 1], self.note_offs[no_i + 1 .. self.note_off_len]);
                self.note_off_len -= 1;
            } else {
                if (t > idx) self.note_offs[no_i].track -= 1;
                no_i += 1;
            }
        }
        switch (self.sampler_target) {
            .drum    => |*t| shiftOrInvalidate(t, idx),
            .sampler => |*t| shiftOrInvalidate(t, idx),
            .slice   => |*t| shiftOrInvalidate(t, idx),
        }
    }
    // zig fmt: on

    pub fn doTrackAdd(self: *App, name_arg: ?[]const u8) void {
        const at = self.trackAddInsertIndex();
        const name: []const u8 = name_arg orelse "untitled track";

        const idx = self.session.insertTrack(at, name) catch |err| {
            if (err == error.TrackLimitReached)
                self.setStatus("track limit reached", .{})
            else
                self.setStatus("out of memory", .{});
            return;
        };

        self.shiftFieldsForInsert(idx);

        const remap: undo_mod.TrackRemap = .{ .insert = idx };
        history.retargetPending(self, remap);
        _ = self.history.retarget(self.allocator, remap);

        self.cursor = idx;
        self.invalidateTrackRow();
        self.dirty = true;
        self.setStatus("added \"{s}\" (track {d})", .{ name, idx + 1 });
        self.emitEvent(.{ .TrackAdd = .{ .track = idx + 1 } });
    }

    pub fn doTrackDel(self: *App, track_idx: usize) void {
        // Capture the whole track BEFORE it's gone, so this delete becomes
        // its own undo step (undo re-inserts it exactly as it was) - on top
        // of (not instead of) the existing remap/drop below, which still
        // clears out-of-date fine-grained edit history that named this
        // track, since restoring from this snapshot supersedes it anyway.
        var backup = history.captureTrackFull(self, track_idx);

        self.session.deleteTrack(track_idx) catch {
            self.setStatus("cannot delete the last track", .{});
            if (backup) |*b| b.deinit(self.allocator);
            return;
        };

        self.shiftFieldsForDelete(track_idx);

        // Track indices shift below the deleted track: remap every undo/
        // redo entry (and any still-open nudge batch) to keep pointing at
        // the same physical track, dropping only entries that named the
        // deleted track itself. Must run BEFORE pushing `backup` below, or
        // this exact-match delete remap would immediately drop the entry
        // that restores the very track it names.
        const remap: undo_mod.TrackRemap = .{ .delete = @intCast(track_idx) };
        history.retargetPending(self, remap);
        const dropped = self.history.retarget(self.allocator, remap);

        // Keep cursor in bounds. The row list can reshape even when the
        // cursor's value survives unchanged, so force a row-cursor re-heal.
        const last = self.session.project.tracks.items.len - 1;
        self.cursor = @min(self.cursor, last);
        self.invalidateTrackRow();

        // Exit any editor whose target track no longer holds the expected kind.
        self.exitStaleEditors();

        if (backup) |b| history.push(self, .{ .track_insert = b });

        self.dirty = true;
        if (dropped > 0) {
            self.setStatus("deleted track {d} ({d} undo entries for it cleared)", .{ track_idx + 1, dropped });
        } else {
            self.setStatus("deleted track {d}", .{track_idx + 1});
        }
        self.emitEvent(.{ .TrackDel = .{ .track = track_idx + 1 } });
    }

    /// After a structural change (delete), bail out of any per-instrument editor
    /// whose target track is gone or holds a different instrument.
    pub fn exitStaleEditors(self: *App) void {
        const racks = self.session.racks.items;
        const kindIs = struct {
            fn f(rs: []const *@import("wstudio").Rack, t: u16, comptime tag: anytype) bool {
                return t < rs.len and std.meta.activeTag(rs[t].instrument) == tag;
            }
        }.f;

        // zig fmt: off
        switch (self.view) {
            .synth_editor, .synth_fx_picker => if (!kindIs(racks, self.synth_track, .poly_synth)) { self.view = .tracks; },
            .drum_grid => if (!kindIs(racks, self.drum_track, .drum_machine)) { self.view = .tracks; },
            .slicer_grid => if (!kindIs(racks, self.slicer_track, .slicer)) { self.view = .tracks; },
            .sampler_editor => {
                const ok = switch (self.sampler_target) {
                    .drum => |t| kindIs(racks, t, .drum_machine),
                    .sampler => |t| kindIs(racks, t, .sampler),
                    .slice => |t| kindIs(racks, t, .slicer),
                };
                if (!ok) self.view = .tracks;
            },
            .piano_roll => if (self.piano_track >= racks.len or
                switch (racks[self.piano_track].instrument) { .poly_synth, .sampler, .soundfont => false, else => true })
            {
                self.view = .tracks;
            },
            .soundfont_editor => if (!kindIs(racks, self.soundfont_track, .soundfont)) { self.view = .tracks; },
            .track_spectrum => if (self.eq_track >= racks.len) {
                _ = self.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
                self.view = self.prev_view;
            },
            // A deleted group's chain view can't linger either - same
            // bounce-out shape .track_spectrum uses for a deleted track.
            .group_spectrum => if (self.eq_group >= engine_mod.max_groups or self.session.groups[self.eq_group] == null) {
                _ = self.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
                self.view = self.prev_view;
            },
            // The picker inserts into eq_track's/eq_group's chain on accept -
            // if that target vanished, retreat all the way to tracks rather
            // than into a chain view whose target is gone.
            .fx_picker => if ((self.fx_picker_return == .track_spectrum and self.eq_track >= racks.len) or
                (self.fx_picker_return == .group_spectrum and
                    (self.eq_group >= engine_mod.max_groups or self.session.groups[self.eq_group] == null)))
            {
                self.view = .tracks;
            },
            .automation, .automation_param_picker => if (automation_ed.currentClip(self) == null) { self.view = .arrangement; },
            // Accepting applies to preset_picker_track - if that track
            // vanished or changed kind, retreat to tracks rather than back
            // into an editor whose target is gone.
            .preset_picker => {
                const ok = switch (self.preset_picker_kind) {
                    .synth => kindIs(racks, self.preset_picker_track, .poly_synth),
                    .drum => kindIs(racks, self.preset_picker_track, .drum_machine),
                    .soundfont => kindIs(racks, self.preset_picker_track, .soundfont),
                };
                if (!ok) self.view = .tracks;
            },
            else => {},
        }
    }
    // zig fmt: on

    /// Deep-copy the track under the cursor into a new track appended at the
    /// end (see Session.duplicateTrack) and jump the cursor to it. Appending
    /// means no existing track's index shifts, so unlike delete this never
    /// needs to touch history or editor-target indices.
    pub fn doTrackDup(self: *App, track_idx: usize) void {
        const idx = self.session.duplicateTrack(track_idx) catch |err| {
            if (err == error.TrackLimitReached)
                self.setStatus("track limit reached", .{})
            else
                self.setStatus("out of memory", .{});
            return;
        };
        self.cursor = idx;
        self.dirty = true;
        self.setStatus("duplicated track {d} -> {d}", .{ track_idx + 1, idx + 1 });
        self.emitEvent(.{ .TrackAdd = .{ .track = idx + 1 } });
    }

    /// Swap the cursor's track with its neighbor (`dir` < 0 = up, > 0 =
    /// down) and follow the cursor along. A swap silently changes what
    /// absolute index every per-instrument editor target and undo entry
    /// refers to, so remap the former and - same call as doTrackDel - drop
    /// the latter rather than risk restoring content into the wrong track.
    pub fn doTrackMove(self: *App, dir: i32) void {
        const len = self.session.project.tracks.items.len;
        if (len < 2) return;
        const cur = self.cursor;
        const other: usize = if (dir < 0)
            (if (cur == 0) return else cur - 1)
        else
            (if (cur + 1 >= len) return else cur + 1);

        self.session.swapTracks(cur, other);

        // zig fmt: off
        const swap = struct {
            fn f(idx: *u16, a: usize, b: usize) void {
                if (idx.* == a) idx.* = @intCast(b) else if (idx.* == b) idx.* = @intCast(a);
            }
        }.f;
        swap(&self.synth_track, cur, other);
        swap(&self.drum_track, cur, other);
        swap(&self.piano_track, cur, other);
        swap(&self.eq_track, cur, other);
        swap(&self.slicer_track, cur, other);
        swap(&self.automation_track, cur, other);
        swap(&self.preset_picker_track, cur, other);
        swap(&self.soundfont_track, cur, other);
        switch (self.sampler_target) {
            .drum => |*t| swap(t, cur, other),
            .sampler => |*t| swap(t, cur, other),
            .slice => |*t| swap(t, cur, other),
        }
        if (self.piano_clip_link) |*link| {
            if (link.track == cur) link.track = @intCast(other)
            else if (link.track == other) link.track = @intCast(cur);
        }
        if (self.automation_clip) |*link| {
            if (link.track == cur) link.track = @intCast(other)
            else if (link.track == other) link.track = @intCast(cur);
        }
        for (self.note_offs[0..self.note_off_len]) |*off| swap(&off.track, cur, other);
        // A swap never removes a track, so unlike delete this never drops
        // an entry - every index just exchanges with its neighbor's.
        const remap: undo_mod.TrackRemap = .{ .swap = .{ .a = @intCast(cur), .b = @intCast(other) } };
        history.retargetPending(self, remap);
        _ = self.history.retarget(self.allocator, remap);
        // zig fmt: on

        self.cursor = other;
        self.dirty = true;
        self.setStatus("moved track {d} {s}", .{ cur + 1, if (dir < 0) "up" else "down" });
    }

    /// `[`/`]` in the tracks view: cycle the cursor track's color through
    /// `ansi.track_palette`, wrapping through 0 ("none") on both ends -
    /// same cycling shape as the drum grid's variant `[`/`]`. Not
    /// undo-tracked, matching mute/solo/gain/pan (mixer-style live state,
    /// not pattern content).
    pub fn doTrackColorCycle(self: *App, dir: i32) void {
        if (self.cursor >= self.session.project.tracks.items.len) return;
        const track = &self.session.project.tracks.items[self.cursor];
        const n: i32 = @intCast(ansi.track_palette.len + 1); // +1 for "none"
        const cur: i32 = @intCast(track.color);
        track.color = @intCast(@mod(cur + dir, n));
        self.dirty = true;
        if (track.color == 0) {
            self.setStatus("track {d} color: none", .{self.cursor + 1});
        } else {
            self.setStatus("track {d} color: {s}", .{ self.cursor + 1, ansi.track_color_names[track.color - 1] });
        }
    }

    // zig fmt: off
    fn doTrackPan(self: *App, track: u16, delta: f32) void {
        if (track >= self.session.project.tracks.items.len) return;
        const t = &self.session.project.tracks.items[track];
        t.pan = std.math.clamp(t.pan + delta, -1.0, 1.0);
        self.dirty = true;
        _ = self.session.engine.send(.{ .set_track_pan = .{ .track = track, .pan = t.pan } });
        const pct: i32 = @intFromFloat(@abs(t.pan) * 100.0);
        if (pct == 0) self.setStatus("track {d} pan: center", .{track + 1})
        else if (t.pan < 0) self.setStatus("track {d} pan: L{d}%", .{ track + 1, pct })
        else self.setStatus("track {d} pan: R{d}%", .{ track + 1, pct });
    }
    // zig fmt: on

    fn doTrackGainStep(self: *App, track: u16, delta_db: f32) void {
        if (track >= self.session.project.tracks.items.len) return;
        const t = &self.session.project.tracks.items[track];
        t.gain_db = std.math.clamp(t.gain_db + delta_db, -60.0, 12.0);
        self.dirty = true;
        _ = self.session.engine.send(.{ .set_track_gain = .{ .track = track, .gain = types.dbToGain(t.gain_db) } });
        const sign: []const u8 = if (t.gain_db >= 0) "+" else "";
        self.setStatus("track {d} gain: {s}{d:.1}dB", .{ track + 1, sign, t.gain_db });
    }

    /// `-`/`+` on the master row - same gesture as a track's gain step, but
    /// against `master_gain_db` (same range/behaviour as `:vol`/`[`/`]`).
    fn doMasterGainStep(self: *App, delta_db: f32) void {
        self.master_gain_db = std.math.clamp(self.master_gain_db + delta_db, -40.0, 6.0);
        _ = self.session.engine.send(.{ .set_master_gain = types.dbToGain(self.master_gain_db) });
        const sign: []const u8 = if (self.master_gain_db >= 0) "+" else "";
        self.setStatus("master gain: {s}{d:.1}dB", .{ sign, self.master_gain_db });
    }

    // -----------------------------------------------------------------------
    // Command handlers
    // -----------------------------------------------------------------------

    /// The remembered project file path, or null when nothing was loaded or
    /// saved yet (`:w` then falls back to "project.wsj").
    pub fn projectPath(self: *const App) ?[]const u8 {
        return if (self.project_path_len > 0) self.project_path_buf[0..self.project_path_len] else null;
    }

    pub fn defaultProjectPath(self: *const App) []const u8 {
        return self.default_project_path.slice();
    }

    pub fn setProjectPath(self: *App, path: []const u8) void {
        const len = @min(path.len, self.project_path_buf.len);
        @memcpy(self.project_path_buf[0..len], path[0..len]);
        self.project_path_len = len;
    }

    pub fn clearProjectPath(self: *App) void {
        self.project_path_len = 0;
    }

    /// Reset every piece of App state that describes or snapshots the old
    /// session, right after `run()` swapped in a new one (`:e`/`:new`/
    /// `:restore-backup`). Undo entries, pending nudge batches, and note-offs
    /// hold old-session content or track indices; editor views and targets
    /// may point past the new track list or at a different instrument kind.
    /// The doTrackDel-time remaps/guards never see any of this because the
    /// whole session changed at once. Both frontends call this after
    /// `app.session = loaded`. `last_view` deliberately stays: the next
    /// tick() then emits ViewEnter for the forced jump to `.tracks`.
    pub fn resetForNewSession(self: *App) void {
        // A project swap mid-record-pass (rare, but `:e`/`:w new` etc. don't
        // guard against it) would otherwise leave the capture device open
        // and stamp onto tracks that no longer exist.
        if (self.audio_input.active != .none) self.audio_input.stop();
        self.recording_pending_len = 0;
        self.recording_active_len = 0;
        self.recording_accum.clearRetainingCapacity();
        self.history.clear(self.allocator);
        self.pending_param_nudge = null;
        if (self.pending_fx_nudge) |*p| p.deinit(self.allocator);
        self.pending_fx_nudge = null;
        self.note_off_len = 0;
        self.piano_clip_link = null;
        self.automation_clip = null;
        if (self.modal.mode != .normal) _ = self.modal.setMode(.normal);
        self.view = .tracks;
        self.prev_view = .tracks;
        self.cursor = 0;
        self.invalidateTrackRow();
        self.synth_track = 0;
        self.drum_track = 0;
        self.piano_track = 0;
        self.eq_track = 0;
        self.slicer_track = 0;
        self.automation_track = 0;
        self.preset_picker_track = 0;
        self.sampler_target = .{ .drum = 0 };
    }

    /// Ask `run()` to load `path` (or start a blank session when null) on
    /// its next loop iteration - see the field doc on `pending_reload`.
    pub fn requestReload(self: *App, path: ?[]const u8) void {
        if (path) |p| {
            const len = @min(p.len, self.pending_reload_buf.len);
            @memcpy(self.pending_reload_buf[0..len], p[0..len]);
            self.pending_reload_len = len;
            self.pending_reload = .load;
        } else {
            self.pending_reload = .blank;
        }
    }

    pub fn pendingReloadPath(self: *const App) []const u8 {
        return self.pending_reload_buf[0..self.pending_reload_len];
    }

    /// `:restore-backup` - load `backup_path` (the `<project>~` autosave)
    /// on the next loop iteration, same swap mechanism as `:e`, but the
    /// project path stays the original file: the backup's content is newer
    /// than what's on disk, not a different project, so it lands `dirty`
    /// rather than re-pointing `:w`'s default target.
    pub fn requestRestoreBackup(self: *App, backup_path: []const u8) void {
        const len = @min(backup_path.len, self.pending_reload_buf.len);
        @memcpy(self.pending_reload_buf[0..len], backup_path[0..len]);
        self.pending_reload_len = len;
        self.pending_reload = .restore_backup;
    }

    /// `<path>~` - shared by the autosave writer, the startup recovery
    /// check, `:restore-backup`, and the post-save/quit cleanup. A project
    /// with no path yet falls back to `:w`'s own default save target, so a
    /// never-saved session still gets the full autosave/restore cycle
    /// instead of no safety net at all.
    fn backupPath(self: *const App, buf: []u8) ?[]const u8 {
        const path = self.projectPath() orelse self.defaultProjectPath();
        return std.fmt.bufPrint(buf, "{s}~", .{path}) catch null;
    }

    /// Delete the `<path>~` autosave backup now that it's stale: either its
    /// content just got saved for real, or the session cleanly matched disk
    /// already. Best-effort - a missing or unremovable backup is a no-op.
    pub fn deleteBackupIfPresent(self: *App) void {
        var buf: [reload_path_buf_len]u8 = undefined;
        const backup = self.backupPath(&buf) orelse return;
        std.Io.Dir.cwd().deleteFile(self.io, backup) catch {};
    }

    pub fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.status_buf, fmt, args) catch &self.status_buf;
        self.status_len = msg.len;
        self.status_pending = true;
    }
};

// zig fmt: off
/// Per-slot trampolines bridging `cmd.Def.run`'s context-free signature to
/// `Runtime.runUserCommand(index, ...)` - a Def can't carry which Lua
/// handler it belongs to, so the slot index is baked in at comptime.
const user_cmd_runners: [config_mod.max_user_cmds]*const fn (*anyopaque, []const u8) void = blk: {
    var fns: [config_mod.max_user_cmds]*const fn (*anyopaque, []const u8) void = undefined;
    for (0..config_mod.max_user_cmds) |i| fns[i] = userCmdRunner(i);
    break :blk fns;
};

/// Lua-facing instrument kind names - the same ones `cmd.Scope` and the
/// design doc use ("synth" not "poly_synth", "drum" not "drum_machine").
pub fn apiKindName(kind: ws.InstrumentKind) []const u8 {
    return switch (kind) {
        .empty => "empty",
        .poly_synth => "synth",
        .sampler => "sampler",
        .drum_machine => "drum",
        .slicer => "slicer",
        .clap => "clap",
        .soundfont => "soundfont",
    };
}

/// Inverse of `apiKindName` for `track_add`'s opts.kind ("empty" is not
/// creatable on purpose - an empty track is the no-opts default state, not
/// something a script should ask for by name).
pub fn apiKindFromName(name: []const u8) ?ws.InstrumentKind {
    if (std.mem.eql(u8, name, "synth")) return .poly_synth;
    if (std.mem.eql(u8, name, "sampler")) return .sampler;
    if (std.mem.eql(u8, name, "drum")) return .drum_machine;
    if (std.mem.eql(u8, name, "slicer")) return .slicer;
    if (std.mem.eql(u8, name, "soundfont")) return .soundfont;
    return null;
}

fn userCmdRunner(comptime index: usize) *const fn (*anyopaque, []const u8) void {
    return struct {
        fn call(ctx: *anyopaque, args: []const u8) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const rt = app.lua_runtime orelse return;
            rt.runUserCommand(index, args);
        }
    }.call;
}

/// The `config.Host` hooks both frontends hand to the Lua runtime: notify
/// lands on the status line, exec goes through the `:` command dispatcher.
pub fn luaHost(app: *App) config_mod.Host {
    const hooks = struct {
        fn notify(ctx: *anyopaque, msg: []const u8) void {
            const a: *App = @ptrCast(@alignCast(ctx));
            a.setStatus("{s}", .{msg});
        }
        fn exec(ctx: *anyopaque, line: []const u8) void {
            const a: *App = @ptrCast(@alignCast(ctx));
            commands.run(a, line);
        }
    };
    return .{ .ctx = app, .notify = hooks.notify, .exec = hooks.exec };
}

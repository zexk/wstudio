//! App state + the main loop: view dispatch, modal actions, track add/delete,
//! and frame drawing. The rest of the TUI is split by concern - per-view input
//! in editors/<name>.zig, rendering in views/<name>.zig (via the tui.zig
//! facade), undo glue in history.zig, the `:command` layer in commands.zig,
//! and the integration tests in app_tests.zig.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const backend_mod = ws.backend;
const modal_mod = ws.input;
const terminal_mod = if (builtin.os.tag == .windows) @import("terminal_windows.zig") else @import("terminal.zig");
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const Slicer = ws.dsp.Slicer;
const commands = @import("commands.zig");
const cmd_mod = @import("cmd.zig");
const config_mod = @import("../config.zig");
const undo_mod = @import("undo.zig");
const history = @import("history.zig");
const tui = @import("tui.zig");
const style = @import("style.zig");
const icons = @import("icons.zig");
// Per-view input handlers; the render halves live in views/<name>.zig.
const drum_ed = @import("editors/drum.zig");
const slicer_ed = @import("editors/slicer.zig");
const synth_ed = @import("editors/synth.zig");
const sampler_ed = @import("editors/sampler.zig");
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

const Engine = engine_mod.Engine;
const Sampler = ws.dsp.Sampler;
const InstrumentKind = ws.InstrumentKind;
const pattern_mod = ws.dsp.pattern;

pub const note_ms = 220;
/// Rows every view's content starts after in `App.draw`: the header line +
/// the `hr` divider beneath it. Mouse hit-testing subtracts this before
/// handing a row to a view's own handler - see `App.handleMouse`.
pub const content_top: u16 = 2;
const cmd_history_cap: usize = 50;
/// Big enough for any real filesystem path; mirrors commands.path_buf_len.
const reload_path_buf_len: usize = 1024;
/// A pause longer than this between taps starts a fresh tap-tempo run.
/// Minimum gap between silent `<path>~` backups; see `maybeAutosave`.
const autosave_interval_ns: i96 = 30 * std.time.ns_per_s;
/// Where a plain `:w` lands when no project path is known yet - also what
/// a pathless session's autosave backs up next to (see `App.backupPath`).
pub const default_project_path = "project.wsj";

pub const AppView = enum { tracks, drum_grid, synth_editor, sampler_editor, help, track_spectrum, master_spectrum, group_spectrum, piano_roll, instrument_picker, fx_picker, synth_fx_picker, arrangement, file_browser, automation, automation_param_picker, slicer_grid, preset_picker };
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
pub const picker_kinds = [_]InstrumentKind{ .poly_synth, .sampler, .drum_machine, .slicer };
pub const picker_labels = [_][]const u8{ "Synth", "Sampler", "Drum Machine", "Slicer" };

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

    /// The extension the browser filters non-directory entries to (case
    /// insensitive); directories are always shown regardless.
    fn ext(self: BrowserPurpose) []const u8 {
        return switch (self) {
            .open_project => ".wsj",
            .load_sample, .load_pad, .load_clip, .load_slice, .load_wavetable => ".wav",
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
pub const DrumRangeClip = struct {
    width: u8,
    active: [DrumMachine.max_pads]u64 = [_]u64{0} ** DrumMachine.max_pads,
    /// Per-step velocity within the yanked range (index = step - range
    /// start); sized to match `active`'s bitmask width cap (`max_steps`).
    vel: [DrumMachine.max_pads][DrumMachine.max_steps]u8 = [_][DrumMachine.max_steps]u8{[_]u8{DrumMachine.vel_full} ** DrumMachine.max_steps} ** DrumMachine.max_pads,
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
    drum_range_delete: struct { width: u8 },
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
    drum_cursor: [2]u8 = .{ 0, 0 },
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
    audio_label: []const u8 = "off",
    master_gain_db: f32 = 0.0,
    should_quit: bool = false,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    status_ttl: u32 = 0,
    note_offs: [32]NoteOff = undefined,
    note_off_len: usize = 0,
    // Last timestamp seen by handleKey; lets sub-view handlers schedule note-offs
    // (e.g. piano-roll preview) without threading now_ns through every signature.
    now_ns: i96 = 0,
    tap_timeout_ns: i96 = 2 * std.time.ns_per_s,
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
    drum_visual_anchor: ?u8 = null,
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
    /// Tap-tempo ring (`t` in the tracks view; see `tapTempo`).
    tap_times: [8]i96 = undefined,
    tap_count: u8 = 0,
    /// Wall-clock ns of the last autosave backup attempt (0 = never tried).
    /// See `maybeAutosave`.
    last_autosave_ns: i96 = 0,
    /// Minimal netrw/dired-style file browser: `:e` and `:load-sample`
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
        user_presets.deinit(self.allocator, &self.user_synth_presets);
        user_drum_kits.deinit(self.allocator, &self.user_drum_kits);
        if (self.arr_range_clip) |r| {
            for (r.clips) |*c| c.deinit(self.allocator);
            self.allocator.free(r.clips);
        }
        if (self.automation_range_clip) |r| self.allocator.free(r.points);
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
                            'd', 'Y', 'J', 'K', 'R', 'p', '<', '>', '[', ']', 'v', 'z' => {
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
                            'Y', 'J', 'K', 'p', '<', '>', '[', ']' => {
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
        switch (ev.kind) {
            .press => {
                if (row < 2 or row - 2 >= picker_kinds.len) return;
                self.picker_cursor = @intCast(row - 2);
                self.pickerInsert();
            },
            .scroll_up => { if (self.picker_cursor > 0) self.picker_cursor -= 1; },
            .scroll_down => { if (self.picker_cursor + 1 < picker_kinds.len) self.picker_cursor += 1; },
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

    /// R opens the command prompt pre-filled with `:track-rename <n> ` for
    /// the cursor track - type the new name and hit enter (`esc` cancels,
    /// same as any other command-mode entry).
    fn startRenamePrompt(self: *App) void {
        if (self.cursor >= self.session.project.tracks.items.len) return;
        self.modal.mode = .command;
        self.cmd_history_pos = self.cmd_history.items.len;
        const text = std.fmt.bufPrint(&self.modal.cmd_buf, "track-rename {d} ", .{self.cursor + 1}) catch return;
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
        const text = std.fmt.bufPrint(&self.modal.cmd_buf, "group-rename {d} ", .{idx + 1}) catch return;
        self.modal.cmd_len = text.len;
        self.modal.cmd_cursor = text.len;
    }

    /// c toggles the click track (also `:metronome [on|off]`).
    fn toggleMetronome(self: *App) void {
        const on = !self.session.metronome_enabled;
        self.session.setMetronome(on);
        self.setStatus("metronome {s}", .{if (on) "on" else "off"});
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
    /// on, entering a live-pattern editor from the tracks view nudges it
    /// off, but ONLY while the transport is stopped. Switching views must
    /// never yank a playing source (mixing during song playback, clip-linked
    /// editing, sound design against the song). `T` in the arrangement stays
    /// the manual override either way.
    pub fn autoSongMode(self: *App, on: bool) void {
        if (self.session.song_mode == on) return;
        if (self.session.engine.uiSnapshot().playing) return;
        self.session.setSongMode(on);
        self.setStatus("{s} mode", .{if (on) "song" else "pattern"});
    }

    /// Open the editor matching the track's instrument, or the instrument
    /// picker if the track is blank.
    fn openTrack(self: *App, cursor: usize) void {
        if (cursor >= self.session.racks.items.len) return;
        switch (self.session.racks.items[cursor].instrument) {
            .empty => { self.picker_cursor = 0; self.view = .instrument_picker; },
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
                self.view = .drum_grid;
                self.autoSongMode(false);
            },
            .slicer => {
                self.slicer_track = @intCast(cursor);
                self.view = .slicer_grid;
                self.autoSongMode(false);
            },
        }
    }

    /// Instrument picker: j/k move, g/G jump to ends, enter/space insert the
    /// highlighted kind on the cursor track and jump to its editor, esc
    /// cancels back to tracks.
    fn handlePickerKey(self: *App, key: modal_mod.Key) void {
        switch (key) {
            .escape => self.view = .tracks,
            .enter => self.pickerInsert(),
            .char => |c| switch (c) {
                'k' => { if (self.picker_cursor > 0) self.picker_cursor -= 1; },
                'j' => { if (self.picker_cursor + 1 < picker_kinds.len) self.picker_cursor += 1; },
                'g' => self.picker_cursor = 0,
                'G' => self.picker_cursor = @intCast(picker_kinds.len - 1),
                ' ' => self.pickerInsert(),
                'q' => self.view = .tracks,
                else => {},
            },
            else => {},
        }
    }
    // zig fmt: on

    fn pickerInsert(self: *App) void {
        const kind = picker_kinds[self.picker_cursor];
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
            .slicer => "enter: step  i: play  :load-slice  ?: help",
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
        if (kinds.len > 0 and self.fx_picker_cursor >= kinds.len) self.fx_picker_cursor = @intCast(kinds.len - 1);
        switch (key) {
            .escape => spectrum_ed.cancelPicker(self),
            .enter => if (self.fx_picker_cursor < kinds.len) spectrum_ed.insertFromPicker(self, kinds[self.fx_picker_cursor]),
            .char => |c| switch (c) {
                'k' => { if (self.fx_picker_cursor > 0) self.fx_picker_cursor -= 1; },
                'j' => { if (self.fx_picker_cursor + 1 < kinds.len) self.fx_picker_cursor += 1; },
                'g' => self.fx_picker_cursor = 0,
                'G' => self.fx_picker_cursor = @intCast(kinds.len -| 1),
                ' ' => if (self.fx_picker_cursor < kinds.len) spectrum_ed.insertFromPicker(self, kinds[self.fx_picker_cursor]),
                'q' => spectrum_ed.cancelPicker(self),
                else => {},
            },
            else => {},
        }
    }

    /// FX picker: click a row to select + insert it (same as enter/space);
    /// scroll moves the highlight.
    fn fxPickerMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        var buf: [spectrum_ed.picker_kinds.len]ws.FxKind = undefined;
        const kinds = spectrum_ed.filteredPickerKinds(self, &buf);
        switch (ev.kind) {
            .press => {
                if (row < 2 or row - 2 >= kinds.len) return;
                self.fx_picker_cursor = @intCast(row - 2);
                spectrum_ed.insertFromPicker(self, kinds[self.fx_picker_cursor]);
            },
            .scroll_up => { if (self.fx_picker_cursor > 0) self.fx_picker_cursor -= 1; },
            .scroll_down => { if (self.fx_picker_cursor + 1 < kinds.len) self.fx_picker_cursor += 1; },
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
    // File browser (netrw/dired-style; `:e`, `:load-sample` with
    // no path open it - see commands.zig)
    // -----------------------------------------------------------------------

    /// Enter the browser for `purpose`, starting in the current project's
    /// directory (or cwd if none is set yet). Leaves the view untouched if
    /// that starting directory can't be listed.
    pub fn openBrowser(self: *App, purpose: BrowserPurpose) void {
        self.browser_purpose = purpose;
        const start: []const u8 = if (self.projectPath()) |p|
            (std.fs.path.dirname(p) orelse ".")
        else
            ".";
        self.setBrowserDir(start) catch |e| {
            self.setStatus("browse: cannot open '{s}': {s}", .{ start, @errorName(e) });
            return;
        };
        self.prev_view = self.view;
        self.view = .file_browser;
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
            if (entry.name.len == 0 or entry.name[0] == '.') continue; // hidden, netrw-style
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
                    // it instead of arming another one on top.
                    _ = self.session.engine.send(.stop);
                    self.setStatus("count-in cancelled", .{});
                } else if (!snap.playing and self.modal.mode == .insert and
                    (self.view == .piano_roll or self.view == .drum_grid))
                {
                    // Starting playback to record (insert mode, piano roll or
                    // drum grid, currently stopped) clicks a one-bar count-in
                    // first so there's a cue to come in on. Already-rolling
                    // playback (jumping into insert mode mid-song) needs none
                    // of this - recordNote just quantizes to the live playhead.
                    _ = self.session.engine.send(.record);
                    self.setStatus("count-in...", .{});
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
                    .poly_synth, .sampler => {
                        self.playNote(track_idx, n.pitch, now_ns);
                        if (self.view == .piano_roll) piano_ed.recordNote(self, n.pitch, pattern_mod.default_velocity);
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

    fn setSearchPattern(self: *App, text: []const u8) void {
        const len = @min(text.len, self.search_pattern_buf.len);
        @memcpy(self.search_pattern_buf[0..len], text[0..len]);
        self.search_pattern_len = len;
    }

    // zig fmt: off
    /// `/` search + `n`/`N` repeat over track names, wrapping around the
    /// list like vim's own search. `dir` is +1 for `n`/a fresh `/`, -1 for
    /// `N` (repeat in reverse). The master row has no name and is skipped -
    /// search only ever lands on a real track.
    pub fn searchTracks(self: *App, dir: i64) void {
        const pattern = self.searchPattern();
        if (pattern.len == 0) { self.setStatus("no previous search pattern", .{}); return; }
        const tracks = self.session.project.tracks.items;
        const n: i64 = @intCast(tracks.len);
        if (n == 0) { self.setStatus("no tracks to search", .{}); return; }
        const start: i64 = @min(@as(i64, @intCast(self.cursor)), n - 1);
        var step: i64 = 1;
        while (step <= n) : (step += 1) {
            const idx: usize = @intCast(@mod(start + dir * step, n));
            if (fuzzy.matches(pattern, tracks[idx].name)) {
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
                return;
            }
        }
        self.setStatus("no match for '{s}'", .{pattern});
    }

    /// `/` search + `n`/`N` repeat over the help view's rendered lines
    /// (ANSI-stripped), wrapping the same way `searchTracks` does. The hit
    /// line scrolls to the top of the window and stays highlighted.
    pub fn searchHelp(self: *App, dir: i64) void {
        const pattern = self.searchPattern();
        if (pattern.len == 0) { self.setStatus("no previous search pattern", .{}); return; }
        const start = self.help_search_hit orelse self.help_scroll;
        if (tui.helpSearch(self.allCmds(), pattern, start, dir)) |idx| {
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
        const n: i64 = @intCast(entries.len);
        if (n == 0) { self.setStatus("no entries to search", .{}); return; }
        const start: i64 = @min(@as(i64, @intCast(self.browser_cursor)), n - 1);
        var step: i64 = 1;
        while (step <= n) : (step += 1) {
            const idx: usize = @intCast(@mod(start + dir * step, n));
            if (fuzzy.matches(pattern, entries[idx].name)) {
                self.browser_cursor = idx;
                self.setStatus("/{s}  [{d}/{d}]", .{ pattern, idx + 1, entries.len });
                return;
            }
        }
        self.setStatus("no match for '{s}'", .{pattern});
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
        const n: i64 = @intCast(tracks.len);
        if (n == 0) { self.setStatus("no tracks to search", .{}); return; }
        const start: i64 = @min(@as(i64, @intCast(self.cursor)), n - 1);
        var step: i64 = 1;
        while (step <= n) : (step += 1) {
            const idx: usize = @intCast(@mod(start + dir * step, n));
            if (fuzzy.matches(pattern, tracks[idx].name)) {
                self.cursor = idx;
                self.setStatus("/{s}  [{d}/{d}]", .{ pattern, idx + 1, tracks.len });
                return;
            }
        }
        self.setStatus("no match for '{s}'", .{pattern});
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
        if (self.cmd_history.items.len >= cmd_history_cap) {
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

        const Source = enum { command_name, drum_kit, synth_preset, metronome, scale };

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

    /// Fire a preview note and schedule its release ~220ms later (see `tick`).
    /// Pub for the editor modules' audition keys.
    pub fn playNote(self: *App, track: u16, pitch: u7, now_ns: i96) void {
        _ = self.session.engine.send(.{ .note_on = .{ .track = track, .note = pitch, .velocity = 0.85 } });
        if (self.note_off_len == self.note_offs.len) {
            const oldest = self.note_offs[0];
            _ = self.session.engine.send(.{ .note_off = .{ .track = oldest.track, .note = oldest.note } });
            std.mem.copyForwards(NoteOff, self.note_offs[0 .. self.note_off_len - 1], self.note_offs[1..self.note_off_len]);
            self.note_off_len -= 1;
        }
        self.note_offs[self.note_off_len] = .{
            .at_ns = now_ns + note_ms * std.time.ns_per_ms,
            .track = track,
            .note = pitch,
        };
        self.note_off_len += 1;
    }

    pub fn tick(self: *App, now_ns: i96) void {
        if (self.status_ttl > 0) {
            self.status_ttl -= 1;
            if (self.status_ttl == 0) self.status_len = 0;
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
    }

    /// Every `autosave_interval_ns`, if there are unsaved changes, silently
    /// write a `<path>~` backup - a safety net, not a real save: it doesn't
    /// clear `dirty` or touch the primary file, so `:q` still guards the
    /// actual edits. A brand-new project with no path yet backs up next to
    /// `:w`'s own default target (see backupPath). Failures are silent
    /// (best-effort); a status message every 30s would just be noise during
    /// active work.
    fn maybeAutosave(self: *App, now_ns: i96) void {
        if (!self.dirty) return;
        if (now_ns - self.last_autosave_ns < autosave_interval_ns) return;
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
    fn promptIfBackupNewer(self: *App, path: []const u8) void {
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
        if (self.synth_track >= idx) self.synth_track += 1;
        if (self.drum_track >= idx) self.drum_track += 1;
        if (self.piano_track >= idx) self.piano_track += 1;
        if (self.eq_track >= idx) self.eq_track += 1;
        if (self.slicer_track >= idx) self.slicer_track += 1;
        if (self.automation_track >= idx) self.automation_track += 1;
        switch (self.sampler_target) {
            .drum => |*t| if (t.* >= idx) { t.* += 1; },
            .sampler => |*t| if (t.* >= idx) { t.* += 1; },
            .slice => |*t| if (t.* >= idx) { t.* += 1; },
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
        if (idx < self.synth_track and self.synth_track > 0) self.synth_track -= 1;
        if (idx < self.drum_track and self.drum_track > 0) self.drum_track -= 1;
        if (idx < self.piano_track and self.piano_track > 0) self.piano_track -= 1;
        if (idx < self.eq_track and self.eq_track > 0) self.eq_track -= 1;
        if (idx < self.slicer_track and self.slicer_track > 0) self.slicer_track -= 1;
        if (idx < self.automation_track and self.automation_track > 0) self.automation_track -= 1;
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
            .drum    => |*t| if (idx < t.* and t.* > 0) { t.* -= 1; },
            .sampler => |*t| if (idx < t.* and t.* > 0) { t.* -= 1; },
            .slice   => |*t| if (idx < t.* and t.* > 0) { t.* -= 1; },
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
                switch (racks[self.piano_track].instrument) { .poly_synth, .sampler => false, else => true })
            {
                self.view = .tracks;
            },
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
    /// `style.track_palette`, wrapping through 0 ("none") on both ends -
    /// same cycling shape as the drum grid's variant `[`/`]`. Not
    /// undo-tracked, matching mute/solo/gain/pan (mixer-style live state,
    /// not pattern content).
    pub fn doTrackColorCycle(self: *App, dir: i32) void {
        if (self.cursor >= self.session.project.tracks.items.len) return;
        const track = &self.session.project.tracks.items[self.cursor];
        const n: i32 = @intCast(style.track_palette.len + 1); // +1 for "none"
        const cur: i32 = @intCast(track.color);
        track.color = @intCast(@mod(cur + dir, n));
        self.dirty = true;
        if (track.color == 0) {
            self.setStatus("track {d} color: none", .{self.cursor + 1});
        } else {
            self.setStatus("track {d} color: {s}", .{ self.cursor + 1, style.track_color_names[track.color - 1] });
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

    pub fn setProjectPath(self: *App, path: []const u8) void {
        const len = @min(path.len, self.project_path_buf.len);
        @memcpy(self.project_path_buf[0..len], path[0..len]);
        self.project_path_len = len;
    }

    pub fn clearProjectPath(self: *App) void {
        self.project_path_len = 0;
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
        const path = self.projectPath() orelse default_project_path;
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
        self.status_ttl = 100;
    }

    pub fn statusText(self: *const App) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    // -----------------------------------------------------------------------
    // Rendering (delegates to tui.zig)
    // -----------------------------------------------------------------------

    /// Smallest terminal the layouts are actually built for: the FX chain's
    /// slot strip is sized "nine boxes + ▶OUT = 78 cols" for 80-col
    /// terminals, and the row budgets were audited down to 14 rows. Below
    /// this, content lines wrap and shove the frame apart - show a notice
    /// instead (btop-style) rather than fighting per-view overflow.
    pub const min_cols: usize = 80;
    pub const min_rows: usize = 14;

    pub fn draw(self: *App, w: *std.Io.Writer, size: terminal_mod.Size) !void {
        self.last_cols = size.cols;
        if (size.cols < min_cols or size.rows < min_rows) {
            try drawTooSmall(w, size);
            return;
        }
        const snap = self.session.engine.uiSnapshot();
        const rows: usize = @max(size.rows, 10);

        // Form-primitive width knobs: back to the compact defaults each
        // frame, so a wide view's opt-in never leaks into the next view.
        style.form_bar_w = style.form_bar_w_default;
        style.form_section_w = style.form_section_w_default;

        // Command-mode's Tab-completion popup (see cmd.writeSuggestionBox)
        // sits directly above the `:` prompt, drawn after the transport
        // line's closing hr below. Carve its rows out of the content area's
        // budget up front so the frame never grows taller than the terminal.
        const max_suggestion_rows = 10;
        const suggestion_rows: usize = if (self.modal.mode == .command and self.suggest_popup_open)
            cmd_mod.suggestionRows(self.allCmds(), self.suggestionFilterText(), commands.activeScope(self), max_suggestion_rows)
        else
            0;
        const content_rows = rows -| suggestion_rows;

        try w.writeAll("\x1b[H");
        // The .wsj format has no project-name field, so a loaded file would
        // otherwise sit under the default "untitled" - show its basename.
        const header_title: []const u8 = if (self.projectPath()) |p| std.fs.path.basename(p) else self.session.project.name;
        // Rendered into a scratch buffer and replayed via style.writeChromeRow
        // (clamp + clean line-end, no separate hr() rule row underneath) -
        // reclaims a row versus the old plain-line-plus-rule layout.
        var header_scratch: [512]u8 = undefined;
        var header_w = std.Io.Writer.fixed(&header_scratch);
        try tui.drawHeader(&header_w, header_title, &self.session.engine.transport, self.audio_label, self.master_gain_db, self.dirty);
        try style.writeChromeRow(w, header_w.buffered(), size.cols);

        // zig fmt: off
        switch (self.view) {
            .tracks          => try tui.drawTracks(self, w, content_rows, size.cols, snap),
            .drum_grid       => try tui.drawDrumGrid(self, w, content_rows, size.cols, snap),
            .synth_editor    => try tui.drawSynthEditor(self, w, content_rows, size.cols, snap),
            .sampler_editor  => try tui.drawSamplerEditor(self, w, content_rows, size.cols, snap),
            .piano_roll      => try tui.drawPianoRoll(self, w, content_rows, size.cols, snap),
            .help            => try tui.drawHelp(w, content_rows, size.cols, self.allCmds(), &self.help_scroll, self.help_search_hit),
            .track_spectrum, .master_spectrum, .group_spectrum =>
                try tui.drawFxView(self, w, content_rows, size.cols, snap, spectrum_ed.currentTarget(self)),
            .instrument_picker => try tui.drawInstrumentPicker(self, w, content_rows),
            .fx_picker       => try tui.drawFxPicker(self, w, content_rows),
            .synth_fx_picker => try tui.drawSynthFxPicker(self, w, content_rows),
            .arrangement     => try tui.drawArrangement(self, w, content_rows, size.cols, snap),
            .file_browser    => try tui.drawFileBrowser(self, w, content_rows),
            .automation      => try tui.drawAutomation(self, w, content_rows, size.cols, snap),
            .automation_param_picker => try tui.drawAutomationParamPicker(self, w, content_rows),
            .slicer_grid     => try tui.drawSlicerGrid(self, w, content_rows, size.cols, snap),
            .preset_picker   => try tui.drawPresetPicker(self, w, content_rows),
        }
        // zig fmt: on

        var transport: Transport = .{
            .sample_rate = self.session.project.sample_rate,
            .tempo_bpm = self.session.project.tempo_bpm,
            .position_frames = snap.position_frames,
        };
        // Off the arrangement timeline, the transport plays a raw straight
        // line while the audio itself loops locally (PatternPlayer/
        // DrumMachine wrap at their own length) - mirror that in the
        // bar:beat readout so it cycles instead of climbing forever.
        if (!self.session.song_mode) {
            const len_beats = self.contentBeats();
            if (len_beats > 0) {
                const fpb = transport.framesPerBeat();
                const loop_frames: u64 = @intFromFloat(len_beats * fpb);
                if (loop_frames > 0) transport.position_frames %= loop_frames;
            }
        }
        const pos = transport.positionBarBeat();
        const secs = transport.positionSeconds();
        // Left = transport state (play/stop, metronome, bar.beat, clock);
        // right = the L/R meters, pinned to the row's right edge instead of
        // trailing wherever the left content happens to end (writeSplitRow).
        var transport_scratch: [512]u8 = undefined;
        var tw = std.Io.Writer.fixed(&transport_scratch);
        if (snap.pre_rolling) {
            // No dedicated glyph for this - it's a brief, rare state, so
            // plain text beats adding another icon just for it.
            try tw.writeAll("\x1b[33m\x1b[1m count-in\x1b[0m");
        } else if (snap.playing) {
            if (icons.font_installed) {
                try tw.writeAll("\x1b[32m\x1b[1m " ++ icons.play ++ "\x1b[0m");
            } else {
                // U+25BA/U+25A0 are in CP437, so even bitmap terminal fonts
                // (PxPlus IBM VGA etc.) have them - no icon font needed.
                try tw.writeAll("\x1b[32m\x1b[1m \u{25BA}\x1b[0m");
            }
        } else {
            if (icons.font_installed) {
                try tw.writeAll("\x1b[2m " ++ icons.stop ++ "\x1b[0m");
            } else {
                try tw.writeAll("\x1b[2m \u{25A0}\x1b[0m");
            }
        }
        if (self.session.metronome_enabled) {
            try tw.writeAll(" \x1b[33m" ++ icons.tempo ++ " click\x1b[0m");
        }
        try tw.print(" {d:0>3}.{d}  {d:0>2}:{d:0>4.1}", .{
            pos.bar + 1,
            pos.beat + 1,
            @as(u64, @intFromFloat(secs / 60.0)),
            @mod(secs, 60.0),
        });
        var meter_scratch: [128]u8 = undefined;
        var mw = std.Io.Writer.fixed(&meter_scratch);
        try mw.writeAll("\x1b[2mL\x1b[0m");
        try tui.meter(&mw, snap.peak[0]);
        try mw.writeAll("\x1b[2m R\x1b[0m");
        try tui.meter(&mw, snap.peak[1]);
        try style.writeSplitRow(w, tw.buffered(), mw.buffered(), size.cols);
        try style.endLine(w);
        // The `:`/`/` prompt's own row - blank outside command/search mode.
        // Moved off the status row below so that row can keep showing the
        // mode badge/view info while a command is being typed instead of
        // being replaced by the prompt text.
        var prompt_scratch: [1024]u8 = undefined;
        var prompt_w = std.Io.Writer.fixed(&prompt_scratch);
        switch (self.modal.mode) {
            .command => try cmd_mod.writePrompt(&prompt_w, self.allCmds(), self.modal.cmd_buf[0..self.modal.cmd_len], self.modal.cmd_cursor, 60),
            .search => try cmd_mod.writeSearchPrompt(&prompt_w, self.modal.cmd_buf[0..self.modal.cmd_len], self.modal.cmd_cursor),
            else => {},
        }
        try style.writeClamped(w, prompt_w.buffered(), size.cols -| 1);
        try style.endLine(w);

        if (suggestion_rows > 0) {
            try cmd_mod.writeSuggestionBox(
                w,
                self.allCmds(),
                self.suggestionFilterText(),
                commands.activeScope(self),
                self.suggestionSelected(commands.activeScope(self)),
                max_suggestion_rows,
            );
        }

        // zig fmt: off
        // Status lines are assembled from several independent print calls
        // with no shared width budget, so a verbose message (e.g. the
        // visual-mode hint) can overflow past the terminal's right edge and
        // wrap onto a new row, scrolling the header off the top. Render into
        // a scratch buffer first and clamp to the terminal width before it
        // ever reaches the real writer.
        var status_scratch: [1024]u8 = undefined;
        var status_w = std.Io.Writer.fixed(&status_scratch);
        // The current-view name (and a couple of short state flags - zoom,
        // song/pattern) rides a second buffer and gets pinned to the row's
        // right edge via writeSplitRow, lualine's "current view is an
        // identity tag on the right, not more left-to-right reading order"
        // convention - mirrors the transport row's L/R meters above.
        var status_right_scratch: [128]u8 = undefined;
        var status_right_w = std.Io.Writer.fixed(&status_right_scratch);
        switch (self.view) {
            .tracks          => try tui.drawTracksStatus(self, &status_w, &status_right_w),
            .drum_grid       => try tui.drawDrumStatus(self, &status_w, &status_right_w),
            .synth_editor    => try tui.drawSynthStatus(self, &status_w, &status_right_w),
            .sampler_editor  => try tui.drawSamplerStatus(self, &status_w, &status_right_w),
            .piano_roll      => try tui.drawPianoRollStatus(self, &status_w, &status_right_w),
            .help            => try tui.drawHelpStatus(self, &status_w, &status_right_w),
            .track_spectrum, .master_spectrum, .group_spectrum =>
                try tui.drawFxStatus(self, &status_w, &status_right_w, spectrum_ed.currentTarget(self)),
            .instrument_picker => try tui.drawPickerStatus(self, &status_w, &status_right_w, "INSTRUMENT", "insert", false),
            .fx_picker       => try tui.drawPickerStatus(self, &status_w, &status_right_w, "EFFECT", "insert", true),
            .synth_fx_picker => try tui.drawPickerStatus(self, &status_w, &status_right_w, "SYNTH FX", "insert", true),
            .arrangement     => try tui.drawArrangementStatus(self, &status_w, &status_right_w),
            .file_browser    => try tui.drawFileBrowserStatus(self, &status_w, &status_right_w),
            .automation      => try tui.drawAutomationStatus(self, &status_w, &status_right_w),
            .automation_param_picker => try tui.drawPickerStatus(self, &status_w, &status_right_w, "PARAM", "pick", true),
            .slicer_grid     => try tui.drawSlicerStatus(self, &status_w, &status_right_w),
            .preset_picker   => try tui.drawPresetPickerStatus(self, &status_w, &status_right_w),
        }
        try style.writeSplitRow(w, status_w.buffered(), status_right_w.buffered(), size.cols -| 1);
        // Erase from cursor to end of screen so stale content from taller
        // previous frames never bleeds through.
        try w.writeAll("\x1b[K\x1b[J");
    }
    // zig fmt: on

    /// Full-screen stand-in below min_cols x min_rows. ASCII only so the
    /// byte-length centering math holds.
    fn drawTooSmall(w: *std.Io.Writer, size: terminal_mod.Size) !void {
        try w.writeAll("\x1b[H");
        var buf: [64]u8 = undefined;
        const line1: []const u8 = "terminal too small";
        const line2: []const u8 = std.fmt.bufPrint(&buf, "need {d}x{d}, have {d}x{d}", .{ min_cols, min_rows, size.cols, size.rows }) catch "";
        const rows: usize = @max(size.rows, 1);
        for (0..(rows / 2) -| 1) |_| try style.endLine(w);
        try drawCenteredLine(w, line1, size.cols, style.bold);
        if (rows >= 2) try drawCenteredLine(w, line2, size.cols, style.dim);
        try w.writeAll("\x1b[K\x1b[J");
    }

    fn drawCenteredLine(w: *std.Io.Writer, text: []const u8, cols: u16, sgr: []const u8) !void {
        const pad = (@as(usize, cols) -| text.len) / 2;
        for (0..pad) |_| try w.writeByte(' ');
        try w.writeAll(sgr);
        try style.writeClamped(w, text, cols);
        try style.endLine(w);
    }
};

fn renderTrampoline(ctx: *anyopaque, out: []types.Sample) void {
    const engine: *Engine = @ptrCast(@alignCast(ctx));
    // During an offline bounce the UI thread owns the engine: park here so the
    // two threads never call process() concurrently. See App.cmdBounce.
    if (engine.bounce_active.load(.acquire)) {
        @memset(out, 0.0);
        engine.bounce_parked.store(true, .release);
        return;
    }
    engine.process(out);
}

/// Set for the lifetime of `run`'s raw-mode session so `main.zig`'s panic
/// handler can find the terminal to restore before it prints the crash
/// trace - without this, a panic left the terminal in raw mode with SGR
/// mouse tracking still on: the shell reads garbled, and the panic message
/// itself is unreadable (no \r\n translation, alternate screen still up).
pub var active_terminal: ?*terminal_mod.Terminal = null;

// zig fmt: off
/// Per-slot trampolines bridging `cmd.Def.run`'s context-free signature to
/// `Runtime.runUserCommand(index, ...)` - a Def can't carry which Lua
/// handler it belongs to, so the slot index is baked in at comptime.
const user_cmd_runners: [config_mod.max_user_cmds]*const fn (*anyopaque, []const u8) void = blk: {
    var fns: [config_mod.max_user_cmds]*const fn (*anyopaque, []const u8) void = undefined;
    for (0..config_mod.max_user_cmds) |i| fns[i] = userCmdRunner(i);
    break :blk fns;
};

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

pub fn run(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8, runtime: *config_mod.Runtime) !void {
    const user_config = runtime.config;
    var term = terminal_mod.Terminal.init(io) catch {
        std.debug.print(
            "wstudio: stdin is not a terminal (try `wstudio render` for the offline demo)\n",
            .{},
        );
        return;
    };
    active_terminal = &term;
    defer { term.deinit(); active_terminal = null; }
    // zig fmt: on

    var app = try App.initWithSampleRate(allocator, io, user_config.default_sample_rate);
    defer app.deinit();
    app.tap_timeout_ns = @as(i96, user_config.tap_timeout_ms) * std.time.ns_per_ms;
    if (init_path == null) {
        app.session.project.tempo_bpm = user_config.default_tempo;
        app.session.project.beats_per_bar = user_config.default_beats_per_bar;
        _ = app.session.engine.send(.{ .set_tempo = user_config.default_tempo });
        _ = app.session.engine.send(.{ .set_time_signature = user_config.default_beats_per_bar });
        app.session.syncLoop();
    }
    icons.font_installed = icons.detectFontInstalled(io);

    // Surface a raw-mode setup failure once there's a status line to put it
    // on - see Terminal.raw_mode_ok's doc comment (Windows only; POSIX raw
    // mode failing is already fatal via tcsetattr's error return in init()).
    if (builtin.os.tag == .windows and !term.raw_mode_ok) {
        app.setStatus("warning: console raw-mode setup failed - quick edit may freeze the display", .{});
    }

    // Load project file before backends start - the backend captures the engine
    // pointer at init, so the swap must happen here.
    if (init_path) |p| {
        if (ws.persist.load(allocator, io, p)) |loaded| {
            app.session.deinit();
            app.session = loaded;
            app.setProjectPath(p);
            app.promptIfBackupNewer(p);
        } else |e| {
            std.debug.print("wstudio: cannot load '{s}': {s}\n", .{ p, @errorName(e) });
        }
    } else {
        // No project argument: a crashed pathless session's autosave lands
        // next to `:w`'s default target (see backupPath's fallback), so the
        // blank start checks the same spot the pathed start does.
        app.promptIfBackupNewer(default_project_path);
    }

    // The app is fully initialized: route `wstudio.notify`/`wstudio.cmd`
    // into it and flush command lines queued while init.lua ran. The
    // command table must include Lua user commands before the flush, since
    // queued lines may invoke them.
    app.lua_runtime = runtime;
    app.rebuildCmdTable();
    runtime.attachHost(luaHost(&app));
    defer runtime.host = null;

    var config: backend_mod.Config = .{
        .sample_rate = app.session.project.sample_rate,
        .block_frames = user_config.audio_block_frames,
    };

    // zig fmt: off
    const has_alsa = builtin.os.tag == .linux;
    const has_wasapi = builtin.os.tag == .windows;
    const NativeBackend = if (has_alsa) ws.alsa.AlsaBackend else if (has_wasapi) ws.wasapi.WasapiBackend else void;
    const MidiIn        = if (has_alsa) ws.midi_in.MidiIn else void;
    var native_backend: NativeBackend = undefined;
    var midi_in:        MidiIn        = undefined;
    var null_backend = backend_mod.NullBackend{
        .config = config,
        .render = renderTrampoline,
        .ctx = app.session.engine,
    };
    // zig fmt: on

    var using_native = false;
    var using_midi = false;
    if (has_alsa) {
        native_backend = .{ .config = config, .render = renderTrampoline, .ctx = app.session.engine };
        if (native_backend.start()) {
            using_native = true;
        } else |_| {}

        // zig fmt: off
        midi_in = .{ .engine = app.session.engine };
        if (midi_in.start()) {
            using_midi = true;
        } else |_| {}
    } else if (has_wasapi) {
        native_backend = .{ .config = config, .render = renderTrampoline, .ctx = app.session.engine };
        if (native_backend.start()) {
            using_native = true;
        } else |_| {}
    }
    if (!using_native) try null_backend.start(io);
    defer if (using_native) native_backend.stop() else null_backend.stop();
    defer if (has_alsa) { if (using_midi) midi_in.stop(); };
    app.audio_label = if (using_native) (if (has_alsa) "alsa" else "wasapi") else "none (silent)";
    // zig fmt: on

    // Sized to comfortably fit the heaviest single-view frame: the drum
    // grid at max pads (64) x max steps (64), where every cell carries its
    // own ANSI color code, runs to ~55KB on a wide+tall terminal. A fixed
    // writer that runs out mid-frame silently truncates (Writer.fixed's
    // error is swallowed below), which cuts the DEC 2026 sync bracket in
    // half and leaves the terminal stuck mid-redraw - 32KB was tight enough
    // for that to actually happen once pad/step banking stacked up.
    var frame_buf: [160 * 1024]u8 = undefined;
    var input_buf: [128]u8 = undefined;
    var keys: [64]modal_mod.Key = undefined;

    while (!app.should_quit) {
        const bytes = try term.readInput(&input_buf, user_config.frame_poll_ms);
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
        const n = terminal_mod.decode(bytes, &keys);
        for (keys[0..n]) |key| switch (key) {
            .mouse => |ev| {
                const sz = term.size();
                app.handleMouse(ev, sz.cols, sz.rows, now);
            },
            else => app.handleKey(key, now),
        };
        app.tick(now);

        // zig fmt: off
        // :e / :new asked for a session swap. Build the replacement first
        // (control-thread only, no backend involved) so a bad path or OOM
        // just reports an error and leaves the running session untouched;
        // only stop the backend once we actually have something to swap in
        // - it holds a raw *Engine pointer captured at start (or the last
        // reload), which the swap would otherwise dangle.
        if (app.pending_reload != .none) {
            const kind = app.pending_reload;
            app.pending_reload = .none;
            const new_session: ?ws.Session = switch (kind) {
                .none => unreachable,
                .blank => ws.Session.initDefault(allocator) catch |e| blk: {
                    app.setStatus("new: {s}", .{@errorName(e)});
                    break :blk null;
                },
                .load, .restore_backup => blk: {
                    const path = app.pendingReloadPath();
                    if (ws.persist.load(allocator, io, path)) |loaded| {
                        break :blk loaded;
                    } else |e| {
                        app.setStatus("e: cannot load '{s}': {s}", .{ path, @errorName(e) });
                        break :blk null;
                    }
                },
            };
            if (new_session) |loaded| {
                if (using_native) native_backend.stop() else null_backend.stop();
                if (has_alsa) { if (using_midi) midi_in.stop(); }

                app.session.deinit();
                app.session = loaded;
                switch (kind) {
                    .load => app.setProjectPath(app.pendingReloadPath()),
                    // Keep the original project path - the backup's content
                    // replaces the in-memory session but `:w` should still
                    // write back to the real file, not `<path>~`.
                    .restore_backup => { app.dirty = true; app.setStatus("restored from autosave backup - :write to keep it", .{}); },
                    .blank => app.project_path_len = 0,
                    .none => unreachable,
                }

                config = .{ .sample_rate = app.session.project.sample_rate };
                null_backend = .{ .config = config, .render = renderTrampoline, .ctx = app.session.engine };
                using_native = false;
                using_midi = false;
                if (has_alsa) {
                    native_backend = .{ .config = config, .render = renderTrampoline, .ctx = app.session.engine };
                    if (native_backend.start()) { using_native = true; } else |_| {}
                    midi_in = .{ .engine = app.session.engine };
                    if (midi_in.start()) { using_midi = true; } else |_| {}
                } else if (has_wasapi) {
                    native_backend = .{ .config = config, .render = renderTrampoline, .ctx = app.session.engine };
                    if (native_backend.start()) { using_native = true; } else |_| {}
                }
                // A restart failure here just leaves the session silent
                // rather than tearing down the whole running app.
                if (!using_native) null_backend.start(io) catch {};
                app.audio_label = if (using_native) (if (has_alsa) "alsa" else "wasapi") else "none (silent)";
                switch (kind) {
                    .load => app.setStatus("loaded: {s}", .{app.projectPath().?}),
                    .blank => app.setStatus("new project", .{}),
                    // Status already set above ("restored from autosave...").
                    .restore_backup => {},
                    .none => unreachable,
                }
            }
        }

        // MIDI input follows the TUI cursor so live playing always targets the
        // currently selected track. Written from the UI thread, read (monotonic)
        // in the MIDI reader thread.
        if (has_alsa) { if (using_midi) midi_in.active_track.store(@intCast(app.cursor), .monotonic); }

        // A MIDI CC can mutate saved instrument params straight from the
        // reader thread (PolySynth.applyCC); it has no App pointer to flag
        // `dirty` itself, so pick up its signal here once per frame instead.
        if (has_alsa) { if (using_midi and midi_in.dirty.swap(false, .acquire)) app.dirty = true; }

        // Live MIDI note recording: every note-on the reader thread saw also
        // landed in `note_queue` (audition itself already went straight to
        // the engine from that thread, unaffected by this). Drain it here
        // and feed each note through the exact same insert-mode recordNote
        // path qwerty playing uses (the `.note` action handler above) -
        // gated the same way: only in insert mode, only for the view whose
        // pattern is actually being edited. A stopped transport or wrong
        // view/mode just drops the note; the live audition already
        // happened regardless. Unlike qwerty, the played velocity comes
        // through, so a take keeps its dynamics.
        if (has_alsa) { if (using_midi) {
            while (midi_in.note_queue.pop()) |rec| {
                if (app.modal.mode != .insert) continue;
                switch (app.view) {
                    .drum_grid => drum_ed.recordNote(&app, rec.pitch, rec.vel),
                    .slicer_grid => slicer_ed.recordNote(&app, rec.pitch, rec.vel),
                    .piano_roll => piano_ed.recordNote(&app, rec.pitch, @as(f32, @floatFromInt(rec.vel)) / 127.0),
                    else => {},
                }
            }
        } }
        // zig fmt: on

        var w = std.Io.Writer.fixed(&frame_buf);
        // Bracket the frame in a DEC 2026 synchronized update, inside the
        // same single write: without it tmux/compositing terminals can
        // repaint mid-frame, which reads as flicker on plain navigation.
        w.writeAll(terminal_mod.begin_sync) catch {};
        app.draw(&w, term.size()) catch {};
        w.writeAll(terminal_mod.end_sync) catch {};
        term.write(w.buffered());
    }
}

// ---------------------------------------------------------------------------
// Tests - integration tests live in app_tests.zig
// ---------------------------------------------------------------------------

test {
    _ = @import("app_tests.zig");
}

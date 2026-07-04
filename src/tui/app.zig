//! App state + the main loop: view dispatch, modal actions, track add/delete,
//! and frame drawing. The rest of the TUI is split by concern — per-view input
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
const terminal_mod = @import("terminal.zig");
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const commands = @import("commands.zig");
const cmd_mod = @import("cmd.zig");
const undo_mod = @import("undo.zig");
const history = @import("history.zig");
const tui = @import("tui.zig");
const icons = @import("icons.zig");
// Per-view input handlers; the render halves live in views/<name>.zig.
const drum_ed = @import("editors/drum.zig");
const synth_ed = @import("editors/synth.zig");
const sampler_ed = @import("editors/sampler.zig");
const piano_ed = @import("editors/piano.zig");
const spectrum_ed = @import("editors/spectrum.zig");
const arrangement_ed = @import("editors/arrangement.zig");

const Engine = engine_mod.Engine;
const Sampler = ws.dsp.Sampler;
const InstrumentKind = ws.InstrumentKind;
const pattern_mod = ws.dsp.pattern;

pub const note_ms = 220;
/// Rows every view's content starts after in `App.draw`: the header line +
/// the `hr` divider beneath it. Mouse hit-testing subtracts this before
/// handing a row to a view's own handler — see `App.handleMouse`.
pub const content_top: u16 = 2;
const frame_poll_ms = 30;
const cmd_history_cap: usize = 50;
/// Big enough for any real filesystem path; mirrors commands.path_buf_len.
const reload_path_buf_len: usize = 1024;
/// A pause longer than this between taps starts a fresh tap-tempo run.
const tap_timeout_ns: i96 = 2 * std.time.ns_per_s;
/// Minimum gap between silent `<path>~` backups; see `maybeAutosave`.
const autosave_interval_ns: i96 = 30 * std.time.ns_per_s;

pub const AppView = enum { tracks, drum_grid, synth_editor, sampler_editor, help, track_spectrum, master_spectrum, piano_roll, instrument_picker, arrangement, file_browser };

/// Which waveform marker a sampler-editor mouse drag is moving — see
/// `App.sampler_drag_marker` and editors/sampler.zig's handleMouse.
pub const SamplerMarker = enum { start, end };

/// What the shared sampler_editor view is currently editing: one pad of a drum
/// machine, or a standalone Sampler instrument. Holds the track index.
pub const SamplerTarget = union(enum) {
    drum: u16,
    sampler: u16,

    pub fn track(self: SamplerTarget) u16 {
        return switch (self) { .drum => |t| t, .sampler => |t| t };
    }
};

/// The instruments the picker offers, in display order.
pub const picker_kinds = [_]InstrumentKind{ .poly_synth, .sampler, .drum_machine };
pub const picker_labels = [_][]const u8{ "Synth", "Sampler", "Drum Machine" };

/// What a file picked in the netrw-style file browser (`file_browser` view)
/// resolves to once selected. Set by `App.openBrowser`; read by
/// `App.browserActivate`.
pub const BrowserPurpose = union(enum) {
    open_project,
    load_sample,
    load_pad: u8,

    /// The extension the browser filters non-directory entries to (case
    /// insensitive); directories are always shown regardless.
    fn ext(self: BrowserPurpose) []const u8 {
        return switch (self) {
            .open_project => ".wsj",
            .load_sample, .load_pad => ".wav",
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
    active: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
    vel_lo: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
    vel_hi: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
};

/// A visual-mode range yank from the arrangement: deep-copied clips from one
/// lane, with start_bar rebased relative to the selection's first bar. Paste
/// re-targets the cursor bar on the same lane it was copied from.
pub const ArrRangeClip = struct {
    clips: []ws.Clip,
};

/// `.` repeats the last "compound" edit — one where replaying it at a new
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
    arr_move_clip: struct { delta: i32 },
    arr_range_delete: struct { width: u32 },
    arr_range_paste,
};

/// Ableton-style clip editing: while set, the piano roll's pattern player
/// holds a working copy of this arrangement clip and every edit is written
/// straight back into it — the clip owns the data. Identified by track +
/// start bar because clip pointers shift as lanes are edited.
const ClipLink = struct { track: u16, start_bar: u32 };

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ws.Session,
    modal: modal_mod.ModalInput = .{},
    /// Tab-cycle state for command-mode completion; see `TabCycle`/`cycleCompletion`.
    tab_cycle: ?TabCycle = null,
    cursor: usize = 0,
    view: AppView = .tracks,
    prev_view: AppView = .tracks,
    drum_cursor: [2]u8 = .{ 0, 0 },
    /// Track currently shown in the drum_grid view (a drum_machine rack).
    drum_track: u16 = 0,
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
    /// Selected param row within the focused FX unit (EQ's are its bands).
    fx_param: usize = 0,
    /// Which chain unit the spectrum/FX view is focused on — Tab cycles it.
    fx_focus: spectrum_ed.FxUnit = .eq,
    eq_track: u16 = 0,
    /// Scroll offset (in lines) of the help view; clamped by tui.drawHelp.
    help_scroll: usize = 0,
    synth_track: u16 = 0,
    synth_cursor: u8 = 0,
    synth_scroll: usize = 0,
    piano_track: u16 = 0,
    piano_cursor_step: u16 = 0,
    piano_cursor_pitch: u7 = 60,
    piano_scroll_step: u16 = 0,
    piano_scroll_pitch: u7 = 72,
    piano_note_len: f64 = 0.25,
    /// True while `M` holds the piano-roll note under the cursor — h/l/j/k
    /// then drag the note instead of the cursor; esc/M (or any other key)
    /// drop it. See editors/piano.zig.
    piano_grab: bool = false,
    /// Arrangement view: bar cursor and horizontal scroll (lane = `cursor`).
    arr_cursor_bar: u32 = 0,
    arr_scroll_bar: u32 = 0,
    /// Pattern clipboards (y yank / P paste), app-wide so patterns can move
    /// between tracks. Whole-pattern granularity; one slot per editor kind.
    piano_clip: ?PianoClip = null,
    drum_clip: ?DrumMachine.Variant = null,
    /// Arrangement clip clipboard (y/P in the arrangement view). Owns a deep
    /// copy; its start_bar is meaningless — paste re-targets the cursor bar.
    arr_clip: ?ws.Clip = null,
    /// Visual-mode anchors: set to the cursor position when `v` is pressed,
    /// null outside visual mode. The selection is [min(anchor,cursor),
    /// max(anchor,cursor)] on the view's time axis (step / step / bar); see
    /// editors/{piano,drum,arrangement}.zig's handleVisual.
    piano_visual_anchor: ?u16 = null,
    drum_visual_anchor: ?u8 = null,
    arr_visual_anchor: ?u32 = null,
    /// Visual-mode range clipboards (y/d/P while `.visual`), separate from
    /// the whole-pattern/single-clip clipboards above.
    piano_range_clip: ?PianoClip = null,
    drum_range_clip: ?DrumRangeClip = null,
    arr_range_clip: ?ArrRangeClip = null,
    /// `.` repeat target — the last compound edit, app-wide (see RepeatOp).
    last_edit: RepeatOp = .none,
    /// Cumulative (dstep, dpitch) of the current note-drag session (M grab
    /// or a mouse drag), reset when the grab starts, committed to
    /// `last_edit` when it drops. `moved` distinguishes a mouse drag that
    /// never actually left its starting cell (a plain click) from one that
    /// did — see editors/piano.zig's handleMouse.
    piano_grab_delta: struct { dstep: i32 = 0, dpitch: i32 = 0, moved: bool = false } = .{},
    /// In-progress drum-grid mouse paint stroke: the state being painted
    /// (true = activating, false = clearing). Null when no drag is active.
    /// See editors/drum.zig's handleMouse.
    drum_paint_state: ?bool = null,
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
    /// Active `:scale` for the piano roll's scale highlighting and `c`/`C`
    /// chord stamp; null = no scale (dims nothing, chord stamp defaults to a
    /// plain major shape). A monitoring/writing aid, not song content — not
    /// persisted, mirroring `Session.metronome_enabled`.
    piano_scale: ?ws.theory.Scale = null,
    /// Undo/redo history for content edits (u / U in the editing views).
    history: undo_mod.History = .{},
    /// True when the session holds edits the project file doesn't. Set at
    /// every persisted mutation (content edits via history.push, param
    /// nudges, track/mix changes); cleared on save. `:q` refuses while set.
    dirty: bool = false,
    /// Path of the current project file — the default for :w / :wq. Set when
    /// a project is loaded at startup and updated on every successful save.
    project_path_buf: [256]u8 = undefined,
    project_path_len: usize = 0,
    /// Submitted `:` commands, oldest first, for up/down recall in the
    /// command prompt. Capped at `cmd_history_cap`; oldest drops when full.
    cmd_history: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Position while recalling: `cmd_history.items.len` means "not
    /// recalling — the prompt holds a fresh, unsubmitted line".
    cmd_history_pos: usize = 0,
    /// Set by `:e`/`:new` (see `requestReload`) to ask `run()` to swap the
    /// session on the next loop iteration. `run()` — not App — owns the
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
    /// Minimal netrw/dired-style file browser: `:e`, `:load-sample`, and
    /// `:load-pad` open it when called with no path. `browser_dir` is the
    /// canonical (realpath'd) directory currently listed in `browser_entries`
    /// — both are owned and freed together (see `closeBrowser`).
    browser_dir: [:0]const u8 = "",
    browser_entries: std.ArrayListUnmanaged(BrowserEntry) = .empty,
    browser_cursor: usize = 0,
    browser_scroll: usize = 0,
    browser_purpose: BrowserPurpose = .load_sample,

    pub const ReloadRequest = enum { none, blank, load };

    const NoteOff = struct { at_ns: i96, track: u16, note: u7 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !App {
        return .{
            .allocator = allocator,
            .io = io,
            .session = try ws.Session.initDefault(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.arr_clip) |*c| c.deinit(self.allocator);
        if (self.arr_range_clip) |r| {
            for (r.clips) |*c| c.deinit(self.allocator);
            self.allocator.free(r.clips);
        }
        self.freeBrowserEntries();
        self.browser_entries.deinit(self.allocator);
        if (self.browser_dir.len > 0) self.allocator.free(self.browser_dir);
        for (self.cmd_history.items) |s| self.allocator.free(s);
        self.cmd_history.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.session.deinit();
    }

    /// The drum machine currently open in the drum_grid view. Valid only while
    /// `drum_track` points at a drum_machine rack — guaranteed by view entry and
    /// the view-exit guards in `doTrackDel`.
    pub fn drumMachine(self: *App) *DrumMachine {
        return &self.session.racks.items[self.drum_track].instrument.drum_machine;
    }

    /// The sampler currently open in the sampler_editor view (when targeting a
    /// standalone Sampler).
    pub fn editingSampler(self: *App) ?*Sampler {
        const t = switch (self.sampler_target) { .sampler => |x| x, .drum => return null };
        if (t >= self.session.racks.items.len) return null;
        return switch (self.session.racks.items[t].instrument) {
            .sampler => |*s| s, else => null,
        };
    }

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

    pub fn handleKey(self: *App, key_in: modal_mod.Key, now_ns: i96) void {
        self.now_ns = now_ns;
        if (key_in == .ctrl_c) {
            self.should_quit = true;
            return;
        }

        // Command mode: up/down recall history, tab completes the command
        // name. Left/right/home/end/ctrl-w edit the cmd_buf cursor in place
        // (modal.handle owns that state) — passed through as their own
        // variants rather than the hjkl aliasing below, which would insert
        // literal 'h'/'l' characters into the line instead of moving through it.
        if (self.modal.mode == .command) {
            switch (key_in) {
                .arrow_up => { self.commandHistoryPrev(); return; },
                .arrow_down => { self.commandHistoryNext(); return; },
                .arrow_left, .arrow_right, .home, .end, .ctrl_w => { _ = self.modal.handle(key_in); return; },
                .tab => { self.completeCommand(); return; },
                else => {},
            }
        }
        // Everywhere else, arrows are a plain hjkl alias (vim convention) —
        // every view already navigates on h/l/j/k, so this is transparent.
        const key: modal_mod.Key = switch (key_in) {
            .arrow_up => .{ .char = 'k' },
            .arrow_down => .{ .char = 'j' },
            .arrow_left => .{ .char = 'h' },
            .arrow_right => .{ .char = 'l' },
            else => key_in,
        };

        switch (self.view) {
            .help => switch (key) {
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
                    else => {},
                },
                else => {},
            },
            // Editor-handled keys discard any unused count prefix (vim: a
            // count binds to the command it precedes, then dies with it).
            // Normal and visual both route through the editor first (visual
            // reuses its motions and adds range y/d/P); only command mode
            // bypasses it entirely.
            .drum_grid => {
                if (self.modal.mode == .command or !drum_ed.handleKey(self, key)) {
                    self.applyAction(self.modal.handle(key), now_ns);
                } else self.modal.count = 0;
            },
            .synth_editor => if (self.modal.mode == .command or !synth_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .sampler_editor => if (self.modal.mode != .normal or !sampler_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .track_spectrum, .master_spectrum => if (self.modal.mode == .command or !spectrum_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            // Insert mode bypasses the roll's own switch entirely — once
            // inserted, the piano-keyboard layout needs h/j/k/l as notes,
            // not roll navigation, so modal.handle owns every key until
            // escape drops back to normal (see recordNote in editors/piano.zig).
            .piano_roll => if (self.modal.mode == .command or self.modal.mode == .insert or !piano_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .instrument_picker => self.handlePickerKey(key),
            .file_browser => self.handleBrowserKey(key),
            .arrangement => if (self.modal.mode == .command or !arrangement_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .tracks => {
                // The master row lives one slot past the last real track —
                // same list, same cursor, but it can't be deleted/duplicated/
                // moved/renamed/muted/soloed and has no piano roll or pan.
                const on_master = self.cursor == self.session.project.tracks.items.len;
                if (key == .enter and self.modal.mode == .normal) {
                    if (on_master) spectrum_ed.switchToMaster(self) else self.openTrack(self.cursor);
                    return;
                }
                if (key == .char and self.modal.mode == .normal) {
                    if (on_master) {
                        switch (key.char) {
                            's', 'M' => { spectrum_ed.switchToMaster(self); return; },
                            'a' => { self.doTrackAdd(null); return; },
                            'c' => { self.toggleMetronome(); return; },
                            '?' => { commands.cmdHelp(self, ""); return; },
                            '-' => { self.doMasterGainStep(-1.0); return; },
                            '+', '=' => { self.doMasterGainStep(1.0); return; },
                            'u' => { history.doUndo(self); return; },
                            'U' => { history.doRedo(self); return; },
                            't' => { self.tapTempo(now_ns); return; },
                            'D', 'Y', 'J', 'K', 'R', 'p', '<', '>' => {
                                self.setStatus("master bus: n/a", .{});
                                return;
                            },
                            else => {},
                        }
                    } else {
                        switch (key.char) {
                            'M' => { spectrum_ed.switchToMaster(self); self.cursor = self.session.project.tracks.items.len; return; },
                            'A' => { self.view = .arrangement; return; },
                            's' => { spectrum_ed.switchToTrack(self, @intCast(self.cursor)); return; },
                            'p' => { piano_ed.switchTo(self, @intCast(self.cursor)); return; },
                            'a' => { self.doTrackAdd(null); return; },
                            'D' => { self.doTrackDel(self.cursor); return; },
                            'Y' => { self.doTrackDup(self.cursor); return; },
                            'J' => { self.doTrackMove(1); return; },
                            'K' => { self.doTrackMove(-1); return; },
                            'c' => { self.toggleMetronome(); return; },
                            '?' => { commands.cmdHelp(self, ""); return; },
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

    /// Mouse entry point — routed here directly by `run()` rather than
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
            .drum_grid => drum_ed.handleMouse(self, ev, row),
            .synth_editor => synth_ed.handleMouse(self, ev, row),
            .sampler_editor => sampler_ed.handleMouse(self, ev, row, cols, view_rows),
            .piano_roll => piano_ed.handleMouse(self, ev, row, cols),
            .track_spectrum, .master_spectrum => spectrum_ed.handleMouse(self, ev, row, cols, view_rows),
            .arrangement => arrangement_ed.handleMouse(self, ev, row, cols),
            .instrument_picker => self.pickerMouse(ev, row),
            .file_browser => self.browserMouse(ev, row),
            .help => self.helpMouse(ev),
        }
    }

    /// Tracks view: click a row to select + open it (same as Enter); scroll
    /// moves the cursor like j/k. Row-level only: track names are unbounded
    /// width (`"{s: <8}"` pads but never truncates), so a mute/solo column
    /// click zone can't be derived reliably from the track index alone.
    fn tracksMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        switch (ev.kind) {
            .press => {
                const track_count = self.session.project.tracks.items.len;
                if (row == 0 or row > track_count + 1) return; // title row / out of range
                const idx = row - 1;
                self.cursor = idx;
                if (idx == track_count) spectrum_ed.switchToMaster(self) else self.openTrack(idx);
            },
            .scroll_up => self.applyAction(.{ .move = .{ .dy = -1 } }, self.now_ns),
            .scroll_down => self.applyAction(.{ .move = .{ .dy = 1 } }, self.now_ns),
            else => {},
        }
    }

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

    /// Help view: scroll wheel scrolls content (same as j/k). No click behavior.
    fn helpMouse(self: *App, ev: modal_mod.MouseEvent) void {
        switch (ev.kind) {
            .scroll_up => self.help_scroll -|= 1,
            .scroll_down => self.help_scroll += 1,
            else => {},
        }
    }

    /// R opens the command prompt pre-filled with `:track-rename <n> ` for
    /// the cursor track — type the new name and hit enter (`esc` cancels,
    /// same as any other command-mode entry).
    fn startRenamePrompt(self: *App) void {
        if (self.cursor >= self.session.project.tracks.items.len) return;
        self.modal.mode = .command;
        self.cmd_history_pos = self.cmd_history.items.len;
        const text = std.fmt.bufPrint(&self.modal.cmd_buf, "track-rename {d} ", .{self.cursor + 1}) catch return;
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
        if (self.tap_count > 0 and now_ns - self.tap_times[self.tap_count - 1] > tap_timeout_ns) {
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

    /// Open the editor matching the track's instrument, or the instrument
    /// picker if the track is blank.
    fn openTrack(self: *App, cursor: usize) void {
        if (cursor >= self.session.racks.items.len) return;
        switch (self.session.racks.items[cursor].instrument) {
            .empty => { self.picker_cursor = 0; self.view = .instrument_picker; },
            .poly_synth => {
                self.synth_track = @intCast(cursor);
                self.synth_cursor = 0;
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
            },
        }
    }

    /// Instrument picker: j/k move, enter/space insert the highlighted kind on
    /// the cursor track and jump to its editor, esc cancels back to tracks.
    fn handlePickerKey(self: *App, key: modal_mod.Key) void {
        switch (key) {
            .escape => self.view = .tracks,
            .enter => self.pickerInsert(),
            .char => |c| switch (c) {
                'k' => { if (self.picker_cursor > 0) self.picker_cursor -= 1; },
                'j' => { if (self.picker_cursor + 1 < picker_kinds.len) self.picker_cursor += 1; },
                ' ' => self.pickerInsert(),
                'q' => self.view = .tracks,
                else => {},
            },
            else => {},
        }
    }

    fn pickerInsert(self: *App) void {
        const kind = picker_kinds[self.picker_cursor];
        self.session.setInstrument(self.cursor, kind) catch {
            self.setStatus("insert failed (out of memory)", .{});
            self.view = .tracks;
            return;
        };
        self.dirty = true;
        self.setStatus("inserted {s}", .{picker_labels[self.picker_cursor]});
        self.view = .tracks;
        self.openTrack(self.cursor);
    }

    // -----------------------------------------------------------------------
    // File browser (netrw/dired-style; `:e`, `:load-sample`, `:load-pad` with
    // no path open it — see commands.zig)
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
    /// group — matches `ls`/netrw ordering.
    fn browserEntryLess(_: void, a: BrowserEntry, b: BrowserEntry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir;
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    /// j/k move, enter/l/space descend into a dir or pick a file, h/backspace
    /// go to the parent dir, g/G jump to the list ends, `~` jumps home,
    /// esc/q cancel back to the view that opened the browser.
    fn handleBrowserKey(self: *App, key: modal_mod.Key) void {
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
                    const home = std.mem.sliceTo(std.c.getenv("HOME") orelse return, 0);
                    self.setBrowserDir(home) catch |e| self.setStatus("browse: {s}", .{@errorName(e)});
                },
                'q' => self.closeBrowser(),
                else => {},
            },
            else => {},
        }
    }

    /// Parent of `browser_dir` (root's parent is itself — nothing to go up to).
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
            .open_project => self.requestReload(joined),
            .load_sample => commands.loadSampleFromPath(self, joined),
            .load_pad => |pad| commands.loadPadFromPath(self, pad, joined),
        }
        self.closeBrowser();
    }

    fn closeBrowser(self: *App) void {
        self.freeBrowserEntries();
        self.view = self.prev_view;
    }

    /// Track that mute/solo/note-preview act on outside the tracks view —
    /// the track whose editor is actually open, not the (possibly stale)
    /// tracks-view cursor. Keep this in sync with every per-track editor;
    /// missing a view here means mute/solo/preview silently hit the wrong
    /// track whenever that view's own track diverges from `self.cursor`.
    fn currentTrack(self: *App) u16 {
        return switch (self.view) {
            .synth_editor   => self.synth_track,
            .piano_roll     => self.piano_track,
            .drum_grid      => self.drum_track,
            .sampler_editor => self.sampler_target.track(),
            .track_spectrum => self.eq_track,
            else            => @intCast(self.cursor),
        };
    }

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
                if (m == .command) self.cmd_history_pos = self.cmd_history.items.len;
            },
            .move => |m| {
                const count: i64 = @as(i64, @intCast(self.cursor)) + m.dy;
                // One extra slot past the last real track — the master row.
                const last: i64 = @intCast(self.session.project.tracks.items.len);
                self.cursor = @intCast(std.math.clamp(count, 0, last));
            },
            .goto_start => _ = self.session.engine.send(.{ .seek_frames = 0 }),
            .toggle_play => {
                const cmd: engine_mod.Command = if (self.session.engine.uiSnapshot().playing) .stop else .play;
                _ = self.session.engine.send(cmd);
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
            },
            .note => |n| {
                const track_idx = self.currentTrack();
                if (track_idx >= self.session.racks.items.len) return;
                switch (self.session.racks.items[track_idx].instrument) {
                    .drum_machine => _ = self.session.engine.send(.{ .note_on = .{
                        .track = track_idx,
                        .note = @intCast(n.pitch % DrumMachine.max_pads),
                        .velocity = 0.9,
                    } }),
                    .poly_synth, .sampler => {
                        self.playNote(track_idx, n.pitch, now_ns);
                        if (self.view == .piano_roll) piano_ed.recordNote(self, n.pitch);
                    },
                    .empty => {},
                }
            },
            .command_submit => |text| {
                self.pushCommandHistory(text);
                commands.run(self, text);
            },
        }
    }

    /// Record a submitted `:` command for later up/down recall. Skips blanks
    /// and immediate repeats (shell-history convention); drops the oldest
    /// entry once at capacity.
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
    }

    /// Step back to the previous history entry.
    fn commandHistoryPrev(self: *App) void {
        if (self.cmd_history.items.len == 0 or self.cmd_history_pos == 0) return;
        self.cmd_history_pos -= 1;
        self.loadCommandHistory();
    }

    /// Step forward through history; past the newest entry, blank the
    /// prompt (mirrors shell history — you're back to a fresh line).
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
    /// (`stem` — the text the user actually typed, *not* whatever
    /// candidate is currently sitting in cmd_buf), where the completed
    /// value starts (`insert_at`), and the exact candidate text last
    /// written there (`last_written`, always a static string from a
    /// command/preset/kit table, so storing the slice directly rather than
    /// copying it is safe across calls). `cycleCompletion` only continues
    /// the cycle — advancing `index` and reusing `stem` — when cmd_buf
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

        const Source = enum { command_name, drum_kit, synth_preset, metronome, master_comp };

        fn stem(self: *const TabCycle) []const u8 {
            return self.stem_buf[0..self.stem_len];
        }
    };

    /// Tab-completes the command name (before the first space), or — for a
    /// handful of commands whose values come from a small fixed set — the
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

        var name_buf: [commands.cmds.len][]const u8 = undefined;
        for (commands.cmds, 0..) |c, i| name_buf[i] = c.name;
        self.cycleCompletion(0, buf, .command_name, &name_buf);
    }

    /// Tab-completes the argument after `buf[0..name_end]` against a small
    /// fixed value set — drum-kit/synth-preset names, and metronome/
    /// master-comp's on/off (and sub-parameter) keywords. Only fires for the
    /// *first* argument token (a trailing space means a second argument is
    /// being typed, which has no fixed candidate list here); every other
    /// command's arguments (track numbers, dB values, paths, ...) aren't
    /// completable from a fixed list, so this is a no-op for those.
    fn completeArgument(self: *App, buf: []const u8, name_end: usize) void {
        const name = buf[0..name_end];
        const arg = buf[name_end + 1 ..];
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) return;

        var name_buf: [24][]const u8 = undefined;
        if (std.mem.eql(u8, name, "drum-kit")) {
            var n: usize = 0;
            for (ws.dsp.drum_kit.variants) |v| {
                name_buf[n] = v.name;
                n += 1;
            }
            self.cycleCompletion(name_end + 1, arg, .drum_kit, name_buf[0..n]);
        } else if (std.mem.eql(u8, name, "synth-preset")) {
            var n: usize = 0;
            for (ws.dsp.synth_presets.presets) |p| {
                name_buf[n] = p.name;
                n += 1;
            }
            self.cycleCompletion(name_end + 1, arg, .synth_preset, name_buf[0..n]);
        } else if (std.mem.eql(u8, name, "metronome")) {
            self.cycleCompletion(name_end + 1, arg, .metronome, &.{ "on", "off" });
        } else if (std.mem.eql(u8, name, "master-comp")) {
            self.cycleCompletion(name_end + 1, arg, .master_comp, &.{ "on", "off", "thresh", "ratio", "attack", "release", "makeup" });
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
    /// over — no separate reset wiring needed). A single match always
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
            // Fresh stem — snapshot `current_text` before cmd_buf gets
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

    /// Which match `draw`'s command-name suggestion popup should highlight:
    /// the in-progress Tab-cycle's index if `cmd_buf` still holds exactly
    /// what that cycle last wrote there (same check `cycleCompletion` uses
    /// to decide whether to continue a cycle), otherwise 0 — the top match,
    /// matching Neovim's wildmenu highlighting the first candidate before
    /// Tab has ever been pressed.
    fn suggestionSelected(self: *const App) usize {
        if (self.tab_cycle) |tc| {
            if (tc.insert_at == 0 and tc.source == .command_name and
                std.mem.eql(u8, tc.last_written, self.modal.cmd_buf[0..self.modal.cmd_len]))
            {
                return tc.index;
            }
        }
        return 0;
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

    /// Every `autosave_interval_ns`, if there are unsaved changes and the
    /// project has a known path, silently write a `<path>~` backup — a
    /// safety net, not a real save: it doesn't clear `dirty` or touch the
    /// primary file, so `:q` still guards the actual edits. A brand-new
    /// project with no path yet has nowhere natural to back up next to, so
    /// it's skipped until the first `:w`. Failures are silent (best-effort);
    /// a status message every 30s would just be noise during active work.
    fn maybeAutosave(self: *App, now_ns: i96) void {
        if (!self.dirty) return;
        if (now_ns - self.last_autosave_ns < autosave_interval_ns) return;
        self.last_autosave_ns = now_ns;
        const path = self.projectPath() orelse return;
        var buf: [reload_path_buf_len]u8 = undefined;
        const backup = std.fmt.bufPrint(&buf, "{s}~", .{path}) catch return;
        ws.persist.save(self.allocator, &self.session, self.io, backup) catch {};
    }

    // -----------------------------------------------------------------------
    // Track add / delete internals
    // -----------------------------------------------------------------------

    pub fn doTrackAdd(self: *App, name_arg: ?[]const u8) void {
        var name_buf: [32]u8 = undefined;
        const name: []const u8 = name_arg orelse std.fmt.bufPrint(
            &name_buf, "track {d}", .{self.session.project.tracks.items.len},
        ) catch "track";

        const idx = self.session.addTrack(name) catch |err| {
            if (err == error.TrackLimitReached)
                self.setStatus("track limit reached", .{})
            else
                self.setStatus("out of memory", .{});
            return;
        };
        self.cursor = @intCast(idx);
        self.dirty = true;
        self.setStatus("added \"{s}\" (track {d})", .{ name, idx + 1 });
    }

    pub fn doTrackDel(self: *App, track_idx: usize) void {
        self.session.deleteTrack(track_idx) catch {
            self.setStatus("cannot delete the last track", .{});
            return;
        };

        // Shift the editor-target indices that sit after the removed track.
        if (track_idx < self.synth_track and self.synth_track > 0) self.synth_track -= 1;
        if (track_idx < self.drum_track and self.drum_track > 0) self.drum_track -= 1;
        if (track_idx < self.piano_track and self.piano_track > 0) self.piano_track -= 1;
        if (track_idx < self.eq_track and self.eq_track > 0) self.eq_track -= 1;
        if (self.piano_clip_link) |link| {
            if (link.track == track_idx) {
                self.piano_clip_link = null;
            } else if (link.track > track_idx) {
                self.piano_clip_link.?.track -= 1;
            }
        }
        // Track indices shifted: history entries would restore into the
        // wrong track. Starting fresh beats remapping every entry.
        self.history.deinit(self.allocator);
        self.history = .{};
        switch (self.sampler_target) {
            .drum    => |*t| if (track_idx < t.* and t.* > 0) { t.* -= 1; },
            .sampler => |*t| if (track_idx < t.* and t.* > 0) { t.* -= 1; },
        }

        // Keep cursor in bounds.
        const last = self.session.project.tracks.items.len - 1;
        self.cursor = @min(self.cursor, last);

        // Exit any editor whose target track no longer holds the expected kind.
        self.exitStaleEditors();

        self.dirty = true;
        self.setStatus("deleted track {d}", .{track_idx + 1});
    }

    /// After a structural change (delete), bail out of any per-instrument editor
    /// whose target track is gone or holds a different instrument.
    fn exitStaleEditors(self: *App) void {
        const racks = self.session.racks.items;
        const kindIs = struct {
            fn f(rs: []const *@import("wstudio").Rack, t: u16, comptime tag: anytype) bool {
                return t < rs.len and std.meta.activeTag(rs[t].instrument) == tag;
            }
        }.f;

        switch (self.view) {
            .synth_editor => if (!kindIs(racks, self.synth_track, .poly_synth)) { self.view = .tracks; },
            .drum_grid => if (!kindIs(racks, self.drum_track, .drum_machine)) { self.view = .tracks; },
            .sampler_editor => {
                const ok = switch (self.sampler_target) {
                    .drum => |t| kindIs(racks, t, .drum_machine),
                    .sampler => |t| kindIs(racks, t, .sampler),
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
            else => {},
        }
    }

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
    /// refers to, so remap the former and — same call as doTrackDel — drop
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

        const swap = struct {
            fn f(idx: *u16, a: usize, b: usize) void {
                if (idx.* == a) idx.* = @intCast(b) else if (idx.* == b) idx.* = @intCast(a);
            }
        }.f;
        swap(&self.synth_track, cur, other);
        swap(&self.drum_track, cur, other);
        swap(&self.piano_track, cur, other);
        swap(&self.eq_track, cur, other);
        switch (self.sampler_target) {
            .drum => |*t| swap(t, cur, other),
            .sampler => |*t| swap(t, cur, other),
        }
        if (self.piano_clip_link) |*link| {
            if (link.track == cur) link.track = @intCast(other)
            else if (link.track == other) link.track = @intCast(cur);
        }
        self.history.deinit(self.allocator);
        self.history = .{};

        self.cursor = other;
        self.dirty = true;
        self.setStatus("moved track {d} {s}", .{ cur + 1, if (dir < 0) "up" else "down" });
    }

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

    fn doTrackGainStep(self: *App, track: u16, delta_db: f32) void {
        if (track >= self.session.project.tracks.items.len) return;
        const t = &self.session.project.tracks.items[track];
        t.gain_db = std.math.clamp(t.gain_db + delta_db, -60.0, 12.0);
        self.dirty = true;
        _ = self.session.engine.send(.{ .set_track_gain = .{ .track = track, .gain = types.dbToGain(t.gain_db) } });
        const sign: []const u8 = if (t.gain_db >= 0) "+" else "";
        self.setStatus("track {d} gain: {s}{d:.1}dB", .{ track + 1, sign, t.gain_db });
    }

    /// `-`/`+` on the master row — same gesture as a track's gain step, but
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

    /// Ask `run()` to load `path` (or start a blank session when null) on
    /// its next loop iteration — see the field doc on `pending_reload`.
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

    pub fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.status_buf, fmt, args) catch &self.status_buf;
        self.status_len = msg.len;
        self.status_ttl = 100;
    }

    // -----------------------------------------------------------------------
    // Rendering (delegates to tui.zig)
    // -----------------------------------------------------------------------

    pub fn draw(self: *App, w: *std.Io.Writer, size: terminal_mod.Size) !void {
        const snap = self.session.engine.uiSnapshot();
        const rows: usize = @max(size.rows, 10);

        // Command-mode's Tab-completion popup (see cmd.writeSuggestionBox)
        // sits directly above the `:` prompt, drawn after the transport
        // line's closing hr below. Carve its rows out of the content area's
        // budget up front so the frame never grows taller than the terminal.
        const max_suggestion_rows = 10;
        const suggestion_rows: usize = if (self.modal.mode == .command)
            cmd_mod.suggestionRows(commands.cmds, self.modal.cmd_buf[0..self.modal.cmd_len], max_suggestion_rows)
        else
            0;
        const content_rows = rows -| suggestion_rows;

        try w.writeAll("\x1b[H");
        try tui.drawHeader(w, &self.session.project, &self.session.engine.transport, self.audio_label, self.master_gain_db, self.dirty);
        try tui.hr(w, size.cols);

        switch (self.view) {
            .tracks          => try tui.drawTracks(self, w, content_rows, snap),
            .drum_grid       => try tui.drawDrumGrid(self, w, content_rows, snap),
            .synth_editor    => try tui.drawSynthEditor(self, w, content_rows, snap),
            .sampler_editor  => try tui.drawSamplerEditor(self, w, content_rows, size.cols, snap),
            .piano_roll      => try tui.drawPianoRoll(self, w, content_rows, size.cols, snap),
            .help            => try tui.drawHelp(w, content_rows, commands.cmds, &self.help_scroll),
            .track_spectrum  => try tui.drawSpectrumView(self, w, content_rows, size.cols, snap, true),
            .master_spectrum => try tui.drawSpectrumView(self, w, content_rows, size.cols, snap, false),
            .instrument_picker => try tui.drawInstrumentPicker(self, w, content_rows),
            .arrangement     => try tui.drawArrangement(self, w, content_rows, size.cols, snap),
            .file_browser    => try tui.drawFileBrowser(self, w, content_rows),
        }

        var transport: Transport = .{
            .sample_rate = self.session.project.sample_rate,
            .tempo_bpm = self.session.project.tempo_bpm,
            .position_frames = snap.position_frames,
        };
        const pos = transport.positionBarBeat();
        const secs = transport.positionSeconds();
        if (snap.playing) {
            if (icons.font_installed) {
                try w.writeAll("\x1b[32m\x1b[1m " ++ icons.play ++ "\x1b[0m");
            } else {
                try w.writeAll("\x1b[32m\x1b[1m |>\x1b[0m");
            }
        } else {
            if (icons.font_installed) {
                try w.writeAll("\x1b[2m " ++ icons.stop ++ "\x1b[0m");
            } else {
                try w.writeAll("\x1b[2m []\x1b[0m");
            }
        }
        if (self.session.metronome_enabled) {
            try w.writeAll(" \x1b[33m" ++ icons.tempo ++ " click\x1b[0m");
        }
        try w.print(" {d:0>3}.{d}  {d:0>2}:{d:0>4.1}  \x1b[2mL\x1b[0m", .{
            pos.bar + 1,
            pos.beat + 1,
            @as(u64, @intFromFloat(secs / 60.0)),
            @mod(secs, 60.0),
        });
        try tui.meter(w, snap.peak[0]);
        try w.writeAll("\x1b[2m R\x1b[0m");
        try tui.meter(w, snap.peak[1]);
        try tui.endLine(w);
        try tui.hr(w, size.cols);

        if (suggestion_rows > 0) {
            try cmd_mod.writeSuggestionBox(
                w,
                commands.cmds,
                self.modal.cmd_buf[0..self.modal.cmd_len],
                self.suggestionSelected(),
                max_suggestion_rows,
            );
        }

        switch (self.view) {
            .tracks          => try tui.drawTracksStatus(self, w, commands.cmds),
            .drum_grid       => try tui.drawDrumStatus(self, w, commands.cmds),
            .synth_editor    => try tui.drawSynthStatus(self, w, commands.cmds),
            .sampler_editor  => try tui.drawSamplerStatus(self, w, commands.cmds),
            .piano_roll      => try tui.drawPianoRollStatus(self, w, commands.cmds),
            .help            => try w.writeAll(" j/k: scroll   d/u: page   g/G: top/bottom   esc: close"),
            .track_spectrum  => try tui.drawSpectrumStatus(self, w, true, commands.cmds),
            .master_spectrum => try tui.drawSpectrumStatus(self, w, false, commands.cmds),
            .instrument_picker => try w.writeAll(" j/k: move   enter: insert   esc: cancel"),
            .arrangement     => try tui.drawArrangementStatus(self, w, commands.cmds),
            .file_browser    => try tui.drawFileBrowserStatus(self, w),
        }
        // Erase from cursor to end of screen so stale content from taller
        // previous frames never bleeds through.
        try w.writeAll("\x1b[K\x1b[J");
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

pub fn run(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8) !void {
    var term = terminal_mod.Terminal.init(io) catch {
        std.debug.print(
            "wstudio: stdin is not a terminal (try `wstudio render` for the offline demo)\n",
            .{},
        );
        return;
    };
    defer term.deinit();

    var app = try App.init(allocator, io);
    defer app.deinit();
    icons.font_installed = icons.detectFontInstalled(io);

    // Load project file before backends start — the backend captures the engine
    // pointer at init, so the swap must happen here.
    if (init_path) |p| {
        if (ws.persist.load(allocator, io, p)) |loaded| {
            app.session.deinit();
            app.session = loaded;
            app.setProjectPath(p);
        } else |e| {
            std.debug.print("wstudio: cannot load '{s}': {s}\n", .{ p, @errorName(e) });
        }
    }

    var config: backend_mod.Config = .{ .sample_rate = app.session.project.sample_rate };

    const has_alsa = builtin.os.tag == .linux;
    const AlsaBackend = if (has_alsa) ws.alsa.AlsaBackend else void;
    const MidiIn     = if (has_alsa) ws.midi_in.MidiIn else void;
    var alsa_backend: AlsaBackend = undefined;
    var midi_in:     MidiIn       = undefined;
    var null_backend = backend_mod.NullBackend{
        .config = config,
        .render = renderTrampoline,
        .ctx = app.session.engine,
    };

    var using_alsa = false;
    var using_midi = false;
    if (has_alsa) {
        alsa_backend = .{ .config = config, .render = renderTrampoline, .ctx = app.session.engine };
        if (alsa_backend.start()) {
            using_alsa = true;
        } else |_| {}

        midi_in = .{ .engine = app.session.engine };
        if (midi_in.start()) {
            using_midi = true;
        } else |_| {}
    }
    if (!using_alsa) try null_backend.start(io);
    defer if (using_alsa) alsa_backend.stop() else null_backend.stop();
    defer if (using_midi) midi_in.stop();
    app.audio_label = if (using_alsa) "alsa" else "none (silent)";

    var frame_buf: [32 * 1024]u8 = undefined;
    var input_buf: [128]u8 = undefined;
    var keys: [64]modal_mod.Key = undefined;

    while (!app.should_quit) {
        const bytes = try term.readInput(&input_buf, frame_poll_ms);
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

        // :e / :new asked for a session swap. Build the replacement first
        // (control-thread only, no backend involved) so a bad path or OOM
        // just reports an error and leaves the running session untouched;
        // only stop the backend once we actually have something to swap in
        // — it holds a raw *Engine pointer captured at start (or the last
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
                .load => blk: {
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
                if (using_alsa) alsa_backend.stop() else null_backend.stop();
                if (using_midi) midi_in.stop();

                app.session.deinit();
                app.session = loaded;
                switch (kind) {
                    .load => app.setProjectPath(app.pendingReloadPath()),
                    .blank => app.project_path_len = 0,
                    .none => unreachable,
                }

                config = .{ .sample_rate = app.session.project.sample_rate };
                null_backend = .{ .config = config, .render = renderTrampoline, .ctx = app.session.engine };
                using_alsa = false;
                using_midi = false;
                if (has_alsa) {
                    alsa_backend = .{ .config = config, .render = renderTrampoline, .ctx = app.session.engine };
                    if (alsa_backend.start()) { using_alsa = true; } else |_| {}
                    midi_in = .{ .engine = app.session.engine };
                    if (midi_in.start()) { using_midi = true; } else |_| {}
                }
                // A restart failure here just leaves the session silent
                // rather than tearing down the whole running app.
                if (!using_alsa) null_backend.start(io) catch {};
                app.audio_label = if (using_alsa) "alsa" else "none (silent)";
                switch (kind) {
                    .load => app.setStatus("loaded: {s}", .{app.projectPath().?}),
                    .blank => app.setStatus("new project", .{}),
                    .none => unreachable,
                }
            }
        }

        // MIDI input follows the TUI cursor so live playing always targets the
        // currently selected track. Written from the UI thread, read (monotonic)
        // in the MIDI reader thread.
        if (using_midi) midi_in.active_track.store(@intCast(app.cursor), .monotonic);

        var w = std.Io.Writer.fixed(&frame_buf);
        app.draw(&w, term.size()) catch {};
        term.write(w.buffered());
    }
}

// ---------------------------------------------------------------------------
// Tests — integration tests live in app_tests.zig
// ---------------------------------------------------------------------------

test {
    _ = @import("app_tests.zig");
}

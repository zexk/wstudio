//! The frontend-agnostic application core: view/modal state, key and mouse
//! dispatch, track add/delete, session lifecycle, and the Lua host hooks.
//! Both frontends embed this App - the TUI's terminal loop and frame
//! rendering live in tui/tui.zig, the GUI's in gui/gui.zig. Per-view
//! input is in editors/<name>.zig, undo glue in history.zig, the
//! `:command` layer in commands.zig, and the integration tests in
//! tui/app_tests.zig.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const modal_mod = ws.input;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const Slicer = ws.dsp.Slicer;
const commands = @import("commands.zig");
const commands_tracks = @import("commands_tracks.zig");
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
const spectrum_ed = @import("editors/fx_editor.zig");
const arrangement_ed = @import("editors/arrangement.zig");
const automation_ed = @import("editors/automation.zig");
const preset_ed = @import("editors/preset_picker.zig");
const user_presets = @import("user_presets.zig");
const user_drum_kits = @import("user_drum_kits.zig");
const cmd_history_store = @import("cmd_history_store.zig");
const bookmark_store = @import("bookmark_store.zig");
const recent_project_store = @import("recent_project_store.zig");
const fuzzy = @import("fuzzy.zig");
const waveform = @import("waveform.zig");
const ansi = @import("ansi.zig");
const help = @import("help.zig");
const app_browser = @import("app_browser.zig");
const app_completion = @import("app_completion.zig");
const app_api = @import("app_api.zig");
const RecordingTake = @import("recording_take.zig").RecordingTake;

const Engine = engine_mod.Engine;
const Sampler = ws.dsp.Sampler;
const InstrumentKind = ws.InstrumentKind;
const pattern_mod = ws.dsp.pattern;

pub fn copyTruncated(dst: []u8, src: []const u8) usize {
    const len = @min(dst.len, src.len);
    @memcpy(dst[0..len], src[0..len]);
    return len;
}

/// Default note-preview release time (`note_preview_ms` option); the field
/// default below and `tui/app_tests.zig`'s note-off timing test both key off
/// this constant.
pub const note_ms = 220;
/// Rows every view's content starts after in `App.draw`: the header line,
/// and nothing else. Mouse hit-testing subtracts this before handing a row
/// to a view's own handler - see `App.handleMouse`.
///
/// This was 2 for the header plus the `hr` divider that used to sit under
/// it; 5a7e815 folded the divider away and reclaimed the row without
/// updating this, so every TUI click landed one row above the cell clicked
/// (clicking the master row opened track 1, clicking the first track row
/// did nothing). The mouse tests all phrase their coordinates as
/// `content_top + n`, so they moved with the bug instead of catching it -
/// tui/app_tests.zig now pins the constant against a real rendered frame.
pub const content_top: u16 = 1;
/// Big enough for any real filesystem path; mirrors commands.path_buf_len.
pub const reload_path_buf_len: usize = 1024;
/// A pause longer than this between taps starts a fresh tap-tempo run.
/// Minimum gap between silent `<path>~` backups; see `maybeAutosave`.
const default_autosave_interval_ns: i96 = 30 * std.time.ns_per_s;
pub const AppView = enum { tracks, drum_grid, synth_editor, sampler_editor, help, track_spectrum, master_spectrum, group_spectrum, piano_roll, instrument_picker, fx_picker, arrangement, file_browser, automation, automation_param_picker, slicer_grid, preset_picker, soundfont_editor };
pub const InputMonitor = enum { off, auto, on };

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

pub const InstrumentPickerItem = struct { kind: InstrumentKind, label: []const u8, description: []const u8 };

/// The instruments the picker offers, in display order. Renderers add their
/// own casing, icon, and color treatment to this shared content.
pub const instrument_picker_items = [_]InstrumentPickerItem{
    .{ .kind = .poly_synth, .label = "Synth", .description = "Synthesis, polyphony, and modulation" },
    .{ .kind = .sampler, .label = "Sampler", .description = "Chromatic sample playback and envelopes" },
    .{ .kind = .drum_machine, .label = "Drum Machine", .description = "Pads, velocity, and step sequencing" },
    .{ .kind = .slicer, .label = "Slicer", .description = "Sample slicing and chop sequencing" },
    .{ .kind = .acoustic, .label = "Acoustic", .description = "Bundled piano, harpsichord, mallet, and harp banks" },
    .{ .kind = .soundfont, .label = "SoundFont", .description = "Presets from a .sf2 bank you load" },
};

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

    /// Extensions the browser filters non-directory entries to (case
    /// insensitive); directories are always shown regardless. Everything
    /// `core/audio_file.zig` decodes is offered, since a sample is a sample
    /// whatever container it arrived in.
    pub fn extensions(self: BrowserPurpose) []const []const u8 {
        return switch (self) {
            .open_project => &.{".wsj"},
            .load_sample, .load_pad, .load_clip, .load_slice, .load_wavetable => &.{
                ".wav",  ".flac", ".aiff", ".aif",
                ".ogg",  ".oga",  ".opus", ".mp3",
                ".caf",  ".w64",  ".rf64", ".au",
                ".aifc", ".voc",
            },
            .load_soundfont => &.{".sf2"},
        };
    }

    /// Whether `name` passes the filter for this purpose.
    pub fn accepts(self: BrowserPurpose, name: []const u8) bool {
        for (self.extensions()) |candidate| {
            if (std.ascii.endsWithIgnoreCase(name, candidate)) return true;
        }
        return false;
    }

    /// Short description of the filter, for browser headers and messages -
    /// the audio list is far too long to spell out.
    pub fn extLabel(self: BrowserPurpose) []const u8 {
        return switch (self) {
            .open_project => ".wsj",
            .load_sample, .load_pad, .load_clip, .load_slice, .load_wavetable => "audio",
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

    pub fn displayLabel(self: BrowserPurpose, buf: []u8) []const u8 {
        var label_buf: [40]u8 = undefined;
        const purpose_label = self.label(&label_buf);
        return std.fmt.bufPrint(buf, "{s} ({s})", .{ purpose_label, self.extLabel() }) catch purpose_label;
    }

    pub fn canAudition(self: BrowserPurpose) bool {
        return switch (self) {
            .load_sample, .load_pad, .load_clip, .load_slice, .load_wavetable => true,
            .open_project, .load_soundfont => false,
        };
    }

    pub fn canMultiSelect(self: BrowserPurpose) bool {
        return self == .load_pad;
    }
};

/// One directory entry as listed by the file browser. `name` is owned
/// (allocator-dup'd from the raw `Io.Dir.Entry`, which is only valid until
/// the next iterator step).
pub const BrowserEntry = struct {
    name: []u8,
    is_dir: bool,
};

test "browser capabilities match selected file type" {
    const sample: BrowserPurpose = .load_sample;
    const project: BrowserPurpose = .open_project;
    const soundfont: BrowserPurpose = .load_soundfont;
    try std.testing.expect(sample.canAudition());
    try std.testing.expect(!project.canAudition());
    try std.testing.expect(!soundfont.canAudition());
    try std.testing.expect((BrowserPurpose{ .load_pad = 0 }).canMultiSelect());
    const clip: BrowserPurpose = .load_clip;
    try std.testing.expect(!clip.canMultiSelect());
}

test "browser purpose display label includes what it accepts" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("load pad 4 (audio)", (BrowserPurpose{ .load_pad = 3 }).displayLabel(&buf));
    const project: BrowserPurpose = .open_project;
    try std.testing.expectEqualStrings("open project (.wsj)", project.displayLabel(&buf));
}

test "browser purpose accepts every audio container, whatever the case" {
    const sample: BrowserPurpose = .load_sample;
    try std.testing.expect(sample.accepts("kick.wav"));
    try std.testing.expect(sample.accepts("PAD.FLAC"));
    try std.testing.expect(sample.accepts("vox.Opus"));
    try std.testing.expect(!sample.accepts("notes.txt"));
    try std.testing.expect(!sample.accepts("song.wsj"));
    // A project browser stays narrow: audio is not a project.
    const project: BrowserPurpose = .open_project;
    try std.testing.expect(!project.accepts("kick.wav"));
    try std.testing.expect(project.accepts("song.wsj"));
}

/// One yanked piano-roll pattern: a private copy of the notes + loop length.
pub const PianoClip = struct {
    notes: [pattern_mod.max_notes]pattern_mod.Note,
    count: u16,
    length_beats: f64,
};

/// A visual-mode range yank from a step grid - the drum machine's pads or
/// the slicer's slices, which are the same 64-row grid over the same note
/// storage: one step-range's worth of active/velocity bits across every row,
/// rebased so the selection's first step becomes bit 0. Paste places it
/// starting at the cursor step. Heap-owned and sized to the yanked range's
/// actual width (word `i / 64`, bit `i % 64` of `active[row]` is step
/// `lo + i`) - neither machine's step storage has a 64-step ceiling any more,
/// so the clipboard doesn't clamp range width either (see
/// step_grid.yankRangeDyn/pasteRangeDyn).
pub const StepRangeClip = struct {
    width: u16,
    /// The row band the yank covered, inclusive. `v` (blockwise) narrows it
    /// to the rows between the row anchor and the cursor; `V` (linewise)
    /// spans every row. Only this band is allocated, and only it is freed.
    row_lo: u8 = 0,
    row_hi: u8 = DrumMachine.max_pads - 1,
    active: [DrumMachine.max_pads][]u64,
    /// Per-step velocity within the yanked range (index = step - range
    /// start), one heap-owned `width`-long slice per row.
    vel: [DrumMachine.max_pads][]u8,

    pub fn deinit(self: *const StepRangeClip, allocator: std.mem.Allocator) void {
        for (self.row_lo..@as(usize, self.row_hi) + 1) |row| {
            allocator.free(self.active[row]);
            allocator.free(self.vel[row]);
        }
    }
};

/// A visual-mode range yank from the arrangement: deep-copied clips with
/// start_bar rebased relative to the selection's first bar. `lane_offsets`
/// runs parallel to `clips`, holding each one's lane relative to the
/// selection's topmost lane, so a `V` (linewise) yank of a 4-bar block
/// across every track pastes back with its lanes intact. A `v` (blockwise)
/// yank pastes with its top lane on the cursor lane; a linewise one keeps
/// its own absolute lanes, the same rule the step grids use (see
/// `step_grid.pasteBaseRow`).
pub const ArrRangeClip = struct {
    clips: []ws.Clip,
    lane_offsets: []u16,
    width_ticks: u32,
    /// Topmost lane the yank came from, and how many lanes it spanned.
    lane_lo: u16 = 0,
    lane_span: u16 = 1,

    pub fn deinit(self: *const ArrRangeClip, allocator: std.mem.Allocator) void {
        for (self.clips) |*c| c.deinit(allocator);
        allocator.free(self.clips);
        allocator.free(self.lane_offsets);
    }
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
    piano_nudge_note_field: struct { field: ws.dsp.pattern.NoteField, delta: f32 },
    piano_resize: struct { delta: f64 },
    piano_drag: struct { dstep: i32, dpitch: i32 },
    piano_range_delete: struct { width: u16 },
    piano_range_paste,
    drum_range_delete: struct { width: u16 },
    drum_range_paste,
    slicer_range_delete: struct { width: u16 },
    slicer_range_paste,
    arr_move_clip: struct { delta: i32 },
    arr_resize_clip: struct { delta: i32 },
    arr_range_delete: struct { width: u32 },
    arr_range_paste: struct { insert: bool },
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
    /// (drawDrumGrid updates it; step_count can exceed a terminal's width).
    drum_step_scroll: u32 = 0,
    drum_grid: GridDivision = .sixteenth,
    /// Track currently shown in the drum_grid view (a drum_machine rack).
    drum_track: u16 = 0,
    /// [slice, step] cursor for the slicer_grid view - same shape and width
    /// as `drum_cursor` now that the slicer's step index is a u16 too.
    slicer_cursor: [2]u16 = .{ 0, 0 },
    /// First visible step column, cursor-follow - same convention as
    /// `drum_step_scroll`.
    slicer_step_scroll: u32 = 0,
    /// The slicer grid's own zoom, same as `drum_grid` (`z`/`Z` step it, and
    /// the machine's `steps_per_beat` follows).
    slicer_grid: GridDivision = .sixteenth,
    /// Track currently shown in the slicer_grid view (a slicer rack).
    slicer_track: u16 = 0,
    /// What the sampler_editor view edits: a drum pad or a standalone Sampler.
    sampler_target: SamplerTarget = .{ .drum = 0 },
    /// Selected param row in the sampler editor (0..param_count-1). For a drum
    /// pad the edited pad is `drum_cursor[0]`, shared with the drum grid.
    sampler_param: u8 = 0,
    /// Where esc/e leaves the sampler editor: the view that opened it. A pad
    /// panel is reachable both from the tracks view (enter) and from the grid
    /// that sequences it (e), and each should back out where it came from.
    /// Set by every site that switches to `.sampler_editor`.
    sampler_return: AppView = .tracks,
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
    /// Record only inside the arrangement A/B bounds. Recording aid, not
    /// project content, like count-in and metronome state.
    punch_enabled: bool = false,
    /// Loop start captured when the current record pass began. Non-null also
    /// marks a punch pass while loop wrapping is temporarily disabled.
    recording_punch_start_bar: ?u32 = null,
    recording_punch_end_bar: ?u32 = null,
    /// Loop bounds captured when an audio record pass starts with A/B looping
    /// enabled. Captured PCM is split into one alternate take per loop span.
    recording_loop_start_bar: ?u32 = null,
    recording_loop_end_bar: ?u32 = null,
    /// Audio-input capture for record-armed Sampler tracks (see
    /// `Session.isAudioArmed`). Opened only for the duration of a record
    /// pass by `startPendingRecording`, closed by `finishRecording` -
    /// never held open otherwise.
    audio_input: ws.AudioInput = .{},
    input_monitor: InputMonitor = .auto,
    /// Backend-native capture device name. Empty selects the system default.
    audio_input_device: config_mod.PathBuf = .{},
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
    /// Disk-backed active take. File remains in `.wstudio-recovery` after a
    /// crash and carries a valid WAV header after every drained block.
    recording_take: ?RecordingTake = null,
    recording_dropout_frames: u64 = 0,
    recording_first_dropout_frame: ?u64 = null,
    recording_capture_base_frame: ?u64 = null,
    /// Interleaved samples captured so far this record pass.
    recording_accum: std.ArrayListUnmanaged(f32) = .empty,
    recording_channel_count: u16 = 1,
    /// j/k nudge sizes in the automation editor, from
    /// `default_automation_gain_step_db`/`default_automation_pan_step`.
    automation_gain_step_db: f32 = 1.0,
    automation_pan_step: f32 = 0.05,
    /// Fallback starting directory for the file browser when no project
    /// path is known yet, from `default_browse_dir`. Empty means "cwd", the
    /// pre-existing behavior - see `openBrowser`.
    default_browse_dir: config_mod.PathBuf = .{},
    /// Directory the last `:load`-family file came from (sample, pad, clip,
    /// slice, wavetable, soundfont, MIDI import - anything routed through
    /// `commands.readFileForLoad`, including a browser audition). The browser
    /// reopens here for every purpose but `.open_project`, so hunting down a
    /// second sample starts in the folder the first one came from. Empty
    /// until something is loaded; not persisted across runs.
    last_load_dir: config_mod.PathBuf = .{},
    clap_plugin_path: config_mod.PathBuf = .{},
    vst3_plugin_path: config_mod.PathBuf = .{},
    external_plugins: ws.plugin_catalog.Catalog,
    environ: ?*const std.process.Environ.Map = null,
    /// Where a plain `:w` and a pathless autosave land.
    default_project_path: config_mod.PathBuf = config_mod.PathBuf.init("project.wsj"),
    /// `:bounce`/`:bounce-stems` defaults, from the `bounce_*` and
    /// `default_bounce_path`/`default_stems_dir` options. The tail is the
    /// silence appended past the content so reverb and release rings out.
    bounce_tail_seconds: f32 = 2.0,
    bounce_bit_depth: ws.wav.BitDepth = .pcm16,
    default_bounce_path: config_mod.PathBuf = config_mod.PathBuf.init("bounce.wav"),
    default_stems_dir: config_mod.PathBuf = config_mod.PathBuf.init("stems"),
    /// Rows the `:` Tab-completion popup may occupy, from
    /// `completion_popup_rows`. Both frontends read this one.
    completion_popup_rows: u8 = 10,
    /// Terminal columns per step/bar in the grid views, from the
    /// `tui_*_cell_width` options - see `pianoCellWidth` and friends.
    tui_piano_cell_width: u8 = 3,
    tui_drum_cell_width: u8 = 3,
    tui_arrangement_cell_width: u8 = 4,
    /// dB span the TUI spectrum analyser draws, from `tui_spectrum_db_range`.
    tui_spectrum_db_range: f32 = 70.0,
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
    /// chain focus changes - see editors/fx_editor.zig's setFocus. Cycling
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
    instrument_picker_filter_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined,
    instrument_picker_filter_len: usize = 0,
    eq_track: u16 = 0,
    /// Which group's FX chain is in view when `view == .group_spectrum` -
    /// parallel to `eq_track`.
    eq_group: u8 = 0,
    /// View-only spectrum-analyzer prefs (not undo-tracked, not persisted) -
    /// see `editors/fx_editor.zig`'s `toggleSpectrumPre`/`toggleSpectrumFreeze`.
    eq_spectrum_pre: bool = false,
    eq_spectrum_frozen: bool = false,
    /// The snapshot captured the moment freeze turned on - held and redrawn
    /// instead of pulling a fresh one while frozen. Cleared whenever freeze
    /// turns back off, so the next freeze always grabs a new one.
    eq_spectrum_frozen_snap: ?ws.dsp.spectrum.SpectrumSnapshot = null,
    /// Scroll offset (in lines) of the help view; clamped by tui.drawHelp.
    help_scroll: usize = 0,
    /// Line index of the last `/` search match in the help view (highlighted
    /// by drawHelp, the anchor `n`/`N` continue from); reset on every open.
    help_search_hit: ?usize = null,
    synth_track: u16 = 0,
    synth_cursor: u16 = 2,
    synth_scroll: usize = 0,
    /// Track currently shown in the soundfont_editor view.
    soundfont_track: u16 = 0,
    /// Selected param row in the soundfont editor (GAIN/PAN/TRANSPOSE/PRESET).
    soundfont_param: u8 = 0,
    /// Which of the synth editor's two subviews (osc/env/filter params, the
    /// mod matrix) is showing - cycled by Tab. `synth_cursor` stays one flat
    /// param-id space across both; only which ids are reachable/rendered
    /// changes with the subview.
    synth_subview: synth_ed.Subview = .main,
    /// Oscillator card shown by GUI's grouped oscillator tabs. View-only state.
    synth_osc_tab: u8 = 0,
    /// LFO card shown by GUI's grouped LFO tabs. View-only state.
    synth_lfo_tab: u8 = 0,
    /// Envelope card shown by GUI's grouped envelope tabs. View-only state.
    synth_env_tab: u8 = 0,
    /// Filter card shown by GUI's grouped filter tabs. View-only state.
    synth_filter_tab: u8 = 0,
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
    /// Row budget the last `draw()` handed the view - the terminal height
    /// minus whatever chrome ate into it (today: the command-mode
    /// completion popup). Views whose layout is height-dependent (sampler
    /// and slicer waveform panes, the drum grid's stacked banks, the
    /// spectrum's FX strip) hit-test against this rather than the raw
    /// terminal height, or a click while the popup is open resolves
    /// against a taller layout than the one on screen.
    last_content_rows: u16 = 0,
    piano_track: u16 = 0,
    piano_cursor_step: u16 = 0,
    piano_cursor_pitch: u7 = 60,
    piano_scroll_step: u16 = 0,
    piano_scroll_pitch: u7 = 72,
    piano_note_len: f64 = 0.25,
    /// Which per-note value `<`/`>` edits and the GUI's lane draws, cycled
    /// by `f`/`F` - see `dsp.pattern.NoteField`. Global and not persisted,
    /// same bucket as `piano_grid`: a view setting, not part of the music.
    piano_note_field: ws.dsp.pattern.NoteField = .velocity,
    /// Chord quality `c`/`C` stamp and `o`/`O` cycle - see
    /// `theory.ChordQuality`. Global, not persisted, same bucket as
    /// `piano_note_field`.
    piano_chord_quality: ws.theory.ChordQuality = .triad,
    /// Chord voicing `r`/`R` cycle in place - see `theory.Voicing`.
    piano_chord_voicing: ws.theory.Voicing = .closed,
    /// The last chord `c`/`C`/`o`/`O`/`r`/`R` stamped, so cycling quality or
    /// voicing in place can clean up the previous shape's notes before
    /// laying down the new one instead of leaving orphaned voices behind.
    /// `beat < 0` means "nothing stamped yet, or the cursor moved since".
    piano_chord_last: struct {
        beat: f64 = -1,
        pitches: [7]u7 = undefined,
        count: u3 = 0,
    } = .{},
    /// Piano-roll step grid: straight sixteenths (4 steps/beat) or
    /// sixteenth-note triplets (6 steps/beat), toggled by `T`. Global, not
    /// persisted - a display/editing aid like `piano_scale`.
    piano_grid: enum { straight, triplet } = .straight,
    /// Piano-roll horizontal zoom: `z` enlarges cells and `Z` compacts them.
    /// Global and not persisted, in the same bucket
    /// as `piano_grid`/`piano_scale`.
    piano_division: GridDivision = .sixteenth,
    /// True while `M` moves or `Y` clones the piano-roll note under the
    /// cursor. h/l/j/k then drag it instead of the cursor; esc/M/Y (or any
    /// other key) drops it. See editors/piano.zig.
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
    /// Same idea as `piano_stamp`/`drum_stamp` for the arrangement: enter
    /// stamping a clip starts a session where h/l live-resize it (reusing
    /// resizeClip) and the cursor stays on the clip; dropping it jumps the
    /// cursor past the clip's end for sequential placing. See
    /// editors/arrangement.zig.
    arr_stamp: bool = false,
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
    /// Visual-mode anchors: set to the cursor position when `v` or `V` is
    /// pressed, null outside visual mode. The selection is
    /// [min(anchor,cursor), max(anchor,cursor)] on the view's time axis
    /// (step / step / bar); see editors/{piano,drum,arrangement}.zig's
    /// handleVisual.
    piano_visual_anchor: ?u16 = null,
    drum_visual_anchor: ?u16 = null,
    slicer_visual_anchor: ?u16 = null,
    arr_visual_anchor: ?u32 = null,
    /// The row half of the same selection - vim's visual vs visual-line,
    /// applied to a 2D grid. `v` sets these to the cursor row so the
    /// selection is a block (one pitch/pad/slice/lane tall until `j`/`k`
    /// grow it); `V` leaves them null, meaning "every row", which is what
    /// visual mode always used to do. A "line" here is one full column of
    /// the grid at a step, so linewise = every pitch, pad, slice, or lane.
    /// Null is the wide case precisely so the old behaviour is the default
    /// any code path that never sets them keeps getting.
    piano_visual_pitch_anchor: ?u7 = null,
    /// Enter toggles selected-note editing while piano visual mode stays
    /// active. Motions then transform notes instead of growing selection.
    piano_visual_edit: bool = false,
    drum_visual_pad_anchor: ?u8 = null,
    slicer_visual_slice_anchor: ?u8 = null,
    arr_visual_lane_anchor: ?usize = null,
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
    /// Multi-key prefix state (normal mode, not `.visual`): `g`/`z`/`c`
    /// arm here on their own, and the next key drains as a pair (`gg`,
    /// `gs`, `zg`, `co`). Editors read it via `takePrefix` at the top of
    /// their handleKey and fall through on an unknown pair, so a prefix
    /// never eats a key it doesn't own. The Lua keymap layer runs ahead of
    /// the builtin path, so a user `gx` map wins over the builtin pair;
    /// visual and operator-pending mode keep single-key g/G motions.
    pending_prefix: ?u8 = null,
    /// The count stashed when a prefix armed (`pending_prefix`), so the
    /// pair can read a `2cc` count the arming key's dispatch would have
    /// discarded (the piano roll's inversion). See `armPrefix`.
    pending_prefix_count: u32 = 0,
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
    /// File browser visual mode: `v` sets the anchor, `j`/`k`/`g`/`G`/`/`
    /// extend, enter loads every selected file into consecutive drum pads
    /// (see commands.loadPadsFromEntries). In `browser_entries` index space.
    /// Only armed for the `.load_pad` purpose - every other purpose picks
    /// exactly one file, so a range would have nowhere to go.
    browser_visual_anchor: ?usize = null,
    /// Visual-mode range clipboards (y/d/P while `.visual`), separate from
    /// the whole-pattern/single-clip clipboards above.
    piano_range_clip: ?PianoClip = null,
    drum_range_clip: ?StepRangeClip = null,
    slicer_range_clip: ?StepRangeClip = null,
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
    /// In-progress piano-roll mouse gestures, shared by both frontends the
    /// way `drum_paint_state` is. `piano_mouse_draw`: the note the press
    /// just placed is being sized by the drag that follows (FL's draw-drag).
    /// `piano_erase_active`: a right-drag erase brush is running and has
    /// already recorded its one undo entry. `piano_clone_source`: where a
    /// shift+drag started, so the release can leave a copy behind.
    /// `piano_mouse_grab_offset` keeps a body grab from jumping its onset
    /// under the pointer.
    /// See editors/piano.zig's handleMouse and gui/views/piano.zig.
    piano_mouse_draw: bool = false,
    piano_erase_active: bool = false,
    piano_clone_source: ?struct { pitch: u7, step: u16 } = null,
    piano_mouse_grab_offset: u16 = 0,
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
    /// `:cc-bind` with no number arms MIDI learn: the target is resolved
    /// from the editor cursor at that moment (so the player can look away
    /// and reach for the hardware), and the next controller message the
    /// engine reports binds it. See `commands.pollCcLearn`, called from
    /// `tick`.
    cc_learn: ?ws.dsp.controller.Target = null,
    /// The engine's CC sequence number when learn was armed - only a message
    /// arriving *after* that counts, or a knob touched a moment earlier
    /// would bind itself the instant learn opened.
    cc_learn_seq: ?u24 = null,
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
    /// `:ghost [on|off]` - dims every OTHER melodic track's notes into the
    /// piano roll's empty cells (e.g. tracing a bassline from a chord
    /// track). Same monitoring-aid status as `piano_scale`: not persisted.
    piano_ghost: bool = false,
    /// `:audition [on|off]` - preview the pitch under the piano-roll cursor
    /// on every j/k/J/K move, the way FL's piano roll sounds a note as you
    /// drag it. Worth more here than in a GUI: the TUI roll can't show which
    /// key a row is without counting. Same not-persisted monitoring-aid
    /// status as `piano_ghost`.
    piano_audition: bool = false,
    /// Undo/redo history for content edits (u / U in the editing views).
    history: undo_mod.History = .{},
    /// User-saved synth + FX presets (`:synth-preset-save <name>`), loaded
    /// from `~/.config/wstudio/instrument_presets.wspreset` and rewritten
    /// wholesale on save. Complements compiled-in factory list.
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
    recent_projects: std.ArrayListUnmanaged([]const u8) = .empty,
    browser_recent_mode: bool = false,
    recent_project_cursor: usize = 0,
    recent_project_scroll: usize = 0,
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
    /// Synth and FX state before picker opened. Cancel restores both.
    preset_audition_original: ws.dsp.PolySynth.Patch = .{},
    preset_audition_original_fx: ?ws.Fx = null,
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

    pub fn initConfigured(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8, user_config: config_mod.Config) !App {
        var app = try initWithSampleRate(allocator, io, user_config.default_sample_rate);
        errdefer app.deinit();

        if (init_path) |path| {
            const loaded = ws.persist.load(allocator, io, path) catch |err| {
                std.debug.print("wstudio: cannot load '{s}': {s}\n", .{ path, @errorName(err) });
                return err;
            };
            app.session.deinit();
            app.session = loaded;
            app.setProjectPath(path);
        }
        app.applyUserConfig(user_config, init_path == null);
        app.promptIfBackupNewer(if (init_path) |path| path else app.defaultProjectPath());
        return app;
    }

    pub fn initWithSampleRate(allocator: std.mem.Allocator, io: std.Io, sample_rate: u32) !App {
        var app: App = .{
            .allocator = allocator,
            .io = io,
            .session = try ws.Session.initDefaultWithSampleRate(allocator, sample_rate),
            .user_synth_presets = user_presets.load(allocator, io, sample_rate),
            .user_drum_kits = user_drum_kits.load(allocator, io),
            .bookmarks = bookmark_store.load(allocator, io),
            .recent_projects = recent_project_store.load(allocator, io),
            .external_plugins = ws.plugin_catalog.Catalog.init(allocator),
        };
        app.cmd_history = cmd_history_store.load(allocator, io);
        app.cmd_history_pos = app.cmd_history.items.len;
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
                    .scope = cmd_mod.ScopeSet.one(uc.scope),
                };
                n += 1;
            }
        }
        self.all_cmds_len = n;
    }

    pub fn deinit(self: *App) void {
        if (self.audio_input.active != .none) self.audio_input.stop();
        if (self.recording_take) |*take| take.finish();
        self.recording_accum.deinit(self.allocator);
        self.external_plugins.deinit();
        user_presets.deinit(self.allocator, &self.user_synth_presets);
        if (self.preset_audition_original_fx) |*fx| fx.deinit(self.allocator);
        user_drum_kits.deinit(self.allocator, &self.user_drum_kits);
        if (self.arr_range_clip) |r| r.deinit(self.allocator);
        if (self.automation_range_clip) |r| self.allocator.free(r.points);
        if (self.drum_range_clip) |*c| c.deinit(self.allocator);
        if (self.slicer_range_clip) |*c| c.deinit(self.allocator);
        if (self.drum_clip) |*c| DrumMachine.freeMidi(self.allocator, &c.midi);
        if (self.pending_fx_nudge) |*p| p.deinit(self.allocator);
        self.freeBrowserEntries();
        self.browser_entries.deinit(self.allocator);
        if (self.browser_dir.len > 0) self.allocator.free(self.browser_dir);
        bookmark_store.deinit(self.allocator, &self.bookmarks);
        recent_project_store.deinit(self.allocator, &self.recent_projects);
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

    /// The SoundfontPlayer currently open in the soundfont_editor view -
    /// both soundfont kinds share the player and the editor.
    pub fn editingSoundfont(self: *App) ?*ws.dsp.SoundfontPlayer {
        if (self.soundfont_track >= self.session.racks.items.len) return null;
        return switch (self.session.racks.items[self.soundfont_track].instrument) {
            .soundfont, .acoustic => |*sf| sf, else => null,
        };
    }
    // zig fmt: on

    /// Which of the two soundfont kinds the editor is open on, for the
    /// title/badge text the TUI, GUI, and status bar all draw. "SOUNDFONT"
    /// when the track is gone, matching the editor's own fallback title.
    pub fn editingSoundfontLabel(self: *App) []const u8 {
        if (self.soundfont_track >= self.session.racks.items.len) return "SOUNDFONT";
        return if (self.session.racks.items[self.soundfont_track].instrument == .acoustic) "ACOUSTIC" else "SOUNDFONT";
    }

    /// Total content length in beats: the longest piano-roll loop and the
    /// longest drum-machine pattern across all tracks.
    pub fn contentBeats(self: *App) f64 {
        return ws.bounce.contentBeats(&self.session);
    }

    /// Frame position shown by frontend transport meters. Pattern playback
    /// loops locally inside each sequencer while the engine clock stays
    /// monotonic, so wrap the readout at the longest live pattern. Song mode
    /// uses the arrangement timeline and keeps the absolute position.
    pub fn displayPositionFrames(self: *App, position_frames: u64) u64 {
        if (self.session.song_mode) return position_frames;
        const len_beats = self.contentBeats();
        if (len_beats <= 0) return position_frames;
        const loop_frames = self.session.engine.transport.framesAtBeats(len_beats);
        return if (loop_frames > 0) position_frames % loop_frames else position_frames;
    }

    pub fn displayTransport(self: *App, position_frames: u64) Transport {
        var transport = self.session.engine.transport;
        transport.position_frames = self.displayPositionFrames(position_frames);
        return transport;
    }

    pub fn audioHost(self: *App, block_frames: u32, output_device: []const u8) ws.AudioHost {
        const render = struct {
            fn callback(ctx: *anyopaque, out: []types.Sample) void {
                const engine: *Engine = @ptrCast(@alignCast(ctx));
                engine.renderRealtime(out);
            }
        }.callback;
        return ws.AudioHost.init(.{
            .sample_rate = self.session.project.sample_rate,
            .block_frames = block_frames,
            .output_device = output_device,
        }, render, self.session.engine);
    }

    pub fn setScale(self: *App, scale: ?ws.theory.Scale) void {
        self.session.project.scale = scale;
        self.dirty = true;
        if (scale) |active|
            self.setStatus("scale: {s} {s}", .{ ws.theory.pitchClassName(active.root), active.kind.label() })
        else
            self.setStatus("scale: off", .{});
    }

    pub fn recordMidiNote(self: *App, pitch: u7, velocity: u7) void {
        if (self.modal.mode != .insert) return;
        switch (self.view) {
            .drum_grid => drum_ed.recordNote(self, pitch, velocity),
            .slicer_grid => slicer_ed.recordNote(self, pitch, velocity),
            .piano_roll => piano_ed.recordNote(self, pitch, @as(f32, @floatFromInt(velocity)) / 127.0),
            else => {},
        }
    }

    /// Follow track focus, collect CC dirtiness, and route queued notes
    /// through control-thread recording. Device open/close stays frontend-owned.
    pub fn serviceMidiInput(self: *App, midi_in: anytype) void {
        midi_in.active_track.store(@intCast(self.cursor), .monotonic);
        if (midi_in.dirty.swap(false, .acquire)) self.dirty = true;
        while (midi_in.note_queue.pop()) |recorded| self.recordMidiNote(recorded.pitch, recorded.vel);
        const dropped = midi_in.dropped_notes.swap(0, .acq_rel);
        if (dropped != 0) {
            self.setStatus("MIDI input backlog: {d} note{s} not recorded", .{ dropped, if (dropped == 1) "" else "s" });
        }
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

    /// Terminal columns per step, from `wstudio.o.tui_piano_cell_width`.
    /// Every column-width computation in editors/piano.zig and
    /// views/piano.zig goes through this.
    pub fn pianoCellWidth(self: *const App) usize {
        return self.tui_piano_cell_width;
    }

    pub fn drumCellWidth(self: *const App) usize {
        return self.tui_drum_cell_width;
    }

    /// Terminal columns per bar, from `wstudio.o.tui_arrangement_cell_width`.
    /// Every column-width computation in editors/arrangement.zig
    /// and views/arrangement.zig goes through this.
    pub fn arrCellWidth(self: *const App) usize {
        return self.tui_arrangement_cell_width;
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
        const command_key = key_in == .char and key_in.char == ':';
        if (command_key) self.keymap_pending_len = 0;
        if (!command_key and key_in != .ctrl_c and key_in != .mouse and key_in != .enter_release) {
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
                // Files only, unlike every other view's plain span: the
                // directories a selection reaches over are skipped by the
                // load, so counting them would promise pads that never fill.
                .file_browser => self.browserVisualCount(),
                else => null,
            };
            if (width) |wd| w.print("v{d}", .{wd}) catch {};
        } else if (self.modal.mode == .normal) {
            if (self.pending_prefix) |p| w.print("{c}", .{p}) catch {};
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
    /// How many files the browser's visual selection would actually load -
    /// the marked rows, directories excluded. Null when nothing is selected.
    fn browserVisualCount(self: *const App) ?u64 {
        const anchor = self.browser_visual_anchor orelse return null;
        // `v` in an empty listing leaves an anchor with nothing under it,
        // and a stale one can outlive the entries it indexed - clamping
        // alone would still slice [0..1] out of an empty list.
        if (self.browser_entries.items.len == 0) return 0;
        const last = self.browser_entries.items.len - 1;
        const lo = @min(@min(anchor, self.browser_cursor), last);
        const hi = @min(@max(anchor, self.browser_cursor), last);
        var n: u64 = 0;
        for (self.browser_entries.items[lo .. hi + 1]) |e| {
            if (!e.is_dir) n += 1;
        }
        return n;
    }

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
        while (self.cmd_history.items.len > self.cmd_history_cap) self.allocator.free(self.cmd_history.orderedRemove(0));
        self.cmd_history_pos = self.cmd_history.items.len;
        self.default_velocity = user_config.default_velocity;
        self.master_gain_db = user_config.default_master_gain_db;
        _ = self.session.engine.send(.{ .set_master_gain = types.dbToGain(self.master_gain_db) });
        self.count_in_bars = user_config.count_in_bars;
        self.audio_input_device = user_config.audio_input_device;
        self.automation_gain_step_db = user_config.default_automation_gain_step_db;
        self.automation_pan_step = user_config.default_automation_pan_step;
        self.history.cap = user_config.undo_history_entries;
        _ = self.session.engine.send(.{ .set_metronome_gain = user_config.metronome_click_gain });
        // Not gated by `if (blank)`: `Session.metronome_enabled` is never
        // persisted (see its doc comment), so every load - blank or from a
        // project file - starts silent unless this restores the click.
        self.session.setMetronome(user_config.default_metronome_enabled);
        self.session.setSongMode(user_config.default_song_mode);
        self.default_browse_dir = user_config.default_browse_dir;
        self.clap_plugin_path = user_config.clap_plugin_path;
        self.vst3_plugin_path = user_config.vst3_plugin_path;
        // Process-wide switch `ClapPlugin.load`/`Vst3Plugin.load` read on
        // every hosted-plugin load - see plugin_host/bridge.zig. Set here
        // (once, at session init) rather than threaded through the ~4
        // independent call sites that construct a hosted plugin.
        ws.plugin_host.bridge.sandbox_enabled.store(user_config.sandbox_plugins, .release);
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
        self.piano_cursor_pitch = user_config.default_piano_pitch;
        self.piano_scroll_pitch = @min(user_config.default_piano_pitch +| 12, 127);
        self.arr_grid = user_config.default_arrangement_grid;
        self.piano_ghost = user_config.piano_ghost_notes;
        self.piano_audition = user_config.piano_audition;
        self.modal.octave = @intCast(user_config.default_octave);
        self.bounce_tail_seconds = user_config.bounce_tail_seconds;
        self.bounce_bit_depth = user_config.bounce_bit_depth;
        self.default_bounce_path = user_config.default_bounce_path;
        self.default_stems_dir = user_config.default_stems_dir;
        self.completion_popup_rows = user_config.completion_popup_rows;
        self.tui_piano_cell_width = user_config.tui_piano_cell_width;
        self.tui_drum_cell_width = user_config.tui_drum_cell_width;
        self.tui_arrangement_cell_width = user_config.tui_arrangement_cell_width;
        self.tui_spectrum_db_range = user_config.tui_spectrum_db_range;
        waveform.low_hz = user_config.waveform_low_hz;
        waveform.high_hz = user_config.waveform_high_hz;
        _ = self.session.engine.send(.{ .set_limiter = .{
            .ceiling = types.dbToGain(user_config.master_limiter_ceiling_db),
            .release_ms = user_config.master_limiter_release_ms,
        } });
        // New-instrument defaults live on Session because racks are built
        // there (setInstrument, project load), where the config isn't in
        // scope. A load overwrites these from the file right after.
        self.session.defaults = .{
            .drum_steps = user_config.default_drum_steps,
            .slicer_steps = user_config.default_slicer_steps,
            .pattern_length_beats = user_config.default_pattern_length_beats,
            .swing = user_config.default_swing,
        };
        if (blank) {
            self.session.project.tempo_bpm = user_config.default_tempo;
            self.session.project.beats_per_bar = user_config.default_beats_per_bar;
            _ = self.session.engine.send(.{ .set_tempo = user_config.default_tempo });
            _ = self.session.engine.send(.{ .set_time_signature = user_config.default_beats_per_bar });
            self.session.syncLoop();
        }
    }

    pub fn scanExternalPlugins(self: *App, environ: *const std.process.Environ.Map) bool {
        self.environ = environ;
        var expanded_buf: [std.fs.max_path_bytes]u8 = undefined;
        const clap_custom_path = commands.expandHome(&expanded_buf, self.clap_plugin_path.slice());
        var clap_custom = [_][]const u8{clap_custom_path};
        var clap_owned: std.ArrayListUnmanaged([]u8) = .empty;
        const clap_paths: []const []const u8 = if (self.clap_plugin_path.len > 0)
            &clap_custom
        else blk: {
            clap_owned = ws.dsp.clap_scan.searchPaths(self.allocator, environ) catch |err| {
                self.setStatus("plugin scan failed: {s}", .{@errorName(err)});
                return false;
            };
            break :blk clap_owned.items;
        };
        defer if (self.clap_plugin_path.len == 0)
            ws.dsp.clap_scan.freeSearchPaths(self.allocator, &clap_owned);

        var vst3_expanded_buf: [std.fs.max_path_bytes]u8 = undefined;
        const vst3_custom_path = commands.expandHome(&vst3_expanded_buf, self.vst3_plugin_path.slice());
        var vst3_custom = [_][]const u8{vst3_custom_path};
        var vst3_owned: std.ArrayListUnmanaged([]u8) = .empty;
        const vst3_paths: []const []const u8 = if (self.vst3_plugin_path.len > 0)
            &vst3_custom
        else blk: {
            vst3_owned = ws.vst3.scan.searchPaths(self.allocator, environ) catch |err| {
                self.setStatus("plugin scan failed: {s}", .{@errorName(err)});
                return false;
            };
            break :blk vst3_owned.items;
        };
        defer if (self.vst3_plugin_path.len == 0)
            ws.vst3.scan.freeSearchPaths(self.allocator, &vst3_owned);
        self.external_plugins.scan(self.io, clap_paths, vst3_paths) catch |err| {
            self.setStatus("plugin scan failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    pub fn rescanExternalPlugins(self: *App) void {
        const environ = self.environ orelse {
            self.setStatus("plugin scan unavailable", .{});
            return;
        };
        if (self.scanExternalPlugins(environ)) self.setStatus("plugin scan: {d} instrument(s), {d} effect(s)", .{
            self.external_plugins.count(.instrument),
            self.external_plugins.count(.effect),
        });
    }

    /// Frontend-neutral half of `:reload-config` (ui/commands.zig sets
    /// `pending_config_reload`; `run()` calls `runtime.reload()` then this,
    /// once it's back holding the fresh `Config`). Re-fires `ConfigDone` -
    /// there's no dedicated "config was reloaded" event, and treating a
    /// reload as a second config-done moment is the more useful reading for
    /// autocmds that want to redo their own setup after one. Frontend-only
    /// side effects (GUI theme repaint, TUI OSC palette, the frame-loop's
    /// own `user_config` copy) are `run()`'s job, not this one's - see
    /// tui/tui.zig and gui/gui.zig's `pending_config_reload` handling.
    pub fn afterConfigReload(self: *App, user_config: config_mod.Config) void {
        self.rebuildCmdTable();
        self.applyUserConfig(user_config, false);
        if (self.environ) |environ| _ = self.scanExternalPlugins(environ);
        self.emitEvent(.ConfigDone);
    }

    pub fn reloadConfig(self: *App, runtime: *config_mod.Runtime) bool {
        _ = runtime.reload(self.io) catch |err| {
            self.afterConfigReload(runtime.config);
            self.setStatus("reload-config: {s}", .{@errorName(err)});
            return false;
        };
        self.afterConfigReload(runtime.config);
        self.setStatus("config reloaded", .{});
        return true;
    }

    pub fn attachRuntime(self: *App, runtime: *config_mod.Runtime) void {
        self.lua_runtime = runtime;
        self.rebuildCmdTable();
        runtime.app = self;
        runtime.attachHost(luaHost(self));
        if (self.projectPath()) |path| self.emitEvent(.{ .ProjectLoadPost = .{ .path = path } });
    }

    pub fn detachRuntime(self: *App, runtime: *config_mod.Runtime) void {
        runtime.host = null;
        runtime.app = null;
        self.lua_runtime = null;
    }

    // wstudio.api surface (docs/lua-api.md phase 6): bodies live in
    // app_api.zig, re-exported here under their own names since
    // config_lua_api.zig reaches them as requireApp(l).apiPlay() /
    // App.ApiPatternError-style qualified access.
    pub const ApiTransportInfo = app_api.ApiTransportInfo;
    pub const apiIsPlaying = app_api.apiIsPlaying;
    pub const apiPlay = app_api.apiPlay;
    pub const apiStop = app_api.apiStop;
    pub const apiTransportInfo = app_api.apiTransportInfo;
    pub const apiSeekBeats = app_api.apiSeekBeats;
    pub const apiSetSongMode = app_api.apiSetSongMode;
    pub const apiSetMetronome = app_api.apiSetMetronome;
    pub const apiSetLoop = app_api.apiSetLoop;
    pub const apiGetTempo = app_api.apiGetTempo;
    pub const apiCurrentTrack = app_api.apiCurrentTrack;
    pub const apiSetTempo = app_api.apiSetTempo;
    pub const ApiTrackInfo = app_api.ApiTrackInfo;
    pub const apiTrackInfo = app_api.apiTrackInfo;
    pub const apiSetTrackGainDb = app_api.apiSetTrackGainDb;
    pub const apiSetTrackPan = app_api.apiSetTrackPan;
    pub const apiSetTrackMuted = app_api.apiSetTrackMuted;
    pub const apiSetTrackSoloed = app_api.apiSetTrackSoloed;
    pub const apiSetTrackArmed = app_api.apiSetTrackArmed;
    pub const apiSelectTrack = app_api.apiSelectTrack;
    pub const apiRenameTrack = app_api.apiRenameTrack;
    pub const apiTrackAdd = app_api.apiTrackAdd;
    pub const apiTrackDel = app_api.apiTrackDel;
    pub const apiTrackDuplicate = app_api.apiTrackDuplicate;
    pub const apiTrackMove = app_api.apiTrackMove;
    pub const ApiPatternError = app_api.ApiPatternError;
    pub const ApiPatternInfo = app_api.ApiPatternInfo;
    pub const apiPatternInfo = app_api.apiPatternInfo;
    pub const apiPatternPlayer = app_api.apiPatternPlayer;
    pub const apiDrumMachine = app_api.apiDrumMachine;
    pub const apiDrumEdit = app_api.apiDrumEdit;
    pub const apiPatternChanged = app_api.apiPatternChanged;
    pub const apiSetNotes = app_api.apiSetNotes;
    pub const ApiPatternUpdate = app_api.ApiPatternUpdate;
    pub const apiSetPattern = app_api.apiSetPattern;
    pub const ApiFxError = app_api.ApiFxError;
    pub const apiFxChain = app_api.apiFxChain;
    pub const apiFxUnit = app_api.apiFxUnit;
    pub const apiFxAdd = app_api.apiFxAdd;
    pub const apiFxDel = app_api.apiFxDel;
    pub const apiFxMove = app_api.apiFxMove;
    pub const apiFxBypass = app_api.apiFxBypass;
    pub const apiFxParamCount = app_api.apiFxParamCount;
    pub const apiFxParamSet = app_api.apiFxParamSet;
    pub const ApiClipError = app_api.ApiClipError;
    pub const apiLane = app_api.apiLane;
    pub const apiClipAdd = app_api.apiClipAdd;
    pub const apiClipDel = app_api.apiClipDel;
    pub const apiClipClear = app_api.apiClipClear;
    pub const apiSectionSet = app_api.apiSectionSet;
    pub const apiSectionDel = app_api.apiSectionDel;
    pub const apiProjectSave = app_api.apiProjectSave;
    pub const apiProjectOpen = app_api.apiProjectOpen;
    pub const apiProjectNew = app_api.apiProjectNew;

    /// Guard frontend-level quit gestures the same way as `:quit`.
    pub fn requestQuit(self: *App) bool {
        if (self.dirty) {
            self.setStatus("unsaved changes - :write to save, :quit! to discard", .{});
            return false;
        }
        self.deleteBackupIfPresent();
        self.should_quit = true;
        return true;
    }

    /// Which modal modes bypass a view's own key handler and go straight to
    /// `modal.handle`. Command and search always do - they own the prompt
    /// line, and a view that grabbed those keys would eat the text being
    /// typed. The variants differ only in how much more they hand over.
    const EditorBypass = enum {
        /// Command and search only; the editor still sees insert and visual.
        prompt,
        /// ...and insert: in a grid view the qwerty layout is playing notes,
        /// not navigating, so modal.handle owns every key until escape drops
        /// back to normal (see recordNote in editors/drum.zig and
        /// editors/piano.zig, and docs/editing-grammar.md).
        prompt_insert,
        /// Anything but normal mode.
        non_normal,

        fn covers(self: EditorBypass, mode: modal_mod.Mode) bool {
            return switch (self) {
                .prompt => mode == .command or mode == .search,
                .prompt_insert => mode == .command or mode == .search or mode == .insert,
                .non_normal => mode != .normal,
            };
        }
    };

    /// The editor views' shared key routing: offer the key to the view's own
    /// handler unless the modal state owns it, and fall back to
    /// `modal.handle` whenever the view passes. A key the editor handled
    /// discards any unused count prefix - vim's rule that a count binds to
    /// the command it precedes, then dies with it.
    fn routeEditorKey(
        self: *App,
        key: modal_mod.Key,
        now_ns: i96,
        bypass: EditorBypass,
        editorKey: *const fn (*App, modal_mod.Key) bool,
    ) void {
        if (bypass.covers(self.modal.mode) or !editorKey(self, key)) {
            self.applyAction(self.modal.handle(key), now_ns);
        } else self.modal.count = 0;
    }

    /// The picker views' shared key routing. `/` (and the search mode it
    /// enters) goes to the modal prompt so the picker's filter narrows live
    /// while typing; submit/cancel land in applyAction's `.search_submit`
    /// case. Unlike `routeEditorKey` the picker handler is total - there is
    /// no unhandled key to fall through with.
    fn routePickerKey(
        self: *App,
        key: modal_mod.Key,
        now_ns: i96,
        pickerKey: *const fn (*App, modal_mod.Key) void,
    ) void {
        if (self.modal.mode == .search or (key == .char and key.char == '/')) {
            self.applyAction(self.modal.handle(key), now_ns);
        } else pickerKey(self, key);
    }

    /// Arm a multi-key prefix for the next normal-mode key (the `gg`-style
    /// pairs). Editors call this from their own key switches; `takePrefix`
    /// drains it. Normal mode only - visual and operator-pending keep
    /// single-key g/G motions.
    pub fn armPrefix(self: *App, p: u8) bool {
        if (self.modal.mode != .normal) return false;
        self.pending_prefix = p;
        // Stash the count the arming key's dispatch is about to discard:
        // `2c` (a chord's inversion) must survive as `2cc`.
        self.pending_prefix_count = self.modal.count;
        return true;
    }

    /// Pop the pending prefix (if any) for `key`. A non-char key (escape,
    /// arrows, tab, …) cancels the prefix without consuming the key itself,
    /// so an armed `g` never swallows a view switch. Returns the armed
    /// prefix with `pending_prefix` already cleared, or null.
    pub fn takePrefix(self: *App, key: modal_mod.Key) ?u8 {
        const p = self.pending_prefix orelse return null;
        self.pending_prefix = null;
        if (key != .char) {
            self.pending_prefix_count = 0;
            return null;
        }
        return p;
    }

    fn handleKeyBuiltin(self: *App, key_in: modal_mod.Key, now_ns: i96) void {
        self.now_ns = now_ns;
        if (key_in == .ctrl_c) {
            _ = self.requestQuit();
            return;
        }

        // zig fmt: off
        // Command/search mode: up/down or ctrl-p/n recall history (command only - search
        // has no history), tab completes the command name (command only).
        // Left/right/home/end/ctrl-w edit the cmd_buf cursor in place
        // (modal.handle owns that state, shared by both prompts) - passed
        // through as their own variants rather than the hjkl aliasing below,
        // which would insert literal 'h'/'l' characters into the line
        // instead of moving through it.
        if (self.modal.mode == .command or self.modal.mode == .search) {
            switch (key_in) {
                .arrow_up, .ctrl_p => { if (self.modal.mode == .command) self.commandHistoryPrev(); return; },
                .arrow_down, .ctrl_n => { if (self.modal.mode == .command) self.commandHistoryNext(); return; },
                .arrow_left, .arrow_right, .home, .end, .ctrl_a, .ctrl_e, .ctrl_u, .ctrl_k, .ctrl_w => { _ = self.modal.handle(key_in); return; },
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
                        'j' => self.help_scroll +|= 1,
                        'k' => self.help_scroll -|= 1,
                        'd' => self.help_scroll +|= 10,
                        'u' => self.help_scroll -|= 10,
                        'G' => self.help_scroll = std.math.maxInt(usize),
                        'g' => self.help_scroll = 0,
                        // Section-at-a-time paging: 500+ lines is a lot of
                        // j/k, and every other view already spells "move by
                        // the next structural unit" as { / }.
                        '}' => self.help_scroll = help.sectionScroll(self.allCmds(), self.userKeymapsSlice(), self.help_scroll, 1),
                        '{' => self.help_scroll = help.sectionScroll(self.allCmds(), self.userKeymapsSlice(), self.help_scroll, -1),
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
            // Every editor view routes the same way; `routeEditorKey` and
            // `EditorBypass` above own the contract, so an arm here is just
            // "which handler, and how much does the modal state take first".
            .drum_grid => self.routeEditorKey(key, now_ns, .prompt_insert, drum_ed.handleKey),
            .slicer_grid => self.routeEditorKey(key, now_ns, .prompt_insert, slicer_ed.handleKey),
            .piano_roll => self.routeEditorKey(key, now_ns, .prompt_insert, piano_ed.handleKey),
            .synth_editor => self.routeEditorKey(key, now_ns, .prompt, synth_ed.handleKey),
            .track_spectrum, .master_spectrum, .group_spectrum => self.routeEditorKey(key, now_ns, .prompt, spectrum_ed.handleKey),
            .arrangement => self.routeEditorKey(key, now_ns, .prompt, arrangement_ed.handleKey),
            .automation => self.routeEditorKey(key, now_ns, .prompt, automation_ed.handleKey),
            .sampler_editor => self.routeEditorKey(key, now_ns, .non_normal, sampler_ed.handleKey),
            .soundfont_editor => self.routeEditorKey(key, now_ns, .non_normal, soundfont_ed.handleKey),
            .instrument_picker => self.routePickerKey(key, now_ns, App.handlePickerKey),
            .fx_picker => self.routePickerKey(key, now_ns, App.handleFxPickerKey),
            .automation_param_picker => self.routePickerKey(key, now_ns, App.handleAutomationParamPickerKey),
            .preset_picker => self.routePickerKey(key, now_ns, preset_ed.handleKey),
            // The browser has no `/` binding of its own to intercept: its
            // search mode is entered from its own key handler, so only an
            // already-open prompt routes past it.
            .file_browser => if (self.modal.mode == .search) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else self.handleBrowserKey(key),
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
                            'd', 'Y', 'J', 'K', 'R', 'p', 'I', 'r', 'f', '<', '>', '[', ']', 'v', 'V', 'z' => {
                                self.setStatus("master bus: n/a", .{});
                                return;
                            },
                            else => {},
                        }
                    } else if (cur_group) |g| {
                        switch (key.char) {
                            's' => { spectrum_ed.switchToGroup(self, g); return; },
                            // m/S on a group row act on every member track.
                            // Falling through to the modal layer instead
                            // reported "master bus has no mute" (a group row
                            // parks `cursor` on the master sentinel), leaving
                            // the group's whole submix unmutable from here.
                            'm' => { self.doGroupMute(g); return; },
                            'S' => { self.doGroupSolo(g); return; },
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
                            // Track rows ARE the only axis, so the selection is linewise by
                            // nature and `V` is just a synonym - accepted so the
                            // grammar reads the same in every view.
                            'v', 'V' => {
                                self.tracks_visual_anchor = self.track_row;
                                self.modal.mode = .visual;
                                self.setStatus("visual: j/k extend, 0/G ends, o swap, g group, m/S/Y/dd/-+/<>/[] edit, esc cancel", .{});
                                return;
                            },
                            'Y', 'J', 'K', 'p', 'I', 'r', 'f', '<', '>', '[', ']' => {
                                self.setStatus("group row: n/a", .{});
                                return;
                            },
                            else => {},
                        }
                    } else {
                        switch (key.char) {
                            'M' => { spectrum_ed.switchToMaster(self); self.setTrackRow(self.track_rows_len); return; },
                            's' => { spectrum_ed.switchToTrack(self, @intCast(self.cursor)); return; },
                            'p' => { self.openStepEditor(@intCast(self.cursor)); return; },
                            'a' => { self.doTrackAdd(null); return; },
                            'I' => { self.openInstrumentPicker(self.cursor, true); return; },
                            // Same key the instrument editors use, one level
                            // up: a synth preset is a whole rack (patch +
                            // FX chain), so it belongs to the track row.
                            'f' => { preset_ed.openForTrack(self, @intCast(self.cursor)); return; },
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
                            'v', 'V' => {
                                self.tracks_visual_anchor = self.track_row;
                                self.modal.mode = .visual;
                                self.setStatus("visual: j/k extend, 0/G ends, o swap, g group, m/S/Y/dd/-+/<>/[] edit, esc cancel", .{});
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
        const view_rows: usize = @max(if (self.last_content_rows > 0) self.last_content_rows else rows, 10);
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
            .file_browser => self.browserMouse(ev, row),
            .help => self.helpMouse(ev),
            .automation => automation_ed.handleMouse(self, ev, row),
            .automation_param_picker => self.automationParamPickerMouse(ev, row),
            .preset_picker => preset_ed.handleMouse(self, ev, row),
            .slicer_grid => slicer_ed.handleMouse(self, ev, row),
        }
    }

    /// Tracks view: click a row to select + open it (same as Enter - a
    /// group row opens its FX chain); scroll moves like j/k, Ctrl ten rows.
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
            .scroll_up, .scroll_down => {
                const dy: i32 = if (ev.kind == .scroll_up) -1 else 1;
                for (0..if (ev.ctrl) 10 else 1) |_| self.applyAction(.{ .move = .{ .dy = dy } }, self.now_ns);
            },
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

    /// `S` on a group row: flip the bus's own solo flag (`GroupState.soloed`
    /// - a real flag now, not soloing every member track: see its doc
    /// comment for why that used to drift, same reason `doGroupMute` got
    /// the same treatment).
    pub fn doGroupSolo(self: *App, g: u8) void {
        const grp = &(self.session.groups[g] orelse return);
        self.session.setGroupSoloed(g, !grp.soloed);
        self.dirty = true;
        self.setStatus("\"{s}\" {s}", .{ grp.name, if (grp.soloed) "soloed" else "unsoloed" });
    }

    /// `m` on a group row: flip the bus's own mute flag (`GroupState.muted`
    /// - see its doc comment for why this is a real flag now rather than
    /// muting every member track).
    pub fn doGroupMute(self: *App, g: u8) void {
        const grp = &(self.session.groups[g] orelse return);
        self.session.setGroupMuted(g, !grp.muted);
        self.dirty = true;
        self.setStatus("\"{s}\" {s}", .{ grp.name, if (grp.muted) "muted" else "unmuted" });
    }

    /// `-`/`+` on a group row: ride the bus fader (session.setGroupGain
    /// clamps to the track-gain range).
    fn doGroupGainStep(self: *App, g: u8, delta_db: f32) void {
        if (g >= engine_mod.max_groups) return;
        if (self.session.groups[g]) |*grp| {
            const before = grp.gain_db;
            self.session.setGroupGain(g, grp.gain_db + delta_db);
            history.recordGroupGain(self, g, before);
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
    /// enter/space); scroll moves the highlight, Ctrl ten entries.
    fn pickerMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        var buf: [instrument_picker_items.len]InstrumentPickerItem = undefined;
        const internal_count = self.filteredInstrumentPickerItems(&buf).len;
        const count = internal_count + self.filteredInstrumentPluginCount();
        switch (ev.kind) {
            .press => {
                const item: ?usize = if (row >= 3 and row < 3 + internal_count)
                    row - 3
                else if (row >= 4 + internal_count)
                    internal_count + row - (4 + internal_count)
                else
                    null;
                if (item == null or item.? >= count) return;
                self.clickInstrumentPickerItem(item.?, self.now_ns);
            },
            .scroll_up => { self.picker_cursor -|= if (ev.ctrl) 10 else 1; },
            .scroll_down => { self.picker_cursor = @intCast(modal_mod.clampDelta(self.picker_cursor, if (ev.ctrl) 10 else 1, @intCast(count -| 1))); },
            else => {},
        }
    }

    /// File browser: click a row to descend into it or activate it (same as
    /// enter/l/space); scroll moves the highlight, Ctrl ten entries.
    fn browserMouse(self: *App, ev: modal_mod.MouseEvent, row: usize) void {
        if (self.browser_bookmark_mode) return; // keyboard-only overlay
        switch (ev.kind) {
            .press => {
                if (row < 2) return;
                const idx = self.browser_scroll + (row - 2);
                if (idx >= self.browser_entries.items.len) return;
                self.clickBrowserItem(idx, self.now_ns);
            },
            .scroll_up => { self.browser_cursor -|= if (ev.ctrl) 10 else 1; },
            .scroll_down => { self.browser_cursor = @min(self.browser_cursor +| (if (ev.ctrl) @as(usize, 10) else 1), self.browser_entries.items.len -| 1); },
            else => {},
        }
    }

    pub fn clickBrowserItem(self: *App, index: usize, now_ns: i96) void {
        if (self.modal.mode == .search) self.handleKey(.enter, now_ns);
        if (index >= self.browser_entries.items.len) return;
        self.browser_cursor = index;
        self.browserActivate();
    }
    // zig fmt: on

    /// Help view: scroll content, Ctrl ten lines. No click behavior.
    fn helpMouse(self: *App, ev: modal_mod.MouseEvent) void {
        switch (ev.kind) {
            .scroll_up => self.help_scroll -|= if (ev.ctrl) 10 else 1,
            .scroll_down => self.help_scroll +|= if (ev.ctrl) 10 else 1,
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
    /// the selection, the bulk mixer/delete keys mirror their single-track
    /// counterparts (`m`/`S`/`-`+`/`</>`/`[]`/`dd`), `esc` cancels.
    /// Everything else is swallowed, matching the other editors' visual modes.
    fn handleTracksVisual(self: *App, key: modal_mod.Key) void {
        if (self.tracks_del_pending) {
            self.tracks_del_pending = false;
            if (key == .char and key.char == 'd') self.deleteVisualSelection()
            else self.setStatus("cancelled", .{});
            return;
        }
        switch (key) {
            .escape => { self.exitTracksVisual(); self.setStatus("selection cancelled", .{}); },
            .char => |c| switch (c) {
                '1'...'9' => { _ = self.modal.handle(key); },
                '0' => if (self.modal.count > 0) {
                    _ = self.modal.handle(key);
                } else self.setTrackRow(0),
                'j' => self.setTrackRow(@min(self.track_row +| @as(usize, @intCast(self.takeCount())), self.track_rows_len -| 1)),
                'k' => self.setTrackRow(self.track_row -| @as(usize, @intCast(self.takeCount()))),
                'G' => self.setTrackRow(self.track_rows_len -| 1),
                'o' => if (self.tracks_visual_anchor) |anchor| {
                    self.tracks_visual_anchor = self.track_row;
                    self.setTrackRow(anchor);
                },
                'g' => self.groupSelectedTracks(),
                'm' => self.doVisualMuteToggle(),
                'S' => self.doVisualSoloToggle(),
                'd' => { self.tracks_del_pending = true; },
                'Y' => self.doVisualDup(),
                '-' => self.doVisualGainStep(-1.0),
                '+', '=' => self.doVisualGainStep(1.0),
                '<' => self.doVisualPanStep(-0.05),
                '>' => self.doVisualPanStep(0.05),
                '[' => self.doVisualColorCycle(-1),
                ']' => self.doVisualColorCycle(1),
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

    /// Track indices covered by display rows `[lo, hi]`: track rows join
    /// directly and a *folded* group row brings its hidden members along; an
    /// unfolded group's own row contributes nothing since its members are
    /// rows of their own. Shared by the group-selection and bulk mixer/
    /// delete ops below. Caller owns the returned list.
    fn resolveVisualTrackIndices(self: *App, lo: usize, hi: usize) std.ArrayListUnmanaged(u16) {
        var out: std.ArrayListUnmanaged(u16) = .empty;
        const rows = self.track_rows_buf[lo..@min(hi + 1, self.track_rows_len)];
        for (rows) |r| switch (r) {
            .track => |t| out.append(self.allocator, t) catch {},
            .group => |g| if (self.session.groups[g].?.folded) {
                for (self.session.project.tracks.items, 0..) |t, j| {
                    const tg = t.group orelse continue;
                    if (tg == g) out.append(self.allocator, @intCast(j)) catch {};
                }
            },
        };
        return out;
    }

    /// How every `doVisual*` below opens: resolve the anchor..cursor range to
    /// track indices and leave visual mode. Null (with the status line already
    /// explaining why) when the range holds no tracks - a group header row on
    /// its own resolves to nothing. The caller owns the returned list.
    fn takeVisualTrackSelection(self: *App) ?std.ArrayListUnmanaged(u16) {
        const anchor = self.tracks_visual_anchor orelse self.track_row;
        const lo = @min(anchor, self.track_row);
        const hi = @max(anchor, self.track_row);
        self.exitTracksVisual();

        var sel = self.resolveVisualTrackIndices(lo, hi);
        if (sel.items.len == 0) {
            sel.deinit(self.allocator);
            self.setStatus("no tracks selected", .{});
            return null;
        }
        return sel;
    }

    /// `g` in tracks-view visual mode: create a new untitled group from the
    /// selected rows.
    fn groupSelectedTracks(self: *App) void {
        var sel = self.takeVisualTrackSelection() orelse return;
        defer sel.deinit(self.allocator);

        const idx = self.session.addGroup("untitled group") catch |err| {
            switch (err) {
                error.GroupLimitReached => self.setStatus("group: bank full ({d} groups)", .{engine_mod.max_groups}),
                error.OutOfMemory => self.setStatus("group: out of memory", .{}),
            }
            return;
        };
        for (sel.items) |t| self.session.assignTrackGroup(t, idx);
        self.dirty = true;
        self.rebuildTrackRows();
        self.setTrackRow(self.rowOfGroup(idx) orelse 0);
    }

    /// `m`/`S` in tracks-view visual mode: mute/solo every selected track at
    /// once, all-or-nothing - if any selected track isn't muted/soloed yet,
    /// this turns it on for all of them; if they're already all on, it turns
    /// them all off. Always the member tracks' own flags (never
    /// GroupState.muted/soloed - a visual selection is an arbitrary row
    /// range, not necessarily a whole bus).
    fn doVisualToggle(self: *App, solo: bool) void {
        var sel = self.takeVisualTrackSelection() orelse return;
        defer sel.deinit(self.allocator);

        var all = true;
        for (sel.items) |t| {
            const trk = self.session.project.tracks.items[t];
            if (!(if (solo) trk.soloed else trk.muted)) all = false;
        }
        const want = !all;
        for (sel.items) |t| if (solo) self.apiSetTrackSoloed(t, want) else self.apiSetTrackMuted(t, want);
        const verb = if (solo) (if (want) "soloed" else "unsoloed") else (if (want) "muted" else "unmuted");
        self.setStatus("{s} {d} tracks", .{ verb, sel.items.len });
    }
    fn doVisualMuteToggle(self: *App) void {
        self.doVisualToggle(false);
    }
    fn doVisualSoloToggle(self: *App) void {
        self.doVisualToggle(true);
    }

    /// `-`/`+` and `<`/`>` in tracks-view visual mode: step every selected
    /// track's own gain/pan by the same delta (not set to one shared value -
    /// each track keeps riding its own fader, same as pressing the
    /// single-track key on each of them in turn).
    fn doVisualGainStep(self: *App, delta_db: f32) void {
        var sel = self.takeVisualTrackSelection() orelse return;
        defer sel.deinit(self.allocator);

        for (sel.items) |t| {
            const before = self.session.project.tracks.items[t].gain_db;
            self.apiSetTrackGainDb(t, before + delta_db);
            history.recordTrackMixer(self, t, .gain, before);
        }
        self.setStatus("gain {s}{d:.1}dB on {d} tracks", .{ if (delta_db >= 0) "+" else "", delta_db, sel.items.len });
    }

    fn doVisualPanStep(self: *App, delta: f32) void {
        var sel = self.takeVisualTrackSelection() orelse return;
        defer sel.deinit(self.allocator);

        for (sel.items) |t| {
            const before = self.session.project.tracks.items[t].pan;
            self.apiSetTrackPan(t, before + delta);
            history.recordTrackMixer(self, t, .pan, before);
        }
        self.setStatus("pan {s}{d:.0}% on {d} tracks", .{ if (delta >= 0) "R" else "L", @abs(delta) * 100.0, sel.items.len });
    }

    /// `[`/`]` in tracks-view visual mode: cycle every selected track's own
    /// color by one step, same relative-not-absolute shape as the gain/pan
    /// steps above.
    fn doVisualColorCycle(self: *App, dir: i32) void {
        var sel = self.takeVisualTrackSelection() orelse return;
        defer sel.deinit(self.allocator);

        const n: i32 = @intCast(ansi.track_palette.len + 1); // +1 for "none"
        for (sel.items) |t| {
            const track = &self.session.project.tracks.items[t];
            const cur: i32 = @mod(@as(i32, track.color), n);
            track.color = @intCast(@mod(cur + dir, n));
        }
        self.dirty = true;
        self.setStatus("cycled color on {d} tracks", .{sel.items.len});
    }

    /// `Y` in tracks-view visual mode: duplicate every selected track.
    /// Reuses `doTrackDup` per track - each duplicate appends at the end, so
    /// unlike delete there's no index-shift ordering to worry about.
    fn doVisualDup(self: *App) void {
        var sel = self.takeVisualTrackSelection() orelse return;
        defer sel.deinit(self.allocator);

        const count = sel.items.len;
        for (sel.items) |t| self.doTrackDup(t);
        self.setStatus("duplicated {d} tracks", .{count});
    }

    /// `dd` in tracks-view visual mode: delete every selected track. Reuses
    /// `doTrackDel` per track (undo, index remap, stale-editor exit all
    /// still apply) - deleting highest index first keeps every remaining
    /// selected index valid, since a delete only shifts indices above it.
    fn deleteVisualSelection(self: *App) void {
        var sel = self.takeVisualTrackSelection() orelse return;
        defer sel.deinit(self.allocator);

        std.mem.sort(u16, sel.items, {}, std.sort.desc(u16));
        const count = sel.items.len;
        for (sel.items) |t| self.doTrackDel(t);
        self.setStatus("deleted {d} tracks", .{count});
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

    pub fn setInputMonitor(self: *App, mode: InputMonitor) bool {
        if (mode == .on and self.audio_input.active == .none) {
            self.audio_input.start(self.session.project.sample_rate, self.audio_input_device.slice()) catch {
                self.setStatus("monitor: no audio input device", .{});
                return false;
            };
        } else if (mode != .on and self.recording_active_len == 0 and self.audio_input.active != .none) {
            self.audio_input.stop();
        }
        self.input_monitor = mode;
        self.setStatus("input monitor {s}", .{@tagName(mode)});
        return true;
    }

    fn drainInputMonitor(self: *App) void {
        while (self.audio_input.popDropout()) |_| {}
        while (self.audio_input.pop()) |block| self.session.engine.monitorInputInterleaved(block.samples[0 .. block.frames * block.channels], block.channels);
    }

    pub fn setPunch(self: *App, enabled: bool) bool {
        const p = &self.session.project;
        if (enabled and (!p.loop_enabled or p.loop_end_bar <= p.loop_start_bar)) {
            self.setStatus("punch: set and enable A/B bounds first", .{});
            return false;
        }
        self.punch_enabled = enabled;
        self.setStatus("punch {s}", .{if (enabled) "on" else "off"});
        return true;
    }

    pub fn recordingPositionAllowed(self: *const App, position_frames: u64) bool {
        if (!self.punch_enabled and self.recording_punch_start_bar == null) return true;
        const start = self.session.project.frameAtBar(self.recording_punch_start_bar orelse self.session.project.loop_start_bar);
        const end = self.session.project.frameAtBar(self.recording_punch_end_bar orelse self.session.project.loop_end_bar);
        return position_frames >= start and position_frames < end;
    }

    /// Called by `tick` the instant a record pass's count-in finishes and
    /// the transport actually starts (playing false->true) with pending
    /// audio targets queued. Opens the input device for real; a missing
    /// device (or a platform with no capture backend) reports status and
    /// leaves the pass MIDI-only rather than failing the whole record.
    fn startPendingRecording(self: *App) void {
        if (self.recording_pending_len == 0) return;
        if (self.audio_input.active == .none) {
            self.audio_input.start(self.session.project.sample_rate, self.audio_input_device.slice()) catch {
                self.setStatus("record: no audio input device", .{});
                self.recording_pending_len = 0;
                return;
            };
        }
        self.recording_take = RecordingTake.start(
            self.io,
            @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(self.io).nanoseconds))),
            self.session.project.sample_rate,
            2,
        ) catch {
            if (self.input_monitor != .on) self.audio_input.stop();
            self.setStatus("record: cannot create recovery take", .{});
            self.recording_pending_len = 0;
            return;
        };
        self.recording_active_len = self.recording_pending_len;
        @memcpy(
            self.recording_active_buf[0..self.recording_active_len],
            self.recording_pending_buf[0..self.recording_pending_len],
        );
        self.recording_accum.clearRetainingCapacity();
        self.recording_dropout_frames = 0;
        self.recording_first_dropout_frame = null;
        self.recording_capture_base_frame = null;
        self.recording_pending_len = 0;
    }

    /// Drains whatever `audio_input` has queued into the recovery WAV -
    /// called every tick while a pass is active, and once more at the very
    /// end of `finishRecording` to pick up the tail.
    fn drainRecording(self: *App) void {
        while (self.audio_input.popDropout()) |dropout| {
            if (self.recording_first_dropout_frame == null) self.recording_first_dropout_frame = dropout.start_frame;
            self.recording_dropout_frames += dropout.frames;
        }
        const allowed = self.recordingPositionAllowed(self.session.engine.uiSnapshot().position_frames);
        while (self.audio_input.pop()) |block| {
            const sample_count = block.frames * block.channels;
            self.recording_channel_count = block.channels;
            if (self.input_monitor != .off) self.session.engine.monitorInputInterleaved(block.samples[0..sample_count], block.channels);
            if (!allowed) continue;
            if (self.recording_take) |*take| {
                if (self.recording_capture_base_frame == null) self.recording_capture_base_frame = block.start_frame;
                const relative_frame = block.start_frame - self.recording_capture_base_frame.?;
                take.appendAt(relative_frame, block.samples[0..sample_count], self.session.project.sample_rate) catch {
                    self.setStatus("record: recovery take write failed", .{});
                    break;
                };
            } else {
                // Synthetic tests and callers without a capture device.
                self.recording_accum.appendSlice(self.allocator, block.samples[0..sample_count]) catch break;
            }
        }
    }

    /// Called by `tick` when a record pass ends. Finalizes one project audio
    /// source, then places an independent region on every armed target.
    /// `pub` so tests can drive it directly with synthetic
    /// `recording_accum`/`recording_active_*` state, without a real capture
    /// device (mirrors `doTrackAdd`/`doTrackDup` etc. being `pub` for the
    /// same reason).
    pub fn finishRecording(self: *App) void {
        if (self.recording_active_len == 0) return;
        if (self.input_monitor != .on) self.audio_input.stop();
        self.drainRecording();

        var disk_samples: ?[]f32 = null;
        defer if (disk_samples) |samples| self.allocator.free(samples);
        if (self.recording_take) |*take| {
            take.finish();
            const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, take.pathSlice(), self.allocator, .limited(4 * 1024 * 1024 * 1024)) catch {
                self.setStatus("record: recovery take kept at {s}", .{take.pathSlice()});
                self.recording_active_len = 0;
                self.recording_take = null;
                self.recording_loop_start_bar = null;
                self.recording_loop_end_bar = null;
                return;
            };
            defer self.allocator.free(bytes);
            const parsed = ws.wav.parseInterleavedAlloc(self.allocator, bytes) catch {
                self.setStatus("record: recovery take kept at {s}", .{take.pathSlice()});
                self.recording_active_len = 0;
                self.recording_take = null;
                self.recording_loop_start_bar = null;
                self.recording_loop_end_bar = null;
                return;
            };
            disk_samples = parsed.samples;
            self.recording_channel_count = parsed.channel_count;
        }
        const captured = disk_samples orelse self.recording_accum.items;
        const channel_count = @max(self.recording_channel_count, 1);
        const captured_frames = captured.len / channel_count;

        const targets = self.recording_active_buf[0..self.recording_active_len];
        if (captured.len == 0) {
            self.setStatus("no audio captured", .{});
            if (self.recording_take) |*take| take.discard();
            self.recording_take = null;
            self.recording_active_len = 0;
            self.recording_loop_start_bar = null;
            self.recording_loop_end_bar = null;
            return;
        }

        const source_path = if (self.recording_take) |*take| take.pathSlice() else "recorded";
        const sr_f: f64 = @floatFromInt(self.session.project.sample_rate);
        const loop_bars = if (self.recording_loop_start_bar != null and self.recording_loop_end_bar.? > self.recording_loop_start_bar.?)
            self.recording_loop_end_bar.? - self.recording_loop_start_bar.?
        else
            0;
        const loop_frames: usize = if (loop_bars > 0)
            @intCast(@min(self.session.project.frameAtBar(self.recording_loop_end_bar.?) -| self.session.project.frameAtBar(self.recording_loop_start_bar.?), std.math.maxInt(usize)))
        else
            captured_frames;
        const loop_samples = loop_frames * channel_count;
        const take_count = (captured.len + loop_samples - 1) / loop_samples;
        const start_bar = self.recording_punch_start_bar orelse self.recording_loop_start_bar orelse self.arr_cursor_bar;
        const start_tick = start_bar *| self.arr_grid.ticks();
        const start_frame = self.session.project.framesAtBeat(ws.time_grid.tickToBeat(start_tick));
        for (targets) |track_idx| history.recordLane(self, track_idx);

        var clip_count: usize = 0;
        for (0..take_count) |take_index| {
            const lo = take_index * loop_samples;
            const hi = @min(lo + loop_samples, captured.len);
            const take_samples = captured[lo..hi];
            const take_frames = take_samples.len / channel_count;
            const beats = self.session.project.beatAtFrames(start_frame +| take_frames) - self.session.project.beatAtFrames(start_frame);
            const length_ticks: u32 = if (loop_bars > 0 and take_frames == loop_frames)
                @intFromFloat(@min((self.session.project.beatAtBar(start_bar +| loop_bars) - self.session.project.beatAtBar(start_bar)) * ws.time_grid.ticks_per_beat, std.math.maxInt(u32)))
            else
                @max(1, @as(u32, @intFromFloat(@ceil(beats * ws.time_grid.ticks_per_beat - 1e-9))));
            const source_id = self.session.project.addAudioSource(source_path, self.session.project.sample_rate, channel_count, take_samples) catch continue;
            for (targets) |track_idx| {
                const lane = self.session.arrangement.lane(track_idx) orelse continue;
                if (lane.clipAt(start_tick)) |clip| {
                    if (clip.start_tick == start_tick and clip.addAudioTake(.{
                        .source_id = source_id,
                        .source_start_frame = 0,
                        .source_length_frames = take_frames,
                        .length_ticks = length_ticks,
                    })) {
                        clip_count += 1;
                        continue;
                    }
                }
                lane.place(self.allocator, ws.Clip.initAudio(start_tick, length_ticks, .{
                    .source_id = source_id,
                    .source_start_frame = 0,
                    .source_length_frames = take_frames,
                })) catch continue;
                clip_count += 1;
            }
        }
        if (self.session.song_mode) self.session.rebuildSongData();

        const secs = @as(f64, @floatFromInt(captured_frames)) / sr_f;
        if (self.recording_first_dropout_frame) |frame| {
            self.setStatus("recorded {d} clip(s), dropout {d} frames at frame {d}", .{ clip_count, self.recording_dropout_frames, frame });
        } else {
            self.setStatus("recorded {d} take(s) on {d} track(s) ({d:.1}s)", .{ take_count, targets.len, secs });
        }
        if (clip_count > 0) self.dirty = true;
        self.recording_take = null;
        self.recording_dropout_frames = 0;
        self.recording_first_dropout_frame = null;
        self.recording_capture_base_frame = null;
        self.recording_active_len = 0;
        self.recording_loop_start_bar = null;
        self.recording_loop_end_bar = null;
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
    pub fn openInstrumentPicker(self: *App, cursor: usize, replace: bool) void {
        self.picker_replace = replace;
        self.picker_cursor = 0;
        self.instrument_picker_filter_len = 0;
        if (cursor < self.session.racks.items.len) {
            const kind = std.meta.activeTag(self.session.racks.items[cursor].instrument);
            for (instrument_picker_items, 0..) |item, i| {
                if (item.kind == kind) { self.picker_cursor = @intCast(i); break; }
            }
        }
        self.view = .instrument_picker;
    }

    /// Open the editor matching the track's instrument, or the instrument
    /// picker if the track is blank.
    /// The note editor for a track: the piano roll on a melodic instrument,
    /// the step grid on a drum machine / slicer. Bound to `p` everywhere the
    /// piano roll used to be bound to it (see openTrack's comment).
    pub fn openStepEditor(self: *App, track: u16) void {
        if (track >= self.session.racks.items.len) return;
        switch (self.session.racks.items[track].instrument) {
            .drum_machine => {
                self.drum_track = track;
                self.drum_stamp = false;
                self.view = .drum_grid;
                self.autoSongMode(false);
            },
            .slicer => {
                self.slicer_track = track;
                self.slicer_cursor[0] = @min(self.slicer_cursor[0], self.session.racks.items[track].instrument.slicer.slice_count -| 1);
                self.view = .slicer_grid;
                self.autoSongMode(false);
            },
            else => {
                piano_ed.switchTo(self, track);
                if (self.view == .piano_roll) self.autoSongMode(false);
            },
        }
    }

    fn openTrack(self: *App, cursor: usize) void {
        if (cursor >= self.session.racks.items.len) return;
        switch (self.session.racks.items[cursor].instrument) {
            .empty => self.openInstrumentPicker(cursor, false),
            .poly_synth => {
                self.synth_track = @intCast(cursor);
                self.synth_cursor = 2;
                self.synth_subview = .main;
                self.synth_section_focus = false;
                self.view = .synth_editor;
            },
            .sampler => {
                self.sampler_target = .{ .sampler = @intCast(cursor) };
                self.sampler_param = 0;
                self.sampler_return = .tracks;
                self.view = .sampler_editor;
            },
            // A drum machine / slicer is a multisampler: enter opens the
            // pad (slice) control panel, the same way enter opens a synth's
            // or sampler's params, and `p` opens its step grid - the note
            // editor a melodic track reaches with the same key.
            .drum_machine => {
                self.drum_track = @intCast(cursor);
                self.drum_stamp = false;
                self.sampler_target = .{ .drum = @intCast(cursor) };
                self.sampler_param = 0;
                self.sampler_return = .tracks;
                self.view = .sampler_editor;
            },
            .slicer => {
                self.slicer_track = @intCast(cursor);
                self.slicer_cursor[0] = @min(self.slicer_cursor[0], self.session.racks.items[cursor].instrument.slicer.slice_count -| 1);
                self.sampler_target = .{ .slice = @intCast(cursor) };
                self.sampler_param = 0;
                self.sampler_return = .tracks;
                self.view = .sampler_editor;
            },
            .clap => commands.cmdClapGui(self, ""),
            .vst3 => commands.cmdVst3Gui(self, ""),
            .soundfont, .acoustic => {
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
        var buf: [instrument_picker_items.len]InstrumentPickerItem = undefined;
        const count = self.filteredInstrumentPickerItems(&buf).len + self.filteredInstrumentPluginCount();
        if (count > 0 and self.picker_cursor >= count) self.picker_cursor = @intCast(count - 1);
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
        var buf: [instrument_picker_items.len]InstrumentPickerItem = undefined;
        const items = self.filteredInstrumentPickerItems(&buf);
        if (self.picker_cursor >= items.len) {
            const plugin = self.filteredInstrumentPluginAt(self.picker_cursor - items.len) orelse return;
            var backup = history.captureTrackKindSwap(self, self.cursor);
            switch (plugin.format) {
                .clap => self.session.setClapInstrument(self.cursor, plugin.path, plugin.id) catch |err| {
                    if (backup) |*b| b.deinit(self.allocator);
                    std.log.err("failed to load {s}: {s}", .{ plugin.name, @errorName(err) });
                    self.setStatus("{s}: {s}", .{ plugin.name, @errorName(err) });
                    return;
                },
                .vst3 => self.session.setVst3Instrument(self.cursor, plugin.path, plugin.id, plugin.name) catch |err| {
                    if (backup) |*b| b.deinit(self.allocator);
                    std.log.err("failed to load {s}: {s}", .{ plugin.name, @errorName(err) });
                    self.setStatus("{s}: {s}", .{ plugin.name, @errorName(err) });
                    return;
                },
            }
            history.push(self, backup);
            self.dirty = true;
            // CLAP instruments always go through `setClapInstrument`, which
            // (like `setInstrument`) has no note-preserving counterpart - see
            // `Session.changeInstrumentKind`'s doc comment on why a bare
            // kind-to-CLAP swap can't be built without a path/id.
            self.setStatus("{s}  {s}  {s}", .{ plugin.name, ws.plugin_catalog.formatLabel(plugin.format), if (self.picker_replace) "(notes cleared)" else "inserted" });
            self.view = .tracks;
            self.openTrack(self.cursor);
            return;
        }
        const item = items[self.picker_cursor];
        const kind = item.kind;
        if (self.picker_replace) {
            if (std.meta.activeTag(self.session.racks.items[self.cursor].instrument) == kind) {
                self.setStatus("track {d} is already {s}", .{ self.cursor + 1, item.label });
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
            if (kind == .acoustic) self.loadDefaultAcoustic(self.cursor);
            if (preserved) {
                self.setStatus("track {d}: now {s} (notes kept)", .{ self.cursor + 1, item.label });
            } else {
                self.setStatus("track {d}: now {s} (no compatible mapping - notes cleared)", .{ self.cursor + 1, item.label });
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
        if (kind == .acoustic) self.loadDefaultAcoustic(self.cursor);
        self.dirty = true;
        const hint: []const u8 = switch (kind) {
            .empty => "?: help",
            .poly_synth => "j/k: move  h/l: adjust  i: play  ?: help",
            .sampler => "j/k: move  h/l: adjust  i: play  ?: help",
            .drum_machine => "enter: pads  p: steps  i: play  ?: help",
            .slicer => "enter: slices  p: steps  :load  ?: help",
            .clap, .vst3 => "enter: plugin GUI  p: piano  i: play  ?: help",
            .soundfont => "h/l: adjust  :load  i: play  ?: help",
            .acoustic => "h/l: adjust  f: banks  i: play  ?: help",
        };
        self.setStatus("{s} inserted  {s}", .{ item.label, hint });
        self.view = .tracks;
        self.openTrack(self.cursor);
    }

    pub fn clickInstrumentPickerItem(self: *App, ordinal: usize, now_ns: i96) void {
        if (self.modal.mode == .search) self.handleKey(.enter, now_ns);
        self.picker_cursor = @intCast(ordinal);
        self.handleKey(.enter, now_ns);
    }

    pub fn clickPresetPickerItem(self: *App, ordinal: usize, now_ns: i96) void {
        if (self.modal.mode == .search) self.handleKey(.enter, now_ns);
        self.preset_picker_cursor = ordinal;
        self.handleKey(.enter, now_ns);
    }

    /// A fresh acoustic track starts on the grand piano - the instrument is
    /// its bundled bank, so landing on an empty one would be a dead track.
    pub fn loadDefaultAcoustic(self: *App, track: usize) void {
        if (track >= self.session.racks.items.len) return;
        const sf = switch (self.session.racks.items[track].instrument) {
            .acoustic => |*instrument| instrument,
            else => return,
        };
        sf.loadBuiltin(self.io, .grand) catch |err| {
            self.setStatus("grand piano: {s}", .{@errorName(err)});
        };
    }

    // zig fmt: off
    /// FX picker: j/k move, g/G jump to ends, `/` filters (see
    /// spectrum_ed.activeFilter), enter/space insert the highlighted effect
    /// after the focused chain slot, esc cancels back to the chain view.
    /// Opened by `a` in the FX chain view (see editors/fx_editor.zig's
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

    pub fn clickFxPickerItem(self: *App, ordinal: usize, now_ns: i96) void {
        if (self.modal.mode == .search) self.handleKey(.enter, now_ns);
        self.fx_picker_cursor = @intCast(ordinal);
        var buf: [spectrum_ed.picker_kinds.len]ws.FxKind = undefined;
        self.activateFxPickerItem(spectrum_ed.filteredPickerKinds(self, &buf));
    }

    /// FX picker: click a row to select + insert it (same as enter/space);
    /// scroll moves the highlight, Ctrl ten entries.
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
                self.clickFxPickerItem(item.?, self.now_ns);
            },
            .scroll_up => { self.fx_picker_cursor -|= if (ev.ctrl) 10 else 1; },
            .scroll_down => { self.fx_picker_cursor = @intCast(modal_mod.clampDelta(self.fx_picker_cursor, if (ev.ctrl) 10 else 1, @intCast(kinds.len + external_count -| 1))); },
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

    pub fn clickAutomationParamPickerItem(self: *App, index: usize, now_ns: i96) void {
        if (self.modal.mode == .search) self.handleKey(.enter, now_ns);
        self.automation_param_cursor = @intCast(index);
        self.automationParamPick();
    }

    // zig fmt: off
    /// Param picker: click a param row to select + apply it (same as enter/
    /// space); header rows aren't clickable. Scroll moves the highlight,
    /// Ctrl ten entries.
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
                    .param => |i| self.clickAutomationParamPickerItem(i, self.now_ns),
                }
            },
            .scroll_up => automation_ed.moveParamCursor(self, if (ev.ctrl) -10 else -1),
            .scroll_down => automation_ed.moveParamCursor(self, if (ev.ctrl) 10 else 1),
            else => {},
        }
    }
    // zig fmt: on

    // -----------------------------------------------------------------------
    // File browser (netrw/dired-style; `:e`, `:load` with
    // no path open it - see commands.zig)
    // -----------------------------------------------------------------------

    /// Remember `path`'s directory as where the browser reopens - see
    /// `last_load_dir`. Called for every file the `:load` family reads,
    /// browser-picked or typed, so both routes leave the same trail.
    pub fn noteLoadDir(self: *App, path: []const u8) void {
        const dir = std.fs.path.dirname(path) orelse return; // bare filename: cwd, already the fallback
        if (dir.len == 0 or dir.len > self.last_load_dir.buf.len) return;
        @memcpy(self.last_load_dir.buf[0..dir.len], dir);
        self.last_load_dir.len = @intCast(dir.len);
    }

    // File browser + recent-projects + bookmarks: bodies live in
    // app_browser.zig, re-exported here under their own names so every
    // self.openBrowser(...)-style call site above and every external
    // app.openBrowser(...) caller keep resolving unchanged.
    pub const openBrowser = app_browser.openBrowser;
    pub const freeBrowserEntries = app_browser.freeBrowserEntries;
    pub const setBrowserDir = app_browser.setBrowserDir;
    pub const browserEntryLess = app_browser.browserEntryLess;
    pub const handleBrowserKey = app_browser.handleBrowserKey;
    pub const openRecentProjects = app_browser.openRecentProjects;
    pub const handleRecentProjectKey = app_browser.handleRecentProjectKey;
    pub const openRecentProject = app_browser.openRecentProject;
    pub const toggleBookmark = app_browser.toggleBookmark;
    pub const handleBookmarkListKey = app_browser.handleBookmarkListKey;
    pub const jumpToBookmark = app_browser.jumpToBookmark;
    pub const browserGoUp = app_browser.browserGoUp;
    pub const browserActivate = app_browser.browserActivate;
    pub const auditionBrowserEntry = app_browser.auditionBrowserEntry;
    pub const closeBrowser = app_browser.closeBrowser;
    pub const clearBrowserVisual = app_browser.clearBrowserVisual;

    // zig fmt: off
    /// Track that mute/solo/note-preview act on outside the tracks view -
    /// the track whose editor is actually open, not the (possibly stale)
    /// tracks-view cursor. Keep this in sync with every per-track editor;
    /// missing a view here means mute/solo/preview silently hit the wrong
    /// track whenever that view's own track diverges from `self.cursor`.
    pub fn currentTrack(self: *App) u16 {
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
                const end_frames = self.session.engine.transport.framesAtBeats(self.contentBeats());
                _ = self.session.engine.send(.{ .seek_frames = end_frames });
            },
            .volume_delta => |delta| self.apiSetMasterGainDb(self.master_gain_db + @as(f32, @floatFromInt(delta))),
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
                    if (self.recording_punch_start_bar != null) self.session.syncLoop();
                    self.recording_punch_start_bar = null;
                    self.recording_punch_end_bar = null;
                    self.recording_loop_start_bar = null;
                    self.recording_loop_end_bar = null;
                    self.setStatus("count-in cancelled", .{});
                } else if (!snap.playing and (self.hasArmedAudioTarget() or
                    (self.modal.mode == .insert and (self.view == .piano_roll or self.view == .drum_grid or self.view == .slicer_grid))))
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
                    self.recording_punch_start_bar = if (self.punch_enabled) self.session.project.loop_start_bar else null;
                    self.recording_punch_end_bar = if (self.punch_enabled) self.session.project.loop_end_bar else null;
                    self.recording_loop_start_bar = if (!self.punch_enabled and self.session.project.loop_enabled) self.session.project.loop_start_bar else null;
                    self.recording_loop_end_bar = if (self.recording_loop_start_bar != null) self.session.project.loop_end_bar else null;
                    if (self.punch_enabled) {
                        _ = self.session.engine.send(.{ .set_loop = .{
                            .enabled = false,
                            .start_frames = self.session.project.frameAtBar(self.session.project.loop_start_bar),
                            .end_frames = self.session.project.frameAtBar(self.session.project.loop_end_bar),
                        } });
                    } else if (self.recording_loop_start_bar) |start_bar| {
                        _ = self.session.engine.send(.{ .seek_frames = self.session.project.frameAtBar(start_bar) });
                    }
                    _ = self.session.engine.send(.{ .record = self.count_in_bars });
                    if (self.count_in_bars > 0) self.setStatus("count-in...", .{});
                } else {
                    const cmd: engine_mod.Command = if (snap.playing) .stop else .play;
                    _ = self.session.engine.send(cmd);
                    if (snap.playing and self.recording_punch_start_bar != null) self.session.syncLoop();
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
                self.apiSetTrackMuted(track_idx, !track.muted);
                self.setStatus("\"{s}\" {s}", .{ track.name, if (track.muted) "muted" else "unmuted" });
            },
            .toggle_solo => {
                const track_idx = self.currentTrack();
                if (track_idx >= self.session.project.tracks.items.len) {
                    self.setStatus("master bus has no solo", .{});
                    return;
                }
                const track = &self.session.project.tracks.items[track_idx];
                self.apiSetTrackSoloed(track_idx, !track.soloed);
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
                    .poly_synth, .sampler, .clap, .vst3, .soundfont, .acoustic => {
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
                        self.preset_filter_len = copyTruncated(&self.preset_filter_buf, text);
                        self.preset_picker_cursor = 0;
                    },
                    .instrument_picker => {
                        self.instrument_picker_filter_len = copyTruncated(&self.instrument_picker_filter_buf, text);
                        self.picker_cursor = 0;
                    },
                    .fx_picker => {
                        self.fx_picker_filter_len = copyTruncated(&self.fx_picker_filter_buf, text);
                        self.fx_picker_cursor = 0;
                    },
                    .automation_param_picker => {
                        self.automation_param_filter_len = copyTruncated(&self.automation_param_filter_buf, text);
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

    pub fn activeInstrumentFilter(self: *App) []const u8 {
        return self.pickerFilterText(.instrument_picker, &self.instrument_picker_filter_buf, self.instrument_picker_filter_len);
    }

    pub fn filteredInstrumentPickerItems(self: *App, buf: *[instrument_picker_items.len]InstrumentPickerItem) []InstrumentPickerItem {
        const filter = self.activeInstrumentFilter();
        var n: usize = 0;
        for (instrument_picker_items) |item| {
            if (filter.len > 0 and !fuzzy.matches(filter, item.label) and !fuzzy.matches(filter, item.description)) continue;
            buf[n] = item;
            n += 1;
        }
        // Best match first, so the cursor already sits on what was typed for
        // rather than on whichever entry the table declares first. Stable, so
        // an empty filter leaves the table's own curated order alone.
        if (filter.len > 0) std.sort.insertion(InstrumentPickerItem, buf[0..n], filter, pickerItemRanksBefore);
        return buf[0..n];
    }

    /// A label match outranks a description match at any score: the label is
    /// what the user is looking at while they type.
    fn pickerItemRanksBefore(filter: []const u8, a: InstrumentPickerItem, b: InstrumentPickerItem) bool {
        return pickerItemScore(filter, a) > pickerItemScore(filter, b);
    }

    fn pickerItemScore(filter: []const u8, item: InstrumentPickerItem) i32 {
        if (fuzzy.score(filter, item.label)) |s| return s;
        if (fuzzy.score(filter, item.description)) |s| return s - 1000;
        return std.math.minInt(i32);
    }

    pub fn filteredInstrumentPluginCount(self: *App) usize {
        var count: usize = 0;
        for (self.external_plugins.plugins.items) |plugin| {
            if (plugin.role == .instrument and self.instrumentPluginMatches(&plugin)) count += 1;
        }
        return count;
    }

    pub fn filteredInstrumentPluginAt(self: *App, ordinal: usize) ?*const ws.plugin_catalog.Plugin {
        var index: usize = 0;
        for (self.external_plugins.plugins.items) |*plugin| {
            if (plugin.role != .instrument or !self.instrumentPluginMatches(plugin)) continue;
            if (index == ordinal) return plugin;
            index += 1;
        }
        return null;
    }

    fn instrumentPluginMatches(self: *App, plugin: *const ws.plugin_catalog.Plugin) bool {
        const filter = self.activeInstrumentFilter();
        return filter.len == 0 or fuzzy.matches(filter, plugin.name) or fuzzy.matches(filter, plugin.vendor);
    }

    fn setSearchPattern(self: *App, text: []const u8) void {
        self.search_pattern_len = copyTruncated(&self.search_pattern_buf, text);
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
        const candidates = synth_ed.searchCandidates(&cbuf);
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
    pub const TabCycle = struct {
        insert_at: usize,
        stem_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined,
        stem_len: usize,
        source: Source,
        index: usize,
        last_written: []const u8,

        pub const Source = enum { command_name, drum_kit, synth_preset, euclid, metronome, scale, colorscheme };

        pub fn stem(self: *const TabCycle) []const u8 {
            return self.stem_buf[0..self.stem_len];
        }
    };

    // Command history + tab completion: bodies live in app_completion.zig,
    // re-exported here under their own names so self.pushCommandHistory(...)
    // -style call sites elsewhere in App keep resolving unchanged.
    pub const pushCommandHistory = app_completion.pushCommandHistory;
    pub const commandHistoryPrev = app_completion.commandHistoryPrev;
    pub const commandHistoryNext = app_completion.commandHistoryNext;
    pub const loadCommandHistory = app_completion.loadCommandHistory;
    pub const completeCommand = app_completion.completeCommand;
    pub const completeArgument = app_completion.completeArgument;
    pub const cycleCompletion = app_completion.cycleCompletion;
    pub const activeCommandCycle = app_completion.activeCommandCycle;
    pub const suggestionSelected = app_completion.suggestionSelected;
    pub const suggestionFilterText = app_completion.suggestionFilterText;

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
        self.servicePluginHosts();
        commands_tracks.pollCcLearn(self);
        const dropped_commands = self.session.engine.takeDroppedCommands();
        if (dropped_commands != 0) {
            self.setStatus("audio command queue full: {d} command{s} dropped", .{ dropped_commands, if (dropped_commands == 1) "" else "s" });
        }
        const excessive_latency = self.session.engine.takeExcessiveLatencyFrames();
        if (excessive_latency != 0) self.setStatus("PDC limit exceeded by {d} frames", .{excessive_latency});
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
        const position_frames = self.session.engine.uiSnapshot().position_frames;
        const punch_end = self.session.project.frameAtBar(self.recording_punch_end_bar orelse self.session.project.loop_end_bar);
        if (self.recording_active_len > 0 and self.recording_punch_start_bar != null and position_frames >= punch_end)
            self.finishRecording()
        else if (self.recording_active_len > 0) self.drainRecording();
        if (self.recording_active_len == 0 and self.input_monitor == .on) self.drainInputMonitor();
        if (!playing and was_playing) self.finishRecording();
        if (!playing and was_playing) self.recording_punch_start_bar = null;
        if (!playing and was_playing) self.recording_punch_end_bar = null;
    }

    pub fn reportAudioHealth(self: *App, health: ws.AudioHost.Health) void {
        if (health.deadline_misses == 0) return;
        self.setStatus("audio: {d} deadline miss{s}, peak {d:.2}ms", .{
            health.deadline_misses,
            if (health.deadline_misses == 1) "" else "es",
            @as(f64, @floatFromInt(health.peak_callback_ns)) / std.time.ns_per_ms,
        });
    }

    /// External-plugin main-thread callbacks and dirty-state notifications share the
    /// frontend-neutral frame tick so TUI and GUI hosts behave identically.
    fn servicePluginHosts(self: *App) void {
        var stalled: u32 = 0;
        var crashed: u32 = 0;
        for (self.session.racks.items) |rack| {
            switch (rack.instrument) {
                .clap => |plugin| self.servicePlugin(plugin, &stalled, &crashed),
                .vst3 => |plugin| self.servicePlugin(plugin, &stalled, &crashed),
                else => {},
            }
            self.serviceFxHosts(&rack.fx, &stalled, &crashed);
        }
        self.serviceFxHosts(&self.session.master_fx, &stalled, &crashed);
        for (&self.session.groups) |*group| if (group.*) |*g| self.serviceFxHosts(&g.fx, &stalled, &crashed);
        if (crashed != 0) {
            self.setStatus("plugin host: {d} crashed", .{crashed});
        } else if (stalled != 0) {
            self.setStatus("plugin host: {d} stalled block{s}", .{ stalled, if (stalled == 1) "" else "s" });
        }
    }

    fn servicePlugin(self: *App, plugin: anytype, stalled: *u32, crashed: *u32) void {
        if (plugin.serviceMainThread()) self.dirty = true;
        stalled.* +|= plugin.takeHostStalledBlocks();
        crashed.* +|= @intFromBool(plugin.takeHostCrashed());
    }

    fn serviceFxHosts(self: *App, fx: *ws.Fx, stalled: *u32, crashed: *u32) void {
        for (fx.units.items) |unit| switch (unit.payload) {
            .clap => |plugin| self.servicePlugin(plugin, stalled, crashed),
            .vst3 => |plugin| self.servicePlugin(plugin, stalled, crashed),
            else => {},
        };
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

    /// Write the `<path>~` backup right now for maybeAutosave.
    fn writeBackup(self: *App) void {
        var buf: [reload_path_buf_len]u8 = undefined;
        const backup = self.backupPath(&buf) orelse return;
        ws.persist.save(self.allocator, &self.session, self.io, backup) catch {};
    }

    /// Startup recovery: maybeAutosave leaves `<path>~` behind on a
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

    /// Where a new track lands and which group it joins: right after the
    /// currently selected track (inheriting that track's group), or - on a
    /// group row - right after that group's last member, as a member of it.
    /// Landing next to a group without joining it was the only way to get a
    /// track "into" a group by hand, which isn't one at all - the row just
    /// rendered below the whole group block, ungrouped. The master row and
    /// any view outside `.tracks` (e.g. `:track-add` run from the synth
    /// editor) fall back to `self.cursor`, which every view keeps pointed at
    /// "the" current track; past the last real track (the master sentinel)
    /// that means append at the end, ungrouped.
    /// Re-syncs the row cursor itself rather than trusting the caller to
    /// have done it - same "call before any row-cursor read" rule
    /// `tracksRowSync`'s own doc comment gives.
    fn trackAddInsertIndex(self: *App) struct { at: u16, group: ?u8 } {
        const tracks = self.session.project.tracks.items;
        const total: u16 = @intCast(tracks.len);
        if (self.view == .tracks) {
            self.tracksRowSync();
            if (self.cursorGroup()) |g| {
                var last: ?u16 = null;
                for (tracks, 0..) |t, i| {
                    if (t.group == g) last = @intCast(i);
                }
                return .{ .at = if (last) |l| l + 1 else total, .group = g };
            }
            if (self.cursorTrack()) |t| return .{ .at = t + 1, .group = tracks[t].group };
            return .{ .at = total, .group = null };
        }
        if (self.cursor < total) return .{
            .at = @as(u16, @intCast(self.cursor)) + 1,
            .group = tracks[self.cursor].group,
        };
        return .{ .at = total, .group = null };
    }

    // zig fmt: off
    /// Rewrite every editor-target/pending-state track index for a
    /// structural track change (insert, delete, swap). One field checklist
    /// for all three ops, with `TrackRemap.apply` owning the arithmetic -
    /// the three lists this replaced were the standing source of the
    /// stale-index bug class. Any NEW field holding a track index must join
    /// this list - see project_bug_hunt_2026_07_11.
    ///
    /// A field naming a deleted track must not merely survive unshifted:
    /// the slot it names gets reused by whatever track shifts down into it,
    /// so keeping the old value would silently rebind the field (and any
    /// open editor keyed on it) to that unrelated track. It is bounced out
    /// of range instead, so the kindIs()/`>= racks.len` checks in
    /// exitStaleEditors always treat it as gone. A field already sitting at
    /// that sentinel names no track at all, so no later op disturbs it.
    pub fn remapTrackFields(self: *App, op: undo_mod.TrackRemap) void {
        const remapField = struct {
            fn f(field: *u16, op_: undo_mod.TrackRemap) void {
                if (field.* == std.math.maxInt(u16)) return;
                field.* = op_.apply(field.*) orelse std.math.maxInt(u16);
            }
        }.f;
        remapField(&self.synth_track, op);
        remapField(&self.drum_track, op);
        remapField(&self.piano_track, op);
        remapField(&self.eq_track, op);
        remapField(&self.slicer_track, op);
        remapField(&self.automation_track, op);
        remapField(&self.preset_picker_track, op);
        remapField(&self.soundfont_track, op);
        switch (self.sampler_target) {
            .drum    => |*t| remapField(t, op),
            .sampler => |*t| remapField(t, op),
            .slice   => |*t| remapField(t, op),
        }
        // A clip link has no sentinel to bounce to - it is dropped outright.
        if (self.piano_clip_link) |link| {
            if (op.apply(link.track)) |t| self.piano_clip_link.?.track = t
            else self.piano_clip_link = null;
        }
        if (self.automation_clip) |link| {
            if (op.apply(link.track)) |t| self.automation_clip.?.track = t
            else self.automation_clip = null;
        }
        // Pending qwerty note-offs name tracks too: drop a deleted track's
        // (its rack is being retired anyway), shift the rest, so a note
        // that outlives the delete is stopped on the track it's actually
        // still sounding on.
        var no_i: usize = 0;
        while (no_i < self.note_off_len) {
            if (op.apply(self.note_offs[no_i].track)) |t| {
                self.note_offs[no_i].track = t;
                no_i += 1;
            } else {
                std.mem.copyForwards(NoteOff, self.note_offs[no_i .. self.note_off_len - 1], self.note_offs[no_i + 1 .. self.note_off_len]);
                self.note_off_len -= 1;
            }
        }
    }
    // zig fmt: on

    pub fn doTrackAdd(self: *App, name_arg: ?[]const u8) void {
        self.doTrackAddKind(name_arg, .empty);
    }

    pub fn doTrackAddKind(self: *App, name_arg: ?[]const u8, kind: ws.InstrumentKind) void {
        const pos = self.trackAddInsertIndex();
        const name: []const u8 = name_arg orelse "untitled track";

        const idx = self.session.insertTrack(pos.at, name) catch |err| {
            if (err == error.TrackLimitReached)
                self.setStatus("track limit reached", .{})
            else
                self.setStatus("out of memory", .{});
            return;
        };

        const remap: undo_mod.TrackRemap = .{ .insert = idx };
        self.remapTrackFields(remap);
        if (pos.group) |g| self.session.assignTrackGroup(idx, g);

        history.retargetPending(self, remap);
        _ = self.history.retarget(self.allocator, remap);
        history.push(self, .{ .track_delete = idx });

        self.cursor = idx;
        self.invalidateTrackRow();
        self.dirty = true;
        const instrument_ok = if (kind == .empty) true else blk: {
            self.session.setInstrument(idx, kind) catch {
                self.setStatus("out of memory setting instrument", .{});
                break :blk false;
            };
            if (kind == .acoustic) self.loadDefaultAcoustic(idx);
            break :blk true;
        };
        if (instrument_ok) {
            // Read the group back off the track: `assignTrackGroup` drops a
            // stale index (a hand-edited file's, the one rebuildTrackRows
            // already renders as ungrouped) rather than trusting `pos`.
            if (self.session.project.tracks.items[idx].group) |g| {
                self.setStatus("added \"{s}\" (track {d}) to \"{s}\"", .{ name, idx + 1, self.session.groups[g].?.name });
            } else {
                self.setStatus("added \"{s}\" (track {d})", .{ name, idx + 1 });
            }
        }
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

        // Track indices shift below the deleted track: remap every undo/
        // redo entry (and any still-open nudge batch) to keep pointing at
        // the same physical track, dropping only entries that named the
        // deleted track itself. Must run BEFORE pushing `backup` below, or
        // this exact-match delete remap would immediately drop the entry
        // that restores the very track it names.
        const remap: undo_mod.TrackRemap = .{ .delete = @intCast(track_idx) };
        self.remapTrackFields(remap);
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
            .synth_editor => if (!kindIs(racks, self.synth_track, .poly_synth)) { self.view = .tracks; },
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
                switch (racks[self.piano_track].instrument) { .poly_synth, .sampler, .soundfont, .acoustic => false, else => true })
            {
                self.view = .tracks;
            },
            .soundfont_editor => if (!kindIs(racks, self.soundfont_track, .soundfont) and
                !kindIs(racks, self.soundfont_track, .acoustic)) { self.view = .tracks; },
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
                    .acoustic => kindIs(racks, self.preset_picker_track, .acoustic),
                };
                if (!ok) self.view = .tracks;
            },
            else => {},
        }
    }
    // zig fmt: on

    /// Deep-copy the track under the cursor into a new track appended at the
    /// end (see Session.duplicateTrack) and jump the cursor to it. Appending
    /// means no existing track's index shifts, so unlike delete this needs no
    /// remap of history or editor-target indices - but it is still a track
    /// appearing out of nowhere, so it takes the same `track_delete` undo
    /// entry `doTrackAddKind` pushes for `a`.
    pub fn doTrackDup(self: *App, track_idx: usize) void {
        const idx = self.session.duplicateTrack(track_idx) catch |err| {
            if (err == error.TrackLimitReached)
                self.setStatus("track limit reached", .{})
            else
                self.setStatus("out of memory", .{});
            return;
        };
        history.push(self, .{ .track_delete = @intCast(idx) });
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

        // A swap never removes a track, so unlike delete this never drops
        // an entry - every index just exchanges with its neighbor's.
        const remap: undo_mod.TrackRemap = .{ .swap = .{ .a = @intCast(cur), .b = @intCast(other) } };
        self.remapTrackFields(remap);
        history.retargetPending(self, remap);
        _ = self.history.retarget(self.allocator, remap);

        self.cursor = other;
        self.dirty = true;
        self.emitEvent(.{ .TrackMove = .{ .from = cur + 1, .to = other + 1 } });
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
        const cur: i32 = @mod(@as(i32, track.color), n);
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
        const before = t.pan;
        self.apiSetTrackPan(track, t.pan + delta);
        history.recordTrackMixer(self, track, .pan, before);
        const pct: i32 = @intFromFloat(@abs(t.pan) * 100.0);
        if (pct == 0) self.setStatus("track {d} pan: center", .{track + 1})
        else if (t.pan < 0) self.setStatus("track {d} pan: L{d}%", .{ track + 1, pct })
        else self.setStatus("track {d} pan: R{d}%", .{ track + 1, pct });
    }
    // zig fmt: on

    fn doTrackGainStep(self: *App, track: u16, delta_db: f32) void {
        if (track >= self.session.project.tracks.items.len) return;
        const t = &self.session.project.tracks.items[track];
        const before = t.gain_db;
        self.apiSetTrackGainDb(track, t.gain_db + delta_db);
        history.recordTrackMixer(self, track, .gain, before);
        const sign: []const u8 = if (t.gain_db >= 0) "+" else "";
        self.setStatus("track {d} gain: {s}{d:.1}dB", .{ track + 1, sign, t.gain_db });
    }

    /// The one place master gain is clamped and pushed to the engine - `[`/`]`,
    /// `-`/`+` on the master row, `:vol` and the GUI's master fader all route
    /// here so none of them can drift out of the -40..+6 dB range the others
    /// enforce. Deliberately not undoable: neither is the keyboard path.
    pub fn apiSetMasterGainDb(self: *App, db: f32) void {
        self.master_gain_db = std.math.clamp(db, -40.0, 6.0);
        _ = self.session.engine.send(.{ .set_master_gain = types.dbToGain(self.master_gain_db) });
        self.session.captureMixAutomation(.master_gain, self.master_gain_db);
    }

    /// `-`/`+` on the master row - same gesture as a track's gain step, but
    /// against `master_gain_db` (same range/behaviour as `:vol`/`[`/`]`).
    fn doMasterGainStep(self: *App, delta_db: f32) void {
        self.apiSetMasterGainDb(self.master_gain_db + delta_db);
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

    /// What to call the open project on screen: the file's name without its
    /// directory or `.wsj` extension, or the project's own name when nothing
    /// has been saved or opened yet. Both frontends title themselves
    /// "<this> - wstudio", and the TUI's header row shows it too.
    pub fn projectDisplayName(self: *const App) []const u8 {
        const path = self.projectPath() orelse return self.session.project.name;
        const stem = std.fs.path.stem(path);
        return if (stem.len > 0) stem else self.session.project.name;
    }

    pub fn defaultProjectPath(self: *const App) []const u8 {
        return self.default_project_path.slice();
    }

    pub fn setProjectPath(self: *App, path: []const u8) void {
        self.project_path_len = copyTruncated(&self.project_path_buf, path);
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator) catch null;
        defer if (canonical) |owned| self.allocator.free(owned);
        recent_project_store.touch(self.allocator, &self.recent_projects, canonical orelse path) catch return;
        recent_project_store.save(self.allocator, self.io, self.recent_projects.items) catch {};
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
        if (self.recording_take) |*take| take.finish();
        self.recording_take = null;
        self.recording_pending_len = 0;
        self.recording_active_len = 0;
        self.recording_accum.clearRetainingCapacity();
        self.input_monitor = .auto;
        self.punch_enabled = false;
        self.recording_punch_start_bar = null;
        self.recording_punch_end_bar = null;
        self.recording_loop_start_bar = null;
        self.recording_loop_end_bar = null;
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
            self.pending_reload_len = copyTruncated(&self.pending_reload_buf, p);
            self.pending_reload = .load;
        } else {
            self.pending_reload = .blank;
        }
    }

    pub fn pendingReloadPath(self: *const App) []const u8 {
        return self.pending_reload_buf[0..self.pending_reload_len];
    }

    pub const PreparedReload = struct {
        kind: ReloadRequest,
        session: ws.Session,
    };

    /// Build a requested replacement before frontends stop audio/MIDI.
    /// Ownership of a returned session passes to `installPreparedReload`.
    pub fn preparePendingReload(self: *App) ?PreparedReload {
        const kind = self.pending_reload;
        if (kind == .none) return null;
        self.pending_reload = .none;
        const session = switch (kind) {
            .blank => ws.Session.initDefault(self.allocator) catch |err| {
                self.setStatus("new: {s}", .{@errorName(err)});
                return null;
            },
            .load, .restore_backup => ws.persist.load(self.allocator, self.io, self.pendingReloadPath()) catch |err| {
                self.setStatus("cannot load '{s}': {s}", .{ self.pendingReloadPath(), @errorName(err) });
                return null;
            },
            .none => unreachable,
        };
        return .{ .kind = kind, .session = session };
    }

    pub fn installPreparedReload(self: *App, prepared: PreparedReload) void {
        self.session.deinit();
        self.session = prepared.session;
        self.resetForNewSession();
        switch (prepared.kind) {
            .load => {
                self.setProjectPath(self.pendingReloadPath());
                self.setStatus("loaded: {s}", .{self.projectPath().?});
            },
            .restore_backup => {
                self.dirty = true;
                self.setStatus("restored from autosave backup; :write to keep it", .{});
            },
            .blank => {
                self.clearProjectPath();
                self.setStatus("new project", .{});
            },
            .none => unreachable,
        }
        if (prepared.kind != .blank) self.emitEvent(.{ .ProjectLoadPost = .{ .path = self.pendingReloadPath() } });
    }

    /// `:restore-backup` - load `backup_path` (the `<project>~` autosave)
    /// on the next loop iteration, same swap mechanism as `:e`, but the
    /// project path stays the original file: the backup's content is newer
    /// than what's on disk, not a different project, so it lands `dirty`
    /// rather than re-pointing `:w`'s default target.
    pub fn requestRestoreBackup(self: *App, backup_path: []const u8) void {
        self.pending_reload_len = copyTruncated(&self.pending_reload_buf, backup_path);
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
        .vst3 => "vst3",
        .soundfont => "soundfont",
        .acoustic => "acoustic",
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
    if (std.mem.eql(u8, name, "acoustic")) return .acoustic;
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

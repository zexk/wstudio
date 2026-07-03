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
const frame_poll_ms = 30;
const cmd_history_cap: usize = 50;
/// Big enough for any real filesystem path; mirrors commands.path_buf_len.
const reload_path_buf_len: usize = 1024;
/// A pause longer than this between taps starts a fresh tap-tempo run.
const tap_timeout_ns: i96 = 2 * std.time.ns_per_s;
/// Minimum gap between silent `<path>~` backups; see `maybeAutosave`.
const autosave_interval_ns: i96 = 30 * std.time.ns_per_s;

pub const AppView = enum { tracks, drum_grid, synth_editor, sampler_editor, help, track_spectrum, master_spectrum, piano_roll, instrument_picker, arrangement };

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

/// One yanked piano-roll pattern: a private copy of the notes + loop length.
pub const PianoClip = struct {
    notes: [pattern_mod.max_notes]pattern_mod.Note,
    count: u16,
    length_beats: f64,
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
    status_buf: [80]u8 = undefined,
    status_len: usize = 0,
    status_ttl: u32 = 0,
    note_offs: [32]NoteOff = undefined,
    note_off_len: usize = 0,
    // Last timestamp seen by handleKey; lets sub-view handlers schedule note-offs
    // (e.g. piano-roll preview) without threading now_ns through every signature.
    now_ns: i96 = 0,
    eq_cursor: usize = 0,
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
    /// The arrangement clip the piano roll is editing, or null when it edits
    /// the track's live pattern (see `ClipLink`). Set by `e` on a clip in the
    /// arrangement; cleared when the roll opens on a live pattern instead.
    piano_clip_link: ?ClipLink = null,
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
        // name; left/right are dropped rather than aliased below (no
        // cursor-in-buffer exists yet, and aliasing them to h/l would
        // corrupt the line being typed).
        if (self.modal.mode == .command) {
            switch (key_in) {
                .arrow_up => { self.commandHistoryPrev(); return; },
                .arrow_down => { self.commandHistoryNext(); return; },
                .arrow_left, .arrow_right => return,
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
            .drum_grid => {
                if (self.modal.mode != .normal or !drum_ed.handleKey(self, key)) {
                    self.applyAction(self.modal.handle(key), now_ns);
                } else self.modal.count = 0;
            },
            .synth_editor => if (!synth_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .sampler_editor => if (self.modal.mode != .normal or !sampler_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .track_spectrum, .master_spectrum => if (!spectrum_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .piano_roll => if (self.modal.mode != .normal or !piano_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .instrument_picker => self.handlePickerKey(key),
            .arrangement => if (self.modal.mode != .normal or !arrangement_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            } else { self.modal.count = 0; },
            .tracks => {
                if (key == .enter and self.modal.mode == .normal) {
                    self.openTrack(self.cursor);
                    return;
                }
                if (key == .char and self.modal.mode == .normal) {
                    switch (key.char) {
                        'M' => { spectrum_ed.switchToMaster(self); return; },
                        'A' => { self.view = .arrangement; return; },
                        's' => { spectrum_ed.switchToTrack(self, @intCast(self.cursor)); return; },
                        'p' => { piano_ed.switchTo(self, @intCast(self.cursor)); return; },
                        'a' => { self.doTrackAdd(null); return; },
                        'D' => { self.doTrackDel(self.cursor); return; },
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
                self.applyAction(self.modal.handle(key), now_ns);
            },
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
                const last: i64 = @intCast(self.session.project.tracks.items.len - 1);
                self.cursor = @intCast(std.math.clamp(count, 0, last));
            },
            .goto_start => _ = self.session.engine.send(.{ .seek_frames = 0 }),
            .toggle_play => {
                const cmd: engine_mod.Command = if (self.session.engine.uiSnapshot().playing) .stop else .play;
                _ = self.session.engine.send(cmd);
            },
            .toggle_mute => {
                const track_idx: u16 = switch (self.view) {
                    .synth_editor   => self.synth_track,
                    .piano_roll     => self.piano_track,
                    .drum_grid      => self.drum_track,
                    .sampler_editor => self.sampler_target.track(),
                    else            => @intCast(self.cursor),
                };
                const track = &self.session.project.tracks.items[track_idx];
                track.muted = !track.muted;
                self.dirty = true;
                _ = self.session.engine.send(.{ .set_track_mute = .{
                    .track = track_idx,
                    .muted = track.muted,
                } });
            },
            .toggle_solo => {
                const track_idx: u16 = switch (self.view) {
                    .synth_editor   => self.synth_track,
                    .piano_roll     => self.piano_track,
                    .drum_grid      => self.drum_track,
                    .sampler_editor => self.sampler_target.track(),
                    else            => @intCast(self.cursor),
                };
                const track = &self.session.project.tracks.items[track_idx];
                track.soloed = !track.soloed;
                self.dirty = true;
                _ = self.session.engine.send(.{ .set_track_solo = .{
                    .track = track_idx,
                    .soloed = track.soloed,
                } });
            },
            .note => |n| {
                if (self.cursor >= self.session.racks.items.len) return;
                switch (self.session.racks.items[self.cursor].instrument) {
                    .drum_machine => _ = self.session.engine.send(.{ .note_on = .{
                        .track = @intCast(self.cursor),
                        .note = @intCast(n.pitch % DrumMachine.max_pads),
                        .velocity = 0.9,
                    } }),
                    .poly_synth, .sampler => self.playNote(@intCast(self.cursor), n.pitch, now_ns),
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
    }

    /// Tab-complete the command name being typed — only while no space has
    /// been typed yet; arguments aren't completed. A single match completes
    /// to the full name plus a trailing space (ready for its argument);
    /// several matches complete to their longest common prefix instead
    /// (readline-style); no matches is a no-op.
    fn completeCommand(self: *App) void {
        const buf = self.modal.cmd_buf[0..self.modal.cmd_len];
        if (buf.len == 0 or std.mem.indexOfScalar(u8, buf, ' ') != null) return;

        var match_count: usize = 0;
        var common: []const u8 = "";
        for (commands.cmds) |c| {
            if (!std.mem.startsWith(u8, c.name, buf)) continue;
            match_count += 1;
            common = if (match_count == 1) c.name else commonPrefix(common, c.name);
        }
        if (match_count == 0 or common.len <= buf.len) return;

        @memcpy(self.modal.cmd_buf[buf.len..common.len], common[buf.len..]);
        self.modal.cmd_len = common.len;
        if (match_count == 1 and self.modal.cmd_len < self.modal.cmd_buf.len) {
            self.modal.cmd_buf[self.modal.cmd_len] = ' ';
            self.modal.cmd_len += 1;
        }
    }

    fn commonPrefix(a: []const u8, b: []const u8) []const u8 {
        var i: usize = 0;
        const n = @min(a.len, b.len);
        while (i < n and a[i] == b[i]) : (i += 1) {}
        return a[0..i];
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

        try w.writeAll("\x1b[H");
        try tui.drawHeader(w, &self.session.project, &self.session.engine.transport, self.audio_label, self.master_gain_db, self.dirty);
        try tui.hr(w, size.cols);

        switch (self.view) {
            .tracks          => try tui.drawTracks(self, w, rows, snap),
            .drum_grid       => try tui.drawDrumGrid(self, w, rows, snap),
            .synth_editor    => try tui.drawSynthEditor(self, w, rows, snap),
            .sampler_editor  => try tui.drawSamplerEditor(self, w, rows, size.cols, snap),
            .piano_roll      => try tui.drawPianoRoll(self, w, rows, size.cols, snap),
            .help            => try tui.drawHelp(w, rows, commands.cmds, &self.help_scroll),
            .track_spectrum  => try tui.drawSpectrumView(self, w, rows, size.cols, snap, true),
            .master_spectrum => try tui.drawSpectrumView(self, w, rows, size.cols, snap, false),
            .instrument_picker => try tui.drawInstrumentPicker(self, w, rows),
            .arrangement     => try tui.drawArrangement(self, w, rows, size.cols, snap),
        }

        var transport: Transport = .{
            .sample_rate = self.session.project.sample_rate,
            .tempo_bpm = self.session.project.tempo_bpm,
            .position_frames = snap.position_frames,
        };
        const pos = transport.positionBarBeat();
        const secs = transport.positionSeconds();
        if (snap.playing) {
            try w.writeAll("\x1b[32m\x1b[1m |> " ++ icons.play ++ "\x1b[0m");
        } else {
            try w.writeAll("\x1b[2m [] " ++ icons.stop ++ "\x1b[0m");
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

        switch (self.view) {
            .tracks          => try tui.drawTracksStatus(self, w),
            .drum_grid       => try tui.drawDrumStatus(self, w),
            .synth_editor    => try tui.drawSynthStatus(self, w),
            .sampler_editor  => try tui.drawSamplerStatus(self, w),
            .piano_roll      => try tui.drawPianoRollStatus(self, w),
            .help            => try w.writeAll(" j/k: scroll   d/u: page   g/G: top/bottom   esc: close"),
            .track_spectrum  => try tui.drawSpectrumStatus(self, w, true),
            .master_spectrum => try tui.drawSpectrumStatus(self, w, false),
            .instrument_picker => try w.writeAll(" j/k: move   enter: insert   esc: cancel"),
            .arrangement     => try tui.drawArrangementStatus(self, w),
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
        for (keys[0..n]) |key| app.handleKey(key, now);
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

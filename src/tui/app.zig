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
    /// Arrangement view: bar cursor and horizontal scroll (lane = `cursor`).
    arr_cursor_bar: u32 = 0,
    arr_scroll_bar: u32 = 0,
    /// Pattern clipboards (y yank / P paste), app-wide so patterns can move
    /// between tracks. Whole-pattern granularity; one slot per editor kind.
    piano_clip: ?PianoClip = null,
    drum_clip: ?DrumMachine.Variant = null,
    /// The arrangement clip the piano roll is editing, or null when it edits
    /// the track's live pattern (see `ClipLink`). Set by `e` on a clip in the
    /// arrangement; cleared when the roll opens on a live pattern instead.
    piano_clip_link: ?ClipLink = null,
    /// Undo/redo history for content edits (u / U in the editing views).
    history: undo_mod.History = .{},
    /// Path of the current project file — the default for :w / :wq. Set when
    /// a project is loaded at startup and updated on every successful save.
    project_path_buf: [256]u8 = undefined,
    project_path_len: usize = 0,

    const NoteOff = struct { at_ns: i96, track: u16, note: u7 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !App {
        return .{
            .allocator = allocator,
            .io = io,
            .session = try ws.Session.initDefault(allocator),
        };
    }

    pub fn deinit(self: *App) void {
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

    pub fn handleKey(self: *App, key: modal_mod.Key, now_ns: i96) void {
        self.now_ns = now_ns;
        if (key == .ctrl_c) {
            self.should_quit = true;
            return;
        }

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
            .drum_grid => {
                if (self.modal.mode != .normal or !drum_ed.handleKey(self, key)) {
                    self.applyAction(self.modal.handle(key), now_ns);
                }
            },
            .synth_editor => if (!synth_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .sampler_editor => if (self.modal.mode != .normal or !sampler_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .track_spectrum, .master_spectrum => if (!spectrum_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .piano_roll => if (self.modal.mode != .normal or !piano_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .instrument_picker => self.handlePickerKey(key),
            .arrangement => if (self.modal.mode != .normal or !arrangement_ed.handleKey(self, key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
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
                        else => {},
                    }
                }
                self.applyAction(self.modal.handle(key), now_ns);
            },
        }
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
            .mode_changed => self.status_len = 0,
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
            .command_submit => |text| commands.run(self, text),
        }
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
        try tui.drawHeader(w, &self.session.project, &self.session.engine.transport, self.audio_label, self.master_gain_db);
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
            try w.writeAll("\x1b[32m\x1b[1m |>\x1b[0m");
        } else {
            try w.writeAll("\x1b[2m []\x1b[0m");
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

    const config: backend_mod.Config = .{ .sample_rate = app.session.project.sample_rate };

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

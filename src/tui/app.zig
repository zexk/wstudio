const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const backend_mod = ws.backend;
const modal_mod = ws.input;
const terminal_mod = @import("terminal.zig");
const dsp = ws.dsp.device;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const GraphicEq = ws.dsp.GraphicEq;
const eq_mod = ws.dsp.eq;
const cmd_mod = @import("cmd.zig");
const tui = @import("tui.zig");
const midi = ws.midi;

const Engine = engine_mod.Engine;

const note_ms = 220;
const frame_poll_ms = 30;

pub const AppView = enum { tracks, drum_grid, synth_editor, help, track_spectrum, master_spectrum, piano_roll };

fn wrap(comptime f: fn (*App, []const u8) void) *const fn (*anyopaque, []const u8) void {
    return struct {
        fn call(ctx: *anyopaque, args: []const u8) void {
            f(@ptrCast(@alignCast(ctx)), args);
        }
    }.call;
}

const cmds: []const cmd_mod.Def = &.{
    .{ .name = "q",           .desc = "quit wstudio",                        .run = wrap(App.cmdQuit) },
    .{ .name = "quit",        .desc = "quit wstudio",                        .run = wrap(App.cmdQuit) },
    .{ .name = "bpm",         .desc = "[<value>]  tempo in BPM (20–400)",    .run = wrap(App.cmdBpm) },
    .{ .name = "gain",        .desc = "<track> [<dB>]  track gain",          .run = wrap(App.cmdGain) },
    .{ .name = "pan",         .desc = "<track> [<-1..1>]  track pan",        .run = wrap(App.cmdPan) },
    .{ .name = "vol",         .desc = "[<dB>]  master volume (–40 to +6)",   .run = wrap(App.cmdVol) },
    .{ .name = "seek",        .desc = "<bar>  move playhead to bar",         .run = wrap(App.cmdSeek) },
    .{ .name = "load-pad",    .desc = "<0-7> <file>  load WAV into pad",     .run = wrap(App.cmdLoadPad) },
    .{ .name = "help",        .desc = "list all commands",                   .run = wrap(App.cmdHelp) },
    .{ .name = "eq",          .desc = "<track> [<band> <db>]  EQ control",   .run = wrap(App.cmdEq) },
    .{ .name = "track-add",   .desc = "[name]  add a synth track",           .run = wrap(App.cmdTrackAdd) },
    .{ .name = "track-del",   .desc = "[n]  delete track n (default: cursor)", .run = wrap(App.cmdTrackDel) },
    .{ .name = "track-rename",.desc = "<n> <name>  rename track n",          .run = wrap(App.cmdTrackRename) },
    .{ .name = "save",        .desc = "[file]  save project (default: project.wsj)", .run = wrap(App.cmdSave) },
    .{ .name = "w",           .desc = "[file]  save project (alias for :save)",      .run = wrap(App.cmdSave) },
    .{ .name = "bounce",      .desc = "[file]  render session to WAV (default: bounce.wav)", .run = wrap(App.cmdBounce) },
    .{ .name = "export",      .desc = "[file]  render session to WAV (alias for :bounce)",   .run = wrap(App.cmdBounce) },
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ws.Session,
    modal: modal_mod.ModalInput = .{},
    cursor: usize = 0,
    view: AppView = .tracks,
    prev_view: AppView = .tracks,
    drum_cursor: [2]u8 = .{ 0, 0 },
    audio_label: []const u8 = "off",
    master_gain_db: f32 = 0.0,
    should_quit: bool = false,
    status_buf: [80]u8 = undefined,
    status_len: usize = 0,
    status_ttl: u32 = 0,
    note_offs: [32]NoteOff = undefined,
    note_off_len: usize = 0,
    eq_cursor: usize = 0,
    eq_track: u16 = 0,
    synth_track: u16 = 0,
    synth_cursor: u8 = 0,
    synth_scroll: usize = 0,
    piano_track: u16 = 0,
    piano_cursor_step: u16 = 0,
    piano_cursor_pitch: u7 = 60,
    piano_scroll_step: u16 = 0,
    piano_scroll_pitch: u7 = 72,
    piano_note_len: f64 = 0.25,

    const NoteOff = struct { at_ns: i96, track: u16, note: u7 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !App {
        return .{
            .allocator = allocator,
            .io = io,
            .session = try ws.Session.initDefault(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.session.deinit();
    }

    pub fn drumMachine(self: *App) *DrumMachine {
        return &self.session.racks.items[self.session.drum_track].instrument.drum_machine;
    }

    // -----------------------------------------------------------------------
    // Input handling
    // -----------------------------------------------------------------------

    pub fn handleKey(self: *App, key: modal_mod.Key, now_ns: i96) void {
        if (key == .ctrl_c) {
            self.should_quit = true;
            return;
        }

        switch (self.view) {
            .help => if (key == .escape) { self.view = self.prev_view; },
            .drum_grid => {
                if (self.modal.mode != .normal or !self.handleDrumKey(key)) {
                    self.applyAction(self.modal.handle(key), now_ns);
                }
            },
            .synth_editor => if (!self.handleSynthKey(key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .track_spectrum, .master_spectrum => if (!self.handleSpectrumKey(key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .piano_roll => if (!self.handlePianoRollKey(key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .tracks => {
                if (key == .enter and self.modal.mode == .normal) {
                    if (self.cursor == self.session.drum_track) {
                        self.view = .drum_grid;
                    } else if (self.cursor < self.session.racks.items.len) {
                        switch (self.session.racks.items[self.cursor].instrument) {
                            .poly_synth => {
                                self.synth_track = @intCast(self.cursor);
                                self.synth_cursor = 0;
                                self.view = .synth_editor;
                            },
                            else => {},
                        }
                    }
                    return;
                }
                if (key == .char and self.modal.mode == .normal) {
                    switch (key.char) {
                        'M' => { self.switchToMasterSpectrum(); return; },
                        's' => { self.switchToTrackSpectrum(@intCast(self.cursor)); return; },
                        'p' => { self.switchToPianoRoll(@intCast(self.cursor)); return; },
                        'a' => { self.doTrackAdd(null); return; },
                        'D' => { self.doTrackDel(self.cursor); return; },
                        '?' => { self.cmdHelp(""); return; },
                        '<' => { self.doTrackPan(@intCast(self.cursor), -0.05); return; },
                        '>' => { self.doTrackPan(@intCast(self.cursor), 0.05); return; },
                        '-' => { self.doTrackGainStep(@intCast(self.cursor), -1.0); return; },
                        '=' => { self.doTrackGainStep(@intCast(self.cursor), 1.0); return; },
                        else => {},
                    }
                }
                self.applyAction(self.modal.handle(key), now_ns);
            },
        }
    }

    fn switchToTrackSpectrum(self: *App, track: u16) void {
        self.prev_view = self.view;
        self.view = .track_spectrum;
        self.eq_track = track;
        self.eq_cursor = 0;
        _ = self.session.engine.send(.{ .set_spectrum_active = .{ .source = .track, .track = track } });
    }

    fn switchToMasterSpectrum(self: *App) void {
        self.prev_view = self.view;
        self.view = .master_spectrum;
        self.eq_cursor = 0;
        _ = self.session.engine.send(.{ .set_spectrum_active = .{ .source = .master, .track = 0 } });
    }

    fn handleSpectrumKey(self: *App, key: modal_mod.Key) bool {
        switch (key) {
            .escape => {
                _ = self.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
                self.view = self.prev_view;
                return true;
            },
            .char => |c| switch (c) {
                'h' => { if (self.eq_cursor > 0) self.eq_cursor -= 1; },
                'l' => { if (self.eq_cursor < eq_mod.num_eq_bands - 1) self.eq_cursor += 1; },
                'j', 'J' => {
                    if (self.view == .track_spectrum and self.eq_track < self.session.racks.items.len) {
                        const delta: f32 = if (c == 'J') -6.0 else -1.0;
                        self.setEqBand(self.eq_track, self.eq_cursor, self.currentEqGain(self.eq_track) + delta);
                    }
                },
                'k', 'K' => {
                    if (self.view == .track_spectrum and self.eq_track < self.session.racks.items.len) {
                        const delta: f32 = if (c == 'K') 6.0 else 1.0;
                        self.setEqBand(self.eq_track, self.eq_cursor, self.currentEqGain(self.eq_track) + delta);
                    }
                },
                'b' => {
                    if (self.view == .track_spectrum and self.eq_track < self.session.racks.items.len) {
                        if (self.session.racks.items[self.eq_track].fx.eq) |*eq| {
                            eq.bypass = !eq.bypass;
                            var buf: [6]dsp.Device = undefined;
                            self.session.engine.setTrackChain(self.eq_track, self.session.racks.items[self.eq_track].chain(&buf));
                        }
                    }
                },
                else => return false,
            },
            else => return false,
        }
        return true;
    }

    fn currentEqGain(self: *App, track: u16) f32 {
        if (track < self.session.racks.items.len) {
            if (self.session.racks.items[track].fx.eq) |*e| return e.bands[self.eq_cursor].gain_db;
        }
        return 0.0;
    }

    fn setEqBand(self: *App, track: u16, band: usize, gain_db: f32) void {
        if (track >= self.session.racks.items.len) return;
        const rack = self.session.racks.items[track];
        if (rack.fx.eq == null) rack.fx.eq = GraphicEq.init(self.session.project.sample_rate);
        rack.fx.eq.?.setBand(band, gain_db);
        var buf: [6]dsp.Device = undefined;
        self.session.engine.setTrackChain(track, rack.chain(&buf));
    }

    pub fn handleDrumKey(self: *App, key: modal_mod.Key) bool {
        const pad = &self.drum_cursor[0];
        const step = &self.drum_cursor[1];
        switch (key) {
            .escape => { self.view = .tracks; return true; },
            // enter toggles the step; space falls through to transport play/pause.
            .enter => { self.drumMachine().toggleStep(pad.*, step.*); return true; },
            .char => |c| {
                switch (c) {
                    // coarse move by one beat (4 steps); shift (HL) moves one step
                    'h' => { step.* -|= 4; },
                    'l' => { step.* = @intCast(@min(@as(u16, step.*) + 4, self.drumMachine().step_count - 1)); },
                    'H' => { if (step.* > 0) step.* -= 1; },
                    'L' => { if (step.* + 1 < self.drumMachine().step_count) step.* += 1; },
                    'k' => if (pad.* > 0) { pad.* -= 1; },
                    'j' => if (pad.* < DrumMachine.max_pads - 1) { pad.* += 1; },
                    'p' => {
                        _ = self.session.engine.send(.{ .note_on = .{
                            .track = self.session.drum_track,
                            .note = @intCast(pad.*),
                            .velocity = 0.9,
                        } });
                        self.setStatus("preview: pad {d}", .{pad.* + 1});
                    },
                    '<' => {
                        const dm = self.drumMachine();
                        dm.setStepCount(dm.step_count - 1);
                        if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                    },
                    '>' => self.drumMachine().setStepCount(self.drumMachine().step_count + 1),
                    'X' => self.drumMachine().pattern[pad.*].store(0, .release),
                    'F' => {
                        const dm = self.drumMachine();
                        const sc = dm.step_count;
                        const mask: u32 = if (sc >= 32) ~@as(u32, 0) else (@as(u32, 1) << @intCast(sc)) - 1;
                        dm.pattern[pad.*].store(mask, .release);
                    },
                    's' => { self.switchToTrackSpectrum(self.session.drum_track); return true; },
                    else => return false,
                }
                return true;
            },
            else => return false,
        }
    }

    fn handleSynthKey(self: *App, key: modal_mod.Key) bool {
        switch (key) {
            .escape => { self.view = .tracks; return true; },
            .char => |c| switch (c) {
                // Block insert mode — piano keys conflict with parameter navigation.
                'i' => return true,
                's' => { self.switchToTrackSpectrum(self.synth_track); return true; },
                'j' => {
                    if (self.synth_cursor < tui.synth_param_count - 1) self.synth_cursor += 1;
                    self.synthUpdateScroll();
                    return true;
                },
                'k' => {
                    if (self.synth_cursor > 0) self.synth_cursor -= 1;
                    self.synthUpdateScroll();
                    return true;
                },
                'h' => { self.adjustSynthParam(-1); return true; },
                'l' => { self.adjustSynthParam(1); return true; },
                'H' => { self.adjustSynthParam(-10); return true; },
                'L' => { self.adjustSynthParam(10); return true; },
                '}', '{' => {
                    const section_starts = [_]u8{ 0, 6, 14, 16, 20, 24, 28, 32, 34, 36, 38 };
                    if (c == '}') {
                        for (section_starts) |s| {
                            if (s > self.synth_cursor) {
                                self.synth_cursor = s;
                                break;
                            }
                        }
                    } else {
                        var sec_idx: usize = 0;
                        for (section_starts, 0..) |s, idx| {
                            if (s <= self.synth_cursor) sec_idx = idx;
                        }
                        if (self.synth_cursor == section_starts[sec_idx] and sec_idx > 0) {
                            self.synth_cursor = section_starts[sec_idx - 1];
                        } else {
                            self.synth_cursor = section_starts[sec_idx];
                        }
                    }
                    self.synthUpdateScroll();
                    return true;
                },
                else => return false,
            },
            else => return false,
        }
    }

    /// Row index of `synth_cursor` within drawSynthEditor's output (0-based).
    /// Must stay in sync with the layout in tui.drawSynthEditor.
    pub fn synthParamRow(cursor: u8) usize {
        return switch (cursor) {
            0...5  => 2 + @as(usize, cursor),          // OSC A section (header at row 1)
            6...13 => 9 + @as(usize, cursor - 6),      // OSC B (header at row 8)
            14...15 => 18 + @as(usize, cursor - 14),   // MOD (header at 17)
            16...19 => 21 + @as(usize, cursor - 16),   // ENV (header at 20)
            20...23 => 26 + @as(usize, cursor - 20),   // FILTER (header at 25)
            24...27 => 31 + @as(usize, cursor - 24),   // FENV (header at 30)
            28...31 => 36 + @as(usize, cursor - 28),   // LFO (header at 35)
            32...33 => 41 + @as(usize, cursor - 32),   // VOICE (header at 40)
            34...35 => 44 + @as(usize, cursor - 34),   // SUB (header at 43)
            36...37 => 47 + @as(usize, cursor - 36),   // NOISE (header at 46)
            38      => 50,                              // OUT (header at 49)
            else    => 0,
        };
    }

    fn synthUpdateScroll(self: *App) void {
        // Will be called with an actual max_rows at draw time; use 20 as a safe
        // minimum so the scroll is kept reasonable even before the first draw.
        const max_rows: usize = 20;
        const row = synthParamRow(self.synth_cursor);
        if (row < self.synth_scroll) self.synth_scroll = row;
        if (row >= self.synth_scroll + max_rows) self.synth_scroll = row - max_rows + 1;
    }

    fn switchToPianoRoll(self: *App, track: u16) void {
        if (track >= self.session.racks.items.len) return;
        switch (self.session.racks.items[track].instrument) {
            .poly_synth => {},
            else => {
                self.setStatus("piano roll: synth tracks only", .{});
                return;
            },
        }
        self.piano_track = track;
        self.piano_cursor_step = 0;
        self.piano_scroll_step = 0;
        // Center the 16-row viewport on the cursor pitch.
        self.piano_scroll_pitch = @intCast(@min(@as(u32, self.piano_cursor_pitch) + 8, 127));
        self.view = .piano_roll;
    }

    fn handlePianoRollKey(self: *App, key: modal_mod.Key) bool {
        if (self.piano_track >= self.session.racks.items.len) return false;
        const rack = self.session.racks.items[self.piano_track];
        const pp = if (rack.pattern_player != null) &self.session.racks.items[self.piano_track].pattern_player.? else return false;

        switch (key) {
            .escape => { self.view = .tracks; return true; },
            .char => |c| switch (c) {
                // Block insert mode — piano keys collide with roll navigation (j/k/h/d/…).
                'i' => return true,
                'h' => {
                    if (self.piano_cursor_step > 0) self.piano_cursor_step -= 1;
                    self.pianoEnsureVisible();
                    return true;
                },
                'l' => {
                    const max_step: u16 = @intFromFloat(pp.length_beats * 4.0);
                    if (self.piano_cursor_step + 1 < max_step) self.piano_cursor_step += 1;
                    self.pianoEnsureVisible();
                    return true;
                },
                'j' => {
                    if (self.piano_cursor_pitch > 0) self.piano_cursor_pitch -= 1;
                    self.pianoEnsureVisible();
                    return true;
                },
                'k' => {
                    if (self.piano_cursor_pitch < 127) self.piano_cursor_pitch += 1;
                    self.pianoEnsureVisible();
                    return true;
                },
                's' => { self.switchToTrackSpectrum(self.piano_track); return true; },
                'n' => { self.pianoInsertNote(); return true; },
                'd' => { self.pianoDeleteNote(); return true; },
                'e' => {
                    self.synth_track = self.piano_track;
                    self.synth_cursor = 0;
                    self.synthUpdateScroll();
                    self.view = .synth_editor;
                    return true;
                },
                '[' => {
                    self.piano_note_len = @max(0.25, self.piano_note_len - 0.25);
                    self.setStatus("note len: {d:.2} beats", .{self.piano_note_len});
                    return true;
                },
                ']' => {
                    self.piano_note_len = @min(pp.length_beats, self.piano_note_len + 0.25);
                    self.setStatus("note len: {d:.2} beats", .{self.piano_note_len});
                    return true;
                },
                '+' => {
                    pp.length_beats += 4.0;
                    self.setStatus("loop: {d:.0} beats", .{pp.length_beats});
                    return true;
                },
                '-' => {
                    pp.length_beats = @max(4.0, pp.length_beats - 4.0);
                    self.setStatus("loop: {d:.0} beats", .{pp.length_beats});
                    return true;
                },
                else => return false,
            },
            else => return false,
        }
    }

    fn pianoEnsureVisible(self: *App) void {
        const vis_cols: u16 = 16;
        const vis_rows: u8  = 16;
        // horizontal
        if (self.piano_cursor_step < self.piano_scroll_step) {
            self.piano_scroll_step = self.piano_cursor_step;
        }
        if (self.piano_cursor_step >= self.piano_scroll_step + vis_cols) {
            self.piano_scroll_step = self.piano_cursor_step - vis_cols + 1;
        }
        // vertical (pitch)
        const top: i32 = @intCast(self.piano_scroll_pitch);
        const bot: i32 = top - @as(i32, vis_rows) + 1;
        const cur: i32 = @intCast(self.piano_cursor_pitch);
        if (cur > top) self.piano_scroll_pitch = @intCast(cur);
        if (cur < bot) self.piano_scroll_pitch = @intCast(cur + @as(i32, vis_rows) - 1);
    }

    fn pianoInsertNote(self: *App) void {
        if (self.piano_track >= self.session.racks.items.len) return;
        const pp = if (self.session.racks.items[self.piano_track].pattern_player != null)
            &self.session.racks.items[self.piano_track].pattern_player.?
        else return;
        const start_beat = @as(f64, @floatFromInt(self.piano_cursor_step)) * 0.25;
        // Don't insert if a note already starts here on this pitch
        if (pp.noteStartsAt(self.piano_cursor_pitch, start_beat)) return;
        pp.addNote(.{
            .pitch        = self.piano_cursor_pitch,
            .start_beat   = start_beat,
            .duration_beat = self.piano_note_len,
        });
        var nbuf: [5]u8 = undefined;
        self.setStatus("added {s}", .{midi.noteName(self.piano_cursor_pitch, &nbuf)});
    }

    fn pianoDeleteNote(self: *App) void {
        if (self.piano_track >= self.session.racks.items.len) return;
        const pp = if (self.session.racks.items[self.piano_track].pattern_player != null)
            &self.session.racks.items[self.piano_track].pattern_player.?
        else return;
        const start_beat = @as(f64, @floatFromInt(self.piano_cursor_step)) * 0.25;
        pp.removeNote(self.piano_cursor_pitch, start_beat);
        var nbuf: [5]u8 = undefined;
        self.setStatus("removed {s}", .{midi.noteName(self.piano_cursor_pitch, &nbuf)});
    }

    /// Nudge the selected synth-editor parameter. The change is routed over the
    /// engine command queue and applied on the audio thread (PolySynth.adjustParam)
    /// so it never races the block reader — the editor view reflects it on the
    /// next frame. See engine.Command.set_track_param.
    fn adjustSynthParam(self: *App, steps: i32) void {
        if (self.synth_track >= self.session.racks.items.len) return;
        const rack = self.session.racks.items[self.synth_track];
        switch (rack.instrument) {
            .poly_synth => {},
            else => return,
        }
        _ = self.session.engine.send(.{ .set_track_param = .{
            .track = self.synth_track,
            .id    = self.synth_cursor,
            .steps = steps,
        } });
    }

    pub fn applyAction(self: *App, action: modal_mod.Action, now_ns: i96) void {
        switch (action) {
            .none, .octave_up, .octave_down => {},
            .goto_end => {
                var max_beats: f64 = 0;
                for (self.session.racks.items) |rack| {
                    if (rack.pattern_player) |pp| max_beats = @max(max_beats, pp.length_beats);
                }
                const dm_beats = @as(f64, @floatFromInt(self.drumMachine().step_count)) / 4.0;
                max_beats = @max(max_beats, dm_beats);
                const end_frames: u64 = @intFromFloat(self.session.engine.transport.framesPerBeat() * max_beats);
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
                    .synth_editor => self.synth_track,
                    .piano_roll   => self.piano_track,
                    .drum_grid    => self.session.drum_track,
                    else          => @intCast(self.cursor),
                };
                const track = &self.session.project.tracks.items[track_idx];
                track.muted = !track.muted;
                _ = self.session.engine.send(.{ .set_track_mute = .{
                    .track = track_idx,
                    .muted = track.muted,
                } });
            },
            .note => |n| {
                if (self.cursor != self.session.drum_track) {
                    self.playNote(n.pitch, now_ns);
                } else {
                    _ = self.session.engine.send(.{ .note_on = .{
                        .track = self.session.drum_track,
                        .note = @intCast(n.pitch % DrumMachine.max_pads),
                        .velocity = 0.9,
                    } });
                }
            },
            .command_submit => |text| self.runCommand(text),
        }
    }

    fn playNote(self: *App, pitch: u7, now_ns: i96) void {
        const track: u16 = @intCast(self.cursor);
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

    fn doTrackAdd(self: *App, name_arg: ?[]const u8) void {
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

    fn doTrackDel(self: *App, track_idx: usize) void {
        self.session.deleteTrack(track_idx) catch |err| {
            if (err == error.CannotDeleteDrumTrack)
                self.setStatus("cannot delete the drum track", .{})
            else
                self.setStatus("cannot delete the last track", .{});
            return;
        };

        if (track_idx < self.synth_track and self.synth_track > 0) self.synth_track -= 1;

        // Keep cursor in bounds; never land on the drum track.
        const last = self.session.project.tracks.items.len - 1;
        self.cursor = @min(self.cursor, last);
        if (self.cursor == self.session.drum_track and self.cursor > 0) self.cursor -= 1;

        // Exit synth editor if the edited track no longer exists or is not a poly_synth.
        if (self.view == .synth_editor) {
            const bad = self.synth_track >= self.session.racks.items.len or
                switch (self.session.racks.items[self.synth_track].instrument) {
                    .poly_synth => false, else => true,
                };
            if (bad) self.view = .tracks;
        }

        // Exit spectrum view if the viewed track was deleted.
        if (self.view == .track_spectrum and self.eq_track >= self.session.racks.items.len) {
            _ = self.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
            self.view = self.prev_view;
        }

        self.setStatus("deleted track {d}", .{track_idx + 1});
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

    fn runCommand(self: *App, text: []const u8) void {
        if (!cmd_mod.dispatch(cmds, self, text)) {
            self.setStatus("not a command: {s}  (try :help)", .{text});
        }
    }

    fn cmdQuit(self: *App, _: []const u8) void { self.should_quit = true; }

    fn cmdHelp(self: *App, _: []const u8) void {
        self.prev_view = self.view;
        self.view = .help;
    }

    fn cmdTrackAdd(self: *App, args: []const u8) void {
        const name = std.mem.trim(u8, args, " ");
        self.doTrackAdd(if (name.len > 0) name else null);
    }

    fn cmdTrackDel(self: *App, args: []const u8) void {
        const trimmed = std.mem.trim(u8, args, " ");
        const idx: usize = if (trimmed.len == 0) blk: {
            break :blk self.cursor;
        } else blk: {
            const n = std.fmt.parseInt(usize, trimmed, 10) catch {
                self.setStatus("track-del: expected a track number", .{});
                return;
            };
            if (n == 0 or n > self.session.project.tracks.items.len) {
                self.setStatus("track-del: track must be 1–{d}", .{self.session.project.tracks.items.len});
                return;
            }
            break :blk n - 1;
        };
        self.doTrackDel(idx);
    }

    fn cmdTrackRename(self: *App, args: []const u8) void {
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
        const n_str = it.next() orelse {
            self.setStatus("usage: track-rename <n> <name>", .{});
            return;
        };
        const name = std.mem.trim(u8, it.rest(), " ");
        if (name.len == 0) {
            self.setStatus("usage: track-rename <n> <name>", .{});
            return;
        }
        const n = std.fmt.parseInt(usize, n_str, 10) catch {
            self.setStatus("track-rename: expected a track number", .{});
            return;
        };
        if (n == 0 or n > self.session.project.tracks.items.len) {
            self.setStatus("track-rename: track must be 1–{d}", .{self.session.project.tracks.items.len});
            return;
        }
        self.session.project.renameTrack(n - 1, name) catch {
            self.setStatus("out of memory", .{});
            return;
        };
        self.setStatus("track {d} renamed to \"{s}\"", .{ n, name });
    }

    fn cmdLoadPad(self: *App, args: []const u8) void {
        var it = std.mem.splitScalar(u8, args, ' ');
        const pad_str = it.next() orelse {
            self.setStatus("usage: load-pad <0-7> <file.wav>", .{});
            return;
        };
        const path = it.rest();
        const pad_idx = std.fmt.parseInt(u8, pad_str, 10) catch {
            self.setStatus("load-pad: bad pad index '{s}'", .{pad_str});
            return;
        };
        if (pad_idx >= DrumMachine.max_pads) {
            self.setStatus("load-pad: pad index must be 0-7", .{});
            return;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(64 * 1024 * 1024),
        ) catch |e| {
            self.setStatus("load-pad: cannot read '{s}': {s}", .{ path, @errorName(e) });
            return;
        };
        defer self.allocator.free(data);
        const basename = std.fs.path.basename(path);
        const stem = if (std.mem.lastIndexOf(u8, basename, ".")) |dot| basename[0..dot] else basename;
        self.drumMachine().loadPadWav(pad_idx, data, stem) catch |e| {
            self.setStatus("load-pad: parse error: {s}", .{@errorName(e)});
            return;
        };
        self.setStatus("pad {d} loaded: {s}", .{ pad_idx, stem });
    }

    fn cmdSave(self: *App, args: []const u8) void {
        const path = if (std.mem.trim(u8, args, " ").len > 0)
            std.mem.trim(u8, args, " ")
        else
            "project.wsj";
        ws.persist.save(self.allocator, &self.session, self.io, path) catch |e| {
            self.setStatus("save: {s}: {s}", .{ path, @errorName(e) });
            return;
        };
        self.setStatus("saved: {s}", .{path});
    }

    /// Render the live session (patterns + synth params + drum grid) offline to
    /// a 16-bit PCM WAV. Length = the longest loop plus a 2s tail for reverb and
    /// release. The realtime backend is parked for the duration so the UI thread
    /// can drive the engine without racing the audio thread.
    fn cmdBounce(self: *App, args: []const u8) void {
        const path = if (std.mem.trim(u8, args, " ").len > 0)
            std.mem.trim(u8, args, " ")
        else
            "bounce.wav";

        const engine = self.session.engine;
        const sr = self.session.project.sample_rate;

        var max_beats: f64 = 1.0;
        for (self.session.racks.items) |rack| {
            if (rack.pattern_player) |pp| max_beats = @max(max_beats, pp.length_beats);
        }
        const dm_beats = @as(f64, @floatFromInt(self.drumMachine().step_count)) / 4.0;
        max_beats = @max(max_beats, dm_beats);

        const content_frames: u64 = @intFromFloat(engine.transport.framesPerBeat() * max_beats);
        const total_frames = content_frames + types.secondsToFrames(2.0, sr);
        const buffer = self.allocator.alloc(
            types.Sample,
            @as(usize, @intCast(total_frames)) * engine_mod.channels,
        ) catch {
            self.setStatus("bounce: out of memory", .{});
            return;
        };
        defer self.allocator.free(buffer);

        self.parkAudio();
        self.renderBounce(buffer);
        engine.bounce_active.store(false, .release);
        engine.bounce_parked.store(false, .release);

        const file = std.Io.Dir.cwd().createFile(self.io, path, .{}) catch |e| {
            self.setStatus("bounce: {s}: {s}", .{ path, @errorName(e) });
            return;
        };
        defer file.close(self.io);
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(self.io, &fbuf);
        ws.wav.write(&fw.interface, sr, engine_mod.channels, buffer) catch |e| {
            self.setStatus("bounce: write failed: {s}", .{@errorName(e)});
            return;
        };
        fw.interface.flush() catch {};

        self.setStatus("bounced {d:.1}s -> {s}", .{ types.framesToSeconds(total_frames, sr), path });
    }

    /// Signal the realtime backend to park, then wait until it confirms (or time
    /// out — in tests no audio thread is running, so there is nothing to wait on).
    fn parkAudio(self: *App) void {
        const engine = self.session.engine;
        engine.bounce_parked.store(false, .release);
        engine.bounce_active.store(true, .release);
        const start = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        while (!engine.bounce_parked.load(.acquire)) {
            const elapsed = std.Io.Timestamp.now(self.io, .awake).nanoseconds - start;
            if (elapsed > 100 * std.time.ns_per_ms) break;
            std.atomic.spinLoopHint();
        }
    }

    /// Render the session from beat 0 into `buffer` (interleaved stereo), then
    /// restore the live transport position and playing state. Assumes the caller
    /// owns the engine (audio thread parked).
    fn renderBounce(self: *App, buffer: []types.Sample) void {
        const engine = self.session.engine;
        const was_playing = engine.transport.playing;
        const saved_pos = engine.transport.position_frames;

        self.resetDevices();
        engine.transport.seekFrames(0);
        engine.transport.play();

        const block = types.default_block_frames * engine_mod.channels;
        var offset: usize = 0;
        while (offset < buffer.len) {
            const end = @min(offset + block, buffer.len);
            engine.process(buffer[offset..end]);
            offset = end;
        }

        self.resetDevices();
        engine.transport.seekFrames(saved_pos);
        if (was_playing) engine.transport.play() else engine.transport.stop();
    }

    /// Clear every device's tails/voices/sequencer state across all racks.
    fn resetDevices(self: *App) void {
        var buf: [6]dsp.Device = undefined;
        for (self.session.racks.items) |rack| {
            for (rack.chain(&buf)) |dev| dev.reset();
        }
    }

    fn cmdBpm(self: *App, args: []const u8) void {
        const trimmed = std.mem.trim(u8, args, " ");
        if (trimmed.len == 0) {
            self.setStatus("bpm: {d:.1}", .{self.session.project.tempo_bpm});
            return;
        }
        const bpm = std.fmt.parseFloat(f64, trimmed) catch {
            self.setStatus("bpm: expected a number, e.g. :bpm 140", .{});
            return;
        };
        if (bpm < 20.0 or bpm > 400.0) {
            self.setStatus("bpm: must be between 20 and 400", .{});
            return;
        }
        self.session.project.tempo_bpm = bpm;
        _ = self.session.engine.send(.{ .set_tempo = bpm });
        self.setStatus("bpm: {d:.1}", .{bpm});
    }

    fn cmdGain(self: *App, args: []const u8) void {
        var it = std.mem.splitScalar(u8, args, ' ');
        const track_str = it.next() orelse {
            self.setStatus("usage: gain <track> [<dB>]", .{});
            return;
        };
        const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
            self.setStatus("gain: bad track number '{s}'", .{track_str});
            return;
        };
        if (track_1 == 0 or track_1 > self.session.project.tracks.items.len) {
            self.setStatus("gain: track must be 1–{d}", .{self.session.project.tracks.items.len});
            return;
        }
        const track_idx = track_1 - 1;
        const track = &self.session.project.tracks.items[track_idx];
        const db_str = std.mem.trim(u8, it.rest(), " ");
        if (db_str.len == 0) {
            self.setStatus("track {d} gain: {d:.1}dB", .{ track_1, track.gain_db });
            return;
        }
        const db = std.fmt.parseFloat(f32, db_str) catch {
            self.setStatus("gain: expected a dB value, e.g. :gain 2 -6", .{});
            return;
        };
        const clamped = std.math.clamp(db, -60.0, 12.0);
        track.gain_db = clamped;
        _ = self.session.engine.send(.{ .set_track_gain = .{
            .track = @intCast(track_idx),
            .gain = types.dbToGain(clamped),
        } });
        self.setStatus("track {d} gain: {d:.1}dB", .{ track_1, clamped });
    }

    fn cmdPan(self: *App, args: []const u8) void {
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
        const track_str = it.next() orelse {
            self.setStatus("usage: pan <track> [<-1..1>]", .{});
            return;
        };
        const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
            self.setStatus("pan: bad track number '{s}'", .{track_str});
            return;
        };
        if (track_1 == 0 or track_1 > self.session.project.tracks.items.len) {
            self.setStatus("pan: track must be 1–{d}", .{self.session.project.tracks.items.len});
            return;
        }
        const track_idx = track_1 - 1;
        const track = &self.session.project.tracks.items[track_idx];
        const val_str = std.mem.trim(u8, it.rest(), " ");
        if (val_str.len == 0) {
            const pct: i32 = @intFromFloat(@abs(track.pan) * 100.0);
            if (pct == 0) self.setStatus("track {d} pan: center", .{track_1})
            else if (track.pan < 0) self.setStatus("track {d} pan: L{d}%", .{ track_1, pct })
            else self.setStatus("track {d} pan: R{d}%", .{ track_1, pct });
            return;
        }
        const val = std.fmt.parseFloat(f32, val_str) catch {
            self.setStatus("pan: expected a value between -1.0 and 1.0", .{});
            return;
        };
        track.pan = std.math.clamp(val, -1.0, 1.0);
        _ = self.session.engine.send(.{ .set_track_pan = .{ .track = @intCast(track_idx), .pan = track.pan } });
        const pct: i32 = @intFromFloat(@abs(track.pan) * 100.0);
        if (pct == 0) self.setStatus("track {d} pan: center", .{track_1})
        else if (track.pan < 0) self.setStatus("track {d} pan: L{d}%", .{ track_1, pct })
        else self.setStatus("track {d} pan: R{d}%", .{ track_1, pct });
    }

    fn cmdSeek(self: *App, args: []const u8) void {
        const trimmed = std.mem.trim(u8, args, " ");
        const bar_1 = std.fmt.parseInt(u64, trimmed, 10) catch {
            self.setStatus("seek: expected a bar number, e.g. :seek 5", .{});
            return;
        };
        if (bar_1 == 0) {
            self.setStatus("seek: bar number starts at 1", .{});
            return;
        }
        const sr = @as(f64, @floatFromInt(self.session.project.sample_rate));
        const bpm = @max(self.session.project.tempo_bpm, 1.0);
        const beats_per_bar: f64 = @floatFromInt(self.session.engine.transport.time_signature.beats_per_bar);
        const frames_per_bar: u64 = @intFromFloat(sr * 60.0 / bpm * beats_per_bar);
        _ = self.session.engine.send(.{ .seek_frames = (bar_1 - 1) * frames_per_bar });
        self.setStatus("seek → bar {d}", .{bar_1});
    }

    fn cmdVol(self: *App, args: []const u8) void {
        const trimmed = std.mem.trim(u8, args, " ");
        if (trimmed.len == 0) {
            const sign: []const u8 = if (self.master_gain_db >= 0) "+" else "";
            self.setStatus("master vol: {s}{d:.1}dB  ([ / ] to adjust)", .{ sign, self.master_gain_db });
            return;
        }
        const db = std.fmt.parseFloat(f32, trimmed) catch {
            self.setStatus("vol: expected a dB value, e.g. :vol -6", .{});
            return;
        };
        self.master_gain_db = std.math.clamp(db, -40.0, 6.0);
        _ = self.session.engine.send(.{ .set_master_gain = types.dbToGain(self.master_gain_db) });
        const sign: []const u8 = if (self.master_gain_db >= 0) "+" else "";
        self.setStatus("master vol: {s}{d:.1}dB", .{ sign, self.master_gain_db });
    }

    fn cmdEq(self: *App, args: []const u8) void {
        var it = std.mem.splitScalar(u8, args, ' ');
        const track_str = it.next() orelse {
            self.setStatus("usage: eq <track> [<band> <db>]", .{});
            return;
        };
        const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
            self.setStatus("eq: bad track number '{s}'", .{track_str});
            return;
        };
        if (track_1 == 0 or track_1 > self.session.racks.items.len) {
            self.setStatus("eq: track must be 1–{d}", .{self.session.racks.items.len});
            return;
        }
        const track_idx = track_1 - 1;
        const rest = std.mem.trim(u8, it.rest(), " ");
        if (rest.len == 0) {
            if (self.session.racks.items[track_idx].fx.eq) |*eq| {
                self.setStatus("track {d}: bypass={}", .{ track_1, eq.bypass });
            } else {
                self.setStatus("track {d}: no EQ", .{track_1});
            }
            return;
        }
        var rit = std.mem.splitScalar(u8, rest, ' ');
        const band_str = rit.next() orelse {
            self.setStatus("eq: usage eq <track> <band> <db>", .{});
            return;
        };
        const band = std.fmt.parseInt(usize, band_str, 10) catch {
            self.setStatus("eq: bad band number", .{});
            return;
        };
        if (band >= eq_mod.num_eq_bands) {
            self.setStatus("eq: band must be 0–{d}", .{eq_mod.num_eq_bands - 1});
            return;
        }
        const db = std.fmt.parseFloat(f32, rit.rest()) catch {
            self.setStatus("eq: expected dB value", .{});
            return;
        };
        self.setEqBand(@intCast(track_idx), band, db);
        self.setStatus("track {d} eq band {d}: {d:.1}dB", .{ track_1, band, db });
    }

    fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
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
            .piano_roll      => try tui.drawPianoRoll(self, w, rows, size.cols, snap),
            .help            => try tui.drawHelp(w, rows, cmds),
            .track_spectrum  => try tui.drawSpectrumView(self, w, rows, size.cols, snap, true),
            .master_spectrum => try tui.drawSpectrumView(self, w, rows, size.cols, snap, false),
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
            .piano_roll      => try tui.drawPianoRollStatus(self, w),
            .help            => try w.writeAll(" esc: close"),
            .track_spectrum  => try tui.drawSpectrumStatus(self, w, true),
            .master_spectrum => try tui.drawSpectrumStatus(self, w, false),
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
// Tests
// ---------------------------------------------------------------------------

test "cursor movement clamps to track range" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.applyAction(.{ .move = .{ .dy = 10 } }, 0);
    try std.testing.expectEqual(@as(usize, 3), app.cursor);
    app.applyAction(.{ .move = .{ .dy = -1 } }, 0);
    try std.testing.expectEqual(@as(usize, 2), app.cursor);
    app.applyAction(.{ .move = .{ .dy = -10 } }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
}

test "renderBounce sequences notes offline and restores transport" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // Sequence a note at beat 0 on the lead track and leave the transport
    // stopped — the bounce must drive playback itself.
    app.session.racks.items[0].pattern_player.?.addNote(
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 },
    );
    try std.testing.expect(!app.session.engine.transport.playing);

    var buffer: [4096 * engine_mod.channels]types.Sample = undefined;
    app.renderBounce(&buffer);

    var peak: f32 = 0.0;
    for (buffer) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.001);

    // Transport restored to its pre-bounce state (stopped, at 0).
    try std.testing.expect(!app.session.engine.transport.playing);
    try std.testing.expectEqual(@as(u64, 0), app.session.engine.transport.position_frames);
}

test "toggle_mute flips project state and reaches the engine" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.applyAction(.toggle_mute, 0);
    try std.testing.expect(app.session.project.tracks.items[0].muted);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.engine.tracks[0].muted);
}

test "notes queue their own release" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.applyAction(.{ .note = .{ .pitch = 60 } }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);

    app.tick(note_ms * std.time.ns_per_ms / 2);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
    app.tick(note_ms * std.time.ns_per_ms + 1);
    try std.testing.expectEqual(@as(usize, 0), app.note_off_len);
}

test "typed :q quits via the modal layer" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.should_quit);
}

test "enter on drum track switches to drum_grid view" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.applyAction(.{ .move = .{ .dy = 10 } }, 0);
    try std.testing.expectEqual(app.session.drum_track, @as(u16, @intCast(app.cursor)));

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "drum grid step toggle" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    try std.testing.expect(app.drumMachine().stepActive(0, 0));

    app.drum_cursor = .{ 0, 0 };
    _ = app.handleDrumKey(.enter);
    try std.testing.expect(!app.drumMachine().stepActive(0, 0));
}

test "draw renders drum_grid view without overflowing" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.view = .drum_grid;
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "DRUMS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "kick") != null);
}

test "draw renders tracks view without overflowing" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "NORMAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "lead") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "drums") != null);
}

test ":help opens help view; draw shows command table; esc closes" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":help") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.help, app.view);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "COMMANDS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, ":bpm") != null);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "s key switches to track spectrum view" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    try std.testing.expectEqual(AppView.track_spectrum, app.view);
}

test "m key switches to master spectrum view" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 'M' }, 0);
    try std.testing.expectEqual(AppView.master_spectrum, app.view);
}

test "spectrum view esc returns to tracks" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "draw renders spectrum view without errors" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.view = .master_spectrum;
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SPECTRUM") != null);
}

test "draw renders track_spectrum after pressing s" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SPECTRUM") != null);
}

test "spectrum fills FFT buffer and draws with real data" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    _ = app.session.engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    var block: [512]types.Sample = undefined;
    for (0..16) |_| app.session.engine.process(&block);

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 120, .rows = 40 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SPECTRUM") != null);
}

test "track add: project, racks, engine, drum_track all update correctly" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    const initial_tracks = app.session.project.tracks.items.len; // 4
    const initial_drum = app.session.drum_track;                 // 3
    const initial_racks = app.session.racks.items.len;           // 3

    app.doTrackAdd("strings");

    try std.testing.expectEqual(initial_tracks + 1, app.session.project.tracks.items.len);
    try std.testing.expectEqual(initial_racks + 1, app.session.racks.items.len);
    try std.testing.expectEqual(initial_drum + 1, app.session.drum_track);
    try std.testing.expectEqualStrings("strings", app.session.project.tracks.items[initial_drum].name);

    // Pointer identity: synth is at chain[1] (pattern player at [0]).
    const new_rack = app.session.racks.items[initial_drum];
    const engine_ptr = app.session.engine.tracks[initial_drum].chain[1].ptr;
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_rack.instrument.poly_synth)), engine_ptr);
}

test "track delete: project, racks, engine, drum_track all update correctly" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    const initial_tracks = app.session.project.tracks.items.len; // 4
    const initial_drum = app.session.drum_track;                 // 3

    // Delete track 1 (pad, index 1).
    app.doTrackDel(1);

    try std.testing.expectEqual(initial_tracks - 1, app.session.project.tracks.items.len);
    try std.testing.expectEqual(initial_tracks - 1, app.session.racks.items.len); // racks == project tracks
    try std.testing.expectEqual(initial_drum - 1, app.session.drum_track);

    // After deletion, engine slot 1 must point to what was slot 2 (bass rack).
    // Synth is at chain[1]; pattern player at chain[0].
    const bass_rack = app.session.racks.items[1]; // was index 2, now index 1
    const engine_ptr = app.session.engine.tracks[1].chain[1].ptr;
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&bass_rack.instrument.poly_synth)), engine_ptr);
}

test ":track-add command adds a track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    const before = app.session.project.tracks.items.len;
    const drum_slot = app.session.drum_track; // new track inserts here, drum shifts up
    for (":track-add mytrack") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(before + 1, app.session.project.tracks.items.len);
    try std.testing.expectEqualStrings("mytrack", app.session.project.tracks.items[drum_slot].name);
}

test ":track-del command deletes a track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    const before = app.session.project.tracks.items.len;
    for (":track-del 1") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(before - 1, app.session.project.tracks.items.len);
}

test ":track-rename renames a track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":track-rename 1 renamed") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqualStrings("renamed", app.session.project.tracks.items[0].name);
}

test "enter on synth track opens synth editor" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // cursor starts at 0 (lead track, poly_synth)
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    try std.testing.expectEqual(@as(u16, 0), app.synth_track);
}

test "synth editor esc returns to tracks" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.enter, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "synth editor jk moves cursor, hl adjusts waveform" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u8, 0), app.synth_cursor); // on waveform

    // Edits route over the engine command queue and apply on the audio thread,
    // so drive a process() block after each key to realize the change.
    var block: [64]types.Sample = undefined;
    app.handleKey(.{ .char = 'l' }, 0); // next waveform
    app.session.engine.process(&block);
    const synth = &app.session.racks.items[0].instrument.poly_synth;
    try std.testing.expect(synth.waveform != .saw); // was saw by default → now triangle

    // j×16: →pls.width(1)→…→spread(5)→b.on(6)→…→b.uni.det(13)→mod.mode(14)→mod.amt(15)→attack(16)
    for (0..16) |_| app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u8, 16), app.synth_cursor);

    const old_attack = synth.attack_s;
    app.handleKey(.{ .char = 'l' }, 0); // increase attack
    app.session.engine.process(&block);
    try std.testing.expect(synth.attack_s > old_attack);
}

test "draw renders synth editor without errors" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.synth_editor, app.view);

    // Use a tall terminal so all 51 rows are visible (synth editor scrolls to fit).
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 60 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SYNTH") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "attack") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "sustain") != null);
}

test "escape returns from track_spectrum to tracks" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "TRACKS") != null);
}

test "draw renders spectrum view when engine has activated the analyzer" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    var block: [512]types.Sample = undefined;
    app.session.engine.process(&block);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SPECTRUM") != null);
}

test "p key opens piano roll for synth track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // cursor at track 0 (lead, poly_synth)
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expectEqual(@as(u16, 0), app.piano_track);

    // draw must not crash and must show PIANO ROLL
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 120, .rows = 36 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "PIANO ROLL") != null);

    // insert a note, verify it appears in the frame
    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;
    app.handleKey(.{ .char = 'n' }, 0);
    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);

    // delete it
    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);

    // esc returns to tracks
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "piano roll p does not open for drum track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    // move cursor to drum track
    app.applyAction(.{ .move = .{ .dy = 10 } }, 0);
    try std.testing.expectEqual(app.session.drum_track, @as(u16, @intCast(app.cursor)));

    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

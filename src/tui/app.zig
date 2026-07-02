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
const commands = @import("commands.zig");
const tui = @import("tui.zig");
const midi = ws.midi;

const Engine = engine_mod.Engine;
const Sampler = ws.dsp.Sampler;
const InstrumentKind = ws.InstrumentKind;
const pattern_mod = ws.dsp.pattern;

const note_ms = 220;
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
const PianoClip = struct {
    notes: [pattern_mod.max_notes]pattern_mod.Note,
    count: u16,
    length_beats: f64,
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
                if (self.modal.mode != .normal or !self.handleDrumKey(key)) {
                    self.applyAction(self.modal.handle(key), now_ns);
                }
            },
            .synth_editor => if (!self.handleSynthKey(key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .sampler_editor => if (self.modal.mode != .normal or !self.handleSamplerKey(key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .track_spectrum, .master_spectrum => if (!self.handleSpectrumKey(key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .piano_roll => if (self.modal.mode != .normal or !self.handlePianoRollKey(key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .instrument_picker => self.handlePickerKey(key),
            .arrangement => if (self.modal.mode != .normal or !self.handleArrangementKey(key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .tracks => {
                if (key == .enter and self.modal.mode == .normal) {
                    self.openTrack(self.cursor);
                    return;
                }
                if (key == .char and self.modal.mode == .normal) {
                    switch (key.char) {
                        'M' => { self.switchToMasterSpectrum(); return; },
                        'A' => { self.view = .arrangement; return; },
                        's' => { self.switchToTrackSpectrum(@intCast(self.cursor)); return; },
                        'p' => { self.switchToPianoRoll(@intCast(self.cursor)); return; },
                        'a' => { self.doTrackAdd(null); return; },
                        'D' => { self.doTrackDel(self.cursor); return; },
                        '?' => { commands.cmdHelp(self, ""); return; },
                        '<' => { self.doTrackPan(@intCast(self.cursor), -0.05); return; },
                        '>' => { self.doTrackPan(@intCast(self.cursor), 0.05); return; },
                        '-' => { self.doTrackGainStep(@intCast(self.cursor), -1.0); return; },
                        // + is the canonical "increase" (matches pattern length); = kept as alias.
                        '+', '=' => { self.doTrackGainStep(@intCast(self.cursor), 1.0); return; },
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

    pub fn setEqBand(self: *App, track: u16, band: usize, gain_db: f32) void {
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
                    // fine move by one step; shift (HL) jumps one beat (4 steps)
                    'h' => { if (step.* > 0) step.* -= 1; },
                    'l' => { if (step.* + 1 < self.drumMachine().step_count) step.* += 1; },
                    'H' => { step.* -|= 4; },
                    'L' => { step.* = @intCast(@min(@as(u16, step.*) + 4, self.drumMachine().step_count - 1)); },
                    'k' => if (pad.* > 0) { pad.* -= 1; },
                    'j' => if (pad.* < DrumMachine.max_pads - 1) { pad.* += 1; },
                    'p' => {
                        _ = self.session.engine.send(.{ .note_on = .{
                            .track = self.drum_track,
                            .note = @intCast(pad.*),
                            .velocity = 0.9,
                        } });
                        self.setStatus("preview: pad {d}", .{pad.* + 1});
                    },
                    '-' => {
                        const dm = self.drumMachine();
                        dm.setStepCount(dm.step_count - 1);
                        if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                    },
                    '+' => self.drumMachine().setStepCount(self.drumMachine().step_count + 1),
                    'v' => {
                        const dm = self.drumMachine();
                        if (dm.stepActive(pad.*, step.*)) {
                            dm.cycleStepVel(pad.*, step.*);
                            self.setStatus("vel {d}%", .{DrumMachine.velPercent(dm.stepVel(pad.*, step.*))});
                        } else self.setStatus("no step here — enter places one", .{});
                    },
                    '<' => self.drumAdjustSwing(-1.0),
                    '>' => self.drumAdjustSwing(1.0),
                    'X' => self.drumMachine().clearPad(pad.*),
                    'F' => self.drumMachine().fillPad(pad.*),
                    'y' => {
                        const dm = self.drumMachine();
                        self.drum_clip = dm.variantData(dm.variant);
                        self.setStatus("yanked pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
                    },
                    'P' => {
                        if (self.drum_clip) |clip| {
                            const dm = self.drumMachine();
                            dm.applyVariant(clip);
                            if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                            self.setStatus("pasted into pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
                        } else self.setStatus("nothing yanked — y copies the pattern", .{});
                    },
                    '[' => { self.drumCycleVariant(-1); },
                    ']' => { self.drumCycleVariant(1); },
                    'N' => {
                        const dm = self.drumMachine();
                        const src = dm.variant;
                        if (dm.addVariant())
                            self.setStatus("new pattern {c} (copy of {c})", .{
                                DrumMachine.variantLetter(dm.variant),
                                DrumMachine.variantLetter(src),
                            })
                        else
                            self.setStatus("pattern bank full ({d} max)", .{DrumMachine.max_variants});
                    },
                    'D' => {
                        const dm = self.drumMachine();
                        if (dm.removeVariant()) {
                            if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                            self.setStatus("deleted pattern — now on {c}", .{DrumMachine.variantLetter(dm.variant)});
                        } else self.setStatus("can't delete the only pattern", .{});
                    },
                    's' => { self.switchToTrackSpectrum(self.drum_track); return true; },
                    'e' => {
                        self.sampler_target = .{ .drum = self.drum_track };
                        self.sampler_param = 0;
                        self.view = .sampler_editor;
                        return true;
                    },
                    else => return false,
                }
                return true;
            },
            else => return false,
        }
    }

    /// Nudge the drum machine's swing and echo the new value.
    fn drumAdjustSwing(self: *App, delta: f32) void {
        const dm = self.drumMachine();
        dm.adjustSwing(delta);
        self.setStatus("swing {d:.0}%", .{dm.swing.load(.monotonic)});
    }

    /// Cycle the drum grid's active pattern variant, keeping the step cursor
    /// inside the new variant's step count.
    fn drumCycleVariant(self: *App, delta: i32) void {
        const dm = self.drumMachine();
        if (dm.variant_count <= 1) {
            self.setStatus("one pattern — N creates another", .{});
            return;
        }
        dm.cycleVariant(delta);
        if (self.drum_cursor[1] >= dm.step_count) self.drum_cursor[1] = dm.step_count - 1;
        self.setStatus("pattern {c} ({d}/{d})", .{
            DrumMachine.variantLetter(dm.variant), dm.variant + 1, dm.variant_count,
        });
    }

    /// Number of editable params for the sampler editor's current target.
    fn samplerParamCount(self: *App) u8 {
        return switch (self.sampler_target) {
            .drum => DrumMachine.pad_param_count,
            .sampler => Sampler.param_count,
        };
    }

    /// Sampler editor: j/k pick a param row, h/l/H/L nudge it. For a drum pad,
    /// 1–8 jump pads (shared `drum_cursor[0]`) and esc/e return to the drum
    /// grid; for a standalone Sampler, esc/e return to the tracks view. p
    /// auditions the current pad / the sampler's root note.
    fn handleSamplerKey(self: *App, key: modal_mod.Key) bool {
        const is_drum = self.sampler_target == .drum;
        switch (key) {
            .escape => { self.view = if (is_drum) .drum_grid else .tracks; return true; },
            .char => |c| switch (c) {
                // Block insert mode — piano keys conflict with param navigation.
                'i' => return true,
                'e' => { self.view = if (is_drum) .drum_grid else .tracks; return true; },
                'j' => {
                    if (self.sampler_param + 1 < self.samplerParamCount()) self.sampler_param += 1;
                    return true;
                },
                'k' => { if (self.sampler_param > 0) self.sampler_param -= 1; return true; },
                'h' => { self.adjustSamplerParam(-1); return true; },
                'l' => { self.adjustSamplerParam(1); return true; },
                'H' => { self.adjustSamplerParam(-10); return true; },
                'L' => { self.adjustSamplerParam(10); return true; },
                '1'...'8' => {
                    if (is_drum) {
                        const pad: u8 = c - '1';
                        if (pad < DrumMachine.max_pads) self.drum_cursor[0] = pad;
                    }
                    return true;
                },
                'p' => { self.samplerPreview(); return true; },
                else => return false,
            },
            else => return false,
        }
    }

    /// Audition the sampler editor's current target.
    fn samplerPreview(self: *App) void {
        switch (self.sampler_target) {
            .drum => |t| {
                _ = self.session.engine.send(.{ .note_on = .{
                    .track = t, .note = @intCast(self.drum_cursor[0]), .velocity = 0.9,
                } });
            },
            .sampler => |t| {
                const root: u7 = if (self.editingSampler()) |s| s.root_note else 60;
                self.playNote(t, root, self.now_ns);
            },
        }
    }

    /// Nudge the selected sampler param. Routed over the command queue so the
    /// edit lands on the audio thread (DrumMachine/Sampler.adjustParam), never
    /// racing the block reader — mirrors adjustSynthParam.
    fn adjustSamplerParam(self: *App, steps: i32) void {
        switch (self.sampler_target) {
            .drum => |t| {
                const id = DrumMachine.paramId(self.drum_cursor[0], self.sampler_param);
                _ = self.session.engine.send(.{ .set_track_param = .{ .track = t, .id = id, .steps = steps } });
            },
            .sampler => |t| {
                _ = self.session.engine.send(.{ .set_track_param = .{ .track = t, .id = self.sampler_param, .steps = steps } });
            },
        }
    }

    fn handleSynthKey(self: *App, key: modal_mod.Key) bool {
        switch (key) {
            .escape => { self.view = .tracks; return true; },
            .char => |c| switch (c) {
                // Block insert mode — piano keys conflict with parameter navigation.
                'i' => return true,
                's' => { self.switchToTrackSpectrum(self.synth_track); return true; },
                // p opens the piano roll for this track (matches p in the tracks view);
                // e in the piano roll comes back here, so synth <-> roll is bidirectional.
                'p' => { self.switchToPianoRoll(self.synth_track); return true; },
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
            .poly_synth, .sampler => {},
            else => {
                self.setStatus("piano roll: melodic tracks only", .{});
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

        const max_step: u16 = @intFromFloat(pp.length_beats * 4.0);
        switch (key) {
            .escape => { self.view = .tracks; return true; },
            // enter toggles the note; space falls through to transport play/pause.
            .enter => { self.pianoToggleNote(); return true; },
            .char => |c| switch (c) {
                // Block insert mode — piano keys collide with roll navigation (j/k/h/d/…).
                'i' => return true,
                // fine move by one step; shift (HL) jumps one beat (4 steps)
                'h' => {
                    if (self.piano_cursor_step > 0) self.piano_cursor_step -= 1;
                    self.pianoEnsureVisible();
                    return true;
                },
                'l' => {
                    if (self.piano_cursor_step + 1 < max_step) self.piano_cursor_step += 1;
                    self.pianoEnsureVisible();
                    return true;
                },
                'H' => {
                    self.piano_cursor_step -|= 4;
                    self.pianoEnsureVisible();
                    return true;
                },
                'L' => {
                    if (max_step > 0)
                        self.piano_cursor_step = @min(self.piano_cursor_step + 4, max_step - 1);
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
                // J/K jump an octave (mirrors h/l → H/L coarse-move pattern).
                'J' => {
                    self.piano_cursor_pitch = @intCast(self.piano_cursor_pitch -| 12);
                    self.pianoEnsureVisible();
                    return true;
                },
                'K' => {
                    self.piano_cursor_pitch = @intCast(@min(@as(u32, self.piano_cursor_pitch) + 12, 127));
                    self.pianoEnsureVisible();
                    return true;
                },
                // g/G jump the cursor to loop start / last step.
                'g' => {
                    self.piano_cursor_step = 0;
                    self.pianoEnsureVisible();
                    return true;
                },
                'G' => {
                    if (max_step > 0) self.piano_cursor_step = max_step - 1;
                    self.pianoEnsureVisible();
                    return true;
                },
                // </> nudge the velocity of the note under the cursor.
                '<' => { self.pianoNudgeVelocity(-0.1); return true; },
                '>' => { self.pianoNudgeVelocity(0.1); return true; },
                'y' => { self.pianoYank(); return true; },
                'P' => { self.pianoPaste(); return true; },
                's' => { self.switchToTrackSpectrum(self.piano_track); return true; },
                // n/d kept as aliases for muscle memory; enter is the canonical toggle.
                'n' => { self.pianoInsertNote(); return true; },
                'd' => { self.pianoDeleteNote(); return true; },
                'p' => {
                    self.playNote(self.piano_track, self.piano_cursor_pitch, self.now_ns);
                    var nbuf: [5]u8 = undefined;
                    self.setStatus("preview: {s}", .{midi.noteName(self.piano_cursor_pitch, &nbuf)});
                    return true;
                },
                'e' => {
                    // Jump to the instrument editor for this track (synth or sampler).
                    switch (self.session.racks.items[self.piano_track].instrument) {
                        .sampler => {
                            self.sampler_target = .{ .sampler = self.piano_track };
                            self.sampler_param = 0;
                            self.view = .sampler_editor;
                        },
                        else => {
                            self.synth_track = self.piano_track;
                            self.synth_cursor = 0;
                            self.synthUpdateScroll();
                            self.view = .synth_editor;
                        },
                    }
                    return true;
                },
                // [/] resize the note under the cursor if one starts here;
                // otherwise they set the default length for newly placed notes.
                '[' => { self.pianoResizeOrLen(-0.25); return true; },
                ']' => { self.pianoResizeOrLen(0.25); return true; },
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

    /// Toggle the note at the cursor: remove it if one starts here on this pitch,
    /// otherwise add one with the current note length. Mirrors the drum grid's
    /// enter-to-toggle so both grid editors share the same place/erase gesture.
    fn pianoToggleNote(self: *App) void {
        if (self.piano_track >= self.session.racks.items.len) return;
        const pp = if (self.session.racks.items[self.piano_track].pattern_player != null)
            &self.session.racks.items[self.piano_track].pattern_player.?
        else return;
        const start_beat = @as(f64, @floatFromInt(self.piano_cursor_step)) * 0.25;
        if (pp.noteStartsAt(self.piano_cursor_pitch, start_beat)) {
            self.pianoDeleteNote();
        } else {
            self.pianoInsertNote();
        }
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

    /// Resize the note starting under the cursor by `delta` beats (clamped to
    /// the loop length), or — if no note starts here — change the default length
    /// applied to newly placed notes.
    fn pianoResizeOrLen(self: *App, delta: f64) void {
        if (self.piano_track >= self.session.racks.items.len) return;
        const pp = if (self.session.racks.items[self.piano_track].pattern_player != null)
            &self.session.racks.items[self.piano_track].pattern_player.?
        else return;
        const start_beat = @as(f64, @floatFromInt(self.piano_cursor_step)) * 0.25;
        if (pp.noteAt(self.piano_cursor_pitch, start_beat)) |n| {
            n.duration_beat = std.math.clamp(n.duration_beat + delta, 0.25, pp.length_beats);
            self.setStatus("note len: {d:.2} beats", .{n.duration_beat});
        } else {
            self.piano_note_len = std.math.clamp(self.piano_note_len + delta, 0.25, pp.length_beats);
            self.setStatus("default len: {d:.2} beats", .{self.piano_note_len});
        }
    }

    /// Nudge the velocity of the note under the cursor by `delta` (clamped 0.05–1).
    fn pianoNudgeVelocity(self: *App, delta: f32) void {
        if (self.piano_track >= self.session.racks.items.len) return;
        const pp = if (self.session.racks.items[self.piano_track].pattern_player != null)
            &self.session.racks.items[self.piano_track].pattern_player.?
        else return;
        const start_beat = @as(f64, @floatFromInt(self.piano_cursor_step)) * 0.25;
        if (pp.noteAt(self.piano_cursor_pitch, start_beat)) |n| {
            n.velocity = std.math.clamp(n.velocity + delta, 0.05, 1.0);
            self.setStatus("velocity: {d:.0}%", .{n.velocity * 100.0});
        } else {
            self.setStatus("no note under cursor", .{});
        }
    }

    /// Yank the piano roll's whole pattern (notes + loop length) to the
    /// app clipboard.
    fn pianoYank(self: *App) void {
        if (self.piano_track >= self.session.racks.items.len) return;
        const pp = if (self.session.racks.items[self.piano_track].pattern_player != null)
            &self.session.racks.items[self.piano_track].pattern_player.?
        else return;
        var clip: PianoClip = .{ .notes = undefined, .count = 0, .length_beats = pp.length_beats };
        clip.count = pp.copyNotes(&clip.notes);
        self.piano_clip = clip;
        self.setStatus("yanked {d} notes ({d:.0} beats)", .{ clip.count, clip.length_beats });
    }

    /// Replace this track's pattern with the yanked one.
    fn pianoPaste(self: *App) void {
        if (self.piano_track >= self.session.racks.items.len) return;
        const pp = if (self.session.racks.items[self.piano_track].pattern_player != null)
            &self.session.racks.items[self.piano_track].pattern_player.?
        else return;
        if (self.piano_clip) |*clip| {
            pp.setNotes(clip.notes[0..clip.count], clip.length_beats);
            self.setStatus("pasted {d} notes ({d:.0} beats)", .{ clip.count, clip.length_beats });
        } else self.setStatus("nothing yanked — y copies the pattern", .{});
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

    fn playNote(self: *App, track: u16, pitch: u7, now_ns: i96) void {
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

    // -----------------------------------------------------------------------
    // Arrangement view
    // -----------------------------------------------------------------------

    /// h/l move ±1 bar, H/L ±4 bars (one phrase), j/k change lane (shared
    /// `cursor`), enter stamps the live pattern as a clip, x deletes, [/]
    /// cycle a drum lane's pattern variant, T toggles song/pattern mode.
    /// Returns false for unhandled keys (space, `:`, …) so the transport and
    /// command line still work. Scroll is clamped at draw.
    fn handleArrangementKey(self: *App, key: modal_mod.Key) bool {
        const lane_count = self.session.project.tracks.items.len;
        switch (key) {
            .escape => { self.view = .tracks; return true; },
            .enter => { self.arrStampClip(); return true; },
            .char => |c| switch (c) {
                // Block insert mode — piano keys would collide with navigation.
                'i' => return true,
                'h' => { self.arrMoveBar(-1); return true; },
                'l' => { self.arrMoveBar(1); return true; },
                'H' => { self.arrMoveBar(-4); return true; },
                'L' => { self.arrMoveBar(4); return true; },
                '0' => { self.arr_cursor_bar = 0; return true; },
                'j' => { if (self.cursor + 1 < lane_count) self.cursor += 1; return true; },
                'k' => { if (self.cursor > 0) self.cursor -= 1; return true; },
                'x' => { self.arrDeleteClip(); return true; },
                'g' => { self.arrPlayFromCursor(); return true; },
                '[' => { self.arrCycleDrumVariant(-1); return true; },
                ']' => { self.arrCycleDrumVariant(1); return true; },
                'T' => {
                    self.session.setSongMode(!self.session.song_mode);
                    self.setStatus("{s} mode", .{if (self.session.song_mode) "song" else "pattern"});
                    return true;
                },
                else => return false,
            },
            else => return false,
        }
    }

    fn arrMoveBar(self: *App, delta: i64) void {
        const nb = @as(i64, self.arr_cursor_bar) + delta;
        self.arr_cursor_bar = @intCast(@max(@as(i64, 0), nb));
    }

    /// Seek the playhead to the cursor bar, starting playback if stopped —
    /// audition the song from the point being arranged (same bar math as
    /// `:seek`, minus the 1-based parsing).
    fn arrPlayFromCursor(self: *App) void {
        const sr = @as(f64, @floatFromInt(self.session.project.sample_rate));
        const bpm = @max(self.session.project.tempo_bpm, 1.0);
        const bpb: f64 = @floatFromInt(self.session.engine.transport.time_signature.beats_per_bar);
        const frames_per_bar: u64 = @intFromFloat(sr * 60.0 / bpm * bpb);
        _ = self.session.engine.send(.{ .seek_frames = self.arr_cursor_bar * frames_per_bar });
        if (!self.session.engine.uiSnapshot().playing) _ = self.session.engine.send(.play);
        self.setStatus("play from bar {d}", .{self.arr_cursor_bar + 1});
    }

    /// On a drum lane, cycle which pattern variant `enter` will stamp. This is
    /// the machine's active variant — the same one the drum grid edits and
    /// pattern mode plays — so there is only one notion of "selected pattern".
    fn arrCycleDrumVariant(self: *App, delta: i32) void {
        if (self.cursor >= self.session.racks.items.len) return;
        switch (self.session.racks.items[self.cursor].instrument) {
            .drum_machine => |*dm| {
                if (dm.variant_count <= 1) {
                    self.setStatus("one pattern — create variants in the drum grid (N)", .{});
                    return;
                }
                dm.cycleVariant(delta);
                self.setStatus("pattern {c} ({d}/{d})", .{
                    DrumMachine.variantLetter(dm.variant), dm.variant + 1, dm.variant_count,
                });
            },
            else => self.setStatus("not a drum track", .{}),
        }
    }

    /// Capture the cursor track's live pattern as a clip at the cursor bar,
    /// then jump the cursor to the clip's end for quick sequential placing.
    fn arrStampClip(self: *App) void {
        if (self.cursor >= self.session.racks.items.len) return;
        if (std.meta.activeTag(self.session.racks.items[self.cursor].instrument) == .empty) {
            self.setStatus("empty track — insert an instrument first", .{});
            return;
        }
        self.session.stampClip(self.cursor, self.arr_cursor_bar) catch {
            self.setStatus("stamp failed (out of memory)", .{});
            return;
        };
        if (self.session.arrangement.lane(self.cursor)) |lane| {
            if (lane.clipAt(self.arr_cursor_bar)) |clip| {
                switch (clip.content) {
                    .drum => |d| self.setStatus("stamped {d}-bar clip (pat {c})", .{
                        clip.length_bars, DrumMachine.variantLetter(d.variant),
                    }),
                    .melodic => self.setStatus("stamped {d}-bar clip", .{clip.length_bars}),
                }
                self.arr_cursor_bar = clip.endBar();
            }
        }
        // Keep song playback in sync with the edit if it's driving the transport.
        if (self.session.song_mode) self.session.rebuildSongData();
    }

    fn arrDeleteClip(self: *App) void {
        const lane = self.session.arrangement.lane(self.cursor) orelse return;
        if (lane.removeAt(self.allocator, self.arr_cursor_bar))
            self.setStatus("deleted clip", .{})
        else
            self.setStatus("no clip here", .{});
        if (self.session.song_mode) self.session.rebuildSongData();
    }

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
// Tests
// ---------------------------------------------------------------------------

/// Build a deterministic 3-track app for tests: synth(0), sampler(1), drums(2).
fn testApp() !App {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    errdefer app.deinit();
    try app.session.setInstrument(0, .poly_synth);
    _ = try app.session.addTrack("samp");
    try app.session.setInstrument(1, .sampler);
    _ = try app.session.addTrack("drums");
    try app.session.setInstrument(2, .drum_machine);
    return app;
}

test "cursor movement clamps to track range" {
    var app = try testApp();
    defer app.deinit();

    app.applyAction(.{ .move = .{ .dy = 10 } }, 0);
    try std.testing.expectEqual(@as(usize, 2), app.cursor);
    app.applyAction(.{ .move = .{ .dy = -1 } }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.cursor);
    app.applyAction(.{ .move = .{ .dy = -10 } }, 0);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
}

test "default session starts with one blank track" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 1), app.session.racks.items.len);
    try std.testing.expectEqual(InstrumentKind.empty, std.meta.activeTag(app.session.racks.items[0].instrument));
}

test "enter on a blank track opens the instrument picker" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.instrument_picker, app.view);
}

test "picker inserts the highlighted instrument and opens its editor" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.enter, 0); // open picker on the blank track
    app.handleKey(.{ .char = 'j' }, 0); // move to Sampler (index 1)
    try std.testing.expectEqual(@as(u8, 1), app.picker_cursor);
    app.handleKey(.enter, 0); // insert
    try std.testing.expectEqual(InstrumentKind.sampler, std.meta.activeTag(app.session.racks.items[0].instrument));
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
}

test "renderBounce sequences notes offline and restores transport" {
    var app = try testApp();
    defer app.deinit();

    // Sequence a note at beat 0 on the synth track; leave the transport stopped.
    app.session.racks.items[0].pattern_player.?.addNote(
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 },
    );
    try std.testing.expect(!app.session.engine.transport.playing);

    var buffer: [4096 * engine_mod.channels]types.Sample = undefined;
    commands.renderBounce(&app, &buffer);

    var peak: f32 = 0.0;
    for (buffer) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.001);

    try std.testing.expect(!app.session.engine.transport.playing);
    try std.testing.expectEqual(@as(u64, 0), app.session.engine.transport.position_frames);
}

test "toggle_mute flips project state and reaches the engine" {
    var app = try testApp();
    defer app.deinit();

    app.applyAction(.toggle_mute, 0);
    try std.testing.expect(app.session.project.tracks.items[0].muted);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.engine.tracks[0].muted);
}

test "toggle_solo flips project state and reaches the engine" {
    var app = try testApp();
    defer app.deinit();

    app.applyAction(.toggle_solo, 0);
    try std.testing.expect(app.session.project.tracks.items[0].soloed);

    var block: [64]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.engine.tracks[0].soloed);
}

test "notes route to a synth track and queue their own release" {
    var app = try testApp();
    defer app.deinit();

    // cursor 0 is a synth → note plays and schedules a release.
    app.applyAction(.{ .note = .{ .pitch = 60 } }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);

    app.tick(note_ms * std.time.ns_per_ms / 2);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
    app.tick(note_ms * std.time.ns_per_ms + 1);
    try std.testing.expectEqual(@as(usize, 0), app.note_off_len);
}

test "notes on a sampler track schedule a release too" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 1; // sampler
    app.applyAction(.{ .note = .{ .pitch = 67 } }, 0);
    try std.testing.expectEqual(@as(usize, 1), app.note_off_len);
}

test "typed :q quits via the modal layer" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    for (":q") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expect(app.should_quit);
}

test "enter on a drum track switches to drum_grid view" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 2; // drum machine
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
    try std.testing.expectEqual(@as(u16, 2), app.drum_track);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "drum grid step toggle" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;

    try std.testing.expect(app.drumMachine().stepActive(0, 0));
    app.drum_cursor = .{ 0, 0 };
    _ = app.handleDrumKey(.enter);
    try std.testing.expect(!app.drumMachine().stepActive(0, 0));
}

test "piano roll yank/paste moves a pattern across tracks" {
    var app = try testApp();
    defer app.deinit();

    // Track 0 (synth): one note, 8-beat loop. Yank it.
    app.piano_track = 0;
    const src = &app.session.racks.items[0].pattern_player.?;
    src.addNote(.{ .pitch = 72, .start_beat = 1.0, .duration_beat = 0.5 });
    src.length_beats = 8.0;
    _ = app.handlePianoRollKey(.{ .char = 'y' });

    // Paste replaces track 1's (sampler) pattern wholesale.
    app.piano_track = 1;
    const dst = &app.session.racks.items[1].pattern_player.?;
    dst.addNote(.{ .pitch = 30, .start_beat = 0.0, .duration_beat = 1.0 });
    _ = app.handlePianoRollKey(.{ .char = 'P' });
    try std.testing.expectEqual(@as(u16, 1), dst.note_count);
    try std.testing.expectEqual(@as(u7, 72), dst.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), dst.length_beats, 1e-9);
}

test "drum grid yank/paste carries pattern, velocity, and length" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;
    const dm = app.drumMachine();

    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.setStepCount(32);
    dm.toggleStep(0, 7);
    dm.setStepVel(0, 7, 2);
    _ = app.handleDrumKey(.{ .char = 'y' });

    // A fresh variant wipes the grid; paste restores the yanked pattern.
    _ = app.handleDrumKey(.{ .char = 'N' });
    dm.clearPad(0);
    dm.setStepCount(16);
    _ = app.handleDrumKey(.{ .char = 'P' });
    try std.testing.expect(dm.stepActive(0, 7));
    try std.testing.expectEqual(@as(u2, 2), dm.stepVel(0, 7));
    try std.testing.expectEqual(@as(u8, 32), dm.step_count);
}

test "paste with an empty clipboard is a no-op" {
    var app = try testApp();
    defer app.deinit();
    app.drum_track = 2;

    const before = app.drumMachine().pattern[0].load(.acquire);
    _ = app.handleDrumKey(.{ .char = 'P' });
    try std.testing.expectEqual(before, app.drumMachine().pattern[0].load(.acquire));

    app.piano_track = 0;
    _ = app.handlePianoRollKey(.{ .char = 'P' });
    try std.testing.expectEqual(@as(u16, 0), app.session.racks.items[0].pattern_player.?.note_count);
}

test "arrangement g plays from the cursor bar" {
    var app = try testApp();
    defer app.deinit();

    app.view = .arrangement;
    app.arr_cursor_bar = 2;
    app.handleKey(.{ .char = 'g' }, 0);

    // Commands land on the audio thread; run one block to apply them.
    var block: [512]ws.types.Sample = undefined;
    app.session.engine.process(&block);
    // 120 bpm 4/4 at 48kHz → 96_000 frames per bar; the seek lands at bar 2
    // and the block advances 256 frames because playback started.
    try std.testing.expect(app.session.engine.transport.playing);
    try std.testing.expectEqual(@as(u64, 192_256), app.session.engine.transport.position_frames);
}

test "draw renders drum_grid view without overflowing" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.view = .drum_grid;
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "DRUMS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "kick") != null);
}

test "e opens drum-pad sampler editor from drum grid; esc returns" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.view = .drum_grid;
    app.drum_cursor = .{ 2, 0 };
    _ = app.handleDrumKey(.{ .char = 'e' });
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expect(app.sampler_target == .drum);

    _ = app.handleSamplerKey(.{ .char = 'j' });
    try std.testing.expectEqual(@as(u8, 1), app.sampler_param);
    _ = app.handleSamplerKey(.{ .char = '5' });
    try std.testing.expectEqual(@as(u8, 4), app.drum_cursor[0]);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);
}

test "enter on a sampler track opens the standalone sampler editor" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 1; // sampler
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.sampler_editor, app.view);
    try std.testing.expect(app.sampler_target == .sampler);
    // esc returns to the tracks view (not the drum grid) for a standalone sampler.
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "draw renders drum-pad sampler editor without overflowing" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.sampler_target = .{ .drum = 2 };
    app.drum_cursor = .{ 0, 0 };
    app.view = .sampler_editor;
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 30 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SAMPLER") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "attack") != null);
}

test "draw renders standalone sampler editor with root row" {
    var app = try testApp();
    defer app.deinit();

    app.sampler_target = .{ .sampler = 1 };
    app.view = .sampler_editor;
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 34 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SAMPLER") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "root") != null);
}

test "drum-pad sampler param edit routes to the drum machine" {
    var app = try testApp();
    defer app.deinit();

    app.drum_track = 2;
    app.sampler_target = .{ .drum = 2 };
    app.drum_cursor = .{ 0, 0 };
    app.sampler_param = 2; // pitch
    app.adjustSamplerParam(5);
    var block: [128]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.racks.items[2].instrument.drum_machine.pads[0].?.pitch_semitones > 0.0);
}

test "standalone sampler param edit routes to the sampler" {
    var app = try testApp();
    defer app.deinit();

    app.sampler_target = .{ .sampler = 1 };
    app.sampler_param = 2; // pitch
    app.adjustSamplerParam(5);
    var block: [128]types.Sample = undefined;
    app.session.engine.process(&block);
    try std.testing.expect(app.session.racks.items[1].instrument.sampler.pad.pitch_semitones > 0.0);
}

test "draw renders tracks view without overflowing" {
    var app = try testApp();
    defer app.deinit();

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "NORMAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "synth") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "drums") != null);
}

test "blank track row shows the empty hint" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "empty") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "SPECTRUM") != null);
}

test "draw renders track_spectrum after pressing s" {
    var app = try testApp();
    defer app.deinit();
    app.handleKey(.{ .char = 's' }, 0);
    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "SPECTRUM") != null);
}

test "spectrum fills FFT buffer and draws with real data" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    _ = app.session.engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    var block: [512]types.Sample = undefined;
    for (0..16) |_| app.session.engine.process(&block);

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 120, .rows = 40 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "SPECTRUM") != null);
}

test "track add appends a blank track at the end" {
    var app = try testApp();
    defer app.deinit();

    const initial_tracks = app.session.project.tracks.items.len;
    app.doTrackAdd("strings");

    try std.testing.expectEqual(initial_tracks + 1, app.session.project.tracks.items.len);
    try std.testing.expectEqual(initial_tracks + 1, app.session.racks.items.len);
    const last = app.session.racks.items.len - 1;
    try std.testing.expectEqualStrings("strings", app.session.project.tracks.items[last].name);
    try std.testing.expectEqual(InstrumentKind.empty, std.meta.activeTag(app.session.racks.items[last].instrument));
    try std.testing.expectEqual(@as(usize, last), app.cursor);
}

test "track delete removes the rack and shifts later tracks down" {
    var app = try testApp();
    defer app.deinit();

    const initial_tracks = app.session.project.tracks.items.len;
    app.doTrackDel(1); // remove the sampler

    try std.testing.expectEqual(initial_tracks - 1, app.session.project.tracks.items.len);
    try std.testing.expectEqual(initial_tracks - 1, app.session.racks.items.len);
    // The drum machine that was at index 2 is now index 1.
    try std.testing.expectEqual(InstrumentKind.drum_machine, std.meta.activeTag(app.session.racks.items[1].instrument));
}

test ":track-add command adds a blank track" {
    var app = try testApp();
    defer app.deinit();

    const before = app.session.project.tracks.items.len;
    for (":track-add mytrack") |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(before + 1, app.session.project.tracks.items.len);
    const last = app.session.project.tracks.items.len - 1;
    try std.testing.expectEqualStrings("mytrack", app.session.project.tracks.items[last].name);
}

test ":track-del command deletes a track" {
    var app = try testApp();
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
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0); // cursor 0 = synth
    try std.testing.expectEqual(AppView.synth_editor, app.view);
    try std.testing.expectEqual(@as(u16, 0), app.synth_track);
}

test "synth editor esc returns to tracks" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "synth editor jk moves cursor, hl adjusts waveform" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(u8, 0), app.synth_cursor);

    var block: [64]types.Sample = undefined;
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    const synth = &app.session.racks.items[0].instrument.poly_synth;
    try std.testing.expect(synth.waveform != .saw);

    for (0..16) |_| app.handleKey(.{ .char = 'j' }, 0);
    try std.testing.expectEqual(@as(u8, 16), app.synth_cursor);

    const old_attack = synth.attack_s;
    app.handleKey(.{ .char = 'l' }, 0);
    app.session.engine.process(&block);
    try std.testing.expect(synth.attack_s > old_attack);
}

test "draw renders synth editor without errors" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.synth_editor, app.view);

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
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "TRACKS") != null);
}

test "p key opens piano roll for synth track" {
    var app = try testApp();
    defer app.deinit();

    app.handleKey(.{ .char = 'p' }, 0); // cursor 0 = synth
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expectEqual(@as(u16, 0), app.piano_track);

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 120, .rows = 36 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "PIANO ROLL") != null);

    app.piano_cursor_step = 0;
    app.piano_cursor_pitch = 60;
    app.handleKey(.{ .char = 'n' }, 0);
    const pp = &app.session.racks.items[0].pattern_player.?;
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);

    app.handleKey(.{ .char = 'd' }, 0);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "p key opens piano roll for sampler track" {
    var app = try testApp();
    defer app.deinit();
    app.cursor = 1; // sampler
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.piano_roll, app.view);
    try std.testing.expectEqual(@as(u16, 1), app.piano_track);
}

test "piano roll p does not open for drum track" {
    var app = try testApp();
    defer app.deinit();

    app.cursor = 2; // drum machine
    app.handleKey(.{ .char = 'p' }, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

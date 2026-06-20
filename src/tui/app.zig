const std = @import("std");
const builtin = @import("builtin");
const types = @import("../core/types.zig");
const engine_mod = @import("../audio/engine.zig");
const backend_mod = @import("../audio/backend.zig");
const modal_mod = @import("../input/modal.zig");
const terminal_mod = @import("terminal.zig");
const dsp = @import("../dsp/device.zig");
const Project = @import("../project.zig").Project;
const Transport = @import("../transport.zig").Transport;
const PolySynth = @import("../dsp/synth.zig").PolySynth;
const Compressor = @import("../dsp/compressor.zig").Compressor;
const StereoDelay = @import("../dsp/delay.zig").StereoDelay;
const Reverb = @import("../dsp/reverb.zig").Reverb;
const DrumMachine = @import("../dsp/drum_sampler.zig").DrumMachine;
const GraphicEq = @import("../dsp/eq.zig").GraphicEq;
const eq_mod = @import("../dsp/eq.zig");
const wav = @import("../core/wav.zig");
const cmd_mod = @import("cmd.zig");
const draw_mod = @import("draw.zig");
pub const Rack = @import("rack.zig").Rack;

const Engine = engine_mod.Engine;

const note_ms = 220;
const frame_poll_ms = 30;

pub const AppView = enum { tracks, drum_grid, help, track_spectrum, master_spectrum };

fn wrap(comptime f: fn (*App, []const u8) void) *const fn (*anyopaque, []const u8) void {
    return struct {
        fn call(ctx: *anyopaque, args: []const u8) void {
            f(@ptrCast(@alignCast(ctx)), args);
        }
    }.call;
}

const cmds: []const cmd_mod.Def = &.{
    .{ .name = "q",        .desc = "quit wstudio",                      .run = wrap(App.cmdQuit) },
    .{ .name = "quit",     .desc = "quit wstudio",                      .run = wrap(App.cmdQuit) },
    .{ .name = "bpm",      .desc = "[<value>]  tempo in BPM (20–400)",  .run = wrap(App.cmdBpm) },
    .{ .name = "gain",     .desc = "<track> [<dB>]  track gain",        .run = wrap(App.cmdGain) },
    .{ .name = "vol",      .desc = "[<dB>]  master volume (–40 to +6)", .run = wrap(App.cmdVol) },
    .{ .name = "seek",     .desc = "<bar>  move playhead to bar",       .run = wrap(App.cmdSeek) },
    .{ .name = "load-pad", .desc = "<0-7> <file>  load WAV into pad",   .run = wrap(App.cmdLoadPad) },
    .{ .name = "help",     .desc = "list all commands",                 .run = wrap(App.cmdHelp) },
    .{ .name = "eq",       .desc = "<track> [<band> <db>]  EQ control", .run = wrap(App.cmdEq) },
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project: Project,
    engine: *Engine,
    racks: []Rack,
    drum: *DrumMachine,
    drum_track: u16,
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
    note_offs: [32]NoteOff = undefined,
    note_off_len: usize = 0,
    eq_cursor: usize = 0,
    eq_track: u16 = 0,

    const NoteOff = struct { at_ns: i96, track: u16, note: u7 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !App {
        var project = Project.init(allocator);
        errdefer project.deinit();
        _ = try project.addTrack(.{ .name = "lead" });
        _ = try project.addTrack(.{ .name = "pad", .gain_db = -6.0 });
        _ = try project.addTrack(.{ .name = "bass", .gain_db = -3.0 });
        _ = try project.addTrack(.{ .name = "drums" });
        const sr = project.sample_rate;

        const engine = try allocator.create(Engine);
        errdefer allocator.destroy(engine);
        engine.* = try Engine.init(allocator, sr);
        engine.loadProject(&project);

        const racks = try allocator.alloc(Rack, 3);
        errdefer allocator.free(racks);

        racks[0] = .{ .synth = PolySynth.init(sr), .label = "synth+comp+dly+rev" };
        racks[0].comp = Compressor.init(sr);
        racks[0].delay = try StereoDelay.init(allocator, sr, 2.0);
        racks[0].delay.?.setTime(0.375);
        racks[0].reverb = try Reverb.init(allocator, sr);

        racks[1] = .{ .synth = PolySynth.init(sr), .label = "synth+rev" };
        racks[1].synth.waveform = .sine;
        racks[1].synth.attack_s = 0.08;
        racks[1].synth.release_s = 0.8;
        racks[1].reverb = try Reverb.init(allocator, sr);
        racks[1].reverb.?.mix = 0.45;

        racks[2] = .{ .synth = PolySynth.init(sr), .label = "synth" };
        racks[2].synth.waveform = .square;
        racks[2].synth.gain = 0.25;

        const drum = try allocator.create(DrumMachine);
        errdefer allocator.destroy(drum);
        drum.* = try DrumMachine.init(allocator, sr, &engine.transport);
        errdefer drum.deinit();
        const drum_track: u16 = @intCast(project.tracks.items.len - 1);

        var self: App = .{
            .allocator = allocator,
            .io = io,
            .project = project,
            .engine = engine,
            .racks = racks,
            .drum = drum,
            .drum_track = drum_track,
        };
        for (self.racks, 0..) |*rack, i| {
            var buf: [5]dsp.Device = undefined;
            self.engine.setTrackChain(@intCast(i), rack.chain(&buf));
        }
        self.engine.setTrackChain(drum_track, &.{self.drum.device()});
        return self;
    }

    pub fn deinit(self: *App) void {
        for (self.racks) |*rack| {
            if (rack.delay) |*d| d.deinit(self.allocator);
            if (rack.reverb) |*r| r.deinit(self.allocator);
        }
        self.allocator.free(self.racks);
        self.drum.deinit();
        self.allocator.destroy(self.drum);
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        self.project.deinit();
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
            .track_spectrum, .master_spectrum => if (!self.handleSpectrumKey(key)) {
                self.applyAction(self.modal.handle(key), now_ns);
            },
            .tracks => {
                if (key == .enter and self.cursor == self.drum_track) {
                    self.view = .drum_grid;
                    return;
                }
                if (key == .char) {
                    switch (key.char) {
                        'm' => { self.switchToMasterSpectrum(); return; },
                        's' => { self.switchToTrackSpectrum(@intCast(self.cursor)); return; },
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
        _ = self.engine.send(.{ .set_spectrum_active = .{ .source = .track, .track = track } });
    }

    fn switchToMasterSpectrum(self: *App) void {
        self.prev_view = self.view;
        self.view = .master_spectrum;
        self.eq_cursor = 0;
        _ = self.engine.send(.{ .set_spectrum_active = .{ .source = .master, .track = 0 } });
    }

    fn handleSpectrumKey(self: *App, key: modal_mod.Key) bool {
        switch (key) {
            .escape => {
                _ = self.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
                self.view = self.prev_view;
                return true;
            },
            .char => |c| switch (c) {
                'h' => { if (self.eq_cursor > 0) self.eq_cursor -= 1; },
                'l' => { if (self.eq_cursor < eq_mod.num_eq_bands - 1) self.eq_cursor += 1; },
                'j', 'J' => {
                    if (self.view == .track_spectrum and self.eq_track < self.racks.len) {
                        const delta: f32 = if (c == 'J') -6.0 else -1.0;
                        self.setEqBand(self.eq_track, self.eq_cursor, self.currentEqGain(self.eq_track) + delta);
                    }
                },
                'k', 'K' => {
                    if (self.view == .track_spectrum and self.eq_track < self.racks.len) {
                        const delta: f32 = if (c == 'K') 6.0 else 1.0;
                        self.setEqBand(self.eq_track, self.eq_cursor, self.currentEqGain(self.eq_track) + delta);
                    }
                },
                'b' => {
                    if (self.view == .track_spectrum and self.eq_track < self.racks.len) {
                        if (self.racks[self.eq_track].eq) |*eq| {
                            eq.bypass = !eq.bypass;
                            var buf: [5]dsp.Device = undefined;
                            self.engine.setTrackChain(self.eq_track, self.racks[self.eq_track].recreateChain(&buf));
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
        if (track < self.racks.len) {
            if (self.racks[track].eq) |*e| return e.bands[self.eq_cursor].gain_db;
        }
        return 0.0;
    }

    fn setEqBand(self: *App, track: u16, band: usize, gain_db: f32) void {
        if (track >= self.racks.len) return;
        const rack = &self.racks[track];
        if (rack.eq == null) rack.eq = GraphicEq.init(self.project.sample_rate);
        rack.eq.?.setBand(band, gain_db);
        var buf: [5]dsp.Device = undefined;
        self.engine.setTrackChain(track, rack.recreateChain(&buf));
    }

    pub fn handleDrumKey(self: *App, key: modal_mod.Key) bool {
        const pad = &self.drum_cursor[0];
        const step = &self.drum_cursor[1];
        switch (key) {
            .escape => { self.view = .tracks; return true; },
            .char => |c| {
                switch (c) {
                    'h' => step.* = if (step.* == 0) DrumMachine.max_steps - 1 else step.* - 1,
                    'l' => step.* = (step.* + 1) % DrumMachine.max_steps,
                    'k' => if (pad.* > 0) { pad.* -= 1; },
                    'j' => if (pad.* < DrumMachine.max_pads - 1) { pad.* += 1; },
                    ' ' => self.drum.toggleStep(pad.*, step.*),
                    'p' => _ = self.engine.send(.{ .note_on = .{
                        .track = self.drum_track,
                        .note = @intCast(pad.*),
                        .velocity = 0.9,
                    } }),
                    else => return false,
                }
                return true;
            },
            else => return false,
        }
    }

    pub fn applyAction(self: *App, action: modal_mod.Action, now_ns: i96) void {
        switch (action) {
            .none, .octave_up, .octave_down, .goto_end => {},
            .volume_delta => |delta| {
                self.master_gain_db = std.math.clamp(
                    self.master_gain_db + @as(f32, @floatFromInt(delta)),
                    -40.0,
                    6.0,
                );
                _ = self.engine.send(.{ .set_master_gain = types.dbToGain(self.master_gain_db) });
            },
            .mode_changed => self.status_len = 0,
            .move => |m| {
                const count: i64 = @as(i64, @intCast(self.cursor)) + m.dy;
                const last: i64 = @intCast(self.project.tracks.items.len - 1);
                self.cursor = @intCast(std.math.clamp(count, 0, last));
            },
            .goto_start => _ = self.engine.send(.{ .seek_frames = 0 }),
            .toggle_play => {
                const cmd: engine_mod.Command = if (self.engine.uiSnapshot().playing) .stop else .play;
                _ = self.engine.send(cmd);
            },
            .toggle_mute => {
                const track = &self.project.tracks.items[self.cursor];
                track.muted = !track.muted;
                _ = self.engine.send(.{ .set_track_mute = .{
                    .track = @intCast(self.cursor),
                    .muted = track.muted,
                } });
            },
            .note => |n| {
                if (self.cursor != self.drum_track) {
                    self.playNote(n.pitch, now_ns);
                } else {
                    _ = self.engine.send(.{ .note_on = .{
                        .track = self.drum_track,
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
        _ = self.engine.send(.{ .note_on = .{ .track = track, .note = pitch, .velocity = 0.85 } });
        if (self.note_off_len == self.note_offs.len) {
            const oldest = self.note_offs[0];
            _ = self.engine.send(.{ .note_off = .{ .track = oldest.track, .note = oldest.note } });
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
        var i: usize = 0;
        while (i < self.note_off_len) {
            const off = self.note_offs[i];
            if (off.at_ns <= now_ns) {
                _ = self.engine.send(.{ .note_off = .{ .track = off.track, .note = off.note } });
                std.mem.copyForwards(NoteOff, self.note_offs[i .. self.note_off_len - 1], self.note_offs[i + 1 .. self.note_off_len]);
                self.note_off_len -= 1;
            } else {
                i += 1;
            }
        }
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
        self.drum.loadPadWav(pad_idx, data, stem) catch |e| {
            self.setStatus("load-pad: parse error: {s}", .{@errorName(e)});
            return;
        };
        self.setStatus("pad {d} loaded: {s}", .{ pad_idx, stem });
    }

    fn cmdBpm(self: *App, args: []const u8) void {
        const trimmed = std.mem.trim(u8, args, " ");
        if (trimmed.len == 0) {
            self.setStatus("bpm: {d:.1}", .{self.project.tempo_bpm});
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
        self.project.tempo_bpm = bpm;
        _ = self.engine.send(.{ .set_tempo = bpm });
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
        if (track_1 == 0 or track_1 > self.project.tracks.items.len) {
            self.setStatus("gain: track must be 1–{d}", .{self.project.tracks.items.len});
            return;
        }
        const track_idx = track_1 - 1;
        const track = &self.project.tracks.items[track_idx];
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
        _ = self.engine.send(.{ .set_track_gain = .{
            .track = @intCast(track_idx),
            .gain = types.dbToGain(clamped),
        } });
        self.setStatus("track {d} gain: {d:.1}dB", .{ track_1, clamped });
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
        const sr = @as(f64, @floatFromInt(self.project.sample_rate));
        const bpm = @max(self.project.tempo_bpm, 1.0);
        const beats_per_bar: f64 = @floatFromInt(self.engine.transport.time_signature.beats_per_bar);
        const frames_per_bar: u64 = @intFromFloat(sr * 60.0 / bpm * beats_per_bar);
        _ = self.engine.send(.{ .seek_frames = (bar_1 - 1) * frames_per_bar });
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
        _ = self.engine.send(.{ .set_master_gain = types.dbToGain(self.master_gain_db) });
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
        if (track_1 == 0 or track_1 > self.racks.len) {
            self.setStatus("eq: track must be 1–{d}", .{self.racks.len});
            return;
        }
        const track_idx = track_1 - 1;
        const rest = std.mem.trim(u8, it.rest(), " ");
        if (rest.len == 0) {
            if (self.racks[track_idx].eq) |*eq| {
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
    }

    // -----------------------------------------------------------------------
    // Rendering (delegates to draw.zig)
    // -----------------------------------------------------------------------

    pub fn draw(self: *App, w: *std.Io.Writer, size: terminal_mod.Size) !void {
        const snap = self.engine.uiSnapshot();
        const rows: usize = @max(size.rows, 10);

        try w.writeAll("\x1b[H");
        try draw_mod.drawHeader(w, &self.project, &self.engine.transport, self.audio_label, self.master_gain_db);
        try draw_mod.hr(w, size.cols);

        switch (self.view) {
            .tracks         => try draw_mod.drawTracks(self, w, rows, snap),
            .drum_grid      => try draw_mod.drawDrumGrid(self, w, rows, snap),
            .help           => try draw_mod.drawHelp(w, rows, cmds),
            .track_spectrum => try draw_mod.drawSpectrumView(self, w, rows, snap, true),
            .master_spectrum => try draw_mod.drawSpectrumView(self, w, rows, snap, false),
        }

        var transport: Transport = .{
            .sample_rate = self.project.sample_rate,
            .tempo_bpm = self.project.tempo_bpm,
            .position_frames = snap.position_frames,
        };
        const pos = transport.positionBarBeat();
        const secs = transport.positionSeconds();
        const icon: []const u8 = if (snap.playing) "|>" else "[]";
        try w.print(" {s} {d:0>3}.{d}  {d:0>2}:{d:0>4.1}  L", .{
            icon,
            pos.bar + 1,
            pos.beat + 1,
            @as(u64, @intFromFloat(secs / 60.0)),
            @mod(secs, 60.0),
        });
        try draw_mod.meter(w, snap.peak[0]);
        try w.writeAll(" R");
        try draw_mod.meter(w, snap.peak[1]);
        try draw_mod.endLine(w);
        try draw_mod.hr(w, size.cols);

        switch (self.view) {
            .tracks          => try draw_mod.drawTracksStatus(self, w),
            .drum_grid       => try draw_mod.drawDrumStatus(self, w),
            .help            => try w.writeAll(" esc: close"),
            .track_spectrum  => try draw_mod.drawSpectrumStatus(self, w, true),
            .master_spectrum => try draw_mod.drawSpectrumStatus(self, w, false),
        }
        try w.writeAll("\x1b[K");
    }
};

fn renderTrampoline(ctx: *anyopaque, out: []types.Sample) void {
    const engine: *Engine = @ptrCast(@alignCast(ctx));
    engine.process(out);
}

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
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

    const config: backend_mod.Config = .{ .sample_rate = app.project.sample_rate };

    const has_alsa = builtin.os.tag == .linux;
    const AlsaBackend = if (has_alsa) @import("../audio/alsa.zig").AlsaBackend else void;
    var alsa_backend: AlsaBackend = undefined;
    var null_backend = backend_mod.NullBackend{
        .config = config,
        .render = renderTrampoline,
        .ctx = app.engine,
    };

    var using_alsa = false;
    if (has_alsa) {
        alsa_backend = .{ .config = config, .render = renderTrampoline, .ctx = app.engine };
        if (alsa_backend.start()) {
            using_alsa = true;
        } else |_| {}
    }
    if (!using_alsa) try null_backend.start(io);
    defer if (using_alsa) alsa_backend.stop() else null_backend.stop();
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

test "toggle_mute flips project state and reaches the engine" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.applyAction(.toggle_mute, 0);
    try std.testing.expect(app.project.tracks.items[0].muted);

    var block: [64]types.Sample = undefined;
    app.engine.process(&block);
    try std.testing.expect(app.engine.tracks[0].muted);
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
    try std.testing.expectEqual(app.drum_track, @as(u16, @intCast(app.cursor)));

    app.handleKey(.enter, 0);
    try std.testing.expectEqual(AppView.drum_grid, app.view);

    app.handleKey(.escape, 0);
    try std.testing.expectEqual(AppView.tracks, app.view);
}

test "drum grid step toggle" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    try std.testing.expect(app.drum.stepActive(0, 0));

    app.drum_cursor = .{ 0, 0 };
    _ = app.handleDrumKey(.{ .char = ' ' });
    try std.testing.expect(!app.drum.stepActive(0, 0));
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

    app.handleKey(.{ .char = 'm' }, 0);
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
    try std.testing.expectEqual(AppView.track_spectrum, app.view);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SPECTRUM") != null);
}

test "draw renders spectrum view when engine has activated the analyzer" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    try std.testing.expectEqual(AppView.track_spectrum, app.view);

    var block: [512]types.Sample = undefined;
    app.engine.process(&block);

    var buf: [32 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 80, .rows = 24 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SPECTRUM") != null);
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

test "spectrum fills FFT buffer and draws with real data" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.handleKey(.{ .char = 's' }, 0);
    _ = app.engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    var block: [512]types.Sample = undefined;
    for (0..16) |_| app.engine.process(&block);

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try app.draw(&w, .{ .cols = 120, .rows = 40 });
    const frame = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "SPECTRUM") != null);
}

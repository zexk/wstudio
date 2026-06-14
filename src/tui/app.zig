//! TUI application: owns the project, engine, and device racks; turns
//! modal actions into engine commands; draws the screen. Drawing and
//! dispatch are separated from the terminal so both are testable.

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
const wav = @import("../core/wav.zig");

const Engine = engine_mod.Engine;

const note_ms = 220;
const frame_poll_ms = 30;

const Rack = struct {
    synth: PolySynth,
    comp: ?Compressor = null,
    delay: ?StereoDelay = null,
    reverb: ?Reverb = null,
    label: []const u8,

    fn chain(self: *Rack, buf: *[4]dsp.Device) []const dsp.Device {
        var len: usize = 0;
        buf[len] = self.synth.device();
        len += 1;
        if (self.comp) |*c| {
            buf[len] = c.device();
            len += 1;
        }
        if (self.delay) |*d| {
            buf[len] = d.device();
            len += 1;
        }
        if (self.reverb) |*r| {
            buf[len] = r.device();
            len += 1;
        }
        return buf[0..len];
    }
};

const AppView = enum { tracks, drum_grid };

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project: Project,
    engine: *Engine,
    racks: []Rack,
    drum: DrumMachine,
    drum_track: u16, // engine track index for the drum machine
    modal: modal_mod.ModalInput = .{},
    cursor: usize = 0,
    view: AppView = .tracks,
    /// Cursor within the drum grid: [pad_idx, step_idx]
    drum_cursor: [2]u8 = .{ 0, 0 },
    audio_label: []const u8 = "off",
    master_gain_db: f32 = 0.0,
    should_quit: bool = false,
    status_buf: [80]u8 = undefined,
    status_len: usize = 0,
    note_offs: [32]NoteOff = undefined,
    note_off_len: usize = 0,

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
        engine.* = Engine.init(sr);
        engine.loadProject(&project);

        // Synth racks for tracks 0–2
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

        // DrumMachine for track 3; transport pointer is stable (engine is heap)
        var drum = try DrumMachine.init(allocator, sr, &engine.transport);
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
            var buf: [4]dsp.Device = undefined;
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
        self.allocator.destroy(self.engine);
        self.project.deinit();
    }

    pub fn handleKey(self: *App, key: modal_mod.Key, now_ns: i96) void {
        if (key == .ctrl_c) {
            self.should_quit = true;
            return;
        }

        switch (self.view) {
            .drum_grid => self.handleDrumKey(key),
            .tracks => {
                // Enter on the drum track opens the grid
                if (key == .enter and self.cursor == self.drum_track) {
                    self.view = .drum_grid;
                    return;
                }
                self.applyAction(self.modal.handle(key), now_ns);
            },
        }
    }

    fn handleDrumKey(self: *App, key: modal_mod.Key) void {
        const pad = &self.drum_cursor[0];
        const step = &self.drum_cursor[1];
        switch (key) {
            .escape => self.view = .tracks,
            .char => |c| switch (c) {
                'h' => step.* = if (step.* == 0) DrumMachine.max_steps - 1 else step.* - 1,
                'l' => step.* = (step.* + 1) % DrumMachine.max_steps,
                'k' => if (pad.* > 0) {
                    pad.* -= 1;
                },
                'j' => if (pad.* < DrumMachine.max_pads - 1) {
                    pad.* += 1;
                },
                ' ' => self.drum.toggleStep(pad.*, step.*),
                // Quick pad preview in grid view
                'p' => _ = self.engine.send(.{ .note_on = .{
                    .track = self.drum_track,
                    .note = @intCast(pad.*),
                    .velocity = 0.9,
                } }),
                else => {},
            },
            else => {},
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
                // Don't play notes on the drum track from the piano keyboard;
                // notes on drum tracks trigger pads directly via engine events
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

    fn runCommand(self: *App, text: []const u8) void {
        if (std.mem.eql(u8, text, "q") or std.mem.eql(u8, text, "quit")) {
            self.should_quit = true;
        } else if (std.mem.startsWith(u8, text, "load-pad ")) {
            self.cmdLoadPad(text["load-pad ".len..]);
        } else if (std.mem.startsWith(u8, text, "vol")) {
            self.cmdVol(text["vol".len..]);
        } else {
            self.setStatus("not a command: {s}", .{text});
        }
    }

    /// :load-pad <pad 0-7> <path/to/file.wav>
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

        // Derive name from filename (last path component, no extension)
        const basename = std.fs.path.basename(path);
        const stem = if (std.mem.lastIndexOf(u8, basename, ".")) |dot|
            basename[0..dot]
        else
            basename;

        self.drum.loadPadWav(pad_idx, data, stem) catch |e| {
            self.setStatus("load-pad: parse error: {s}", .{@errorName(e)});
            return;
        };
        self.setStatus("pad {d} loaded: {s}", .{ pad_idx, stem });
    }

    /// :vol [<dB>]  — set or query master gain. E.g. `:vol -6`, `:vol +3`, `:vol`
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

    fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.status_buf, fmt, args) catch &self.status_buf;
        self.status_len = msg.len;
    }

    // ------------------------------------------------------------------
    // Drawing

    pub fn draw(self: *App, w: *std.Io.Writer, size: terminal_mod.Size) !void {
        const snap = self.engine.uiSnapshot();
        const rows: usize = @max(size.rows, 10);

        try w.writeAll("\x1b[H");
        try drawHeader(w, &self.project, &self.engine.transport, self.audio_label, self.master_gain_db);
        try hr(w, size.cols);

        switch (self.view) {
            .tracks => try self.drawTracks(w, rows, snap),
            .drum_grid => try self.drawDrumGrid(w, rows, snap),
        }

        // Transport + meters
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
        try meter(w, snap.peak[0]);
        try w.writeAll(" R");
        try meter(w, snap.peak[1]);
        try endLine(w);
        try hr(w, size.cols);

        // Status line
        switch (self.view) {
            .tracks => try self.drawTracksStatus(w),
            .drum_grid => try self.drawDrumStatus(w),
        }
        try w.writeAll("\x1b[K");
    }

    fn drawHeader(w: *std.Io.Writer, project: *const Project, transport: *const Transport, audio_label: []const u8, master_gain_db: f32) !void {
        const vol_sign: []const u8 = if (master_gain_db >= 0) "+" else "";
        try w.print(" wstudio - {s}", .{project.name});
        try w.print("   bpm {d:.0}  {d}/{d}   vol: {s}{d:.0}dB   audio: {s}", .{
            project.tempo_bpm,
            transport.time_signature.beats_per_bar,
            transport.time_signature.beat_unit,
            vol_sign,
            master_gain_db,
            audio_label,
        });
        try endLine(w);
    }

    fn drawTracks(self: *App, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
        _ = snap;
        try w.writeAll(" TRACKS\r\n");
        for (self.project.tracks.items, 0..) |track, i| {
            const is_drum = (i == self.drum_track);
            const label: []const u8 = if (is_drum) "drum machine" else self.racks[i].label;
            const hint: []const u8 = if (is_drum) " [enter:open grid]" else "";
            const marker: []const u8 = if (i == self.cursor) ">" else " ";
            const inv: []const u8 = if (i == self.cursor) "\x1b[7m" else "";
            const mute: []const u8 = if (track.muted) "M" else " ";
            try w.print(" {s}{s} {d} {s: <8} {s} [{s}]{s}\x1b[0m", .{
                inv, marker, i + 1, track.name, mute, label, hint,
            });
            try endLine(w);
        }
        const used = 3 + self.project.tracks.items.len;
        for (used..rows - 3) |_| try endLine(w);
    }

    fn drawDrumGrid(self: *App, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
        _ = snap;
        const playing_step = self.drum.currentStep();
        const is_playing = self.engine.uiSnapshot().playing;
        const cur_pad = self.drum_cursor[0];
        const cur_step = self.drum_cursor[1];

        const track_name = self.project.tracks.items[self.drum_track].name;
        try w.print(" DRUMS \"{s}\"  [hjkl:move  spc:toggle  p:preview  esc:back]\r\n", .{track_name});

        // Step header
        try w.writeAll("      ");
        for (0..DrumMachine.max_steps) |s| {
            if (s % 4 == 0) try w.writeByte('|');
            try w.print("{d:>2} ", .{s + 1});
        }
        try endLine(w);

        // Pad rows
        for (0..DrumMachine.max_pads) |p| {
            const name = self.drum.padName(@intCast(p));
            try w.print(" {s: <4} ", .{name[0..@min(name.len, 4)]});
            for (0..DrumMachine.max_steps) |s| {
                if (s % 4 == 0) try w.writeByte('|');
                const active = self.drum.stepActive(@intCast(p), @intCast(s));
                const is_cursor = (p == cur_pad and s == cur_step);
                const is_play = is_playing and (s == playing_step);

                if (is_cursor) try w.writeAll("\x1b[7m");
                if (is_play and !is_cursor) try w.writeAll("\x1b[1m");

                try w.writeAll(if (active) "[X]" else "[ ]");

                if (is_cursor or is_play) try w.writeAll("\x1b[0m");
            }
            try endLine(w);
        }

        // Padding
        const used = 4 + DrumMachine.max_pads;
        for (used..rows - 3) |_| try endLine(w);
    }

    fn drawTracksStatus(self: *App, w: *std.Io.Writer) !void {
        switch (self.modal.mode) {
            .command => try w.print(" :{s}_", .{self.modal.cmd_buf[0..self.modal.cmd_len]}),
            else => {
                const mode_name = switch (self.modal.mode) {
                    .normal => "NORMAL",
                    .insert => "INSERT",
                    .visual => "VISUAL",
                    .command => unreachable,
                };
                try w.print(" \x1b[7m {s} \x1b[0m oct {d}", .{ mode_name, self.modal.octave });
                if (self.modal.count > 0) try w.print("  {d}", .{self.modal.count});
                if (self.status_len > 0) try w.print("  {s}", .{self.status_buf[0..self.status_len]});
            },
        }
    }

    fn drawDrumStatus(self: *App, w: *std.Io.Writer) !void {
        const p = self.drum_cursor[0];
        const s = self.drum_cursor[1];
        try w.print(" \x1b[7m DRUM \x1b[0m  pad {d}/8  step {d}/16  {s}", .{
            p + 1,
            s + 1,
            self.drum.padName(p),
        });
        if (self.status_len > 0) try w.print("  {s}", .{self.status_buf[0..self.status_len]});
    }

    fn endLine(w: *std.Io.Writer) !void {
        try w.writeAll("\x1b[K\r\n");
    }

    fn hr(w: *std.Io.Writer, cols: u16) !void {
        for (0..@min(cols, 100)) |_| try w.writeByte('-');
        try endLine(w);
    }

    fn meter(w: *std.Io.Writer, peak: f32) !void {
        const cells = 10;
        const db = types.gainToDb(peak);
        const norm = std.math.clamp((db + 50.0) / 50.0, 0.0, 1.0);
        const filled: usize = @intFromFloat(norm * cells);
        try w.writeByte('[');
        for (0..cells) |i| try w.writeByte(if (i < filled) '#' else '-');
        try w.writeByte(']');
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

test "cursor movement clamps to track range" {
    var app = try App.init(std.testing.allocator, std.Io.failing);
    defer app.deinit();

    app.applyAction(.{ .move = .{ .dy = 10 } }, 0);
    try std.testing.expectEqual(@as(usize, 3), app.cursor); // now 4 tracks
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

    // Navigate to drum track (index 3)
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

    // Kick (pad 0) step 0 should be active from default pattern
    try std.testing.expect(app.drum.stepActive(0, 0));

    // Toggle it off
    app.drum_cursor = .{ 0, 0 };
    app.handleDrumKey(.{ .char = ' ' });
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

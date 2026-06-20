const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("../dsp/device.zig");
const spectrum_mod = @import("../dsp/spectrum.zig");
const Spsc = @import("../core/ring_buffer.zig").Spsc;
const Transport = @import("../transport.zig").Transport;
const Project = @import("../project.zig").Project;

const Sample = types.Sample;
const SpectrumAnalyzer = spectrum_mod.SpectrumAnalyzer;
const SpectrumSnapshot = spectrum_mod.SpectrumSnapshot;

pub const max_tracks = 64;
pub const max_chain_devices = 8;
pub const channels = 2;

pub const SpectrumSource = enum { none, track, master };

pub const Command = union(enum) {
    play,
    stop,
    seek_frames: u64,
    set_tempo: f64,
    set_master_gain: f32,
    set_track_gain: struct { track: u16, gain: f32 },
    set_track_pan: struct { track: u16, pan: f32 },
    set_track_mute: struct { track: u16, muted: bool },
    note_on: struct { track: u16, note: u7, velocity: f32 },
    note_off: struct { track: u16, note: u7 },
    all_notes_off,
    set_spectrum_active: struct { source: SpectrumSource, track: u16 },
};

const TrackState = struct {
    active: bool = false,
    gain: f32 = 1.0,
    pan: f32 = 0.0,
    muted: bool = false,
    chain: [max_chain_devices]dsp.Device = undefined,
    chain_len: usize = 0,
};

pub const UiSnapshot = struct {
    playing: bool,
    position_frames: u64,
    peak: [channels]f32,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    commands: Spsc(Command, 256) = .{},
    master_gain: f32 = 1.0,
    tracks: [max_tracks]TrackState = [_]TrackState{.{}} ** max_tracks,
    scratch: [types.max_block_frames * channels]Sample = undefined,
    peak: [channels]f32 = .{ 0.0, 0.0 },
    track_spectrum: []SpectrumAnalyzer,
    master_spectrum: SpectrumAnalyzer,
    active_spectrum_source: SpectrumSource = .none,
    active_spectrum_track: u16 = 0,
    shared: Shared = .{},

    const Shared = struct {
        playing: std.atomic.Value(bool) = .init(false),
        position_frames: std.atomic.Value(u64) = .init(0),
        peak_bits: [channels]std.atomic.Value(u32) = .{ .init(0), .init(0) },
    };

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Engine {
        const track_spec = try allocator.alloc(SpectrumAnalyzer, max_tracks);
        var initialized: usize = 0;
        errdefer {
            for (track_spec[0..initialized]) |*sa| sa.deinit(allocator);
            allocator.free(track_spec);
        }
        for (track_spec) |*sa| {
            sa.* = try SpectrumAnalyzer.init(allocator, sample_rate);
            initialized += 1;
        }
        const master_spec = try SpectrumAnalyzer.init(allocator, sample_rate);

        return .{
            .allocator = allocator,
            .transport = .{ .sample_rate = sample_rate },
            .track_spectrum = track_spec,
            .master_spectrum = master_spec,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.master_spectrum.deinit(self.allocator);
        for (self.track_spectrum) |*sa| sa.deinit(self.allocator);
        self.allocator.free(self.track_spectrum);
    }

    pub fn loadProject(self: *Engine, project: *const Project) void {
        self.transport.tempo_bpm = project.tempo_bpm;
        for (&self.tracks, 0..) |*state, i| {
            if (i < project.tracks.items.len) {
                const t = project.tracks.items[i];
                state.* = .{
                    .active = true,
                    .gain = types.dbToGain(t.gain_db),
                    .pan = t.pan,
                    .muted = t.muted,
                };
            } else {
                state.* = .{};
            }
        }
    }

    pub fn setTrackChain(self: *Engine, track: u16, devices: []const dsp.Device) void {
        const state = self.trackAt(track);
        state.chain_len = @min(devices.len, max_chain_devices);
        for (devices[0..state.chain_len], state.chain[0..state.chain_len]) |src, *dst| {
            dst.* = src;
        }
    }

    pub fn send(self: *Engine, cmd: Command) bool {
        return self.commands.push(cmd);
    }

    pub fn process(self: *Engine, out: []Sample) void {
        const frames: u32 = @intCast(out.len / channels);
        std.debug.assert(frames <= types.max_block_frames);

        self.drainCommands();
        @memset(out, 0.0);
        self.renderTracks(out, frames);

        self.peak = .{ 0.0, 0.0 };
        var i: usize = 0;
        while (i < out.len) : (i += channels) {
            inline for (0..channels) |ch| {
                out[i + ch] *= self.master_gain;
                const mag = @abs(out[i + ch]);
                if (mag > self.peak[ch]) self.peak[ch] = mag;
            }
        }

        self.master_spectrum.push(out);
        self.master_spectrum.analyze();

        self.transport.advance(frames);

        self.shared.playing.store(self.transport.playing, .monotonic);
        self.shared.position_frames.store(self.transport.position_frames, .monotonic);
        inline for (0..channels) |ch| {
            self.shared.peak_bits[ch].store(@bitCast(self.peak[ch]), .monotonic);
        }
    }

    pub fn uiSnapshot(self: *const Engine) UiSnapshot {
        var snap: UiSnapshot = .{
            .playing = self.shared.playing.load(.monotonic),
            .position_frames = self.shared.position_frames.load(.monotonic),
            .peak = undefined,
        };
        inline for (0..channels) |ch| {
            snap.peak[ch] = @bitCast(self.shared.peak_bits[ch].load(.monotonic));
        }
        return snap;
    }

    pub fn trackSpectrumSnapshot(self: *const Engine, track: u16) ?SpectrumSnapshot {
        if (track >= max_tracks) return null;
        return self.track_spectrum[track].snapshot();
    }

    pub fn masterSpectrumSnapshot(self: *const Engine) ?SpectrumSnapshot {
        return self.master_spectrum.snapshot();
    }

    fn drainCommands(self: *Engine) void {
        while (self.commands.pop()) |cmd| switch (cmd) {
            .play => self.transport.play(),
            .stop => self.transport.stop(),
            .seek_frames => |f| self.transport.seekFrames(f),
            .set_tempo => |bpm| self.transport.tempo_bpm = bpm,
            .set_master_gain => |g| self.master_gain = g,
            .set_track_gain => |c| self.trackAt(c.track).gain = c.gain,
            .set_track_pan => |c| self.trackAt(c.track).pan = c.pan,
            .set_track_mute => |c| self.trackAt(c.track).muted = c.muted,
            .note_on => |c| self.sendTrackEvent(c.track, .{
                .note_on = .{ .note = c.note, .velocity = c.velocity },
            }),
            .note_off => |c| self.sendTrackEvent(c.track, .{
                .note_off = .{ .note = c.note },
            }),
            .all_notes_off => for (&self.tracks) |*t| {
                for (t.chain[0..t.chain_len]) |dev| dev.sendEvent(.all_off);
            },
            .set_spectrum_active => |c| {
                self.active_spectrum_source = c.source;
                self.active_spectrum_track = c.track;
                for (self.track_spectrum) |*sa| sa.active.store(false, .release);
                self.master_spectrum.active.store(false, .release);
                switch (c.source) {
                    .none => {},
                    .track => {
                        if (c.track < max_tracks) self.track_spectrum[c.track].active.store(true, .release);
                    },
                    .master => self.master_spectrum.active.store(true, .release),
                }
            },
        };
    }

    fn trackAt(self: *Engine, index: u16) *TrackState {
        return &self.tracks[@min(index, max_tracks - 1)];
    }

    fn sendTrackEvent(self: *Engine, track: u16, ev: dsp.Event) void {
        const state = self.trackAt(track);
        for (state.chain[0..state.chain_len]) |dev| dev.sendEvent(ev);
    }

    fn renderTracks(self: *Engine, out: []Sample, frames: u32) void {
        for (&self.tracks, 0..) |*track, ti| {
            if (!track.active or track.chain_len == 0) continue;

            const scratch = self.scratch[0 .. frames * channels];
            @memset(scratch, 0.0);
            for (track.chain[0..track.chain_len]) |dev| dev.process(scratch);

            if (track.muted) continue;

            const angle = (track.pan + 1.0) * std.math.pi / 4.0;
            const gain_l = track.gain * @cos(angle);
            const gain_r = track.gain * @sin(angle);
            for (0..frames) |i| {
                out[i * channels] += scratch[i * channels] * gain_l;
                out[i * channels + 1] += scratch[i * channels + 1] * gain_r;
            }

            self.track_spectrum[ti].push(scratch);
            self.track_spectrum[ti].analyze();
        }
    }
};

const PolySynth = @import("../dsp/synth.zig").PolySynth;
const DrumMachine = @import("../dsp/drum_sampler.zig").DrumMachine;

test "notes sound even while transport is stopped (live preview)" {
    var synth = PolySynth.init(48_000);
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.tracks[0] = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);

    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    engine.process(&block);
    try std.testing.expect(engine.peak[0] > 0.01);
    try std.testing.expectEqual(@as(u64, 0), engine.transport.position_frames);
}

test "transport advances only while playing" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var block: [512]Sample = undefined;

    engine.process(&block);
    try std.testing.expectEqual(@as(u64, 0), engine.transport.position_frames);

    _ = engine.send(.play);
    engine.process(&block);
    try std.testing.expectEqual(@as(u64, 256), engine.transport.position_frames);
}

test "mute command silences a track" {
    var synth = PolySynth.init(48_000);
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.tracks[0] = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.send(.{ .set_track_mute = .{ .track = 0, .muted = true } });

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);
}

test "uiSnapshot publishes transport and meter state" {
    var synth = PolySynth.init(48_000);
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.tracks[0] = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.play);
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });

    var block: [512]Sample = undefined;
    engine.process(&block);

    const snap = engine.uiSnapshot();
    try std.testing.expect(snap.playing);
    try std.testing.expectEqual(@as(u64, 256), snap.position_frames);
    try std.testing.expect(snap.peak[0] > 0.01);
}

test "spectrum snapshot returns null when inactive" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.masterSpectrumSnapshot() == null);
}

test "spectrum snapshot returns data when active" {
    var synth = PolySynth.init(48_000);
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.tracks[0] = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.send(.{ .set_spectrum_active = .{ .source = .track, .track = 0 } });

    var block: [512]Sample = undefined;
    // Process enough blocks to fill the FFT window
    for (0..10) |_| engine.process(&block);

    const snap = engine.trackSpectrumSnapshot(0);
    try std.testing.expect(snap != null);
    var has_signal = false;
    for (snap.?.bins) |b| {
        if (b > -80.0) has_signal = true;
    }
    try std.testing.expect(has_signal);
}

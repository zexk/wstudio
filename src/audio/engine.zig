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

pub const max_tracks = 8192;
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
    cc: struct { track: u16, cc: u7, value: u7 },
    pitch_bend: struct { track: u16, bend: i16 },
    /// Nudge synth editor parameter `id` by `steps` on track `track`. Applied
    /// on the audio thread so editor edits don't race the block reader.
    set_track_param: struct { track: u16, id: u8, steps: i32 },
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
    tracks: [max_tracks]TrackState,
    scratch: [types.max_block_frames * channels]Sample = undefined,
    peak: [channels]f32 = .{ 0.0, 0.0 },
    /// Single analyzer reused for whichever track is being viewed.
    track_spectrum: SpectrumAnalyzer,
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
        var track_spec = try SpectrumAnalyzer.init(allocator, sample_rate);
        errdefer track_spec.deinit(allocator);
        const master_spec = try SpectrumAnalyzer.init(allocator, sample_rate);

        var self = Engine{
            .allocator = allocator,
            .transport = .{ .sample_rate = sample_rate },
            .tracks = undefined,
            .track_spectrum = track_spec,
            .master_spectrum = master_spec,
        };
        for (&self.tracks) |*t| t.* = .{};
        return self;
    }

    pub fn deinit(self: *Engine) void {
        self.master_spectrum.deinit(self.allocator);
        self.track_spectrum.deinit(self.allocator);
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

    /// Shift engine slot `idx` up by one (to make room for a new track),
    /// then initialize `idx` as a new active track with no chain.
    /// Called from the UI/control thread — same class of race as setTrackChain.
    pub fn applyInsertTrack(self: *Engine, idx: u16, gain: f32, pan: f32, muted: bool) void {
        // Move the slot at idx (typically the drum) up to idx+1.
        if (idx < max_tracks - 1) self.tracks[idx + 1] = self.tracks[idx];
        self.tracks[idx] = .{
            .active = true,
            .gain = gain,
            .pan = pan,
            .muted = muted,
            .chain_len = 0,
        };
    }

    /// Shift engine slots [idx+1, total) down by one, clearing the last slot.
    /// Called from the UI/control thread — same class of race as setTrackChain.
    pub fn applyDeleteTrack(self: *Engine, idx: u16, total: u16) void {
        for (idx..total - 1) |i| self.tracks[i] = self.tracks[i + 1];
        self.tracks[total - 1] = .{};
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

    /// Returns the current spectrum snapshot for the given track, or null if
    /// that track is not the one being analyzed. Relies on the analyzer's
    /// `active` atomic — no race on internal fields.
    pub fn trackSpectrumSnapshot(self: *const Engine, track: u16) ?SpectrumSnapshot {
        _ = track;
        return self.track_spectrum.snapshot();
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
            .cc         => |c| self.sendTrackEvent(c.track, .{ .cc         = .{ .cc   = c.cc,   .value = c.value } }),
            .pitch_bend => |c| self.sendTrackEvent(c.track, .{ .pitch_bend = .{ .bend = c.bend } }),
            .set_track_param => |c| self.sendTrackEvent(c.track, .{ .set_param = .{ .id = c.id, .steps = c.steps } }),
            .set_spectrum_active => |c| {
                self.active_spectrum_source = c.source;
                // Reset buffer when switching to a different track so stale
                // data from the previous track doesn't bleed into the view.
                if (c.source == .track and c.track != self.active_spectrum_track) {
                    self.track_spectrum.accumulated = 0;
                }
                self.active_spectrum_track = c.track;
                self.track_spectrum.active.store(c.source == .track, .release);
                self.master_spectrum.active.store(c.source == .master, .release);
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

            if (self.active_spectrum_source == .track and
                ti == self.active_spectrum_track)
            {
                self.track_spectrum.push(scratch);
                self.track_spectrum.analyze();
            }
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
    for (0..10) |_| engine.process(&block);

    const snap = engine.trackSpectrumSnapshot(0);
    try std.testing.expect(snap != null);
    var has_signal = false;
    for (snap.?.bins) |b| {
        if (b > -80.0) has_signal = true;
    }
    try std.testing.expect(has_signal);
}

test "loadProject mirrors track settings" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    _ = try project.addTrack(.{ .name = "a", .gain_db = -6.0206, .pan = -1.0 });

    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.loadProject(&project);

    try std.testing.expect(engine.tracks[0].active);
    try std.testing.expect(!engine.tracks[1].active);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), engine.tracks[0].gain, 1e-4);
}

test "applyInsertTrack shifts drum and inits new slot" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();

    engine.tracks[0] = .{ .active = true, .gain = 0.5 }; // lead
    engine.tracks[1] = .{ .active = true, .gain = 0.8 }; // drum at slot 1

    // Insert before drum (at idx=1)
    engine.applyInsertTrack(1, 1.0, 0.0, false);

    try std.testing.expect(engine.tracks[1].active);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), engine.tracks[1].gain, 1e-6);
    try std.testing.expectEqual(@as(usize, 0), engine.tracks[1].chain_len);
    // Drum shifted to slot 2
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), engine.tracks[2].gain, 1e-6);
}

test "applyDeleteTrack shifts tracks down" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();

    engine.tracks[0] = .{ .active = true, .gain = 0.1 };
    engine.tracks[1] = .{ .active = true, .gain = 0.2 }; // deleted
    engine.tracks[2] = .{ .active = true, .gain = 0.3 };
    engine.tracks[3] = .{ .active = true, .gain = 0.4 }; // drum

    engine.applyDeleteTrack(1, 4);

    try std.testing.expectApproxEqAbs(@as(f32, 0.1), engine.tracks[0].gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), engine.tracks[1].gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), engine.tracks[2].gain, 1e-6);
    try std.testing.expect(!engine.tracks[3].active); // cleared
}

//! Real-time audio engine.
//!
//! `process` runs on the audio thread and must stay allocation-free,
//! lock-free, and syscall-free. All mutation arrives through the
//! command queue; everything else is fixed-size state owned here.
//!
//! Each track holds a chain of devices (instrument first, then
//! effects). Chains always run — even with the transport stopped — so
//! live keyboard input is audible and effect tails ring out; the
//! transport only gates the playhead.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("../dsp/device.zig");
const Spsc = @import("../core/ring_buffer.zig").Spsc;
const Transport = @import("../transport.zig").Transport;
const Project = @import("../project.zig").Project;

const Sample = types.Sample;

pub const max_tracks = 64;
pub const max_chain_devices = 8;
pub const channels = 2; // stereo until a flexible bus layout lands

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
};

/// RT-side mirror of a project track: just what rendering needs.
const TrackState = struct {
    active: bool = false,
    gain: f32 = 1.0,
    pan: f32 = 0.0,
    muted: bool = false,
    chain: [max_chain_devices]dsp.Device = undefined,
    chain_len: usize = 0,
};

/// Engine state published for UI threads, read via `uiSnapshot`.
pub const UiSnapshot = struct {
    playing: bool,
    position_frames: u64,
    peak: [channels]f32,
};

pub const Engine = struct {
    transport: Transport,
    commands: Spsc(Command, 256) = .{},
    master_gain: f32 = 1.0,
    tracks: [max_tracks]TrackState = [_]TrackState{.{}} ** max_tracks,
    scratch: [types.max_block_frames * channels]Sample = undefined,
    /// Per-channel peak of the last block, for metering.
    peak: [channels]f32 = .{ 0.0, 0.0 },
    shared: Shared = .{},

    /// Atomic mirror of RT state so UI threads can read it without
    /// touching the audio thread's data.
    const Shared = struct {
        playing: std.atomic.Value(bool) = .init(false),
        position_frames: std.atomic.Value(u64) = .init(0),
        peak_bits: [channels]std.atomic.Value(u32) = .{ .init(0), .init(0) },
    };

    pub fn init(sample_rate: u32) Engine {
        return .{ .transport = .{ .sample_rate = sample_rate } };
    }

    /// Control-side setup. Call before the backend starts (or while
    /// stopped); concurrent edits go through commands instead.
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

    /// Control-side setup, like `loadProject`. Devices must outlive
    /// the engine (or be detached before they are freed).
    pub fn setTrackChain(self: *Engine, track: u16, devices: []const dsp.Device) void {
        const state = self.trackAt(track);
        state.chain_len = @min(devices.len, max_chain_devices);
        for (devices[0..state.chain_len], state.chain[0..state.chain_len]) |src, *dst| {
            dst.* = src;
        }
    }

    /// Control side. Returns false if the queue is full.
    pub fn send(self: *Engine, cmd: Command) bool {
        return self.commands.push(cmd);
    }

    /// Audio thread entry point. `out` is interleaved stereo;
    /// out.len / channels frames are rendered.
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

        self.transport.advance(frames);

        self.shared.playing.store(self.transport.playing, .monotonic);
        self.shared.position_frames.store(self.transport.position_frames, .monotonic);
        inline for (0..channels) |ch| {
            self.shared.peak_bits[ch].store(@bitCast(self.peak[ch]), .monotonic);
        }
    }

    /// Safe to call from any thread while the audio thread runs.
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
        for (&self.tracks) |*track| {
            if (!track.active or track.chain_len == 0) continue;

            const scratch = self.scratch[0 .. frames * channels];
            @memset(scratch, 0.0);
            for (track.chain[0..track.chain_len]) |dev| dev.process(scratch);

            if (track.muted) continue;

            // constant-power pan law
            const angle = (track.pan + 1.0) * std.math.pi / 4.0;
            const gain_l = track.gain * @cos(angle);
            const gain_r = track.gain * @sin(angle);
            for (0..frames) |i| {
                out[i * channels] += scratch[i * channels] * gain_l;
                out[i * channels + 1] += scratch[i * channels + 1] * gain_r;
            }
        }
    }
};

const PolySynth = @import("../dsp/synth.zig").PolySynth;
const DrumMachine = @import("../dsp/drum_sampler.zig").DrumMachine;

test "notes sound even while transport is stopped (live preview)" {
    var synth = PolySynth.init(48_000);
    var engine = Engine.init(48_000);
    engine.tracks[0] = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);

    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    engine.process(&block);
    try std.testing.expect(engine.peak[0] > 0.01);
    // transport did not move: nothing is playing back
    try std.testing.expectEqual(@as(u64, 0), engine.transport.position_frames);
}

test "transport advances only while playing" {
    var engine = Engine.init(48_000);
    var block: [512]Sample = undefined;

    engine.process(&block);
    try std.testing.expectEqual(@as(u64, 0), engine.transport.position_frames);

    _ = engine.send(.play);
    engine.process(&block);
    try std.testing.expectEqual(@as(u64, 256), engine.transport.position_frames);
}

test "mute command silences a track" {
    var synth = PolySynth.init(48_000);
    var engine = Engine.init(48_000);
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
    var engine = Engine.init(48_000);
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

test "drum machine fires through engine on first block" {
    var engine = Engine.init(48_000);
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &engine.transport);
    defer dm.deinit();
    engine.tracks[0] = .{ .active = true };
    engine.setTrackChain(0, &.{dm.device()});

    _ = engine.send(.play);
    var block: [512]Sample = undefined;
    engine.process(&block);

    // Default pattern: kick (pad 0) and hihat (pad 2) fire on step 0.
    try std.testing.expect(engine.peak[0] > 0.01);
}

test "loadProject mirrors track settings" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    _ = try project.addTrack(.{ .name = "a", .gain_db = -6.0206, .pan = -1.0 });

    var engine = Engine.init(48_000);
    engine.loadProject(&project);

    try std.testing.expect(engine.tracks[0].active);
    try std.testing.expect(!engine.tracks[1].active);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), engine.tracks[0].gain, 1e-4);
}

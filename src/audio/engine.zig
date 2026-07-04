const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("../dsp/device.zig");
const spectrum_mod = @import("../dsp/spectrum.zig");
const Spsc = @import("../core/ring_buffer.zig").Spsc;
const Limiter = @import("../dsp/limiter.zig").Limiter;
const Metronome = @import("../dsp/metronome.zig").Metronome;
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
    /// Beats per bar; the beat unit stays /4 (a beat is always a quarter).
    set_time_signature: u8,
    set_master_gain: f32,
    set_track_gain: struct { track: u16, gain: f32 },
    set_track_pan: struct { track: u16, pan: f32 },
    set_track_mute: struct { track: u16, muted: bool },
    set_track_solo: struct { track: u16, soloed: bool },
    note_on: struct { track: u16, note: u7, velocity: f32 },
    note_off: struct { track: u16, note: u7 },
    all_notes_off,
    cc: struct { track: u16, cc: u7, value: u7 },
    pitch_bend: struct { track: u16, bend: i16 },
    /// Nudge synth editor parameter `id` by `steps` on track `track`. Applied
    /// on the audio thread so editor edits don't race the block reader.
    set_track_param: struct { track: u16, id: u8, steps: i32 },
    set_spectrum_active: struct { source: SpectrumSource, track: u16 },
    /// A/B loop region (frames). See Transport.advance for the wrap.
    set_loop: struct { enabled: bool, start_frames: u64, end_frames: u64 },
    set_metronome: bool,
    /// Arms a one-bar count-in at the current position: the metronome
    /// clicks through a bar (regardless of `set_metronome`'s on/off state)
    /// while the transport stays stopped, then playback starts for real
    /// exactly on the downbeat. See Engine.firePreRoll.
    record,
};

const TrackState = struct {
    active: bool = false,
    gain: f32 = 1.0,
    pan: f32 = 0.0,
    muted: bool = false,
    soloed: bool = false,
    chain: [max_chain_devices]dsp.Device = undefined,
    chain_len: usize = 0,
};

pub const UiSnapshot = struct {
    playing: bool,
    /// True while a `.record` count-in is clicking through its bar — the
    /// transport itself is still stopped (`playing` is false) until it
    /// finishes. Lets the UI show a distinct "counting in" state and lets
    /// space cancel it instead of arming a second one.
    pre_rolling: bool,
    position_frames: u64,
    peak: [channels]f32,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    commands: Spsc(Command, 256) = .{},
    master_gain: f32 = 1.0,
    /// Always-on master-bus limiter: catches hot mixes before the WAV
    /// writer's ±1 clamp (and the DAC) turns them into hard-clip distortion.
    limiter: Limiter,
    /// User-configurable master bus FX (comp/eq/delay/reverb), applied to the
    /// summed mix before `master_gain` and the always-on limiter. Devices are
    /// fat pointers into `Session.master_fx` — see `setMasterChain`.
    master_chain: [4]dsp.Device = undefined,
    master_chain_len: usize = 0,
    metronome: Metronome,
    metronome_enabled: bool = false,
    /// Monotonic count of beats fired so far — same resync-on-discontinuity
    /// technique as DrumMachine.next_step_k, one level up (beats, not steps).
    metronome_next_beat: u64 = 0,
    /// Record count-in: frames left in the armed bar (0 = no pre-roll in
    /// flight). `pre_roll_elapsed` is a virtual clock — the transport itself
    /// hasn't started yet — driving the same beat-boundary click math
    /// `fireMetronome` uses, via its own `pre_roll_next_beat` counter. See
    /// `firePreRoll`.
    pre_roll_frames_remaining: u64 = 0,
    pre_roll_elapsed: u64 = 0,
    pre_roll_next_beat: u64 = 0,
    tracks: [max_tracks]TrackState,
    scratch: [types.max_block_frames * channels]Sample = undefined,
    peak: [channels]f32 = .{ 0.0, 0.0 },
    /// Single analyzer reused for whichever track is being viewed.
    track_spectrum: SpectrumAnalyzer,
    master_spectrum: SpectrumAnalyzer,
    active_spectrum_source: SpectrumSource = .none,
    active_spectrum_track: u16 = 0,
    shared: Shared = .{},
    /// Offline-bounce handshake. When the UI thread sets `bounce_active`, the
    /// realtime backend parks (outputs silence, sets `bounce_parked`) so the UI
    /// thread can drive process() into a file without racing the audio thread.
    bounce_active: std.atomic.Value(bool) = .init(false),
    bounce_parked: std.atomic.Value(bool) = .init(false),

    const Shared = struct {
        playing: std.atomic.Value(bool) = .init(false),
        pre_rolling: std.atomic.Value(bool) = .init(false),
        position_frames: std.atomic.Value(u64) = .init(0),
        peak_bits: [channels]std.atomic.Value(u32) = .{ .init(0), .init(0) },
    };

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Engine {
        var track_spec = try SpectrumAnalyzer.init(allocator, sample_rate);
        errdefer track_spec.deinit(allocator);
        var master_spec = try SpectrumAnalyzer.init(allocator, sample_rate);
        errdefer master_spec.deinit(allocator);
        var metronome = try Metronome.init(allocator, sample_rate);
        errdefer metronome.deinit();

        var self = Engine{
            .allocator = allocator,
            .transport = .{ .sample_rate = sample_rate },
            .limiter = Limiter.init(sample_rate),
            .metronome = metronome,
            .tracks = undefined,
            .track_spectrum = track_spec,
            .master_spectrum = master_spec,
        };
        for (&self.tracks) |*t| t.* = .{};
        return self;
    }

    pub fn deinit(self: *Engine) void {
        self.metronome.deinit();
        self.master_spectrum.deinit(self.allocator);
        self.track_spectrum.deinit(self.allocator);
    }

    pub fn loadProject(self: *Engine, project: *const Project) void {
        self.transport.tempo_bpm = project.tempo_bpm;
        self.transport.time_signature.beats_per_bar = project.beats_per_bar;
        const fpb = project.framesPerBar();
        self.transport.loop_enabled = project.loop_enabled and
            project.loop_end_bar > project.loop_start_bar;
        self.transport.loop_start_frames = @as(u64, project.loop_start_bar) * fpb;
        self.transport.loop_end_frames = @as(u64, project.loop_end_bar) * fpb;
        for (&self.tracks, 0..) |*state, i| {
            if (i < project.tracks.items.len) {
                const t = project.tracks.items[i];
                state.* = .{
                    .active = true,
                    .gain = types.dbToGain(t.gain_db),
                    .pan = t.pan,
                    .muted = t.muted,
                    .soloed = t.soloed,
                };
            } else {
                state.* = .{};
            }
        }
    }

    /// Shift engine slots [idx, total) up by one (to make room for a new
    /// track), then initialize `idx` as a new active track with no chain.
    /// `total` is the track count before the insert.
    /// Called from the UI/control thread — same class of race as setTrackChain.
    pub fn applyInsertTrack(self: *Engine, idx: u16, total: u16, gain: f32, pan: f32, muted: bool) void {
        var i: usize = @min(total, max_tracks - 1);
        while (i > idx) : (i -= 1) self.tracks[i] = self.tracks[i - 1];
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

    /// Swap two tracks' engine slots (state + chain) in place. Same race
    /// class as applyInsertTrack/applyDeleteTrack — called from the UI/control
    /// thread while the audio thread may be mid-block.
    pub fn swapTracks(self: *Engine, a: u16, b: u16) void {
        std.mem.swap(TrackState, &self.tracks[a], &self.tracks[b]);
    }

    /// Fire the metronome click at every beat boundary inside this block
    /// (same monotonic-counter, resync-on-discontinuity technique as
    /// DrumMachine.processBlock's step firing, one level up: beats instead
    /// of steps), then mix whatever's in flight into `out`.
    fn fireMetronome(self: *Engine, out: []Sample, frames: u32) void {
        if (self.transport.playing) {
            const pos_f = @as(f64, @floatFromInt(self.transport.position_frames));
            const fpb = self.transport.framesPerBeat();
            var beat_k = self.metronome_next_beat;

            const expected = @as(f64, @floatFromInt(beat_k)) * fpb;
            if (@abs(expected - pos_f) > fpb * 2.0) {
                beat_k = @intFromFloat(@ceil(pos_f / fpb));
            }

            while (true) {
                const fire_pos = @as(f64, @floatFromInt(beat_k)) * fpb;
                if (fire_pos >= pos_f + @as(f64, @floatFromInt(frames))) break;

                const fire_frame: u32 = if (fire_pos <= pos_f)
                    0
                else
                    @intCast(@min(
                        @as(u64, @intFromFloat(fire_pos - pos_f)),
                        @as(u64, frames - 1),
                    ));

                const bpb: u64 = self.transport.time_signature.beats_per_bar;
                self.metronome.trigger(beat_k % bpb == 0, fire_frame);
                beat_k += 1;
            }
            self.metronome_next_beat = beat_k;
        }

        self.metronome.render(out, channels, frames);
    }

    /// Clicks through the armed count-in bar and, once it's fully elapsed,
    /// starts the transport for real — recording begins exactly on the
    /// downbeat. Same beat-boundary-crossing loop as `fireMetronome`, just
    /// driven by `pre_roll_elapsed` (a virtual clock) instead of the real
    /// transport position, since the transport hasn't started yet. Clicks
    /// unconditionally — count-in isn't gated by `metronome_enabled`; it's
    /// the only timing cue you have while nothing else is playing.
    fn firePreRoll(self: *Engine, out: []Sample, frames: u32) void {
        const fpb = self.transport.framesPerBeat();
        const bpb: u64 = self.transport.time_signature.beats_per_bar;
        const pos_f: f64 = @floatFromInt(self.pre_roll_elapsed);
        var beat_k = self.pre_roll_next_beat;

        while (true) {
            const fire_pos = @as(f64, @floatFromInt(beat_k)) * fpb;
            if (fire_pos >= pos_f + @as(f64, @floatFromInt(frames))) break;

            const fire_frame: u32 = if (fire_pos <= pos_f)
                0
            else
                @intCast(@min(
                    @as(u64, @intFromFloat(fire_pos - pos_f)),
                    @as(u64, frames - 1),
                ));

            self.metronome.trigger(beat_k % bpb == 0, fire_frame);
            beat_k += 1;
        }
        self.pre_roll_next_beat = beat_k;
        self.metronome.render(out, channels, frames);

        if (frames >= self.pre_roll_frames_remaining) {
            self.pre_roll_frames_remaining = 0;
            self.pre_roll_next_beat = 0;
            self.transport.play();
        } else {
            self.pre_roll_frames_remaining -= frames;
            self.pre_roll_elapsed += frames;
        }
    }

    pub fn setTrackChain(self: *Engine, track: u16, devices: []const dsp.Device) void {
        const state = self.trackAt(track);
        state.chain_len = @min(devices.len, max_chain_devices);
        for (devices[0..state.chain_len], state.chain[0..state.chain_len]) |src, *dst| {
            dst.* = src;
        }
    }

    /// Same shape as `setTrackChain` but for the master bus — no instrument
    /// slot, just whichever FX stages `Session.master_fx` has active.
    pub fn setMasterChain(self: *Engine, devices: []const dsp.Device) void {
        self.master_chain_len = @min(devices.len, self.master_chain.len);
        for (devices[0..self.master_chain_len], self.master_chain[0..self.master_chain_len]) |src, *dst| {
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

        if (self.pre_roll_frames_remaining > 0) {
            // Count-in: click through the armed bar, no track audio, and
            // the transport itself stays stopped until it's done.
            self.firePreRoll(out, frames);
        } else {
            self.renderTracks(out, frames);
            if (self.metronome_enabled) self.fireMetronome(out, frames);
        }

        for (self.master_chain[0..self.master_chain_len]) |dev| dev.process(out);

        for (out) |*s| s.* *= self.master_gain;
        self.limiter.processBlock(out);

        // Peaks measured post-limiter, so the meters show what actually
        // reaches the output.
        self.peak = .{ 0.0, 0.0 };
        var i: usize = 0;
        while (i < out.len) : (i += channels) {
            inline for (0..channels) |ch| {
                const mag = @abs(out[i + ch]);
                if (mag > self.peak[ch]) self.peak[ch] = mag;
            }
        }

        self.master_spectrum.push(out);
        self.master_spectrum.analyze();

        self.transport.advance(frames);

        self.shared.playing.store(self.transport.playing, .monotonic);
        self.shared.pre_rolling.store(self.pre_roll_frames_remaining > 0, .monotonic);
        self.shared.position_frames.store(self.transport.position_frames, .monotonic);
        inline for (0..channels) |ch| {
            self.shared.peak_bits[ch].store(@bitCast(self.peak[ch]), .monotonic);
        }
    }

    pub fn uiSnapshot(self: *const Engine) UiSnapshot {
        var snap: UiSnapshot = .{
            .playing = self.shared.playing.load(.monotonic),
            .pre_rolling = self.shared.pre_rolling.load(.monotonic),
            .position_frames = self.shared.position_frames.load(.monotonic),
            .peak = undefined,
        };
        inline for (0..channels) |ch| {
            snap.peak[ch] = @bitCast(self.shared.peak_bits[ch].load(.monotonic));
        }
        return snap;
    }

    /// Returns the current spectrum snapshot for the given track, or null if
    /// that track is not the one being analyzed (so a just-switched view never
    /// shows the previous track's bins). Relies on the analyzer's `active`
    /// atomic — no race on internal fields.
    pub fn trackSpectrumSnapshot(self: *const Engine, track: u16) ?SpectrumSnapshot {
        if (self.active_spectrum_source != .track or track != self.active_spectrum_track)
            return null;
        return self.track_spectrum.snapshot();
    }

    pub fn masterSpectrumSnapshot(self: *const Engine) ?SpectrumSnapshot {
        return self.master_spectrum.snapshot();
    }

    fn drainCommands(self: *Engine) void {
        while (self.commands.pop()) |cmd| switch (cmd) {
            .play => self.transport.play(),
            .stop => {
                self.transport.stop();
                self.pre_roll_frames_remaining = 0; // cancel an in-flight count-in too
            },
            .seek_frames => |f| self.transport.seekFrames(f),
            .set_tempo => |bpm| self.transport.tempo_bpm = bpm,
            .set_time_signature => |bpb| self.transport.time_signature.beats_per_bar = bpb,
            .set_master_gain => |g| self.master_gain = g,
            .set_track_gain => |c| self.trackAt(c.track).gain = c.gain,
            .set_track_pan => |c| self.trackAt(c.track).pan = c.pan,
            .set_track_mute => |c| self.trackAt(c.track).muted = c.muted,
            .set_track_solo => |c| self.trackAt(c.track).soloed = c.soloed,
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
            .set_loop => |c| {
                self.transport.loop_enabled = c.enabled;
                self.transport.loop_start_frames = c.start_frames;
                self.transport.loop_end_frames = c.end_frames;
            },
            .set_metronome => |v| self.metronome_enabled = v,
            .record => {
                const bpb: f64 = @floatFromInt(self.transport.time_signature.beats_per_bar);
                self.pre_roll_frames_remaining = @intFromFloat(bpb * self.transport.framesPerBeat());
                self.pre_roll_elapsed = 0;
                self.pre_roll_next_beat = 0;
            },
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
        // When any track is soloed, only soloed tracks are audible.
        var any_solo = false;
        for (&self.tracks) |*t| {
            if (t.active and t.soloed) {
                any_solo = true;
                break;
            }
        }

        for (&self.tracks, 0..) |*track, ti| {
            if (!track.active or track.chain_len == 0) continue;

            const scratch = self.scratch[0 .. frames * channels];
            @memset(scratch, 0.0);
            for (track.chain[0..track.chain_len]) |dev| dev.process(scratch);

            if (track.muted or (any_solo and !track.soloed)) continue;

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
const Compressor = @import("../dsp/compressor.zig").Compressor;

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

test "metronome only clicks while enabled and playing" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var block: [512]Sample = undefined;

    _ = engine.send(.play);
    engine.process(&block); // enabled = false: silent
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);

    _ = engine.send(.{ .set_metronome = true });
    engine.process(&block); // first block always crosses beat 0
    try std.testing.expect(engine.peak[0] > 0.0);
}

test "metronome accents beat 1 of every bar" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    _ = engine.send(.{ .set_metronome = true });
    _ = engine.send(.play);

    var block: [64]Sample = undefined;
    engine.process(&block); // fires beat 0 (the downbeat) at frame 0
    try std.testing.expect(engine.metronome.is_accent);
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

test "master limiter keeps a hot mix under the ceiling" {
    var synth = PolySynth.init(48_000);
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.tracks[0] = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .set_master_gain = 16.0 }); // way past clipping
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });

    var block: [512]Sample = undefined;
    var loudest: f32 = 0.0;
    for (0..8) |_| {
        engine.process(&block);
        for (block) |s| loudest = @max(loudest, @abs(s));
    }
    try std.testing.expect(loudest > 0.5); // audible…
    try std.testing.expect(loudest <= engine.limiter.ceiling + 1e-4); // …not clipped
}

test "master FX chain processes the summed mix before gain/limiter" {
    var synth = PolySynth.init(48_000);
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.tracks[0] = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block); // let the synth's envelope settle in
    var loud: f32 = 0.0;
    for (block) |s| loud = @max(loud, @abs(s));

    // A master compressor riding near-instantly on a very low threshold and
    // steep ratio should crush the level well below the uncompressed pass.
    var comp = Compressor.init(48_000);
    comp.threshold_db = -60.0;
    comp.ratio = 20.0;
    comp.attack_ms = 0.1;
    comp.release_ms = 0.1;
    engine.setMasterChain(&.{comp.device()});

    var block2: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block2);
    var quiet: f32 = 0.0;
    for (block2) |s| quiet = @max(quiet, @abs(s));

    try std.testing.expect(loud > 0.05);
    try std.testing.expect(quiet < loud * 0.5);
}

test "solo silences other tracks but keeps the soloed one" {
    var lead = PolySynth.init(48_000);
    var pad  = PolySynth.init(48_000);
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.tracks[0] = .{ .active = true };
    engine.tracks[1] = .{ .active = true };
    engine.setTrackChain(0, &.{lead.device()});
    engine.setTrackChain(1, &.{pad.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.send(.{ .note_on = .{ .track = 1, .note = 64, .velocity = 1.0 } });
    _ = engine.send(.{ .set_track_solo = .{ .track = 1, .soloed = true } });

    var block: [512]Sample = undefined;
    engine.process(&block);
    // track 1 is soloed, so audio is present...
    try std.testing.expect(engine.peak[0] > 0.01);

    // ...but unsoloing track 1 (no track soloed) restores both — sanity that
    // the gate is the solo state, not a permanent mute.
    _ = engine.send(.{ .set_track_solo = .{ .track = 1, .soloed = false } });
    engine.process(&block);
    try std.testing.expect(engine.peak[0] > 0.01);
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

    // Insert before drum (at idx=1, 2 tracks present)
    engine.applyInsertTrack(1, 2, 1.0, 0.0, false);

    try std.testing.expect(engine.tracks[1].active);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), engine.tracks[1].gain, 1e-6);
    try std.testing.expectEqual(@as(usize, 0), engine.tracks[1].chain_len);
    // Drum shifted to slot 2
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), engine.tracks[2].gain, 1e-6);
}

test "applyInsertTrack in the middle shifts every later slot" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();

    engine.tracks[0] = .{ .active = true, .gain = 0.1 };
    engine.tracks[1] = .{ .active = true, .gain = 0.2 };
    engine.tracks[2] = .{ .active = true, .gain = 0.3 };

    engine.applyInsertTrack(1, 3, 1.0, 0.0, false);

    try std.testing.expectApproxEqAbs(@as(f32, 0.1), engine.tracks[0].gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), engine.tracks[1].gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), engine.tracks[2].gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), engine.tracks[3].gain, 1e-6);
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

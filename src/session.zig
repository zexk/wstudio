//! Default session factory and track lifecycle management.
//!
//! Session owns the canonical backend objects (project, engine, racks) and
//! exposes the operations that mutate them atomically. Frontends embed Session
//! and call its methods; TUI-only state (cursor, views, status) lives in the
//! frontend struct.

const std = @import("std");
const Project = @import("project.zig").Project;
const engine_mod = @import("audio/engine.zig");
const Engine = engine_mod.Engine;
const Rack = @import("rack.zig").Rack;
const PolySynth = @import("dsp/synth.zig").PolySynth;
const PatternPlayer = @import("dsp/pattern.zig").PatternPlayer;
const Compressor = @import("dsp/compressor.zig").Compressor;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const dsp = @import("dsp/device.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    project: Project,
    /// Heap-allocated so its address (and Transport's address) never moves.
    engine: *Engine,
    /// Each *Rack is heap-allocated; pointers are stable for DSP self-refs.
    racks: std.ArrayListUnmanaged(*Rack),
    /// Index of the drum-machine rack within `racks`.
    drum_track: u16,
    /// Racks removed from active use but not yet freed — the audio thread may
    /// still be mid-frame referencing them. Freed at deinit.
    retired_racks: std.ArrayListUnmanaged(*Rack),

    /// Build the default 4-track session: supersaw lead, FM e-piano, FM bass,
    /// drum machine. Wires PatternPlayers and engine chains before returning.
    pub fn initDefault(allocator: std.mem.Allocator) !Session {
        var project = Project.init(allocator);
        errdefer project.deinit();
        _ = try project.addTrack(.{ .name = "lead" });
        _ = try project.addTrack(.{ .name = "e-piano", .gain_db = -3.0 });
        _ = try project.addTrack(.{ .name = "bass", .gain_db = -3.0 });
        _ = try project.addTrack(.{ .name = "drums" });
        const sr = project.sample_rate;

        const engine = try allocator.create(Engine);
        errdefer allocator.destroy(engine);
        engine.* = try Engine.init(allocator, sr);
        errdefer engine.deinit();
        engine.loadProject(&project);

        var racks: std.ArrayListUnmanaged(*Rack) = .empty;
        errdefer {
            for (racks.items) |r| { r.deinit(allocator); allocator.destroy(r); }
            racks.deinit(allocator);
        }

        // ── Supersaw lead: 7-voice detuned saw + saw sub an octave down ──────
        const r0 = try allocator.create(Rack);
        r0.* = .{ .instrument = .{ .poly_synth = PolySynth.init(sr) }, .label = "supersaw+comp+dly+rev" };
        r0.instrument.poly_synth.waveform            = .saw;
        r0.instrument.poly_synth.unison              = 7;
        r0.instrument.poly_synth.unison_detune       = 35.0;
        r0.instrument.poly_synth.unison_spread       = 0.7;
        r0.instrument.poly_synth.osc_b_on            = true;
        r0.instrument.poly_synth.osc_b_waveform      = .saw;
        r0.instrument.poly_synth.osc_b_semi          = -12.0;
        r0.instrument.poly_synth.osc_b_detune_cents  = 5.0;
        r0.instrument.poly_synth.osc_b_level         = 0.55;
        r0.instrument.poly_synth.osc_b_unison        = 2;
        r0.instrument.poly_synth.osc_b_unison_detune = 10.0;
        r0.instrument.poly_synth.filter_cutoff       = 9_000.0;
        r0.instrument.poly_synth.attack_s            = 0.012;
        r0.instrument.poly_synth.release_s           = 0.4;
        r0.fx.comp   = Compressor.init(sr);
        r0.fx.delay  = try StereoDelay.init(allocator, sr, 2.0);
        r0.fx.delay.?.setTime(0.375);
        r0.fx.reverb = try Reverb.init(allocator, sr);
        try racks.append(allocator, r0);
        r0.pattern_player = PatternPlayer.init(&r0.instrument.poly_synth, &engine.transport);

        // ── FM electric piano: sine carrier + sine operator (β=2.5) ─────────
        // Fast decay / zero sustain = tine-style. Small noise = hammer click.
        const r1 = try allocator.create(Rack);
        r1.* = .{ .instrument = .{ .poly_synth = PolySynth.init(sr) }, .label = "fm e-piano" };
        r1.instrument.poly_synth.waveform        = .sine;
        r1.instrument.poly_synth.osc_b_on        = true;
        r1.instrument.poly_synth.osc_b_waveform  = .sine;
        r1.instrument.poly_synth.osc_b_semi      = 0.0;
        r1.instrument.poly_synth.osc_b_level     = 0.0;
        r1.instrument.poly_synth.mod_mode        = .fm_b_to_a;
        r1.instrument.poly_synth.mod_amount      = 2.5;
        r1.instrument.poly_synth.attack_s        = 0.003;
        r1.instrument.poly_synth.decay_s         = 1.8;
        r1.instrument.poly_synth.sustain         = 0.0;
        r1.instrument.poly_synth.release_s       = 0.3;
        r1.instrument.poly_synth.filter_cutoff   = 8_000.0;
        r1.instrument.poly_synth.fenv_amount     = 1.2;
        r1.instrument.poly_synth.fenv_attack_s   = 0.005;
        r1.instrument.poly_synth.fenv_decay_s    = 0.35;
        r1.instrument.poly_synth.fenv_sustain    = 0.0;
        r1.instrument.poly_synth.noise_level     = 0.06;
        r1.instrument.poly_synth.noise_color     = 1.0;
        r1.instrument.poly_synth.gain            = 0.32;
        r1.fx.reverb = try Reverb.init(allocator, sr);
        r1.fx.reverb.?.mix = 0.22;
        try racks.append(allocator, r1);
        r1.pattern_player = PatternPlayer.init(&r1.instrument.poly_synth, &engine.transport);

        // ── FM bass: saw carrier + sine operator (β=3.5) + sine sub ─────────
        const r2 = try allocator.create(Rack);
        r2.* = .{ .instrument = .{ .poly_synth = PolySynth.init(sr) }, .label = "fm bass" };
        r2.instrument.poly_synth.waveform        = .saw;
        r2.instrument.poly_synth.voice_mode      = .mono;
        r2.instrument.poly_synth.glide_s         = 0.05;
        r2.instrument.poly_synth.osc_b_on        = true;
        r2.instrument.poly_synth.osc_b_waveform  = .sine;
        r2.instrument.poly_synth.osc_b_semi      = 0.0;
        r2.instrument.poly_synth.osc_b_level     = 0.0;
        r2.instrument.poly_synth.mod_mode        = .fm_b_to_a;
        r2.instrument.poly_synth.mod_amount      = 3.5;
        r2.instrument.poly_synth.sub_level       = 0.45;
        r2.instrument.poly_synth.sub_shape       = .sine;
        r2.instrument.poly_synth.attack_s        = 0.006;
        r2.instrument.poly_synth.decay_s         = 0.28;
        r2.instrument.poly_synth.sustain         = 0.6;
        r2.instrument.poly_synth.release_s       = 0.15;
        r2.instrument.poly_synth.filter_cutoff   = 1_100.0;
        r2.instrument.poly_synth.filter_res      = 0.2;
        r2.instrument.poly_synth.fenv_amount     = 2.2;
        r2.instrument.poly_synth.fenv_attack_s   = 0.004;
        r2.instrument.poly_synth.fenv_decay_s    = 0.22;
        r2.instrument.poly_synth.fenv_sustain    = 0.0;
        r2.instrument.poly_synth.gain            = 0.40;
        r2.fx.comp = Compressor.init(sr);
        try racks.append(allocator, r2);
        r2.pattern_player = PatternPlayer.init(&r2.instrument.poly_synth, &engine.transport);

        // ── Drum machine ─────────────────────────────────────────────────────
        const drum_rack = try allocator.create(Rack);
        drum_rack.* = .{
            .instrument = .{ .drum_machine = try DrumMachine.init(allocator, sr, &engine.transport) },
            .label = "drums",
        };
        try racks.append(allocator, drum_rack);
        const drum_track: u16 = @intCast(racks.items.len - 1);

        var self: Session = .{
            .allocator = allocator,
            .project = project,
            .engine = engine,
            .racks = racks,
            .drum_track = drum_track,
            .retired_racks = .empty,
        };
        for (self.racks.items, 0..) |rack, i| {
            var buf: [6]dsp.Device = undefined;
            self.engine.setTrackChain(@intCast(i), rack.chain(&buf));
        }
        return self;
    }

    /// Insert a new synth track immediately before the drum rack.
    /// Returns the inserted track index so the caller can update cursor state.
    pub fn addTrack(self: *Session, name: []const u8) error{ TrackLimitReached, OutOfMemory }!u16 {
        if (self.project.tracks.items.len >= engine_mod.max_tracks)
            return error.TrackLimitReached;

        const sr = self.project.sample_rate;
        const idx = self.drum_track;

        const rack = try self.allocator.create(Rack);
        errdefer self.allocator.destroy(rack);
        rack.* = .{ .instrument = .{ .poly_synth = PolySynth.init(sr) }, .label = "synth" };
        rack.pattern_player = PatternPlayer.init(&rack.instrument.poly_synth, &self.engine.transport);

        try self.racks.insert(self.allocator, idx, rack);
        errdefer _ = self.racks.orderedRemove(idx);

        try self.project.insertTrack(idx, .{ .name = name });

        self.engine.applyInsertTrack(idx, 1.0, 0.0, false);
        var buf: [6]dsp.Device = undefined;
        self.engine.setTrackChain(idx, rack.chain(&buf));

        self.drum_track += 1;
        return idx;
    }

    pub const DeleteTrackError = error{ CannotDeleteDrumTrack, CannotDeleteLastTrack };

    /// Remove the track at `track_idx`. The displaced rack is moved to
    /// `retired_racks` rather than freed immediately — the audio thread may
    /// still be referencing it. Racks are freed at `deinit`.
    pub fn deleteTrack(self: *Session, track_idx: usize) DeleteTrackError!void {
        if (track_idx == self.drum_track) return error.CannotDeleteDrumTrack;
        if (self.project.tracks.items.len <= 1) return error.CannotDeleteLastTrack;

        _ = self.engine.send(.all_notes_off);

        const total: u16 = @intCast(self.project.tracks.items.len);
        self.engine.applyDeleteTrack(@intCast(track_idx), total);

        const rack = self.racks.orderedRemove(track_idx);
        self.retired_racks.append(self.allocator, rack) catch {};

        self.project.removeTrack(track_idx);

        if (track_idx < self.drum_track) self.drum_track -= 1;
    }

    pub fn deinit(self: *Session) void {
        for (self.racks.items) |r| { r.deinit(self.allocator); self.allocator.destroy(r); }
        self.racks.deinit(self.allocator);
        for (self.retired_racks.items) |r| { r.deinit(self.allocator); self.allocator.destroy(r); }
        self.retired_racks.deinit(self.allocator);
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        self.project.deinit();
    }
};

test "initDefault builds 4 tracks and 4 racks" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 4), s.project.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 4), s.racks.items.len);
    try std.testing.expectEqual(@as(u16, 3), s.drum_track);
}

test "engine chains are live after initDefault" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    _ = s.engine.send(.play);
    var block: [128]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block);
}

test "addTrack inserts before drum, updates drum_track" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    const idx = try s.addTrack("strings");
    try std.testing.expectEqual(@as(u16, 3), idx);
    try std.testing.expectEqual(@as(usize, 5), s.project.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 5), s.racks.items.len);
    try std.testing.expectEqual(@as(u16, 4), s.drum_track);
}

test "deleteTrack removes project+rack, updates drum_track" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.deleteTrack(1); // remove e-piano
    try std.testing.expectEqual(@as(usize, 3), s.project.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 3), s.racks.items.len);
    try std.testing.expectEqual(@as(u16, 2), s.drum_track);
    try std.testing.expectEqual(@as(usize, 1), s.retired_racks.items.len);
}

test "deleteTrack rejects drum track" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectError(error.CannotDeleteDrumTrack, s.deleteTrack(s.drum_track));
}

test "deleteTrack rejects last track (custom session)" {
    // Build a minimal 1-track session without a drum to exercise the guard.
    var s: Session = .{
        .allocator = std.testing.allocator,
        .project = Project.init(std.testing.allocator),
        .engine = try std.testing.allocator.create(Engine),
        .racks = .empty,
        .drum_track = 99, // no drum in this toy session
        .retired_racks = .empty,
    };
    s.engine.* = try Engine.init(std.testing.allocator, 48_000);
    defer s.deinit();
    _ = try s.project.addTrack(.{ .name = "solo" });
    try std.testing.expectError(error.CannotDeleteLastTrack, s.deleteTrack(0));
}

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
const rack_mod = @import("rack.zig");
const Rack = rack_mod.Rack;
const InstrumentKind = rack_mod.InstrumentKind;
const PolySynth = @import("dsp/synth.zig").PolySynth;
const Sampler = @import("dsp/sampler.zig").Sampler;
const pattern_mod = @import("dsp/pattern.zig");
const PatternPlayer = pattern_mod.PatternPlayer;
const Note = pattern_mod.Note;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const dsp = @import("dsp/device.zig");
const arr_mod = @import("arrangement.zig");
const Arrangement = arr_mod.Arrangement;
const Clip = arr_mod.Clip;

pub const Session = struct {
    allocator: std.mem.Allocator,
    project: Project,
    /// Heap-allocated so its address (and Transport's address) never moves.
    engine: *Engine,
    /// Each *Rack is heap-allocated; pointers are stable for DSP self-refs.
    racks: std.ArrayListUnmanaged(*Rack),
    /// Racks removed from active use but not yet freed — the audio thread may
    /// still be mid-frame referencing them. Freed at deinit.
    retired_racks: std.ArrayListUnmanaged(*Rack),
    /// Song-mode clip timeline, one lane per track (parallel to `racks`).
    arrangement: Arrangement,
    /// When true, playback follows the arrangement timeline; when false, each
    /// track loops its single live pattern (the original behavior). Honored by
    /// the engine in song-mode playback.
    song_mode: bool = false,

    /// Build the default session: a single blank track. Instruments are added
    /// per-track via `setInstrument`; the shipped `demo.wsj` is the curated
    /// multi-track starting point (load it with `wstudio demo.wsj`).
    pub fn initDefault(allocator: std.mem.Allocator) !Session {
        var project = Project.init(allocator);
        errdefer project.deinit();
        _ = try project.addTrack(.{ .name = "track 1" });
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

        const r0 = try allocator.create(Rack);
        r0.* = .{ .instrument = .empty, .label = "empty" };
        try racks.append(allocator, r0);

        var arrangement: Arrangement = .{};
        errdefer arrangement.deinit(allocator);
        try arrangement.addLane(allocator); // one lane for the blank track

        var self: Session = .{
            .allocator = allocator,
            .project = project,
            .engine = engine,
            .racks = racks,
            .retired_racks = .empty,
            .arrangement = arrangement,
        };
        for (self.racks.items, 0..) |rack, i| {
            var buf: [6]dsp.Device = undefined;
            self.engine.setTrackChain(@intCast(i), rack.chain(&buf));
        }
        return self;
    }

    /// Append a new blank track at the end. The user picks an instrument for it
    /// via `setInstrument`. Returns the new track index.
    pub fn addTrack(self: *Session, name: []const u8) error{ TrackLimitReached, OutOfMemory }!u16 {
        if (self.project.tracks.items.len >= engine_mod.max_tracks)
            return error.TrackLimitReached;

        const idx: u16 = @intCast(self.project.tracks.items.len);

        const rack = try self.allocator.create(Rack);
        errdefer self.allocator.destroy(rack);
        rack.* = .{ .instrument = .empty, .label = "empty" };

        try self.racks.append(self.allocator, rack);
        errdefer _ = self.racks.pop();

        try self.arrangement.addLane(self.allocator);
        errdefer self.arrangement.removeLane(self.allocator, self.arrangement.lanes.items.len - 1);

        _ = try self.project.addTrack(.{ .name = name });

        self.engine.applyInsertTrack(idx, 1.0, 0.0, false);
        var buf: [6]dsp.Device = undefined;
        self.engine.setTrackChain(idx, rack.chain(&buf));

        return idx;
    }

    /// Replace the instrument on `track_idx` with a fresh instance of `kind`,
    /// tearing down whatever was there. Melodic kinds (synth, sampler) get a
    /// PatternPlayer so they are piano-roll sequenceable. Rebuilds the engine
    /// chain. The rack is heap-allocated, so the new instrument's device and
    /// any self-referential PatternPlayer pointer stay valid.
    pub fn setInstrument(self: *Session, track_idx: usize, kind: InstrumentKind) !void {
        if (track_idx >= self.racks.items.len) return;
        const rack = self.racks.items[track_idx];
        const sr = self.project.sample_rate;

        _ = self.engine.send(.all_notes_off);

        // Clips captured the old instrument's pattern; drop them so song mode
        // never plays a melodic clip into a drum track or vice versa.
        if (self.arrangement.lane(track_idx)) |lane| lane.clear(self.allocator);

        rack.instrument.deinit();
        rack.pattern_player = null;

        switch (kind) {
            .empty => {
                rack.instrument = .empty;
                rack.label = "empty";
            },
            .poly_synth => {
                rack.instrument = .{ .poly_synth = PolySynth.init(sr) };
                rack.label = "synth";
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &self.engine.transport);
            },
            .sampler => {
                rack.instrument = .{ .sampler = try Sampler.init(self.allocator, sr) };
                rack.label = "sampler";
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &self.engine.transport);
            },
            .drum_machine => {
                rack.instrument = .{ .drum_machine = try DrumMachine.init(self.allocator, sr, &self.engine.transport) };
                rack.label = "drums";
            },
        }

        var buf: [6]dsp.Device = undefined;
        self.engine.setTrackChain(@intCast(track_idx), rack.chain(&buf));
    }

    pub const DeleteTrackError = error{CannotDeleteLastTrack};

    /// Remove the track at `track_idx`. The displaced rack is moved to
    /// `retired_racks` rather than freed immediately — the audio thread may
    /// still be referencing it. Racks are freed at `deinit`.
    pub fn deleteTrack(self: *Session, track_idx: usize) DeleteTrackError!void {
        if (self.project.tracks.items.len <= 1) return error.CannotDeleteLastTrack;

        _ = self.engine.send(.all_notes_off);

        const total: u16 = @intCast(self.project.tracks.items.len);
        self.engine.applyDeleteTrack(@intCast(track_idx), total);

        const rack = self.racks.orderedRemove(track_idx);
        self.retired_racks.append(self.allocator, rack) catch {};

        self.arrangement.removeLane(self.allocator, track_idx);
        self.project.removeTrack(track_idx);
    }

    /// Capture `track_idx`'s current live pattern as a clip at `start_bar`.
    /// Melodic tracks copy their piano-roll notes; drum tracks copy the step
    /// bitmask. The clip's bar length is derived from the pattern length. No-op
    /// for empty tracks. Replaces any clips it overlaps (see `Lane.place`).
    pub fn stampClip(self: *Session, track_idx: usize, start_bar: u32) !void {
        if (track_idx >= self.racks.items.len) return;
        const lane = self.arrangement.lane(track_idx) orelse return;
        const rack = self.racks.items[track_idx];
        const bpb: f64 = @floatFromInt(self.engine.transport.time_signature.beats_per_bar);

        switch (rack.instrument) {
            .empty => return,
            .drum_machine => |*dm| {
                var pat: [DrumMachine.max_pads]u32 = undefined;
                for (&pat, 0..) |*p, i| p.* = dm.pattern[i].load(.acquire);
                const len_beats = @as(f64, @floatFromInt(dm.step_count)) / 4.0;
                try lane.place(self.allocator, Clip.initDrum(
                    start_bar, barsFor(len_beats, bpb), pat, dm.step_count,
                ));
            },
            else => {
                const pp = if (rack.pattern_player) |*p| p else return;
                // Snapshot the notes under the player's lock (UI thread).
                while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
                const count = pp.note_count;
                const len_beats = pp.length_beats;
                var tmp: [pattern_mod.max_notes]Note = undefined;
                for (pp.notes[0..count], tmp[0..count]) |n, *t| t.* = n;
                pp.notes_lock.unlock();
                try lane.place(self.allocator, try Clip.initMelodic(
                    self.allocator, start_bar, barsFor(len_beats, bpb), tmp[0..count], len_beats,
                ));
            },
        }
    }

    /// Whole bars needed to hold `len_beats`, at least one.
    fn barsFor(len_beats: f64, beats_per_bar: f64) u32 {
        if (len_beats <= 0 or beats_per_bar <= 0) return 1;
        return @max(1, @as(u32, @intFromFloat(@ceil(len_beats / beats_per_bar))));
    }

    pub fn deinit(self: *Session) void {
        self.arrangement.deinit(self.allocator);
        for (self.racks.items) |r| { r.deinit(self.allocator); self.allocator.destroy(r); }
        self.racks.deinit(self.allocator);
        for (self.retired_racks.items) |r| { r.deinit(self.allocator); self.allocator.destroy(r); }
        self.retired_racks.deinit(self.allocator);
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        self.project.deinit();
    }
};

test "initDefault builds one blank track" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 1), s.project.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.racks.items.len);
    try std.testing.expectEqual(rack_mod.InstrumentKind.empty, std.meta.activeTag(s.racks.items[0].instrument));
}

test "engine chains are live after initDefault" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    _ = s.engine.send(.play);
    var block: [128]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block);
}

test "addTrack appends a blank track at the end" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    const idx = try s.addTrack("strings");
    try std.testing.expectEqual(@as(u16, 1), idx);
    try std.testing.expectEqual(@as(usize, 2), s.project.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 2), s.racks.items.len);
    try std.testing.expectEqual(rack_mod.InstrumentKind.empty, std.meta.activeTag(s.racks.items[1].instrument));
}

test "setInstrument swaps instrument and wires pattern player" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();

    try s.setInstrument(0, .poly_synth);
    try std.testing.expectEqual(rack_mod.InstrumentKind.poly_synth, std.meta.activeTag(s.racks.items[0].instrument));
    try std.testing.expect(s.racks.items[0].pattern_player != null);

    try s.setInstrument(0, .sampler);
    try std.testing.expectEqual(rack_mod.InstrumentKind.sampler, std.meta.activeTag(s.racks.items[0].instrument));
    try std.testing.expect(s.racks.items[0].pattern_player != null);

    try s.setInstrument(0, .drum_machine);
    try std.testing.expectEqual(rack_mod.InstrumentKind.drum_machine, std.meta.activeTag(s.racks.items[0].instrument));
    try std.testing.expect(s.racks.items[0].pattern_player == null);

    // Chains stay live and renderable after each swap.
    _ = s.engine.send(.play);
    var block: [128]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block);
}

test "deleteTrack removes project+rack and retires it" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    _ = try s.addTrack("two");
    try s.deleteTrack(0);
    try std.testing.expectEqual(@as(usize, 1), s.project.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.racks.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.retired_racks.items.len);
}

test "deleteTrack rejects last track" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectError(error.CannotDeleteLastTrack, s.deleteTrack(0));
}

test "stampClip captures the live melodic pattern as a clip" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .poly_synth);
    const pp = &s.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.length_beats = 8.0; // two bars in 4/4

    try s.stampClip(0, 2);
    const lane = s.arrangement.lane(0).?;
    try std.testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    const clip = lane.clips.items[0];
    try std.testing.expectEqual(@as(u32, 2), clip.start_bar);
    try std.testing.expectEqual(@as(u32, 2), clip.length_bars);
    try std.testing.expectEqual(@as(usize, 1), clip.content.melodic.notes.len);
}

test "stampClip on empty track is a no-op" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.stampClip(0, 0);
    try std.testing.expectEqual(@as(usize, 0), s.arrangement.lane(0).?.clips.items.len);
}

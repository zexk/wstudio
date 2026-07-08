//! Default session factory and track lifecycle management.
//!
//! Session owns the canonical backend objects (project, engine, racks) and
//! exposes the operations that mutate them atomically. Frontends embed Session
//! and call its methods; TUI-only state (cursor, views, status) lives in the
//! frontend struct.

const std = @import("std");
const types = @import("core/types.zig");
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
const automation_mod = @import("dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;

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
    /// Click track on/off. Control-side source of truth, mirrored to the
    /// engine via `set_metronome` — same pattern as `loop_enabled`/`song_mode`.
    /// A monitoring aid, not song content, so it isn't persisted.
    metronome_enabled: bool = false,
    /// Master bus FX chain, applied to the summed mix before the master gain
    /// and always-on limiter — same user-built `Fx` chain as a track's rack,
    /// so any unit plugs into either the same way. Persisted
    /// (`Snapshot.master_fx_chain`, see persist.zig). Push param/membership
    /// changes to the audio thread with `syncMasterChain`.
    master_fx: rack_mod.Fx = .{},

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
        try engine.initInPlace(allocator, sr);
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
            var buf: [Rack.chain_cap]dsp.Device = undefined;
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

        self.engine.applyInsertTrack(idx, idx, 1.0, 0.0, false);
        var buf: [Rack.chain_cap]dsp.Device = undefined;
        self.engine.setTrackChain(idx, rack.chain(&buf));

        return idx;
    }

    /// Replace the instrument on `track_idx` with a fresh instance of `kind`.
    /// The replacement is built in a brand-new heap rack; the old rack is moved
    /// to `retired_racks` rather than torn down in place — the audio thread may
    /// still be mid-block inside its devices (same policy as deleteTrack).
    /// Melodic kinds (synth, sampler) get a PatternPlayer so they are
    /// piano-roll sequenceable. Rebuilds the engine chain. Any allocation
    /// failure leaves the session untouched.
    pub fn setInstrument(self: *Session, track_idx: usize, kind: InstrumentKind) !void {
        if (track_idx >= self.racks.items.len) return;
        const sr = self.project.sample_rate;

        const rack = try self.allocator.create(Rack);
        errdefer self.allocator.destroy(rack);
        rack.* = .{ .instrument = .empty, .label = "empty" };
        errdefer rack.instrument.deinit();

        switch (kind) {
            .empty => {},
            .poly_synth => {
                rack.instrument = .{ .poly_synth = PolySynth.init(sr) };
                rack.label = "synth";
            },
            .sampler => {
                rack.instrument = .{ .sampler = try Sampler.init(self.allocator, sr) };
                rack.label = "sampler";
            },
            .drum_machine => {
                rack.instrument = .{ .drum_machine = try DrumMachine.init(self.allocator, sr, &self.engine.transport) };
                rack.label = "drums";
            },
        }
        // Set AFTER the instrument lands in the heap rack — the player holds a
        // pointer into it.
        switch (kind) {
            .poly_synth, .sampler => rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &self.engine.transport),
            else => {},
        }

        try self.retired_racks.append(self.allocator, self.racks.items[track_idx]);

        _ = self.engine.send(.all_notes_off);

        // Clips captured the old instrument's pattern; drop them so song mode
        // never plays a melodic clip into a drum track or vice versa.
        if (self.arrangement.lane(track_idx)) |lane| lane.clear(self.allocator);

        self.racks.items[track_idx] = rack;

        var buf: [Rack.chain_cap]dsp.Device = undefined;
        self.engine.setTrackChain(@intCast(track_idx), rack.chain(&buf));

        // Keep the new device coherent with the current playback mode: its
        // lane is empty now, so in song mode it must follow the (empty) song
        // buffer rather than looping its live pattern over the arrangement.
        if (self.song_mode) {
            self.rebuildSongData();
            if (rack.pattern_player) |*pp| pp.song_mode = true;
            switch (rack.instrument) {
                .drum_machine => |*dm| dm.song_mode = true,
                else => {},
            }
        }
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

    /// Deep-copy `track_idx` — instrument, params, FX, pattern/pad audio, and
    /// its arrangement clips — into a new track appended at the end. Appending
    /// (rather than inserting right after the source) never reindexes an
    /// existing track, so undo history and editor-target indices stay valid,
    /// same rule as `addTrack`. Returns the new track's index.
    pub fn duplicateTrack(self: *Session, track_idx: usize) !u16 {
        if (track_idx >= self.racks.items.len) return error.TrackLimitReached;
        if (self.project.tracks.items.len >= engine_mod.max_tracks)
            return error.TrackLimitReached;

        const src = self.project.tracks.items[track_idx];
        var name_buf: [40]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s} copy", .{src.name}) catch src.name;

        const new_rack = try self.racks.items[track_idx].dupe(
            self.allocator, self.project.sample_rate, &self.engine.transport,
        );
        errdefer { new_rack.deinit(self.allocator); self.allocator.destroy(new_rack); }

        const idx: u16 = @intCast(self.project.tracks.items.len);

        try self.racks.append(self.allocator, new_rack);
        errdefer _ = self.racks.pop();

        try self.arrangement.addLane(self.allocator);
        errdefer self.arrangement.removeLane(self.allocator, self.arrangement.lanes.items.len - 1);
        if (self.arrangement.lane(track_idx)) |src_lane| {
            const dst_lane = self.arrangement.lane(idx).?;
            for (src_lane.clips.items) |c| try dst_lane.clips.append(self.allocator, try c.dupe(self.allocator));
        }

        _ = try self.project.addTrack(.{
            .name = name, .kind = src.kind, .gain_db = src.gain_db,
            .pan = src.pan, .muted = src.muted, .soloed = src.soloed,
        });

        self.engine.applyInsertTrack(idx, idx, types.dbToGain(src.gain_db), src.pan, src.muted);
        var buf: [Rack.chain_cap]dsp.Device = undefined;
        self.engine.setTrackChain(idx, new_rack.chain(&buf));
        if (src.soloed) _ = self.engine.send(.{ .set_track_solo = .{ .track = idx, .soloed = true } });

        if (self.song_mode) self.rebuildSongData();

        return idx;
    }

    /// Swap two tracks' positions across every parallel structure (project,
    /// racks, arrangement lanes, engine state+chain). No allocation, cannot
    /// fail. A rack's own song-mode data travels with it, so no rebuild is
    /// needed. Callers should reset any per-instrument editor-target/undo
    /// state tied to an absolute track index — a swap silently changes what
    /// index `a`/`b` mean, same rule as `deleteTrack`.
    pub fn swapTracks(self: *Session, a: usize, b: usize) void {
        if (a == b or a >= self.racks.items.len or b >= self.racks.items.len) return;
        self.project.swapTracks(a, b);
        std.mem.swap(*Rack, &self.racks.items[a], &self.racks.items[b]);
        self.arrangement.swapLanes(a, b);
        self.engine.swapTracks(@intCast(a), @intCast(b));
    }

    /// Capture `track_idx`'s current live pattern as a clip at `start_bar`.
    /// Melodic tracks copy their piano-roll notes; drum tracks copy the step
    /// bitmask. The clip's bar length is derived from the pattern length. No-op
    /// for empty tracks. Replaces any clips it overlaps (see `Lane.place`).
    pub fn stampClip(self: *Session, track_idx: usize, start_bar: u32) !void {
        if (track_idx >= self.racks.items.len) return;
        const lane = self.arrangement.lane(track_idx) orelse return;
        const rack = self.racks.items[track_idx];
        const bpb: f64 = @floatFromInt(self.project.beats_per_bar);

        switch (rack.instrument) {
            .empty => return,
            .drum_machine => |*dm| {
                var drum: Clip.Drum = .{
                    .pattern = undefined,
                    .step_count = dm.step_count,
                    .variant = dm.variant,
                };
                for (&drum.pattern, &drum.vel_lo, &drum.vel_hi, 0..) |*p, *lo, *hi, i| {
                    p.*  = dm.pattern[i].load(.acquire);
                    lo.* = dm.vel_lo[i].load(.acquire);
                    hi.* = dm.vel_hi[i].load(.acquire);
                }
                const len_beats = @as(f64, @floatFromInt(dm.step_count)) / 4.0;
                try lane.place(self.allocator, Clip.initDrum(
                    start_bar, barsFor(len_beats, bpb), drum,
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

    /// Toggle song mode. Rebuilds each device's song buffer first (so the audio
    /// thread never sees the flag flip ahead of valid data), flips the per-device
    /// flags, and silences anything left hanging from the previous mode.
    pub fn setSongMode(self: *Session, on: bool) void {
        self.song_mode = on;
        if (on) {
            self.rebuildSongData();
        } else {
            // Automation is meaningless off the arrangement timeline — leave
            // it armed and a stray transport position from live jamming
            // could yank a track's gain/pan. Clearing falls back to the
            // manual value, same as before automation existed.
            for (0..self.racks.items.len) |i| {
                self.engine.setTrackAutomation(@intCast(i), .gain, &.{});
                self.engine.setTrackAutomation(@intCast(i), .pan, &.{});
            }
        }
        _ = self.engine.send(.all_notes_off);
        for (self.racks.items) |rack| {
            if (rack.pattern_player) |*pp| pp.song_mode = on;
            switch (rack.instrument) {
                .drum_machine => |*dm| dm.song_mode = on,
                else => {},
            }
        }
    }

    /// Toggle the click track.
    pub fn setMetronome(self: *Session, on: bool) void {
        self.metronome_enabled = on;
        _ = self.engine.send(.{ .set_metronome = on });
    }

    /// Push the master bus's active FX units (in chain order) to the audio
    /// thread. Call after inserting, removing, reordering, or bypassing a
    /// master FX unit — same idea as `setTrackChain`, but the master bus has
    /// no instrument slot, just `master_fx`.
    pub fn syncMasterChain(self: *Session) void {
        var buf: [rack_mod.Fx.max_units]dsp.Device = undefined;
        self.engine.setMasterChain(self.master_fx.chain(&buf));
    }

    /// Push the project's A/B loop region (bars) to the audio thread as
    /// frames. Call after editing the loop or anything its bar math depends
    /// on (tempo, time signature).
    pub fn syncLoop(self: *Session) void {
        const fpb = self.project.framesPerBar();
        _ = self.engine.send(.{ .set_loop = .{
            .enabled = self.project.loop_enabled and
                self.project.loop_end_bar > self.project.loop_start_bar,
            .start_frames = @as(u64, self.project.loop_start_bar) * fpb,
            .end_frames = @as(u64, self.project.loop_end_bar) * fpb,
        } });
    }

    /// Flatten the arrangement's clips into each track's device song buffer.
    /// Melodic lanes become one absolute-beat note timeline; drum lanes become a
    /// list of step-placed clips. The whole arrangement loops as one unit, so all
    /// devices share the same total length. Call after any clip edit while in
    /// song mode. Control thread only.
    pub fn rebuildSongData(self: *Session) void {
        const bpb_u = self.project.beats_per_bar;
        const bpb: f64 = @floatFromInt(bpb_u);
        const total_bars = self.arrangement.lengthBars();
        const song_len_beats = @as(f64, @floatFromInt(total_bars)) * bpb;
        const steps_per_bar: u32 = @as(u32, bpb_u) * 4;
        const song_len_steps = total_bars * steps_per_bar;

        for (self.racks.items, 0..) |rack, i| {
            const lane = self.arrangement.lane(i) orelse continue;
            switch (rack.instrument) {
                .drum_machine => |*dm| {
                    var clips: [DrumMachine.max_song_clips]DrumMachine.SongClip = undefined;
                    var n: usize = 0;
                    for (lane.clips.items) |c| {
                        if (n >= clips.len) break;
                        const drum = switch (c.content) { .drum => |d| d, .melodic => continue };
                        clips[n] = .{
                            .start_step = c.start_bar * steps_per_bar,
                            .span_steps = c.length_bars * steps_per_bar,
                            .step_count = drum.step_count,
                            .pattern = drum.pattern,
                            .vel_lo = drum.vel_lo,
                            .vel_hi = drum.vel_hi,
                        };
                        n += 1;
                    }
                    dm.setSongClips(clips[0..n], song_len_steps);
                },
                .poly_synth, .sampler => {
                    const pp = if (rack.pattern_player) |*p| p else continue;
                    var notes: [pattern_mod.max_notes]Note = undefined;
                    var n: usize = 0;
                    for (lane.clips.items) |c| {
                        const mel = switch (c.content) { .melodic => |m| m, .drum => continue };
                        const clip_start_beat = @as(f64, @floatFromInt(c.start_bar)) * bpb;
                        // The captured pattern repeats to fill the clip's own
                        // bar span (length_bars, edge-resizable in the
                        // arrangement editor) — the same repeat-to-fill-span
                        // rule DrumMachine.fireSongStep already applies to
                        // drum clips, just expressed in beats instead of a
                        // step modulo since melodic content has no fixed grid.
                        const clip_span_beats = @as(f64, @floatFromInt(c.length_bars)) * bpb;
                        if (mel.length_beats <= 0) continue;
                        var rep_start: f64 = 0;
                        while (rep_start < clip_span_beats) : (rep_start += mel.length_beats) {
                            for (mel.notes) |note| {
                                if (n >= notes.len) break;
                                if (note.start_beat >= mel.length_beats) continue;
                                const abs_start = rep_start + note.start_beat;
                                if (abs_start >= clip_span_beats) continue;
                                notes[n] = .{
                                    .pitch = note.pitch,
                                    .start_beat = clip_start_beat + abs_start,
                                    .duration_beat = note.duration_beat,
                                    .velocity = note.velocity,
                                };
                                n += 1;
                            }
                            if (n >= notes.len) break;
                        }
                    }
                    pp.setSongNotes(notes[0..n], song_len_beats);
                },
                .empty => {},
            }
            self.flattenClipAutomation(@intCast(i), lane, bpb);
        }
    }

    /// Flatten one track's clips' gain/pan/filter-cutoff breakpoints (clip-
    /// relative beats) into absolute-song-beat curves and push them to the
    /// engine. Runs for every instrument kind — a non-synth track's
    /// `filter_cutoff` slice is simply always empty (the automation editor
    /// only ever writes it for poly_synth tracks), so this loop needs no
    /// extra guard. Clips are already stored start_bar-ascending
    /// (`Lane.place`) and each clip's own points are beat-ascending
    /// (`automation.setPoint`), so appending in clip order needs no extra sort.
    fn flattenClipAutomation(self: *Session, track: u16, lane: *arr_mod.Lane, bpb: f64) void {
        var gain_pts: [automation_mod.max_points]AutomationPoint = undefined;
        var gain_n: usize = 0;
        var pan_pts: [automation_mod.max_points]AutomationPoint = undefined;
        var pan_n: usize = 0;
        var fc_pts: [automation_mod.max_points]AutomationPoint = undefined;
        var fc_n: usize = 0;
        for (lane.clips.items) |c| {
            const clip_start_beat = @as(f64, @floatFromInt(c.start_bar)) * bpb;
            for (c.automation.gain) |p| {
                if (gain_n >= gain_pts.len) break;
                // Points are edited in dB; the engine curve stores linear
                // gain, the same unit `TrackState.gain` already uses.
                gain_pts[gain_n] = .{ .beat = clip_start_beat + p.beat, .value = types.dbToGain(p.value) };
                gain_n += 1;
            }
            for (c.automation.pan) |p| {
                if (pan_n >= pan_pts.len) break;
                pan_pts[pan_n] = .{ .beat = clip_start_beat + p.beat, .value = p.value };
                pan_n += 1;
            }
            for (c.automation.filter_cutoff) |p| {
                if (fc_n >= fc_pts.len) break;
                // Already Hz, the same unit PolySynth.setParamAbsolute
                // expects — no conversion needed, unlike gain's dB->linear.
                fc_pts[fc_n] = .{ .beat = clip_start_beat + p.beat, .value = p.value };
                fc_n += 1;
            }
        }
        self.engine.setTrackAutomation(track, .gain, gain_pts[0..gain_n]);
        self.engine.setTrackAutomation(track, .pan, pan_pts[0..pan_n]);
        self.engine.setTrackAutomation(track, .filter_cutoff, fc_pts[0..fc_n]);
    }

    /// Whole bars needed to hold `len_beats`, at least one.
    fn barsFor(len_beats: f64, beats_per_bar: f64) u32 {
        if (len_beats <= 0 or beats_per_bar <= 0) return 1;
        return @max(1, @as(u32, @intFromFloat(@ceil(len_beats / beats_per_bar))));
    }

    pub fn deinit(self: *Session) void {
        self.master_fx.deinit(self.allocator);
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

test "setInstrument retires the old rack instead of freeing it" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();

    const old_rack = s.racks.items[0];
    try s.setInstrument(0, .poly_synth);
    try std.testing.expectEqual(@as(usize, 1), s.retired_racks.items.len);
    try std.testing.expectEqual(old_rack, s.retired_racks.items[0]);
    try std.testing.expect(s.racks.items[0] != old_rack);
}

test "setInstrument keeps the new device in the current song mode" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .poly_synth);
    s.setSongMode(true);

    try s.setInstrument(0, .drum_machine);
    try std.testing.expect(s.racks.items[0].instrument.drum_machine.song_mode);

    try s.setInstrument(0, .sampler);
    try std.testing.expect(s.racks.items[0].pattern_player.?.song_mode);
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

test "duplicateTrack copies params and appends at the end" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .poly_synth);
    s.project.tracks.items[0].gain_db = -6.0;
    s.project.tracks.items[0].pan = 0.5;
    s.project.tracks.items[0].muted = true;

    const idx = try s.duplicateTrack(0);
    try std.testing.expectEqual(@as(u16, 1), idx);
    try std.testing.expectEqual(@as(usize, 2), s.project.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 2), s.racks.items.len);

    const dup = s.project.tracks.items[1];
    try std.testing.expectEqualStrings("track 1 copy", dup.name);
    try std.testing.expectApproxEqAbs(@as(f32, -6.0), dup.gain_db, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dup.pan, 1e-6);
    try std.testing.expect(dup.muted);
    try std.testing.expect(s.racks.items[0] != s.racks.items[1]);
    try std.testing.expectEqual(rack_mod.InstrumentKind.poly_synth, std.meta.activeTag(s.racks.items[1].instrument));

    // Chains stay live and renderable after the duplicate.
    _ = s.engine.send(.play);
    var block: [128]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block);
}

test "duplicateTrack deep-copies sampler audio and drum kit pads" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .sampler);
    const idx = try s.duplicateTrack(0);

    const orig_samples = s.racks.items[0].instrument.sampler.pad.samples;
    const dup_samples = s.racks.items[idx].instrument.sampler.pad.samples;
    try std.testing.expect(orig_samples.ptr != dup_samples.ptr);
    try std.testing.expectEqualSlices(f32, orig_samples, dup_samples);

    try s.setInstrument(0, .drum_machine);
    const drum_idx = try s.duplicateTrack(0);
    const orig_pad = s.racks.items[0].instrument.drum_machine.pads[0].pad;
    const dup_pad = s.racks.items[drum_idx].instrument.drum_machine.pads[0].pad;
    try std.testing.expect(orig_pad.samples.ptr != dup_pad.samples.ptr);
    try std.testing.expectEqualSlices(f32, orig_pad.samples, dup_pad.samples);
}

test "duplicateTrack copies arrangement clips into a new lane" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .poly_synth);
    const pp = &s.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    try s.stampClip(0, 0);

    const idx = try s.duplicateTrack(0);
    const dst_lane = s.arrangement.lane(idx).?;
    try std.testing.expectEqual(@as(usize, 1), dst_lane.clips.items.len);
    try std.testing.expectEqual(@as(usize, 1), dst_lane.clips.items[0].content.melodic.notes.len);
    // Independent allocation: mutating the source doesn't touch the copy.
    try std.testing.expect(
        dst_lane.clips.items[0].content.melodic.notes.ptr !=
            s.arrangement.lane(0).?.clips.items[0].content.melodic.notes.ptr,
    );
}

test "swapTracks exchanges project, rack, lane, and engine state" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    _ = try s.addTrack("second");
    try s.setInstrument(0, .poly_synth);
    s.project.tracks.items[0].gain_db = -3.0;
    try s.stampClip(0, 0);

    const rack_a = s.racks.items[0];
    const rack_b = s.racks.items[1];

    s.swapTracks(0, 1);

    try std.testing.expectEqual(rack_b, s.racks.items[0]);
    try std.testing.expectEqual(rack_a, s.racks.items[1]);
    try std.testing.expectEqualStrings("second", s.project.tracks.items[0].name);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), s.project.tracks.items[1].gain_db, 1e-6);
    try std.testing.expectEqual(@as(usize, 0), s.arrangement.lane(0).?.clips.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.arrangement.lane(1).?.clips.items.len);

    // Engine still renders after the swap.
    _ = s.engine.send(.play);
    var block: [128]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block);
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

test "song mode flattens a melodic clip to absolute beats" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .poly_synth);
    const pp = &s.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 1.0 });
    pp.length_beats = 4.0; // one bar in 4/4
    try s.stampClip(0, 2); // place the clip at bar 2

    s.setSongMode(true);
    try std.testing.expect(pp.song_mode);
    try std.testing.expectEqual(@as(u16, 1), pp.song_note_count);
    // bar 2 = beat 8, plus the note's 1-beat offset → absolute beat 9.
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), pp.song_notes[0].start_beat, 1e-9);
    // Arrangement spans bars 0..3 (the clip covers bar 2) → 12 beats.
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), pp.song_length_beats, 1e-9);

    s.setSongMode(false);
    try std.testing.expect(!pp.song_mode);
}

test "song mode repeats a melodic clip's pattern to fill an edge-resized span" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .poly_synth);
    const pp = &s.racks.items[0].pattern_player.?;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.length_beats = 4.0; // one bar in 4/4
    try s.stampClip(0, 0);

    // Edge-resize the clip to 3 bars — 3x the captured pattern's length —
    // the same operation editors/arrangement.zig's resizeClip performs.
    const lane = s.arrangement.lane(0).?;
    lane.clips.items[0].length_bars = 3;

    s.setSongMode(true);
    // The one-note pattern should repeat 3 times: beats 0, 4, 8.
    try std.testing.expectEqual(@as(u16, 3), pp.song_note_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pp.song_notes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), pp.song_notes[1].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), pp.song_notes[2].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), pp.song_length_beats, 1e-9);
}

test "stampClip captures the active drum variant" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .drum_machine);
    const dm = &s.racks.items[0].instrument.drum_machine;
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.toggleStep(0, 0); // variant A: pad 0 step 0

    _ = dm.addVariant(); // variant B, copy of A
    dm.toggleStep(0, 0);
    dm.toggleStep(1, 2); // variant B: pad 1 step 2 only
    dm.setStepVel(1, 2, 2); // at 50% velocity

    try s.stampClip(0, 0); // stamps B (active) — spans bars 0-1 (32 steps = 2 bars)
    dm.selectVariant(0);
    try s.stampClip(0, 2); // stamps A — bar 2, past B's span so it isn't evicted

    const lane = s.arrangement.lane(0).?;
    const b = lane.clips.items[0].content.drum;
    const a = lane.clips.items[1].content.drum;
    try std.testing.expectEqual(@as(u8, 1), b.variant);
    try std.testing.expectEqual(@as(u32, 1 << 2), b.pattern[1]);
    try std.testing.expectEqual(@as(u32, 1 << 2), b.vel_hi[1]); // 50% carried
    try std.testing.expectEqual(@as(u32, 0), b.vel_lo[1]);
    try std.testing.expectEqual(@as(u32, 0), b.pattern[0]);
    try std.testing.expectEqual(@as(u8, 0), a.variant);
    try std.testing.expectEqual(@as(u32, 1), a.pattern[0]);
}

test "song mode places a drum clip on the step timeline" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .drum_machine);
    const dm = &s.racks.items[0].instrument.drum_machine;
    dm.pattern[0].store(1, .monotonic); // pad 0, step 0
    try s.stampClip(0, 1); // bar 1

    s.setSongMode(true);
    try std.testing.expect(dm.song_mode);
    try std.testing.expectEqual(@as(u16, 1), dm.song_clip_count);
    // 4/4, 16th-note steps → 16 steps per bar, so bar 1 starts at step 16.
    try std.testing.expectEqual(@as(u32, 16), dm.song_clips[0].start_step);
    // The clip's own pattern is 32 steps (2 bars) — the new default.
    try std.testing.expectEqual(@as(u32, 32), dm.song_clips[0].span_steps);
    try std.testing.expectEqual(@as(u32, 1), dm.song_clips[0].pattern[0]);
    // Arrangement spans bars 0..3 (clip covers bars 1-2) → 48 steps.
    try std.testing.expectEqual(@as(u32, 48), dm.song_length_steps);
}

test "setMetronome mirrors to the engine" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(!s.metronome_enabled);

    s.setMetronome(true);
    try std.testing.expect(s.metronome_enabled);
    _ = s.engine.send(.play);
    var block: [128]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block);
    try std.testing.expect(s.engine.metronome_enabled);

    s.setMetronome(false);
    try std.testing.expect(!s.metronome_enabled);
}

test "syncMasterChain pushes master_fx's active units to the engine" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.engine.master_chain_len);

    _ = try s.master_fx.insert(s.allocator, 0, .comp, s.project.sample_rate);
    _ = try s.master_fx.insert(s.allocator, 1, .eq, s.project.sample_rate);
    s.syncMasterChain();
    try std.testing.expectEqual(@as(usize, 2), s.engine.master_chain_len);

    s.master_fx.remove(s.allocator, 0);
    s.syncMasterChain();
    try std.testing.expectEqual(@as(usize, 1), s.engine.master_chain_len);
}

test "song-mode gain automation ramps a track's level down over the clip" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .poly_synth);

    // A held note spanning the whole clip so the synth's own envelope stays
    // at sustain level throughout — any amplitude change we measure comes
    // from the automation curve, not the note's own attack/release.
    const lane = s.arrangement.lane(0).?;
    const notes = [_]Note{.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 4.0, .velocity = 1.0 }};
    try lane.place(s.allocator, try Clip.initMelodic(s.allocator, 0, 1, &notes, 4.0));
    const clip = lane.clipAt(0).?;
    try automation_mod.setPoint(s.allocator, &clip.automation.gain, 0.0, 0.0); // 0 dB
    try automation_mod.setPoint(s.allocator, &clip.automation.gain, 1.0, -40.0); // -40 dB by beat 1

    s.setSongMode(true);
    _ = s.engine.send(.play);

    var block: [512]@import("core/types.zig").Sample = undefined;
    var loud: f32 = 0.0;
    for (0..4) |_| { // let the envelope settle in, still near beat 0
        s.engine.process(&block);
        for (block) |v| loud = @max(loud, @abs(v));
    }
    try std.testing.expect(loud > 0.02);

    // 120bpm/48kHz = 24_000 frames/beat; 256 frames/block (512 interleaved
    // stereo samples) → ~94 blocks to clear beat 1. Run comfortably past it.
    for (0..120) |_| s.engine.process(&block);
    var quiet: f32 = 0.0;
    for (0..4) |_| {
        s.engine.process(&block);
        for (block) |v| quiet = @max(quiet, @abs(v));
    }
    try std.testing.expect(quiet < loud * 0.05); // -40dB ≈ 1% amplitude

    // Seeking back to the start re-evaluates the curve from scratch — proves
    // it's a live function of transport position, not a one-way latch.
    _ = s.engine.send(.{ .seek_frames = 0 });
    var back_loud: f32 = 0.0;
    for (0..4) |_| {
        s.engine.process(&block);
        for (block) |v| back_loud = @max(back_loud, @abs(v));
    }
    try std.testing.expect(back_loud > loud * 0.5);
}

//! Default session factory and track lifecycle management.
//!
//! Session owns the canonical backend objects (project, engine, racks) and
//! exposes the operations that mutate them atomically. Frontends embed Session
//! and call its methods; TUI-only state (cursor, views, status) lives in the
//! frontend struct.

const std = @import("std");
const types = @import("core/types.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;
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
const Slicer = @import("dsp/slicer.zig").Slicer;
const Compressor = @import("dsp/compressor.zig").Compressor;
const dsp = @import("dsp/device.zig");
const arr_mod = @import("arrangement.zig");
const Arrangement = arr_mod.Arrangement;
const Clip = arr_mod.Clip;
const automation_mod = @import("dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;
const time_grid = @import("time_grid.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    project: Project,
    /// Heap-allocated so its address (and Transport's address) never moves.
    engine: *Engine,
    /// Each *Rack is heap-allocated; pointers are stable for DSP self-refs.
    racks: std.ArrayListUnmanaged(*Rack),
    /// Racks removed from active use but not yet freed - the audio thread may
    /// still be mid-frame referencing them. Freed at deinit.
    retired_racks: std.ArrayListUnmanaged(*Rack),
    /// Song-mode clip timeline, one lane per track (parallel to `racks`).
    arrangement: Arrangement,
    /// When true, playback follows the arrangement timeline; when false, each
    /// track loops its single live pattern (the original behavior). Honored by
    /// the engine in song-mode playback.
    song_mode: bool = false,
    /// Click track on/off. Control-side source of truth, mirrored to the
    /// engine via `set_metronome` - same pattern as `loop_enabled`/`song_mode`.
    /// A monitoring aid, not song content, so it isn't persisted.
    metronome_enabled: bool = false,
    /// Master bus FX chain, applied to the summed mix before the master gain
    /// and always-on limiter - same user-built `Fx` chain as a track's rack,
    /// so any unit plugs into either the same way. Persisted
    /// (`Snapshot.master_fx_chain`, see persist.zig). Push param/membership
    /// changes to the audio thread with `syncMasterChain`.
    master_fx: rack_mod.Fx = .{},
    /// Track-grouping submix buses (see `Group`). Fixed bank of
    /// `engine_mod.max_groups` slots, `null` = unused - same "fixed bank,
    /// null-slot" shape `engine_mod.GroupState` mirrors on the audio-thread
    /// side. Persisted (`Snapshot.groups`, see persist.zig).
    groups: [engine_mod.max_groups]?Group = [_]?Group{null} ** engine_mod.max_groups,

    /// One track-grouping submix bus: a named FX chain every member track's
    /// summed signal passes through before the master mix - same idea as
    /// `master_fx`, just scoped to whichever tracks point at it (see
    /// `Track.group`, `Session.assignTrackGroup`). The FX-chain editor UI is
    /// shared wholesale with tracks/master (tui/editors/spectrum.zig).
    pub const Group = struct {
        name: []u8,
        fx: rack_mod.Fx = .{},
        /// Bus fader, dB - applied post-chain by the engine (see
        /// `GroupState.gain`). Same clamp range as track gain.
        gain_db: f32 = 0.0,
        /// Tracks-view fold state: when true the group's member rows are
        /// hidden behind the group's own row. Pure UI state - the engine
        /// never sees it - but persisted so a folded mixer stays folded
        /// across save/load (`GroupSnap.folded`).
        folded: bool = false,

        pub fn deinit(self: *Group, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            self.fx.deinit(allocator);
        }
    };

    /// Build the default session: a single blank track. Instruments are added
    /// per-track via `setInstrument`; the shipped `demo.wsj` is the curated
    /// multi-track starting point (load it with `wstudio demo.wsj`).
    pub fn initDefault(allocator: std.mem.Allocator) !Session {
        return initDefaultWithSampleRate(allocator, types.default_sample_rate);
    }

    pub fn initDefaultWithSampleRate(allocator: std.mem.Allocator, sample_rate: u32) !Session {
        var project = Project.init(allocator);
        errdefer project.deinit();
        project.sample_rate = sample_rate;
        _ = try project.addTrack(.{ .name = "untitled track", .color = 1 });
        const sr = project.sample_rate;

        const engine = try allocator.create(Engine);
        errdefer allocator.destroy(engine);
        try engine.initInPlace(allocator, sr);
        errdefer engine.deinit();
        engine.loadProject(&project);

        var racks: std.ArrayListUnmanaged(*Rack) = .empty;
        errdefer {
            // zig fmt: off
            for (racks.items) |r| { r.deinit(allocator); allocator.destroy(r); }
            // zig fmt: on
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
            self.syncTrackChain(@intCast(i), rack);
        }
        return self;
    }

    /// Append a new blank track at the end. The user picks an instrument for it
    /// via `setInstrument`. Returns the new track index.
    pub fn addTrack(self: *Session, name: []const u8) error{ TrackLimitReached, OutOfMemory }!u16 {
        return self.insertTrack(@intCast(self.project.tracks.items.len), name);
    }

    /// Insert a new blank track at `at` (clamped to the current track
    /// count, so `at == len` is the same as `addTrack`), shifting every
    /// track from `at` on up by one. The user picks an instrument for it
    /// via `setInstrument`. Returns the new track's index.
    pub fn insertTrack(self: *Session, at: u16, name: []const u8) error{ TrackLimitReached, OutOfMemory }!u16 {
        if (self.project.tracks.items.len >= engine_mod.max_tracks)
            return error.TrackLimitReached;

        const total: u16 = @intCast(self.project.tracks.items.len);
        const idx = @min(at, total);

        const rack = try self.allocator.create(Rack);
        errdefer self.allocator.destroy(rack);
        rack.* = .{ .instrument = .empty, .label = "empty" };

        try self.racks.insert(self.allocator, idx, rack);
        errdefer _ = self.racks.orderedRemove(idx);

        try self.arrangement.insertLane(self.allocator, idx);
        errdefer self.arrangement.removeLane(self.allocator, idx);

        // Auto-assign a color so new tracks are visually distinct from the
        // moment they're created, instead of starting uncolored until the
        // user manually cycles one with `[`/`]`. Cycles by track count
        // (not `idx`) so repeated inserts at the same position still walk
        // the palette instead of repeating a color.
        const color: u8 = @intCast(@mod(total, project_mod.track_color_count) + 1);
        try self.project.insertTrack(idx, .{ .name = name, .color = color });

        self.engine.applyInsertTrack(idx, total, 1.0, 0.0, false);
        self.syncTrackChain(idx, rack);
        // Existing tracks from `idx` on shifted up by one; any compressor
        // sidechaining off one of them must follow.
        self.remapSidechainSources(.{ .insert = idx });

        return idx;
    }

    /// Replace the instrument on `track_idx` with a fresh instance of `kind`.
    /// The replacement is built in a brand-new heap rack; the old rack is moved
    /// to `retired_racks` rather than torn down in place - the audio thread may
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
                rack.instrument = .{ .poly_synth = try PolySynth.init(self.allocator, sr) };
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
            .slicer => {
                rack.instrument = .{ .slicer = try Slicer.init(self.allocator, sr, &self.engine.transport) };
                rack.label = "slicer";
            },
        }
        // Set AFTER the instrument lands in the heap rack - the player holds a
        // pointer into it. Slicer gets its own step grid, not a PatternPlayer,
        // same as drum_machine.
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

        self.syncTrackChain(@intCast(track_idx), rack);

        // Keep the new device coherent with the current playback mode: its
        // lane is empty now, so in song mode it must follow the (empty) song
        // buffer rather than looping its live pattern over the arrangement.
        if (self.song_mode) {
            self.rebuildSongData();
            if (rack.pattern_player) |*pp| pp.song_mode = true;
            switch (rack.instrument) {
                .drum_machine => |*dm| dm.song_mode = true,
                .slicer => |*sl| sl.song_mode = true,
                else => {},
            }
        }
    }

    /// Replace one drum-machine track with one sampler track per materialized
    /// pad. Hit times and velocities become ordinary melodic notes, including
    /// private MIDI copies for every arrangement clip.
    pub fn splitDrumTrack(self: *Session, track_idx: usize) !u8 {
        if (track_idx >= self.racks.items.len) return error.NotDrumMachine;
        const dm = switch (self.racks.items[track_idx].instrument) {
            .drum_machine => |*v| v,
            else => return error.NotDrumMachine,
        };
        var pads: [DrumMachine.max_pads]u8 = undefined;
        var pad_count: u8 = 0;
        for (dm.pads, 0..) |pad, i| {
            if (pad == null) continue;
            pads[pad_count] = @intCast(i);
            pad_count += 1;
        }
        if (pad_count == 0) return error.NoPads;
        const final_count = self.project.tracks.items.len - 1 + pad_count;
        if (final_count > engine_mod.max_tracks) return error.TrackLimitReached;

        var inserted: u8 = 0;
        errdefer while (inserted > 0) {
            inserted -= 1;
            self.deleteTrack(track_idx + 1) catch {};
        };

        for (pads[0..pad_count]) |pad_idx| {
            const name = dm.padName(pad_idx);
            const out_idx = try self.insertTrack(@intCast(track_idx + 1 + inserted), name);
            inserted += 1;
            try self.setInstrument(out_idx, .sampler);
            const out_rack = self.racks.items[out_idx];
            const fresh = &out_rack.instrument.sampler;
            const copied = try dm.pads[pad_idx].?.dupe();
            fresh.deinit();
            fresh.* = copied;

            const pp = &out_rack.pattern_player.?;
            var notes: [DrumMachine.max_steps]Note = undefined;
            var note_count: usize = dm.copyPadMidi(pad_idx, &notes);
            for (notes[0..note_count]) |*note| note.pitch = fresh.root_note;
            const live_length = @as(f64, @floatFromInt(dm.step_count)) / @as(f64, @floatFromInt(dm.steps_per_beat));
            pp.setNotes(notes[0..note_count], live_length);

            const source_lane = self.arrangement.lane(track_idx).?;
            const out_lane = self.arrangement.lane(out_idx).?;
            for (source_lane.clips.items) |clip| {
                const drum = switch (clip.content) {
                    .drum => |v| v,
                    .melodic => continue,
                };
                note_count = 0;
                for (drum.midi[pad_idx][0..drum.step_count]) |maybe_note| {
                    var note = (maybe_note orelse continue).toPattern(drum.steps_per_beat);
                    note.pitch = fresh.root_note;
                    notes[note_count] = note;
                    note_count += 1;
                }
                const pattern_beats = @as(f64, @floatFromInt(drum.step_count)) / @as(f64, @floatFromInt(drum.steps_per_beat));
                try out_lane.place(self.allocator, try Clip.initMelodic(
                    self.allocator,
                    clip.start_tick,
                    clip.length_ticks,
                    notes[0..note_count],
                    pattern_beats,
                ));
            }
        }

        self.deleteTrack(track_idx) catch unreachable;
        if (self.song_mode) self.rebuildSongData();
        return pad_count;
    }

    pub const DeleteTrackError = error{CannotDeleteLastTrack};

    /// Remove the track at `track_idx`. The displaced rack is moved to
    /// `retired_racks` rather than freed immediately - the audio thread may
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

        // Compressors elsewhere may sidechain off a track index that just
        // shifted (or off the deleted track itself) - rewrite and resync.
        self.remapSidechainSources(.{ .delete = @intCast(track_idx) });
    }

    /// Per-track mixer fields `restoreTrack` needs, mirroring `Track`'s own
    /// fields minus `name`/`kind` (name is a separate arg; kind is implied
    /// by the restored rack's instrument).
    pub const RestoredMeta = struct {
        gain_db: f32,
        pan: f32,
        muted: bool,
        soloed: bool,
        color: u8,
        group: ?u8,
    };

    /// Re-insert a previously-deleted track's full state at `at`, shifting
    /// later tracks up by one - the undo-side counterpart to `deleteTrack`.
    /// Takes ownership of `rack` and `clips`: they land directly in session
    /// structures with no further copy, since the caller (undo's
    /// `TrackFullState`) already holds a deep copy made specifically for
    /// this restore. Mirrors `insertTrack`'s exact call shape - including
    /// running `remapSidechainSources` only after the rack is already in
    /// `self.racks`, so a sidechain reference living on the RESTORED rack's
    /// own chain gets swept by the same pass as everyone else's.
    pub fn restoreTrack(self: *Session, at: u16, name: []const u8, meta: RestoredMeta, rack: *Rack, clips: []Clip) !void {
        const total: u16 = @intCast(self.project.tracks.items.len);
        const idx = @min(at, total);

        try self.racks.insert(self.allocator, idx, rack);
        errdefer _ = self.racks.orderedRemove(idx);

        try self.arrangement.insertLane(self.allocator, idx);
        errdefer self.arrangement.removeLane(self.allocator, idx);
        const lane = self.arrangement.lane(idx).?;
        for (clips) |c| try lane.clips.append(self.allocator, c);
        self.allocator.free(clips);

        try self.project.insertTrack(idx, .{
            // zig fmt: off
            .name = name, .gain_db = meta.gain_db, .pan = meta.pan,
            .muted = meta.muted, .soloed = meta.soloed, .color = meta.color,
            // zig fmt: on
            .group = meta.group,
        });

        self.engine.applyInsertTrack(idx, total, types.dbToGain(meta.gain_db), meta.pan, meta.muted);
        self.syncTrackChain(idx, rack);
        self.remapSidechainSources(.{ .insert = idx });
        if (meta.soloed) _ = self.engine.send(.{ .set_track_solo = .{ .track = idx, .soloed = true } });
        if (meta.group) |g| _ = self.engine.send(.{ .set_track_group = .{ .track = idx, .group = g } });

        if (self.song_mode) self.rebuildSongData();
    }

    /// Deep-copy `track_idx` - instrument, params, FX, pattern/pad audio, and
    /// its arrangement clips - into a new track appended at the end. Appending
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
            // zig fmt: off
            self.allocator, self.project.sample_rate, &self.engine.transport,
        );
        errdefer { new_rack.deinit(self.allocator); self.allocator.destroy(new_rack); }
        // zig fmt: on

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
            // zig fmt: off
            .name = name, .kind = src.kind, .gain_db = src.gain_db,
            .pan = src.pan, .muted = src.muted, .soloed = src.soloed,
            .color = src.color, .group = src.group,
            // zig fmt: on
        });

        self.engine.applyInsertTrack(idx, idx, types.dbToGain(src.gain_db), src.pan, src.muted);
        self.syncTrackChain(idx, new_rack);
        if (src.soloed) _ = self.engine.send(.{ .set_track_solo = .{ .track = idx, .soloed = true } });
        if (src.group) |g| _ = self.engine.send(.{ .set_track_group = .{ .track = idx, .group = g } });

        if (self.song_mode) self.rebuildSongData();

        return idx;
    }

    /// Swap two tracks' positions across every parallel structure (project,
    /// racks, arrangement lanes, engine state+chain). No allocation, cannot
    /// fail. A rack's own song-mode data travels with it, so no rebuild is
    /// needed. Callers should reset any per-instrument editor-target/undo
    /// state tied to an absolute track index - a swap silently changes what
    /// index `a`/`b` mean, same rule as `deleteTrack`.
    pub fn swapTracks(self: *Session, a: usize, b: usize) void {
        if (a == b or a >= self.racks.items.len or b >= self.racks.items.len) return;
        // A note queued for either track right before the swap must not
        // fire on the wrong instrument once reindexed - same rule
        // setInstrument/deleteTrack/setSongMode already follow.
        _ = self.engine.send(.all_notes_off);
        self.project.swapTracks(a, b);
        std.mem.swap(*Rack, &self.racks.items[a], &self.racks.items[b]);
        self.arrangement.swapLanes(a, b);
        self.engine.swapTracks(@intCast(a), @intCast(b));
        // Same rule as deleteTrack: sidechain sources name tracks, so they
        // follow the swap.
        self.remapSidechainSources(.{ .swap = .{ .a = @intCast(a), .b = @intCast(b) } });
    }

    /// Backward-compatible whole-bar stamping entry point.
    /// Melodic tracks copy their piano-roll notes; drum tracks copy their MIDI
    /// notes and playback projection. The clip's bar length is derived from
    /// the pattern length. No-op for empty tracks. Replaces any clips it
    /// overlaps (see `Lane.place`).
    pub fn stampClip(self: *Session, track_idx: usize, start_bar: u32) !void {
        return self.stampClipAtTick(track_idx, start_bar * time_grid.barTicks(self.project.beats_per_bar));
    }

    /// Capture a live pattern at an exact musical tick.
    pub fn stampClipAtTick(self: *Session, track_idx: usize, start_tick: u32) !void {
        if (track_idx >= self.racks.items.len) return;
        const lane = self.arrangement.lane(track_idx) orelse return;
        const rack = self.racks.items[track_idx];
        const bpb: f64 = @floatFromInt(self.project.beats_per_bar);
        const ticks_per_bar = time_grid.barTicks(self.project.beats_per_bar);

        switch (rack.instrument) {
            .empty => return,
            .drum_machine => |*dm| {
                var drum: Clip.Drum = .{
                    .pattern = undefined,
                    .midi = dm.midi,
                    .step_count = dm.step_count,
                    .steps_per_beat = dm.steps_per_beat,
                    .variant = dm.variant,
                };
                for (&drum.pattern, &drum.vel, 0..) |*p, *vel_row, i| {
                    p.* = dm.pattern[i].load(.acquire);
                    for (vel_row, &dm.vel[i]) |*v, *live| v.* = live.load(.acquire);
                }
                const len_beats = @as(f64, @floatFromInt(dm.step_count)) / @as(f64, @floatFromInt(dm.steps_per_beat));
                try lane.place(self.allocator, Clip.initDrum(
                    // zig fmt: off
                    start_tick, barsFor(len_beats, bpb) * ticks_per_bar, drum,
                    // zig fmt: on
                ));
            },
            // Slicer patterns are the same 64-row step grid a drum bank is
            // (`Slicer.max_slices == DrumMachine.max_pads`), so they stamp
            // as the same `.drum` clip content - no third clip kind.
            .slicer => |*sl| {
                var drum: Clip.Drum = .{
                    .pattern = undefined,
                    .step_count = sl.step_count,
                    .variant = sl.variant,
                };
                for (&drum.pattern, &drum.vel, 0..) |*p, *vel_row, i| {
                    p.* = sl.pattern[i].load(.acquire);
                    for (vel_row, &sl.vel[i]) |*v, *live| v.* = live.load(.acquire);
                }
                const len_beats = @as(f64, @floatFromInt(sl.step_count)) / 4.0;
                try lane.place(self.allocator, Clip.initDrum(
                    // zig fmt: off
                    start_tick, barsFor(len_beats, bpb) * ticks_per_bar, drum,
                    // zig fmt: on
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
                    // zig fmt: off
                    self.allocator, start_tick, barsFor(len_beats, bpb) * ticks_per_bar, tmp[0..count], len_beats,
                    // zig fmt: on
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
            // Automation is meaningless off the arrangement timeline - leave
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
                .slicer => |*sl| sl.song_mode = on,
                else => {},
            }
        }
    }

    /// Toggle the click track.
    pub fn setMetronome(self: *Session, on: bool) void {
        self.metronome_enabled = on;
        _ = self.engine.send(.{ .set_metronome = on });
    }

    /// Push `rack`'s chain (instrument/pattern-player + active FX units) to
    /// the audio thread, AND the sidechain-detector routing for any
    /// compressor in that chain (see `Rack.sidechainSources`) - the two
    /// always go together since the audio thread never introspects chain
    /// contents itself to discover sidechain routing live (see
    /// `Engine.setTrackSidechainSources`'s doc comment). Call after any
    /// change that could move where a compressor sits in the chain (insert,
    /// remove, reorder, bypass) or change its `sidechain_source`, not just
    /// after a fresh instrument swap.
    pub fn syncTrackChain(self: *Session, idx: u16, rack: *rack_mod.Rack) void {
        var buf: [rack_mod.Rack.chain_cap]dsp.Device = undefined;
        self.engine.setTrackChain(idx, rack.chain(&buf));
        var sc_buf: [rack_mod.Rack.chain_cap]?Compressor.SidechainSource = undefined;
        self.engine.setTrackSidechainSources(idx, rack.sidechainSources(&sc_buf));
    }

    /// Push the master bus's active FX units (in chain order) to the audio
    /// thread, plus their sidechain-detector routing - same idea as
    /// `syncTrackChain`, but the master bus has no instrument slot, just
    /// `master_fx`. Call after inserting, removing, reordering, or bypassing
    /// a master FX unit, or changing a compressor's `sidechain_source`.
    pub fn syncMasterChain(self: *Session) void {
        var buf: [rack_mod.Fx.max_units]dsp.Device = undefined;
        self.engine.setMasterChain(self.master_fx.chain(&buf));
        var sc_buf: [rack_mod.Fx.max_units]?Compressor.SidechainSource = undefined;
        self.engine.setMasterSidechainSources(self.master_fx.sidechainSources(&sc_buf));
    }

    /// Push group `idx`'s active FX units (and their sidechain-detector
    /// routing) to the audio thread - same idea as `syncMasterChain`, one
    /// group at a time. Call after inserting, removing, reordering, or
    /// bypassing a unit in that group's chain (or changing a compressor's
    /// `sidechain_source`), and once for every active group after loading a
    /// project (see persist.zig). A null (unused) slot pushes an empty,
    /// inactive chain, matching `deleteGroup`'s own cleanup.
    pub fn syncGroupChain(self: *Session, idx: u8) void {
        if (idx >= engine_mod.max_groups) return;
        var buf: [rack_mod.Fx.max_units]dsp.Device = undefined;
        var sc_buf: [rack_mod.Fx.max_units]?Compressor.SidechainSource = undefined;
        if (self.groups[idx]) |*g| {
            self.engine.setGroupChain(idx, true, g.fx.chain(&buf));
            self.engine.setGroupSidechainSources(idx, g.fx.sidechainSources(&sc_buf));
            _ = self.engine.send(.{ .set_group_gain = .{ .group = idx, .gain = types.dbToGain(g.gain_db) } });
        } else {
            self.engine.setGroupChain(idx, false, &.{});
            self.engine.setGroupSidechainSources(idx, &.{});
            _ = self.engine.send(.{ .set_group_gain = .{ .group = idx, .gain = 1.0 } });
        }
    }

    /// Set group `idx`'s bus fader (clamped to track gain's -60..+12 dB
    /// range) and push it to the audio thread. No-op on an unused slot.
    pub fn setGroupGain(self: *Session, idx: u8, db: f32) void {
        if (idx >= engine_mod.max_groups) return;
        if (self.groups[idx]) |*g| {
            g.gain_db = std.math.clamp(db, -60.0, 12.0);
            _ = self.engine.send(.{ .set_group_gain = .{ .group = idx, .gain = types.dbToGain(g.gain_db) } });
        }
    }

    /// How a structural track change (delete/swap/insert) reshapes a track
    /// index. Shared by `remapSidechainSources` below and, via
    /// `tui/undo.zig`'s re-export, `History.retarget` for undo entries - one
    /// definition of "what happens to a track index" instead of two unions
    /// with the same three cases drifting apart.
    pub const TrackRemap = union(enum) {
        delete: u16,
        swap: struct { a: u16, b: u16 },
        /// A new track was inserted at this index; everything from here on
        /// shifted up by one.
        insert: u16,

        /// The track's new index, or null if it no longer exists (delete
        /// only - neither a swap nor an insert ever removes a track).
        pub fn apply(self: TrackRemap, track: u16) ?u16 {
            return switch (self) {
                .delete => |del| if (track == del) null else if (track > del) track - 1 else track,
                .swap => |s| if (track == s.a) s.b else if (track == s.b) s.a else track,
                .insert => |at| if (track >= at) track + 1 else track,
            };
        }
    };

    /// Rewrite every compressor's `sidechain_source` (track racks, group
    /// buses, master) after track indices shift, then push the refreshed
    /// routing to the engine. Without this a compressor keeps its raw
    /// index and silently starts detecting from whatever track slid into
    /// it - the source is a persisted USER setting naming a specific
    /// track, so it must follow that track (or clear when it's deleted),
    /// same reason `TrackState.group` values are per-track state the
    /// engine shifts in applyDeleteTrack.
    fn remapSidechainSources(self: *Session, op: TrackRemap) void {
        const remapFx = struct {
            fn go(fx: *rack_mod.Fx, op_: TrackRemap) void {
                for (fx.units.items) |u| switch (u.payload) {
                    .comp => |*c| if (c.sidechain_source) |sc| {
                        c.sidechain_source = if (op_.apply(sc.track)) |nt|
                            .{ .track = nt, .pad = sc.pad }
                        else
                            null;
                    },
                    else => {},
                };
            }
        }.go;
        for (self.racks.items) |rack| remapFx(&rack.fx, op);
        for (&self.groups) |*slot| if (slot.*) |*g| remapFx(&g.fx, op);
        remapFx(&self.master_fx, op);

        for (self.racks.items, 0..) |rack, i| {
            var sc_buf: [rack_mod.Rack.chain_cap]?Compressor.SidechainSource = undefined;
            self.engine.setTrackSidechainSources(@intCast(i), rack.sidechainSources(&sc_buf));
        }
        for (0..engine_mod.max_groups) |gi| self.syncGroupChain(@intCast(gi));
        self.syncMasterChain();
    }

    /// Create a new group named `name` in the first free slot. Starts with
    /// an empty FX chain - same "blank slate, user builds it" convention
    /// `master_fx`/a fresh track's rack already follow.
    pub fn addGroup(self: *Session, name: []const u8) error{ GroupLimitReached, OutOfMemory }!u8 {
        for (&self.groups, 0..) |*slot, i| {
            if (slot.* != null) continue;
            const owned = try self.allocator.dupe(u8, name);
            slot.* = .{ .name = owned };
            const idx: u8 = @intCast(i);
            self.syncGroupChain(idx);
            return idx;
        }
        return error.GroupLimitReached;
    }

    /// Rename group `idx`. No-op on an unused slot.
    pub fn renameGroup(self: *Session, idx: u8, name: []const u8) !void {
        if (idx >= engine_mod.max_groups) return;
        const g = &(self.groups[idx] orelse return);
        const owned = try self.allocator.dupe(u8, name);
        self.allocator.free(g.name);
        g.name = owned;
    }

    /// Delete group `idx`: unassigns every member track (falls back to the
    /// master mix, same as a track that was never grouped), frees the
    /// group's name/FX chain, and tells the audio thread the slot is
    /// inactive. No-op on an already-unused slot.
    pub fn deleteGroup(self: *Session, idx: u8) void {
        if (idx >= engine_mod.max_groups) return;
        var g = self.groups[idx] orelse return;
        for (self.project.tracks.items, 0..) |*t, ti| {
            if (t.group == idx) self.assignTrackGroup(ti, null);
        }
        g.deinit(self.allocator);
        self.groups[idx] = null;
        self.syncGroupChain(idx);
    }

    /// Assign (or clear, with `null`) which group track `track_idx` submixes
    /// through. Validates `group` against an active slot - an out-of-range
    /// or unused index is treated as `null` (ungrouped) rather than silently
    /// pointing at nothing, matching `renderTracks`'s own inactive-slot
    /// fallback on the audio thread.
    pub fn assignTrackGroup(self: *Session, track_idx: usize, group: ?u8) void {
        if (track_idx >= self.project.tracks.items.len) return;
        const resolved: ?u8 = if (group) |g| (if (g < engine_mod.max_groups and self.groups[g] != null) g else null) else null;
        self.project.tracks.items[track_idx].group = resolved;
        _ = self.engine.send(.{ .set_track_group = .{ .track = @intCast(track_idx), .group = resolved } });
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
        const total_ticks = self.arrangement.lengthTicks();
        const song_len_beats = time_grid.tickToBeat(total_ticks);

        for (self.racks.items, 0..) |rack, i| {
            const lane = self.arrangement.lane(i) orelse continue;
            switch (rack.instrument) {
                .drum_machine => |*dm| {
                    var clips: [DrumMachine.max_song_clips]DrumMachine.SongClip = undefined;
                    var n: usize = 0;
                    const song_spb: u8 = 32;
                    for (lane.clips.items) |c| {
                        if (n >= clips.len) break;
                        // zig fmt: off
                        const drum = switch (c.content) { .drum => |d| d, .melodic => continue };
                        // zig fmt: on
                        clips[n] = .{
                            .start_step = c.start_tick,
                            .span_steps = c.length_ticks,
                            .step_count = drum.step_count,
                            .steps_per_beat = drum.steps_per_beat,
                            .pattern = drum.pattern,
                            .vel = drum.vel,
                        };
                        n += 1;
                    }
                    dm.setSongClips(clips[0..n], total_ticks, song_spb);
                },
                .slicer => |*sl| {
                    var clips: [Slicer.max_song_clips]Slicer.SongClip = undefined;
                    var n: usize = 0;
                    for (lane.clips.items) |c| {
                        if (n >= clips.len) break;
                        // zig fmt: off
                        const drum = switch (c.content) { .drum => |d| d, .melodic => continue };
                        // zig fmt: on
                        clips[n] = .{
                            .start_step = c.start_tick / 8,
                            .span_steps = @max(1, c.length_ticks / 8),
                            .step_count = drum.step_count,
                            .pattern = drum.pattern,
                            .vel = drum.vel,
                        };
                        n += 1;
                    }
                    sl.setSongClips(clips[0..n], @max(1, total_ticks / 8));
                },
                .poly_synth, .sampler => {
                    const pp = if (rack.pattern_player) |*p| p else continue;
                    var notes: [pattern_mod.max_notes]Note = undefined;
                    var n: usize = 0;
                    for (lane.clips.items) |c| {
                        // zig fmt: off
                        const mel = switch (c.content) { .melodic => |m| m, .drum => continue };
                        // zig fmt: on
                        const clip_start_beat = time_grid.tickToBeat(c.start_tick);
                        // The captured pattern repeats to fill the clip's own
                        // bar span (length_bars, edge-resizable in the
                        // arrangement editor) - the same repeat-to-fill-span
                        // rule DrumMachine.fireSongStep already applies to
                        // drum clips, just expressed in beats instead of a
                        // step modulo since melodic content has no fixed grid.
                        const clip_span_beats = time_grid.tickToBeat(c.length_ticks);
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
            self.flattenClipAutomation(@intCast(i), lane);
        }
    }

    /// Flatten one track's clips' gain/pan/synth-param breakpoints (clip-
    /// relative beats) into absolute-song-beat curves and push them to the
    /// engine. Runs for every instrument kind - a drum/slicer/empty track's
    /// `synth_params` list is simply always empty (the automation editor's
    /// picker only offers poly_synth/sampler tracks a param to automate),
    /// so this loop needs no extra guard. Clips are already stored start_bar-ascending
    /// (`Lane.place`) and each clip's own points are beat-ascending
    /// (`automation.setPoint`), so appending in clip order needs no extra sort.
    fn flattenClipAutomation(self: *Session, track: u16, lane: *arr_mod.Lane) void {
        var gain_pts: [automation_mod.max_points]AutomationPoint = undefined;
        var gain_n: usize = 0;
        var pan_pts: [automation_mod.max_points]AutomationPoint = undefined;
        var pan_n: usize = 0;

        // Distinct synth param ids used anywhere in this lane, first-seen
        // order, capped at max_synth_slots - matches the engine's own
        // per-track slot bank exactly (Engine.setTrackSynthParam silently
        // drops any param past it, so collecting more here is wasted work).
        var param_ids: [engine_mod.max_synth_slots]u8 = undefined;
        var param_n: usize = 0;
        var param_pts: [engine_mod.max_synth_slots][automation_mod.max_points]AutomationPoint = undefined;
        var param_pt_n: [engine_mod.max_synth_slots]usize = [_]usize{0} ** engine_mod.max_synth_slots;

        for (lane.clips.items) |c| {
            const clip_start_beat = time_grid.tickToBeat(c.start_tick);
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
            for (c.automation.synth_params.items) |sp| {
                var slot: ?usize = null;
                for (param_ids[0..param_n], 0..) |pid, idx| {
                    // zig fmt: off
                    if (pid == sp.param_id) { slot = idx; break; }
                    // zig fmt: on
                }
                if (slot == null) {
                    if (param_n >= param_ids.len) continue; // slot cap reached - drop, matches engine's own cap
                    param_ids[param_n] = sp.param_id;
                    slot = param_n;
                    param_n += 1;
                }
                const s = slot.?;
                for (sp.points) |p| {
                    if (param_pt_n[s] >= param_pts[s].len) break;
                    // Already the unit PolySynth.setParamAbsolute expects
                    // (Hz for cutoff, etc.) - no conversion needed, unlike
                    // gain's dB->linear.
                    param_pts[s][param_pt_n[s]] = .{ .beat = clip_start_beat + p.beat, .value = p.value };
                    param_pt_n[s] += 1;
                }
            }
        }
        self.engine.setTrackAutomation(track, .gain, gain_pts[0..gain_n]);
        self.engine.setTrackAutomation(track, .pan, pan_pts[0..pan_n]);
        // Clear every slot first - a param removed from every clip since the
        // last rebuild must not linger in a stale slot forever.
        self.engine.clearTrackSynthParams(track);
        for (param_ids[0..param_n], 0..) |pid, idx| {
            self.engine.setTrackSynthParam(track, pid, param_pts[idx][0..param_pt_n[idx]]);
        }
    }

    /// Whole bars needed to hold `len_beats`, at least one.
    fn barsFor(len_beats: f64, beats_per_bar: f64) u32 {
        if (len_beats <= 0 or beats_per_bar <= 0) return 1;
        return @max(1, @as(u32, @intFromFloat(@ceil(len_beats / beats_per_bar))));
    }

    pub fn deinit(self: *Session) void {
        self.master_fx.deinit(self.allocator);
        for (&self.groups) |*slot| if (slot.*) |*g| g.deinit(self.allocator);
        self.arrangement.deinit(self.allocator);
        // zig fmt: off
        for (self.racks.items) |r| { r.deinit(self.allocator); self.allocator.destroy(r); }
        self.racks.deinit(self.allocator);
        for (self.retired_racks.items) |r| { r.deinit(self.allocator); self.allocator.destroy(r); }
        // zig fmt: on
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

    try s.setInstrument(0, .slicer);
    try std.testing.expectEqual(rack_mod.InstrumentKind.slicer, std.meta.activeTag(s.racks.items[0].instrument));
    try std.testing.expect(s.racks.items[0].pattern_player == null); // own step grid, not piano-roll sequenced

    // Chains stay live and renderable after each swap.
    _ = s.engine.send(.play);
    var block: [128]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block);
}

test "slicer instrument: slices into the engine chain and triggers audibly" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .slicer);

    const sl = &s.racks.items[0].instrument.slicer;
    std.testing.allocator.free(sl.samples);
    sl.samples = try std.testing.allocator.alloc(f32, 1024);
    @memset(sl.samples, 0.5);
    for (&sl.slices) |*p| p.samples = sl.samples;
    sl.sliceInto(8);
    try std.testing.expectEqual(@as(u8, 8), sl.slice_count);

    _ = s.engine.send(.{ .note_on = .{ .track = 0, .note = 3, .velocity = 1.0 } });
    var block: [512]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block);
    var peak: f32 = 0.0;
    for (block) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.001);
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
    try std.testing.expectEqualStrings("untitled track copy", dup.name);
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
    s.racks.items[0].instrument.sampler.setSamples(
        try std.testing.allocator.dupe(f32, &[_]f32{ 0.25, -0.25 }),
        "test",
    );
    const idx = try s.duplicateTrack(0);

    const orig_samples = s.racks.items[0].instrument.sampler.pad.samples;
    const dup_samples = s.racks.items[idx].instrument.sampler.pad.samples;
    try std.testing.expect(orig_samples.ptr != dup_samples.ptr);
    try std.testing.expectEqualSlices(f32, orig_samples, dup_samples);

    try s.setInstrument(0, .drum_machine);
    const drum_idx = try s.duplicateTrack(0);
    const orig_pad = s.racks.items[0].instrument.drum_machine.pads[0].?.pad;
    const dup_pad = s.racks.items[drum_idx].instrument.drum_machine.pads[0].?.pad;
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
    try std.testing.expectEqual(@as(u32, 256), clip.start_tick);
    try std.testing.expectEqual(@as(u32, 256), clip.length_ticks);
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

    // Edge-resize the clip to 3 bars - 3x the captured pattern's length -
    // the same operation editors/arrangement.zig's resizeClip performs.
    const lane = s.arrangement.lane(0).?;
    lane.clips.items[0].length_ticks = 384;

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
    dm.setStepVel(1, 2, 63); // at ~50% velocity

    try s.stampClip(0, 0); // stamps B (active) - spans bars 0-1 (32 steps = 2 bars)
    dm.selectVariant(0);
    try s.stampClip(0, 2); // stamps A - bar 2, past B's span so it isn't evicted

    const lane = s.arrangement.lane(0).?;
    const b = lane.clips.items[0].content.drum;
    const a = lane.clips.items[1].content.drum;
    try std.testing.expectEqual(@as(u8, 1), b.variant);
    try std.testing.expectEqual(@as(u32, 1 << 2), b.pattern[1]);
    try std.testing.expectEqual(@as(u8, 63), b.vel[1][2]); // 50% carried
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
    try std.testing.expectEqual(@as(u32, 128), dm.song_clips[0].start_step);
    // The clip's own pattern is 32 steps (2 bars) - the new default.
    try std.testing.expectEqual(@as(u32, 256), dm.song_clips[0].span_steps);
    try std.testing.expectEqual(@as(u32, 1), dm.song_clips[0].pattern[0]);
    // Arrangement spans bars 0..3 (clip covers bars 1-2) → 48 steps.
    try std.testing.expectEqual(@as(u32, 384), dm.song_length_steps);
}

test "split drum track creates sampler MIDI tracks and arrangement clips" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .drum_machine);
    const dm = &s.racks.items[0].instrument.drum_machine;
    dm.toggleStep(0, 1);
    dm.setStepVel(0, 1, 95);
    try s.stampClip(0, 1);

    const count = try s.splitDrumTrack(0);
    try std.testing.expectEqual(@as(u8, 8), count);
    try std.testing.expectEqual(@as(usize, 8), s.racks.items.len);
    try std.testing.expect(s.racks.items[0].instrument == .sampler);
    const pp = &s.racks.items[0].pattern_player.?;
    const hit = pp.noteAt(pp.notes[0].pitch, 0.25).?;
    try std.testing.expectApproxEqAbs(@as(f32, 95.0 / 127.0), hit.velocity, 1e-6);
    const clip = s.arrangement.lane(0).?.clips.items[0];
    try std.testing.expectEqual(@as(u32, 128), clip.start_tick);
    try std.testing.expectEqual(@as(usize, 1), clip.content.melodic.notes.len);
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

test "syncTrackChain pushes a compressor's sidechain_source to the engine, parallel to the chain" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .poly_synth);
    const rack = s.racks.items[0];

    // Chain slot order: pattern_player(0), instrument(1), then FX from slot 2.
    const comp_unit = try rack.fx.insert(s.allocator, 0, .comp, s.project.sample_rate);
    comp_unit.payload.comp.sidechain_source = .{ .track = 5 };
    s.syncTrackChain(0, rack);

    const slots = s.engine.track_sidechain[0];
    try std.testing.expectEqual(@as(?Compressor.SidechainSource, null), slots[0]); // pattern_player
    try std.testing.expectEqual(@as(?Compressor.SidechainSource, null), slots[1]); // instrument
    try std.testing.expectEqual(@as(u16, 5), slots[2].?.track); // the compressor

    // Clearing it and re-syncing clears the routing too, not just leftover state.
    comp_unit.payload.comp.sidechain_source = null;
    s.syncTrackChain(0, rack);
    try std.testing.expectEqual(@as(?Compressor.SidechainSource, null), s.engine.track_sidechain[0][2]);
}

test "syncTrackChain pushes a compressor's sidechain pad routing to the engine too" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .drum_machine);
    const rack = s.racks.items[0];

    // No pattern_player for a drum machine - instrument at slot 0, comp at 1.
    const comp_unit = try rack.fx.insert(s.allocator, 0, .comp, s.project.sample_rate);
    comp_unit.payload.comp.sidechain_source = .{ .track = 4, .pad = 2 };
    s.syncTrackChain(0, rack);

    const slot = s.engine.track_sidechain[0][1].?;
    try std.testing.expectEqual(@as(u16, 4), slot.track);
    try std.testing.expectEqual(@as(?u8, 2), slot.pad);
}

test "syncMasterChain and syncGroupChain push sidechain routing too" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();

    const master_comp = try s.master_fx.insert(s.allocator, 0, .comp, s.project.sample_rate);
    master_comp.payload.comp.sidechain_source = .{ .track = 2 };
    s.syncMasterChain();
    try std.testing.expectEqual(@as(u16, 2), s.engine.master_sidechain_sources[0].?.track);

    const idx = try s.addGroup("bus");
    const group_comp = try s.groups[idx].?.fx.insert(s.allocator, 0, .comp, s.project.sample_rate);
    group_comp.payload.comp.sidechain_source = .{ .track = 3 };
    s.syncGroupChain(idx);
    try std.testing.expectEqual(@as(u16, 3), s.engine.groups[idx].sidechain_sources[0].?.track);
}

test "deleteTrack remaps other compressors' sidechain_source track indices" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    _ = try s.addTrack("kick"); // idx 1: the sidechain source
    _ = try s.addTrack("bass"); // idx 2: carries the compressor

    const rack = s.racks.items[2];
    const comp = try rack.fx.insert(s.allocator, 0, .comp, s.project.sample_rate);
    comp.payload.comp.sidechain_source = .{ .track = 1, .pad = 3 };
    s.syncTrackChain(2, rack);

    // Deleting track 0 shifts the source 1 -> 0 (and the consumer 2 -> 1);
    // the compressor must keep detecting from the same musical track, pad
    // untouched by the shift.
    try s.deleteTrack(0);
    try std.testing.expectEqual(@as(u16, 0), s.racks.items[1].fx.units.items[0].payload.comp.sidechain_source.?.track);
    try std.testing.expectEqual(@as(?u8, 3), s.racks.items[1].fx.units.items[0].payload.comp.sidechain_source.?.pad);
    try std.testing.expectEqual(@as(u16, 0), s.engine.track_sidechain[1][0].?.track);

    // Deleting the source itself clears the routing back to self-detection.
    try s.deleteTrack(0);
    try std.testing.expectEqual(@as(?Compressor.SidechainSource, null), s.racks.items[0].fx.units.items[0].payload.comp.sidechain_source);
    try std.testing.expectEqual(@as(?Compressor.SidechainSource, null), s.engine.track_sidechain[0][0]);
}

test "swapTracks follows a compressor's sidechain_source through the swap" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    _ = try s.addTrack("kick"); // idx 1: the sidechain source
    _ = try s.addTrack("bass"); // idx 2: carries the compressor

    const rack = s.racks.items[2];
    const comp = try rack.fx.insert(s.allocator, 0, .comp, s.project.sample_rate);
    comp.payload.comp.sidechain_source = .{ .track = 1 };
    s.syncTrackChain(2, rack);

    s.swapTracks(0, 1);
    try std.testing.expectEqual(@as(u16, 0), s.racks.items[2].fx.units.items[0].payload.comp.sidechain_source.?.track);
    try std.testing.expectEqual(@as(u16, 0), s.engine.track_sidechain[2][0].?.track);
}

test "addGroup/assignTrackGroup/deleteGroup: CRUD, membership, and engine sync" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    _ = try s.addTrack("second");

    const g = try s.addGroup("drums bus");
    try std.testing.expectEqualStrings("drums bus", s.groups[g].?.name);
    try std.testing.expect(s.engine.groups[g].active);

    s.assignTrackGroup(0, g);
    try std.testing.expectEqual(@as(?u8, g), s.project.tracks.items[0].group);
    var block: [128]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block); // set_track_group is queued; drain before checking the engine side
    try std.testing.expectEqual(@as(?u8, g), s.engine.tracks[0].group);
    // Track 1 stays ungrouped - assigning one track never touches another.
    try std.testing.expectEqual(@as(?u8, null), s.project.tracks.items[1].group);

    // Renaming and pushing an FX unit both reach the engine via syncGroupChain.
    try s.renameGroup(g, "drum bus");
    try std.testing.expectEqualStrings("drum bus", s.groups[g].?.name);
    _ = try s.groups[g].?.fx.insert(s.allocator, 0, .comp, s.project.sample_rate);
    s.syncGroupChain(g);
    try std.testing.expectEqual(@as(usize, 1), s.engine.groups[g].chain_len);

    // Deleting the group unassigns its members and marks the engine slot
    // inactive - track 0 falls back to the master mix, not a dangling index.
    s.deleteGroup(g);
    try std.testing.expectEqual(@as(?u8, null), s.project.tracks.items[0].group);
    s.engine.process(&block); // drain the unassign command deleteGroup queued
    try std.testing.expectEqual(@as(?u8, null), s.engine.tracks[0].group);
    try std.testing.expect(s.groups[g] == null);
    try std.testing.expect(!s.engine.groups[g].active);
}

test "addGroup fails once every slot is taken; assignTrackGroup rejects an unused slot" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();

    var i: u8 = 0;
    while (i < @import("audio/engine.zig").max_groups) : (i += 1) {
        _ = try s.addGroup("g");
    }
    try std.testing.expectError(error.GroupLimitReached, s.addGroup("one too many"));

    // A track pointed at a never-created group index resolves to ungrouped,
    // not a dangling reference - mirrors renderTracks's own fallback.
    s.deleteGroup(0);
    s.assignTrackGroup(0, 0);
    try std.testing.expectEqual(@as(?u8, null), s.project.tracks.items[0].group);
}

test "duplicateTrack carries color and group along with gain/pan/mute/solo" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    const g = try s.addGroup("bus");
    s.project.tracks.items[0].color = 3;
    s.assignTrackGroup(0, g);

    const dup = try s.duplicateTrack(0);
    try std.testing.expectEqual(@as(u8, 3), s.project.tracks.items[dup].color);
    try std.testing.expectEqual(@as(?u8, g), s.project.tracks.items[dup].group);
    var block: [128]@import("core/types.zig").Sample = undefined;
    s.engine.process(&block); // duplicateTrack's set_track_group is queued
    try std.testing.expectEqual(@as(?u8, g), s.engine.tracks[dup].group);
}

test "song-mode gain automation ramps a track's level down over the clip" {
    var s = try Session.initDefault(std.testing.allocator);
    defer s.deinit();
    try s.setInstrument(0, .poly_synth);

    // A held note spanning the whole clip so the synth's own envelope stays
    // at sustain level throughout - any amplitude change we measure comes
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

    // Seeking back to the start re-evaluates the curve from scratch - proves
    // it's a live function of transport position, not a one-way latch.
    _ = s.engine.send(.{ .seek_frames = 0 });
    var back_loud: f32 = 0.0;
    for (0..4) |_| {
        s.engine.process(&block);
        for (block) |v| back_loud = @max(back_loud, @abs(v));
    }
    try std.testing.expect(back_loud > loud * 0.5);
}

//! Song arrangement: per-track clips placed on an exact musical tick timeline.
//! See docs/arrangement-playback.md for the ownership and playback design.

const std = @import("std");
const Note = @import("dsp/pattern.zig").Note;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const automation_mod = @import("dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;

/// Slicer's own step-grid ceiling (`Slicer.max_steps`, unimported here to
/// avoid a cross-module dependency just for one constant) - `Clip.Drum`'s
/// `vel` field mirrors it directly rather than `DrumMachine.max_steps`,
/// since the two diverged once the drum machine's own ceiling grew.
const slicer_max_steps: u16 = 64;

/// A clip placed on a track lane. Positions use `time_grid.ticks_per_beat`.
pub const Clip = struct {
    start_tick: u32,
    length_ticks: u32,
    content: Content,
    /// Gain/pan automation for this clip's span, in clip-relative beats (0 =
    /// clip start). Independent of `content` - every clip kind (melodic or
    /// drum) can carry it, since gain/pan are track-level, not instrument
    /// params. Empty = no automation (the track plays at its manual gain/pan
    /// for this clip's whole span). See `Session.rebuildSongData`, which
    /// flattens every clip's points into one whole-song curve per track.
    automation: Automation = .{},

    /// One instrument-param automation lane: `param_id` matches whichever
    /// instrument the track holds' own `setParamAbsolute` id space -
    /// PolySynth's or Sampler's (the automation editor's picker gates
    /// offering these to poly_synth/sampler tracks only; a clip on any other
    /// track kind simply never gets an entry, no separate guard needed
    /// here). The field/type names here still say "synth" from when only
    /// PolySynth had automatable params - this storage was always just a
    /// param-id-keyed list, so extending it to Sampler needed no format
    /// change or rename.
    pub const SynthParamCurve = struct {
        param_id: u8,
        points: []AutomationPoint = &.{},
    };

    /// Gain (dB, same range as `:gain`/`Track.gain_db`) and pan (-1..1, same
    /// range as `Track.pan`) breakpoints, each independently optional, plus a
    /// sparse list of synth-instrument-param lanes (filter cutoff, LFO rate,
    /// envelope times, ...) - was a single dedicated `filter_cutoff` field,
    /// generalized to a growable list so any of PolySynth's ~30 continuous
    /// params can be automated per clip, not just cutoff (see dsp/synth.zig's
    /// `automatable_params`). Clips aren't multiplied across `max_tracks` the
    /// way the engine's live `AutomationPair` is, so a growable list here
    /// costs nothing extra unlike a fixed-size bank would in the engine.
    pub const Automation = struct {
        gain: []AutomationPoint = &.{},
        pan: []AutomationPoint = &.{},
        synth_params: std.ArrayListUnmanaged(SynthParamCurve) = .empty,

        pub fn deinit(self: *Automation, allocator: std.mem.Allocator) void {
            allocator.free(self.gain);
            allocator.free(self.pan);
            for (self.synth_params.items) |*sp| allocator.free(sp.points);
            self.synth_params.deinit(allocator);
        }

        pub fn dupe(self: Automation, allocator: std.mem.Allocator) !Automation {
            const gain = try allocator.dupe(AutomationPoint, self.gain);
            errdefer allocator.free(gain);
            const pan = try allocator.dupe(AutomationPoint, self.pan);
            errdefer allocator.free(pan);
            var synth_params: std.ArrayListUnmanaged(SynthParamCurve) = .empty;
            errdefer {
                for (synth_params.items) |*sp| allocator.free(sp.points);
                synth_params.deinit(allocator);
            }
            for (self.synth_params.items) |sp| {
                const points = try allocator.dupe(AutomationPoint, sp.points);
                synth_params.append(allocator, .{ .param_id = sp.param_id, .points = points }) catch |err| {
                    allocator.free(points);
                    return err;
                };
            }
            return .{ .gain = gain, .pan = pan, .synth_params = synth_params };
        }

        /// Read-only lookup - null if this param has no lane on this clip yet.
        pub fn findSynthParam(self: *const Automation, param_id: u8) ?[]const AutomationPoint {
            for (self.synth_params.items) |sp| {
                if (sp.param_id == param_id) return sp.points;
            }
            return null;
        }

        /// The mutable points-slice pointer for `param_id`, creating an empty
        /// lane for it first if none exists yet (the param picker's "start
        /// automating this" action) - same "own the pointer, mutate through
        /// it" shape `gain`/`pan` fields already offer via `&self.gain`.
        pub fn synthParamPoints(self: *Automation, allocator: std.mem.Allocator, param_id: u8) !*[]AutomationPoint {
            for (self.synth_params.items) |*sp| {
                if (sp.param_id == param_id) return &sp.points;
            }
            try self.synth_params.append(allocator, .{ .param_id = param_id });
            return &self.synth_params.items[self.synth_params.items.len - 1].points;
        }
    };

    /// The musical payload, mirroring the two sequenceable instrument families.
    pub const Content = union(enum) {
        melodic: Melodic,
        drum: Drum,
    };

    /// A private copy of a piano-roll pattern.
    pub const Melodic = struct {
        notes: []Note,
        /// Loop length of the captured pattern, in beats.
        length_beats: f64,
    };

    /// A private copy of a drum-machine (or slicer) pattern - the two share
    /// the same 64-row step-grid shape (`Slicer.max_slices ==
    /// DrumMachine.max_pads`), so slicer clips reuse this content kind
    /// wholesale rather than adding a third. `pattern`/`vel` are Slicer's own
    /// fixed-size bitmask+velocity data (Slicer keeps its own 64-step
    /// ceiling, independent of DrumMachine's); `midi` is the drum-machine's
    /// heap-owned per-pad note data (empty `&.{}` slices for a slicer stamp).
    /// Callers know which side is live from the source track's instrument
    /// kind, not from this struct - see `Session.stampClipAtTick`.
    pub const Drum = struct {
        pattern: [DrumMachine.max_pads]u64 = [_]u64{0} ** DrumMachine.max_pads,
        /// Per-step velocity (0-127; 127 = full, see DrumMachine.velGain) -
        /// Slicer's own fixed-size step data.
        vel: [DrumMachine.max_pads][slicer_max_steps]u8 =
            [_][slicer_max_steps]u8{[_]u8{DrumMachine.vel_full} ** slicer_max_steps} ** DrumMachine.max_pads,
        /// Drum-machine step data: heap-owned per-pad note slices, length ==
        /// step_count. `Clip.deinit`/`Clip.dupe` own freeing/duping this.
        midi: [DrumMachine.max_pads][]?DrumMachine.MidiNote =
            [_][]?DrumMachine.MidiNote{&.{}} ** DrumMachine.max_pads,
        step_count: u16,
        steps_per_beat: u8 = 4,
        /// Which variant (A..H) this was stamped from - display label only;
        /// the pattern/vel/midi above are the payload, so bank edits never
        /// reach clips.
        variant: u8 = 0,
    };

    /// Build a melodic clip, duplicating `notes` so the clip owns them.
    pub fn initMelodic(
        allocator: std.mem.Allocator,
        start_tick: u32,
        length_ticks: u32,
        notes: []const Note,
        length_beats: f64,
    ) !Clip {
        const owned = try allocator.dupe(Note, notes);
        const safe_start = @min(start_tick, std.math.maxInt(u32) - 1);
        const safe_length = @min(@max(1, length_ticks), std.math.maxInt(u32) - safe_start);
        const safe_length_beats = if (std.math.isFinite(length_beats))
            @max(1.0, length_beats)
        else
            1.0;
        return .{
            .start_tick = safe_start,
            .length_ticks = safe_length,
            .content = .{ .melodic = .{ .notes = owned, .length_beats = safe_length_beats } },
        };
    }

    /// Build a drum clip from a copied payload. No allocation - the caller
    /// has already built `drum.midi`'s slices (if any); this just moves the
    /// already-owned struct into place.
    pub fn initDrum(start_tick: u32, length_ticks: u32, drum: Drum) Clip {
        const safe_start = @min(start_tick, std.math.maxInt(u32) - 1);
        return .{
            .start_tick = safe_start,
            .length_ticks = @min(@max(1, length_ticks), std.math.maxInt(u32) - safe_start),
            .content = .{ .drum = drum },
        };
    }

    pub fn deinit(self: *Clip, allocator: std.mem.Allocator) void {
        switch (self.content) {
            .melodic => |m| allocator.free(m.notes),
            .drum => |*d| DrumMachine.freeMidi(allocator, &d.midi),
        }
        self.automation.deinit(allocator);
    }

    /// Deep copy: melodic notes get a fresh allocation, drum payloads dupe
    /// their heap-owned `midi` slices (`pattern`/`vel` stay plain values),
    /// automation points get a fresh allocation either way. Used by clip
    /// yank/paste and the undo lane snapshots.
    pub fn dupe(self: Clip, allocator: std.mem.Allocator) !Clip {
        var out: Clip = switch (self.content) {
            .melodic => |m| try initMelodic(
                // zig fmt: off
                allocator, self.start_tick, self.length_ticks, m.notes, m.length_beats,
                // zig fmt: on
            ),
            .drum => |d| blk: {
                var copy = d;
                copy.midi = try DrumMachine.dupeMidi(allocator, &d.midi);
                break :blk initDrum(self.start_tick, self.length_ticks, copy);
            },
        };
        errdefer out.deinit(allocator);
        out.automation = try self.automation.dupe(allocator);
        return out;
    }

    pub fn endTick(self: Clip) u32 {
        return self.start_tick +| self.length_ticks;
    }

    pub fn covers(self: Clip, tick: u32) bool {
        return tick >= self.start_tick and tick < self.endTick();
    }

    fn overlaps(self: Clip, start: u32, end: u32) bool {
        return self.start_tick < end and start < self.endTick();
    }
};

/// One track's clips, kept sorted by `start_bar` and non-overlapping.
pub const Lane = struct {
    clips: std.ArrayListUnmanaged(Clip) = .empty,

    pub fn deinit(self: *Lane, allocator: std.mem.Allocator) void {
        for (self.clips.items) |*c| c.deinit(allocator);
        self.clips.deinit(allocator);
    }

    /// Insert `clip`, first removing any existing clip it overlaps. Keeps the
    /// list sorted by `start_bar`. Takes ownership of the clip's content -
    /// including on failure, when the content is freed.
    pub fn place(self: *Lane, allocator: std.mem.Allocator, clip: Clip) !void {
        self.clips.ensureUnusedCapacity(allocator, 1) catch |err| {
            var owned = clip;
            owned.deinit(allocator);
            return err;
        };
        const start = clip.start_tick;
        const end = clip.endTick();
        var i: usize = 0;
        while (i < self.clips.items.len) {
            if (self.clips.items[i].overlaps(start, end)) {
                var removed = self.clips.orderedRemove(i);
                removed.deinit(allocator);
            } else i += 1;
        }
        // Insert at the first clip starting after `start`.
        var idx: usize = self.clips.items.len;
        for (self.clips.items, 0..) |c, j| {
            if (c.start_tick > start) {
                idx = j;
                break;
            }
        }
        self.clips.insertAssumeCapacity(idx, clip);
    }

    /// Remove the clip covering `bar`, if any. Returns true if one was removed.
    pub fn removeAt(self: *Lane, allocator: std.mem.Allocator, bar: u32) bool {
        for (self.clips.items, 0..) |c, i| {
            if (c.covers(bar)) {
                var removed = self.clips.orderedRemove(i);
                removed.deinit(allocator);
                return true;
            }
        }
        return false;
    }

    /// Pointer to the clip covering `bar`, or null.
    pub fn clipAt(self: *Lane, bar: u32) ?*Clip {
        for (self.clips.items) |*c| {
            if (c.covers(bar)) return c;
        }
        return null;
    }

    /// Remove every clip (e.g. when a track's instrument kind changes).
    pub fn clear(self: *Lane, allocator: std.mem.Allocator) void {
        for (self.clips.items) |*c| c.deinit(allocator);
        self.clips.clearRetainingCapacity();
    }

    /// Remove `[lo, hi)` from every clip it touches: a clip fully inside the
    /// range is deleted outright, a clip the range only clips one edge of is
    /// trimmed to whatever's left outside the range, and a clip the range
    /// cuts clean through the middle of is split into a left and right
    /// remainder - the right one `dupe`d off the original (content
    /// re-triggers its own loop from its own start on the new span, same as
    /// every other resize/move already does; see `dupe`). `hi` is exclusive,
    /// so `(bar_tick, bar_tick + grid.ticks())` removes exactly one grid
    /// cell out of whatever clip sits under it, instead of the whole clip.
    pub fn cutRange(self: *Lane, allocator: std.mem.Allocator, lo: u32, hi: u32) !void {
        if (hi <= lo) return;
        var i: usize = 0;
        while (i < self.clips.items.len) {
            const c = &self.clips.items[i];
            const start = c.start_tick;
            const end = c.endTick();
            if (end <= lo or start >= hi) {
                i += 1;
                continue;
            }
            if (start >= lo and end <= hi) {
                var removed = self.clips.orderedRemove(i);
                removed.deinit(allocator);
                continue; // next clip just shifted into position i
            }
            if (start < lo and end > hi) {
                // The cut is a strict interior range: split into two clips.
                // Dupe (which only reads c) and mutate c's length before the
                // insert below, which can reallocate and invalidate `c`.
                var right = try c.dupe(allocator);
                self.clips.ensureUnusedCapacity(allocator, 1) catch |err| {
                    right.deinit(allocator);
                    return err;
                };
                right.start_tick = hi;
                right.length_ticks = end - hi;
                c.length_ticks = lo - start;
                self.clips.insertAssumeCapacity(i + 1, right);
                i += 2;
                continue;
            }
            if (start < lo) {
                c.length_ticks = lo - start; // trim the tail
            } else {
                c.length_ticks = end - hi; // trim the head
                c.start_tick = hi;
            }
            i += 1;
        }
    }

    /// First bar past the last clip - the lane's content length in bars.
    pub fn lengthTicks(self: *const Lane) u32 {
        var end: u32 = 0;
        for (self.clips.items) |c| end = @max(end, c.endTick());
        return end;
    }
};

/// Per-track lanes, kept parallel to the project's tracks.
pub const Arrangement = struct {
    lanes: std.ArrayListUnmanaged(Lane) = .empty,

    pub fn deinit(self: *Arrangement, allocator: std.mem.Allocator) void {
        for (self.lanes.items) |*l| l.deinit(allocator);
        self.lanes.deinit(allocator);
    }

    /// Append a blank lane (mirrors Session.addTrack).
    pub fn addLane(self: *Arrangement, allocator: std.mem.Allocator) !void {
        try self.lanes.append(allocator, .{});
    }

    /// Insert a blank lane at `index`, shifting later lanes right (mirrors
    /// Session.insertTrack).
    pub fn insertLane(self: *Arrangement, allocator: std.mem.Allocator, index: usize) !void {
        try self.lanes.insert(allocator, index, .{});
    }

    /// Remove the lane at `index` (mirrors Session.deleteTrack).
    pub fn removeLane(self: *Arrangement, allocator: std.mem.Allocator, index: usize) void {
        if (index >= self.lanes.items.len) return;
        var removed = self.lanes.orderedRemove(index);
        removed.deinit(allocator);
    }

    pub fn lane(self: *Arrangement, index: usize) ?*Lane {
        if (index >= self.lanes.items.len) return null;
        return &self.lanes.items[index];
    }

    /// Swap two lanes' positions (mirrors Session.swapTracks). No allocation.
    pub fn swapLanes(self: *Arrangement, a: usize, b: usize) void {
        if (a >= self.lanes.items.len or b >= self.lanes.items.len) return;
        std.mem.swap(Lane, &self.lanes.items[a], &self.lanes.items[b]);
    }

    /// Song length in bars: the longest lane.
    pub fn lengthTicks(self: *const Arrangement) u32 {
        var end: u32 = 0;
        for (self.lanes.items) |l| end = @max(end, l.lengthTicks());
        return end;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "place inserts sorted and reports lane length" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);

    try lane.place(a, Clip.initDrum(4, 2, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try lane.place(a, Clip.initDrum(0, 2, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try lane.place(a, Clip.initDrum(2, 2, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));

    try testing.expectEqual(@as(usize, 3), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 0), lane.clips.items[0].start_tick);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[1].start_tick);
    try testing.expectEqual(@as(u32, 4), lane.clips.items[2].start_tick);
    try testing.expectEqual(@as(u32, 6), lane.lengthTicks());
}

test "place evicts overlapping clips" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);

    // A 4-bar clip at 0, then a 2-bar clip at 2 must evict the first.
    try lane.place(a, Clip.initDrum(0, 4, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try lane.place(a, Clip.initDrum(2, 2, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));

    try testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[0].start_tick);
}

test "clip constructors enforce non-empty lengths" {
    const a = testing.allocator;
    var melodic = try Clip.initMelodic(a, 0, 0, &.{}, 0.0);
    defer melodic.deinit(a);
    try testing.expectEqual(@as(u32, 1), melodic.length_ticks);
    try testing.expectEqual(@as(f64, 1.0), melodic.content.melodic.length_beats);

    const drum = Clip.initDrum(0, 0, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 });
    try testing.expectEqual(@as(u32, 1), drum.length_ticks);
}

test "clip end and lane length saturate at the timeline limit" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(std.math.maxInt(u32) - 1, 4, .{
        .pattern = [_]u64{0} ** DrumMachine.max_pads,
        .step_count = 16,
    }));
    try testing.expectEqual(std.math.maxInt(u32), lane.clips.items[0].endTick());
    try testing.expectEqual(std.math.maxInt(u32), lane.lengthTicks());
}

test "melodic clip replaces non-finite beat length" {
    var clip = try Clip.initMelodic(testing.allocator, 0, 1, &.{}, std.math.nan(f64));
    defer clip.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 1.0), clip.content.melodic.length_beats);
}

test "clipAt and removeAt cover the clip's whole span" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);

    try lane.place(a, Clip.initDrum(1, 3, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try testing.expect(lane.clipAt(0) == null);
    try testing.expect(lane.clipAt(1) != null);
    try testing.expect(lane.clipAt(3) != null);
    try testing.expect(lane.clipAt(4) == null);

    try testing.expect(!lane.removeAt(a, 0));
    try testing.expect(lane.removeAt(a, 3));
    try testing.expectEqual(@as(usize, 0), lane.clips.items.len);
}

test "clip dupe deep-copies automation independently of content kind" {
    const a = testing.allocator;
    var src = Clip.initDrum(0, 2, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 });
    var gain: []AutomationPoint = &.{};
    try automation_mod.setPoint(a, &gain, 0.0, -6.0);
    src.automation.gain = gain;
    defer src.deinit(a);

    var copy = try src.dupe(a);
    defer copy.deinit(a);

    try testing.expect(copy.automation.gain.ptr != src.automation.gain.ptr);
    try testing.expectApproxEqAbs(@as(f32, -6.0), copy.automation.gain[0].value, 1e-6);

    // Mutating the source's points must not affect the copy.
    src.automation.gain[0].value = 0.0;
    try testing.expectApproxEqAbs(@as(f32, -6.0), copy.automation.gain[0].value, 1e-6);
}

test "clip dupe deep-copies drum midi notes independently" {
    const a = testing.allocator;
    var midi = try DrumMachine.allocMidi(a, 4);
    midi[0][1] = DrumMachine.gridNote(0, 1, 95);
    var src = Clip.initDrum(0, 2, .{ .midi = midi, .step_count = 4 });
    defer src.deinit(a);

    var copy = try src.dupe(a);
    defer copy.deinit(a);

    try testing.expect(copy.content.drum.midi[0][1].?.velocity == 95);
    try testing.expect(copy.content.drum.midi[0].ptr != src.content.drum.midi[0].ptr);

    // Mutating the source's notes must not affect the copy.
    src.content.drum.midi[0][1] = null;
    try testing.expect(copy.content.drum.midi[0][1] != null);
}

test "melodic clip owns a private note copy" {
    const a = testing.allocator;
    var src = [_]Note{.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 }};
    var clip = try Clip.initMelodic(a, 0, 1, &src, 4.0);
    defer clip.deinit(a);

    src[0].pitch = 0; // mutate the source after capture
    try testing.expectEqual(@as(u7, 60), clip.content.melodic.notes[0].pitch);
}

test "clip constructors keep the end tick representable" {
    const drum = Clip.initDrum(std.math.maxInt(u32), 128, .{
        .pattern = [_]u64{0} ** DrumMachine.max_pads,
        .step_count = 16,
    });
    try testing.expectEqual(std.math.maxInt(u32) - 1, drum.start_tick);
    try testing.expectEqual(@as(u32, 1), drum.length_ticks);
    try testing.expectEqual(std.math.maxInt(u32), drum.endTick());

    var melodic = try Clip.initMelodic(testing.allocator, std.math.maxInt(u32) - 8, 128, &.{}, 4.0);
    defer melodic.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 8), melodic.length_ticks);
    try testing.expectEqual(std.math.maxInt(u32), melodic.endTick());
}

test "cutRange removes a clip fully inside the cut" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(2, 2, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));

    try lane.cutRange(a, 0, 8);
    try testing.expectEqual(@as(usize, 0), lane.clips.items.len);
}

test "cutRange trims the tail of a clip overlapping the cut's start" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(0, 4, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));

    try lane.cutRange(a, 2, 6);
    try testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 0), lane.clips.items[0].start_tick);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[0].length_ticks);
}

test "cutRange trims the head of a clip overlapping the cut's end" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(4, 4, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));

    try lane.cutRange(a, 0, 6);
    try testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 6), lane.clips.items[0].start_tick);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[0].length_ticks);
}

test "cutRange splits a clip the cut passes clean through the middle of" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    // A 4-bar clip (ticks 0-4), cutting out bar 2 (ticks 2-3) should leave
    // a 2-tick left remainder and a 1-tick right remainder.
    try lane.place(a, Clip.initDrum(0, 4, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));

    try lane.cutRange(a, 2, 3);
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 0), lane.clips.items[0].start_tick);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[0].length_ticks);
    try testing.expectEqual(@as(u32, 3), lane.clips.items[1].start_tick);
    try testing.expectEqual(@as(u32, 1), lane.clips.items[1].length_ticks);
}

test "cutRange leaves clips outside the range untouched and no-ops on an empty range" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(0, 2, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try lane.place(a, Clip.initDrum(10, 2, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));

    try lane.cutRange(a, 4, 6);
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);

    try lane.cutRange(a, 5, 5);
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);
}

test "arrangement adds and removes lanes" {
    const a = testing.allocator;
    var arr: Arrangement = .{};
    defer arr.deinit(a);

    try arr.addLane(a);
    try arr.addLane(a);
    try arr.lane(0).?.place(a, Clip.initDrum(0, 5, .{ .pattern = [_]u64{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try testing.expectEqual(@as(u32, 5), arr.lengthTicks());

    arr.removeLane(a, 0);
    try testing.expectEqual(@as(usize, 1), arr.lanes.items.len);
    try testing.expectEqual(@as(u32, 0), arr.lengthTicks());
}

test "swapLanes ignores invalid indices" {
    const a = testing.allocator;
    var arrangement: Arrangement = .{};
    defer arrangement.deinit(a);
    try arrangement.addLane(a);

    arrangement.swapLanes(0, 99);
    try testing.expectEqual(@as(usize, 1), arrangement.lanes.items.len);
}

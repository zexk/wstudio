//! Song arrangement: per-track clips placed on an exact musical tick timeline.
//! See docs/arrangement-playback.md for the ownership and playback design.

const std = @import("std");
const Note = @import("dsp/pattern.zig").Note;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const time_grid = @import("time_grid.zig");
const automation_mod = @import("dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;
pub const max_audio_takes: usize = 8;

pub const FadeCurve = enum { linear, equal_power };

pub fn fadeGain(progress: f32, curve: FadeCurve) f32 {
    const t = std.math.clamp(progress, 0.0, 1.0);
    return switch (curve) {
        .linear => t,
        .equal_power => @sin(t * std.math.pi / 2.0),
    };
}

pub fn audioSourceFrame(start: u64, length: u64, offset: u64, reverse: bool) ?u64 {
    if (offset >= length) return null;
    const relative = if (reverse) length - offset - 1 else offset;
    return std.math.add(u64, start, relative) catch null;
}

test "equal-power crossfade keeps summed power constant" {
    for (0..11) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 10.0;
        const a = fadeGain(t, .equal_power);
        const b = fadeGain(1.0 - t, .equal_power);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), a * a + b * b, 1e-5);
    }
}

test "audio source frame rejects range and integer overflow" {
    try std.testing.expectEqual(@as(?u64, 12), audioSourceFrame(10, 4, 2, false));
    try std.testing.expectEqual(@as(?u64, 11), audioSourceFrame(10, 4, 2, true));
    try std.testing.expectEqual(@as(?u64, null), audioSourceFrame(10, 4, 4, false));
    try std.testing.expectEqual(@as(?u64, null), audioSourceFrame(std.math.maxInt(u64), 2, 1, false));
    try std.testing.expectEqual(@as(?u64, null), audioSourceFrame(std.math.maxInt(u64), 2, 0, true));
}

/// A clip placed on a track lane. Positions use `time_grid.ticks_per_beat`.
pub const Clip = struct {
    start_tick: u32,
    length_ticks: u32,
    layer: u8 = 0,
    content: Content,
    /// Gain/pan automation for this clip's span, in clip-relative beats (0 =
    /// clip start). Independent of `content` - every clip kind (melodic or
    /// drum) can carry it, since gain/pan are track-level, not instrument
    /// params. Empty = no automation (the track plays at its manual gain/pan
    /// for this clip's whole span). See `Session.rebuildSongData`, which
    /// flattens every clip's points into one whole-song curve per track.
    automation: Automation = .{},

    /// One instrument- or FX-unit-param automation lane. `instance_id` = 0
    /// (the default, and the only value pre-item-2 files ever had) targets
    /// the track's own instrument, whose `setParamAbsolute` id space
    /// `param_id` indexes - PolySynth's or Sampler's (the automation
    /// editor's picker gates offering these to poly_synth/sampler tracks
    /// only; a clip on any other track kind simply never gets an entry, no
    /// separate guard needed here). A nonzero `instance_id` targets a
    /// specific `FxUnit` in the track's rack instead, and `param_id` is then
    /// a local index into that unit's own `dsp.fx_params` table - the same
    /// `{instance_id, param_id}` shape the PolySynth mod-matrix already uses
    /// for `fx_mod_bus`/`fx_instance_id` (0 is never allocated as a real
    /// instance id - see `Fx.allocInstanceId` - so it's a safe sentinel for
    /// "the instrument, not an FX unit"). The field/type names here still
    /// say "synth" from when only PolySynth had automatable params - this
    /// storage was always just an id-keyed list, so extending it needed no
    /// format change or rename.
    pub const SynthParamCurve = struct {
        instance_id: u32 = 0,
        param_id: u32,
        points: []AutomationPoint = &.{},
    };

    /// Gain (dB, same range as `:gain`/`Track.gain_db`) and pan (-1..1, same
    /// range as `Track.pan`) breakpoints, each independently optional, plus a
    /// sparse list of synth-instrument-param lanes (filter cutoff, LFO rate,
    /// envelope times, ...) - was a single dedicated `filter_cutoff` field,
    /// generalized to a growable list so any of PolySynth's ~30 continuous
    /// params can be automated per clip, not just cutoff (see dsp/synth.zig's
    /// `automatable_params`). Clips aren't multiplied across `max_tracks` the
    /// way the engine's live `TrackAutomation` is, so a growable list here
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

        /// Slide every curve back by `beats`, for a clip that just lost that
        /// much off its front. Points now before the clip start keep their
        /// slot at beat 0 rather than being dropped: they are what the curve
        /// held at the cut, and `dsp.automation.interpolate` reads the last
        /// point at or before a beat, so removing them would leave the
        /// remainder starting from the wrong value.
        pub fn dropFront(self: *Automation, beats: f64) void {
            if (beats <= 0) return;
            for ([_][]AutomationPoint{ self.gain, self.pan }) |curve| shiftPoints(curve, beats);
            for (self.synth_params.items) |sp| shiftPoints(sp.points, beats);
        }

        fn shiftPoints(points: []AutomationPoint, beats: f64) void {
            for (points) |*point| point.beat = @max(0, point.beat - beats);
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
                synth_params.append(allocator, .{ .instance_id = sp.instance_id, .param_id = sp.param_id, .points = points }) catch |err| {
                    allocator.free(points);
                    return err;
                };
            }
            return .{ .gain = gain, .pan = pan, .synth_params = synth_params };
        }

        /// Read-only lookup - null if this param has no lane on this clip yet.
        pub fn findSynthParam(self: *const Automation, instance_id: u32, param_id: u32) ?[]const AutomationPoint {
            for (self.synth_params.items) |sp| {
                if (sp.instance_id == instance_id and sp.param_id == param_id) return sp.points;
            }
            return null;
        }

        /// The mutable points-slice pointer for `param_id`, creating an empty
        /// lane for it first if none exists yet (the param picker's "start
        /// automating this" action) - same "own the pointer, mutate through
        /// it" shape `gain`/`pan` fields already offer via `&self.gain`.
        pub fn synthParamPoints(self: *Automation, allocator: std.mem.Allocator, instance_id: u32, param_id: u32) !*[]AutomationPoint {
            for (self.synth_params.items) |*sp| {
                if (sp.instance_id == instance_id and sp.param_id == param_id) return &sp.points;
            }
            try self.synth_params.append(allocator, .{ .instance_id = instance_id, .param_id = param_id });
            return &self.synth_params.items[self.synth_params.items.len - 1].points;
        }
    };

    /// The musical payload, mirroring the two sequenceable instrument families.
    pub const Content = union(enum) {
        melodic: Melodic,
        drum: Drum,
        audio: AudioRegion,
    };

    pub const AudioRegion = struct {
        pub const Take = struct {
            source_id: u32,
            source_start_frame: u64,
            source_length_frames: u64,
            length_ticks: u32,
        };

        source_id: u32,
        source_start_frame: u64,
        source_length_frames: u64,
        gain_db: f32 = 0.0,
        fade_in_frames: u64 = 0,
        fade_out_frames: u64 = 0,
        fade_curve: FadeCurve = .linear,
        stretch_ratio: f32 = 1.0,
        reverse: bool = false,
        alternate_takes: [max_audio_takes - 1]?Take = @splat(null),

        pub fn takeCount(self: AudioRegion) usize {
            var count: usize = 1;
            for (self.alternate_takes) |take| count += @intFromBool(take != null);
            return count;
        }
    };

    /// A private copy of a piano-roll pattern.
    pub const Melodic = struct {
        notes: []Note,
        /// Loop length of the captured pattern, in beats.
        length_beats: f64,
    };

    /// A private copy of a drum-machine (or slicer) pattern - the two share
    /// the same 64-row step-grid shape (`Slicer.max_slices ==
    /// DrumMachine.max_pads`) and, since the slicer moved to the same note
    /// storage, the same payload type, so slicer clips reuse this content
    /// kind wholesale rather than adding a third.
    pub const Drum = struct {
        /// Step data: heap-owned per-row note slices, length == step_count.
        /// `Clip.deinit`/`Clip.dupe` own freeing/duping this.
        midi: [DrumMachine.max_pads][]?DrumMachine.MidiNote =
            [_][]?DrumMachine.MidiNote{&.{}} ** DrumMachine.max_pads,
        step_count: u16,
        steps_per_beat: u8 = 4,
        /// Which variant (A..H) this was stamped from - display label only;
        /// `midi` above is the payload, so bank edits never reach clips.
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

    pub fn initAudio(start_tick: u32, length_ticks: u32, region: AudioRegion) Clip {
        const safe_start = @min(start_tick, std.math.maxInt(u32) - 1);
        return .{
            .start_tick = safe_start,
            .length_ticks = @min(@max(1, length_ticks), std.math.maxInt(u32) - safe_start),
            .content = .{ .audio = region },
        };
    }

    pub fn deinit(self: *Clip, allocator: std.mem.Allocator) void {
        switch (self.content) {
            .melodic => |m| allocator.free(m.notes),
            .drum => |*d| DrumMachine.freeMidi(allocator, &d.midi),
            .audio => {},
        }
        self.automation.deinit(allocator);
    }

    /// Deep copy: melodic notes get a fresh allocation, drum payloads dupe
    /// their heap-owned `midi` rows, automation points get a fresh
    /// allocation either way. Used by clip yank/paste and the undo lane
    /// snapshots.
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
            .audio => |audio| initAudio(self.start_tick, self.length_ticks, audio),
        };
        errdefer out.deinit(allocator);
        out.automation = try self.automation.dupe(allocator);
        return out;
    }

    pub fn endTick(self: Clip) u32 {
        return self.start_tick +| self.length_ticks;
    }

    pub fn addAudioTake(self: *Clip, take: AudioRegion.Take) bool {
        switch (self.content) {
            .audio => {},
            else => return false,
        }
        const audio = &self.content.audio;
        for (&audio.alternate_takes) |*slot| {
            if (slot.* != null) continue;
            slot.* = .{ .source_id = audio.source_id, .source_start_frame = audio.source_start_frame, .source_length_frames = audio.source_length_frames, .length_ticks = self.length_ticks };
            audio.source_id = take.source_id;
            audio.source_start_frame = take.source_start_frame;
            audio.source_length_frames = take.source_length_frames;
            self.length_ticks = take.length_ticks;
            return true;
        }
        audio.alternate_takes[0] = .{ .source_id = audio.source_id, .source_start_frame = audio.source_start_frame, .source_length_frames = audio.source_length_frames, .length_ticks = self.length_ticks };
        audio.source_id = take.source_id;
        audio.source_start_frame = take.source_start_frame;
        audio.source_length_frames = take.source_length_frames;
        self.length_ticks = take.length_ticks;
        return true;
    }

    pub fn cycleAudioTake(self: *Clip, delta: i32) bool {
        switch (self.content) {
            .audio => {},
            else => return false,
        }
        const audio = &self.content.audio;
        const count = audio.takeCount() - 1;
        if (count == 0) return false;
        const current: AudioRegion.Take = .{ .source_id = audio.source_id, .source_start_frame = audio.source_start_frame, .source_length_frames = audio.source_length_frames, .length_ticks = self.length_ticks };
        const selected = if (delta >= 0) audio.alternate_takes[0].? else audio.alternate_takes[count - 1].?;
        if (delta >= 0) {
            for (0..count - 1) |i| audio.alternate_takes[i] = audio.alternate_takes[i + 1];
            audio.alternate_takes[count - 1] = current;
        } else {
            var i = count - 1;
            while (i > 0) : (i -= 1) audio.alternate_takes[i] = audio.alternate_takes[i - 1];
            audio.alternate_takes[0] = current;
        }
        audio.source_id = selected.source_id;
        audio.source_start_frame = selected.source_start_frame;
        audio.source_length_frames = selected.source_length_frames;
        self.length_ticks = selected.length_ticks;
        return true;
    }

    /// Drop `ticks` of material off the clip's front, keeping what is left
    /// where it already sounds. Every front trim used to just move
    /// `start_tick` forward, and content is played from the clip's own start
    /// (`Session.rebuildSongData` repeats a pattern from `rep_start = 0`, and
    /// an audio region is read from `source_start_frame`) - so cutting a clip
    /// in two handed back two clips both replaying the same opening instead of
    /// one clip cut in place.
    ///
    /// `audio_cursor` resolves how much source material a span of ticks
    /// actually covers, since the arrangement holds neither the tempo map nor
    /// the sample pool. Pass `{}` for the proportional fallback, which is
    /// exact whenever the region spans its clip (what recording and
    /// `:consolidate` produce) and an approximation for a short sample under
    /// a long clip. Anything else must expose:
    ///
    ///     fn sourceFrames(self, source_id: u32, from_tick: u32, ticks: u32,
    ///                     stretch_ratio: f32) u64
    ///
    /// Alternate takes and the fade lengths ride along unchanged either way.
    pub fn dropFront(self: *Clip, ticks: u32, audio_cursor: anytype) void {
        const drop = @min(ticks, self.length_ticks);
        if (drop == 0) return;
        const span = self.length_ticks;
        const from_tick = self.start_tick;
        self.start_tick +|= drop;
        self.length_ticks -= drop;
        switch (self.content) {
            .melodic => |*m| {
                if (m.length_beats > 0) {
                    const by = @mod(time_grid.tickToBeat(drop), m.length_beats);
                    for (m.notes) |*note| note.start_beat = @mod(note.start_beat - by + m.length_beats, m.length_beats);
                    std.mem.sort(Note, m.notes, {}, noteBeforeStart);
                }
            },
            .drum => |*d| {
                // The grid can only hold whole-step offsets; a cut that lands
                // between two steps rounds to the nearer one.
                const steps_f = @round(time_grid.tickToBeat(drop) * @as(f64, @floatFromInt(@max(d.steps_per_beat, 1))));
                if (d.step_count > 0 and steps_f > 0) {
                    const by: usize = @as(usize, @intFromFloat(steps_f)) % d.step_count;
                    if (by > 0) for (&d.midi) |row| {
                        if (row.len == d.step_count) std.mem.rotate(?DrumMachine.MidiNote, row, by);
                    };
                }
            },
            .audio => |*a| {
                const consumed: u64 = if (@TypeOf(audio_cursor) == void)
                    (if (span == 0) 0 else a.source_length_frames * drop / span)
                else
                    @min(audio_cursor.sourceFrames(a.source_id, from_tick, drop, a.stretch_ratio), a.source_length_frames);
                // Reversed playback reads the region back to front, so the
                // material dropped off the front comes off the source's tail.
                if (!a.reverse) a.source_start_frame +|= consumed;
                a.source_length_frames -|= consumed;
            },
        }
        self.automation.dropFront(time_grid.tickToBeat(drop));
    }

    fn noteBeforeStart(_: void, a: Note, b: Note) bool {
        return a.start_beat < b.start_beat;
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
            if (self.clips.items[i].layer == clip.layer and self.clips.items[i].overlaps(start, end)) {
                var removed = self.clips.orderedRemove(i);
                removed.deinit(allocator);
            } else i += 1;
        }
        // Insert at the first clip starting after `start`.
        var idx: usize = self.clips.items.len;
        for (self.clips.items, 0..) |c, j| {
            if (c.start_tick > start or (c.start_tick == start and c.layer > clip.layer)) {
                idx = j;
                break;
            }
        }
        self.clips.insertAssumeCapacity(idx, clip);
    }

    /// Remove the clip covering `bar`, if any. Returns true if one was removed.
    pub fn removeAt(self: *Lane, allocator: std.mem.Allocator, bar: u32) bool {
        // Topmost, the same clip `clipAt` names. Walking the list backwards
        // instead picks the last by *start tick*, which is a different clip
        // once layers stack - callers check with `clipAt` and delete with
        // this, so they have to agree.
        const idx = self.topmostAt(bar) orelse return false;
        var removed = self.clips.orderedRemove(idx);
        removed.deinit(allocator);
        return true;
    }

    fn topmostAt(self: *const Lane, bar: u32) ?usize {
        var best: ?usize = null;
        for (self.clips.items, 0..) |c, i| {
            if (!c.covers(bar)) continue;
            if (best == null or c.layer >= self.clips.items[best.?].layer) best = i;
        }
        return best;
    }

    /// Pointer to the clip covering `bar`, or null.
    pub fn clipAt(self: *Lane, bar: u32) ?*Clip {
        return &self.clips.items[self.topmostAt(bar) orelse return null];
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
    pub fn cutRange(self: *Lane, allocator: std.mem.Allocator, lo: u32, hi: u32, audio_cursor: anytype) !void {
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
                // Dupe (which only reads c) first, then reserve - the
                // reservation can reallocate and invalidate `c`, so the left
                // remainder is trimmed through a fresh index rather than
                // through that pointer.
                var right = try c.dupe(allocator);
                self.clips.ensureUnusedCapacity(allocator, 1) catch |err| {
                    right.deinit(allocator);
                    return err;
                };
                right.dropFront(hi - start, audio_cursor);
                self.clips.items[i].length_ticks = lo - start;
                self.clips.insertAssumeCapacity(i + 1, right);
                i += 2;
                continue;
            }
            if (start < lo) {
                c.length_ticks = lo - start; // trim the tail
            } else {
                c.dropFront(hi - start, audio_cursor); // trim the head, content and all
            }
            i += 1;
        }
        // A head trim moves a clip's start forward and a split drops its right
        // half at `hi`, either of which can overtake a clip that sits later in
        // the list untouched - reachable only with layers, where two clips can
        // cover the same tick. Same reasoning as `insertTime`.
        std.mem.sort(Clip, self.clips.items, {}, lessThanStart);
    }

    /// Cut every clip crossing `at` in two, removing nothing: the halves butt
    /// against each other and keep playing what they played. Returns whether
    /// anything crossed. A clip already starting or ending there is left
    /// alone - it is split at that point by definition.
    pub fn splitAt(self: *Lane, allocator: std.mem.Allocator, at: u32, audio_cursor: anytype) !bool {
        // Index loop, not `for (items)`: layers let a lane hold overlapping
        // clips (`place` only evicts an overlap on the same layer), so more
        // than one can cross `at`, and each split inserts into the list being
        // walked. Same shape `cutRange` uses for the same reason.
        var split_any = false;
        var i: usize = 0;
        while (i < self.clips.items.len) {
            const c = self.clips.items[i];
            if (c.start_tick >= at or c.endTick() <= at) {
                i += 1;
                continue;
            }
            var right = try c.dupe(allocator);
            self.clips.ensureUnusedCapacity(allocator, 1) catch |err| {
                right.deinit(allocator);
                return err;
            };
            right.dropFront(at - c.start_tick, audio_cursor);
            self.clips.items[i].length_ticks = at - c.start_tick;
            self.clips.insertAssumeCapacity(i + 1, right);
            i += 2; // past the remainder and the piece just inserted
            split_any = true;
        }
        // The right half lands at `at`, which can overtake a clip sitting
        // later in the list untouched - reachable only with layers, same as
        // `cutRange`'s own re-sort.
        if (split_any) std.mem.sort(Clip, self.clips.items, {}, lessThanStart);
        return split_any;
    }

    /// Open an empty span at `at`. A clip crossing the insertion point is
    /// split so material on its right moves with later clips.
    pub fn insertTime(self: *Lane, allocator: std.mem.Allocator, at: u32, width: u32, audio_cursor: anytype) !void {
        if (width == 0) return;
        for (self.clips.items) |c| {
            if (c.endTick() > at and c.endTick() > std.math.maxInt(u32) - width)
                return error.OutOfRange;
        }
        _ = try self.splitAt(allocator, at, audio_cursor);
        for (self.clips.items) |*c| {
            if (c.start_tick >= at) c.start_tick += width;
        }
        // That pass shifts a subset, which is only a suffix when no two clips
        // share a start tick - layers break that, so re-sort to keep the
        // by-start order this lane is documented to hold and `place` walks.
        std.mem.sort(Clip, self.clips.items, {}, lessThanStart);
    }

    fn lessThanStart(_: void, a: Clip, b: Clip) bool {
        if (a.start_tick != b.start_tick) return a.start_tick < b.start_tick;
        return a.layer < b.layer;
    }

    /// Remove `[lo, hi)` and close its gap.
    pub fn removeTime(self: *Lane, allocator: std.mem.Allocator, lo: u32, hi: u32, audio_cursor: anytype) !void {
        if (hi <= lo) return;
        try self.cutRange(allocator, lo, hi, audio_cursor);
        const width = hi - lo;
        // Needs no re-sort, unlike `cutRange` and `insertTime`: the cut above
        // leaves every start either below `lo` or at/after `hi`, and shifting
        // only the second group down by the gap width lands it at/after `lo`.
        // The two groups keep their order and cannot interleave.
        for (self.clips.items) |*c| {
            if (c.start_tick >= hi) c.start_tick -= width;
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

test "audio takes cycle through every alternate" {
    var clip = Clip.initAudio(0, 32, .{ .source_id = 1, .source_start_frame = 0, .source_length_frames = 10 });
    try std.testing.expect(clip.addAudioTake(.{ .source_id = 2, .source_start_frame = 0, .source_length_frames = 20, .length_ticks = 64 }));
    try std.testing.expect(clip.addAudioTake(.{ .source_id = 3, .source_start_frame = 0, .source_length_frames = 30, .length_ticks = 96 }));
    try std.testing.expectEqual(@as(usize, 3), clip.content.audio.takeCount());
    try std.testing.expect(clip.cycleAudioTake(1));
    try std.testing.expectEqual(@as(u32, 1), clip.content.audio.source_id);
    try std.testing.expect(clip.cycleAudioTake(1));
    try std.testing.expectEqual(@as(u32, 2), clip.content.audio.source_id);
    try std.testing.expect(clip.cycleAudioTake(-1));
    try std.testing.expectEqual(@as(u32, 1), clip.content.audio.source_id);
}

test "place inserts sorted and reports lane length" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);

    try lane.place(a, Clip.initDrum(4, 2, .{ .step_count = 16 }));
    try lane.place(a, Clip.initDrum(0, 2, .{ .step_count = 16 }));
    try lane.place(a, Clip.initDrum(2, 2, .{ .step_count = 16 }));

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
    try lane.place(a, Clip.initDrum(0, 4, .{ .step_count = 16 }));
    try lane.place(a, Clip.initDrum(2, 2, .{ .step_count = 16 }));

    try testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[0].start_tick);
}

test "different clip layers may overlap and top layer wins lookup" {
    const a = std.testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initAudio(0, 8, .{ .source_id = 1, .source_start_frame = 0, .source_length_frames = 8 }));
    var upper = Clip.initAudio(2, 4, .{ .source_id = 2, .source_start_frame = 0, .source_length_frames = 4 });
    upper.layer = 1;
    try lane.place(a, upper);

    try std.testing.expectEqual(@as(usize, 2), lane.clips.items.len);
    try std.testing.expectEqual(@as(u32, 2), lane.clipAt(3).?.content.audio.source_id);
}

test "clip constructors enforce non-empty lengths" {
    const a = testing.allocator;
    var melodic = try Clip.initMelodic(a, 0, 0, &.{}, 0.0);
    defer melodic.deinit(a);
    try testing.expectEqual(@as(u32, 1), melodic.length_ticks);
    try testing.expectEqual(@as(f64, 1.0), melodic.content.melodic.length_beats);

    const drum = Clip.initDrum(0, 0, .{ .step_count = 16 });
    try testing.expectEqual(@as(u32, 1), drum.length_ticks);
}

test "clip end and lane length saturate at the timeline limit" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(std.math.maxInt(u32) - 1, 4, .{
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

    try lane.place(a, Clip.initDrum(1, 3, .{ .step_count = 16 }));
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
    var src = Clip.initDrum(0, 2, .{ .step_count = 16 });
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
    const drum = Clip.initDrum(std.math.maxInt(u32), 128, .{ .step_count = 16 });
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
    try lane.place(a, Clip.initDrum(2, 2, .{ .step_count = 16 }));

    try lane.cutRange(a, 0, 8, {});
    try testing.expectEqual(@as(usize, 0), lane.clips.items.len);
}

test "cutRange trims the tail of a clip overlapping the cut's start" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(0, 4, .{ .step_count = 16 }));

    try lane.cutRange(a, 2, 6, {});
    try testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 0), lane.clips.items[0].start_tick);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[0].length_ticks);
}

test "cutRange trims the head of a clip overlapping the cut's end" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(4, 4, .{ .step_count = 16 }));

    try lane.cutRange(a, 0, 6, {});
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
    try lane.place(a, Clip.initDrum(0, 4, .{ .step_count = 16 }));

    try lane.cutRange(a, 2, 3, {});
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 0), lane.clips.items[0].start_tick);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[0].length_ticks);
    try testing.expectEqual(@as(u32, 3), lane.clips.items[1].start_tick);
    try testing.expectEqual(@as(u32, 1), lane.clips.items[1].length_ticks);
}

test "cutRange splits correctly when the reservation has to grow the clip list" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(0, 4, .{ .step_count = 16 }));
    // Capacity == len, so the split's reservation reallocates mid-cut. The
    // left remainder must still be trimmed in the NEW buffer.
    lane.clips.shrinkAndFree(a, lane.clips.items.len);

    try lane.cutRange(a, 2, 3, {});
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[0].length_ticks);
    try testing.expectEqual(@as(u32, 3), lane.clips.items[1].start_tick);
}

test "cutRange leaves clips outside the range untouched and no-ops on an empty range" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(0, 2, .{ .step_count = 16 }));
    try lane.place(a, Clip.initDrum(10, 2, .{ .step_count = 16 }));

    try lane.cutRange(a, 4, 6, {});
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);

    try lane.cutRange(a, 5, 5, {});
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);
}

test "insertTime splits a crossing clip and shifts later clips" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(0, 8, .{ .step_count = 16 }));
    try lane.place(a, Clip.initDrum(10, 2, .{ .step_count = 16 }));

    try lane.insertTime(a, 4, 3, {});
    try testing.expectEqual(@as(usize, 3), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 0), lane.clips.items[0].start_tick);
    try testing.expectEqual(@as(u32, 7), lane.clips.items[1].start_tick);
    try testing.expectEqual(@as(u32, 13), lane.clips.items[2].start_tick);
    try testing.expectEqual(@as(u32, 4), lane.clips.items[0].length_ticks);
    try testing.expectEqual(@as(u32, 4), lane.clips.items[1].length_ticks);
}

test "insertTime splits every crossing clip, not just the first" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    // Layers are the one case a lane holds overlapping clips: `place` only
    // evicts an overlap on the *same* layer (see `:crossfade`).
    const lower = Clip.initDrum(0, 8, .{ .step_count = 16 });
    var upper = Clip.initDrum(0, 8, .{ .step_count = 16 });
    upper.layer = 1;
    try lane.place(a, lower);
    try lane.place(a, upper);
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);

    try lane.insertTime(a, 4, 3, {});

    // Both clips split at 4: two remainders at 0, two shifted halves at 7.
    try testing.expectEqual(@as(usize, 4), lane.clips.items.len);
    var at_zero: usize = 0;
    var at_seven: usize = 0;
    for (lane.clips.items) |c| {
        try testing.expectEqual(@as(u32, 4), c.length_ticks);
        if (c.start_tick == 0) at_zero += 1;
        if (c.start_tick == 7) at_seven += 1;
    }
    try testing.expectEqual(@as(usize, 2), at_zero);
    try testing.expectEqual(@as(usize, 2), at_seven);

    // The lane is documented as kept sorted by start tick, and `place` walks
    // it assuming that when it picks an insertion index.
    for (lane.clips.items[1..], 0..) |c, prev| {
        try testing.expect(lane.clips.items[prev].start_tick <= c.start_tick);
    }
}

test "removeAt takes the same clip clipAt reports" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    // Stacked layers with different starts: list order (by start) and layer
    // order disagree, which is where the two used to pick different clips.
    var top = Clip.initDrum(0, 100, .{ .step_count = 16 });
    top.layer = 5;
    const bottom = Clip.initDrum(50, 100, .{ .step_count = 16 });
    try lane.place(a, top);
    try lane.place(a, bottom);

    const reported = lane.clipAt(60).?.*;
    try testing.expectEqual(@as(u8, 5), reported.layer);
    try testing.expect(lane.removeAt(a, 60));
    try testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    // The survivor must be the one clipAt did *not* name.
    try testing.expectEqual(@as(u8, 0), lane.clips.items[0].layer);
}

test "removeTime trims boundaries and closes the gap" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(0, 8, .{ .step_count = 16 }));
    try lane.place(a, Clip.initDrum(10, 2, .{ .step_count = 16 }));

    try lane.removeTime(a, 2, 5, {});
    try testing.expectEqual(@as(usize, 3), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 0), lane.clips.items[0].start_tick);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[1].start_tick);
    try testing.expectEqual(@as(u32, 7), lane.clips.items[2].start_tick);
    try testing.expectEqual(@as(u32, 3), lane.clips.items[1].length_ticks);
}

test "arrangement adds and removes lanes" {
    const a = testing.allocator;
    var arr: Arrangement = .{};
    defer arr.deinit(a);

    try arr.addLane(a);
    try arr.addLane(a);
    try arr.lane(0).?.place(a, Clip.initDrum(0, 5, .{ .step_count = 16 }));
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

test "a cut through a clip leaves the right half playing where the left one stopped" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    // One bar of pattern (32 ticks = 1 beat here) repeating over 4 beats, with
    // a note on each beat of the pattern.
    const notes = [_]Note{
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 },
        .{ .pitch = 64, .start_beat = 0.5, .duration_beat = 0.25 },
    };
    var clip = try Clip.initMelodic(a, 0, 4 * time_grid.ticks_per_beat, &notes, 1.0);
    clip.automation.gain = try a.dupe(AutomationPoint, &[_]AutomationPoint{
        .{ .beat = 0, .value = -6 },
        .{ .beat = 2, .value = 0 },
    });
    try lane.place(a, clip);

    // Cut out the third beat: left half keeps beats 0-1, right half is the
    // half-beat that was playing at beat 3 - so its pattern must be rotated by
    // that same 3 beats, not restarted.
    try lane.cutRange(a, 2 * time_grid.ticks_per_beat, 3 * time_grid.ticks_per_beat, {});
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);
    const right = lane.clips.items[1];
    try testing.expectEqual(@as(u32, 3 * time_grid.ticks_per_beat), right.start_tick);
    // 3 beats dropped, pattern is 1 beat long: rotation is 0, and the notes
    // keep their places. The curve, which is clip-relative, slides back by 3.
    try testing.expectApproxEqAbs(@as(f64, 0.0), right.automation.gain[0].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), right.automation.gain[1].beat, 1e-9);

    // A drop the pattern does not divide: a 2-beat pattern, cut from beat 1 to
    // beat 3, so the right half opens 3 beats into the pattern - one beat in,
    // and every note rotates by that beat.
    var lane2: Lane = .{};
    defer lane2.deinit(a);
    try lane2.place(a, try Clip.initMelodic(a, 0, 8 * time_grid.ticks_per_beat, &notes, 2.0));
    try lane2.cutRange(a, 1 * time_grid.ticks_per_beat, 3 * time_grid.ticks_per_beat, {});
    const half = lane2.clips.items[1].content.melodic;
    try testing.expectApproxEqAbs(@as(f64, 1.0), half.notes[0].start_beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5), half.notes[1].start_beat, 1e-9);
}

test "a cut through an audio region moves its source cursor with it" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initAudio(0, 100, .{ .source_id = 1, .source_start_frame = 1_000, .source_length_frames = 50_000 }));

    try lane.cutRange(a, 40, 60, {});
    const right = lane.clips.items[1].content.audio;
    // 60 of 100 ticks dropped off the front, so 60% of the source with it.
    try testing.expectEqual(@as(u64, 31_000), right.source_start_frame);
    try testing.expectEqual(@as(u64, 20_000), right.source_length_frames);

    // Reversed playback reads the region backwards, so the front comes off
    // the source's tail and the cursor stays put.
    var lane3: Lane = .{};
    defer lane3.deinit(a);
    try lane3.place(a, Clip.initAudio(0, 100, .{ .source_id = 1, .source_start_frame = 1_000, .source_length_frames = 50_000, .reverse = true }));
    try lane3.cutRange(a, 40, 60, {});
    const rev = lane3.clips.items[1].content.audio;
    try testing.expectEqual(@as(u64, 1_000), rev.source_start_frame);
    try testing.expectEqual(@as(u64, 20_000), rev.source_length_frames);
}

test "splitAt divides a clip without losing a tick of it" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initDrum(0, 100, .{ .step_count = 16 }));

    try testing.expect(try lane.splitAt(a, 40, {}));
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 0), lane.clips.items[0].start_tick);
    try testing.expectEqual(@as(u32, 40), lane.clips.items[0].length_ticks);
    try testing.expectEqual(@as(u32, 40), lane.clips.items[1].start_tick);
    try testing.expectEqual(@as(u32, 60), lane.clips.items[1].length_ticks);

    // A tick no clip crosses (a seam, the far end, a bare stretch) is a no-op.
    try testing.expect(!try lane.splitAt(a, 40, {}));
    try testing.expect(!try lane.splitAt(a, 100, {}));
    try testing.expect(!try lane.splitAt(a, 500, {}));
    try testing.expectEqual(@as(usize, 2), lane.clips.items.len);
}

test "splitAt divides every clip crossing the tick, stacked layers included" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    var lower = Clip.initDrum(0, 100, .{ .step_count = 16 });
    lower.layer = 0;
    var upper = Clip.initDrum(30, 40, .{ .step_count = 16 });
    upper.layer = 1;
    try lane.place(a, lower);
    try lane.place(a, upper);

    try testing.expect(try lane.splitAt(a, 50, {}));
    try testing.expectEqual(@as(usize, 4), lane.clips.items.len);
    for (lane.clips.items[1..], 0..) |c, prev| {
        try testing.expect(lane.clips.items[prev].start_tick <= c.start_tick);
    }
}

test "cutRange leaves the lane sorted when layers stack" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);
    var lower = Clip.initDrum(0, 100, .{ .step_count = 16 });
    lower.layer = 0;
    var upper = Clip.initDrum(5, 10, .{ .step_count = 16 });
    upper.layer = 1;
    try lane.place(a, lower);
    try lane.place(a, upper);

    // Splits the layer-0 clip in two while only trimming the layer-1 one,
    // so the pieces land either side of a clip that never moved.
    try lane.cutRange(a, 10, 20, {});

    for (lane.clips.items[1..], 0..) |c, prev| {
        try testing.expect(lane.clips.items[prev].start_tick <= c.start_tick);
    }
}

test "a front trim consumes the material actually under the cut, not a proportion of the region" {
    const a = std.testing.allocator;
    // A one-beat sample sitting under a four-beat clip: 48000 source frames
    // for the first beat, silence for the rest.
    const cursor = struct {
        pub fn sourceFrames(_: @This(), _: u32, _: u32, ticks: u32, stretch_ratio: f32) u64 {
            const beats = time_grid.tickToBeat(ticks);
            return @intFromFloat(beats * 48_000.0 / @as(f64, stretch_ratio));
        }
    }{};

    var lane: Lane = .{};
    defer lane.deinit(a);
    try lane.place(a, Clip.initAudio(0, 4 * time_grid.ticks_per_beat, .{
        .source_id = 1,
        .source_start_frame = 0,
        .source_length_frames = 48_000,
    }));

    // Split two beats in: the right half starts after every frame of audio,
    // so it holds none of it. Proportional math would have handed it the
    // sample's second half.
    try std.testing.expect(try lane.splitAt(a, 2 * time_grid.ticks_per_beat, cursor));
    try std.testing.expectEqual(@as(usize, 2), lane.clips.items.len);
    const left = lane.clips.items[0].content.audio;
    const right = lane.clips.items[1].content.audio;
    try std.testing.expectEqual(@as(u64, 0), left.source_start_frame);
    try std.testing.expectEqual(@as(u64, 48_000), left.source_length_frames);
    try std.testing.expectEqual(@as(u64, 48_000), right.source_start_frame);
    try std.testing.expectEqual(@as(u64, 0), right.source_length_frames);

    // Half a beat in, the cut lands inside the sample and takes exactly that
    // much of it.
    var clip = Clip.initAudio(0, 4 * time_grid.ticks_per_beat, .{
        .source_id = 1,
        .source_start_frame = 0,
        .source_length_frames = 48_000,
    });
    defer clip.deinit(a);
    clip.dropFront(time_grid.ticks_per_beat / 2, cursor);
    try std.testing.expectEqual(@as(u64, 24_000), clip.content.audio.source_start_frame);
    try std.testing.expectEqual(@as(u64, 24_000), clip.content.audio.source_length_frames);
}

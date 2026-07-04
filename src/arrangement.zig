//! Song arrangement: per-track clips placed on a bar timeline.
//!
//! The arrangement is the "song mode" counterpart to the per-track live
//! patterns. In pattern mode each track loops its single live pattern; in song
//! mode the transport sweeps this timeline and each track plays whichever clip
//! sits under the playhead. Clips are independent — each owns a private copy of
//! its note data (melodic) or drum bitmask (drum), so editing or duplicating
//! one never touches another.
//!
//! Control-side only. The audio thread never touches an Arrangement directly;
//! song-mode playback is driven by flattening each lane's clips into the same
//! per-track devices used in pattern mode (Session.rebuildSongData) — the
//! device replays that timeline against the transport.

const std = @import("std");
const Note = @import("dsp/pattern.zig").Note;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const automation_mod = @import("dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;

/// A clip placed on a track lane. Spans whole bars; owns its content.
pub const Clip = struct {
    /// Bar index where the clip begins (0-based).
    start_bar: u32,
    /// Length in whole bars (>= 1).
    length_bars: u32,
    content: Content,
    /// Gain/pan automation for this clip's span, in clip-relative beats (0 =
    /// clip start). Independent of `content` — every clip kind (melodic or
    /// drum) can carry it, since gain/pan are track-level, not instrument
    /// params. Empty = no automation (the track plays at its manual gain/pan
    /// for this clip's whole span). See `Session.rebuildSongData`, which
    /// flattens every clip's points into one whole-song curve per track.
    automation: Automation = .{},

    /// Gain (dB, same range as `:gain`/`Track.gain_db`) and pan (-1..1, same
    /// range as `Track.pan`) breakpoints, each independently optional.
    pub const Automation = struct {
        gain: []AutomationPoint = &.{},
        pan: []AutomationPoint = &.{},

        pub fn deinit(self: *Automation, allocator: std.mem.Allocator) void {
            allocator.free(self.gain);
            allocator.free(self.pan);
        }

        pub fn dupe(self: Automation, allocator: std.mem.Allocator) !Automation {
            const gain = try allocator.dupe(AutomationPoint, self.gain);
            errdefer allocator.free(gain);
            const pan = try allocator.dupe(AutomationPoint, self.pan);
            return .{ .gain = gain, .pan = pan };
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

    /// A private copy of a drum-machine pattern.
    pub const Drum = struct {
        pattern: [DrumMachine.max_pads]u32,
        /// Per-step velocity bitplanes (see DrumMachine.velGain). All-zero =
        /// every step at full velocity.
        vel_lo: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
        vel_hi: [DrumMachine.max_pads]u32 = [_]u32{0} ** DrumMachine.max_pads,
        step_count: u8,
        /// Which variant (A..H) this was stamped from — display label only;
        /// the pattern above is the payload, so bank edits never reach clips.
        variant: u8 = 0,
    };

    /// Build a melodic clip, duplicating `notes` so the clip owns them.
    pub fn initMelodic(
        allocator: std.mem.Allocator,
        start_bar: u32,
        length_bars: u32,
        notes: []const Note,
        length_beats: f64,
    ) !Clip {
        const owned = try allocator.dupe(Note, notes);
        return .{
            .start_bar = start_bar,
            .length_bars = length_bars,
            .content = .{ .melodic = .{ .notes = owned, .length_beats = length_beats } },
        };
    }

    /// Build a drum clip from a copied payload. No allocation.
    pub fn initDrum(start_bar: u32, length_bars: u32, drum: Drum) Clip {
        return .{
            .start_bar = start_bar,
            .length_bars = length_bars,
            .content = .{ .drum = drum },
        };
    }

    pub fn deinit(self: *Clip, allocator: std.mem.Allocator) void {
        switch (self.content) {
            .melodic => |m| allocator.free(m.notes),
            .drum => {},
        }
        self.automation.deinit(allocator);
    }

    /// Deep copy: melodic notes get a fresh allocation, drum payloads are
    /// plain values, automation points get a fresh allocation either way.
    /// Used by clip yank/paste and the undo lane snapshots.
    pub fn dupe(self: Clip, allocator: std.mem.Allocator) !Clip {
        var out: Clip = switch (self.content) {
            .melodic => |m| try initMelodic(
                allocator, self.start_bar, self.length_bars, m.notes, m.length_beats,
            ),
            .drum => |d| initDrum(self.start_bar, self.length_bars, d),
        };
        errdefer out.deinit(allocator);
        out.automation = try self.automation.dupe(allocator);
        return out;
    }

    /// First bar past the clip (exclusive end).
    pub fn endBar(self: Clip) u32 {
        return self.start_bar + self.length_bars;
    }

    /// True if `bar` falls within [start_bar, endBar).
    pub fn covers(self: Clip, bar: u32) bool {
        return bar >= self.start_bar and bar < self.endBar();
    }

    fn overlaps(self: Clip, start: u32, end: u32) bool {
        return self.start_bar < end and start < self.endBar();
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
    /// list sorted by `start_bar`. Takes ownership of the clip's content —
    /// including on failure, when the content is freed.
    pub fn place(self: *Lane, allocator: std.mem.Allocator, clip: Clip) !void {
        const start = clip.start_bar;
        const end = clip.endBar();
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
            if (c.start_bar > start) {
                idx = j;
                break;
            }
        }
        self.clips.insert(allocator, idx, clip) catch |err| {
            var owned = clip;
            owned.deinit(allocator);
            return err;
        };
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

    /// First bar past the last clip — the lane's content length in bars.
    pub fn lengthBars(self: *const Lane) u32 {
        var end: u32 = 0;
        for (self.clips.items) |c| end = @max(end, c.endBar());
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
        std.mem.swap(Lane, &self.lanes.items[a], &self.lanes.items[b]);
    }

    /// Song length in bars: the longest lane.
    pub fn lengthBars(self: *const Arrangement) u32 {
        var end: u32 = 0;
        for (self.lanes.items) |l| end = @max(end, l.lengthBars());
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

    try lane.place(a, Clip.initDrum(4, 2, .{ .pattern = [_]u32{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try lane.place(a, Clip.initDrum(0, 2, .{ .pattern = [_]u32{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try lane.place(a, Clip.initDrum(2, 2, .{ .pattern = [_]u32{0} ** DrumMachine.max_pads, .step_count = 16 }));

    try testing.expectEqual(@as(usize, 3), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 0), lane.clips.items[0].start_bar);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[1].start_bar);
    try testing.expectEqual(@as(u32, 4), lane.clips.items[2].start_bar);
    try testing.expectEqual(@as(u32, 6), lane.lengthBars());
}

test "place evicts overlapping clips" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);

    // A 4-bar clip at 0, then a 2-bar clip at 2 must evict the first.
    try lane.place(a, Clip.initDrum(0, 4, .{ .pattern = [_]u32{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try lane.place(a, Clip.initDrum(2, 2, .{ .pattern = [_]u32{0} ** DrumMachine.max_pads, .step_count = 16 }));

    try testing.expectEqual(@as(usize, 1), lane.clips.items.len);
    try testing.expectEqual(@as(u32, 2), lane.clips.items[0].start_bar);
}

test "clipAt and removeAt cover the clip's whole span" {
    const a = testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(a);

    try lane.place(a, Clip.initDrum(1, 3, .{ .pattern = [_]u32{0} ** DrumMachine.max_pads, .step_count = 16 }));
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
    var src = Clip.initDrum(0, 2, .{ .pattern = [_]u32{0} ** DrumMachine.max_pads, .step_count = 16 });
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

test "melodic clip owns a private note copy" {
    const a = testing.allocator;
    var src = [_]Note{.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 }};
    var clip = try Clip.initMelodic(a, 0, 1, &src, 4.0);
    defer clip.deinit(a);

    src[0].pitch = 0; // mutate the source after capture
    try testing.expectEqual(@as(u7, 60), clip.content.melodic.notes[0].pitch);
}

test "arrangement adds and removes lanes" {
    const a = testing.allocator;
    var arr: Arrangement = .{};
    defer arr.deinit(a);

    try arr.addLane(a);
    try arr.addLane(a);
    try arr.lane(0).?.place(a, Clip.initDrum(0, 5, .{ .pattern = [_]u32{0} ** DrumMachine.max_pads, .step_count = 16 }));
    try testing.expectEqual(@as(u32, 5), arr.lengthBars());

    arr.removeLane(a, 0);
    try testing.expectEqual(@as(usize, 1), arr.lanes.items.len);
    try testing.expectEqual(@as(u32, 0), arr.lengthBars());
}

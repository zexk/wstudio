//! Project model: the document a user edits.
//!
//! Lives on the control side. The audio thread never touches this
//! directly - edits are translated into engine commands.

const std = @import("std");
const types = @import("core/types.zig");
const theory = @import("theory.zig");
const dsp_tuning = @import("dsp/tuning.zig");
const dsp_controller = @import("dsp/controller.zig");

pub const TrackKind = enum { audio, midi };

/// Number of colors in `style.track_palette`. Duplicated here (rather than
/// importing the tui-layer style module into this control-layer one) so
/// `Session.insertTrack` can auto-assign colors; `style.zig` comptime-asserts
/// its palette length matches this constant to keep the two in sync.
pub const track_color_count: u8 = 16;

/// Aux/send slots per track (see `Track.sends`). Same small-fixed-bank
/// convention as the engine's `max_sidechain_sources`/`max_groups` - a
/// Small fixed bank, not a growable list. Defined here (not
/// `audio/engine.zig`, which
/// already imports `Project` from this file) so `Track` can hold the type
/// directly without a circular import.
pub const max_sends_per_track: u8 = 8;

/// Where a track's aux send lands - either straight to the master bus or
/// into one of the group submix buses (see `Session.groups`), same
/// destination set `Track.group` already routes a track's PRIMARY signal
/// through. A send is a parallel, independently-leveled tap alongside that
/// primary route, not a replacement for it.
pub const SendTarget = union(enum) { master, group: u8 };

/// One aux send: post-fader (applies after the track's own gain/pan, same
/// signal the primary-destination mix already uses), linear `level` - same
/// convention `gain_db`/`types.dbToGain` already establish for track gain.
pub const SendSlot = struct {
    target: SendTarget,
    level: f32 = 0.0,
};

pub const Track = struct {
    name: []const u8,
    kind: TrackKind = .audio,
    gain_db: f32 = 0.0,
    /// -1.0 hard left, 0.0 center, 1.0 hard right.
    pan: f32 = 0.0,
    muted: bool = false,
    soloed: bool = false,
    /// 0 = no color (default, uncolored name, matches every track's
    /// look before this field existed). 1..track_palette.len index into
    /// `style.track_palette`, cycled with `[`/`]` in the tracks view.
    /// Auto-assigned on creation by `Session.insertTrack`; duplicated
    /// tracks instead inherit their source's color.
    color: u8 = 0,
    /// Which group submix bus (see `Session.Group`/`Session.groups`) this
    /// track's signal routes through instead of straight to the master mix.
    /// `null` (the default) is the pre-grouping behaviour, unchanged.
    group: ?u8 = null,
    /// Parallel aux sends - see `SendSlot`. `null` entries are unused slots.
    sends: [max_sends_per_track]?SendSlot = @splat(null),
};

pub const Section = struct {
    tick: u32,
    name: []const u8,
};

pub const Project = struct {
    allocator: std.mem.Allocator,
    name: []const u8 = "untitled",
    sample_rate: u32 = types.default_sample_rate,
    tempo_bpm: f64 = 120.0,
    /// Song key used by piano-roll scale tools and sample tuning.
    scale: ?theory.Scale = null,
    /// Temperament every pitched instrument plays in. Orthogonal to `scale`
    /// above: that one picks which of the twelve keys the piece uses, this
    /// one picks what frequency those keys sound at. The default is equal
    /// temperament, which changes nothing.
    tuning: dsp_tuning.Tuning = .{},
    /// Beats per bar (the time signature's numerator; the unit stays /4).
    /// Control-side source of truth - the transport mirrors it, exactly
    /// like `tempo_bpm`.
    beats_per_bar: u8 = 4,
    /// A/B loop region in bars (`loop_end_bar` exclusive; empty = no region).
    /// Control-side source of truth - Session.syncLoop pushes it to the
    /// transport as frames whenever it (or the bar math) changes.
    loop_enabled: bool = false,
    loop_start_bar: u32 = 0,
    loop_end_bar: u32 = 0,
    /// Free-floating modulation controllers (see `dsp/controller.zig`).
    /// Project-scoped rather than per-track: one controller drives knobs
    /// across any number of tracks, which is the whole point of it.
    controllers: [dsp_controller.max_controllers]?dsp_controller.Controller = @splat(null),
    /// Learned MIDI CC bindings - the same targets, driven by hardware
    /// instead of an LFO. See `dsp_controller.CcBinding`.
    cc_bindings: [dsp_controller.max_cc_bindings]?dsp_controller.CcBinding = @splat(null),
    tracks: std.ArrayList(Track) = .empty,
    sections: std.ArrayList(Section) = .empty,

    pub fn init(allocator: std.mem.Allocator) Project {
        return .{ .allocator = allocator };
    }

    /// Frames in one bar at the current tempo and time signature.
    pub fn framesPerBar(self: *const Project) u64 {
        const sr = @as(f64, @floatFromInt(@max(self.sample_rate, 1)));
        const bpm = if (std.math.isFinite(self.tempo_bpm) and self.tempo_bpm > 0.0) self.tempo_bpm else 120.0;
        const beats_per_bar = @max(self.beats_per_bar, 1);
        const frames_f = sr * 60.0 / bpm * @as(f64, @floatFromInt(beats_per_bar));
        if (!std.math.isFinite(frames_f) or frames_f >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
            return std.math.maxInt(u64);
        const frames: u64 = @intFromFloat(frames_f);
        return @max(frames, 1);
    }

    pub fn deinit(self: *Project) void {
        for (self.tracks.items) |t| self.allocator.free(t.name);
        self.tracks.deinit(self.allocator);
        for (self.sections.items) |section| self.allocator.free(section.name);
        self.sections.deinit(self.allocator);
    }

    pub fn setSection(self: *Project, tick: u32, name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        for (self.sections.items) |*section| {
            if (section.tick != tick) continue;
            self.allocator.free(section.name);
            section.name = owned;
            return;
        }
        var index = self.sections.items.len;
        for (self.sections.items, 0..) |section, i| {
            if (section.tick > tick) {
                index = i;
                break;
            }
        }
        try self.sections.insert(self.allocator, index, .{ .tick = tick, .name = owned });
    }

    pub fn removeSection(self: *Project, tick: u32) bool {
        for (self.sections.items, 0..) |section, i| {
            if (section.tick != tick) continue;
            const removed = self.sections.orderedRemove(i);
            self.allocator.free(removed.name);
            return true;
        }
        return false;
    }

    pub fn insertTime(self: *Project, at: u32, width: u32) void {
        for (self.sections.items) |*section| {
            if (section.tick >= at) section.tick +|= width;
        }
    }

    pub fn removeTime(self: *Project, lo: u32, hi: u32) void {
        if (hi <= lo) return;
        var i: usize = 0;
        while (i < self.sections.items.len) {
            if (self.sections.items[i].tick >= lo and self.sections.items[i].tick < hi) {
                const removed = self.sections.orderedRemove(i);
                self.allocator.free(removed.name);
            } else {
                if (self.sections.items[i].tick >= hi) self.sections.items[i].tick -= hi - lo;
                i += 1;
            }
        }
    }

    /// Appends a track. Duplicates the name so the caller's string need not
    /// outlive the project.
    pub fn addTrack(self: *Project, track: Track) !usize {
        const name = try self.allocator.dupe(u8, track.name);
        errdefer self.allocator.free(name);
        var t = track;
        t.name = name;
        try self.tracks.append(self.allocator, t);
        return self.tracks.items.len - 1;
    }

    /// Inserts a track at `index`, shifting later tracks right. Duplicates
    /// the name.
    pub fn insertTrack(self: *Project, index: usize, track: Track) !void {
        const name = try self.allocator.dupe(u8, track.name);
        errdefer self.allocator.free(name);
        var t = track;
        t.name = name;
        try self.tracks.insert(self.allocator, index, t);
    }

    pub fn removeTrack(self: *Project, index: usize) void {
        if (index >= self.tracks.items.len) return;
        const t = self.tracks.orderedRemove(index);
        self.allocator.free(t.name);
    }

    pub fn renameTrack(self: *Project, index: usize, new_name: []const u8) !void {
        if (index >= self.tracks.items.len) return error.InvalidTrack;
        const name = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.tracks.items[index].name);
        self.tracks.items[index].name = name;
    }

    /// Swap two tracks' positions. No allocation, cannot fail.
    pub fn swapTracks(self: *Project, a: usize, b: usize) void {
        if (a >= self.tracks.items.len or b >= self.tracks.items.len) return;
        std.mem.swap(Track, &self.tracks.items[a], &self.tracks.items[b]);
    }
};

test "add and remove tracks" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();

    const a = try p.addTrack(.{ .name = "drums" });
    const b = try p.addTrack(.{ .name = "bass", .gain_db = -3.0 });
    try std.testing.expectEqual(@as(usize, 0), a);
    try std.testing.expectEqual(@as(usize, 1), b);
    try std.testing.expectEqual(@as(usize, 2), p.tracks.items.len);

    p.removeTrack(0);
    try std.testing.expectEqualStrings("bass", p.tracks.items[0].name);
}

test "insert track" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();

    _ = try p.addTrack(.{ .name = "a" });
    _ = try p.addTrack(.{ .name = "c" });
    try p.insertTrack(1, .{ .name = "b" });
    try std.testing.expectEqualStrings("b", p.tracks.items[1].name);
    try std.testing.expectEqualStrings("c", p.tracks.items[2].name);
}

test "rename track" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();

    _ = try p.addTrack(.{ .name = "old" });
    try p.renameTrack(0, "new");
    try std.testing.expectEqualStrings("new", p.tracks.items[0].name);
}

test "track mutations reject invalid indices" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.addTrack(.{ .name = "only" });

    p.removeTrack(99);
    p.swapTracks(0, 99);
    try std.testing.expectError(error.InvalidTrack, p.renameTrack(99, "bad"));
    try std.testing.expectEqual(@as(usize, 1), p.tracks.items.len);
    try std.testing.expectEqualStrings("only", p.tracks.items[0].name);
}

test "framesPerBar remains valid with invalid timing fields" {
    var p = Project.init(std.testing.allocator);
    p.sample_rate = 0;
    p.tempo_bpm = std.math.nan(f64);
    p.beats_per_bar = 0;
    try std.testing.expectEqual(@as(u64, 1), p.framesPerBar());

    p.sample_rate = std.math.maxInt(u32);
    p.tempo_bpm = std.math.floatMin(f64);
    p.beats_per_bar = std.math.maxInt(u8);
    try std.testing.expectEqual(std.math.maxInt(u64), p.framesPerBar());
}

test "sections stay sorted and follow time edits" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();
    try p.setSection(20, "chorus");
    try p.setSection(0, "intro");
    try p.setSection(20, "verse");
    try std.testing.expectEqualStrings("intro", p.sections.items[0].name);
    try std.testing.expectEqualStrings("verse", p.sections.items[1].name);

    p.insertTime(10, 5);
    try std.testing.expectEqual(@as(u32, 25), p.sections.items[1].tick);
    p.removeTime(0, 5);
    try std.testing.expectEqual(@as(usize, 1), p.sections.items.len);
    try std.testing.expectEqual(@as(u32, 20), p.sections.items[0].tick);
}

//! Project model: the document a user edits.
//!
//! Lives on the control side. The audio thread never touches this
//! directly - edits are translated into engine commands.

const std = @import("std");
const types = @import("core/types.zig");

pub const TrackKind = enum { audio, midi };

/// Number of colors in `style.track_palette`. Duplicated here (rather than
/// importing the tui-layer style module into this control-layer one) so
/// `Session.insertTrack` can auto-assign colors; `style.zig` comptime-asserts
/// its palette length matches this constant to keep the two in sync.
pub const track_color_count: u8 = 7;

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
};

pub const Project = struct {
    allocator: std.mem.Allocator,
    name: []const u8 = "untitled",
    sample_rate: u32 = types.default_sample_rate,
    tempo_bpm: f64 = 120.0,
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
    tracks: std.ArrayList(Track) = .empty,

    pub fn init(allocator: std.mem.Allocator) Project {
        return .{ .allocator = allocator };
    }

    /// Frames in one bar at the current tempo and time signature.
    pub fn framesPerBar(self: *const Project) u64 {
        const sr = @as(f64, @floatFromInt(@max(self.sample_rate, 1)));
        const bpm = if (std.math.isFinite(self.tempo_bpm) and self.tempo_bpm > 0.0) self.tempo_bpm else 120.0;
        const beats_per_bar = @max(self.beats_per_bar, 1);
        const frames: u64 = @intFromFloat(sr * 60.0 / bpm * @as(f64, @floatFromInt(beats_per_bar)));
        return @max(frames, 1);
    }

    pub fn deinit(self: *Project) void {
        for (self.tracks.items) |t| self.allocator.free(t.name);
        self.tracks.deinit(self.allocator);
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
        const t = self.tracks.orderedRemove(index);
        self.allocator.free(t.name);
    }

    pub fn renameTrack(self: *Project, index: usize, new_name: []const u8) !void {
        const name = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.tracks.items[index].name);
        self.tracks.items[index].name = name;
    }

    /// Swap two tracks' positions. No allocation, cannot fail.
    pub fn swapTracks(self: *Project, a: usize, b: usize) void {
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

test "framesPerBar remains valid with invalid timing fields" {
    var p = Project.init(std.testing.allocator);
    p.sample_rate = 0;
    p.tempo_bpm = std.math.nan(f64);
    p.beats_per_bar = 0;
    try std.testing.expectEqual(@as(u64, 1), p.framesPerBar());
}

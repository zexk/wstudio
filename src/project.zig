//! Project model: the document a user edits.
//!
//! Lives on the control side. The audio thread never touches this
//! directly — edits are translated into engine commands.

const std = @import("std");
const types = @import("core/types.zig");

pub const TrackKind = enum { audio, midi };

pub const Track = struct {
    name: []const u8,
    kind: TrackKind = .audio,
    gain_db: f32 = 0.0,
    /// -1.0 hard left, 0.0 center, 1.0 hard right.
    pan: f32 = 0.0,
    muted: bool = false,
    soloed: bool = false,
};

pub const Project = struct {
    allocator: std.mem.Allocator,
    name: []const u8 = "untitled",
    sample_rate: u32 = types.default_sample_rate,
    tempo_bpm: f64 = 120.0,
    tracks: std.ArrayList(Track) = .empty,

    pub fn init(allocator: std.mem.Allocator) Project {
        return .{ .allocator = allocator };
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

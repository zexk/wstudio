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
        self.tracks.deinit(self.allocator);
    }

    pub fn addTrack(self: *Project, track: Track) !usize {
        try self.tracks.append(self.allocator, track);
        return self.tracks.items.len - 1;
    }

    pub fn removeTrack(self: *Project, index: usize) void {
        _ = self.tracks.orderedRemove(index);
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

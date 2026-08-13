//! Persisted recent project paths, newest first.

const std = @import("std");
const json_store = @import("json.zig");

const FileSnapshot = struct {
    version: u32 = 1,
    projects: []const []const u8 = &.{},
};

const filename = "recent_projects.json";
pub const max_entries = 10;

pub fn load(allocator: std.mem.Allocator, io: std.Io) std.ArrayListUnmanaged([]const u8) {
    var parsed = json_store.load(FileSnapshot, allocator, io, filename, 1 * 1024 * 1024) orelse return .empty;
    defer parsed.deinit();
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (parsed.value.projects[0..@min(parsed.value.projects.len, max_entries)]) |path| {
        const owned = allocator.dupe(u8, path) catch continue;
        list.append(allocator, owned) catch allocator.free(owned);
    }
    return list;
}

pub fn touch(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), path: []const u8) !void {
    for (list.items, 0..) |old, i| {
        if (!std.mem.eql(u8, old, path)) continue;
        const owned = list.orderedRemove(i);
        list.insertAssumeCapacity(0, owned);
        return;
    }
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try list.insert(allocator, 0, owned);
    if (list.items.len > max_entries) allocator.free(list.pop().?);
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, list: []const []const u8) !void {
    try json_store.save(allocator, io, filename, FileSnapshot{ .projects = list });
}

pub fn deinit(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |path| allocator.free(path);
    list.deinit(allocator);
}

test "touch moves duplicates to front and caps list" {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer deinit(std.testing.allocator, &list);
    for (0..max_entries + 1) |i| {
        var buf: [16]u8 = undefined;
        try touch(std.testing.allocator, &list, try std.fmt.bufPrint(&buf, "{d}.wsj", .{i}));
    }
    try std.testing.expectEqual(max_entries, list.items.len);
    try std.testing.expectEqualStrings("10.wsj", list.items[0]);
    try touch(std.testing.allocator, &list, "5.wsj");
    try std.testing.expectEqualStrings("5.wsj", list.items[0]);
    try std.testing.expectEqual(max_entries, list.items.len);

    const owned = list.items[4];
    try touch(std.testing.allocator, &list, owned);
    try std.testing.expectEqual(@intFromPtr(owned.ptr), @intFromPtr(list.items[0].ptr));
}

test "save and load preserve order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try json_store.testRedirectHome(&tmp);
    try save(std.testing.allocator, std.testing.io, &.{ "/music/a.wsj", "/music/b.wsj" });
    var loaded = load(std.testing.allocator, std.testing.io);
    defer deinit(std.testing.allocator, &loaded);
    try std.testing.expectEqualStrings("/music/a.wsj", loaded.items[0]);
    try std.testing.expectEqualStrings("/music/b.wsj", loaded.items[1]);
}

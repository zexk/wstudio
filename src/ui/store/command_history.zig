//! Persisted `:` command and `/` search histories, bounded by
//! `cmd_history_cap`.
//! See docs/user-config-storage.md for paths and write conventions.

const std = @import("std");
const json_store = @import("json.zig");

const FileSnapshot = struct {
    version: u32 = 1,
    commands: []const []const u8 = &.{},
    searches: []const []const u8 = &.{},
};

pub const Loaded = struct {
    commands: std.ArrayListUnmanaged([]const u8) = .empty,
    searches: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        deinitList(allocator, &self.commands);
        deinitList(allocator, &self.searches);
    }
};

const filename = "cmd_history.json";

/// Load saved history, oldest first. Empty (not an error) if the file
/// doesn't exist yet or `$HOME` is unset - a missing history file should
/// never block startup, same spirit as a missing sample sidecar. A file
/// that exists but fails to parse is quarantined rather than silently
/// treated as empty, so a later save can't clobber it.
pub fn load(allocator: std.mem.Allocator, io: std.Io) Loaded {
    var parsed = json_store.load(FileSnapshot, allocator, io, filename, 1 * 1024 * 1024) orelse return .{};
    defer parsed.deinit();
    return .{
        .commands = dupeList(allocator, parsed.value.commands),
        .searches = dupeList(allocator, parsed.value.searches),
    };
}

fn dupeList(allocator: std.mem.Allocator, entries: []const []const u8) std.ArrayListUnmanaged([]const u8) {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (entries) |c| {
        const owned = allocator.dupe(u8, c) catch continue;
        list.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }
    return list;
}

/// Write every entry in `list` to disk, creating `~/.config/wstudio/` first
/// if needed. Best-effort from the caller's side - a failure here (no
/// `$HOME`, disk full) never blocks command entry, it just means history
/// doesn't outlive this run.
pub fn save(allocator: std.mem.Allocator, io: std.Io, commands: []const []const u8, searches: []const []const u8) !void {
    try json_store.save(allocator, io, filename, FileSnapshot{ .commands = commands, .searches = searches });
}

fn deinitList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit(allocator);
}

test "save writes command and search histories and load reads them back" {
    const testing = std.testing;
    var tmp = try json_store.testTempHome();
    defer tmp.cleanup();

    try save(testing.allocator, testing.io, &.{ "gain 1 3", "bounce out.wav" }, &.{ "drums", "bass" });

    var loaded = load(testing.allocator, testing.io);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), loaded.commands.items.len);
    try testing.expectEqualStrings("gain 1 3", loaded.commands.items[0]);
    try testing.expectEqualStrings("bounce out.wav", loaded.commands.items[1]);
    try testing.expectEqual(@as(usize, 2), loaded.searches.items.len);
    try testing.expectEqualStrings("drums", loaded.searches.items[0]);
    try testing.expectEqualStrings("bass", loaded.searches.items[1]);
}

test "load accepts command-only version 1 history" {
    const testing = std.testing;
    var tmp = try json_store.testTempHome();
    defer tmp.cleanup();

    const LegacySnapshot = struct { version: u32 = 1, commands: []const []const u8 = &.{} };
    try json_store.save(testing.allocator, testing.io, filename, LegacySnapshot{ .commands = &.{"bpm 120"} });

    var loaded = load(testing.allocator, testing.io);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("bpm 120", loaded.commands.items[0]);
    try testing.expectEqual(@as(usize, 0), loaded.searches.items.len);
}

test "load on a missing file returns an empty list, not an error" {
    const testing = std.testing;
    var tmp = try json_store.testTempHome();
    defer tmp.cleanup();

    var loaded = load(testing.allocator, testing.io);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.commands.items.len);
    try testing.expectEqual(@as(usize, 0), loaded.searches.items.len);
}

test "a corrupt history file is quarantined instead of silently emptied" {
    const testing = std.testing;
    var tmp = try json_store.testTempHome();
    defer tmp.cleanup();

    var path_buf: [json_store.path_buf_len]u8 = undefined;
    const path = try json_store.testWriteCorrupt(testing.io, &path_buf, filename);

    var loaded = load(testing.allocator, testing.io);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.commands.items.len);
    try testing.expectEqual(@as(usize, 0), loaded.searches.items.len);
    try json_store.testExpectQuarantined(testing.io, path);
}

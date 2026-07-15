//! Persisted `:` command history, bounded by `cmd_history_cap`.
//! See docs/user-config-storage.md for paths and write conventions.

const std = @import("std");
const json_store = @import("json_store.zig");

const FileSnapshot = struct {
    version: u32 = 1,
    commands: []const []const u8 = &.{},
};

const filename = "cmd_history.json";

/// Load saved history, oldest first. Empty (not an error) if the file
/// doesn't exist yet or `$HOME` is unset - a missing history file should
/// never block startup, same spirit as a missing sample sidecar. A file
/// that exists but fails to parse is quarantined rather than silently
/// treated as empty, so a later save can't clobber it.
pub fn load(allocator: std.mem.Allocator, io: std.Io) std.ArrayListUnmanaged([]const u8) {
    var parsed = json_store.load(FileSnapshot, allocator, io, filename, 1 * 1024 * 1024) orelse return .empty;
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (parsed.value.commands) |c| {
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
pub fn save(allocator: std.mem.Allocator, io: std.Io, list: []const []const u8) !void {
    try json_store.save(allocator, io, filename, FileSnapshot{ .commands = list });
}

pub fn deinit(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Not exposed by std.c on this target; declared directly (libc is already
// linked) so tests can redirect `configPath` at a scratch dir.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "save writes entries and load reads them back in order" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrintZ(&home_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = setenv("HOME", home.ptr, 1);

    try save(testing.allocator, testing.io, &.{ "gain 1 3", "bounce out.wav" });

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 2), loaded.items.len);
    try testing.expectEqualStrings("gain 1 3", loaded.items[0]);
    try testing.expectEqualStrings("bounce out.wav", loaded.items[1]);
}

test "load on a missing file returns an empty list, not an error" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrintZ(&home_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = setenv("HOME", home.ptr, 1);

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 0), loaded.items.len);
}

test "a corrupt history file is quarantined instead of silently emptied" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrintZ(&home_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = setenv("HOME", home.ptr, 1);

    var path_buf: [512]u8 = undefined;
    const path = json_store.configPath(&path_buf, filename).?;
    try std.Io.Dir.cwd().createDirPath(testing.io, std.fs.path.dirname(path).?);
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
        defer file.close(testing.io);
        var buf: [64]u8 = undefined;
        var fw = file.writer(testing.io, &buf);
        try fw.interface.writeAll("not json");
        try fw.interface.flush();
    }

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 0), loaded.items.len);

    var quarantine_path_buf: [520]u8 = undefined;
    const quarantine_path = try std.fmt.bufPrint(&quarantine_path_buf, "{s}.corrupt", .{path});
    var file = try std.Io.Dir.cwd().openFile(testing.io, quarantine_path, .{});
    file.close(testing.io);
}

//! Persisted file-browser bookmarks.
//! See docs/user-config-storage.md for paths and write conventions.

const std = @import("std");
const json_store = @import("json_store.zig");

/// A file-browser bookmark - `path` is the absolute path
/// `openBrowser`/`setBrowserDir` canonicalize to, so jumping to it later
/// works regardless of what directory is currently listed.
pub const Bookmark = struct {
    path: []u8,
    is_dir: bool,
};

const FileEntry = struct {
    path: []const u8,
    is_dir: bool,
};

const FileSnapshot = struct {
    version: u32 = 1,
    bookmarks: []const FileEntry = &.{},
};

const filename = "bookmarks.json";

/// Load saved bookmarks, in save order. Empty (not an error) if the file
/// doesn't exist yet or `$HOME` is unset - a missing bookmarks file should
/// never block startup, same spirit as a missing sample sidecar. A file
/// that exists but fails to parse is quarantined rather than silently
/// treated as empty, so a later save can't clobber it.
pub fn load(allocator: std.mem.Allocator, io: std.Io) std.ArrayListUnmanaged(Bookmark) {
    var parsed = json_store.load(FileSnapshot, allocator, io, filename, 1 * 1024 * 1024) orelse return .empty;
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(Bookmark) = .empty;
    for (parsed.value.bookmarks) |b| {
        const owned = allocator.dupe(u8, b.path) catch continue;
        list.append(allocator, .{ .path = owned, .is_dir = b.is_dir }) catch {
            allocator.free(owned);
            continue;
        };
    }
    return list;
}

/// Write every entry in `list` to disk, creating `~/.config/wstudio/` first
/// if needed. Best-effort from the caller's side - a failure here (no
/// `$HOME`, disk full) never blocks bookmark toggling, it just means the
/// bookmark list doesn't outlive this run.
pub fn save(allocator: std.mem.Allocator, io: std.Io, list: []const Bookmark) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const entries = try arena.allocator().alloc(FileEntry, list.len);
    for (list, 0..) |b, i| entries[i] = .{ .path = b.path, .is_dir = b.is_dir };
    try json_store.save(allocator, io, filename, FileSnapshot{ .bookmarks = entries });
}

pub fn deinit(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(Bookmark)) void {
    for (list.items) |b| allocator.free(b.path);
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

    try save(testing.allocator, testing.io, &.{
        .{ .path = @constCast("/home/user/samples"), .is_dir = true },
        .{ .path = @constCast("/home/user/kick.wav"), .is_dir = false },
    });

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 2), loaded.items.len);
    try testing.expectEqualStrings("/home/user/samples", loaded.items[0].path);
    try testing.expect(loaded.items[0].is_dir);
    try testing.expectEqualStrings("/home/user/kick.wav", loaded.items[1].path);
    try testing.expect(!loaded.items[1].is_dir);
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

test "a corrupt bookmarks file is quarantined instead of silently emptied" {
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

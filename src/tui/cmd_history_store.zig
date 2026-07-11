//! Persisted `:` command history: `~/.config/wstudio/cmd_history.json`, same
//! JSON + tmp-rename convention user_presets.zig uses. Loaded once at
//! App.init, the whole list rewritten every time a new entry lands in
//! `App.cmd_history` (see `App.pushCommandHistory`) — cheap at the
//! `cmd_history_cap`=50 cap.

const std = @import("std");

const FileSnapshot = struct {
    version: u32 = 1,
    commands: []const []const u8 = &.{},
};

/// Resolves the history file path via `$HOME` ($USERPROFILE on Windows,
/// which has no $HOME). Null if unset — history then just doesn't persist
/// across runs rather than blocking startup.
fn configPath(buf: []u8) ?[]const u8 {
    const home = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/wstudio/cmd_history.json", .{home}) catch null;
}

/// Best-effort rescue for a file that exists but didn't parse: rename it
/// aside instead of leaving `load` to report an empty list, which would let
/// the very next save overwrite it with that empty list and wipe history.
fn quarantine(io: std.Io, path: []const u8) void {
    var buf: [520]u8 = undefined;
    const dest = std.fmt.bufPrint(&buf, "{s}.corrupt", .{path}) catch return;
    std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), dest, io) catch {};
}

/// Load saved history, oldest first. Empty (not an error) if the file
/// doesn't exist yet or `$HOME` is unset — a missing history file should
/// never block startup, same spirit as a missing sample sidecar. A file
/// that exists but fails to parse is quarantined rather than silently
/// treated as empty, so a later save can't clobber it.
pub fn load(allocator: std.mem.Allocator, io: std.Io) std.ArrayListUnmanaged([]const u8) {
    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf) orelse return .empty;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 * 1024 * 1024)) catch return .empty;
    defer allocator.free(data);
    var parsed = std.json.parseFromSlice(FileSnapshot, allocator, data, .{ .ignore_unknown_fields = true }) catch {
        quarantine(io, path);
        return .empty;
    };
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
/// if needed. Best-effort from the caller's side — a failure here (no
/// `$HOME`, disk full) never blocks command entry, it just means history
/// doesn't outlive this run.
pub fn save(allocator: std.mem.Allocator, io: std.Io, list: []const []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf) orelse return error.NoHome;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);

    const snap: FileSnapshot = .{ .commands = list };
    const json_bytes = try std.json.Stringify.valueAlloc(aa, snap, .{ .whitespace = .indent_2 });

    const tmp_path = try std.fmt.allocPrint(aa, "{s}.tmp", .{path});
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(json_bytes);
        try fw.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
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
    const path = configPath(&path_buf).?;
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

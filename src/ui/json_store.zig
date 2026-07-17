//! Shared load/save primitives for small user-configuration JSON files.
//! See docs/user-config-storage.md for the storage conventions.

const std = @import("std");

/// Resolves `~/.config/wstudio/<filename>` via `$HOME` ($USERPROFILE on
/// Windows, which has no $HOME). Null if unset - callers then just don't
/// persist across runs rather than blocking startup.
pub fn configPath(buf: []u8, comptime filename: []const u8) ?[]const u8 {
    const home = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/wstudio/" ++ filename, .{home}) catch null;
}

/// Best-effort rescue for a file that exists but didn't parse: rename it
/// aside instead of leaving `load` to report an empty result, which would
/// let the very next save overwrite it with that empty result and wipe
/// whatever it held.
pub fn quarantine(io: std.Io, path: []const u8) void {
    var buf: [520]u8 = undefined;
    const dest = std.fmt.bufPrint(&buf, "{s}.corrupt", .{path}) catch return;
    std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), dest, io) catch {};
}

/// Read and parse `Snapshot` from `~/.config/wstudio/<filename>`. Null
/// (not an error) on a missing `$HOME`, a missing file, or a parse failure
/// (the last case also quarantines the file) - callers treat all three as
/// "nothing saved yet". Caller owns the returned `Parsed` and must
/// `.deinit()` it.
pub fn load(
    comptime Snapshot: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime filename: []const u8,
    limit_bytes: usize,
) ?std.json.Parsed(Snapshot) {
    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf, filename) orelse return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit_bytes)) catch return null;
    defer allocator.free(data);
    // alloc_always: parseFromSlice defaults to borrowing unescaped strings
    // straight from `data`, which this function frees before the caller
    // ever touches `parsed.value` - force full copies into the Parsed
    // arena instead, or callers get a use-after-free that only shows up
    // with real-sized files, not small test fixtures.
    return std.json.parseFromSlice(Snapshot, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        quarantine(io, path);
        return null;
    };
}

/// Serialize `snapshot` and write it to `~/.config/wstudio/<filename>` via
/// a tmp file + rename, creating the directory first if needed.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime filename: []const u8,
    snapshot: anytype,
) !void {
    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf, filename) orelse return error.NoHome;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    const json_bytes = try std.json.Stringify.valueAlloc(aa, snapshot, .{ .whitespace = .indent_2 });

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

// ---------------------------------------------------------------------------
// Test support - shared by every store module's tests
// ---------------------------------------------------------------------------

// Not exposed by std.c on this target; declared directly (libc is already
// linked) so tests can redirect `configPath` at a scratch dir.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Point `$HOME` at `tmp` so `configPath` lands in the test's scratch dir.
/// setenv copies its value, so the local buffer is safe to drop.
pub fn testRedirectHome(tmp: *const std.testing.TmpDir) !void {
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrintZ(&home_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = setenv("HOME", home.ptr, 1);
}

/// Write unparseable bytes at `filename`'s config path and return that path
/// (sliced into `path_buf`), for exercising the quarantine path.
pub fn testWriteCorrupt(io: std.Io, path_buf: []u8, comptime filename: []const u8) ![]const u8 {
    const path = configPath(path_buf, filename).?;
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll("not json");
    try fw.interface.flush();
    return path;
}

/// Assert the malformed file moved aside instead of vanishing: the original
/// path is gone and `<path>.corrupt` exists.
pub fn testExpectQuarantined(io: std.Io, path: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, path, .{}));
    var buf: [520]u8 = undefined;
    const quarantine_path = try std.fmt.bufPrint(&buf, "{s}.corrupt", .{path});
    var file = try std.Io.Dir.cwd().openFile(io, quarantine_path, .{});
    file.close(io);
}

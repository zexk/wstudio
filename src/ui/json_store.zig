//! Shared load/save primitives for small user-configuration JSON files.
//! See docs/user-config-storage.md for the storage conventions.

const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("../config.zig");

/// Size every caller's `configPath` buffer. Deliberately not
/// `std.fs.max_path_bytes`: these are stack buffers and a 4 KiB `$HOME` is
/// not a case worth sizing for - `configPath` reports null rather than
/// truncating, and the caller degrades to "nothing saved yet".
pub const path_buf_len = 512;

/// A quarantine destination is a `configPath` plus `.corrupt` and, on a
/// collision, `.<n>` for n < `max_quarantine_suffix`. Derived so bumping
/// `path_buf_len` can't leave the rename silently unable to format its
/// destination.
const max_quarantine_suffix = 100;
pub const quarantine_buf_len = path_buf_len + ".corrupt.".len +
    std.fmt.count("{d}", .{max_quarantine_suffix - 1});

/// Resolves `<config dir>/<filename>` through the same `userConfigDir` that
/// places `init.lua`, so every user file this program owns lives in one
/// directory: `$XDG_CONFIG_HOME/wstudio`, else `%APPDATA%\wstudio` on
/// Windows, else `~/.config/wstudio`. Null if none of those resolve -
/// callers then just don't persist across runs rather than blocking
/// startup.
pub fn configPath(buf: []u8, comptime filename: []const u8) ?[]const u8 {
    var dir_buf: [path_buf_len]u8 = undefined;
    const dir = config_mod.userConfigDir(&dir_buf) orelse return null;
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.bufPrint(buf, "{s}{c}" ++ filename, .{ dir, sep }) catch null;
}

/// Where these files landed before they followed `userConfigDir`: always
/// `$HOME/.config/wstudio` (`$USERPROFILE` on Windows), regardless of
/// `$XDG_CONFIG_HOME` or `%APPDATA%`. `load` still reads it when the real
/// path holds nothing, so a beta user who set either variable keeps their
/// bookmarks and presets; `save` only ever writes the real path, so the
/// first save after this moves the file for good. Null when it would name
/// the same file `configPath` already returned.
fn legacyConfigPath(buf: []u8, comptime filename: []const u8) ?[]const u8 {
    const home = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return null;
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    const path = std.fmt.bufPrint(
        buf,
        "{s}{c}.config{c}wstudio{c}" ++ filename,
        .{ std.mem.sliceTo(home, 0), sep, sep, sep },
    ) catch return null;
    var current_buf: [path_buf_len]u8 = undefined;
    const current = configPath(&current_buf, filename) orelse return path;
    return if (std.mem.eql(u8, current, path)) null else path;
}

/// Best-effort rescue for a file that exists but didn't parse: rename it
/// aside instead of leaving `load` to report an empty result, which would
/// let the very next save overwrite it with that empty result and wipe
/// whatever it held.
pub fn quarantine(io: std.Io, path: []const u8) void {
    var buf: [quarantine_buf_len]u8 = undefined;
    var suffix: usize = 0;
    while (suffix < max_quarantine_suffix) : (suffix += 1) {
        const dest = if (suffix == 0)
            std.fmt.bufPrint(&buf, "{s}.corrupt", .{path}) catch return
        else
            std.fmt.bufPrint(&buf, "{s}.corrupt.{d}", .{ path, suffix }) catch return;
        _ = std.Io.Dir.cwd().statFile(io, dest, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), dest, io) catch return;
                return;
            },
            else => return,
        };
        continue;
    }
}

/// Read and parse `Snapshot` from `configPath`, falling back to
/// `legacyConfigPath`. Null (not an error) when no config dir resolves, no
/// file exists at either path, or neither parses (a parse failure also
/// quarantines the file it read) - callers treat all of those as "nothing
/// saved yet". Caller owns the returned `Parsed` and must `.deinit()` it.
pub fn load(
    comptime Snapshot: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime filename: []const u8,
    limit_bytes: usize,
) ?std.json.Parsed(Snapshot) {
    var path_buf: [path_buf_len]u8 = undefined;
    if (configPath(&path_buf, filename)) |path| {
        if (readAt(Snapshot, allocator, io, path, limit_bytes)) |parsed| return parsed;
    }
    var legacy_buf: [path_buf_len]u8 = undefined;
    const legacy = legacyConfigPath(&legacy_buf, filename) orelse return null;
    return readAt(Snapshot, allocator, io, legacy, limit_bytes);
}

fn readAt(
    comptime Snapshot: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit_bytes: usize,
) ?std.json.Parsed(Snapshot) {
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

/// Serialize `snapshot` and write it to `configPath` via a tmp file +
/// rename, creating the directory first if needed. Never writes the legacy
/// path - a save is what migrates a file out of it.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime filename: []const u8,
    snapshot: anytype,
) !void {
    var path_buf: [path_buf_len]u8 = undefined;
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
///
/// `$XDG_CONFIG_HOME` is redirected too, and must be: it outranks `$HOME`
/// in `userConfigDir`, so a developer who has it set would otherwise have
/// their real `~/.config/wstudio` written to by the test suite. Pointing it
/// at `<tmp>/.config` reproduces the `$HOME`-derived layout exactly, which
/// also keeps the legacy path identical to the real one (so these tests
/// exercise the real path, not the fallback).
pub fn testRedirectHome(tmp: *const std.testing.TmpDir) !void {
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrintZ(&home_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = setenv("HOME", home.ptr, 1);
    var xdg_buf: [160]u8 = undefined;
    const xdg = try std.fmt.bufPrintZ(&xdg_buf, "{s}/.config", .{home});
    _ = setenv("XDG_CONFIG_HOME", xdg.ptr, 1);
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
    var buf: [quarantine_buf_len]u8 = undefined;
    const quarantine_path = try std.fmt.bufPrint(&buf, "{s}.corrupt", .{path});
    var file = try std.Io.Dir.cwd().openFile(io, quarantine_path, .{});
    file.close(io);
}

test "the store follows XDG_CONFIG_HOME and still reads the legacy path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testRedirectHome(&tmp);
    // Every later test in this binary expects the default redirect back.
    defer testRedirectHome(&tmp) catch {};

    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var xdg_buf: [160]u8 = undefined;
    const xdg = try std.fmt.bufPrintZ(&xdg_buf, "{s}/xdg", .{home});
    _ = setenv("XDG_CONFIG_HOME", xdg.ptr, 1);

    const S = struct { n: u32 = 0 };
    const io = std.testing.io;

    // $XDG_CONFIG_HOME outranks $HOME, and the pre-XDG location stays
    // readable rather than reading as "nothing saved yet".
    var path_buf: [path_buf_len]u8 = undefined;
    const path = configPath(&path_buf, "xdg_probe.json").?;
    try std.testing.expect(std.mem.startsWith(u8, path, xdg));

    var legacy_buf: [path_buf_len]u8 = undefined;
    const legacy = legacyConfigPath(&legacy_buf, "xdg_probe.json").?;
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(legacy).?);
    {
        const file = try std.Io.Dir.cwd().createFile(io, legacy, .{});
        defer file.close(io);
        var buf: [32]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll("{\"n\":7}");
        try fw.interface.flush();
    }
    var parsed = load(S, std.testing.allocator, io, "xdg_probe.json", 4096).?;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 7), parsed.value.n);

    // Saving migrates it: the write lands under $XDG_CONFIG_HOME, and that
    // copy is what the next load returns.
    try save(std.testing.allocator, io, "xdg_probe.json", S{ .n = 9 });
    var migrated = load(S, std.testing.allocator, io, "xdg_probe.json", 4096).?;
    defer migrated.deinit();
    try std.testing.expectEqual(@as(u32, 9), migrated.value.n);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    file.close(io);
}

test "quarantine preserves an earlier corrupt file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testRedirectHome(&tmp);

    var path_buf: [path_buf_len]u8 = undefined;
    const path = try testWriteCorrupt(std.testing.io, &path_buf, "collision.json");
    var corrupt_buf: [quarantine_buf_len]u8 = undefined;
    const corrupt = try std.fmt.bufPrint(&corrupt_buf, "{s}.corrupt", .{path});
    try std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), corrupt, std.testing.io);
    _ = try testWriteCorrupt(std.testing.io, &path_buf, "collision.json");

    quarantine(std.testing.io, path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, path, .{}));
    var first = try std.Io.Dir.cwd().openFile(std.testing.io, corrupt, .{});
    first.close(std.testing.io);
    var numbered_buf: [quarantine_buf_len]u8 = undefined;
    const numbered = try std.fmt.bufPrint(&numbered_buf, "{s}.1", .{corrupt});
    var second = try std.Io.Dir.cwd().openFile(std.testing.io, numbered, .{});
    second.close(std.testing.io);
}

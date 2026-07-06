//! User-saved synth presets: a hand-tuned `PolySynth.Patch` persisted to
//! `~/.config/wstudio/synth_presets.json` (same std.json.Stringify/
//! parseFromSlice convention persist.zig uses for the project file, and the
//! same tmp+rename atomic write). Loaded once at `App.init`, the whole set
//! rewritten on every `:synth-preset-save`. Complements the factory presets
//! in `dsp/synth_presets.zig`, which are compiled-in and read-only.

const std = @import("std");
const ws = @import("wstudio");
const Patch = ws.dsp.PolySynth.Patch;

pub const UserPreset = struct {
    name: []const u8,
    patch: Patch,
};

const FileSnapshot = struct {
    presets: []const UserPreset = &.{},
};

/// Resolves the presets file path via `$HOME` ($USERPROFILE on Windows,
/// which has no $HOME). Null if unset — presets then just don't persist
/// across runs rather than blocking startup.
fn configPath(buf: []u8) ?[]const u8 {
    const home = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/wstudio/synth_presets.json", .{home}) catch null;
}

/// Load every saved preset. Empty (not an error) if the file doesn't exist
/// yet, is malformed, or `$HOME` is unset — a missing/broken presets file
/// should never block startup, same spirit as a missing sample sidecar.
pub fn load(allocator: std.mem.Allocator, io: std.Io) std.ArrayListUnmanaged(UserPreset) {
    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf) orelse return .empty;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch return .empty;
    defer allocator.free(data);
    var parsed = std.json.parseFromSlice(FileSnapshot, allocator, data, .{ .ignore_unknown_fields = true }) catch return .empty;
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(UserPreset) = .empty;
    for (parsed.value.presets) |p| {
        const name = allocator.dupe(u8, p.name) catch continue;
        list.append(allocator, .{ .name = name, .patch = p.patch }) catch {
            allocator.free(name);
            continue;
        };
    }
    return list;
}

/// Write every preset in `list` to disk, creating `~/.config/wstudio/`
/// first if needed.
fn save(allocator: std.mem.Allocator, io: std.Io, list: []const UserPreset) !void {
    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf) orelse return error.NoHome;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);

    const snap: FileSnapshot = .{ .presets = list };
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

/// Insert or update (by case-insensitive name) `name`'s patch in `list`,
/// then persist the whole set to disk. The caller keeps owning `list`
/// (`App.user_synth_presets`) after this call.
pub fn upsert(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayListUnmanaged(UserPreset),
    name: []const u8,
    patch: Patch,
) !void {
    for (list.items) |*p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) {
            p.patch = patch;
            try save(allocator, io, list.items);
            return;
        }
    }
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try list.append(allocator, .{ .name = owned_name, .patch = patch });
    try save(allocator, io, list.items);
}

/// Case-insensitive lookup, mirroring `dsp/synth_presets.find`.
pub fn find(list: []const UserPreset, name: []const u8) ?Patch {
    for (list) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return p.patch;
    }
    return null;
}

pub fn deinit(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(UserPreset)) void {
    for (list.items) |p| allocator.free(p.name);
    list.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Not exposed by std.c on this target; declared directly (libc is already
// linked) so tests can redirect `configPath` at a scratch dir.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "upsert saves and load reads a preset back" {
    const testing = std.testing;
    // Point $HOME at a temp dir (relative to cwd, same convention
    // persist.zig's own tests use for their .wsj paths) so this test never
    // touches the real config file — setenv is process-global but tests run
    // single-threaded.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrintZ(&home_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = setenv("HOME", home.ptr, 1);

    var list: std.ArrayListUnmanaged(UserPreset) = .empty;
    defer deinit(testing.allocator, &list);

    var patch: Patch = .{};
    patch.gain = 0.42;
    try upsert(testing.allocator, testing.io, &list, "my-lead", patch);
    try testing.expectEqual(@as(usize, 1), list.items.len);

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 1), loaded.items.len);
    try testing.expectEqualStrings("my-lead", loaded.items[0].name);
    try testing.expectApproxEqAbs(@as(f32, 0.42), loaded.items[0].patch.gain, 1e-6);

    // Re-saving under the same name (any case) updates in place, not appends.
    patch.gain = 0.9;
    try upsert(testing.allocator, testing.io, &list, "MY-LEAD", patch);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectApproxEqAbs(@as(f32, 0.9), find(list.items, "my-lead").?.gain, 1e-6);
}

test "load returns an empty list when there's nothing saved yet" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrintZ(&home_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = setenv("HOME", home.ptr, 1);

    var list = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &list);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

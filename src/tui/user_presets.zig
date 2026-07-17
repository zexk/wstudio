//! User-saved `PolySynth.Patch` values, separate from factory presets.
//! See docs/user-config-storage.md for paths and write conventions.

const std = @import("std");
const ws = @import("wstudio");
const json_store = @import("json_store.zig");
const Patch = ws.dsp.PolySynth.Patch;

pub const UserPreset = struct {
    name: []const u8,
    patch: Patch,
};

const FileSnapshot = struct {
    version: u32 = 1,
    presets: []const UserPreset = &.{},
};

const filename = "synth_presets.json";

/// Load every saved preset. Empty (not an error) if the file doesn't exist
/// yet or `$HOME` is unset - a missing presets file should never block
/// startup, same spirit as a missing sample sidecar. A file that exists but
/// fails to parse is quarantined rather than silently treated as empty, so
/// a later save can't clobber it.
pub fn load(allocator: std.mem.Allocator, io: std.Io) std.ArrayListUnmanaged(UserPreset) {
    var parsed = json_store.load(FileSnapshot, allocator, io, filename, 4 * 1024 * 1024) orelse return .empty;
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
    try json_store.save(allocator, io, filename, FileSnapshot{ .presets = list });
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

/// Remove `name`'s preset (case-insensitive, mirroring `upsert`'s match)
/// from `list` and persist the shrunk set. False when no such preset -
/// nothing is written to disk then.
pub fn remove(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayListUnmanaged(UserPreset),
    name: []const u8,
) !bool {
    for (list.items, 0..) |p, i| {
        if (!std.ascii.eqlIgnoreCase(p.name, name)) continue;
        const removed = list.orderedRemove(i);
        allocator.free(removed.name);
        try save(allocator, io, list.items);
        return true;
    }
    return false;
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

test "upsert saves and load reads a preset back" {
    const testing = std.testing;
    // Point $HOME at a temp dir (relative to cwd, same convention
    // persist.zig's own tests use for their .wsj paths) so this test never
    // touches the real config file - setenv is process-global but tests run
    // single-threaded.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try json_store.testRedirectHome(&tmp);

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

test "remove deletes by name (any case) and persists the shrunk set" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try json_store.testRedirectHome(&tmp);

    var list: std.ArrayListUnmanaged(UserPreset) = .empty;
    defer deinit(testing.allocator, &list);
    try upsert(testing.allocator, testing.io, &list, "keeper", .{});
    try upsert(testing.allocator, testing.io, &list, "goner", .{});

    try testing.expect(try remove(testing.allocator, testing.io, &list, "GONER"));
    try testing.expectEqual(@as(usize, 1), list.items.len);
    // An unknown name is a clean false, not an error.
    try testing.expect(!try remove(testing.allocator, testing.io, &list, "goner"));

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 1), loaded.items.len);
    try testing.expectEqualStrings("keeper", loaded.items[0].name);
}

test "a malformed presets file is quarantined, not silently discarded" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try json_store.testRedirectHome(&tmp);

    var path_buf: [512]u8 = undefined;
    const path = try json_store.testWriteCorrupt(testing.io, &path_buf, filename);

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 0), loaded.items.len);
    try json_store.testExpectQuarantined(testing.io, path);

    // A subsequent save writes a fresh file rather than resurrecting the
    // corrupt one, and doesn't error out just because it's starting empty.
    const patch: Patch = .{};
    try upsert(testing.allocator, testing.io, &loaded, "rescued", patch);
    try testing.expectEqual(@as(usize, 1), loaded.items.len);
}

test "load returns an empty list when there's nothing saved yet" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try json_store.testRedirectHome(&tmp);

    var list = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &list);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

//! User-saved synth + FX instrument racks, separate from factory presets.
//! See docs/user-config-storage.md for paths and write conventions.

const std = @import("std");
const ws = @import("wstudio");
const json_store = @import("json_store.zig");
const Patch = ws.dsp.PolySynth.Patch;
const Fx = ws.Fx;

pub const UserPreset = struct {
    name: []const u8,
    patch: Patch,
    fx: Fx = .{},
};

const StoredPreset = struct {
    name: []const u8,
    patch: Patch,
    fx_chain: []const ws.persist.FxUnitSnap = &.{},
};

const FileSnapshot = struct {
    format: []const u8 = "wstudio-instrument-preset",
    version: u32 = 1,
    presets: []const StoredPreset = &.{},
};

const filename = "instrument_presets.wspreset";
const legacy_filename = "synth_presets.json";

const LegacyPreset = struct { name: []const u8, patch: Patch };
const LegacySnapshot = struct { version: u32 = 1, presets: []const LegacyPreset = &.{} };

/// Load every saved preset. Empty (not an error) if the file doesn't exist
/// yet or `$HOME` is unset - a missing presets file should never block
/// startup, same spirit as a missing sample sidecar. A file that exists but
/// fails to parse is quarantined rather than silently treated as empty, so
/// a later save can't clobber it.
pub fn load(allocator: std.mem.Allocator, io: std.Io, sample_rate: u32) std.ArrayListUnmanaged(UserPreset) {
    var parsed = json_store.load(FileSnapshot, allocator, io, filename, 4 * 1024 * 1024) orelse
        return importLegacy(allocator, io, sample_rate);
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.format, "wstudio-instrument-preset") or parsed.value.version > 1) return .empty;

    var list: std.ArrayListUnmanaged(UserPreset) = .empty;
    for (parsed.value.presets) |p| {
        const name = allocator.dupe(u8, p.name) catch continue;
        var fx: Fx = .{};
        ws.persist.applyFxChain(allocator, &fx, p.fx_chain, sample_rate, null) catch {
            fx.deinit(allocator);
            allocator.free(name);
            continue;
        };
        list.append(allocator, .{ .name = name, .patch = p.patch, .fx = fx }) catch {
            fx.deinit(allocator);
            allocator.free(name);
            continue;
        };
    }
    return list;
}

fn importLegacy(allocator: std.mem.Allocator, io: std.Io, sample_rate: u32) std.ArrayListUnmanaged(UserPreset) {
    var parsed = json_store.load(LegacySnapshot, allocator, io, legacy_filename, 4 * 1024 * 1024) orelse return .empty;
    defer parsed.deinit();
    var list: std.ArrayListUnmanaged(UserPreset) = .empty;
    for (parsed.value.presets) |p| {
        const name = allocator.dupe(u8, p.name) catch continue;
        list.append(allocator, .{ .name = name, .patch = p.patch }) catch allocator.free(name);
    }
    if (list.items.len > 0) save(allocator, io, list.items, sample_rate) catch {};
    return list;
}

/// Write every preset in `list` to disk, creating `~/.config/wstudio/`
/// first if needed.
fn save(allocator: std.mem.Allocator, io: std.Io, list: []const UserPreset, sample_rate: u32) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const stored = try aa.alloc(StoredPreset, list.len);
    for (list, stored) |p, *out| out.* = .{
        .name = p.name,
        .patch = p.patch,
        .fx_chain = try ws.persist.chainToSnap(aa, &p.fx, sample_rate),
    };
    try json_store.save(allocator, io, filename, FileSnapshot{ .presets = stored });
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
    fx: *const Fx,
    sample_rate: u32,
) !void {
    var copy = try fx.dupe(allocator, sample_rate);
    var copy_unowned = true;
    errdefer if (copy_unowned) copy.deinit(allocator);
    for (list.items) |*p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) {
            p.fx.deinit(allocator);
            p.patch = patch;
            p.fx = copy;
            copy_unowned = false;
            try save(allocator, io, list.items, sample_rate);
            return;
        }
    }
    const owned_name = allocator.dupe(u8, name) catch |e| return e;
    // The append has to be the last thing that can leave `owned_name`
    // unowned: once the entry is in the list, the list owns the name and
    // freeing it here would leave a dangling `p.name` behind for the next
    // upsert (or `deinit`) to read. A failed `save` therefore keeps the
    // preset in memory and only reports the write error, same as
    // `user_drum_kits.upsert`.
    list.append(allocator, .{ .name = owned_name, .patch = patch, .fx = copy }) catch |e| {
        allocator.free(owned_name);
        return e;
    };
    copy_unowned = false;
    try save(allocator, io, list.items, sample_rate);
}

/// Remove `name`'s preset (case-insensitive, mirroring `upsert`'s match)
/// from `list` and persist the shrunk set. False when no such preset -
/// nothing is written to disk then.
pub fn remove(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayListUnmanaged(UserPreset),
    name: []const u8,
    sample_rate: u32,
) !bool {
    for (list.items, 0..) |p, i| {
        if (!std.ascii.eqlIgnoreCase(p.name, name)) continue;
        const removed = list.orderedRemove(i);
        allocator.free(removed.name);
        var owned = removed;
        owned.fx.deinit(allocator);
        try save(allocator, io, list.items, sample_rate);
        return true;
    }
    return false;
}

/// Case-insensitive lookup, mirroring `dsp/synth_presets.find`.
pub fn find(list: []const UserPreset, name: []const u8) ?*const UserPreset {
    for (list) |*p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return p;
    }
    return null;
}

/// Replace synth and full FX chain only after duplicating every owned FX
/// resource succeeds. Failure leaves live rack untouched.
pub fn apply(allocator: std.mem.Allocator, rack: *ws.Rack, preset: *const UserPreset, sample_rate: u32) !void {
    if (rack.instrument != .poly_synth) return error.NotSynth;
    var replacement = try preset.fx.dupe(allocator, sample_rate);
    errdefer replacement.deinit(allocator);
    rack.fx.deinit(allocator);
    rack.fx = replacement;
    rack.instrument.poly_synth.applyPatch(preset.patch);
}

pub fn deinit(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(UserPreset)) void {
    for (list.items) |*p| {
        allocator.free(p.name);
        p.fx.deinit(allocator);
    }
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
    var fx: Fx = .{};
    defer fx.deinit(testing.allocator);
    const sat = try fx.insert(testing.allocator, 0, .sat, ws.types.default_sample_rate);
    sat.payload.sat.drive_db = 9.0;
    try upsert(testing.allocator, testing.io, &list, "my-lead", patch, &fx, ws.types.default_sample_rate);
    try testing.expectEqual(@as(usize, 1), list.items.len);

    var loaded = load(testing.allocator, testing.io, ws.types.default_sample_rate);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 1), loaded.items.len);
    try testing.expectEqualStrings("my-lead", loaded.items[0].name);
    try testing.expectApproxEqAbs(@as(f32, 0.42), loaded.items[0].patch.gain, 1e-6);
    try testing.expectEqual(@as(usize, 1), loaded.items[0].fx.units.items.len);
    try testing.expectApproxEqAbs(@as(f32, 9.0), loaded.items[0].fx.units.items[0].payload.sat.drive_db, 1e-6);

    // Re-saving under the same name (any case) updates in place, not appends.
    patch.gain = 0.9;
    try upsert(testing.allocator, testing.io, &list, "MY-LEAD", patch, &fx, ws.types.default_sample_rate);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectApproxEqAbs(@as(f32, 0.9), find(list.items, "my-lead").?.patch.gain, 1e-6);
}

test "remove deletes by name (any case) and persists the shrunk set" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try json_store.testRedirectHome(&tmp);

    var list: std.ArrayListUnmanaged(UserPreset) = .empty;
    defer deinit(testing.allocator, &list);
    var fx: Fx = .{};
    defer fx.deinit(testing.allocator);
    try upsert(testing.allocator, testing.io, &list, "keeper", .{}, &fx, ws.types.default_sample_rate);
    try upsert(testing.allocator, testing.io, &list, "goner", .{}, &fx, ws.types.default_sample_rate);

    try testing.expect(try remove(testing.allocator, testing.io, &list, "GONER", ws.types.default_sample_rate));
    try testing.expectEqual(@as(usize, 1), list.items.len);
    // An unknown name is a clean false, not an error.
    try testing.expect(!try remove(testing.allocator, testing.io, &list, "goner", ws.types.default_sample_rate));

    var loaded = load(testing.allocator, testing.io, ws.types.default_sample_rate);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 1), loaded.items.len);
    try testing.expectEqualStrings("keeper", loaded.items[0].name);
}

test "a malformed presets file is quarantined, not silently discarded" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try json_store.testRedirectHome(&tmp);

    var path_buf: [json_store.path_buf_len]u8 = undefined;
    const path = try json_store.testWriteCorrupt(testing.io, &path_buf, filename);

    var loaded = load(testing.allocator, testing.io, ws.types.default_sample_rate);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 0), loaded.items.len);
    try json_store.testExpectQuarantined(testing.io, path);

    // A subsequent save writes a fresh file rather than resurrecting the
    // corrupt one, and doesn't error out just because it's starting empty.
    const patch: Patch = .{};
    var fx: Fx = .{};
    defer fx.deinit(testing.allocator);
    try upsert(testing.allocator, testing.io, &loaded, "rescued", patch, &fx, ws.types.default_sample_rate);
    try testing.expectEqual(@as(usize, 1), loaded.items.len);
}

test "a preset whose save fails stays owned by the list" {
    const testing = std.testing;
    var list: std.ArrayListUnmanaged(UserPreset) = .empty;
    defer deinit(testing.allocator, &list);

    // A read-only config dir, an unset $HOME, a full disk: the write fails
    // but the entry is already in the list. It used to be freed anyway, so
    // the next upsert walked a dangling `p.name` (a segfault in practice)
    // and `deinit` double-freed it.
    var fx: Fx = .{};
    defer fx.deinit(testing.allocator);
    upsert(testing.allocator, std.Io.failing, &list, "one", .{}, &fx, ws.types.default_sample_rate) catch {};
    upsert(testing.allocator, std.Io.failing, &list, "two", .{}, &fx, ws.types.default_sample_rate) catch {};
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("one", list.items[0].name);
    try testing.expectEqualStrings("two", list.items[1].name);
}

test "load returns an empty list when there's nothing saved yet" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try json_store.testRedirectHome(&tmp);

    var list = load(testing.allocator, testing.io, ws.types.default_sample_rate);
    defer deinit(testing.allocator, &list);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

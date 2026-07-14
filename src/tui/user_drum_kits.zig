//! User-saved drum kits: pad *tuning* (name/gain/pan/pitch/ADSR/choke-group,
//! `dsp.DrumMachine.PadTune`) persisted to `~/.config/wstudio/drum_kits.json`,
//! same tmp+rename atomic write + quarantine-on-corrupt convention
//! `user_presets.zig` established. Unlike a synth preset (a self-sufficient
//! patch) or a factory drum kit (`dsp/drum_kit.zig`, which also carries the
//! procedural audio), a saved kit here carries NO audio — it's a reusable
//! mixing/ADSR/choke template layered onto whatever sample each pad already
//! holds. Loaded once at `App.init`, the whole set rewritten on every
//! `:drum-kit-save`.

const std = @import("std");
const ws = @import("wstudio");
const json_store = @import("json_store.zig");
const PadTune = ws.dsp.DrumMachine.PadTune;

pub const UserKit = struct {
    name: []const u8,
    pads: [8]PadTune,
};

const FileSnapshot = struct {
    version: u32 = 1,
    kits: []const UserKit = &.{},
};

const filename = "drum_kits.json";

fn dupePads(allocator: std.mem.Allocator, pads: [8]PadTune) ![8]PadTune {
    var out: [8]PadTune = pads;
    var filled: usize = 0;
    errdefer for (out[0..filled]) |p| allocator.free(p.name);
    for (pads, 0..) |p, i| {
        out[i].name = try allocator.dupe(u8, p.name);
        filled = i + 1;
    }
    return out;
}

fn freePads(allocator: std.mem.Allocator, pads: [8]PadTune) void {
    for (pads) |p| allocator.free(p.name);
}

pub fn load(allocator: std.mem.Allocator, io: std.Io) std.ArrayListUnmanaged(UserKit) {
    var parsed = json_store.load(FileSnapshot, allocator, io, filename, 4 * 1024 * 1024) orelse return .empty;
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(UserKit) = .empty;
    for (parsed.value.kits) |k| {
        const name = allocator.dupe(u8, k.name) catch continue;
        const pads = dupePads(allocator, k.pads) catch {
            allocator.free(name);
            continue;
        };
        list.append(allocator, .{ .name = name, .pads = pads }) catch {
            allocator.free(name);
            freePads(allocator, pads);
            continue;
        };
    }
    return list;
}

fn save(allocator: std.mem.Allocator, io: std.Io, list: []const UserKit) !void {
    try json_store.save(allocator, io, filename, FileSnapshot{ .kits = list });
}

/// Insert or update (by case-insensitive name) `name`'s tuning in `list`,
/// then persist the whole set to disk. `pads`' names are borrowed
/// (typically straight from live `Sampler.clipName()`s) — duped here before
/// they outlive the caller's stack frame.
pub fn upsert(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayListUnmanaged(UserKit),
    name: []const u8,
    pads: [8]PadTune,
) !void {
    const owned_pads = try dupePads(allocator, pads);

    for (list.items) |*existing| {
        if (std.ascii.eqlIgnoreCase(existing.name, name)) {
            freePads(allocator, existing.pads);
            existing.pads = owned_pads;
            try save(allocator, io, list.items);
            return;
        }
    }
    const owned_name = allocator.dupe(u8, name) catch |e| {
        freePads(allocator, owned_pads);
        return e;
    };
    list.append(allocator, .{ .name = owned_name, .pads = owned_pads }) catch |e| {
        allocator.free(owned_name);
        freePads(allocator, owned_pads);
        return e;
    };
    try save(allocator, io, list.items);
}

/// Remove `name`'s kit (case-insensitive) from `list` and persist the
/// shrunk set. False when no such kit — nothing is written to disk then.
pub fn remove(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayListUnmanaged(UserKit),
    name: []const u8,
) !bool {
    for (list.items, 0..) |k, i| {
        if (!std.ascii.eqlIgnoreCase(k.name, name)) continue;
        const removed = list.orderedRemove(i);
        allocator.free(removed.name);
        freePads(allocator, removed.pads);
        try save(allocator, io, list.items);
        return true;
    }
    return false;
}

/// Case-insensitive lookup, mirroring `user_presets.find`. The returned
/// kit's pad names are borrowed from `list`'s own storage.
pub fn find(list: []const UserKit, name: []const u8) ?UserKit {
    for (list) |k| {
        if (std.ascii.eqlIgnoreCase(k.name, name)) return k;
    }
    return null;
}

pub fn deinit(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(UserKit)) void {
    for (list.items) |k| {
        allocator.free(k.name);
        freePads(allocator, k.pads);
    }
    list.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn redirectHome(tmp: *std.testing.TmpDir, buf: []u8) [:0]const u8 {
    const home = std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
    _ = setenv("HOME", home.ptr, 1);
    return home;
}

test "upsert saves and load reads a kit back" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    _ = redirectHome(&tmp, &home_buf);

    var list: std.ArrayListUnmanaged(UserKit) = .empty;
    defer deinit(testing.allocator, &list);

    var pads: [8]PadTune = [_]PadTune{.{}} ** 8;
    pads[0] = .{ .name = "kick", .gain = 0.75, .choke_group = 1 };
    pads[1] = .{ .name = "snare", .pan = -0.3 };
    try upsert(testing.allocator, testing.io, &list, "my-kit", pads);
    try testing.expectEqual(@as(usize, 1), list.items.len);

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 1), loaded.items.len);
    try testing.expectEqualStrings("my-kit", loaded.items[0].name);
    try testing.expectEqualStrings("kick", loaded.items[0].pads[0].name);
    try testing.expectApproxEqAbs(@as(f32, 0.75), loaded.items[0].pads[0].gain, 1e-6);
    try testing.expectEqual(@as(u8, 1), loaded.items[0].pads[0].choke_group);
    try testing.expectApproxEqAbs(@as(f32, -0.3), loaded.items[0].pads[1].pan, 1e-6);

    // Re-saving under the same name (any case) updates in place, not appends.
    pads[0].gain = 0.9;
    try upsert(testing.allocator, testing.io, &list, "MY-KIT", pads);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectApproxEqAbs(@as(f32, 0.9), find(list.items, "my-kit").?.pads[0].gain, 1e-6);
}

test "remove deletes by name (any case) and persists the shrunk set" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    _ = redirectHome(&tmp, &home_buf);

    const blank: [8]PadTune = [_]PadTune{.{}} ** 8;
    var list: std.ArrayListUnmanaged(UserKit) = .empty;
    defer deinit(testing.allocator, &list);
    try upsert(testing.allocator, testing.io, &list, "keeper", blank);
    try upsert(testing.allocator, testing.io, &list, "goner", blank);

    try testing.expect(try remove(testing.allocator, testing.io, &list, "GONER"));
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expect(!try remove(testing.allocator, testing.io, &list, "goner"));

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 1), loaded.items.len);
    try testing.expectEqualStrings("keeper", loaded.items[0].name);
}

test "a malformed kits file is quarantined, not silently discarded" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = redirectHome(&tmp, &home_buf);

    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/.config/wstudio", .{home});
    defer testing.allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/.config/wstudio/drum_kits.json", .{home});
    defer testing.allocator.free(path);
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
        defer file.close(testing.io);
        var buf: [64]u8 = undefined;
        var fw = file.writer(testing.io, &buf);
        try fw.interface.writeAll("not valid json {{{");
        try fw.interface.flush();
    }

    var loaded = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &loaded);
    try testing.expectEqual(@as(usize, 0), loaded.items.len);

    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(testing.io, path, .{}));
    const quarantined = try std.fmt.allocPrint(testing.allocator, "{s}.corrupt", .{path});
    defer testing.allocator.free(quarantined);
    (try std.Io.Dir.cwd().openFile(testing.io, quarantined, .{})).close(testing.io);
}

test "load returns an empty list when there's nothing saved yet" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    _ = redirectHome(&tmp, &home_buf);

    var list = load(testing.allocator, testing.io);
    defer deinit(testing.allocator, &list);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

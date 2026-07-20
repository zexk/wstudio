//! CLAP plugin discovery using the standard paths from `clap/entry.h`.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const open_entry = @import("open_entry.zig");

pub const PluginInfo = struct {
    path: []u8,
    id: []u8,
    name: []u8,
    vendor: []u8,
    features: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *PluginInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.vendor);
        for (self.features.items) |feature| allocator.free(feature);
        self.features.deinit(allocator);
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayListUnmanaged(PluginInfo) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.plugins.items) |*plugin| plugin.deinit(self.allocator);
        self.plugins.deinit(self.allocator);
    }

    /// Recursively scan explicit directories. An unreadable directory or bad
    /// plugin is skipped so one installation cannot hide every other plugin.
    pub fn scanPaths(self: *Registry, io: std.Io, paths: []const []const u8) !void {
        for (paths) |path| self.scanPath(io, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        std.mem.sort(PluginInfo, self.plugins.items, {}, lessThan);
    }

    fn scanPath(self: *Registry, io: std.Io, path: []const u8) !void {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.basename, ".clap")) continue;
            const full_path = try std.fs.path.join(self.allocator, &.{ path, entry.path });
            defer self.allocator.free(full_path);
            try self.scanFile(full_path);
        }
    }

    fn scanFile(self: *Registry, path: []const u8) !void {
        var opened = open_entry.openEntry(self.allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        defer opened.library.close();
        defer self.allocator.free(opened.path_z);
        defer opened.entry.deinit();
        const entry = opened.entry;

        const raw = entry.get_factory(abi.plugin_factory_id) orelse return;
        const factory: *const abi.PluginFactory = @ptrCast(@alignCast(raw));
        for (0..factory.get_plugin_count(factory)) |index| {
            const desc = factory.get_plugin_descriptor(factory, @intCast(index)) orelse continue;
            if (!abi.versionIsCompatible(desc.clap_version)) continue;
            try self.appendDescriptor(path, desc);
        }
    }

    fn appendDescriptor(self: *Registry, path: []const u8, desc: *const abi.PluginDescriptor) !void {
        const id = std.mem.span(desc.id);
        const name = std.mem.span(desc.name);
        if (id.len == 0 or name.len == 0) return;
        for (self.plugins.items) |plugin| {
            if (std.mem.eql(u8, plugin.id, id)) return;
        }

        var info = PluginInfo{
            .path = try self.allocator.dupe(u8, path),
            .id = undefined,
            .name = undefined,
            .vendor = undefined,
        };
        errdefer self.allocator.free(info.path);
        info.id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(info.id);
        info.name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(info.name);
        info.vendor = try self.allocator.dupe(u8, if (desc.vendor) |vendor| std.mem.span(vendor) else "");
        errdefer self.allocator.free(info.vendor);
        errdefer {
            for (info.features.items) |feature| self.allocator.free(feature);
            info.features.deinit(self.allocator);
        }
        if (desc.features) |features| {
            var index: usize = 0;
            while (features[index]) |feature| : (index += 1)
                try info.features.append(self.allocator, try self.allocator.dupe(u8, std.mem.span(feature)));
        }
        try self.plugins.append(self.allocator, info);
    }

    fn lessThan(_: void, a: PluginInfo, b: PluginInfo) bool {
        const name_order = std.ascii.orderIgnoreCase(a.name, b.name);
        if (name_order != .eq) return name_order == .lt;
        return std.mem.order(u8, a.id, b.id) == .lt;
    }
};

/// Build the search list mandated by CLAP 1.2.10. `CLAP_PATH` entries come
/// first, followed by the platform defaults.
pub fn searchPaths(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !std.ArrayListUnmanaged([]u8) {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer freeSearchPaths(allocator, &paths);
    if (environ.get("CLAP_PATH")) |value| {
        var split = std.mem.splitScalar(u8, value, std.fs.path.delimiter);
        while (split.next()) |path| {
            if (path.len > 0) try appendUnique(allocator, &paths, path);
        }
    }

    switch (builtin.os.tag) {
        .linux => {
            if (environ.get("HOME")) |home| {
                const user = try std.fs.path.join(allocator, &.{ home, ".clap" });
                defer allocator.free(user);
                try appendUnique(allocator, &paths, user);
            }
            try appendUnique(allocator, &paths, "/usr/lib/clap");
        },
        .macos => {
            if (environ.get("HOME")) |home| {
                const user = try std.fs.path.join(allocator, &.{ home, "Library/Audio/Plug-Ins/CLAP" });
                defer allocator.free(user);
                try appendUnique(allocator, &paths, user);
            }
            try appendUnique(allocator, &paths, "/Library/Audio/Plug-Ins/CLAP");
        },
        .windows => {
            if (environ.get("COMMONPROGRAMFILES")) |common| {
                const path = try std.fs.path.join(allocator, &.{ common, "CLAP" });
                defer allocator.free(path);
                try appendUnique(allocator, &paths, path);
            }
            if (environ.get("LOCALAPPDATA")) |local| {
                const path = try std.fs.path.join(allocator, &.{ local, "Programs", "Common", "CLAP" });
                defer allocator.free(path);
                try appendUnique(allocator, &paths, path);
            }
        },
        else => {},
    }
    return paths;
}

pub fn freeSearchPaths(allocator: std.mem.Allocator, paths: *std.ArrayListUnmanaged([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn appendUnique(
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]u8),
    path: []const u8,
) !void {
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try paths.append(allocator, try allocator.dupe(u8, path));
}

test "explicit scan paths tolerate missing directories" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.scanPaths(std.testing.io, &.{"/path/which/does/not/exist"});
    try std.testing.expectEqual(@as(usize, 0), registry.plugins.items.len);
}

test "plugin ordering is case insensitive then stable by id" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.plugins.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "b.clap"),
        .id = try std.testing.allocator.dupe(u8, "b"),
        .name = try std.testing.allocator.dupe(u8, "Synth"),
        .vendor = try std.testing.allocator.dupe(u8, ""),
    });
    try registry.plugins.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "a.clap"),
        .id = try std.testing.allocator.dupe(u8, "a"),
        .name = try std.testing.allocator.dupe(u8, "synth"),
        .vendor = try std.testing.allocator.dupe(u8, ""),
    });
    std.mem.sort(PluginInfo, registry.plugins.items, {}, Registry.lessThan);
    try std.testing.expectEqualStrings("a", registry.plugins.items[0].id);
}

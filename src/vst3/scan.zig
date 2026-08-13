//! VST3 bundle discovery and factory enumeration.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const Module = @import("module.zig").Module;

pub const PluginInfo = struct {
    path: []u8,
    id: [32]u8,
    name: []u8,
    vendor: []u8,
    instrument: bool,

    fn deinit(self: *PluginInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
        allocator.free(self.vendor);
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
            if ((entry.kind != .directory and entry.kind != .sym_link) or !std.ascii.endsWithIgnoreCase(entry.basename, ".vst3")) continue;
            const bundle = try std.fs.path.join(self.allocator, &.{ path, entry.path });
            defer self.allocator.free(bundle);
            self.scanBundle(bundle) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
        }
    }

    fn scanBundle(self: *Registry, bundle: []const u8) !void {
        const relative = try moduleRelativePath(self.allocator, std.fs.path.basename(bundle), builtin.os.tag, builtin.cpu.arch);
        defer self.allocator.free(relative);
        const module_path = try std.fs.path.join(self.allocator, &.{ bundle, relative });
        defer self.allocator.free(module_path);

        try self.scanModule(module_path, bundle);
    }

    pub fn scanModule(self: *Registry, module_path: []const u8, bundle: []const u8) !void {
        var module = try Module.open(bundle, module_path);
        defer module.close();
        const factory = module.factory;

        var factory_info: abi.FactoryInfo = undefined;
        const have_factory_info = factory.vtable.get_factory_info(factory, &factory_info) == 0;
        const fallback_vendor = if (have_factory_info) std.mem.sliceTo(&factory_info.vendor, 0) else "";

        var factory2_raw: ?*anyopaque = null;
        if (factory.vtable.query_interface(factory, &abi.plugin_factory_2_iid, &factory2_raw) == 0) {
            const factory2: *abi.PluginFactory2 = @ptrCast(@alignCast(factory2_raw orelse return));
            defer _ = factory2.vtable.release(factory2);
            const count = factory2.vtable.count_classes(factory2);
            if (count <= 0) return;
            for (0..@as(usize, @intCast(count))) |index| {
                var info: abi.ClassInfo2 = undefined;
                if (factory2.vtable.get_class_info_2(factory2, @intCast(index), &info) != 0) continue;
                if (!std.mem.eql(u8, std.mem.sliceTo(&info.category, 0), "Audio Module Class")) continue;
                const class_vendor = std.mem.sliceTo(&info.vendor, 0);
                try self.append(bundle, info.cid, std.mem.sliceTo(&info.name, 0), if (class_vendor.len > 0) class_vendor else fallback_vendor, hasSubcategory(std.mem.sliceTo(&info.subcategories, 0), "Instrument"));
            }
            return;
        }

        // No IPluginFactory2 (optional in the VST3 spec) - fall back to the
        // mandatory base factory. No per-class vendor or subcategories here,
        // so every class from this bundle reports as a non-instrument with
        // the bundle's factory-level vendor.
        const count = factory.vtable.count_classes(factory);
        if (count <= 0) return;
        for (0..@as(usize, @intCast(count))) |index| {
            var info: abi.ClassInfo = undefined;
            if (factory.vtable.get_class_info(factory, @intCast(index), &info) != 0) continue;
            if (!std.mem.eql(u8, std.mem.sliceTo(&info.category, 0), "Audio Module Class")) continue;
            try self.append(bundle, info.cid, std.mem.sliceTo(&info.name, 0), fallback_vendor, false);
        }
    }

    fn append(self: *Registry, bundle: []const u8, cid: abi.Tuid, name: []const u8, vendor: []const u8, instrument: bool) !void {
        const id = abi.formatUid(cid);
        for (self.plugins.items) |plugin| if (std.mem.eql(u8, &plugin.id, &id)) return;
        if (name.len == 0) return;
        var plugin: PluginInfo = .{
            .path = try self.allocator.dupe(u8, bundle),
            .id = id,
            .name = undefined,
            .vendor = undefined,
            .instrument = instrument,
        };
        errdefer self.allocator.free(plugin.path);
        plugin.name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(plugin.name);
        plugin.vendor = try self.allocator.dupe(u8, vendor);
        errdefer self.allocator.free(plugin.vendor);
        try self.plugins.append(self.allocator, plugin);
    }

    fn lessThan(_: void, a: PluginInfo, b: PluginInfo) bool {
        const order = std.ascii.orderIgnoreCase(a.name, b.name);
        if (order != .eq) return order == .lt;
        return std.mem.order(u8, &a.id, &b.id) == .lt;
    }
};

pub fn moduleRelativePath(allocator: std.mem.Allocator, bundle_name: []const u8, os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ![]u8 {
    const stem = std.fs.path.stem(bundle_name);
    return switch (os) {
        .linux => std.fmt.allocPrint(allocator, "Contents/{s}-linux/{s}.so", .{ @tagName(arch), stem }),
        .windows => std.fmt.allocPrint(allocator, "Contents/{s}-win/{s}.vst3", .{ @tagName(arch), stem }),
        .macos => std.fmt.allocPrint(allocator, "Contents/MacOS/{s}", .{stem}),
        else => error.UnsupportedPlatform,
    };
}

pub fn searchPaths(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !std.ArrayListUnmanaged([]u8) {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer freeSearchPaths(allocator, &paths);
    if (environ.get("VST3_PATH")) |value| {
        var split = std.mem.splitScalar(u8, value, std.fs.path.delimiter);
        while (split.next()) |path| {
            if (path.len > 0) try appendUnique(allocator, &paths, path);
        }
    }
    switch (builtin.os.tag) {
        .linux => {
            if (environ.get("HOME")) |home| try appendJoined(allocator, &paths, &.{ home, ".vst3" });
            try appendUnique(allocator, &paths, "/usr/lib/vst3");
            try appendUnique(allocator, &paths, "/usr/local/lib/vst3");
        },
        .windows => {
            if (environ.get("LOCALAPPDATA")) |local| try appendJoined(allocator, &paths, &.{ local, "Programs", "Common", "VST3" });
            if (environ.get("COMMONPROGRAMFILES")) |common| try appendJoined(allocator, &paths, &.{ common, "VST3" });
        },
        .macos => {
            if (environ.get("HOME")) |home| try appendJoined(allocator, &paths, &.{ home, "Library/Audio/Plug-Ins/VST3" });
            try appendUnique(allocator, &paths, "/Library/Audio/Plug-Ins/VST3");
            try appendUnique(allocator, &paths, "/Network/Library/Audio/Plug-Ins/VST3");
        },
        else => {},
    }
    return paths;
}

pub fn freeSearchPaths(allocator: std.mem.Allocator, paths: *std.ArrayListUnmanaged([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn appendJoined(allocator: std.mem.Allocator, paths: *std.ArrayListUnmanaged([]u8), parts: []const []const u8) !void {
    const path = try std.fs.path.join(allocator, parts);
    defer allocator.free(path);
    try appendUnique(allocator, paths, path);
}

fn appendUnique(allocator: std.mem.Allocator, paths: *std.ArrayListUnmanaged([]u8), path: []const u8) !void {
    for (paths.items) |existing| if (std.mem.eql(u8, existing, path)) return;
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try paths.append(allocator, owned);
}

fn hasSubcategory(categories: []const u8, wanted: []const u8) bool {
    var parts = std.mem.splitScalar(u8, categories, '|');
    while (parts.next()) |part| if (std.mem.eql(u8, part, wanted)) return true;
    return false;
}

test "VST3 bundle module paths follow each platform layout" {
    const linux = try moduleRelativePath(std.testing.allocator, "Test.vst3", .linux, .x86_64);
    defer std.testing.allocator.free(linux);
    try std.testing.expectEqualStrings("Contents/x86_64-linux/Test.so", linux);
    const windows = try moduleRelativePath(std.testing.allocator, "Test.vst3", .windows, .x86_64);
    defer std.testing.allocator.free(windows);
    try std.testing.expectEqualStrings("Contents/x86_64-win/Test.vst3", windows);
    const macos = try moduleRelativePath(std.testing.allocator, "Test.vst3", .macos, .aarch64);
    defer std.testing.allocator.free(macos);
    try std.testing.expectEqualStrings("Contents/MacOS/Test", macos);
}

test "VST3 instrument subcategory is an exact token" {
    try std.testing.expect(hasSubcategory("Instrument|Synth", "Instrument"));
    try std.testing.expect(!hasSubcategory("Instrumental|Synth", "Instrument"));
}

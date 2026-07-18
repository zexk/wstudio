//! Format-neutral inventory of external audio plugins.

const std = @import("std");
const clap_scan = @import("clap/scan.zig");

pub const Format = enum { clap, vst3, vst2 };
pub const Role = enum { instrument, effect };

pub const Plugin = struct {
    format: Format,
    role: Role,
    path: []u8,
    id: []u8,
    name: []u8,
    vendor: []u8,

    fn deinit(self: *Plugin, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.vendor);
    }
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayListUnmanaged(Plugin) = .empty,
    scanned: bool = false,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        self.clear();
        self.plugins.deinit(self.allocator);
    }

    pub fn clear(self: *Catalog) void {
        for (self.plugins.items) |*plugin| plugin.deinit(self.allocator);
        self.plugins.clearRetainingCapacity();
        self.scanned = false;
    }

    pub fn scanClap(self: *Catalog, io: std.Io, paths: []const []const u8) !void {
        self.clear();
        var registry = clap_scan.Registry.init(self.allocator);
        defer registry.deinit();
        try registry.scanPaths(io, paths);
        for (registry.plugins.items) |plugin| {
            if (hasFeature(plugin.features.items, "instrument"))
                try self.appendClap(plugin, .instrument);
            if (hasFeature(plugin.features.items, "audio-effect"))
                try self.appendClap(plugin, .effect);
        }
        std.mem.sort(Plugin, self.plugins.items, {}, lessThan);
        self.scanned = true;
    }

    pub fn count(self: *const Catalog, role: Role) usize {
        var result: usize = 0;
        for (self.plugins.items) |plugin| {
            if (plugin.role == role) result += 1;
        }
        return result;
    }

    pub fn at(self: *const Catalog, role: Role, ordinal: usize) ?*const Plugin {
        var index: usize = 0;
        for (self.plugins.items) |*plugin| {
            if (plugin.role != role) continue;
            if (index == ordinal) return plugin;
            index += 1;
        }
        return null;
    }

    fn appendClap(self: *Catalog, source: clap_scan.PluginInfo, role: Role) !void {
        var plugin: Plugin = .{
            .format = .clap,
            .role = role,
            .path = try self.allocator.dupe(u8, source.path),
            .id = undefined,
            .name = undefined,
            .vendor = undefined,
        };
        errdefer self.allocator.free(plugin.path);
        plugin.id = try self.allocator.dupe(u8, source.id);
        errdefer self.allocator.free(plugin.id);
        plugin.name = try self.allocator.dupe(u8, source.name);
        errdefer self.allocator.free(plugin.name);
        plugin.vendor = try self.allocator.dupe(u8, source.vendor);
        errdefer self.allocator.free(plugin.vendor);
        try self.plugins.append(self.allocator, plugin);
    }

    fn lessThan(_: void, a: Plugin, b: Plugin) bool {
        if (a.role != b.role) return @intFromEnum(a.role) < @intFromEnum(b.role);
        const order = std.ascii.orderIgnoreCase(a.name, b.name);
        if (order != .eq) return order == .lt;
        return std.mem.order(u8, a.id, b.id) == .lt;
    }
};

fn hasFeature(features: []const []u8, wanted: []const u8) bool {
    for (features) |feature| {
        if (std.mem.eql(u8, feature, wanted)) return true;
    }
    return false;
}

test "catalog exposes plugins by role" {
    var catalog = Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    try catalog.plugins.append(std.testing.allocator, .{
        .format = .clap,
        .role = .effect,
        .path = try std.testing.allocator.dupe(u8, "effect.clap"),
        .id = try std.testing.allocator.dupe(u8, "effect"),
        .name = try std.testing.allocator.dupe(u8, "Effect"),
        .vendor = try std.testing.allocator.dupe(u8, "Vendor"),
    });
    try std.testing.expectEqual(@as(usize, 1), catalog.count(.effect));
    try std.testing.expectEqualStrings("Effect", catalog.at(.effect, 0).?.name);
    try std.testing.expect(catalog.at(.instrument, 0) == null);
}

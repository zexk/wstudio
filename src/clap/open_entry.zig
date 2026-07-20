//! Shared prefix of opening a `.clap` shared library and getting it ready
//! to hand back a plugin factory: dlopen, look up `clap_entry`, check ABI
//! version compatibility, and call `entry.init` with a NUL-terminated copy
//! of the path. Used by both scan.zig's discovery pass and plugin.zig's
//! `load` - they diverge in error-handling philosophy from here on (the
//! scanner silently skips anything but OutOfMemory so one bad install
//! can't hide every other plugin; `load` propagates a specific error for
//! each failure since it's servicing an explicit user request) and in how
//! long they keep the returned resources alive, so that divergence stays
//! at the call site rather than being forced into one shape here.

const std = @import("std");
const abi = @import("abi.zig");
const dynlib_compat = @import("dynlib_compat.zig");

pub const OpenedEntry = struct {
    library: dynlib_compat.DynLib,
    entry: *const abi.PluginEntry,
    path_z: [:0]u8,
};

pub fn openEntry(allocator: std.mem.Allocator, path: []const u8) !OpenedEntry {
    var library = try dynlib_compat.DynLib.open(path);
    errdefer library.close();
    const entry = library.lookup(*const abi.PluginEntry, "clap_entry") orelse return error.MissingClapEntry;
    if (!abi.versionIsCompatible(entry.clap_version)) return error.IncompatibleClapVersion;

    const path_z = try allocator.dupeZ(u8, path);
    errdefer allocator.free(path_z);
    if (!entry.init(path_z.ptr)) return error.EntryInitFailed;

    return .{ .library = library, .entry = entry, .path_z = path_z };
}

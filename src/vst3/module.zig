const builtin = @import("builtin");
const abi = @import("abi.zig");
const DynLib = @import("../clap/dynlib_compat.zig").DynLib;

const has_macos_bundle = builtin.os.tag == .macos;
const MacosBundle = if (has_macos_bundle) @import("module_macos.zig") else struct {
    pub const Bundle = ?*anyopaque;
    pub fn create(_: []const u8) !Bundle {
        return null;
    }
    pub fn callEntry(_: Bundle) !void {}
    pub fn callExit(_: Bundle) void {}
    pub fn release(_: Bundle) void {}
};

pub const Module = struct {
    library: DynLib,
    factory: *abi.PluginFactory,
    exit: ?*const fn () callconv(abi.abi_callconv) bool,
    cf_bundle: MacosBundle.Bundle = null,

    /// `bundle_path` is the `.vst3` bundle directory itself, `path` the
    /// platform binary inside it (see `moduleRelativePath`). macOS plugins
    /// expect their CFBundle's own bundleEntry/bundleExit pair called around
    /// use - same contract Windows' InitDll/ExitDll and Linux's
    /// ModuleEntry/ModuleExit already get below, just routed through
    /// CoreFoundation (see module_macos.zig) instead of a plain exported
    /// symbol.
    pub fn open(bundle_path: []const u8, path: []const u8) !Module {
        var library = try DynLib.open(path);
        errdefer library.close();
        var exit: ?*const fn () callconv(abi.abi_callconv) bool = null;
        var cf_bundle: MacosBundle.Bundle = null;
        switch (builtin.os.tag) {
            .windows => {
                const entry = library.lookup(*const fn () callconv(abi.abi_callconv) bool, "InitDll") orelse return error.MissingModuleEntry;
                if (!entry()) return error.ModuleEntryFailed;
                exit = library.lookup(*const fn () callconv(abi.abi_callconv) bool, "ExitDll");
            },
            .linux => {
                const entry = library.lookup(*const fn (?*anyopaque) callconv(abi.abi_callconv) bool, "ModuleEntry") orelse return error.MissingModuleEntry;
                if (!entry(null)) return error.ModuleEntryFailed;
                exit = library.lookup(*const fn () callconv(abi.abi_callconv) bool, "ModuleExit");
            },
            .macos => {
                cf_bundle = try MacosBundle.create(bundle_path);
                errdefer MacosBundle.release(cf_bundle);
                try MacosBundle.callEntry(cf_bundle);
            },
            else => {},
        }
        errdefer {
            if (exit) |leave| _ = leave();
            MacosBundle.release(cf_bundle);
        }
        const get_factory = library.lookup(*const fn () callconv(abi.abi_callconv) ?*abi.PluginFactory, "GetPluginFactory") orelse
            return error.MissingPluginFactory;
        return .{ .library = library, .factory = get_factory() orelse return error.MissingPluginFactory, .exit = exit, .cf_bundle = cf_bundle };
    }

    pub fn close(self: *Module) void {
        if (self.exit) |leave| _ = leave();
        MacosBundle.callExit(self.cf_bundle);
        MacosBundle.release(self.cf_bundle);
        self.library.close();
    }
};

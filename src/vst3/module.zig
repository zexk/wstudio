const builtin = @import("builtin");
const abi = @import("abi.zig");
const DynLib = @import("../clap/dynlib_compat.zig").DynLib;

pub const Module = struct {
    library: DynLib,
    factory: *abi.PluginFactory,
    exit: ?*const fn () callconv(abi.abi_callconv) bool,

    pub fn open(path: []const u8) !Module {
        var library = try DynLib.open(path);
        errdefer library.close();
        var exit: ?*const fn () callconv(abi.abi_callconv) bool = null;
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
            else => {},
        }
        errdefer {
            if (exit) |leave| _ = leave();
        }
        const get_factory = library.lookup(*const fn () callconv(abi.abi_callconv) ?*abi.PluginFactory, "GetPluginFactory") orelse
            return error.MissingPluginFactory;
        return .{ .library = library, .factory = get_factory() orelse return error.MissingPluginFactory, .exit = exit };
    }

    pub fn close(self: *Module) void {
        if (self.exit) |leave| _ = leave();
        self.library.close();
    }
};

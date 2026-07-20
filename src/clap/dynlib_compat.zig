//! HACK, not a permanent design choice: Zig 0.16.0's `std.DynLib` has no
//! Windows implementation. Its `InnerType` selection (lib/zig/std/
//! dynamic_library.zig) switches on `native_os` and only covers Linux
//! (`ElfDynLib`/`DlDynLib`) and the macOS/BSD family (`DlDynLib`); every
//! other target - including `.windows` - falls into an `else` branch whose
//! `open`/`openZ` are a bare `@compileError("unsupported platform")`. CLAP
//! plugin hosting (`clap/scan.zig`, `clap/plugin.zig`) needs to load an
//! arbitrary `.clap` binary at runtime on every platform wstudio targets,
//! Windows included, so this fills the gap directly against the raw Win32
//! API (`LoadLibraryW`/`GetProcAddress`/`FreeLibrary`) rather than leaving
//! Windows builds broken.
//!
//! `DynLib` here is `std.DynLib` unchanged on every target where it already
//! works - this file only exists to patch the one hole, not to replace the
//! real implementation anywhere it's already provided. Once upstream Zig
//! ships a working Windows `std.DynLib` (search "DynLib" and "windows" in
//! the ziglang/zig issue tracker before assuming - it may already have
//! landed by the time anyone reads this), delete this file and change
//! `clap/scan.zig`'s and `clap/plugin.zig`'s `dynlib_compat.DynLib` back to
//! a plain `std.DynLib`.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const DynLib = if (builtin.os.tag == .windows) WindowsDynLib else std.DynLib;

/// Win32 declarations `std.os.windows`/`kernel32.zig` don't carry in this
/// Zig release (its curated binding set dropped module-loading entirely
/// alongside `std.DynLib`'s own Windows support) - declaring the three
/// externs directly here is the normal, supported way to reach a Win32 API
/// Zig hasn't (yet, or any more) pre-declared.
extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;

/// Mirrors `std.DynLib`'s own shape (`open`/`lookup`/`close`) closely enough
/// to drop straight into `scan.zig`/`plugin.zig`'s call sites unchanged.
const WindowsDynLib = struct {
    handle: windows.HMODULE,

    pub const Error = error{FileNotFound};

    pub fn open(path: []const u8) Error!WindowsDynLib {
        var buf: [std.fs.max_path_bytes]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, path) catch return error.FileNotFound;
        if (len >= buf.len) return error.FileNotFound;
        buf[len] = 0;
        const handle = LoadLibraryW(buf[0..len :0]) orelse return error.FileNotFound;
        return .{ .handle = handle };
    }

    pub fn close(self: *WindowsDynLib) void {
        _ = FreeLibrary(self.handle);
    }

    pub fn lookup(self: *WindowsDynLib, comptime T: type, name: [:0]const u8) ?T {
        const symbol = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @as(T, @ptrCast(@alignCast(symbol)));
    }
};

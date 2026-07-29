//! CoreFoundation glue for the macOS VST3 module-entry contract (bundleEntry/
//! bundleExit), mirroring Windows' InitDll/ExitDll and Linux's ModuleEntry/
//! ModuleExit in module.zig. Only ever `@import`ed on macOS builds - see
//! module.zig's `MacosBundle` for the non-macOS stub with the same shape.

const abi = @import("abi.zig");

const CFAllocatorRef = ?*anyopaque;
const CFURLRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const utf8_encoding: u32 = 0x08000100;

extern var kCFAllocatorDefault: CFAllocatorRef;
extern fn CFURLCreateFromFileSystemRepresentation(CFAllocatorRef, [*]const u8, isize, u8) callconv(.c) CFURLRef;
extern fn CFBundleCreate(CFAllocatorRef, CFURLRef) callconv(.c) Bundle;
extern fn CFBundleGetFunctionPointerForName(Bundle, CFStringRef) callconv(.c) ?*anyopaque;
extern fn CFStringCreateWithCString(CFAllocatorRef, [*:0]const u8, u32) callconv(.c) CFStringRef;
extern fn CFRelease(?*anyopaque) callconv(.c) void;

pub const Bundle = ?*anyopaque;

pub fn create(bundle_path: []const u8) !Bundle {
    const url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, bundle_path.ptr, @intCast(bundle_path.len), 1) orelse
        return error.MissingModuleEntry;
    defer CFRelease(url);
    return CFBundleCreate(kCFAllocatorDefault, url) orelse error.MissingModuleEntry;
}

pub fn callEntry(bundle: Bundle) !void {
    const name = CFStringCreateWithCString(kCFAllocatorDefault, "bundleEntry", utf8_encoding) orelse
        return error.MissingModuleEntry;
    defer CFRelease(name);
    const ptr = CFBundleGetFunctionPointerForName(bundle, name) orelse return error.MissingModuleEntry;
    const entry: *const fn (Bundle) callconv(abi.abi_callconv) bool = @ptrCast(ptr);
    if (!entry(bundle)) return error.ModuleEntryFailed;
}

pub fn callExit(bundle: Bundle) void {
    const name = CFStringCreateWithCString(kCFAllocatorDefault, "bundleExit", utf8_encoding) orelse return;
    defer CFRelease(name);
    const ptr = CFBundleGetFunctionPointerForName(bundle, name) orelse return;
    const exit: *const fn () callconv(abi.abi_callconv) bool = @ptrCast(ptr);
    _ = exit();
}

pub fn release(bundle: Bundle) void {
    if (bundle) |b| CFRelease(b);
}

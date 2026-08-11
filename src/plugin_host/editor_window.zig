const std = @import("std");
const builtin = @import("builtin");

pub const Api = enum { win32, cocoa, wayland, x11 };

pub const Window = switch (builtin.os.tag) {
    .linux => X11Window,
    .windows => Win32Window,
    .macos => CocoaWindow,
    else => UnsupportedWindow,
};

const UnsupportedWindow = struct {
    pub fn open(_: i32, _: i32, _: [*:0]const u8) !UnsupportedWindow {
        return error.GuiUnavailable;
    }
    pub fn api(_: *const UnsupportedWindow) Api {
        unreachable;
    }
    pub fn handle(_: *const UnsupportedWindow) usize {
        unreachable;
    }
    pub fn resize(_: *UnsupportedWindow, _: i32, _: i32) void {}
    pub fn show(_: *UnsupportedWindow) void {}
    pub fn hide(_: *UnsupportedWindow) void {}
    pub fn service(_: *UnsupportedWindow) void {}
    pub fn close(_: *UnsupportedWindow) void {}
};

const Win32Window = struct {
    hwnd: *anyopaque,

    pub fn open(width: i32, height: i32, title: [*:0]const u8) !Win32Window {
        var title_w: [512]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_w, std.mem.span(title)) catch return error.InvalidGuiTitle;
        if (title_len == title_w.len) return error.GuiTitleTooLong;
        title_w[title_len] = 0;
        const hwnd = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), @ptrCast(title_w[0..title_len :0]), ws_overlapped_window, cw_use_default, cw_use_default, width, height, null, null, null, null) orelse return error.Win32WindowFailed;
        return .{ .hwnd = hwnd };
    }

    pub fn api(_: *const Win32Window) Api {
        return .win32;
    }

    pub fn handle(self: *const Win32Window) usize {
        return @intFromPtr(self.hwnd);
    }

    pub fn resize(self: *Win32Window, width: i32, height: i32) void {
        _ = SetWindowPos(self.hwnd, null, 0, 0, width, height, swp_no_move | swp_no_zorder | swp_no_activate);
    }

    pub fn show(self: *Win32Window) void {
        _ = ShowWindow(self.hwnd, sw_show);
    }

    pub fn hide(self: *Win32Window) void {
        _ = ShowWindow(self.hwnd, sw_hide);
    }

    pub fn service(_: *Win32Window) void {
        var message: Message = undefined;
        while (PeekMessageW(&message, null, 0, 0, pm_remove) != 0) {
            _ = TranslateMessage(&message);
            _ = DispatchMessageW(&message);
        }
    }

    pub fn close(self: *Win32Window) void {
        _ = DestroyWindow(self.hwnd);
    }

    const Point = extern struct { x: i32, y: i32 };
    const Message = extern struct { hwnd: ?*anyopaque, message: u32, wparam: usize, lparam: isize, time: u32, point: Point, private: u32 };
    const ws_overlapped_window: u32 = 0x00cf0000;
    const cw_use_default: i32 = @bitCast(@as(u32, 0x80000000));
    const swp_no_move: u32 = 0x0002;
    const swp_no_zorder: u32 = 0x0004;
    const swp_no_activate: u32 = 0x0010;
    const pm_remove: u32 = 0x0001;
    const sw_hide: i32 = 0;
    const sw_show: i32 = 5;

    extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "user32" fn DestroyWindow(*anyopaque) callconv(.winapi) i32;
    extern "user32" fn SetWindowPos(*anyopaque, ?*anyopaque, i32, i32, i32, i32, u32) callconv(.winapi) i32;
    extern "user32" fn ShowWindow(*anyopaque, i32) callconv(.winapi) i32;
    extern "user32" fn PeekMessageW(*Message, ?*anyopaque, u32, u32, u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(*const Message) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(*const Message) callconv(.winapi) isize;
};

const CocoaWindow = struct {
    window: *anyopaque,

    pub fn open(width: i32, height: i32, title: [*:0]const u8) !CocoaWindow {
        return .{ .window = wstudio_editor_window_open(width, height, title) orelse return error.CocoaWindowFailed };
    }

    pub fn api(_: *const CocoaWindow) Api {
        return .cocoa;
    }

    pub fn handle(self: *const CocoaWindow) usize {
        return @intFromPtr(wstudio_editor_window_handle(self.window));
    }

    pub fn resize(self: *CocoaWindow, width: i32, height: i32) void {
        wstudio_editor_window_resize(self.window, width, height);
    }

    pub fn show(self: *CocoaWindow) void {
        wstudio_editor_window_show(self.window);
    }

    pub fn hide(self: *CocoaWindow) void {
        wstudio_editor_window_hide(self.window);
    }

    pub fn service(_: *CocoaWindow) void {
        wstudio_editor_window_service();
    }

    pub fn close(self: *CocoaWindow) void {
        wstudio_editor_window_close(self.window);
    }

    extern fn wstudio_editor_window_open(i32, i32, [*:0]const u8) ?*anyopaque;
    extern fn wstudio_editor_window_handle(*anyopaque) *anyopaque;
    extern fn wstudio_editor_window_resize(*anyopaque, i32, i32) void;
    extern fn wstudio_editor_window_show(*anyopaque) void;
    extern fn wstudio_editor_window_hide(*anyopaque) void;
    extern fn wstudio_editor_window_service() void;
    extern fn wstudio_editor_window_close(*anyopaque) void;
};

const X11Window = struct {
    lib: std.DynLib,
    functions: Functions,
    display: *anyopaque,
    id: usize,

    pub fn open(width: i32, height: i32, title: [*:0]const u8) !X11Window {
        var lib = std.DynLib.open("libX11.so.6") catch return error.X11Unavailable;
        errdefer lib.close();
        const functions = try Functions.load(&lib);
        const display = functions.open_display(null) orelse return error.X11DisplayUnavailable;
        errdefer _ = functions.close_display(display);
        const screen = functions.default_screen(display);
        const root = functions.root_window(display, screen);
        const id = functions.create_simple_window(display, root, 0, 0, @intCast(width), @intCast(height), 0, 0, 0);
        if (id == 0) return error.X11WindowFailed;
        _ = functions.store_name(display, id, title);
        _ = functions.flush(display);
        return .{ .lib = lib, .functions = functions, .display = display, .id = id };
    }

    pub fn api(_: *const X11Window) Api {
        return .x11;
    }

    pub fn handle(self: *const X11Window) usize {
        return self.id;
    }

    pub fn resize(self: *X11Window, width: i32, height: i32) void {
        _ = self.functions.resize_window(self.display, self.id, @intCast(width), @intCast(height));
        _ = self.functions.flush(self.display);
    }

    pub fn show(self: *X11Window) void {
        _ = self.functions.map_window(self.display, self.id);
        _ = self.functions.flush(self.display);
    }

    pub fn hide(self: *X11Window) void {
        _ = self.functions.unmap_window(self.display, self.id);
        _ = self.functions.flush(self.display);
    }

    pub fn service(_: *X11Window) void {}

    pub fn close(self: *X11Window) void {
        _ = self.functions.destroy_window(self.display, self.id);
        _ = self.functions.close_display(self.display);
        self.lib.close();
    }

    const Functions = struct {
        open_display: *const fn (?[*:0]const u8) callconv(.c) ?*anyopaque,
        close_display: *const fn (*anyopaque) callconv(.c) c_int,
        default_screen: *const fn (*anyopaque) callconv(.c) c_int,
        root_window: *const fn (*anyopaque, c_int) callconv(.c) usize,
        create_simple_window: *const fn (*anyopaque, usize, c_int, c_int, c_uint, c_uint, c_uint, usize, usize) callconv(.c) usize,
        store_name: *const fn (*anyopaque, usize, [*:0]const u8) callconv(.c) c_int,
        map_window: *const fn (*anyopaque, usize) callconv(.c) c_int,
        unmap_window: *const fn (*anyopaque, usize) callconv(.c) c_int,
        resize_window: *const fn (*anyopaque, usize, c_uint, c_uint) callconv(.c) c_int,
        destroy_window: *const fn (*anyopaque, usize) callconv(.c) c_int,
        flush: *const fn (*anyopaque) callconv(.c) c_int,

        fn load(lib: *std.DynLib) !Functions {
            return .{
                .open_display = lib.lookup(@FieldType(Functions, "open_display"), "XOpenDisplay") orelse return error.X11SymbolMissing,
                .close_display = lib.lookup(@FieldType(Functions, "close_display"), "XCloseDisplay") orelse return error.X11SymbolMissing,
                .default_screen = lib.lookup(@FieldType(Functions, "default_screen"), "XDefaultScreen") orelse return error.X11SymbolMissing,
                .root_window = lib.lookup(@FieldType(Functions, "root_window"), "XRootWindow") orelse return error.X11SymbolMissing,
                .create_simple_window = lib.lookup(@FieldType(Functions, "create_simple_window"), "XCreateSimpleWindow") orelse return error.X11SymbolMissing,
                .store_name = lib.lookup(@FieldType(Functions, "store_name"), "XStoreName") orelse return error.X11SymbolMissing,
                .map_window = lib.lookup(@FieldType(Functions, "map_window"), "XMapWindow") orelse return error.X11SymbolMissing,
                .unmap_window = lib.lookup(@FieldType(Functions, "unmap_window"), "XUnmapWindow") orelse return error.X11SymbolMissing,
                .resize_window = lib.lookup(@FieldType(Functions, "resize_window"), "XResizeWindow") orelse return error.X11SymbolMissing,
                .destroy_window = lib.lookup(@FieldType(Functions, "destroy_window"), "XDestroyWindow") orelse return error.X11SymbolMissing,
                .flush = lib.lookup(@FieldType(Functions, "flush"), "XFlush") orelse return error.X11SymbolMissing,
            };
        }
    };
};

test "editor window platform selection" {
    if (builtin.os.tag == .linux) {
        var window: Window = undefined;
        try std.testing.expectEqual(Api.x11, window.api());
    }
}

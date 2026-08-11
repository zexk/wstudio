const std = @import("std");
const builtin = @import("builtin");

pub const Api = enum { win32, cocoa, wayland, x11 };
pub const Size = struct { width: i32, height: i32 };

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
    pub fn service(_: *UnsupportedWindow) bool {
        return true;
    }
    pub fn takeResize(_: *UnsupportedWindow) ?Size {
        return null;
    }
    pub fn close(_: *UnsupportedWindow) void {}
};

const Win32Window = struct {
    hwnd: *anyopaque,
    pending_resize: ?Size = null,

    pub fn open(width: i32, height: i32, title: [*:0]const u8) !Win32Window {
        var title_w: [512]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_w, std.mem.span(title)) catch return error.InvalidGuiTitle;
        if (title_len == title_w.len) return error.GuiTitleTooLong;
        title_w[title_len] = 0;
        const size = frameSize(width, height);
        const hwnd = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), @ptrCast(title_w[0..title_len :0]), ws_overlapped_window, cw_use_default, cw_use_default, size.width, size.height, null, null, null, null) orelse return error.Win32WindowFailed;
        return .{ .hwnd = hwnd };
    }

    pub fn api(_: *const Win32Window) Api {
        return .win32;
    }

    pub fn handle(self: *const Win32Window) usize {
        return @intFromPtr(self.hwnd);
    }

    pub fn resize(self: *Win32Window, width: i32, height: i32) void {
        const size = frameSize(width, height);
        _ = SetWindowPos(self.hwnd, null, 0, 0, size.width, size.height, swp_no_move | swp_no_zorder | swp_no_activate);
    }

    pub fn show(self: *Win32Window) void {
        _ = ShowWindow(self.hwnd, sw_show);
    }

    pub fn hide(self: *Win32Window) void {
        _ = ShowWindow(self.hwnd, sw_hide);
    }

    pub fn service(self: *Win32Window) bool {
        var message: Message = undefined;
        while (PeekMessageW(&message, null, 0, 0, pm_remove) != 0) {
            if (message.hwnd == self.hwnd and message.message == wm_size)
                self.pending_resize = .{ .width = @intCast(message.lparam & 0xffff), .height = @intCast(message.lparam >> 16 & 0xffff) };
            _ = TranslateMessage(&message);
            _ = DispatchMessageW(&message);
        }
        return IsWindow(self.hwnd) != 0;
    }

    pub fn takeResize(self: *Win32Window) ?Size {
        const size = self.pending_resize;
        self.pending_resize = null;
        return size;
    }

    pub fn close(self: *Win32Window) void {
        _ = DestroyWindow(self.hwnd);
    }

    fn frameSize(width: i32, height: i32) Size {
        var rect = Rect{ .left = 0, .top = 0, .right = width, .bottom = height };
        _ = AdjustWindowRectEx(&rect, ws_overlapped_window, 0, 0);
        return .{ .width = rect.right - rect.left, .height = rect.bottom - rect.top };
    }

    const Point = extern struct { x: i32, y: i32 };
    const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
    const Message = extern struct { hwnd: ?*anyopaque, message: u32, wparam: usize, lparam: isize, time: u32, point: Point, private: u32 };
    const ws_overlapped_window: u32 = 0x00cf0000;
    const cw_use_default: i32 = @bitCast(@as(u32, 0x80000000));
    const swp_no_move: u32 = 0x0002;
    const swp_no_zorder: u32 = 0x0004;
    const swp_no_activate: u32 = 0x0010;
    const pm_remove: u32 = 0x0001;
    const wm_size: u32 = 0x0005;
    const sw_hide: i32 = 0;
    const sw_show: i32 = 5;

    extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "user32" fn DestroyWindow(*anyopaque) callconv(.winapi) i32;
    extern "user32" fn AdjustWindowRectEx(*Rect, u32, i32, u32) callconv(.winapi) i32;
    extern "user32" fn SetWindowPos(*anyopaque, ?*anyopaque, i32, i32, i32, i32, u32) callconv(.winapi) i32;
    extern "user32" fn ShowWindow(*anyopaque, i32) callconv(.winapi) i32;
    extern "user32" fn IsWindow(*anyopaque) callconv(.winapi) i32;
    extern "user32" fn PeekMessageW(*Message, ?*anyopaque, u32, u32, u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(*const Message) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(*const Message) callconv(.winapi) isize;
};

const CocoaWindow = struct {
    window: *anyopaque,
    visible: bool = false,
    width: i32,
    height: i32,
    pending_resize: ?Size = null,

    pub fn open(width: i32, height: i32, title: [*:0]const u8) !CocoaWindow {
        return .{ .window = wstudio_editor_window_open(width, height, title) orelse return error.CocoaWindowFailed, .width = width, .height = height };
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
        self.visible = true;
    }

    pub fn hide(self: *CocoaWindow) void {
        wstudio_editor_window_hide(self.window);
        self.visible = false;
    }

    pub fn service(self: *CocoaWindow) bool {
        wstudio_editor_window_service();
        var width: i32 = 0;
        var height: i32 = 0;
        wstudio_editor_window_size(self.window, &width, &height);
        if (width != self.width or height != self.height) {
            self.width = width;
            self.height = height;
            self.pending_resize = .{ .width = width, .height = height };
        }
        return !self.visible or wstudio_editor_window_visible(self.window);
    }

    pub fn takeResize(self: *CocoaWindow) ?Size {
        const size = self.pending_resize;
        self.pending_resize = null;
        return size;
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
    extern fn wstudio_editor_window_visible(*anyopaque) bool;
    extern fn wstudio_editor_window_size(*anyopaque, *i32, *i32) void;
    extern fn wstudio_editor_window_close(*anyopaque) void;
};

const X11Window = struct {
    lib: std.DynLib,
    functions: Functions,
    display: *anyopaque,
    id: usize,
    delete_atom: usize,
    pending_resize: ?Size = null,

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
        const delete_atom = functions.intern_atom(display, "WM_DELETE_WINDOW", 0);
        if (delete_atom == 0 or functions.set_wm_protocols(display, id, @constCast(&delete_atom), 1) == 0) return error.X11WindowProtocolFailed;
        _ = functions.flush(display);
        return .{ .lib = lib, .functions = functions, .display = display, .id = id, .delete_atom = delete_atom };
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

    pub fn service(self: *X11Window) bool {
        var event: XEvent = undefined;
        while (self.functions.pending(self.display) != 0) {
            _ = self.functions.next_event(self.display, &event);
            if (event.client.type == 33 and event.client.data.l[0] == @as(c_long, @intCast(self.delete_atom))) return false;
            if (event.configure.type == 22)
                self.pending_resize = .{ .width = event.configure.width, .height = event.configure.height };
        }
        return true;
    }

    pub fn takeResize(self: *X11Window) ?Size {
        const size = self.pending_resize;
        self.pending_resize = null;
        return size;
    }

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
        intern_atom: *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) usize,
        set_wm_protocols: *const fn (*anyopaque, usize, *usize, c_int) callconv(.c) c_int,
        pending: *const fn (*anyopaque) callconv(.c) c_int,
        next_event: *const fn (*anyopaque, *XEvent) callconv(.c) c_int,
        send_event: *const fn (*anyopaque, usize, c_int, c_long, *XEvent) callconv(.c) c_int,

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
                .intern_atom = lib.lookup(@FieldType(Functions, "intern_atom"), "XInternAtom") orelse return error.X11SymbolMissing,
                .set_wm_protocols = lib.lookup(@FieldType(Functions, "set_wm_protocols"), "XSetWMProtocols") orelse return error.X11SymbolMissing,
                .pending = lib.lookup(@FieldType(Functions, "pending"), "XPending") orelse return error.X11SymbolMissing,
                .next_event = lib.lookup(@FieldType(Functions, "next_event"), "XNextEvent") orelse return error.X11SymbolMissing,
                .send_event = lib.lookup(@FieldType(Functions, "send_event"), "XSendEvent") orelse return error.X11SymbolMissing,
            };
        }
    };

    const ClientData = extern union { b: [20]u8, s: [10]i16, l: [5]c_long };
    const ClientMessage = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: *anyopaque,
        window: c_ulong,
        message_type: c_ulong,
        format: c_int,
        data: ClientData,
    };
    const ConfigureEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: *anyopaque,
        event: c_ulong,
        window: c_ulong,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        border_width: c_int,
        above: c_ulong,
        override_redirect: c_int,
    };
    const XEvent = extern union { type: c_int, client: ClientMessage, configure: ConfigureEvent, pad: [24]c_long };
};

test "editor window platform selection" {
    if (builtin.os.tag == .linux) {
        var window: Window = undefined;
        try std.testing.expectEqual(Api.x11, window.api());
    }
}

test "X11 close request reaches host lifecycle" {
    if (builtin.os.tag != .linux or std.c.getenv("DISPLAY") == null) return;
    var window = try Window.open(64, 64, "wstudio GUI test");
    defer window.close();
    var event: X11Window.XEvent = std.mem.zeroes(X11Window.XEvent);
    event.configure = .{
        .type = 22,
        .serial = 0,
        .send_event = 1,
        .display = window.display,
        .event = window.id,
        .window = window.id,
        .x = 0,
        .y = 0,
        .width = 96,
        .height = 80,
        .border_width = 0,
        .above = 0,
        .override_redirect = 0,
    };
    try std.testing.expect(window.functions.send_event(window.display, window.id, 0, 0, &event) != 0);
    _ = window.functions.flush(window.display);
    try std.testing.expect(window.service());
    try std.testing.expectEqual(Size{ .width = 96, .height = 80 }, window.takeResize().?);
    event.client = .{
        .type = 33,
        .serial = 0,
        .send_event = 1,
        .display = window.display,
        .window = window.id,
        .message_type = window.functions.intern_atom(window.display, "WM_PROTOCOLS", 0),
        .format = 32,
        .data = .{ .l = .{ @intCast(window.delete_atom), 0, 0, 0, 0 } },
    };
    try std.testing.expect(window.functions.send_event(window.display, window.id, 0, 0, &event) != 0);
    _ = window.functions.flush(window.display);
    try std.testing.expect(!window.service());
}

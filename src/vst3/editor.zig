const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");

pub const supported = builtin.os.tag == .linux;
pub const platform_type: [*:0]const u8 = "X11EmbedWindowID";

pub const Editor = if (supported) LinuxEditor else struct {
    pub fn open(_: *abi.EditController, _: [*:0]const u8) !@This() {
        return error.GuiUnavailable;
    }
    pub fn close(_: *@This()) void {}
    pub fn service(_: *@This()) void {}
};

const LinuxEditor = struct {
    view: *abi.PlugView,
    window: *X11Window,
    frame: *Frame,

    pub fn open(controller: *abi.EditController, title: [*:0]const u8) !LinuxEditor {
        const raw = controller.vtable.create_view(controller, "editor") orelse return error.GuiUnavailable;
        const view: *abi.PlugView = @ptrCast(@alignCast(raw));
        errdefer _ = view.vtable.release(view);
        if (view.vtable.is_platform_type_supported(view, platform_type) != 0) return error.GuiUnavailable;
        var rect: abi.ViewRect = undefined;
        if (view.vtable.get_size(view, &rect) != 0) return error.GuiSizeFailed;
        const window = try std.heap.page_allocator.create(X11Window);
        errdefer std.heap.page_allocator.destroy(window);
        window.* = try X11Window.open(@max(rect.right - rect.left, 1), @max(rect.bottom - rect.top, 1), title);
        errdefer window.close();
        const frame = try std.heap.page_allocator.create(Frame);
        errdefer std.heap.page_allocator.destroy(frame);
        frame.* = .{ .window = window };
        if (view.vtable.set_frame(view, &frame.interface) != 0) return error.GuiFrameFailed;
        errdefer _ = view.vtable.set_frame(view, null);
        if (view.vtable.attached(view, @ptrFromInt(window.id), platform_type) != 0) return error.GuiAttachFailed;
        return .{ .view = view, .window = window, .frame = frame };
    }

    pub fn close(self: *LinuxEditor) void {
        _ = self.view.vtable.removed(self.view);
        _ = self.view.vtable.set_frame(self.view, null);
        self.frame.deinit();
        _ = self.view.vtable.release(self.view);
        self.window.close();
        std.heap.page_allocator.destroy(self.frame);
        std.heap.page_allocator.destroy(self.window);
    }

    pub fn service(self: *LinuxEditor) void {
        self.frame.service();
    }
};

const Frame = struct {
    interface: abi.PlugFrame = .{ .vtable = &vtable },
    run_loop: abi.RunLoop = .{ .vtable = &run_loop_vtable },
    window: *X11Window,
    // ponytail: fixed banks avoid allocation in plugin callbacks. Raise only
    // if a real editor exhausts 16 event handlers or timers.
    events: [16]?Event = @splat(null),
    timers: [16]?Timer = @splat(null),

    const Event = struct { handler: *abi.EventHandler, fd: c_int };
    const Timer = struct { handler: *abi.TimerHandler, interval_ns: u64, next_ns: i128 };

    fn from(raw: *anyopaque) *Frame {
        return @alignCast(@fieldParentPtr("interface", @as(*abi.PlugFrame, @ptrCast(@alignCast(raw)))));
    }
    fn runLoopFrom(raw: *anyopaque) *Frame {
        return @alignCast(@fieldParentPtr("run_loop", @as(*abi.RunLoop, @ptrCast(@alignCast(raw)))));
    }
    fn queryFrame(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        return from(raw).query(iid, object);
    }
    fn queryRunLoop(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        return runLoopFrom(raw).query(iid, object);
    }
    fn query(self: *Frame, iid: *const abi.Tuid, object: *?*anyopaque) abi.Result {
        if (std.mem.eql(u8, iid, &abi.f_unknown_iid) or std.mem.eql(u8, iid, &abi.plug_frame_iid)) {
            object.* = &self.interface;
            return 0;
        }
        if (std.mem.eql(u8, iid, &abi.run_loop_iid)) {
            object.* = &self.run_loop;
            return 0;
        }
        object.* = null;
        return -1;
    }
    fn ref(_: *anyopaque) callconv(abi.abi_callconv) u32 {
        return 1;
    }
    fn resize(raw: *anyopaque, view: *abi.PlugView, rect: *abi.ViewRect) callconv(abi.abi_callconv) abi.Result {
        const self = from(raw);
        self.window.resize(@max(rect.right - rect.left, 1), @max(rect.bottom - rect.top, 1));
        return view.vtable.on_size(view, rect);
    }

    fn registerEvent(raw: *anyopaque, handler: *abi.EventHandler, fd: c_int) callconv(abi.abi_callconv) abi.Result {
        const self = runLoopFrom(raw);
        for (&self.events) |*slot| if (slot.* == null) {
            slot.* = .{ .handler = handler, .fd = fd };
            _ = handler.vtable.add_ref(handler);
            return 0;
        };
        return 1;
    }
    fn unregisterEvent(raw: *anyopaque, handler: *abi.EventHandler) callconv(abi.abi_callconv) abi.Result {
        const self = runLoopFrom(raw);
        for (&self.events) |*slot| if (slot.*) |event| {
            if (event.handler != handler) continue;
            _ = handler.vtable.release(handler);
            slot.* = null;
            return 0;
        };
        return 1;
    }
    fn registerTimer(raw: *anyopaque, handler: *abi.TimerHandler, milliseconds: u64) callconv(abi.abi_callconv) abi.Result {
        const self = runLoopFrom(raw);
        const interval = @max(@min(milliseconds, 86_400_000), 1) * std.time.ns_per_ms;
        const now: i128 = @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds);
        for (&self.timers) |*slot| if (slot.* == null) {
            slot.* = .{ .handler = handler, .interval_ns = interval, .next_ns = now + interval };
            _ = handler.vtable.add_ref(handler);
            return 0;
        };
        return 1;
    }
    fn unregisterTimer(raw: *anyopaque, handler: *abi.TimerHandler) callconv(abi.abi_callconv) abi.Result {
        const self = runLoopFrom(raw);
        for (&self.timers) |*slot| if (slot.*) |timer| {
            if (timer.handler != handler) continue;
            _ = handler.vtable.release(handler);
            slot.* = null;
            return 0;
        };
        return 1;
    }

    fn service(self: *Frame) void {
        var poll_fds: [16]std.posix.pollfd = undefined;
        var handlers: [16]*abi.EventHandler = undefined;
        var count: usize = 0;
        for (self.events) |maybe| if (maybe) |event| {
            poll_fds[count] = .{ .fd = event.fd, .events = std.posix.POLL.IN, .revents = 0 };
            handlers[count] = event.handler;
            count += 1;
        };
        if (count != 0 and (std.posix.poll(poll_fds[0..count], 0) catch 0) != 0) {
            for (poll_fds[0..count], handlers[0..count]) |fd, handler| if (fd.revents != 0) handler.vtable.on_fd_is_set(handler, fd.fd);
        }
        const now: i128 = @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds);
        for (&self.timers) |*slot| if (slot.*) |*timer| {
            if (now < timer.next_ns) continue;
            timer.next_ns = now + timer.interval_ns;
            timer.handler.vtable.on_timer(timer.handler);
        };
    }

    fn deinit(self: *Frame) void {
        for (&self.events) |*slot| if (slot.*) |event| {
            _ = event.handler.vtable.release(event.handler);
            slot.* = null;
        };
        for (&self.timers) |*slot| if (slot.*) |timer| {
            _ = timer.handler.vtable.release(timer.handler);
            slot.* = null;
        };
    }

    const vtable: abi.PlugFrameVTable = .{ .query_interface = queryFrame, .add_ref = ref, .release = ref, .resize_view = resize };
    const run_loop_vtable: abi.RunLoopVTable = .{ .query_interface = queryRunLoop, .add_ref = ref, .release = ref, .register_event_handler = registerEvent, .unregister_event_handler = unregisterEvent, .register_timer = registerTimer, .unregister_timer = unregisterTimer };
};

const X11Window = struct {
    lib: std.DynLib,
    api: Api,
    display: *anyopaque,
    id: usize,

    fn open(width: i32, height: i32, title: [*:0]const u8) !X11Window {
        var lib = std.DynLib.open("libX11.so.6") catch return error.X11Unavailable;
        errdefer lib.close();
        const api = try Api.load(&lib);
        const display = api.open_display(null) orelse return error.X11DisplayUnavailable;
        errdefer _ = api.close_display(display);
        const screen = api.default_screen(display);
        const root = api.root_window(display, screen);
        const id = api.create_simple_window(display, root, 0, 0, @intCast(width), @intCast(height), 0, 0, 0);
        if (id == 0) return error.X11WindowFailed;
        _ = api.store_name(display, id, title);
        _ = api.map_window(display, id);
        _ = api.flush(display);
        return .{ .lib = lib, .api = api, .display = display, .id = id };
    }

    fn resize(self: *X11Window, width: i32, height: i32) void {
        _ = self.api.resize_window(self.display, self.id, @intCast(width), @intCast(height));
        _ = self.api.flush(self.display);
    }

    fn close(self: *X11Window) void {
        _ = self.api.destroy_window(self.display, self.id);
        _ = self.api.close_display(self.display);
        self.lib.close();
    }

    const Api = struct {
        open_display: *const fn (?[*:0]const u8) callconv(.c) ?*anyopaque,
        close_display: *const fn (*anyopaque) callconv(.c) c_int,
        default_screen: *const fn (*anyopaque) callconv(.c) c_int,
        root_window: *const fn (*anyopaque, c_int) callconv(.c) usize,
        create_simple_window: *const fn (*anyopaque, usize, c_int, c_int, c_uint, c_uint, c_uint, usize, usize) callconv(.c) usize,
        store_name: *const fn (*anyopaque, usize, [*:0]const u8) callconv(.c) c_int,
        map_window: *const fn (*anyopaque, usize) callconv(.c) c_int,
        resize_window: *const fn (*anyopaque, usize, c_uint, c_uint) callconv(.c) c_int,
        destroy_window: *const fn (*anyopaque, usize) callconv(.c) c_int,
        flush: *const fn (*anyopaque) callconv(.c) c_int,

        fn load(lib: *std.DynLib) !Api {
            return .{
                .open_display = lib.lookup(@FieldType(Api, "open_display"), "XOpenDisplay") orelse return error.X11SymbolMissing,
                .close_display = lib.lookup(@FieldType(Api, "close_display"), "XCloseDisplay") orelse return error.X11SymbolMissing,
                .default_screen = lib.lookup(@FieldType(Api, "default_screen"), "XDefaultScreen") orelse return error.X11SymbolMissing,
                .root_window = lib.lookup(@FieldType(Api, "root_window"), "XRootWindow") orelse return error.X11SymbolMissing,
                .create_simple_window = lib.lookup(@FieldType(Api, "create_simple_window"), "XCreateSimpleWindow") orelse return error.X11SymbolMissing,
                .store_name = lib.lookup(@FieldType(Api, "store_name"), "XStoreName") orelse return error.X11SymbolMissing,
                .map_window = lib.lookup(@FieldType(Api, "map_window"), "XMapWindow") orelse return error.X11SymbolMissing,
                .resize_window = lib.lookup(@FieldType(Api, "resize_window"), "XResizeWindow") orelse return error.X11SymbolMissing,
                .destroy_window = lib.lookup(@FieldType(Api, "destroy_window"), "XDestroyWindow") orelse return error.X11SymbolMissing,
                .flush = lib.lookup(@FieldType(Api, "flush"), "XFlush") orelse return error.X11SymbolMissing,
            };
        }
    };
};

test "plug frame exposes Linux run loop" {
    if (!supported) return;
    var frame = Frame{ .window = undefined };
    var object: ?*anyopaque = null;
    try std.testing.expectEqual(@as(abi.Result, 0), frame.interface.vtable.query_interface(&frame.interface, &abi.run_loop_iid, &object));
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&frame.run_loop)), object);
}

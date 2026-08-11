const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const editor_window = @import("../plugin_host/editor_window.zig");

pub const supported = builtin.os.tag == .linux or builtin.os.tag == .windows or builtin.os.tag == .macos;
pub const platform_type: [*:0]const u8 = switch (builtin.os.tag) {
    .windows => "HWND",
    .macos => "NSView",
    else => "X11EmbedWindowID",
};

pub const Editor = if (supported) NativeEditor else struct {
    pub fn open(_: *abi.EditController, _: [*:0]const u8) !@This() {
        return error.GuiUnavailable;
    }
    pub fn close(_: *@This()) void {}
    pub fn service(_: *@This()) bool {
        return true;
    }
};

const NativeEditor = struct {
    view: *abi.PlugView,
    window: *editor_window.Window,
    frame: *Frame,

    pub fn open(controller: *abi.EditController, title: [*:0]const u8) !NativeEditor {
        const raw = controller.vtable.create_view(controller, "editor") orelse return error.GuiUnavailable;
        const view: *abi.PlugView = @ptrCast(@alignCast(raw));
        errdefer _ = view.vtable.release(view);
        if (view.vtable.is_platform_type_supported(view, platform_type) != 0) return error.GuiUnavailable;
        var rect: abi.ViewRect = undefined;
        if (view.vtable.get_size(view, &rect) != 0) return error.GuiSizeFailed;
        const window = try std.heap.page_allocator.create(editor_window.Window);
        errdefer std.heap.page_allocator.destroy(window);
        window.* = try editor_window.Window.open(@max(rect.right - rect.left, 1), @max(rect.bottom - rect.top, 1), title);
        errdefer window.close();
        const frame = try std.heap.page_allocator.create(Frame);
        errdefer std.heap.page_allocator.destroy(frame);
        frame.* = .{ .window = window, .view = view };
        if (view.vtable.set_frame(view, &frame.interface) != 0) return error.GuiFrameFailed;
        errdefer _ = view.vtable.set_frame(view, null);
        if (view.vtable.attached(view, @ptrFromInt(window.handle()), platform_type) != 0) return error.GuiAttachFailed;
        window.show();
        return .{ .view = view, .window = window, .frame = frame };
    }

    pub fn close(self: *NativeEditor) void {
        _ = self.view.vtable.removed(self.view);
        _ = self.view.vtable.set_frame(self.view, null);
        self.frame.deinit();
        _ = self.view.vtable.release(self.view);
        self.window.close();
        std.heap.page_allocator.destroy(self.frame);
        std.heap.page_allocator.destroy(self.window);
    }

    pub fn service(self: *NativeEditor) bool {
        return self.frame.service();
    }
};

const Frame = struct {
    interface: abi.PlugFrame = .{ .vtable = &vtable },
    run_loop: abi.RunLoop = .{ .vtable = &run_loop_vtable },
    window: *editor_window.Window,
    view: *abi.PlugView,
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
        if (builtin.os.tag == .linux and std.mem.eql(u8, iid, &abi.run_loop_iid)) {
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

    fn service(self: *Frame) bool {
        if (!self.window.service()) return false;
        if (self.window.takeResize()) |size| if (size.width > 0 and size.height > 0) {
            var rect: abi.ViewRect = .{ .left = 0, .top = 0, .right = size.width, .bottom = size.height };
            _ = self.view.vtable.check_size_constraint(self.view, &rect);
            if (rect.right != size.width or rect.bottom != size.height)
                self.window.resize(@max(rect.right, 1), @max(rect.bottom, 1));
            _ = self.view.vtable.on_size(self.view, &rect);
        };
        if (comptime builtin.os.tag != .linux) return true;
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
        return true;
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

test "plug frame exposes Linux run loop" {
    if (builtin.os.tag != .linux) return;
    var frame = Frame{ .window = undefined, .view = undefined };
    var object: ?*anyopaque = null;
    try std.testing.expectEqual(@as(abi.Result, 0), frame.interface.vtable.query_interface(&frame.interface, &abi.run_loop_iid, &object));
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&frame.run_loop)), object);
}

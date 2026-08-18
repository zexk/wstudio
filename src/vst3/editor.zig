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
        window.* = try editor_window.Window.open(@max(rect.right - rect.left, 1), @max(rect.bottom - rect.top, 1), title, view.vtable.can_resize(view) == 0);
        errdefer window.close();
        const frame = try std.heap.page_allocator.create(Frame);
        errdefer std.heap.page_allocator.destroy(frame);
        frame.* = .{ .window = window, .view = view };
        if (view.vtable.set_frame(view, &frame.interface) != 0) return error.GuiFrameFailed;
        errdefer _ = view.vtable.set_frame(view, null);
        if (view.vtable.attached(view, @ptrFromInt(window.handle()), platform_type) != 0) return error.GuiAttachFailed;
        // The size before `attached` is the plugin's guess about a window it
        // has not seen yet; the size after is the one it will actually draw.
        // JUCE editors in particular report a placeholder until attachment.
        var attached_rect: abi.ViewRect = undefined;
        if (view.vtable.get_size(view, &attached_rect) == 0) {
            const w = @max(attached_rect.right - attached_rect.left, 1);
            const h = @max(attached_rect.bottom - attached_rect.top, 1);
            if (w != @max(rect.right - rect.left, 1) or h != @max(rect.bottom - rect.top, 1)) window.resize(w, h);
        }
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
    /// Registered fd handlers and timers. Slots are nulled on unregister
    /// rather than removed, so an index stays valid across a callback that
    /// registers or unregisters from inside `service` - the lists only ever
    /// grow to a plugin's own high-water mark. Registration runs on the UI
    /// thread (never the audio thread), so allocating here is fine; a failed
    /// allocation reports the same refusal a full bank used to.
    events: std.ArrayListUnmanaged(?Event) = .empty,
    timers: std.ArrayListUnmanaged(?Timer) = .empty,
    /// Scratch for `service`'s poll, kept across calls so a steady-state
    /// frame allocates nothing.
    poll_fds: std.ArrayListUnmanaged(std.posix.pollfd) = .empty,
    poll_handlers: std.ArrayListUnmanaged(*abi.EventHandler) = .empty,

    const allocator = std.heap.page_allocator;

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
        for (self.events.items) |*slot| if (slot.* == null) {
            slot.* = .{ .handler = handler, .fd = fd };
            _ = handler.vtable.add_ref(handler);
            return 0;
        };
        self.events.append(allocator, .{ .handler = handler, .fd = fd }) catch return 1;
        _ = handler.vtable.add_ref(handler);
        return 0;
    }
    fn unregisterEvent(raw: *anyopaque, handler: *abi.EventHandler) callconv(abi.abi_callconv) abi.Result {
        const self = runLoopFrom(raw);
        for (self.events.items) |*slot| if (slot.*) |event| {
            if (event.handler != handler) continue;
            _ = handler.vtable.release(handler);
            slot.* = null;
            return 0;
        };
        return 1;
    }
    fn registerTimer(raw: *anyopaque, handler: *abi.TimerHandler, milliseconds: u64) callconv(abi.abi_callconv) abi.Result {
        const self = runLoopFrom(raw);
        // `@min` narrows to the smallest type holding the literal (u27 here),
        // so the multiply must not happen in that inferred type: 86_400_000 *
        // ns_per_ms overflows it. Annotating the cap as u64 first is what
        // keeps the product in range.
        const capped_ms: u64 = @max(@min(milliseconds, 86_400_000), 1);
        const interval = capped_ms * std.time.ns_per_ms;
        const now: i128 = @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds);
        for (self.timers.items) |*slot| if (slot.* == null) {
            slot.* = .{ .handler = handler, .interval_ns = interval, .next_ns = now + interval };
            _ = handler.vtable.add_ref(handler);
            return 0;
        };
        self.timers.append(allocator, .{ .handler = handler, .interval_ns = interval, .next_ns = now + interval }) catch return 1;
        _ = handler.vtable.add_ref(handler);
        return 0;
    }
    fn unregisterTimer(raw: *anyopaque, handler: *abi.TimerHandler) callconv(abi.abi_callconv) abi.Result {
        const self = runLoopFrom(raw);
        for (self.timers.items) |*slot| if (slot.*) |timer| {
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
        self.poll_fds.clearRetainingCapacity();
        self.poll_handlers.clearRetainingCapacity();
        for (self.events.items) |maybe| if (maybe) |event| {
            // A failed reserve just polls fewer fds this tick; the handler
            // stays registered and is picked up on the next one.
            self.poll_fds.append(allocator, .{ .fd = event.fd, .events = std.posix.POLL.IN, .revents = 0 }) catch break;
            self.poll_handlers.append(allocator, event.handler) catch {
                _ = self.poll_fds.pop();
                break;
            };
        };
        if (self.poll_fds.items.len != 0 and (std.posix.poll(self.poll_fds.items, 0) catch 0) != 0) {
            for (self.poll_fds.items, self.poll_handlers.items) |fd, handler| if (fd.revents != 0) handler.vtable.on_fd_is_set(handler, fd.fd);
        }
        const now: i128 = @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds);
        // Index loop, not a slice iterator: `on_timer` may register another
        // timer and grow the list out from under a captured slice.
        var i: usize = 0;
        while (i < self.timers.items.len) : (i += 1) {
            const timer = &(self.timers.items[i] orelse continue);
            if (now < timer.next_ns) continue;
            timer.next_ns = now + timer.interval_ns;
            const handler = timer.handler;
            handler.vtable.on_timer(handler);
        }
        return true;
    }

    fn deinit(self: *Frame) void {
        for (self.events.items) |slot| if (slot) |event| {
            _ = event.handler.vtable.release(event.handler);
        };
        for (self.timers.items) |slot| if (slot) |timer| {
            _ = timer.handler.vtable.release(timer.handler);
        };
        self.events.deinit(allocator);
        self.timers.deinit(allocator);
        self.poll_fds.deinit(allocator);
        self.poll_handlers.deinit(allocator);
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

test "the run loop takes more handlers than any fixed bank, and reuses freed slots" {
    if (builtin.os.tag != .linux) return;
    const stub = struct {
        var refs: i32 = 0;
        fn query(_: *anyopaque, _: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
            object.* = null;
            return -1;
        }
        fn addRef(_: *anyopaque) callconv(abi.abi_callconv) u32 {
            refs += 1;
            return 1;
        }
        fn release(_: *anyopaque) callconv(abi.abi_callconv) u32 {
            refs -= 1;
            return 1;
        }
        fn onFd(_: *anyopaque, _: c_int) callconv(abi.abi_callconv) void {}
        fn onTimer(_: *anyopaque) callconv(abi.abi_callconv) void {}
        const event_vtable: abi.EventHandlerVTable = .{ .query_interface = query, .add_ref = addRef, .release = release, .on_fd_is_set = onFd };
        const timer_vtable: abi.TimerHandlerVTable = .{ .query_interface = query, .add_ref = addRef, .release = release, .on_timer = onTimer };
    };

    var frame = Frame{ .window = undefined, .view = undefined };
    defer frame.deinit();
    const run_loop = &frame.run_loop;

    // 20 of each - past the 16 slots the fixed banks used to hold.
    var events: [20]abi.EventHandler = @splat(.{ .vtable = &stub.event_vtable });
    var timers: [20]abi.TimerHandler = @splat(.{ .vtable = &stub.timer_vtable });
    for (&events, 0..) |*handler, i| {
        try std.testing.expectEqual(@as(abi.Result, 0), run_loop.vtable.register_event_handler(run_loop, handler, @intCast(i)));
    }
    for (&timers) |*handler| {
        try std.testing.expectEqual(@as(abi.Result, 0), run_loop.vtable.register_timer(run_loop, handler, 10));
    }
    try std.testing.expectEqual(@as(usize, 20), frame.events.items.len);
    try std.testing.expectEqual(@as(usize, 20), frame.timers.items.len);
    try std.testing.expectEqual(@as(i32, 40), stub.refs);

    // Unregistering frees a slot for reuse rather than growing the list.
    try std.testing.expectEqual(@as(abi.Result, 0), run_loop.vtable.unregister_event_handler(run_loop, &events[3]));
    try std.testing.expectEqual(@as(abi.Result, 1), run_loop.vtable.unregister_event_handler(run_loop, &events[3]));
    try std.testing.expectEqual(@as(abi.Result, 0), run_loop.vtable.register_event_handler(run_loop, &events[3], 3));
    try std.testing.expectEqual(@as(usize, 20), frame.events.items.len);
}

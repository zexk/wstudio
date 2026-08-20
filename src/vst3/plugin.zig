//! VST3 component loader and realtime-safe mono/stereo audio adapter.

const std = @import("std");
const abi = @import("abi.zig");
const module_mod = @import("module.zig");
const scan = @import("scan.zig");
const device_mod = @import("../dsp/device.zig");
const types = @import("../core/types.zig");
const Transport = @import("../transport.zig").Transport;
const bridge_mod = @import("../plugin_host/bridge.zig");
const wire = @import("../plugin_host/transport.zig");
const editor_mod = @import("editor.zig");

const max_events = 256;
const max_param_changes = 64;
const max_parameters = 256;
const MemoryStream = struct {
    interface: abi.Stream = .{ .vtable = &vtable },
    allocator: std.mem.Allocator,
    data: std.ArrayListUnmanaged(u8) = .empty,
    position: usize = 0,

    fn from(raw: *anyopaque) *MemoryStream {
        return @ptrCast(@alignCast(raw));
    }
    /// Only the two interfaces this stream really is. Answering "yes" to
    /// every id hands the caller an `IBStream` vtable under another
    /// interface's name: JUCE asks a state stream for `IStreamAttributes`,
    /// then calls what it believes is `getFileName` and lands on `read`.
    /// Surge XT, Odin 2, and CHOW Tape all crashed in `setState` that way.
    fn query(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        if (!std.mem.eql(u8, iid, &abi.bstream_iid) and !std.mem.eql(u8, iid, &abi.f_unknown_iid)) {
            object.* = null;
            return -1;
        }
        object.* = raw;
        return 0;
    }
    fn ref(_: *anyopaque) callconv(abi.abi_callconv) u32 {
        return 1;
    }
    fn read(raw: *anyopaque, destination: *anyopaque, count: i32, read_count: ?*i32) callconv(abi.abi_callconv) abi.Result {
        const self = from(raw);
        if (count < 0) return -1;
        const len = @min(@as(usize, @intCast(count)), self.data.items.len -| self.position);
        @memcpy(@as([*]u8, @ptrCast(destination))[0..len], self.data.items[self.position..][0..len]);
        self.position += len;
        if (read_count) |out| out.* = @intCast(len);
        return 0;
    }
    fn write(raw: *anyopaque, source: *const anyopaque, count: i32, written: ?*i32) callconv(abi.abi_callconv) abi.Result {
        const self = from(raw);
        if (count < 0) return -1;
        const len: usize = @intCast(count);
        const end = std.math.add(usize, self.position, len) catch return -1;
        self.data.resize(self.allocator, end) catch return -1;
        @memcpy(self.data.items[self.position..end], @as([*]const u8, @ptrCast(source))[0..len]);
        self.position = end;
        if (written) |out| out.* = count;
        return 0;
    }
    fn seek(raw: *anyopaque, offset: i64, mode: i32, result: ?*i64) callconv(abi.abi_callconv) abi.Result {
        const self = from(raw);
        const base: i64 = switch (mode) {
            0 => 0,
            1 => @intCast(self.position),
            2 => @intCast(self.data.items.len),
            else => return -1,
        };
        const target = std.math.add(i64, base, offset) catch return -1;
        if (target < 0) return -1;
        self.position = @intCast(target);
        if (result) |out| out.* = target;
        return 0;
    }
    fn tell(raw: *anyopaque, result: ?*i64) callconv(abi.abi_callconv) abi.Result {
        if (result) |out| out.* = @intCast(from(raw).position);
        return 0;
    }
    const vtable: abi.StreamVTable = .{ .query_interface = query, .add_ref = ref, .release = ref, .read = read, .write = write, .seek = seek, .tell = tell };

    fn init(allocator: std.mem.Allocator) MemoryStream {
        return .{ .allocator = allocator };
    }
    fn initRead(allocator: std.mem.Allocator, bytes: []const u8) !MemoryStream {
        var self = init(allocator);
        try self.data.appendSlice(allocator, bytes);
        return self;
    }
    fn deinit(self: *MemoryStream) void {
        self.data.deinit(self.allocator);
    }
};
/// One host-created `IMessage` plus the `IAttributeList` it carries.
///
/// A plugin's controller and component talk to each other over their
/// connection points, and the message they pass is allocated by the HOST -
/// `IHostApplication::createInstance`. Answering that call with "no" (what
/// this host did until now) does not degrade gracefully: sfizz reports
/// "UI could not allocate message" and its editor simply cannot reach its
/// own DSP, so nothing the user does in the GUI takes effect.
///
/// Refcounted for real, unlike the host's other singletons: the plugin
/// creates and releases these constantly. The attribute list is embedded
/// and reports a constant refcount of 1 - its lifetime is the message's,
/// which is how the SDK's own host implementation treats it.
const HostMessage = struct {
    interface: abi.Message = .{ .vtable = &message_vtable },
    attributes: abi.AttributeList = .{ .vtable = &attributes_vtable },
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    id: [128]u8 = @splat(0),
    entries: [max_attributes]Attribute = undefined,
    count: usize = 0,

    const max_attributes = 32;
    const max_key = 64;
    const Attribute = struct {
        key: [max_key]u8,
        key_len: usize,
        value: union(enum) {
            int: i64,
            float: f64,
            /// Owned copies, freed with the message. The string keeps its
            /// sentinel in the type: `allocSentinel` reserves len + 1, and
            /// freeing it as a plain `[]u16` frees the wrong size.
            string: [:0]u16,
            binary: []u8,
        },
    };

    fn create(allocator: std.mem.Allocator) !*HostMessage {
        const self = try allocator.create(HostMessage);
        self.* = .{ .allocator = allocator };
        return self;
    }

    fn from(raw: *anyopaque) *HostMessage {
        return @ptrCast(@alignCast(raw));
    }
    /// The attribute list is a second interface pointer into the same
    /// allocation, so it has to step back to the message before use.
    fn fromAttributes(raw: *anyopaque) *HostMessage {
        const list: *abi.AttributeList = @ptrCast(@alignCast(raw));
        return @fieldParentPtr("attributes", list);
    }

    fn destroy(self: *HostMessage) void {
        for (self.entries[0..self.count]) |entry| switch (entry.value) {
            .string => |s| self.allocator.free(s),
            .binary => |b| self.allocator.free(b),
            else => {},
        };
        self.allocator.destroy(self);
    }

    fn find(self: *HostMessage, id: [*:0]const u8) ?*Attribute {
        const key = std.mem.span(id);
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.key[0..entry.key_len], key)) return entry;
        }
        return null;
    }
    /// Reuses an existing slot for the same key (a plugin overwrites the
    /// same attribute on every message it sends), freeing whatever that
    /// slot owned first.
    fn slot(self: *HostMessage, id: [*:0]const u8) ?*Attribute {
        const key = std.mem.span(id);
        if (key.len > max_key) return null;
        if (self.find(id)) |entry| {
            switch (entry.value) {
                .string => |s| self.allocator.free(s),
                .binary => |b| self.allocator.free(b),
                else => {},
            }
            return entry;
        }
        if (self.count == max_attributes) return null;
        const entry = &self.entries[self.count];
        self.count += 1;
        @memcpy(entry.key[0..key.len], key);
        entry.key_len = key.len;
        return entry;
    }

    fn query(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        if (!std.mem.eql(u8, iid, &abi.message_iid) and !std.mem.eql(u8, iid, &abi.f_unknown_iid)) {
            object.* = null;
            return -1;
        }
        object.* = raw;
        _ = addRef(raw);
        return 0;
    }
    fn addRef(raw: *anyopaque) callconv(abi.abi_callconv) u32 {
        return from(raw).refs.fetchAdd(1, .acq_rel) + 1;
    }
    fn release(raw: *anyopaque) callconv(abi.abi_callconv) u32 {
        const self = from(raw);
        const remaining = self.refs.fetchSub(1, .acq_rel) - 1;
        if (remaining == 0) self.destroy();
        return remaining;
    }
    fn getMessageId(raw: *anyopaque) callconv(abi.abi_callconv) ?[*:0]const u8 {
        const self = from(raw);
        if (self.id[0] == 0) return null;
        return @ptrCast(&self.id);
    }
    fn setMessageId(raw: *anyopaque, id: ?[*:0]const u8) callconv(abi.abi_callconv) void {
        const self = from(raw);
        self.id = @splat(0);
        const text = std.mem.span(id orelse return);
        const len = @min(text.len, self.id.len - 1);
        @memcpy(self.id[0..len], text[0..len]);
    }
    fn getAttributes(raw: *anyopaque) callconv(abi.abi_callconv) ?*abi.AttributeList {
        return &from(raw).attributes;
    }
    const message_vtable: abi.MessageVTable = .{
        .query_interface = query,
        .add_ref = addRef,
        .release = release,
        .get_message_id = getMessageId,
        .set_message_id = setMessageId,
        .get_attributes = getAttributes,
    };

    fn attributesQuery(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        if (!std.mem.eql(u8, iid, &abi.attribute_list_iid) and !std.mem.eql(u8, iid, &abi.f_unknown_iid)) {
            object.* = null;
            return -1;
        }
        object.* = raw;
        return 0;
    }
    fn attributesRef(_: *anyopaque) callconv(abi.abi_callconv) u32 {
        return 1;
    }
    fn setInt(raw: *anyopaque, id: [*:0]const u8, value: i64) callconv(abi.abi_callconv) abi.Result {
        const entry = fromAttributes(raw).slot(id) orelse return -1;
        entry.value = .{ .int = value };
        return 0;
    }
    fn getInt(raw: *anyopaque, id: [*:0]const u8, value: *i64) callconv(abi.abi_callconv) abi.Result {
        const entry = fromAttributes(raw).find(id) orelse return -1;
        value.* = switch (entry.value) {
            .int => |v| v,
            .float => |v| @intFromFloat(v),
            else => return -1,
        };
        return 0;
    }
    fn setFloat(raw: *anyopaque, id: [*:0]const u8, value: f64) callconv(abi.abi_callconv) abi.Result {
        const entry = fromAttributes(raw).slot(id) orelse return -1;
        entry.value = .{ .float = value };
        return 0;
    }
    fn getFloat(raw: *anyopaque, id: [*:0]const u8, value: *f64) callconv(abi.abi_callconv) abi.Result {
        const entry = fromAttributes(raw).find(id) orelse return -1;
        value.* = switch (entry.value) {
            .float => |v| v,
            .int => |v| @floatFromInt(v),
            else => return -1,
        };
        return 0;
    }
    fn setString(raw: *anyopaque, id: [*:0]const u8, text: [*:0]const u16) callconv(abi.abi_callconv) abi.Result {
        const self = fromAttributes(raw);
        const source = std.mem.span(text);
        const copy = self.allocator.allocSentinel(u16, source.len, 0) catch return -1;
        @memcpy(copy, source);
        const entry = self.slot(id) orelse {
            self.allocator.free(copy);
            return -1;
        };
        entry.value = .{ .string = copy };
        return 0;
    }
    fn getString(raw: *anyopaque, id: [*:0]const u8, buffer: [*]u16, size_in_bytes: u32) callconv(abi.abi_callconv) abi.Result {
        const entry = fromAttributes(raw).find(id) orelse return -1;
        const source = switch (entry.value) {
            .string => |s| s,
            else => return -1,
        };
        const capacity = size_in_bytes / @sizeOf(u16);
        if (capacity == 0) return -1;
        const len = @min(source.len, capacity - 1);
        @memcpy(buffer[0..len], source[0..len]);
        buffer[len] = 0;
        return 0;
    }
    fn setBinary(raw: *anyopaque, id: [*:0]const u8, data: *const anyopaque, size_in_bytes: u32) callconv(abi.abi_callconv) abi.Result {
        const self = fromAttributes(raw);
        const source = @as([*]const u8, @ptrCast(data))[0..size_in_bytes];
        const copy = self.allocator.dupe(u8, source) catch return -1;
        const entry = self.slot(id) orelse {
            self.allocator.free(copy);
            return -1;
        };
        entry.value = .{ .binary = copy };
        return 0;
    }
    fn getBinary(raw: *anyopaque, id: [*:0]const u8, data: *?*const anyopaque, size_in_bytes: *u32) callconv(abi.abi_callconv) abi.Result {
        const entry = fromAttributes(raw).find(id) orelse return -1;
        const source = switch (entry.value) {
            .binary => |b| b,
            else => return -1,
        };
        data.* = source.ptr;
        size_in_bytes.* = @intCast(source.len);
        return 0;
    }
    const attributes_vtable: abi.AttributeListVTable = .{
        .query_interface = attributesQuery,
        .add_ref = attributesRef,
        .release = attributesRef,
        .set_int = setInt,
        .get_int = getInt,
        .set_float = setFloat,
        .get_float = getFloat,
        .set_string = setString,
        .get_string = getString,
        .set_binary = setBinary,
        .get_binary = getBinary,
    };
};

const HostContext = struct {
    handler: abi.ComponentHandler = .{ .vtable = &vtable },
    application: abi.HostApplication = .{ .vtable = &application_vtable },
    allocator: std.mem.Allocator,
    restart_flags: std.atomic.Value(i32) = .init(0),
    state_dirty: std.atomic.Value(bool) = .init(false),

    fn from(raw: *anyopaque) *HostContext {
        return @ptrCast(@alignCast(raw));
    }
    /// A plugin reaching `IHostApplication` through the component handler is
    /// ordinary, but it has to arrive at the application interface, not at
    /// this one under another name. Everything else this host does not
    /// implement (`IComponentHandler2`, `IComponentHandler3`, ...) has to be
    /// refused, or the plugin calls a vtable slot that means something else.
    fn query(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        if (std.mem.eql(u8, iid, &abi.host_application_iid)) {
            object.* = @ptrCast(&from(raw).application);
            return 0;
        }
        if (!std.mem.eql(u8, iid, &abi.component_handler_iid) and !std.mem.eql(u8, iid, &abi.f_unknown_iid)) {
            object.* = null;
            return -1;
        }
        object.* = raw;
        return 0;
    }
    fn ref(_: *anyopaque) callconv(abi.abi_callconv) u32 {
        return 1;
    }
    fn begin(_: *anyopaque, _: u32) callconv(abi.abi_callconv) abi.Result {
        return 0;
    }
    fn perform(raw: *anyopaque, _: u32, _: f64) callconv(abi.abi_callconv) abi.Result {
        from(raw).state_dirty.store(true, .release);
        return 0;
    }
    fn end(raw: *anyopaque, _: u32) callconv(abi.abi_callconv) abi.Result {
        from(raw).state_dirty.store(true, .release);
        return 0;
    }
    fn restart(raw: *anyopaque, flags: i32) callconv(abi.abi_callconv) abi.Result {
        _ = from(raw).restart_flags.fetchOr(flags, .release);
        return 0;
    }
    const vtable: abi.ComponentHandlerVTable = .{ .query_interface = query, .add_ref = ref, .release = ref, .begin_edit = begin, .perform_edit = perform, .end_edit = end, .restart_component = restart };
    fn appQuery(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        if (!std.mem.eql(u8, iid, &abi.host_application_iid) and !std.mem.eql(u8, iid, &abi.f_unknown_iid)) {
            object.* = null;
            return -1;
        }
        object.* = raw;
        return 0;
    }
    fn appName(_: *anyopaque, name: *[128]u16) callconv(abi.abi_callconv) abi.Result {
        name.* = std.mem.zeroes([128]u16);
        for ("wstudio", 0..) |byte, i| name[i] = byte;
        return 0;
    }
    fn appCreate(raw: *anyopaque, cid: *const abi.Tuid, _: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        object.* = null;
        // IMessage is the only class a host is actually required to make.
        // The requested interface is ignored: both of a message's
        // interfaces live in the one allocation, and the plugin reaches
        // the attribute list through `getAttributes` regardless.
        if (!std.mem.eql(u8, cid, &abi.message_iid)) return -1;
        // Not `from`: what a plugin holds is `&host_context.application`,
        // and only `handler` sits at the context's own address.
        const application: *abi.HostApplication = @ptrCast(@alignCast(raw));
        const self: *HostContext = @fieldParentPtr("application", application);
        const message = HostMessage.create(self.allocator) catch return -1;
        object.* = @ptrCast(&message.interface);
        return 0;
    }
    const application_vtable: abi.HostApplicationVTable = .{ .query_interface = appQuery, .add_ref = ref, .release = ref, .get_name = appName, .create_instance = appCreate };
};
const HostEventList = struct {
    interface: abi.EventList = .{ .vtable = &vtable },
    events: [max_events]abi.Event = undefined,
    len: usize = 0,

    fn from(raw: *anyopaque) *HostEventList {
        return @ptrCast(@alignCast(raw));
    }
    fn query(_: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        if (!std.mem.eql(u8, iid, &abi.event_list_iid)) {
            object.* = null;
            return -1;
        }
        object.* = null;
        return 0;
    }
    fn ref(_: *anyopaque) callconv(abi.abi_callconv) u32 {
        return 1;
    }
    fn count(raw: *anyopaque) callconv(abi.abi_callconv) i32 {
        return @intCast(from(raw).len);
    }
    fn get(raw: *anyopaque, index: i32, event: *abi.Event) callconv(abi.abi_callconv) abi.Result {
        const self = from(raw);
        if (index < 0 or index >= self.len) return -1;
        event.* = self.events[@intCast(index)];
        return 0;
    }
    fn add(_: *anyopaque, _: *abi.Event) callconv(abi.abi_callconv) abi.Result {
        return -1;
    }
    const vtable: abi.EventListVTable = .{ .query_interface = query, .add_ref = ref, .release = ref, .get_event_count = count, .get_event = get, .add_event = add };
};

const ParamQueue = struct {
    const max_points = 64;
    const Point = struct { offset: i32, value: f64 };
    interface: abi.ParamValueQueue = .{ .vtable = &vtable },
    id: u32 = 0,
    points: [max_points]Point = undefined,
    len: usize = 0,

    fn from(raw: *anyopaque) *ParamQueue {
        return @ptrCast(@alignCast(raw));
    }
    fn query(_: *anyopaque, _: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        object.* = null;
        return -1;
    }
    fn ref(_: *anyopaque) callconv(abi.abi_callconv) u32 {
        return 1;
    }
    fn getId(raw: *anyopaque) callconv(abi.abi_callconv) u32 {
        return from(raw).id;
    }
    fn count(raw: *anyopaque) callconv(abi.abi_callconv) i32 {
        return @intCast(from(raw).len);
    }
    fn get(raw: *anyopaque, index: i32, offset: *i32, value: *f64) callconv(abi.abi_callconv) abi.Result {
        const self = from(raw);
        if (index < 0 or index >= self.len) return -1;
        offset.* = self.points[@intCast(index)].offset;
        value.* = self.points[@intCast(index)].value;
        return 0;
    }
    fn add(raw: *anyopaque, offset: i32, value: f64, index: *i32) callconv(abi.abi_callconv) abi.Result {
        const self = from(raw);
        if (self.len == max_points) return -1;
        self.points[self.len] = .{ .offset = offset, .value = value };
        index.* = @intCast(self.len);
        self.len += 1;
        return 0;
    }
    const vtable: abi.ParamValueQueueVTable = .{ .query_interface = query, .add_ref = ref, .release = ref, .get_parameter_id = getId, .get_point_count = count, .get_point = get, .add_point = add };
};

const ParamChanges = struct {
    interface: abi.ParameterChanges = .{ .vtable = &vtable },
    queues: [max_param_changes]ParamQueue = undefined,
    len: usize = 0,

    fn from(raw: *anyopaque) *ParamChanges {
        return @ptrCast(@alignCast(raw));
    }
    fn query(_: *anyopaque, _: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        object.* = null;
        return -1;
    }
    fn ref(_: *anyopaque) callconv(abi.abi_callconv) u32 {
        return 1;
    }
    fn count(raw: *anyopaque) callconv(abi.abi_callconv) i32 {
        return @intCast(from(raw).len);
    }
    fn get(raw: *anyopaque, index: i32) callconv(abi.abi_callconv) ?*abi.ParamValueQueue {
        const self = from(raw);
        if (index < 0 or index >= self.len) return null;
        return &self.queues[@intCast(index)].interface;
    }
    fn add(raw: *anyopaque, id: *const u32, index: *i32) callconv(abi.abi_callconv) ?*abi.ParamValueQueue {
        const self = from(raw);
        for (self.queues[0..self.len], 0..) |*queue, i| {
            if (queue.id == id.*) {
                index.* = @intCast(i);
                return &queue.interface;
            }
        }
        if (self.len == max_param_changes) return null;
        self.queues[self.len] = .{ .id = id.* };
        index.* = @intCast(self.len);
        self.len += 1;
        return &self.queues[self.len - 1].interface;
    }
    fn push(self: *ParamChanges, id: u32, offset: u32, value: f64) void {
        var queue_index: i32 = 0;
        const queue = add(self, &id, &queue_index) orelse return;
        _ = queue.vtable.add_point(queue, @intCast(offset), value, &queue_index);
    }
    const vtable: abi.ParameterChangesVTable = .{ .query_interface = query, .add_ref = ref, .release = ref, .get_parameter_count = count, .get_parameter_data = get, .add_parameter_data = add };
};

fn releaseController(controller: anytype, initialized: bool) void {
    if (controller) |value| {
        if (initialized) _ = value.vtable.terminate(value);
        _ = value.vtable.release(value);
    }
}

fn vstSamplePosition(frames: u64) i64 {
    return std.math.cast(i64, frames) orelse std.math.maxInt(i64);
}

/// Public VST3 plugin handle. Wraps either a real in-process instance
/// (`Direct`, today's implementation, byte-for-byte unchanged internally)
/// or a `*Bridge` handle to a sandboxed child process running that same
/// unmodified `Direct` code (see plugin_host/child_main.zig) - see
/// `ClapPlugin` in src/clap/plugin.zig for the identical split and why
/// it's shaped this way. `pluginPath`/`classId` need no RPC in either
/// mode: unlike CLAP's plugin id (which can be null, letting the plugin's
/// own factory pick a default), VST3's bundle path and 32-char class id
/// are always caller-supplied `load()` arguments, so the outer wrapper
/// just caches them directly.
pub const Vst3Plugin = struct {
    pub const sample_offset_events = true;
    allocator: std.mem.Allocator,
    bundle_path: []u8,
    class_id: [32]u8,
    impl: Impl,
    transport: ?*const Transport = null,
    /// Bridged-mode only: events queued by `handleEvent`/`setParameter`
    /// between blocks, published to the child on the next `processBlock`.
    pending_events: [wire.max_events]wire.WireEvent = undefined,
    pending_count: u32 = 0,
    /// Bridged-mode only: populated once at load time over RPC (the same
    /// eager-population loop `Direct.loadModule` runs itself, just fed by
    /// `parameterCount`/`parameterInfo` calls instead of direct vtable
    /// access) since these don't change afterward - see `Direct`'s own
    /// fields of the same name for the direct-mode source of truth.
    automatable_params: [max_parameters]device_mod.AutomatableParam = undefined,
    automatable_names: [max_parameters][64]u8 = undefined,
    automatable_count: usize = 0,

    const Impl = union(enum) {
        direct: Direct,
        bridged: *bridge_mod.Bridge,
    };

    pub const device = device_mod.deviceOf(@This());

    pub fn load(allocator: std.mem.Allocator, bundle_path: []const u8, id: []const u8, sample_rate: u32, instrument: bool) !*Vst3Plugin {
        if (bridge_mod.sandboxActive()) return loadBridged(allocator, bundle_path, id, sample_rate, instrument);
        return loadDirect(allocator, bundle_path, id, sample_rate, instrument);
    }

    fn loadBridged(allocator: std.mem.Allocator, bundle_path: []const u8, id: []const u8, sample_rate: u32, instrument: bool) !*Vst3Plugin {
        const class_id = try abi.parseUid(id); // validated here too so a malformed id fails before spawning a child
        const b = try bridge_mod.Bridge.spawn(allocator, .{
            .kind = .vst3,
            .path = bundle_path,
            .plugin_id = id,
            .sample_rate = sample_rate,
            .instrument = instrument,
        });
        errdefer b.deinit();
        const self = try allocator.create(Vst3Plugin);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .bundle_path = try allocator.dupe(u8, bundle_path),
            .class_id = abi.formatUid(class_id),
            .impl = .{ .bridged = b },
        };
        if (instrument) {
            const count_resp = b.call(.parameter_count, &.{}) catch &.{};
            const count: usize = if (count_resp.len >= 4) std.mem.bytesToValue(u32, count_resp[0..4]) else 0;
            var index: usize = 0;
            while (index < @min(count, max_parameters)) : (index += 1) {
                const idx32: u32 = @intCast(index);
                const info_resp = b.call(.parameter_info, std.mem.asBytes(&idx32)) catch continue;
                if (info_resp.len < @sizeOf(abi.ParameterInfo)) continue;
                const info = std.mem.bytesToValue(abi.ParameterInfo, info_resp[0..@sizeOf(abi.ParameterInfo)]);
                if (info.flags & 1 == 0) continue;
                const slot = self.automatable_count;
                const title = std.mem.sliceTo(&info.title, 0);
                const len = std.unicode.utf16LeToUtf8(&self.automatable_names[slot], title) catch 0;
                self.automatable_params[slot] = .{
                    .id = info.id,
                    .label = self.automatable_names[slot][0..len],
                    .section = "VST3",
                    .range = .{ 0, 1 },
                    .step = 0.01,
                };
                self.automatable_count += 1;
            }
        }
        return self;
    }

    fn loadDirect(allocator: std.mem.Allocator, bundle_path: []const u8, id: []const u8, sample_rate: u32, instrument: bool) !*Vst3Plugin {
        const relative = try scan.moduleRelativePath(allocator, std.fs.path.basename(bundle_path), @import("builtin").os.tag, @import("builtin").cpu.arch);
        defer allocator.free(relative);
        const module_path = try std.fs.path.join(allocator, &.{ bundle_path, relative });
        defer allocator.free(module_path);
        return loadModuleDirect(allocator, module_path, bundle_path, id, sample_rate, instrument);
    }

    pub fn loadModule(allocator: std.mem.Allocator, module_path: []const u8, bundle_path: []const u8, id: []const u8, sample_rate: u32, instrument: bool) !*Vst3Plugin {
        if (bridge_mod.sandboxActive()) return loadBridged(allocator, bundle_path, id, sample_rate, instrument);
        return loadModuleDirect(allocator, module_path, bundle_path, id, sample_rate, instrument);
    }

    fn loadModuleDirect(allocator: std.mem.Allocator, module_path: []const u8, bundle_path: []const u8, id: []const u8, sample_rate: u32, instrument: bool) !*Vst3Plugin {
        const class_id = try abi.parseUid(id);
        var module = try module_mod.Module.open(bundle_path, module_path);
        errdefer module.close();
        const host_context = try allocator.create(HostContext);
        errdefer allocator.destroy(host_context);
        host_context.* = .{ .allocator = allocator };

        var component_raw: ?*anyopaque = null;
        if (module.factory.vtable.create_instance(module.factory, &class_id, &abi.component_iid, &component_raw) != 0)
            return error.ComponentCreateFailed;
        const component: *abi.Component = @ptrCast(@alignCast(component_raw orelse return error.ComponentCreateFailed));
        var initialized = false;
        errdefer {
            if (initialized) _ = component.vtable.terminate(component);
            _ = component.vtable.release(component);
        }
        if (component.vtable.initialize(component, @ptrCast(&host_context.application)) != 0) return error.ComponentInitializeFailed;
        initialized = true;

        var processor_raw: ?*anyopaque = null;
        if (component.vtable.query_interface(component, &abi.audio_processor_iid, &processor_raw) != 0)
            return error.MissingAudioProcessor;
        const processor: *abi.AudioProcessor = @ptrCast(@alignCast(processor_raw orelse return error.MissingAudioProcessor));
        errdefer _ = processor.vtable.release(processor);

        var controller: ?*abi.EditController = null;
        var controller_initialized = false;
        errdefer releaseController(controller, controller_initialized);
        var controller_id: abi.Tuid = undefined;
        if (component.vtable.get_controller_class_id(component, &controller_id) == 0) {
            var controller_raw: ?*anyopaque = null;
            if (module.factory.vtable.create_instance(module.factory, &controller_id, &abi.edit_controller_iid, &controller_raw) == 0) {
                controller = @ptrCast(@alignCast(controller_raw orelse return error.ControllerCreateFailed));
                if (controller.?.vtable.initialize(controller.?, @ptrCast(&host_context.application)) != 0) return error.ControllerInitializeFailed;
                controller_initialized = true;
                if (controller.?.vtable.set_component_handler(controller.?, &host_context.handler) != 0) return error.ComponentHandlerRejected;
            }
        }
        var midi_mapping: ?*abi.MidiMapping = null;
        if (controller) |value| {
            var mapping_raw: ?*anyopaque = null;
            if (value.vtable.query_interface(value, &abi.midi_mapping_iid, &mapping_raw) == 0)
                midi_mapping = @ptrCast(@alignCast(mapping_raw orelse return error.MidiMappingQueryFailed));
        }
        errdefer {
            if (midi_mapping) |value| _ = value.vtable.release(value);
        }
        var component_connection: ?*abi.ConnectionPoint = null;
        var controller_connection: ?*abi.ConnectionPoint = null;
        if (controller) |value| {
            var component_connection_raw: ?*anyopaque = null;
            var controller_connection_raw: ?*anyopaque = null;
            const component_result = component.vtable.query_interface(component, &abi.connection_point_iid, &component_connection_raw);
            const controller_result = value.vtable.query_interface(value, &abi.connection_point_iid, &controller_connection_raw);
            if (component_result == 0 and controller_result == 0) {
                component_connection = @ptrCast(@alignCast(component_connection_raw orelse return error.ConnectionPointQueryFailed));
                controller_connection = @ptrCast(@alignCast(controller_connection_raw orelse return error.ConnectionPointQueryFailed));
                if (component_connection.?.vtable.connect(component_connection.?, controller_connection.?) != 0 or
                    controller_connection.?.vtable.connect(controller_connection.?, component_connection.?) != 0)
                {
                    _ = component_connection.?.vtable.disconnect(component_connection.?, controller_connection.?);
                    _ = component_connection.?.vtable.release(component_connection.?);
                    _ = controller_connection.?.vtable.release(controller_connection.?);
                    return error.ConnectionPointConnectFailed;
                }
            } else {
                if (component_connection_raw) |raw| {
                    const point: *abi.ConnectionPoint = @ptrCast(@alignCast(raw));
                    _ = point.vtable.release(point);
                }
                if (controller_connection_raw) |raw| {
                    const point: *abi.ConnectionPoint = @ptrCast(@alignCast(raw));
                    _ = point.vtable.release(point);
                }
            }
        }
        errdefer {
            if (component_connection) |value| _ = value.vtable.release(value);
            if (controller_connection) |value| _ = value.vtable.release(value);
        }

        if (processor.vtable.can_process_sample_size(processor, 0) != 0) return error.Sample32Unsupported;
        // Bus counts are whatever the plugin declares, not what this host
        // would prefer. Demanding exactly one input and one output bus
        // rejected 93 of the 210 plugins in the test set: every sidechain
        // effect, every A/B tester, every multi-out sampler. Only the main
        // bus (index 0 in each direction) carries host audio; the rest are
        // deactivated but still handed real buffers below, because plugins
        // index `data.inputs[bus]` across every bus they declare.
        const input_bus_count: usize = @intCast(@max(component.vtable.get_bus_count(component, 0, 0), 0));
        const output_bus_count: usize = @intCast(@max(component.vtable.get_bus_count(component, 0, 1), 0));
        if (output_bus_count == 0) return error.UnsupportedAudioBusCount;
        const has_main_input = !instrument and input_bus_count > 0;

        // The VST3 spec makes `set_bus_arrangements` a *negotiation*: a
        // plugin may answer kResultFalse and keep its own layout, which is
        // what every mono LSP plugin and every Uhhyou synth does. Treating
        // that answer as fatal rejected 56 more plugins. So ask for each
        // bus's current arrangement (a confirmation, not a change), ignore
        // the answer, and read the channel counts back afterwards.
        {
            const arrangements = try allocator.alloc(u64, input_bus_count + output_bus_count);
            defer allocator.free(arrangements);
            for (0..input_bus_count) |index| arrangements[index] = busArrangement(component, processor, 0, index);
            for (0..output_bus_count) |index| arrangements[input_bus_count + index] = busArrangement(component, processor, 1, index);
            _ = processor.vtable.set_bus_arrangements(
                processor,
                if (input_bus_count == 0) null else arrangements.ptr,
                @intCast(input_bus_count),
                arrangements[input_bus_count..].ptr,
                @intCast(output_bus_count),
            );
        }

        for (0..input_bus_count) |index| {
            const active: u8 = @intFromBool(has_main_input and index == 0);
            const result = component.vtable.activate_bus(component, 0, 0, @intCast(index), active);
            if (result != 0 and active == 1) return error.BusActivationFailed;
        }
        for (0..output_bus_count) |index| {
            const active: u8 = @intFromBool(index == 0);
            const result = component.vtable.activate_bus(component, 0, 1, @intCast(index), active);
            if (result != 0 and active == 1) return error.BusActivationFailed;
        }

        var setup: abi.ProcessSetup = .{ .process_mode = 0, .symbolic_sample_size = 0, .max_samples_per_block = types.max_block_frames, .sample_rate = @floatFromInt(sample_rate) };
        if (processor.vtable.setup_processing(processor, &setup) != 0) return error.ProcessingSetupFailed;
        if (component.vtable.set_active(component, 1) != 0) return error.ComponentActivationFailed;
        errdefer _ = component.vtable.set_active(component, 0);
        const start_result = processor.vtable.set_processing(processor, 1);
        if (start_result != 0 and start_result != abi.not_implemented) return error.ProcessingStartFailed;
        errdefer _ = processor.vtable.set_processing(processor, 0);

        const self = try allocator.create(Vst3Plugin);
        errdefer allocator.destroy(self);
        var buses = try BusBuffers.init(allocator, component, input_bus_count, output_bus_count);
        errdefer buses.deinit(allocator);
        const input_channels: usize = if (has_main_input and buses.inputs.len > 0) @intCast(@max(buses.inputs[0].num_channels, 0)) else 0;
        const output_channels: usize = @intCast(@max(buses.outputs[0].num_channels, 0));
        const owned_path = try allocator.dupe(u8, bundle_path);
        errdefer allocator.free(owned_path);
        const owned_path_outer = try allocator.dupe(u8, bundle_path);
        errdefer allocator.free(owned_path_outer);
        self.* = .{
            .allocator = allocator,
            .bundle_path = owned_path_outer,
            .class_id = abi.formatUid(class_id),
            .impl = .{ .direct = .{
                .allocator = allocator,
                .module = module,
                .component = component,
                .processor = processor,
                .controller = controller,
                .midi_mapping = midi_mapping,
                .component_connection = component_connection,
                .controller_connection = controller_connection,
                .host_context = host_context,
                .bundle_path = owned_path,
                .class_id = abi.formatUid(class_id),
                .input_channels = @intCast(@min(input_channels, 2)),
                .output_channels = @intCast(@min(output_channels, 2)),
                .buses = buses,
                .sample_rate = sample_rate,
                .instrument = instrument,
            } },
        };
        if (controller) |value| {
            const direct = &self.impl.direct;
            const count: usize = @intCast(@min(@max(value.vtable.get_parameter_count(value), 0), max_parameters));
            for (0..count) |raw_index| {
                var info: abi.ParameterInfo = undefined;
                if (value.vtable.get_parameter_info(value, @intCast(raw_index), &info) != 0 or info.flags & 1 == 0) continue;
                const index = direct.parameter_count;
                direct.parameter_indices[index] = @intCast(raw_index);
                direct.parameter_count += 1;
                const title = std.mem.sliceTo(&info.title, 0);
                const len = std.unicode.utf16LeToUtf8(&direct.parameter_names[index], title) catch 0;
                direct.automatable_params[direct.automatable_count] = .{
                    .id = info.id,
                    .label = direct.parameter_names[index][0..len],
                    .section = "VST3",
                    .range = .{ 0, 1 },
                    .step = 0.01,
                };
                direct.automatable_count += 1;
            }
        }
        return self;
    }

    pub fn deinit(self: *Vst3Plugin) void {
        switch (self.impl) {
            .direct => |*d| d.deinit(),
            .bridged => |b| b.deinit(),
        }
        self.allocator.free(self.bundle_path);
        self.allocator.destroy(self);
    }

    pub fn processBlock(self: *Vst3Plugin, buf: []types.Sample) void {
        switch (self.impl) {
            .direct => |*d| d.processBlock(buf),
            .bridged => |b| {
                b.processBlock(buf, self.pending_events[0..self.pending_count], self.transport);
                self.pending_count = 0;
            },
        }
        // A third-party plugin's output is untrusted - see `scrubNonFinite`.
        types.scrubNonFinite(buf);
    }

    fn pushPending(self: *Vst3Plugin, w: wire.WireEvent) void {
        if (self.pending_count < wire.max_events) {
            self.pending_events[self.pending_count] = w;
            self.pending_count += 1;
        }
    }

    pub fn handleEvent(self: *Vst3Plugin, event: device_mod.Event) void {
        switch (self.impl) {
            .direct => |*d| d.handleEvent(self, event),
            .bridged => {
                const self_ptr: *anyopaque = @ptrCast(self);
                if (wire.fromDeviceEvent(event, self_ptr)) |w| self.pushPending(w);
            },
        }
    }

    pub fn attachTransport(self: *Vst3Plugin, transport: *const Transport) void {
        self.transport = transport;
        switch (self.impl) {
            .direct => |*d| d.attachTransport(transport),
            .bridged => {},
        }
    }

    pub fn pluginPath(self: *const Vst3Plugin) []const u8 {
        return self.bundle_path;
    }

    pub fn classId(self: *const Vst3Plugin) []const u8 {
        return &self.class_id;
    }

    pub fn parameterCount(self: *const Vst3Plugin) usize {
        return switch (self.impl) {
            .direct => |*d| d.parameterCount(),
            .bridged => |b| blk: {
                const resp = b.call(.parameter_count, &.{}) catch break :blk 0;
                break :blk if (resp.len >= 4) std.mem.bytesToValue(u32, resp[0..4]) else 0;
            },
        };
    }

    pub fn parameterInfo(self: *const Vst3Plugin, index: usize) ?abi.ParameterInfo {
        return switch (self.impl) {
            .direct => |*d| d.parameterInfo(index),
            .bridged => |b| blk: {
                const index32: u32 = @intCast(index);
                const resp = b.call(.parameter_info, std.mem.asBytes(&index32)) catch break :blk null;
                if (resp.len < @sizeOf(abi.ParameterInfo)) break :blk null;
                break :blk std.mem.bytesToValue(abi.ParameterInfo, resp[0..@sizeOf(abi.ParameterInfo)]);
            },
        };
    }

    pub fn automationParams(self: *const Vst3Plugin) []const device_mod.AutomatableParam {
        return switch (self.impl) {
            .direct => |*d| d.automationParams(),
            .bridged => self.automatable_params[0..self.automatable_count],
        };
    }

    pub fn parameterName(self: *const Vst3Plugin, index: usize, buf: []u8) ?[]const u8 {
        return switch (self.impl) {
            .direct => |*d| d.parameterName(index, buf),
            .bridged => |b| blk: {
                const index32: u32 = @intCast(index);
                const resp = b.call(.parameter_name, std.mem.asBytes(&index32)) catch break :blk null;
                if (resp.len == 0 or buf.len == 0) break :blk null;
                const len = @min(resp.len, buf.len);
                @memcpy(buf[0..len], resp[0..len]);
                break :blk buf[0..len];
            },
        };
    }

    pub fn formatParameter(self: *const Vst3Plugin, id: u32, value: f64, buf: []u8) ?[]const u8 {
        return switch (self.impl) {
            .direct => |*d| d.formatParameter(id, value, buf),
            .bridged => |b| blk: {
                var req: [12]u8 = undefined;
                @memcpy(req[0..4], std.mem.asBytes(&id));
                @memcpy(req[4..12], std.mem.asBytes(&value));
                const resp = b.call(.format_parameter, &req) catch break :blk null;
                if (resp.len == 0 or buf.len == 0) break :blk null;
                const len = @min(resp.len, buf.len);
                @memcpy(buf[0..len], resp[0..len]);
                break :blk buf[0..len];
            },
        };
    }

    pub fn saveComponentState(self: *Vst3Plugin, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.impl) {
            .direct => |*d| d.saveComponentState(allocator),
            .bridged => |b| {
                const resp = try b.call(.save_state, &.{});
                return try savedComponentFromWire(allocator, resp);
            },
        };
    }

    pub fn saveControllerState(self: *Vst3Plugin, allocator: std.mem.Allocator) !?[]u8 {
        return switch (self.impl) {
            .direct => |*d| d.saveControllerState(allocator),
            .bridged => |b| {
                const resp = try b.call(.save_state, &.{});
                return try savedControllerFromWire(allocator, resp);
            },
        };
    }

    pub fn loadState(self: *Vst3Plugin, component_bytes: []const u8, controller_bytes: []const u8) !void {
        switch (self.impl) {
            .direct => |*d| return d.loadState(component_bytes, controller_bytes),
            .bridged => |b| {
                var buf: [rpc_max_payload]u8 = undefined;
                const payload = try encodeStateForWire(&buf, component_bytes, controller_bytes);
                _ = try b.call(.load_state, payload);
            },
        }
    }

    pub fn parameterValue(self: *const Vst3Plugin, id: u32) ?f64 {
        return switch (self.impl) {
            .direct => |*d| d.parameterValue(id),
            .bridged => |b| blk: {
                const resp = b.call(.parameter_value, std.mem.asBytes(&id)) catch break :blk null;
                break :blk if (resp.len >= 8) std.mem.bytesToValue(f64, resp[0..8]) else null;
            },
        };
    }

    pub fn setParameter(self: *Vst3Plugin, id: u32, value: f64) void {
        switch (self.impl) {
            .direct => |*d| d.setParameter(id, value, 0),
            .bridged => |b| {
                var req: [12]u8 = undefined;
                @memcpy(req[0..4], std.mem.asBytes(&id));
                @memcpy(req[4..12], std.mem.asBytes(&value));
                _ = b.call(.set_parameter, &req) catch {};
            },
        }
    }

    pub fn setParameterAt(self: *Vst3Plugin, id: u32, value: f64, sample_offset: u32) void {
        switch (self.impl) {
            .direct => |*d| d.setParameter(id, value, sample_offset),
            .bridged => self.pushPending(.{ .kind = .vst3_param, .param_id = id, .value = value, .sample_offset = sample_offset }),
        }
    }

    pub fn reset(self: *Vst3Plugin) void {
        switch (self.impl) {
            .direct => |*d| d.reset(),
            .bridged => |b| {
                self.pending_count = 0;
                b.requestReset();
            },
        }
    }

    pub fn latencySamples(self: *const Vst3Plugin) u32 {
        return switch (self.impl) {
            .direct => |*d| d.latencySamples(),
            .bridged => |b| b.latencyFrames(),
        };
    }

    pub fn latencyFrames(self: *const Vst3Plugin) u32 {
        return self.latencySamples();
    }

    pub fn hasGui(self: *const Vst3Plugin) bool {
        return switch (self.impl) {
            .direct => |*d| d.hasGui(),
            .bridged => |b| b.has_gui,
        };
    }

    pub fn toggleGui(self: *Vst3Plugin) !bool {
        return switch (self.impl) {
            .direct => |*d| d.toggleGui(),
            .bridged => |b| {
                const response = try b.call(.toggle_gui, &.{});
                return response.len == 1 and response[0] != 0;
            },
        };
    }

    /// Bridged mode forwards this as a synchronous RPC to the child (see
    /// `ClapPlugin.serviceMainThread` in src/clap/plugin.zig for why it
    /// must be synchronous, not a passive background-published flag).
    pub fn serviceMainThread(self: *Vst3Plugin) bool {
        return switch (self.impl) {
            .direct => |*d| d.serviceMainThread(),
            .bridged => |b| b.serviceMainThread(),
        };
    }

    pub fn takeHostStalledBlocks(self: *Vst3Plugin) u32 {
        return switch (self.impl) {
            .direct => 0,
            .bridged => |b| b.takeStalledBlocks(),
        };
    }

    pub fn takeHostCrashed(self: *Vst3Plugin) bool {
        return switch (self.impl) {
            .direct => false,
            .bridged => |b| b.takeCrashed(),
        };
    }
};

const rpc_max_payload = @import("../plugin_host/rpc.zig").max_payload;

/// `save_state`'s bridged response packs both streams as the child's
/// `dispatch` already frames them (u32 length + bytes, twice) - see
/// child_main.zig's `.save_state` VST3 arm. Component state is
/// unconditionally present.
fn savedComponentFromWire(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (payload.len < 4) return error.ComponentStateSaveFailed;
    const len = std.mem.readInt(u32, payload[0..4], .little);
    if (len > payload.len - 4) return error.ComponentStateSaveFailed;
    return try allocator.dupe(u8, payload[4..][0..len]);
}

fn savedControllerFromWire(allocator: std.mem.Allocator, payload: []const u8) !?[]u8 {
    if (payload.len < 4) return error.ComponentStateSaveFailed;
    const component_len = std.mem.readInt(u32, payload[0..4], .little);
    if (component_len > payload.len - 4) return error.ComponentStateSaveFailed;
    const rest = payload[4 + component_len ..];
    if (rest.len < 4) return error.ComponentStateSaveFailed;
    const controller_len = std.mem.readInt(u32, rest[0..4], .little);
    if (controller_len > rest.len - 4) return error.ComponentStateSaveFailed;
    if (controller_len == 0) return null;
    return try allocator.dupe(u8, rest[4..][0..controller_len]);
}

/// Wire format for `load_state`'s request - matches what child_main.zig's
/// `.load_state` VST3 arm expects to unpack: u32 length + component
/// bytes, then u32 length + controller bytes.
pub fn encodeStateForWire(buf: []u8, component_bytes: []const u8, controller_bytes: []const u8) ![]const u8 {
    var pos: usize = 0;
    if (buf.len < 8 or component_bytes.len > buf.len - 8 or controller_bytes.len > buf.len - 8 - component_bytes.len)
        return error.StatePayloadTooLarge;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(component_bytes.len), .little);
    pos += 4;
    @memcpy(buf[pos..][0..component_bytes.len], component_bytes);
    pos += component_bytes.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(controller_bytes.len), .little);
    pos += 4;
    @memcpy(buf[pos..][0..controller_bytes.len], controller_bytes);
    pos += controller_bytes.len;
    return buf[0..pos];
}

/// Speaker arrangement a bus already reports, for handing straight back to
/// `set_bus_arrangements`. Falls back to deriving one from the channel
/// count when the plugin has no answer - note that VST3 mono is
/// `kSpeakerM` (bit 19), not bit 0: asking for bit 0 (which is
/// `kSpeakerL`, the left channel of a stereo pair) is what every mono
/// plugin in the test set rejected.
fn busArrangement(component: *abi.Component, processor: *abi.AudioProcessor, direction: i32, index: usize) u64 {
    var arrangement: u64 = 0;
    if (processor.vtable.get_bus_arrangement(processor, direction, @intCast(index), &arrangement) == 0 and arrangement != 0)
        return arrangement;
    return switch (busChannelCount(component, direction, index)) {
        0 => 0,
        1 => 1 << 19, // kSpeakerM
        2 => 3, // kSpeakerL | kSpeakerR
        else => |channels| (@as(u64, 1) << @intCast(@min(channels, 63))) - 1,
    };
}

fn busChannelCount(component: *abi.Component, direction: i32, index: usize) usize {
    var info: abi.BusInfo = undefined;
    if (component.vtable.get_bus_info(component, 0, direction, @intCast(index), &info) != 0) return 0;
    return @intCast(@max(info.channel_count, 0));
}

/// Process buffers for every bus a plugin declares.
///
/// `process` takes one `AudioBusBuffers` per declared bus, and plugins index
/// `data.inputs[bus]` by their own bus count rather than by `numInputs` - so
/// the deactivated buses (sidechains, aux sends, the 47 extra outputs of a
/// multi-out sampler) need real channel pointers too. Bus 0 in each
/// direction carries host audio; every other bus reads silence and has its
/// output discarded.
const BusBuffers = struct {
    inputs: []abi.AudioBusBuffers,
    outputs: []abi.AudioBusBuffers,
    channel_ptrs: [][*]f32,
    pool: []f32,
    /// Index into `channel_ptrs` of the main output bus's first channel.
    /// The main input bus is bus 0, so its own first channel is index 0.
    main_output_channel: usize,

    fn init(allocator: std.mem.Allocator, component: *abi.Component, input_bus_count: usize, output_bus_count: usize) !BusBuffers {
        const inputs = try allocator.alloc(abi.AudioBusBuffers, input_bus_count);
        errdefer allocator.free(inputs);
        const outputs = try allocator.alloc(abi.AudioBusBuffers, output_bus_count);
        errdefer allocator.free(outputs);

        var total: usize = 0;
        for (inputs, 0..) |*bus, index| {
            const channels = busChannelCount(component, 0, index);
            bus.* = .{ .num_channels = @intCast(channels), .silence_flags = 0, .buffers = undefined };
            total += channels;
        }
        const main_output_channel = total;
        for (outputs, 0..) |*bus, index| {
            const channels = busChannelCount(component, 1, index);
            bus.* = .{ .num_channels = @intCast(channels), .silence_flags = 0, .buffers = undefined };
            total += channels;
        }

        const pool = try allocator.alloc(f32, @max(total, 1) * types.max_block_frames);
        errdefer allocator.free(pool);
        const channel_ptrs = try allocator.alloc([*]f32, @max(total, 1));
        errdefer allocator.free(channel_ptrs);
        for (channel_ptrs, 0..) |*ptr, index| ptr.* = pool[index * types.max_block_frames ..].ptr;

        var next: usize = 0;
        for ([_][]abi.AudioBusBuffers{ inputs, outputs }) |list| {
            for (list) |*bus| {
                bus.buffers = .{ .channel_buffers_32 = channel_ptrs[next..].ptr };
                next += @intCast(bus.num_channels);
            }
        }
        return .{ .inputs = inputs, .outputs = outputs, .channel_ptrs = channel_ptrs, .pool = pool, .main_output_channel = main_output_channel };
    }

    fn deinit(self: *BusBuffers, allocator: std.mem.Allocator) void {
        allocator.free(self.inputs);
        allocator.free(self.outputs);
        allocator.free(self.channel_ptrs);
        allocator.free(self.pool);
    }
};

/// Real in-process VST3 hosting - unchanged from before sandboxing
/// existed. Constructed by `Vst3Plugin.loadModuleDirect`; also the exact
/// code plugin_host/child_main.zig runs inside a sandboxed child.
const Direct = struct {
    allocator: std.mem.Allocator,
    module: module_mod.Module,
    component: *abi.Component,
    processor: *abi.AudioProcessor,
    controller: ?*abi.EditController,
    midi_mapping: ?*abi.MidiMapping,
    component_connection: ?*abi.ConnectionPoint,
    controller_connection: ?*abi.ConnectionPoint,
    host_context: *HostContext,
    bundle_path: []u8,
    class_id: [32]u8,
    /// Channels of the *main* bus this host actually exchanges audio on,
    /// clamped to 2. The buses themselves may have more (or none).
    input_channels: u8,
    output_channels: u8,
    buses: BusBuffers,
    events: HostEventList = .{},
    active_notes: [128]bool = .{false} ** 128,
    transport: ?*const Transport = null,
    param_changes: ParamChanges = .{},
    restart_in_progress: std.atomic.Value(bool) = .init(false),
    restart_ready: std.atomic.Value(bool) = .init(false),
    sample_rate: u32,
    instrument: bool,
    parameter_indices: [max_parameters]u16 = undefined,
    parameter_count: usize = 0,
    parameter_names: [max_parameters][64]u8 = undefined,
    automatable_params: [max_parameters]device_mod.AutomatableParam = undefined,
    automatable_count: usize = 0,
    editor: ?editor_mod.Editor = null,

    fn deinit(self: *Direct) void {
        if (self.editor) |*editor| editor.close();
        _ = self.processor.vtable.set_processing(self.processor, 0);
        _ = self.component.vtable.set_active(self.component, 0);
        _ = self.processor.vtable.release(self.processor);
        if (self.midi_mapping) |value| _ = value.vtable.release(value);
        if (self.controller_connection) |controller| {
            if (self.component_connection) |component| {
                _ = controller.vtable.disconnect(controller, component);
                _ = component.vtable.disconnect(component, controller);
            }
        }
        if (self.component_connection) |value| _ = value.vtable.release(value);
        if (self.controller_connection) |value| _ = value.vtable.release(value);
        if (self.controller) |value| {
            _ = value.vtable.set_component_handler(value, null);
            _ = value.vtable.terminate(value);
            _ = value.vtable.release(value);
        }
        _ = self.component.vtable.terminate(self.component);
        _ = self.component.vtable.release(self.component);
        self.module.close();
        self.allocator.free(self.bundle_path);
        self.buses.deinit(self.allocator);
        self.allocator.destroy(self.host_context);
        // No `allocator.destroy(self)` here: unlike the outer `Vst3Plugin`,
        // `Direct` is embedded by value inside `Vst3Plugin.impl`, not its
        // own heap allocation - the outer `deinit` frees the whole thing.
    }

    fn processBlock(self: *Direct, buf: []types.Sample) void {
        const frames = buf.len / 2;
        if (frames == 0 or frames > types.max_block_frames or buf.len % 2 != 0) return;
        const restart_flags = self.host_context.restart_flags.load(.acquire);
        if (restart_flags & 3 != 0 and !self.restart_in_progress.load(.acquire)) {
            self.restart_in_progress.store(true, .release);
            _ = self.processor.vtable.set_processing(self.processor, 0);
            self.restart_ready.store(true, .release);
        }
        if (self.restart_in_progress.load(.acquire)) return;
        // Every channel of every bus starts silent - the deactivated ones
        // stay that way, and the plugin's writes into them are discarded.
        for (self.buses.channel_ptrs) |channel| @memset(channel[0..frames], 0);
        if (self.input_channels > 0) {
            const left = self.buses.channel_ptrs[0];
            for (0..frames) |frame|
                left[frame] = if (self.input_channels == 1) (buf[frame * 2] + buf[frame * 2 + 1]) * 0.5 else buf[frame * 2];
            if (self.input_channels >= 2) {
                const right = self.buses.channel_ptrs[1];
                for (0..frames) |frame| right[frame] = buf[frame * 2 + 1];
            }
        }
        var context = self.makeProcessContext();
        var data: abi.ProcessData = .{
            .process_mode = 0,
            .symbolic_sample_size = 0,
            .num_samples = @intCast(frames),
            .num_inputs = @intCast(self.buses.inputs.len),
            .num_outputs = @intCast(self.buses.outputs.len),
            .inputs = if (self.buses.inputs.len == 0) null else self.buses.inputs.ptr,
            .outputs = self.buses.outputs.ptr,
            .input_parameter_changes = @ptrCast(&self.param_changes.interface),
            .output_parameter_changes = null,
            .input_events = @ptrCast(&self.events.interface),
            .output_events = null,
            .process_context = @ptrCast(&context),
        };
        const result = self.processor.vtable.process(self.processor, &data);
        self.events.len = 0;
        self.param_changes.len = 0;
        if (result != 0) return;
        const out_left = self.buses.channel_ptrs[self.buses.main_output_channel];
        const out_right = if (self.output_channels >= 2) self.buses.channel_ptrs[self.buses.main_output_channel + 1] else out_left;
        for (0..frames) |frame| {
            buf[frame * 2] = out_left[frame];
            buf[frame * 2 + 1] = out_right[frame];
        }
    }

    /// `outer` is the `Vst3Plugin` wrapper this `Direct` is embedded in -
    /// needed only for the `vst3_param` identity check below, matching
    /// `ClapPlugin`'s `Direct.handleEvent` (see src/clap/plugin.zig).
    fn handleEvent(self: *Direct, outer: *Vst3Plugin, event: device_mod.Event) void {
        switch (event) {
            .note_on => |note| self.pushNote(true, note.note, note.velocity),
            .note_off => |note| self.pushNote(false, note.note, 0),
            .all_off => for (&self.active_notes, 0..) |active, note| if (active) self.pushNote(false, @intCast(note), 0),
            .cc => |cc| self.pushMidiMapping(cc.cc, @as(f64, @floatFromInt(cc.value)) / 127.0),
            .midi2_cc => |cc| self.pushMidiMapping(cc.cc, cc.value),
            .pitch_bend => |bend| self.pushMidiMapping(129, @as(f64, @floatFromInt(@as(i32, bend.bend) + 8192)) / 16383.0),
            .midi2_pitch_bend => |bend| self.pushMidiMapping(129, (@as(f64, bend.value) + 1.0) * 0.5),
            .midi2_per_note_pitch_bend => {},
            .channel_pressure => |pressure| self.pushMidiMapping(128, pressure.value),
            .poly_pressure => {},
            .program_change => |program| self.pushMidiMapping(130, @as(f64, @floatFromInt(program.program)) / 127.0),
            .automation_param => |param| if (self.instrument and param.instance_id == 0) self.setParameter(param.id, param.value, param.sample_offset),
            .vst3_param => |param| if (param.target == @as(*anyopaque, @ptrCast(outer))) self.setParameter(param.id, param.value, param.sample_offset),
            else => {},
        }
    }

    fn pushMidiMapping(self: *Direct, controller_number: i16, value: f64) void {
        const mapping = self.midi_mapping orelse return;
        var id: u32 = 0;
        if (mapping.vtable.get_midi_controller_assignment(mapping, 0, 0, controller_number, &id) == 0)
            self.param_changes.push(id, 0, std.math.clamp(value, 0, 1));
    }

    fn pushNote(self: *Direct, on: bool, note: u7, velocity: f32) void {
        if (self.events.len == max_events) return;
        var event: abi.Event = std.mem.zeroes(abi.Event);
        event.flags = 1;
        if (on) {
            event.event_type = 0;
            event.payload.note_on = .{ .channel = 0, .pitch = note, .tuning = 0, .velocity = velocity, .length = 0, .note_id = note };
        } else {
            event.event_type = 1;
            event.payload.note_off = .{ .channel = 0, .pitch = note, .velocity = velocity, .note_id = note, .tuning = 0 };
        }
        self.events.events[self.events.len] = event;
        self.events.len += 1;
        self.active_notes[note] = on;
    }

    fn attachTransport(self: *Direct, transport: *const Transport) void {
        self.transport = transport;
    }

    fn parameterCount(self: *const Direct) usize {
        return self.parameter_count;
    }

    fn parameterInfo(self: *const Direct, index: usize) ?abi.ParameterInfo {
        const controller = self.controller orelse return null;
        var info: abi.ParameterInfo = undefined;
        if (index >= self.parameter_count) return null;
        if (controller.vtable.get_parameter_info(controller, self.parameter_indices[index], &info) != 0) return null;
        return info;
    }

    fn automationParams(self: *const Direct) []const device_mod.AutomatableParam {
        return self.automatable_params[0..self.automatable_count];
    }

    fn parameterName(self: *const Direct, index: usize, buf: []u8) ?[]const u8 {
        const info = self.parameterInfo(index) orelse return null;
        const title = std.mem.sliceTo(&info.title, 0);
        const len = std.unicode.utf16LeToUtf8(buf, title) catch return null;
        return buf[0..len];
    }

    fn formatParameter(self: *const Direct, id: u32, value: f64, buf: []u8) ?[]const u8 {
        const controller = self.controller orelse return null;
        var text: [128]u16 = undefined;
        if (controller.vtable.get_param_string_by_value(controller, id, value, &text) != 0) return null;
        const len = std.unicode.utf16LeToUtf8(buf, std.mem.sliceTo(&text, 0)) catch return null;
        return buf[0..len];
    }

    fn saveComponentState(self: *Direct, allocator: std.mem.Allocator) ![]u8 {
        var stream = MemoryStream.init(allocator);
        defer stream.deinit();
        if (self.component.vtable.get_state(self.component, &stream.interface) != 0) return error.ComponentStateSaveFailed;
        return try allocator.dupe(u8, stream.data.items);
    }

    fn saveControllerState(self: *Direct, allocator: std.mem.Allocator) !?[]u8 {
        const controller = self.controller orelse return null;
        var stream = MemoryStream.init(allocator);
        defer stream.deinit();
        // `IEditController::getState` is optional, and a plugin that keeps no
        // controller-side state of its own says so with `kNotImplemented`
        // rather than by failing. Every JUCE plugin in the test set answers
        // that way; treating it as an error made saving them impossible.
        const result = controller.vtable.get_state(controller, &stream.interface);
        if (result == abi.not_implemented) return null;
        if (result != 0) return error.ControllerStateSaveFailed;
        return @as(?[]u8, try allocator.dupe(u8, stream.data.items));
    }

    fn loadState(self: *Direct, component_bytes: []const u8, controller_bytes: []const u8) !void {
        self.param_changes.len = 0;
        var component_stream = try MemoryStream.initRead(self.allocator, component_bytes);
        defer component_stream.deinit();
        if (self.component.vtable.set_state(self.component, &component_stream.interface) != 0) return error.ComponentStateLoadFailed;
        if (self.controller) |controller| {
            component_stream.position = 0;
            // Same optionality on the way back in: syncing the controller to
            // the processor's state is best effort, and a plugin that mirrors
            // its parameters internally answers `kNotImplemented`. The
            // component state above is what actually carries the sound.
            const sync = controller.vtable.set_component_state(controller, &component_stream.interface);
            if (sync != 0 and sync != abi.not_implemented) return error.ControllerComponentStateLoadFailed;
            if (controller_bytes.len > 0) {
                var controller_stream = try MemoryStream.initRead(self.allocator, controller_bytes);
                defer controller_stream.deinit();
                const restored = controller.vtable.set_state(controller, &controller_stream.interface);
                if (restored != 0 and restored != abi.not_implemented) return error.ControllerStateLoadFailed;
            }
        }
    }

    fn parameterValue(self: *const Direct, id: u32) ?f64 {
        const controller = self.controller orelse return null;
        return controller.vtable.get_param_normalized(controller, id);
    }

    fn setParameter(self: *Direct, id: u32, value: f64, sample_offset: u32) void {
        const controller = self.controller orelse return;
        const normalized = std.math.clamp(value, 0, 1);
        if (controller.vtable.set_param_normalized(controller, id, normalized) == 0)
            self.param_changes.push(id, sample_offset, normalized);
    }

    fn makeProcessContext(self: *const Direct) abi.ProcessContext {
        const transport = self.transport orelse return std.mem.zeroes(abi.ProcessContext);
        const beats = transport.positionBeats();
        const meter = transport.currentMeter();
        const bar = transport.positionBarBeat().bar;
        var state: u32 = (1 << 17) | (1 << 9) | (1 << 11) | (1 << 10) | (1 << 13);
        if (transport.playing) state |= 1 << 1;
        if (transport.loop_enabled) state |= (1 << 2) | (1 << 12);
        return .{
            .state = state,
            .sample_rate = @floatFromInt(transport.sample_rate),
            .project_time_samples = vstSamplePosition(transport.position_frames),
            .system_time = 0,
            .continuous_time_samples = vstSamplePosition(transport.position_frames),
            .project_time_music = beats,
            .bar_position_music = transport.beatAtBar(bar),
            .cycle_start_music = transport.beatsAtFrames(transport.loop_start_frames),
            .cycle_end_music = transport.beatsAtFrames(transport.loop_end_frames),
            .tempo = transport.currentTempo(),
            .time_sig_numerator = meter.numerator,
            .time_sig_denominator = meter.denominator,
            .chord = .{ .key_note = 0, .root_note = 0, .chord_mask = 0 },
            .smpte_offset_subframes = 0,
            .frame_rate = .{ .frames_per_second = 0, .flags = 0 },
            .samples_to_next_clock = 0,
        };
    }

    fn reset(_: *Direct) void {}
    fn latencySamples(self: *const Direct) u32 {
        return self.processor.vtable.get_latency_samples(self.processor);
    }

    fn hasGui(self: *const Direct) bool {
        if (!editor_mod.supported) return false;
        const controller = self.controller orelse return false;
        const raw = controller.vtable.create_view(controller, "editor") orelse return false;
        const view: *abi.PlugView = @ptrCast(@alignCast(raw));
        defer _ = view.vtable.release(view);
        return view.vtable.is_platform_type_supported(view, editor_mod.platform_type) == 0;
    }

    fn toggleGui(self: *Direct) !bool {
        if (self.editor) |*editor| {
            editor.close();
            self.editor = null;
            return false;
        }
        const controller = self.controller orelse return error.GuiUnavailable;
        self.editor = try editor_mod.Editor.open(controller, "wstudio VST3");
        return true;
    }

    fn serviceMainThread(self: *Direct) bool {
        if (self.editor) |*editor| if (!editor.service()) {
            editor.close();
            self.editor = null;
        };
        if (self.restart_ready.swap(false, .acquire)) {
            _ = self.component.vtable.set_active(self.component, 0);
            var setup: abi.ProcessSetup = .{ .process_mode = 0, .symbolic_sample_size = 0, .max_samples_per_block = types.max_block_frames, .sample_rate = @floatFromInt(self.sample_rate) };
            const setup_ok = self.processor.vtable.setup_processing(self.processor, &setup) == 0;
            const active_ok = setup_ok and self.component.vtable.set_active(self.component, 1) == 0;
            const start_result = if (active_ok) self.processor.vtable.set_processing(self.processor, 1) else -1;
            const restarted = active_ok and (start_result == 0 or start_result == abi.not_implemented);
            if (!restarted)
                std.log.err("VST3 restart failed: {s}", .{&self.class_id});
            if (restarted) self.restart_in_progress.store(false, .release);
        }
        _ = self.host_context.restart_flags.swap(0, .acquire);
        return self.host_context.state_dirty.swap(false, .acquire);
    }
};

test "VST3 memory stream reads writes and seeks" {
    var stream = MemoryStream.init(std.testing.allocator);
    defer stream.deinit();
    const input = "state";
    var count: i32 = 0;
    try std.testing.expectEqual(@as(abi.Result, 0), stream.interface.vtable.write(&stream.interface, input.ptr, input.len, &count));
    try std.testing.expectEqual(@as(i32, input.len), count);
    var position: i64 = -1;
    try std.testing.expectEqual(@as(abi.Result, 0), stream.interface.vtable.seek(&stream.interface, 0, 0, &position));
    var output: [5]u8 = undefined;
    try std.testing.expectEqual(@as(abi.Result, 0), stream.interface.vtable.read(&stream.interface, &output, output.len, &count));
    try std.testing.expectEqualStrings(input, &output);
}

test "VST3 stream out-parameters are optional" {
    var stream = MemoryStream.init(std.testing.allocator);
    defer stream.deinit();
    const input = "state";
    // JUCE's getState passes null for numBytesWritten; a host that stores
    // through it unconditionally segfaults on every JUCE plugin's save.
    try std.testing.expectEqual(@as(abi.Result, 0), stream.interface.vtable.write(&stream.interface, input.ptr, input.len, null));
    try std.testing.expectEqual(@as(abi.Result, 0), stream.interface.vtable.seek(&stream.interface, 0, 0, null));
    try std.testing.expectEqual(@as(abi.Result, 0), stream.interface.vtable.tell(&stream.interface, null));
    var output: [5]u8 = undefined;
    try std.testing.expectEqual(@as(abi.Result, 0), stream.interface.vtable.read(&stream.interface, &output, output.len, null));
    try std.testing.expectEqualStrings(input, &output);
}

test "host-created VST3 messages carry attributes and free themselves" {
    var host: HostContext = .{ .allocator = std.testing.allocator };
    var raw: ?*anyopaque = null;
    try std.testing.expectEqual(
        @as(abi.Result, 0),
        host.application.vtable.create_instance(&host.application, &abi.message_iid, &abi.message_iid, &raw),
    );
    const message: *abi.Message = @ptrCast(@alignCast(raw.?));
    message.vtable.set_message_id(message, "sfizz");
    try std.testing.expectEqualStrings("sfizz", std.mem.span(message.vtable.get_message_id(message).?));

    const attributes = message.vtable.get_attributes(message).?;
    _ = attributes.vtable.set_int(attributes, "count", 7);
    _ = attributes.vtable.set_float(attributes, "gain", 0.5);
    _ = attributes.vtable.set_string(attributes, "path", std.unicode.utf8ToUtf16LeStringLiteral("a.sfz"));
    _ = attributes.vtable.set_binary(attributes, "blob", "xyz", 3);
    // Overwriting a key reuses its slot rather than growing the list.
    _ = attributes.vtable.set_int(attributes, "count", 9);

    var int_value: i64 = 0;
    try std.testing.expectEqual(@as(abi.Result, 0), attributes.vtable.get_int(attributes, "count", &int_value));
    try std.testing.expectEqual(@as(i64, 9), int_value);
    var float_value: f64 = 0;
    try std.testing.expectEqual(@as(abi.Result, 0), attributes.vtable.get_float(attributes, "gain", &float_value));
    try std.testing.expectEqual(@as(f64, 0.5), float_value);
    var text: [8]u16 = undefined;
    try std.testing.expectEqual(@as(abi.Result, 0), attributes.vtable.get_string(attributes, "path", &text, @sizeOf(@TypeOf(text))));
    var utf8: [8]u8 = undefined;
    const len = try std.unicode.utf16LeToUtf8(&utf8, std.mem.sliceTo(&text, 0));
    try std.testing.expectEqualStrings("a.sfz", utf8[0..len]);
    var blob: ?*const anyopaque = null;
    var blob_len: u32 = 0;
    try std.testing.expectEqual(@as(abi.Result, 0), attributes.vtable.get_binary(attributes, "blob", &blob, &blob_len));
    try std.testing.expectEqualStrings("xyz", @as([*]const u8, @ptrCast(blob.?))[0..blob_len]);
    try std.testing.expect(attributes.vtable.get_int(attributes, "missing", &int_value) != 0);

    // The plugin owns the message from here: the testing allocator fails
    // this test if release does not free it and everything it copied.
    try std.testing.expectEqual(@as(u32, 2), message.vtable.add_ref(message));
    try std.testing.expectEqual(@as(u32, 1), message.vtable.release(message));
    try std.testing.expectEqual(@as(u32, 0), message.vtable.release(message));
}

test "controller cleanup terminates only initialized instances and always releases" {
    const Mock = struct {
        const Self = @This();
        const VTable = struct {
            terminate: *const fn (*Self) i32,
            release: *const fn (*Self) u32,
        };
        vtable: *const VTable = &vtable_value,
        terminated: usize = 0,
        released: usize = 0,

        fn terminate(self: *Self) i32 {
            self.terminated += 1;
            return 0;
        }
        fn release(self: *Self) u32 {
            self.released += 1;
            return 0;
        }
        const vtable_value: VTable = .{ .terminate = terminate, .release = release };
    };

    var before_init: Mock = .{};
    releaseController(@as(?*Mock, &before_init), false);
    try std.testing.expectEqual(@as(usize, 0), before_init.terminated);
    try std.testing.expectEqual(@as(usize, 1), before_init.released);

    var after_init: Mock = .{};
    releaseController(@as(?*Mock, &after_init), true);
    try std.testing.expectEqual(@as(usize, 1), after_init.terminated);
    try std.testing.expectEqual(@as(usize, 1), after_init.released);
}

test "VST3 sample position clamps beyond signed ABI range" {
    try std.testing.expectEqual(@as(i64, 48_000), vstSamplePosition(48_000));
    try std.testing.expectEqual(std.math.maxInt(i64), vstSamplePosition(std.math.maxInt(u64)));
}

test "VST3 state wire decoder rejects oversized fields" {
    const oversized = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 };
    try std.testing.expectError(error.ComponentStateSaveFailed, savedComponentFromWire(std.testing.allocator, &oversized));
    try std.testing.expectError(error.ComponentStateSaveFailed, savedControllerFromWire(std.testing.allocator, &oversized));

    const oversized_controller = [_]u8{ 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.ComponentStateSaveFailed, savedControllerFromWire(std.testing.allocator, &oversized_controller));

    var state_buf: [16]u8 = undefined;
    try std.testing.expectError(error.StatePayloadTooLarge, encodeStateForWire(&state_buf, "123456789", &.{}));
    try std.testing.expectError(error.StatePayloadTooLarge, encodeStateForWire(state_buf[0..7], &.{}, &.{}));
}

test "VST3 parameter queue preserves sample offsets" {
    var changes: ParamChanges = .{};
    changes.push(7, 12, 0.25);
    changes.push(7, 48, 0.75);
    const queue = ParamChanges.get(&changes.interface, 0).?;
    try std.testing.expectEqual(@as(i32, 2), queue.vtable.get_point_count(queue));
    var offset: i32 = 0;
    var value: f64 = 0;
    try std.testing.expectEqual(@as(abi.Result, 0), queue.vtable.get_point(queue, 1, &offset, &value));
    try std.testing.expectEqual(@as(i32, 48), offset);
    try std.testing.expectEqual(@as(f64, 0.75), value);
}

//! VST3 component loader and realtime-safe mono/stereo audio adapter.

const std = @import("std");
const abi = @import("abi.zig");
const module_mod = @import("module.zig");
const scan = @import("scan.zig");
const device_mod = @import("../dsp/device.zig");
const types = @import("../core/types.zig");
const Transport = @import("../transport.zig").Transport;

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
    fn query(raw: *anyopaque, _: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        object.* = raw;
        return 0;
    }
    fn ref(_: *anyopaque) callconv(abi.abi_callconv) u32 {
        return 1;
    }
    fn read(raw: *anyopaque, destination: *anyopaque, count: i32, read_count: *i32) callconv(abi.abi_callconv) abi.Result {
        const self = from(raw);
        if (count < 0) return -1;
        const len = @min(@as(usize, @intCast(count)), self.data.items.len -| self.position);
        @memcpy(@as([*]u8, @ptrCast(destination))[0..len], self.data.items[self.position..][0..len]);
        self.position += len;
        read_count.* = @intCast(len);
        return 0;
    }
    fn write(raw: *anyopaque, source: *const anyopaque, count: i32, written: *i32) callconv(abi.abi_callconv) abi.Result {
        const self = from(raw);
        if (count < 0) return -1;
        const len: usize = @intCast(count);
        const end = std.math.add(usize, self.position, len) catch return -1;
        self.data.resize(self.allocator, end) catch return -1;
        @memcpy(self.data.items[self.position..end], @as([*]const u8, @ptrCast(source))[0..len]);
        self.position = end;
        written.* = count;
        return 0;
    }
    fn seek(raw: *anyopaque, offset: i64, mode: i32, result: *i64) callconv(abi.abi_callconv) abi.Result {
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
        result.* = target;
        return 0;
    }
    fn tell(raw: *anyopaque, result: *i64) callconv(abi.abi_callconv) abi.Result {
        result.* = @intCast(from(raw).position);
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
const HostContext = struct {
    handler: abi.ComponentHandler = .{ .vtable = &vtable },
    application: abi.HostApplication = .{ .vtable = &application_vtable },
    restart_flags: std.atomic.Value(i32) = .init(0),
    state_dirty: std.atomic.Value(bool) = .init(false),

    fn from(raw: *anyopaque) *HostContext {
        return @ptrCast(@alignCast(raw));
    }
    fn query(raw: *anyopaque, _: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
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
    fn appCreate(_: *anyopaque, _: *const abi.Tuid, _: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
        object.* = null;
        return -1;
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
    interface: abi.ParamValueQueue = .{ .vtable = &vtable },
    id: u32 = 0,
    value: f64 = 0,

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
    fn count(_: *anyopaque) callconv(abi.abi_callconv) i32 {
        return 1;
    }
    fn get(raw: *anyopaque, index: i32, offset: *i32, value: *f64) callconv(abi.abi_callconv) abi.Result {
        if (index != 0) return -1;
        offset.* = 0;
        value.* = from(raw).value;
        return 0;
    }
    fn add(raw: *anyopaque, _: i32, value: f64, index: *i32) callconv(abi.abi_callconv) abi.Result {
        from(raw).value = value;
        index.* = 0;
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
    fn push(self: *ParamChanges, id: u32, value: f64) void {
        var queue_index: i32 = 0;
        const queue = add(self, &id, &queue_index) orelse return;
        _ = queue.vtable.add_point(queue, 0, value, &queue_index);
    }
    const vtable: abi.ParameterChangesVTable = .{ .query_interface = query, .add_ref = ref, .release = ref, .get_parameter_count = count, .get_parameter_data = get, .add_parameter_data = add };
};

pub const Vst3Plugin = struct {
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
    input_channels: u8,
    output_channels: u8,
    input_left: []f32,
    input_right: []f32,
    output_left: []f32,
    output_right: []f32,
    input_ptrs: [2][*]f32 = undefined,
    output_ptrs: [2][*]f32 = undefined,
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

    pub const device = device_mod.deviceOf(Vst3Plugin);

    pub fn load(allocator: std.mem.Allocator, bundle_path: []const u8, id: []const u8, sample_rate: u32, instrument: bool) !*Vst3Plugin {
        const relative = try scan.moduleRelativePath(allocator, std.fs.path.basename(bundle_path), @import("builtin").os.tag, @import("builtin").cpu.arch);
        defer allocator.free(relative);
        const module_path = try std.fs.path.join(allocator, &.{ bundle_path, relative });
        defer allocator.free(module_path);
        return loadModule(allocator, module_path, bundle_path, id, sample_rate, instrument);
    }

    pub fn loadModule(allocator: std.mem.Allocator, module_path: []const u8, bundle_path: []const u8, id: []const u8, sample_rate: u32, instrument: bool) !*Vst3Plugin {
        const class_id = try abi.parseUid(id);
        var module = try module_mod.Module.open(module_path);
        errdefer module.close();
        const host_context = try allocator.create(HostContext);
        errdefer allocator.destroy(host_context);
        host_context.* = .{};

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
        var controller_id: abi.Tuid = undefined;
        if (component.vtable.get_controller_class_id(component, &controller_id) == 0) {
            var controller_raw: ?*anyopaque = null;
            if (module.factory.vtable.create_instance(module.factory, &controller_id, &abi.edit_controller_iid, &controller_raw) == 0) {
                controller = @ptrCast(@alignCast(controller_raw orelse return error.ControllerCreateFailed));
                if (controller.?.vtable.initialize(controller.?, @ptrCast(&host_context.application)) != 0) return error.ControllerInitializeFailed;
                if (controller.?.vtable.set_component_handler(controller.?, &host_context.handler) != 0) return error.ComponentHandlerRejected;
            }
        }
        errdefer {
            if (controller) |value| {
                _ = value.vtable.terminate(value);
                _ = value.vtable.release(value);
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
        const input_count = component.vtable.get_bus_count(component, 0, 0);
        const output_count = component.vtable.get_bus_count(component, 0, 1);
        if (input_count != @as(i32, if (instrument) 0 else 1) or output_count != 1)
            return error.UnsupportedAudioBusCount;
        var output_info: abi.BusInfo = undefined;
        if (component.vtable.get_bus_info(component, 0, 1, 0, &output_info) != 0 or
            (output_info.channel_count != 1 and output_info.channel_count != 2))
            return error.UnsupportedAudioBusLayout;
        var input_channels: i32 = 0;
        if (input_count == 1) {
            var input_info: abi.BusInfo = undefined;
            if (component.vtable.get_bus_info(component, 0, 0, 0, &input_info) != 0 or
                (input_info.channel_count != 1 and input_info.channel_count != 2))
                return error.UnsupportedAudioBusLayout;
            input_channels = input_info.channel_count;
        }

        var input_arrangement: [1]u64 = .{if (input_channels == 1) 1 else 3};
        var output_arrangement: [1]u64 = .{if (output_info.channel_count == 1) 1 else 3};
        if (processor.vtable.set_bus_arrangements(
            processor,
            if (input_count == 1) &input_arrangement else null,
            input_count,
            &output_arrangement,
            1,
        ) != 0) return error.UnsupportedAudioBusLayout;
        if (input_count == 1 and component.vtable.activate_bus(component, 0, 0, 0, 1) != 0)
            return error.BusActivationFailed;
        if (component.vtable.activate_bus(component, 0, 1, 0, 1) != 0) return error.BusActivationFailed;

        var setup: abi.ProcessSetup = .{ .process_mode = 0, .symbolic_sample_size = 0, .max_samples_per_block = types.max_block_frames, .sample_rate = @floatFromInt(sample_rate) };
        if (processor.vtable.setup_processing(processor, &setup) != 0) return error.ProcessingSetupFailed;
        if (component.vtable.set_active(component, 1) != 0) return error.ComponentActivationFailed;
        errdefer _ = component.vtable.set_active(component, 0);
        if (processor.vtable.set_processing(processor, 1) != 0) return error.ProcessingStartFailed;
        errdefer _ = processor.vtable.set_processing(processor, 0);

        const self = try allocator.create(Vst3Plugin);
        errdefer allocator.destroy(self);
        const input_left = try allocator.alloc(f32, types.max_block_frames);
        errdefer allocator.free(input_left);
        const input_right = try allocator.alloc(f32, types.max_block_frames);
        errdefer allocator.free(input_right);
        const output_left = try allocator.alloc(f32, types.max_block_frames);
        errdefer allocator.free(output_left);
        const output_right = try allocator.alloc(f32, types.max_block_frames);
        errdefer allocator.free(output_right);
        const owned_path = try allocator.dupe(u8, bundle_path);
        errdefer allocator.free(owned_path);
        self.* = .{
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
            .input_channels = @intCast(input_channels),
            .output_channels = @intCast(output_info.channel_count),
            .input_left = input_left,
            .input_right = input_right,
            .output_left = output_left,
            .output_right = output_right,
            .sample_rate = sample_rate,
            .instrument = instrument,
        };
        if (controller) |value| {
            const count: usize = @intCast(@min(@max(value.vtable.get_parameter_count(value), 0), max_parameters));
            for (0..count) |raw_index| {
                var info: abi.ParameterInfo = undefined;
                if (value.vtable.get_parameter_info(value, @intCast(raw_index), &info) != 0 or info.flags & 1 == 0) continue;
                const index = self.parameter_count;
                self.parameter_indices[index] = @intCast(raw_index);
                self.parameter_count += 1;
                const title = std.mem.sliceTo(&info.title, 0);
                const len = std.unicode.utf16LeToUtf8(&self.parameter_names[index], title) catch 0;
                self.automatable_params[self.automatable_count] = .{
                    .id = info.id,
                    .label = self.parameter_names[index][0..len],
                    .section = "VST3",
                    .range = .{ 0, 1 },
                    .step = 0.01,
                };
                self.automatable_count += 1;
            }
        }
        return self;
    }

    pub fn deinit(self: *Vst3Plugin) void {
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
        self.allocator.free(self.input_left);
        self.allocator.free(self.input_right);
        self.allocator.free(self.output_left);
        self.allocator.free(self.output_right);
        self.allocator.destroy(self.host_context);
        self.allocator.destroy(self);
    }

    pub fn processBlock(self: *Vst3Plugin, buf: []types.Sample) void {
        const frames = buf.len / 2;
        if (frames == 0 or frames > types.max_block_frames or buf.len % 2 != 0) return;
        const restart_flags = self.host_context.restart_flags.load(.acquire);
        if (restart_flags & 3 != 0 and !self.restart_in_progress.load(.acquire)) {
            self.restart_in_progress.store(true, .release);
            _ = self.processor.vtable.set_processing(self.processor, 0);
            self.restart_ready.store(true, .release);
        }
        if (self.restart_in_progress.load(.acquire)) return;
        for (0..frames) |frame| {
            self.input_left[frame] = if (self.input_channels == 1) (buf[frame * 2] + buf[frame * 2 + 1]) * 0.5 else buf[frame * 2];
            self.input_right[frame] = buf[frame * 2 + 1];
            self.output_left[frame] = 0;
            self.output_right[frame] = 0;
        }
        self.input_ptrs = .{ self.input_left.ptr, self.input_right.ptr };
        self.output_ptrs = .{ self.output_left.ptr, self.output_right.ptr };
        var input = abi.AudioBusBuffers{ .num_channels = self.input_channels, .silence_flags = 0, .buffers = .{ .channel_buffers_32 = &self.input_ptrs } };
        var output = abi.AudioBusBuffers{ .num_channels = self.output_channels, .silence_flags = 0, .buffers = .{ .channel_buffers_32 = &self.output_ptrs } };
        var context = self.makeProcessContext();
        var data: abi.ProcessData = .{
            .process_mode = 0,
            .symbolic_sample_size = 0,
            .num_samples = @intCast(frames),
            .num_inputs = if (self.input_channels == 0) 0 else 1,
            .num_outputs = 1,
            .inputs = if (self.input_channels == 0) null else @ptrCast(&input),
            .outputs = @ptrCast(&output),
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
        for (0..frames) |frame| {
            buf[frame * 2] = self.output_left[frame];
            buf[frame * 2 + 1] = if (self.output_channels == 1) self.output_left[frame] else self.output_right[frame];
        }
    }

    pub fn handleEvent(self: *Vst3Plugin, event: device_mod.Event) void {
        switch (event) {
            .note_on => |note| self.pushNote(true, note.note, note.velocity),
            .note_off => |note| self.pushNote(false, note.note, 0),
            .all_off => for (&self.active_notes, 0..) |active, note| if (active) self.pushNote(false, @intCast(note), 0),
            .cc => |cc| self.pushMidiMapping(cc.cc, @as(f64, @floatFromInt(cc.value)) / 127.0),
            .pitch_bend => |bend| self.pushMidiMapping(129, @as(f64, @floatFromInt(@as(i32, bend.bend) + 8192)) / 16383.0),
            .automation_param => |param| if (self.instrument) self.setParameter(param.id, param.value),
            .vst3_param => |param| if (param.target == @as(*anyopaque, @ptrCast(self))) self.setParameter(param.id, param.value),
            else => {},
        }
    }

    fn pushMidiMapping(self: *Vst3Plugin, controller_number: i16, value: f64) void {
        const mapping = self.midi_mapping orelse return;
        var id: u32 = 0;
        if (mapping.vtable.get_midi_controller_assignment(mapping, 0, 0, controller_number, &id) == 0)
            self.param_changes.push(id, std.math.clamp(value, 0, 1));
    }

    fn pushNote(self: *Vst3Plugin, on: bool, note: u7, velocity: f32) void {
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

    pub fn attachTransport(self: *Vst3Plugin, transport: *const Transport) void {
        self.transport = transport;
    }

    pub fn pluginPath(self: *const Vst3Plugin) []const u8 {
        return self.bundle_path;
    }

    pub fn classId(self: *const Vst3Plugin) []const u8 {
        return &self.class_id;
    }

    pub fn parameterCount(self: *const Vst3Plugin) usize {
        return self.parameter_count;
    }

    pub fn parameterInfo(self: *const Vst3Plugin, index: usize) ?abi.ParameterInfo {
        const controller = self.controller orelse return null;
        var info: abi.ParameterInfo = undefined;
        if (index >= self.parameter_count) return null;
        if (controller.vtable.get_parameter_info(controller, self.parameter_indices[index], &info) != 0) return null;
        return info;
    }

    pub fn automationParams(self: *const Vst3Plugin) []const device_mod.AutomatableParam {
        return self.automatable_params[0..self.automatable_count];
    }

    pub fn parameterName(self: *const Vst3Plugin, index: usize, buf: []u8) ?[]const u8 {
        const info = self.parameterInfo(index) orelse return null;
        const title = std.mem.sliceTo(&info.title, 0);
        const len = std.unicode.utf16LeToUtf8(buf, title) catch return null;
        return buf[0..len];
    }

    pub fn formatParameter(self: *const Vst3Plugin, id: u32, value: f64, buf: []u8) ?[]const u8 {
        const controller = self.controller orelse return null;
        var text: [128]u16 = undefined;
        if (controller.vtable.get_param_string_by_value(controller, id, value, &text) != 0) return null;
        const len = std.unicode.utf16LeToUtf8(buf, std.mem.sliceTo(&text, 0)) catch return null;
        return buf[0..len];
    }

    pub fn saveComponentState(self: *Vst3Plugin, allocator: std.mem.Allocator) ![]u8 {
        var stream = MemoryStream.init(allocator);
        defer stream.deinit();
        if (self.component.vtable.get_state(self.component, &stream.interface) != 0) return error.ComponentStateSaveFailed;
        return try allocator.dupe(u8, stream.data.items);
    }

    pub fn saveControllerState(self: *Vst3Plugin, allocator: std.mem.Allocator) !?[]u8 {
        const controller = self.controller orelse return null;
        var stream = MemoryStream.init(allocator);
        defer stream.deinit();
        if (controller.vtable.get_state(controller, &stream.interface) != 0) return error.ControllerStateSaveFailed;
        return @as(?[]u8, try allocator.dupe(u8, stream.data.items));
    }

    pub fn loadState(self: *Vst3Plugin, component_bytes: []const u8, controller_bytes: []const u8) !void {
        self.param_changes.len = 0;
        var component_stream = try MemoryStream.initRead(self.allocator, component_bytes);
        defer component_stream.deinit();
        if (self.component.vtable.set_state(self.component, &component_stream.interface) != 0) return error.ComponentStateLoadFailed;
        if (self.controller) |controller| {
            component_stream.position = 0;
            if (controller.vtable.set_component_state(controller, &component_stream.interface) != 0) return error.ControllerComponentStateLoadFailed;
            if (controller_bytes.len > 0) {
                var controller_stream = try MemoryStream.initRead(self.allocator, controller_bytes);
                defer controller_stream.deinit();
                if (controller.vtable.set_state(controller, &controller_stream.interface) != 0) return error.ControllerStateLoadFailed;
            }
        }
    }

    pub fn parameterValue(self: *const Vst3Plugin, id: u32) ?f64 {
        const controller = self.controller orelse return null;
        return controller.vtable.get_param_normalized(controller, id);
    }

    pub fn setParameter(self: *Vst3Plugin, id: u32, value: f64) void {
        const controller = self.controller orelse return;
        const normalized = std.math.clamp(value, 0, 1);
        if (controller.vtable.set_param_normalized(controller, id, normalized) == 0)
            self.param_changes.push(id, normalized);
    }

    fn makeProcessContext(self: *const Vst3Plugin) abi.ProcessContext {
        const transport = self.transport orelse return std.mem.zeroes(abi.ProcessContext);
        const beats = transport.positionBeats();
        const beats_per_bar: f64 = @floatFromInt(@max(transport.time_signature.beats_per_bar, 1));
        var state: u32 = (1 << 17) | (1 << 9) | (1 << 11) | (1 << 10) | (1 << 13);
        if (transport.playing) state |= 1 << 1;
        if (transport.loop_enabled) state |= (1 << 2) | (1 << 12);
        return .{
            .state = state,
            .sample_rate = @floatFromInt(transport.sample_rate),
            .project_time_samples = @intCast(transport.position_frames),
            .system_time = 0,
            .continuous_time_samples = @intCast(transport.position_frames),
            .project_time_music = beats,
            .bar_position_music = @floor(beats / beats_per_bar) * beats_per_bar,
            .cycle_start_music = @as(f64, @floatFromInt(transport.loop_start_frames)) / transport.framesPerBeat(),
            .cycle_end_music = @as(f64, @floatFromInt(transport.loop_end_frames)) / transport.framesPerBeat(),
            .tempo = transport.tempo_bpm,
            .time_sig_numerator = transport.time_signature.beats_per_bar,
            .time_sig_denominator = transport.time_signature.beat_unit,
            .chord = .{ .key_note = 0, .root_note = 0, .chord_mask = 0 },
            .smpte_offset_subframes = 0,
            .frame_rate = .{ .frames_per_second = 0, .flags = 0 },
            .samples_to_next_clock = 0,
        };
    }

    pub fn reset(_: *Vst3Plugin) void {}
    pub fn latencySamples(self: *const Vst3Plugin) u32 {
        return self.processor.vtable.get_latency_samples(self.processor);
    }

    pub fn latencyFrames(self: *const Vst3Plugin) u32 {
        return self.latencySamples();
    }

    pub fn serviceMainThread(self: *Vst3Plugin) bool {
        if (self.restart_ready.swap(false, .acquire)) {
            _ = self.component.vtable.set_active(self.component, 0);
            var setup: abi.ProcessSetup = .{ .process_mode = 0, .symbolic_sample_size = 0, .max_samples_per_block = types.max_block_frames, .sample_rate = @floatFromInt(self.sample_rate) };
            if (self.processor.vtable.setup_processing(self.processor, &setup) == 0 and
                self.component.vtable.set_active(self.component, 1) == 0 and
                self.processor.vtable.set_processing(self.processor, 1) == 0)
            {
                self.restart_in_progress.store(false, .release);
            } else std.log.err("VST3 restart failed: {s}", .{self.classId()});
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

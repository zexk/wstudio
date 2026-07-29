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

        var component_raw: ?*anyopaque = null;
        if (module.factory.vtable.create_instance(module.factory, &class_id, &abi.component_iid, &component_raw) != 0)
            return error.ComponentCreateFailed;
        const component: *abi.Component = @ptrCast(@alignCast(component_raw orelse return error.ComponentCreateFailed));
        var initialized = false;
        errdefer {
            if (initialized) _ = component.vtable.terminate(component);
            _ = component.vtable.release(component);
        }
        if (component.vtable.initialize(component, null) != 0) return error.ComponentInitializeFailed;
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
                if (controller.?.vtable.initialize(controller.?, null) != 0) return error.ControllerInitializeFailed;
            }
        }
        errdefer {
            if (controller) |value| {
                _ = value.vtable.terminate(value);
                _ = value.vtable.release(value);
            }
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
            .bundle_path = owned_path,
            .class_id = abi.formatUid(class_id),
            .input_channels = @intCast(input_channels),
            .output_channels = @intCast(output_info.channel_count),
            .input_left = input_left,
            .input_right = input_right,
            .output_left = output_left,
            .output_right = output_right,
        };
        return self;
    }

    pub fn deinit(self: *Vst3Plugin) void {
        _ = self.processor.vtable.set_processing(self.processor, 0);
        _ = self.component.vtable.set_active(self.component, 0);
        _ = self.processor.vtable.release(self.processor);
        if (self.controller) |value| {
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
        self.allocator.destroy(self);
    }

    pub fn processBlock(self: *Vst3Plugin, buf: []types.Sample) void {
        const frames = buf.len / 2;
        if (frames == 0 or frames > types.max_block_frames or buf.len % 2 != 0) return;
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
            .vst3_param => |param| if (param.target == @as(*anyopaque, @ptrCast(self))) self.setParameter(param.id, param.value),
            else => {},
        }
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

    pub fn parameterCount(self: *const Vst3Plugin) usize {
        const controller = self.controller orelse return 0;
        return @intCast(@max(controller.vtable.get_parameter_count(controller), 0));
    }

    pub fn parameterInfo(self: *const Vst3Plugin, index: usize) ?abi.ParameterInfo {
        const controller = self.controller orelse return null;
        var info: abi.ParameterInfo = undefined;
        if (controller.vtable.get_parameter_info(controller, @intCast(index), &info) != 0) return null;
        return info;
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
};

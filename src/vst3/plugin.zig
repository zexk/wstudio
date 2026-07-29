//! VST3 component loader and realtime-safe mono/stereo audio adapter.

const std = @import("std");
const abi = @import("abi.zig");
const module_mod = @import("module.zig");
const scan = @import("scan.zig");
const device_mod = @import("../dsp/device.zig");
const types = @import("../core/types.zig");

pub const Vst3Plugin = struct {
    allocator: std.mem.Allocator,
    module: module_mod.Module,
    component: *abi.Component,
    processor: *abi.AudioProcessor,
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
        var data: abi.ProcessData = .{
            .process_mode = 0,
            .symbolic_sample_size = 0,
            .num_samples = @intCast(frames),
            .num_inputs = if (self.input_channels == 0) 0 else 1,
            .num_outputs = 1,
            .inputs = if (self.input_channels == 0) null else @ptrCast(&input),
            .outputs = @ptrCast(&output),
            .input_parameter_changes = null,
            .output_parameter_changes = null,
            .input_events = null,
            .output_events = null,
            .process_context = null,
        };
        if (self.processor.vtable.process(self.processor, &data) != 0) return;
        for (0..frames) |frame| {
            buf[frame * 2] = self.output_left[frame];
            buf[frame * 2 + 1] = if (self.output_channels == 1) self.output_left[frame] else self.output_right[frame];
        }
    }

    pub fn reset(_: *Vst3Plugin) void {}
    pub fn latencySamples(self: *const Vst3Plugin) u32 {
        return self.processor.vtable.get_latency_samples(self.processor);
    }
};

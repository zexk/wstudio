//! Native CLAP plugin loader and realtime-safe stereo processing adapter.

const std = @import("std");
const abi = @import("abi.zig");
const device_mod = @import("../dsp/device.zig");
const types = @import("../core/types.zig");

const max_events = 256;

fn discardOutputEvent(_: ?*const abi.OutputEvents, _: *const abi.EventHeader) callconv(.c) bool {
    return false;
}

const discard_output_events: abi.OutputEvents = .{
    .ctx = null,
    .try_push = discardOutputEvent,
};

const StoredEvent = union(enum) {
    note: abi.EventNote,
    midi: abi.EventMidi,

    fn header(self: *const StoredEvent) *const abi.EventHeader {
        return switch (self.*) {
            .note => |*event| &event.header,
            .midi => |*event| &event.header,
        };
    }
};

const EventList = struct {
    interface: abi.InputEvents,
    events: [max_events]StoredEvent = undefined,
    len: u32 = 0,

    fn init() EventList {
        return .{
            .interface = .{
                .ctx = null,
                .size = size,
                .get = get,
            },
        };
    }

    fn bind(self: *EventList) void {
        self.interface.ctx = self;
    }

    fn size(list: ?*const abi.InputEvents) callconv(.c) u32 {
        const self: *const EventList = @ptrCast(@alignCast(list.?.ctx.?));
        return self.len;
    }

    fn get(list: ?*const abi.InputEvents, index: u32) callconv(.c) ?*const abi.EventHeader {
        const self: *const EventList = @ptrCast(@alignCast(list.?.ctx.?));
        if (index >= self.len) return null;
        return self.events[index].header();
    }

    fn push(self: *EventList, event: StoredEvent) void {
        if (self.len == max_events) return;
        self.events[self.len] = event;
        self.len += 1;
    }
};

const HostContext = struct {
    host: abi.Host,
    restart_requested: std.atomic.Value(bool) = .init(false),
    process_requested: std.atomic.Value(bool) = .init(false),
    callback_requested: std.atomic.Value(bool) = .init(false),

    fn init() HostContext {
        return .{
            .host = .{
                .clap_version = abi.version,
                .host_data = null,
                .name = "wstudio",
                .vendor = "wstudio",
                .url = "https://github.com/",
                .host_version = "0.1",
                .get_extension = getExtension,
                .request_restart = requestRestart,
                .request_process = requestProcess,
                .request_callback = requestCallback,
            },
        };
    }

    fn bind(self: *HostContext) void {
        self.host.host_data = self;
    }

    fn fromHost(host: *const abi.Host) *HostContext {
        return @ptrCast(@alignCast(host.host_data.?));
    }

    fn getExtension(_: *const abi.Host, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
        return null;
    }

    fn requestRestart(host: *const abi.Host) callconv(.c) void {
        fromHost(host).restart_requested.store(true, .release);
    }

    fn requestProcess(host: *const abi.Host) callconv(.c) void {
        fromHost(host).process_requested.store(true, .release);
    }

    fn requestCallback(host: *const abi.Host) callconv(.c) void {
        fromHost(host).callback_requested.store(true, .release);
    }
};

pub const ClapPlugin = struct {
    allocator: std.mem.Allocator,
    library: std.DynLib,
    entry: *const abi.PluginEntry,
    plugin: *const abi.Plugin,
    host_context: *HostContext,
    path_z: [:0]u8,
    input_left: []f32,
    input_right: []f32,
    output_left: []f32,
    output_right: []f32,
    input_channel_ptrs: [2]?[*]f32 = .{ null, null },
    output_channel_ptrs: [2]?[*]f32 = .{ null, null },
    events: EventList = EventList.init(),
    audio_inputs_count: u32,
    steady_time: i64 = 0,
    started: bool = false,

    pub const device = device_mod.deviceOf(@This());

    pub fn load(
        allocator: std.mem.Allocator,
        path: []const u8,
        plugin_id: ?[]const u8,
        sample_rate: u32,
    ) !*ClapPlugin {
        var library = try std.DynLib.open(path);
        errdefer library.close();
        const entry = library.lookup(*const abi.PluginEntry, "clap_entry") orelse return error.MissingClapEntry;
        if (!abi.versionIsCompatible(entry.clap_version)) return error.IncompatibleClapVersion;

        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);
        if (!entry.init(path_z.ptr)) return error.EntryInitFailed;
        errdefer entry.deinit();

        const factory_raw = entry.get_factory(abi.plugin_factory_id) orelse return error.MissingPluginFactory;
        const factory: *const abi.PluginFactory = @ptrCast(@alignCast(factory_raw));
        const id = try selectPluginId(allocator, factory, plugin_id);
        defer allocator.free(id);

        const host_context = try allocator.create(HostContext);
        errdefer allocator.destroy(host_context);
        host_context.* = HostContext.init();
        host_context.bind();

        const plugin = factory.create_plugin(factory, &host_context.host, id.ptr) orelse
            return error.PluginCreateFailed;
        errdefer plugin.destroy(plugin);
        if (!abi.versionIsCompatible(plugin.desc.clap_version)) return error.IncompatibleClapVersion;
        if (!plugin.init(plugin)) return error.PluginInitFailed;
        const audio_inputs_count = try validateAudioPorts(plugin);
        if (!plugin.activate(plugin, @floatFromInt(sample_rate), 1, types.max_block_frames))
            return error.PluginActivateFailed;
        errdefer plugin.deactivate(plugin);

        const self = try allocator.create(ClapPlugin);
        errdefer allocator.destroy(self);
        const input_left = try allocator.alloc(f32, types.max_block_frames);
        errdefer allocator.free(input_left);
        const input_right = try allocator.alloc(f32, types.max_block_frames);
        errdefer allocator.free(input_right);
        const output_left = try allocator.alloc(f32, types.max_block_frames);
        errdefer allocator.free(output_left);
        const output_right = try allocator.alloc(f32, types.max_block_frames);
        errdefer allocator.free(output_right);
        self.* = .{
            .allocator = allocator,
            .library = library,
            .entry = entry,
            .plugin = plugin,
            .host_context = host_context,
            .path_z = path_z,
            .input_left = input_left,
            .input_right = input_right,
            .output_left = output_left,
            .output_right = output_right,
            .audio_inputs_count = audio_inputs_count,
        };
        self.events.bind();
        return self;
    }

    fn validateAudioPorts(plugin: *const abi.Plugin) !u32 {
        const raw = plugin.get_extension(plugin, abi.ext_audio_ports) orelse
            return error.MissingAudioPorts;
        const ports: *const abi.PluginAudioPorts = @ptrCast(@alignCast(raw));
        const input_count = ports.count(plugin, true);
        const output_count = ports.count(plugin, false);
        if (input_count > 1 or output_count != 1) return error.UnsupportedAudioPortLayout;

        if (input_count == 1) {
            var input_info: abi.AudioPortInfo = undefined;
            if (!ports.get(plugin, 0, true, &input_info) or input_info.channel_count != 2)
                return error.UnsupportedAudioPortLayout;
        }
        var output_info: abi.AudioPortInfo = undefined;
        if (!ports.get(plugin, 0, false, &output_info) or output_info.channel_count != 2)
            return error.UnsupportedAudioPortLayout;
        return input_count;
    }

    fn selectPluginId(
        allocator: std.mem.Allocator,
        factory: *const abi.PluginFactory,
        requested: ?[]const u8,
    ) ![:0]u8 {
        const count = factory.get_plugin_count(factory);
        if (count == 0) return error.NoPlugins;
        if (requested) |wanted| {
            for (0..count) |index| {
                const desc = factory.get_plugin_descriptor(factory, @intCast(index)) orelse continue;
                if (std.mem.eql(u8, std.mem.span(desc.id), wanted))
                    return allocator.dupeZ(u8, wanted);
            }
            return error.PluginNotFound;
        }
        const desc = factory.get_plugin_descriptor(factory, 0) orelse return error.InvalidPluginDescriptor;
        return allocator.dupeZ(u8, std.mem.span(desc.id));
    }

    pub fn deinit(self: *ClapPlugin) void {
        if (self.started) self.plugin.stop_processing(self.plugin);
        self.plugin.deactivate(self.plugin);
        self.plugin.destroy(self.plugin);
        self.entry.deinit();
        self.library.close();
        self.allocator.free(self.input_left);
        self.allocator.free(self.input_right);
        self.allocator.free(self.output_left);
        self.allocator.free(self.output_right);
        self.allocator.free(self.path_z);
        self.allocator.destroy(self.host_context);
        self.allocator.destroy(self);
    }

    pub fn processBlock(self: *ClapPlugin, buf: []types.Sample) void {
        const frames = buf.len / 2;
        if (frames == 0 or frames > types.max_block_frames or buf.len % 2 != 0) return;
        if (!self.started) {
            self.started = self.plugin.start_processing(self.plugin);
            if (!self.started) return;
        }

        for (0..frames) |frame| {
            self.input_left[frame] = buf[frame * 2];
            self.input_right[frame] = buf[frame * 2 + 1];
            self.output_left[frame] = 0;
            self.output_right[frame] = 0;
        }
        self.input_channel_ptrs = .{ self.input_left.ptr, self.input_right.ptr };
        self.output_channel_ptrs = .{ self.output_left.ptr, self.output_right.ptr };
        var input_audio = abi.AudioBuffer{
            .data32 = &self.input_channel_ptrs,
            .data64 = null,
            .channel_count = 2,
            .latency = 0,
            .constant_mask = 0,
        };
        var output_audio = abi.AudioBuffer{
            .data32 = &self.output_channel_ptrs,
            .data64 = null,
            .channel_count = 2,
            .latency = 0,
            .constant_mask = 0,
        };
        var process = abi.Process{
            .steady_time = self.steady_time,
            .frames_count = @intCast(frames),
            .transport = null,
            .audio_inputs = if (self.audio_inputs_count == 1) @ptrCast(&input_audio) else null,
            .audio_outputs = @ptrCast(&output_audio),
            .audio_inputs_count = self.audio_inputs_count,
            .audio_outputs_count = 1,
            .in_events = &self.events.interface,
            .out_events = &discard_output_events,
        };
        const status = self.plugin.process(self.plugin, &process);
        self.events.len = 0;
        self.steady_time += @intCast(frames);
        if (status == 0) return;
        for (0..frames) |frame| {
            buf[frame * 2] = self.output_left[frame];
            buf[frame * 2 + 1] = self.output_right[frame];
        }
    }

    pub fn handleEvent(self: *ClapPlugin, event: device_mod.Event) void {
        switch (event) {
            .note_on => |note| self.pushNote(abi.event_note_on, note.note, note.velocity),
            .note_off => |note| self.pushNote(abi.event_note_off, note.note, 0),
            .all_off => self.pushNote(abi.event_note_choke, null, 0),
            .cc => |cc| self.pushMidi(.{ 0xb0, cc.cc, cc.value }),
            .pitch_bend => |bend| {
                const value: u14 = @intCast(@as(i32, bend.bend) + 8192);
                self.pushMidi(.{ 0xe0, @truncate(value), @truncate(value >> 7) });
            },
            else => {},
        }
    }

    fn pushNote(self: *ClapPlugin, event_type: u16, key: ?u7, velocity: f32) void {
        self.events.push(.{ .note = .{
            .header = .{
                .size = @sizeOf(abi.EventNote),
                .time = 0,
                .space_id = abi.core_event_space_id,
                .event_type = event_type,
                .flags = 0,
            },
            .note_id = -1,
            .port_index = if (key == null) -1 else 0,
            .channel = if (key == null) -1 else 0,
            .key = if (key) |value| value else -1,
            .velocity = velocity,
        } });
    }

    fn pushMidi(self: *ClapPlugin, data: [3]u8) void {
        self.events.push(.{ .midi = .{
            .header = .{
                .size = @sizeOf(abi.EventMidi),
                .time = 0,
                .space_id = abi.core_event_space_id,
                .event_type = abi.event_midi,
                .flags = 0,
            },
            .port_index = 0,
            .data = data,
        } });
    }

    pub fn reset(self: *ClapPlugin) void {
        self.events.len = 0;
        if (self.started) self.plugin.reset(self.plugin);
    }
};

test "CLAP event list preserves event order and ABI headers" {
    var list = EventList.init();
    list.bind();
    list.push(.{ .midi = .{
        .header = .{
            .size = @sizeOf(abi.EventMidi),
            .time = 4,
            .space_id = abi.core_event_space_id,
            .event_type = abi.event_midi,
            .flags = 0,
        },
        .port_index = 0,
        .data = .{ 0xb0, 1, 64 },
    } });
    try std.testing.expectEqual(@as(u32, 1), list.interface.size(&list.interface));
    const header = list.interface.get(&list.interface, 0).?;
    try std.testing.expectEqual(abi.event_midi, header.event_type);
    try std.testing.expectEqual(@as(u32, 4), header.time);
    try std.testing.expect(list.interface.get(&list.interface, 1) == null);
}

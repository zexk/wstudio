//! Native CLAP plugin loader and realtime-safe stereo processing adapter.

const std = @import("std");
const abi = @import("abi.zig");
const device_mod = @import("../dsp/device.zig");
const types = @import("../core/types.zig");
const Transport = @import("../transport.zig").Transport;
const dynlib_compat = @import("dynlib_compat.zig");
const open_entry = @import("open_entry.zig");

const max_events = 256;

threadlocal var on_audio_thread = false;

const NoteDialect = enum { none, clap, midi };

/// Looks up CLAP extension `ext_id` on `plugin` and casts it to `*const T`,
/// or null if the plugin doesn't implement it - shared by every extension
/// query below, which otherwise each repeat the same
/// get_extension+ptrCast+alignCast pair (the only place any of them cast
/// the raw `?*const anyopaque`).
fn getExt(comptime T: type, plugin: *const abi.Plugin, ext_id: [*:0]const u8) ?*const T {
    const raw = plugin.get_extension(plugin, ext_id) orelse return null;
    return @ptrCast(@alignCast(raw));
}

const StoredEvent = union(enum) {
    note: abi.EventNote,
    midi: abi.EventMidi,
    param: abi.EventParamValue,

    fn header(self: *const StoredEvent) *const abi.EventHeader {
        return switch (self.*) {
            .note => |*event| &event.header,
            .midi => |*event| &event.header,
            .param => |*event| &event.header,
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
    param_flush_requested: std.atomic.Value(bool) = .init(false),
    param_rescan_flags: std.atomic.Value(u32) = .init(0),
    state_dirty: std.atomic.Value(bool) = .init(false),
    latency_changed: std.atomic.Value(bool) = .init(false),
    tail_changed: std.atomic.Value(bool) = .init(false),
    main_thread_id: std.Thread.Id,

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
            .main_thread_id = std.Thread.getCurrentId(),
        };
    }

    fn bind(self: *HostContext) void {
        self.host.host_data = self;
    }

    fn fromHost(host: *const abi.Host) *HostContext {
        return @ptrCast(@alignCast(host.host_data.?));
    }

    fn getExtension(_: *const abi.Host, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
        const name = std.mem.span(id);
        if (std.mem.eql(u8, name, std.mem.span(abi.ext_params))) return &host_params;
        if (std.mem.eql(u8, name, std.mem.span(abi.ext_state))) return &host_state;
        if (std.mem.eql(u8, name, std.mem.span(abi.ext_latency))) return &host_latency;
        if (std.mem.eql(u8, name, std.mem.span(abi.ext_tail))) return &host_tail;
        if (std.mem.eql(u8, name, std.mem.span(abi.ext_thread_check))) return &host_thread_check;
        if (std.mem.eql(u8, name, std.mem.span(abi.ext_log))) return &host_log;
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

    fn paramsRescan(host: *const abi.Host, flags: u32) callconv(.c) void {
        _ = fromHost(host).param_rescan_flags.fetchOr(flags, .release);
    }

    fn paramsClear(_: *const abi.Host, _: u32, _: u32) callconv(.c) void {}

    fn paramsRequestFlush(host: *const abi.Host) callconv(.c) void {
        fromHost(host).param_flush_requested.store(true, .release);
    }

    fn stateMarkDirty(host: *const abi.Host) callconv(.c) void {
        fromHost(host).state_dirty.store(true, .release);
    }

    fn latencyChanged(host: *const abi.Host) callconv(.c) void {
        fromHost(host).latency_changed.store(true, .release);
    }

    fn tailChanged(host: *const abi.Host) callconv(.c) void {
        fromHost(host).tail_changed.store(true, .release);
    }

    fn isMainThread(host: *const abi.Host) callconv(.c) bool {
        return fromHost(host).main_thread_id == std.Thread.getCurrentId();
    }

    fn isAudioThread(_: *const abi.Host) callconv(.c) bool {
        return on_audio_thread;
    }

    fn log(_: *const abi.Host, severity: i32, message: [*:0]const u8) callconv(.c) void {
        const text = std.mem.span(message);
        switch (severity) {
            0, 1 => std.log.info("CLAP: {s}", .{text}),
            2 => std.log.warn("CLAP: {s}", .{text}),
            else => std.log.err("CLAP: {s}", .{text}),
        }
    }

    const host_params: abi.HostParams = .{
        .rescan = paramsRescan,
        .clear = paramsClear,
        .request_flush = paramsRequestFlush,
    };
    const host_state: abi.HostState = .{ .mark_dirty = stateMarkDirty };
    const host_latency: abi.HostLatency = .{ .changed = latencyChanged };
    const host_tail: abi.HostTail = .{ .changed = tailChanged };
    const host_thread_check: abi.HostThreadCheck = .{
        .is_main_thread = isMainThread,
        .is_audio_thread = isAudioThread,
    };
    const host_log: abi.HostLog = .{ .log = log };
};

fn acceptOutputEvent(list: ?*const abi.OutputEvents, event: *const abi.EventHeader) callconv(.c) bool {
    const context: *HostContext = @ptrCast(@alignCast(list.?.ctx.?));
    if (event.space_id != abi.core_event_space_id or event.event_type != abi.event_param_value)
        return false;
    context.state_dirty.store(true, .release);
    return true;
}

pub const ClapPlugin = struct {
    allocator: std.mem.Allocator,
    library: dynlib_compat.DynLib,
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
    output_events: abi.OutputEvents,
    audio_inputs_count: u32,
    note_dialect: NoteDialect,
    supports_midi: bool,
    transport: ?*const Transport = null,
    steady_time: i64 = 0,
    started: bool = false,

    pub const device = device_mod.deviceOf(@This());

    pub fn load(
        allocator: std.mem.Allocator,
        path: []const u8,
        plugin_id: ?[]const u8,
        sample_rate: u32,
    ) !*ClapPlugin {
        const opened = try open_entry.openEntry(allocator, path);
        var library = opened.library;
        errdefer library.close();
        const entry = opened.entry;
        const path_z = opened.path_z;
        errdefer allocator.free(path_z);
        errdefer entry.deinit();

        const factory_raw = entry.get_factory(abi.plugin_factory_id) orelse return error.MissingPluginFactory;
        const factory: *const abi.PluginFactory = @ptrCast(@alignCast(factory_raw));
        const selected_id = try selectPluginId(allocator, factory, plugin_id);
        defer allocator.free(selected_id);

        const host_context = try allocator.create(HostContext);
        errdefer allocator.destroy(host_context);
        host_context.* = HostContext.init();
        host_context.bind();

        const plugin = factory.create_plugin(factory, &host_context.host, selected_id.ptr) orelse
            return error.PluginCreateFailed;
        errdefer plugin.destroy(plugin);
        if (!abi.versionIsCompatible(plugin.desc.clap_version)) return error.IncompatibleClapVersion;
        if (!plugin.init(plugin)) return error.PluginInitFailed;
        const audio_inputs_count = try validateAudioPorts(plugin);
        const note_support = detectNoteSupport(plugin);
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
            .note_dialect = note_support.dialect,
            .supports_midi = note_support.supports_midi,
            .output_events = .{ .ctx = host_context, .try_push = acceptOutputEvent },
        };
        self.events.bind();
        return self;
    }

    fn validateAudioPorts(plugin: *const abi.Plugin) !u32 {
        const ports = getExt(abi.PluginAudioPorts, plugin, abi.ext_audio_ports) orelse
            return error.MissingAudioPorts;
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

    fn detectNoteSupport(plugin: *const abi.Plugin) struct {
        dialect: NoteDialect,
        supports_midi: bool,
    } {
        const ports = getExt(abi.PluginNotePorts, plugin, abi.ext_note_ports) orelse
            return .{ .dialect = .none, .supports_midi = false };
        if (ports.count(plugin, true) == 0) return .{ .dialect = .none, .supports_midi = false };
        var info: abi.NotePortInfo = undefined;
        if (!ports.get(plugin, 0, true, &info)) return .{ .dialect = .none, .supports_midi = false };
        const supports_clap = info.supported_dialects & abi.note_dialect_clap != 0;
        const supports_midi = info.supported_dialects & abi.note_dialect_midi != 0;
        const dialect: NoteDialect = if (info.preferred_dialect == abi.note_dialect_midi and supports_midi)
            .midi
        else if (supports_clap)
            .clap
        else if (supports_midi)
            .midi
        else
            .none;
        return .{ .dialect = dialect, .supports_midi = supports_midi };
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
        var transport_event: abi.EventTransport = undefined;
        const transport_ptr: ?*const anyopaque = if (self.transport) |transport| blk: {
            transport_event = makeTransportEvent(transport);
            break :blk &transport_event;
        } else null;
        var process = abi.Process{
            .steady_time = self.steady_time,
            .frames_count = @intCast(frames),
            .transport = transport_ptr,
            .audio_inputs = if (self.audio_inputs_count == 1) @ptrCast(&input_audio) else null,
            .audio_outputs = @ptrCast(&output_audio),
            .audio_inputs_count = self.audio_inputs_count,
            .audio_outputs_count = 1,
            .in_events = &self.events.interface,
            .out_events = &self.output_events,
        };
        on_audio_thread = true;
        defer on_audio_thread = false;
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
            .note_on => |note| switch (self.note_dialect) {
                .clap => self.pushNote(abi.event_note_on, note.note, note.velocity),
                .midi => self.pushMidi(.{ 0x90, note.note, @intFromFloat(std.math.clamp(note.velocity, 0, 1) * 127) }),
                .none => {},
            },
            .note_off => |note| switch (self.note_dialect) {
                .clap => self.pushNote(abi.event_note_off, note.note, 0),
                .midi => self.pushMidi(.{ 0x80, note.note, 0 }),
                .none => {},
            },
            .all_off => switch (self.note_dialect) {
                .clap => self.pushNote(abi.event_note_choke, null, 0),
                .midi => self.pushMidi(.{ 0xb0, 123, 0 }),
                .none => {},
            },
            .cc => |cc| if (self.supports_midi) self.pushMidi(.{ 0xb0, cc.cc, cc.value }),
            .pitch_bend => |bend| {
                if (!self.supports_midi) return;
                const value: u14 = @intCast(@as(i32, bend.bend) + 8192);
                self.pushMidi(.{ 0xe0, @truncate(value), @truncate(value >> 7) });
            },
            .clap_param => |param| {
                if (param.target == @as(*anyopaque, @ptrCast(self)))
                    self.pushParameter(param.id, param.cookie, param.value);
            },
            else => {},
        }
    }

    /// Builds a `size`-sized, now-timed CLAP core-space event header for
    /// `event_type` - shared by pushNote/pushMidi/pushParameter, which
    /// otherwise each repeat the same 5-field literal.
    fn eventHeader(size: u32, event_type: u16) abi.EventHeader {
        return .{
            .size = size,
            .time = 0,
            .space_id = abi.core_event_space_id,
            .event_type = event_type,
            .flags = 0,
        };
    }

    fn pushNote(self: *ClapPlugin, event_type: u16, key: ?u7, velocity: f32) void {
        self.events.push(.{ .note = .{
            .header = eventHeader(@sizeOf(abi.EventNote), event_type),
            .note_id = -1,
            .port_index = if (key == null) -1 else 0,
            .channel = if (key == null) -1 else 0,
            .key = if (key) |value| value else -1,
            .velocity = velocity,
        } });
    }

    fn pushMidi(self: *ClapPlugin, data: [3]u8) void {
        self.events.push(.{ .midi = .{
            .header = eventHeader(@sizeOf(abi.EventMidi), abi.event_midi),
            .port_index = 0,
            .data = data,
        } });
    }

    pub fn pluginPath(self: *const ClapPlugin) []const u8 {
        return self.path_z;
    }

    pub fn attachTransport(self: *ClapPlugin, transport: *const Transport) void {
        self.transport = transport;
    }

    pub fn id(self: *const ClapPlugin) []const u8 {
        return std.mem.span(self.plugin.desc.id);
    }

    pub fn name(self: *const ClapPlugin) []const u8 {
        return std.mem.span(self.plugin.desc.name);
    }

    fn paramsExtension(self: *const ClapPlugin) ?*const abi.PluginParams {
        return getExt(abi.PluginParams, self.plugin, abi.ext_params);
    }

    pub fn parameterCount(self: *const ClapPlugin) u32 {
        const params = self.paramsExtension() orelse return 0;
        return params.count(self.plugin);
    }

    pub fn parameterInfo(self: *const ClapPlugin, index: u32) ?abi.ParamInfo {
        const params = self.paramsExtension() orelse return null;
        var info: abi.ParamInfo = undefined;
        if (!params.get_info(self.plugin, index, &info)) return null;
        return info;
    }

    pub fn parameterName(self: *const ClapPlugin, index: u32, buffer: []u8) ?[]const u8 {
        const info = self.parameterInfo(index) orelse return null;
        const param_name = std.mem.sliceTo(&info.name, 0);
        if (param_name.len == 0 or buffer.len == 0) return null;
        const len = @min(param_name.len, buffer.len);
        @memcpy(buffer[0..len], param_name[0..len]);
        return buffer[0..len];
    }

    pub fn parameterValue(self: *const ClapPlugin, id_value: u32) ?f64 {
        const params = self.paramsExtension() orelse return null;
        var value: f64 = undefined;
        if (!params.get_value(self.plugin, id_value, &value)) return null;
        return value;
    }

    pub fn formatParameter(
        self: *const ClapPlugin,
        id_value: u32,
        value: f64,
        buffer: []u8,
    ) ?[]const u8 {
        if (buffer.len == 0) return null;
        const params = self.paramsExtension() orelse return null;
        if (!params.value_to_text(self.plugin, id_value, value, buffer.ptr, @intCast(buffer.len)))
            return null;
        return std.mem.sliceTo(buffer, 0);
    }

    /// Queue a parameter edit for the next audio block. The caller must use
    /// the engine command queue when it runs concurrently with audio.
    pub fn setParameter(self: *ClapPlugin, id_value: u32, cookie: ?*anyopaque, value: f64) void {
        self.pushParameter(id_value, cookie, value);
    }

    fn pushParameter(self: *ClapPlugin, id_value: u32, cookie: ?*anyopaque, value: f64) void {
        self.events.push(.{ .param = .{
            .header = eventHeader(@sizeOf(abi.EventParamValue), abi.event_param_value),
            .param_id = id_value,
            .cookie = cookie,
            .note_id = -1,
            .port_index = -1,
            .channel = -1,
            .key = -1,
            .value = value,
        } });
        self.host_context.state_dirty.store(true, .release);
    }

    pub fn saveState(self: *ClapPlugin, allocator: std.mem.Allocator) !?[]u8 {
        const state = getExt(abi.PluginState, self.plugin, abi.ext_state) orelse return null;
        var writer = StateWriter{ .allocator = allocator };
        errdefer writer.bytes.deinit(allocator);
        var stream = abi.OutputStream{ .ctx = &writer, .write = StateWriter.write };
        if (!state.save(self.plugin, &stream) or writer.failed) return error.PluginStateSaveFailed;
        return try writer.bytes.toOwnedSlice(allocator);
    }

    pub fn loadState(self: *ClapPlugin, bytes: []const u8) !bool {
        const state = getExt(abi.PluginState, self.plugin, abi.ext_state) orelse return false;
        var reader = StateReader{ .bytes = bytes };
        var stream = abi.InputStream{ .ctx = &reader, .read = StateReader.read };
        if (!state.load(self.plugin, &stream)) return error.PluginStateLoadFailed;
        self.host_context.state_dirty.store(false, .release);
        return true;
    }

    pub fn latencyFrames(self: *const ClapPlugin) u32 {
        const latency = getExt(abi.PluginLatency, self.plugin, abi.ext_latency) orelse return 0;
        return latency.get(self.plugin);
    }

    pub fn tailFrames(self: *const ClapPlugin) ?u32 {
        const tail = getExt(abi.PluginTail, self.plugin, abi.ext_tail) orelse return null;
        return tail.get(self.plugin);
    }

    pub fn reset(self: *ClapPlugin) void {
        self.events.len = 0;
        if (self.started) self.plugin.reset(self.plugin);
    }
};

const StateWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    failed: bool = false,

    fn write(stream: *const abi.OutputStream, data: *const anyopaque, size: u64) callconv(.c) i64 {
        const self: *StateWriter = @ptrCast(@alignCast(stream.ctx));
        const len = std.math.cast(usize, size) orelse {
            self.failed = true;
            return -1;
        };
        const source: [*]const u8 = @ptrCast(data);
        self.bytes.appendSlice(self.allocator, source[0..len]) catch {
            self.failed = true;
            return -1;
        };
        return @intCast(len);
    }
};

const StateReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn read(stream: *const abi.InputStream, dest: *anyopaque, size: u64) callconv(.c) i64 {
        const self: *StateReader = @ptrCast(@alignCast(stream.ctx));
        const requested = std.math.cast(usize, size) orelse return -1;
        const len = @min(requested, self.bytes.len - self.offset);
        const output: [*]u8 = @ptrCast(dest);
        @memcpy(output[0..len], self.bytes[self.offset..][0..len]);
        self.offset += len;
        return @intCast(len);
    }
};

fn fixedTime(value: f64) i64 {
    const scaled = value * 2_147_483_648.0;
    if (!std.math.isFinite(scaled)) return 0;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    if (scaled <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
    return @intFromFloat(scaled);
}

fn makeTransportEvent(transport: *const Transport) abi.EventTransport {
    const sample_rate = @as(f64, @floatFromInt(@max(transport.sample_rate, 1)));
    const frames_per_beat = transport.framesPerBeat();
    const song_beats = transport.positionBeats();
    const beats_per_bar = @as(f64, @floatFromInt(@max(transport.time_signature.beats_per_bar, 1)));
    var flags = abi.transport_has_tempo |
        abi.transport_has_beats_timeline |
        abi.transport_has_seconds_timeline |
        abi.transport_has_time_signature;
    if (transport.playing) flags |= abi.transport_is_playing;
    if (transport.loop_enabled and transport.loop_end_frames > transport.loop_start_frames)
        flags |= abi.transport_is_loop_active;
    const loop_start_beats = @as(f64, @floatFromInt(transport.loop_start_frames)) / frames_per_beat;
    const loop_end_beats = @as(f64, @floatFromInt(transport.loop_end_frames)) / frames_per_beat;
    const bar_number_f = @floor(song_beats / beats_per_bar);
    const bar_number: i32 = if (bar_number_f >= @as(f64, @floatFromInt(std.math.maxInt(i32))))
        std.math.maxInt(i32)
    else
        @intFromFloat(@max(bar_number_f, 0));
    return .{
        .header = .{
            .size = @sizeOf(abi.EventTransport),
            .time = 0,
            .space_id = abi.core_event_space_id,
            .event_type = abi.event_transport,
            .flags = 0,
        },
        .flags = flags,
        .song_pos_beats = fixedTime(song_beats),
        .song_pos_seconds = fixedTime(transport.positionSeconds()),
        .tempo = transport.tempo_bpm,
        .tempo_inc = 0,
        .loop_start_beats = fixedTime(loop_start_beats),
        .loop_end_beats = fixedTime(loop_end_beats),
        .loop_start_seconds = fixedTime(@as(f64, @floatFromInt(transport.loop_start_frames)) / sample_rate),
        .loop_end_seconds = fixedTime(@as(f64, @floatFromInt(transport.loop_end_frames)) / sample_rate),
        .bar_start = fixedTime(@as(f64, @floatFromInt(bar_number)) * beats_per_bar),
        .bar_number = bar_number,
        .tsig_num = transport.time_signature.beats_per_bar,
        .tsig_denom = transport.time_signature.beat_unit,
    };
}

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

test "CLAP transport carries musical position loop and play state" {
    var transport = Transport{
        .sample_rate = 48_000,
        .tempo_bpm = 120,
        .playing = true,
        .loop_enabled = true,
        .loop_start_frames = 48_000,
        .loop_end_frames = 96_000,
        .position_frames = 72_000,
    };
    transport.time_signature.beats_per_bar = 3;
    const event = makeTransportEvent(&transport);
    try std.testing.expect(event.flags & abi.transport_is_playing != 0);
    try std.testing.expect(event.flags & abi.transport_is_loop_active != 0);
    try std.testing.expectApproxEqAbs(@as(f64, 3), @as(f64, @floatFromInt(event.song_pos_beats)) / 2_147_483_648.0, 1e-9);
    try std.testing.expectEqual(@as(u16, 3), event.tsig_num);
    try std.testing.expectEqual(@as(u16, 4), event.tsig_denom);
    try std.testing.expectEqual(@as(i32, 1), event.bar_number);
}

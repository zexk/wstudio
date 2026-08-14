//! Native CLAP plugin loader and realtime-safe stereo processing adapter.

const std = @import("std");
const abi = @import("abi.zig");
const device_mod = @import("../dsp/device.zig");
const types = @import("../core/types.zig");
const Transport = @import("../transport.zig").Transport;
const dynlib_compat = @import("dynlib_compat.zig");
const open_entry = @import("open_entry.zig");
const bridge_mod = @import("../plugin_host/bridge.zig");
const wire = @import("../plugin_host/transport.zig");
const editor_window = @import("../plugin_host/editor_window.zig");

const max_events = 256;
const max_parameters = 256;
const max_timers = 16;
const max_thread_pool_workers = 4;

threadlocal var on_audio_thread = false;
threadlocal var on_thread_pool = false;

const NoteDialect = enum { none, clap, midi };

/// What the plugin declares, not what this host would prefer: any number
/// of ports with any channel counts. Host audio only ever travels on port 0
/// in each direction (mono inputs downmix host stereo, mono outputs
/// duplicate); the rest exist so sidechains and multi-out plugins load and
/// process at all.
const AudioPortLayout = struct {
    input_count: u32,
    output_count: u32,
    input_channels: u32,
    output_channels: u32,
};

/// Process buffers for every audio port a CLAP plugin declares.
///
/// `clap_process` carries one `AudioBuffer` per port, and plugins index
/// `audio_outputs[port]` across their own port count - so the ports this
/// host does not exchange audio on still need real channel pointers. Port 0
/// in each direction carries host audio; the others read silence and have
/// their output discarded. Same reasoning as `BusBuffers` in src/vst3/plugin.zig.
const PortBuffers = struct {
    inputs: []abi.AudioBuffer,
    outputs: []abi.AudioBuffer,
    channel_ptrs: []?[*]f32,
    pool: []f32,
    /// Index into `channel_ptrs` of the main output port's first channel.
    /// The main input port is port 0, so its first channel is index 0.
    main_output_channel: usize,

    fn init(allocator: std.mem.Allocator, plugin: *const abi.Plugin, input_count: usize, output_count: usize) !PortBuffers {
        const inputs = try allocator.alloc(abi.AudioBuffer, input_count);
        errdefer allocator.free(inputs);
        const outputs = try allocator.alloc(abi.AudioBuffer, output_count);
        errdefer allocator.free(outputs);

        var total: usize = 0;
        for (inputs, 0..) |*port, index| {
            port.* = .{ .data32 = null, .data64 = null, .channel_count = portChannelCount(plugin, index, true), .latency = 0, .constant_mask = 0 };
            total += port.channel_count;
        }
        const main_output_channel = total;
        for (outputs, 0..) |*port, index| {
            port.* = .{ .data32 = null, .data64 = null, .channel_count = portChannelCount(plugin, index, false), .latency = 0, .constant_mask = 0 };
            total += port.channel_count;
        }

        const pool = try allocator.alloc(f32, @max(total, 1) * types.max_block_frames);
        errdefer allocator.free(pool);
        const channel_ptrs = try allocator.alloc(?[*]f32, @max(total, 1));
        errdefer allocator.free(channel_ptrs);
        for (channel_ptrs, 0..) |*ptr, index| ptr.* = pool[index * types.max_block_frames ..].ptr;

        var next: usize = 0;
        for ([_][]abi.AudioBuffer{ inputs, outputs }) |list| {
            for (list) |*port| {
                port.data32 = channel_ptrs[next..].ptr;
                next += port.channel_count;
            }
        }
        return .{ .inputs = inputs, .outputs = outputs, .channel_ptrs = channel_ptrs, .pool = pool, .main_output_channel = main_output_channel };
    }

    fn deinit(self: *PortBuffers, allocator: std.mem.Allocator) void {
        allocator.free(self.inputs);
        allocator.free(self.outputs);
        allocator.free(self.channel_ptrs);
        allocator.free(self.pool);
    }
};

fn portChannelCount(plugin: *const abi.Plugin, index: usize, is_input: bool) u32 {
    const ports = getExt(abi.PluginAudioPorts, plugin, abi.ext_audio_ports) orelse return 0;
    var info: abi.AudioPortInfo = undefined;
    if (!ports.get(plugin, @intCast(index), is_input, &info)) return 0;
    return info.channel_count;
}

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

const empty_input_events: abi.InputEvents = .{
    .ctx = null,
    .size = emptyEventCount,
    .get = emptyEventAt,
};

fn emptyEventCount(_: ?*const abi.InputEvents) callconv(.c) u32 {
    return 0;
}

fn emptyEventAt(_: ?*const abi.InputEvents, _: u32) callconv(.c) ?*const abi.EventHeader {
    return null;
}

const HostContext = struct {
    const Timer = struct { period_ns: u64, next_ns: u64 };

    host: abi.Host,
    restart_requested: std.atomic.Value(bool) = .init(false),
    process_requested: std.atomic.Value(bool) = .init(false),
    callback_requested: std.atomic.Value(bool) = .init(false),
    param_flush_requested: std.atomic.Value(bool) = .init(false),
    param_rescan_flags: std.atomic.Value(u32) = .init(0),
    state_dirty: std.atomic.Value(bool) = .init(false),
    latency_changed: std.atomic.Value(bool) = .init(false),
    tail_changed: std.atomic.Value(bool) = .init(false),
    gui_show_requested: std.atomic.Value(bool) = .init(false),
    gui_hide_requested: std.atomic.Value(bool) = .init(false),
    gui_closed: std.atomic.Value(u8) = .init(0),
    gui_resize_requested: std.atomic.Value(u64) = .init(0),
    timers: [max_timers]?Timer = .{null} ** max_timers,
    plugin: ?*const abi.Plugin = null,
    plugin_thread_pool: ?*const abi.PluginThreadPool = null,
    main_thread_id: std.Thread.Id,
    workers: [max_thread_pool_workers]?std.Thread = .{null} ** max_thread_pool_workers,
    worker_args: [max_thread_pool_workers]WorkerArg = undefined,
    worker_count: u32 = 0,
    request_worker_count: u32 = 0,
    task_count: u32 = 0,
    work_epoch: std.atomic.Value(u32) = .init(0),
    workers_remaining: std.atomic.Value(u32) = .init(0),
    workers_stopping: std.atomic.Value(bool) = .init(false),

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

    fn startWorkers(self: *HostContext) void {
        for (0..max_thread_pool_workers) |i| {
            self.worker_args[i] = .{ .host = self, .index = @intCast(i) };
            self.workers[i] = std.Thread.spawn(.{}, WorkerArg.run, .{&self.worker_args[i]}) catch break;
            self.worker_count += 1;
        }
    }

    fn stopWorkers(self: *HostContext) void {
        self.workers_stopping.store(true, .release);
        _ = self.work_epoch.fetchAdd(1, .release);
        std.Options.debug_io.futexWake(u32, &self.work_epoch.raw, max_thread_pool_workers);
        for (self.workers) |thread| if (thread) |t| t.join();
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
        if (std.mem.eql(u8, name, std.mem.span(abi.ext_gui))) return &host_gui;
        if (std.mem.eql(u8, name, std.mem.span(abi.ext_thread_pool))) return &host_thread_pool;
        if (std.mem.eql(u8, name, std.mem.span(abi.ext_timer_support))) return &host_timer_support;
        return null;
    }

    fn requestExec(host: *const abi.Host, num_tasks: u32) callconv(.c) bool {
        const self = fromHost(host);
        if (!on_audio_thread or on_thread_pool or num_tasks == 0) return false;
        const plugin = self.plugin orelse return false;
        const pool = self.plugin_thread_pool orelse return false;
        const worker_count = @min(num_tasks, self.worker_count);
        if (worker_count == 0) {
            for (0..num_tasks) |task| pool.exec(plugin, @intCast(task));
            return true;
        }
        self.task_count = num_tasks;
        self.request_worker_count = worker_count;
        self.workers_remaining.store(worker_count, .release);
        _ = self.work_epoch.fetchAdd(1, .release);
        std.Options.debug_io.futexWake(u32, &self.work_epoch.raw, max_thread_pool_workers);
        while (self.workers_remaining.load(.acquire) != 0) {
            const remaining = self.workers_remaining.load(.acquire);
            if (remaining != 0)
                std.Options.debug_io.futexWaitUncancelable(u32, &self.workers_remaining.raw, remaining);
        }
        return true;
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

    fn guiResizeHintsChanged(_: *const abi.Host) callconv(.c) void {}

    fn guiRequestResize(host: *const abi.Host, width: u32, height: u32) callconv(.c) bool {
        if (width == 0 or height == 0) return false;
        fromHost(host).gui_resize_requested.store(@as(u64, width) << 32 | height, .release);
        return true;
    }

    fn guiRequestShow(host: *const abi.Host) callconv(.c) bool {
        fromHost(host).gui_show_requested.store(true, .release);
        return true;
    }

    fn guiRequestHide(host: *const abi.Host) callconv(.c) bool {
        fromHost(host).gui_hide_requested.store(true, .release);
        return true;
    }

    fn guiClosed(host: *const abi.Host, was_destroyed: bool) callconv(.c) void {
        fromHost(host).gui_closed.store(if (was_destroyed) 2 else 1, .release);
    }

    fn registerTimer(host: *const abi.Host, period_ms: u32, timer_id: *u32) callconv(.c) bool {
        if (period_ms == 0) return false;
        const self = fromHost(host);
        for (&self.timers, 0..) |*slot, id| if (slot.* == null) {
            const period_ns = @as(u64, period_ms) * std.time.ns_per_ms;
            slot.* = .{ .period_ns = period_ns, .next_ns = wire.monotonicNs() + period_ns };
            timer_id.* = @intCast(id);
            return true;
        };
        return false;
    }

    fn unregisterTimer(host: *const abi.Host, timer_id: u32) callconv(.c) bool {
        const self = fromHost(host);
        if (timer_id >= self.timers.len or self.timers[timer_id] == null) return false;
        self.timers[timer_id] = null;
        return true;
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
    const host_gui: abi.HostGui = .{
        .resize_hints_changed = guiResizeHintsChanged,
        .request_resize = guiRequestResize,
        .request_show = guiRequestShow,
        .request_hide = guiRequestHide,
        .closed = guiClosed,
    };
    const host_thread_pool: abi.HostThreadPool = .{ .request_exec = requestExec };
    const host_timer_support: abi.HostTimerSupport = .{ .register_timer = registerTimer, .unregister_timer = unregisterTimer };
};

const WorkerArg = struct {
    host: *HostContext,
    index: u32,

    fn run(self: *const WorkerArg) void {
        on_audio_thread = true;
        on_thread_pool = true;
        defer {
            on_thread_pool = false;
            on_audio_thread = false;
        }
        var epoch: u32 = 0;
        while (true) {
            while (self.host.work_epoch.load(.acquire) == epoch)
                std.Options.debug_io.futexWaitUncancelable(u32, &self.host.work_epoch.raw, epoch);
            epoch = self.host.work_epoch.load(.acquire);
            if (self.host.workers_stopping.load(.acquire)) return;
            if (self.index >= self.host.request_worker_count) continue;

            const plugin = self.host.plugin orelse continue;
            const pool = self.host.plugin_thread_pool orelse continue;
            var task = self.index;
            while (task < self.host.task_count) : (task += self.host.request_worker_count)
                pool.exec(plugin, task);
            if (self.host.workers_remaining.fetchSub(1, .acq_rel) == 1)
                std.Options.debug_io.futexWake(u32, &self.host.workers_remaining.raw, 1);
        }
    }
};

fn acceptOutputEvent(list: ?*const abi.OutputEvents, event: *const abi.EventHeader) callconv(.c) bool {
    const context: *HostContext = @ptrCast(@alignCast(list.?.ctx.?));
    if (event.space_id != abi.core_event_space_id or event.event_type != abi.event_param_value)
        return false;
    context.state_dirty.store(true, .release);
    return true;
}

/// Public CLAP plugin handle. Wraps either a real in-process instance
/// (`Direct`, today's implementation, byte-for-byte unchanged internally)
/// or a `*Bridge` handle to a sandboxed child process running that same
/// unmodified `Direct` code (see plugin_host/child_main.zig) - the split
/// exists so a crashing/hanging third-party plugin can't take the whole
/// process down with it. Every method here dispatches on `impl`; callers
/// (rack.zig, session.zig, persist_*.zig, ui/*) never need to know which
/// mode a given instance is in.
pub const ClapPlugin = struct {
    pub const sample_offset_events = true;
    allocator: std.mem.Allocator,
    /// Cached at load time so external readers (`Fx.insertClap`,
    /// `Session.setClapInstrument`) can check it as a plain field, exactly
    /// as before this split - a live CLAP restart can change `Direct`'s own
    /// copy, but nothing re-reads this cache after the initial post-load
    /// check anyway, in either mode.
    audio_inputs_count: u32,
    impl: Impl,
    /// Bridged-mode only: `attachTransport` also stores here (in addition
    /// to `Direct.transport` when direct) since `processBlock` needs it
    /// without an extra branch back into `Impl.direct`.
    transport: ?*const Transport = null,
    /// Bridged-mode only: events queued by `handleEvent`/`setParameter`
    /// between blocks, published to the child on the next `processBlock`
    /// - the parent-process counterpart of `Direct.events`.
    pending_events: [wire.max_events]wire.WireEvent = undefined,
    pending_count: u32 = 0,
    automatable_params: [max_parameters]device_mod.AutomatableParam = undefined,
    automatable_names: [max_parameters][256]u8 = undefined,
    automatable_count: usize = 0,

    const Impl = union(enum) {
        direct: Direct,
        bridged: *bridge_mod.Bridge,
    };

    pub const device = device_mod.deviceOf(@This());

    pub fn load(
        allocator: std.mem.Allocator,
        path: []const u8,
        plugin_id: ?[]const u8,
        sample_rate: u32,
    ) !*ClapPlugin {
        if (bridge_mod.sandboxActive()) return loadBridged(allocator, path, plugin_id, sample_rate);
        return loadDirect(allocator, path, plugin_id, sample_rate);
    }

    fn loadBridged(
        allocator: std.mem.Allocator,
        path: []const u8,
        plugin_id: ?[]const u8,
        sample_rate: u32,
    ) !*ClapPlugin {
        const b = try bridge_mod.Bridge.spawn(allocator, .{
            .kind = .clap,
            .path = path,
            .plugin_id = plugin_id orelse "",
            .sample_rate = sample_rate,
        });
        errdefer b.deinit();
        const self = try allocator.create(ClapPlugin);
        self.* = .{
            .allocator = allocator,
            .audio_inputs_count = b.audio_inputs_count,
            .impl = .{ .bridged = b },
        };
        self.cacheAutomatableParams();
        return self;
    }

    fn loadDirect(
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
        host_context.plugin = plugin;
        host_context.plugin_thread_pool = getExt(abi.PluginThreadPool, plugin, abi.ext_thread_pool);
        if (host_context.plugin_thread_pool != null) host_context.startWorkers();
        errdefer host_context.stopWorkers();
        const audio_layout = try validateAudioPorts(plugin);
        const note_support = detectNoteSupport(plugin);
        if (!plugin.activate(plugin, @floatFromInt(sample_rate), 1, types.max_block_frames))
            return error.PluginActivateFailed;
        errdefer plugin.deactivate(plugin);

        const self = try allocator.create(ClapPlugin);
        errdefer allocator.destroy(self);
        var ports = try PortBuffers.init(allocator, plugin, audio_layout.input_count, audio_layout.output_count);
        errdefer ports.deinit(allocator);
        self.* = .{
            .allocator = allocator,
            .audio_inputs_count = audio_layout.input_count,
            .impl = .{ .direct = .{
                .allocator = allocator,
                .library = library,
                .entry = entry,
                .plugin = plugin,
                .host_context = host_context,
                .path_z = path_z,
                .ports = ports,
                .audio_inputs_count = audio_layout.input_count,
                .input_channels = audio_layout.input_channels,
                .output_channels = audio_layout.output_channels,
                .note_dialect = note_support.dialect,
                .supports_midi = note_support.supports_midi,
                .sample_rate = sample_rate,
                .output_events = .{ .ctx = host_context, .try_push = acceptOutputEvent },
            } },
        };
        self.impl.direct.events.bind();
        self.cacheAutomatableParams();
        return self;
    }

    fn cacheAutomatableParams(self: *ClapPlugin) void {
        const count = @min(self.parameterCount(), max_parameters);
        for (0..count) |index| {
            const info = self.parameterInfo(@intCast(index)) orelse continue;
            if (info.flags & (1 << 5) == 0 or !std.math.isFinite(info.min_value) or !std.math.isFinite(info.max_value) or info.min_value >= info.max_value) continue;
            if (info.min_value < -std.math.floatMax(f32) or info.max_value > std.math.floatMax(f32)) continue;
            const slot = self.automatable_count;
            const param_name = std.mem.sliceTo(&info.name, 0);
            const len = @min(param_name.len, self.automatable_names[slot].len);
            @memcpy(self.automatable_names[slot][0..len], param_name[0..len]);
            self.automatable_params[slot] = .{
                .id = info.id,
                .label = self.automatable_names[slot][0..len],
                .section = "CLAP",
                .range = .{ @floatCast(info.min_value), @floatCast(info.max_value) },
                .step = @floatCast((info.max_value - info.min_value) / 100.0),
            };
            self.automatable_count += 1;
        }
    }

    pub fn automationParams(self: *const ClapPlugin) []const device_mod.AutomatableParam {
        return self.automatable_params[0..self.automatable_count];
    }

    pub fn deinit(self: *ClapPlugin) void {
        switch (self.impl) {
            .direct => |*d| d.deinit(),
            .bridged => |b| b.deinit(),
        }
        self.allocator.destroy(self);
    }

    pub fn processBlock(self: *ClapPlugin, buf: []types.Sample) void {
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

    fn pushPending(self: *ClapPlugin, w: wire.WireEvent) void {
        if (self.pending_count < wire.max_events) {
            self.pending_events[self.pending_count] = w;
            self.pending_count += 1;
        }
    }

    pub fn handleEvent(self: *ClapPlugin, event: device_mod.Event) void {
        switch (self.impl) {
            .direct => |*d| d.handleEvent(self, event),
            .bridged => {
                const self_ptr: *anyopaque = @ptrCast(self);
                if (wire.fromDeviceEvent(event, self_ptr)) |w| self.pushPending(w);
            },
        }
    }

    pub fn pluginPath(self: *const ClapPlugin) []const u8 {
        return switch (self.impl) {
            .direct => |*d| d.pluginPath(),
            .bridged => |b| b.path,
        };
    }

    pub fn attachTransport(self: *ClapPlugin, transport: *const Transport) void {
        self.transport = transport;
        switch (self.impl) {
            .direct => |*d| d.attachTransport(transport),
            .bridged => {},
        }
    }

    pub fn id(self: *const ClapPlugin) []const u8 {
        return switch (self.impl) {
            .direct => |*d| d.id(),
            .bridged => |b| b.resolved_id,
        };
    }

    pub fn name(self: *const ClapPlugin) []const u8 {
        return switch (self.impl) {
            .direct => |*d| d.name(),
            .bridged => |b| b.resolved_name,
        };
    }

    pub fn parameterCount(self: *const ClapPlugin) u32 {
        return switch (self.impl) {
            .direct => |*d| d.parameterCount(),
            .bridged => |b| blk: {
                const resp = b.call(.parameter_count, &.{}) catch break :blk 0;
                break :blk if (resp.len >= 4) std.mem.bytesToValue(u32, resp[0..4]) else 0;
            },
        };
    }

    pub fn parameterInfo(self: *const ClapPlugin, index: u32) ?abi.ParamInfo {
        return switch (self.impl) {
            .direct => |*d| d.parameterInfo(index),
            .bridged => |b| blk: {
                const resp = b.call(.parameter_info, std.mem.asBytes(&index)) catch break :blk null;
                if (resp.len < @sizeOf(abi.ParamInfo)) break :blk null;
                break :blk std.mem.bytesToValue(abi.ParamInfo, resp[0..@sizeOf(abi.ParamInfo)]);
            },
        };
    }

    pub fn parameterName(self: *const ClapPlugin, index: u32, buffer: []u8) ?[]const u8 {
        return switch (self.impl) {
            .direct => |*d| d.parameterName(index, buffer),
            .bridged => |b| blk: {
                const resp = b.call(.parameter_name, std.mem.asBytes(&index)) catch break :blk null;
                if (resp.len == 0 or buffer.len == 0) break :blk null;
                const len = @min(resp.len, buffer.len);
                @memcpy(buffer[0..len], resp[0..len]);
                break :blk buffer[0..len];
            },
        };
    }

    pub fn parameterValue(self: *const ClapPlugin, id_value: u32) ?f64 {
        return switch (self.impl) {
            .direct => |*d| d.parameterValue(id_value),
            .bridged => |b| blk: {
                const resp = b.call(.parameter_value, std.mem.asBytes(&id_value)) catch break :blk null;
                break :blk if (resp.len >= 8) std.mem.bytesToValue(f64, resp[0..8]) else null;
            },
        };
    }

    pub fn formatParameter(
        self: *const ClapPlugin,
        id_value: u32,
        value: f64,
        buffer: []u8,
    ) ?[]const u8 {
        return switch (self.impl) {
            .direct => |*d| d.formatParameter(id_value, value, buffer),
            .bridged => |b| blk: {
                var req: [12]u8 = undefined;
                @memcpy(req[0..4], std.mem.asBytes(&id_value));
                @memcpy(req[4..12], std.mem.asBytes(&value));
                const resp = b.call(.format_parameter, &req) catch break :blk null;
                if (resp.len == 0 or buffer.len == 0) break :blk null;
                const len = @min(resp.len, buffer.len);
                @memcpy(buffer[0..len], resp[0..len]);
                break :blk buffer[0..len];
            },
        };
    }

    /// Queue a parameter edit for the next audio block. The caller must use
    /// the engine command queue when it runs concurrently with audio.
    pub fn setParameter(self: *ClapPlugin, id_value: u32, cookie: ?*anyopaque, value: f64) void {
        self.setParameterAt(id_value, cookie, value, 0);
    }

    pub fn setParameterAt(self: *ClapPlugin, id_value: u32, cookie: ?*anyopaque, value: f64, sample_offset: u32) void {
        switch (self.impl) {
            .direct => |*d| d.pushParameter(id_value, cookie, value, sample_offset),
            .bridged => self.pushPending(.{ .kind = .clap_param, .param_id = id_value, .cookie = cookie, .value = value, .sample_offset = sample_offset }),
        }
    }

    pub fn saveState(self: *ClapPlugin, allocator: std.mem.Allocator) !?[]u8 {
        switch (self.impl) {
            .direct => |*d| return d.saveState(allocator),
            .bridged => |b| {
                const resp = try b.call(.save_state, &.{});
                if (resp.len == 0) return null;
                return try allocator.dupe(u8, resp);
            },
        }
    }

    pub fn loadState(self: *ClapPlugin, bytes: []const u8) !bool {
        switch (self.impl) {
            .direct => |*d| return d.loadState(bytes),
            .bridged => |b| {
                _ = try b.call(.load_state, bytes);
                return true;
            },
        }
    }

    pub fn latencyFrames(self: *const ClapPlugin) u32 {
        return switch (self.impl) {
            .direct => |*d| d.latencyFrames(),
            .bridged => |b| b.latencyFrames(),
        };
    }

    pub fn tailFrames(self: *const ClapPlugin) ?u32 {
        return switch (self.impl) {
            .direct => |*d| d.tailFrames(),
            .bridged => |b| b.tailFrames(),
        };
    }

    pub fn reset(self: *ClapPlugin) void {
        switch (self.impl) {
            .direct => |*d| d.reset(),
            .bridged => |b| {
                self.pending_count = 0;
                b.requestReset();
            },
        }
    }

    pub fn hasGui(self: *const ClapPlugin) bool {
        return switch (self.impl) {
            .direct => |*d| d.hasGui(),
            .bridged => |b| b.has_gui,
        };
    }

    /// Whether the plugin has a note input port this host can drive, which
    /// is what makes it usable as a track's instrument. Audio input count
    /// says nothing about it: Surge XT is an instrument with one.
    pub fn acceptsNotes(self: *const ClapPlugin) bool {
        return switch (self.impl) {
            .direct => |*d| d.acceptsNotes(),
            .bridged => |b| b.has_note_input,
        };
    }

    pub fn toggleGui(self: *ClapPlugin) !bool {
        switch (self.impl) {
            .direct => |*d| return d.toggleGui(),
            .bridged => |b| {
                const resp = try b.call(.toggle_gui, &.{});
                return resp.len > 0 and resp[0] != 0;
            },
        }
    }

    /// Service callbacks whose CLAP contract requires the host's main
    /// thread. Bridged mode forwards this as a synchronous RPC to the
    /// child (see plugin_host/bridge.zig's `Bridge.serviceMainThread`),
    /// which runs the real plugin's own `serviceMainThread` and reports
    /// back - callers (app.zig's `servicePluginHosts`, and this file's own
    /// integration test) depend on servicing being complete by the time
    /// this call returns, the same as the direct path's plain function
    /// call.
    pub fn serviceMainThread(self: *ClapPlugin) bool {
        return switch (self.impl) {
            .direct => |*d| d.serviceMainThread(),
            .bridged => |b| b.serviceMainThread(),
        };
    }

    pub fn takeHostStalledBlocks(self: *ClapPlugin) u32 {
        return switch (self.impl) {
            .direct => 0,
            .bridged => |b| b.takeStalledBlocks(),
        };
    }

    pub fn takeHostCrashed(self: *ClapPlugin) bool {
        return switch (self.impl) {
            .direct => false,
            .bridged => |b| b.takeCrashed(),
        };
    }
};

fn validateAudioPorts(plugin: *const abi.Plugin) !AudioPortLayout {
    const ports = getExt(abi.PluginAudioPorts, plugin, abi.ext_audio_ports) orelse
        return error.MissingAudioPorts;
    const input_count = ports.count(plugin, true);
    const output_count = ports.count(plugin, false);
    if (output_count == 0) return error.UnsupportedAudioPortLayout;

    // Channels beyond the first two of the main port are still allocated and
    // handed to the plugin (see `PortBuffers`); this host just exchanges the
    // first one or two with the track.
    const input_channels: u32 = if (input_count == 0) 0 else @min(portChannelCount(plugin, 0, true), 2);
    return .{
        .input_count = input_count,
        .output_count = output_count,
        .input_channels = input_channels,
        .output_channels = @min(portChannelCount(plugin, 0, false), 2),
    };
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

/// Real in-process CLAP hosting - unchanged from before sandboxing existed.
/// Constructed by `ClapPlugin.loadDirect`; also the exact code
/// plugin_host/child_main.zig runs inside a sandboxed child (via
/// `ClapPlugin.load` with sandboxing disabled, since the child always
/// loads directly - sandboxing a sandbox would be turtles all the way
/// down).
const Direct = struct {
    allocator: std.mem.Allocator,
    library: dynlib_compat.DynLib,
    entry: *const abi.PluginEntry,
    plugin: *const abi.Plugin,
    host_context: *HostContext,
    path_z: [:0]u8,
    ports: PortBuffers,
    events: EventList = EventList.init(),
    output_events: abi.OutputEvents,
    audio_inputs_count: u32,
    /// Channels of the *main* port this host exchanges audio on, clamped to
    /// 2. The ports themselves may declare more (or none).
    input_channels: u32,
    output_channels: u32,
    note_dialect: NoteDialect,
    supports_midi: bool,
    sample_rate: u32,
    transport: ?*const Transport = null,
    steady_time: i64 = 0,
    activated: bool = true,
    started: bool = false,
    restart_in_progress: std.atomic.Value(bool) = .init(false),
    restart_ready: std.atomic.Value(bool) = .init(false),
    gui_created: bool = false,
    gui_visible: bool = false,
    gui_window: ?editor_window.Window = null,

    fn deinit(self: *Direct) void {
        self.destroyGui();
        if (self.started) {
            // `stop_processing` is [audio-thread] in the CLAP spec, and
            // plugins check: Odin2 calls std::terminate when the host says
            // otherwise. No audio thread is running by now (teardown owns
            // the plugin exclusively), so this thread is the audio thread
            // for the length of that one call.
            on_audio_thread = true;
            self.plugin.stop_processing(self.plugin);
            on_audio_thread = false;
        }
        if (self.activated) self.plugin.deactivate(self.plugin);
        self.host_context.stopWorkers();
        self.plugin.destroy(self.plugin);
        self.entry.deinit();
        self.library.close();
        self.ports.deinit(self.allocator);
        self.allocator.free(self.path_z);
        self.allocator.destroy(self.host_context);
    }

    fn processBlock(self: *Direct, buf: []types.Sample) void {
        const frames = buf.len / 2;
        if (frames == 0 or frames > types.max_block_frames or buf.len % 2 != 0) return;
        on_audio_thread = true;
        defer on_audio_thread = false;
        if (self.host_context.restart_requested.swap(false, .acquire)) {
            self.restart_in_progress.store(true, .release);
            if (self.started) self.plugin.stop_processing(self.plugin);
            self.started = false;
            self.restart_ready.store(true, .release);
        }
        if (self.restart_in_progress.load(.acquire)) return;
        if (!self.started) {
            self.started = self.plugin.start_processing(self.plugin);
            if (!self.started) return;
        }

        // Every channel of every port starts silent - the ports this host
        // does not use stay that way, and their output is discarded.
        for (self.ports.channel_ptrs) |channel| if (channel) |ptr| @memset(ptr[0..frames], 0);
        if (self.input_channels > 0) {
            if (self.ports.channel_ptrs[0]) |left| {
                for (0..frames) |frame|
                    left[frame] = if (self.input_channels == 1)
                        (buf[frame * 2] + buf[frame * 2 + 1]) * 0.5
                    else
                        buf[frame * 2];
            }
            if (self.input_channels >= 2) {
                if (self.ports.channel_ptrs[1]) |right| {
                    for (0..frames) |frame| right[frame] = buf[frame * 2 + 1];
                }
            }
        }
        var transport_event: abi.EventTransport = undefined;
        const transport_ptr: ?*const anyopaque = if (self.transport) |transport| blk: {
            transport_event = makeTransportEvent(transport);
            break :blk &transport_event;
        } else null;
        var process = abi.Process{
            .steady_time = self.steady_time,
            .frames_count = @intCast(frames),
            .transport = transport_ptr,
            .audio_inputs = if (self.ports.inputs.len == 0) null else self.ports.inputs.ptr,
            .audio_outputs = self.ports.outputs.ptr,
            .audio_inputs_count = @intCast(self.ports.inputs.len),
            .audio_outputs_count = @intCast(self.ports.outputs.len),
            .in_events = &self.events.interface,
            .out_events = &self.output_events,
        };
        if (self.host_context.param_flush_requested.swap(false, .acquire)) {
            if (self.paramsExtension()) |params|
                params.flush(self.plugin, &empty_input_events, &self.output_events);
        }
        const status = self.plugin.process(self.plugin, &process);
        self.events.len = 0;
        self.steady_time += @intCast(frames);
        if (status == 0) return;
        if (self.output_channels == 0) return;
        const out_left = self.ports.channel_ptrs[self.ports.main_output_channel] orelse return;
        const out_right = if (self.output_channels >= 2)
            (self.ports.channel_ptrs[self.ports.main_output_channel + 1] orelse out_left)
        else
            out_left;
        for (0..frames) |frame| {
            buf[frame * 2] = out_left[frame];
            buf[frame * 2 + 1] = out_right[frame];
        }
    }

    /// `outer` is the `ClapPlugin` wrapper this `Direct` is embedded in -
    /// needed only for the `clap_param` identity check below, since a
    /// track-wide broadcast's `target` is always the outer pointer callers
    /// actually hold (`Direct`'s own address differs, being embedded
    /// inside `ClapPlugin.impl`).
    pub fn handleEvent(self: *Direct, outer: *ClapPlugin, event: device_mod.Event) void {
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
                if (param.target == @as(*anyopaque, @ptrCast(outer)))
                    self.pushParameter(param.id, param.cookie, param.value, param.sample_offset);
            },
            // instance_id 0 is the track's instrument slot and never a real
            // FxUnit id, and `FxUnit.handleEvent` swallows those before they
            // reach a chain plugin - so the slot test alone is the whole
            // guard. It used to also require zero audio inputs as an
            // "am I the instrument" proxy, which silently dropped automation
            // for every synth that has an audio input (Surge XT, Odin2).
            .automation_param => |param| if (param.instance_id == 0) self.pushParameter(param.id, null, param.value, param.sample_offset),
            else => {},
        }
    }

    /// Builds a `size`-sized, now-timed CLAP core-space event header for
    /// `event_type` - shared by pushNote/pushMidi/pushParameter, which
    /// otherwise each repeat the same 5-field literal.
    fn eventHeader(size: u32, event_type: u16) abi.EventHeader {
        return eventHeaderAt(size, event_type, 0);
    }

    fn eventHeaderAt(size: u32, event_type: u16, sample_offset: u32) abi.EventHeader {
        return .{
            .size = size,
            .time = sample_offset,
            .space_id = abi.core_event_space_id,
            .event_type = event_type,
            .flags = 0,
        };
    }

    fn pushNote(self: *Direct, event_type: u16, key: ?u7, velocity: f32) void {
        self.events.push(.{ .note = .{
            .header = eventHeader(@sizeOf(abi.EventNote), event_type),
            .note_id = -1,
            .port_index = if (key == null) -1 else 0,
            .channel = if (key == null) -1 else 0,
            .key = if (key) |value| value else -1,
            .velocity = velocity,
        } });
    }

    fn pushMidi(self: *Direct, data: [3]u8) void {
        self.events.push(.{ .midi = .{
            .header = eventHeader(@sizeOf(abi.EventMidi), abi.event_midi),
            .port_index = 0,
            .data = data,
        } });
    }

    pub fn pluginPath(self: *const Direct) []const u8 {
        return self.path_z;
    }

    pub fn attachTransport(self: *Direct, transport: *const Transport) void {
        self.transport = transport;
    }

    pub fn id(self: *const Direct) []const u8 {
        return std.mem.span(self.plugin.desc.id);
    }

    pub fn name(self: *const Direct) []const u8 {
        return std.mem.span(self.plugin.desc.name);
    }

    fn paramsExtension(self: *const Direct) ?*const abi.PluginParams {
        return getExt(abi.PluginParams, self.plugin, abi.ext_params);
    }

    pub fn parameterCount(self: *const Direct) u32 {
        const params = self.paramsExtension() orelse return 0;
        return params.count(self.plugin);
    }

    pub fn parameterInfo(self: *const Direct, index: u32) ?abi.ParamInfo {
        const params = self.paramsExtension() orelse return null;
        var info: abi.ParamInfo = undefined;
        if (!params.get_info(self.plugin, index, &info)) return null;
        return info;
    }

    pub fn parameterName(self: *const Direct, index: u32, buffer: []u8) ?[]const u8 {
        const info = self.parameterInfo(index) orelse return null;
        const param_name = std.mem.sliceTo(&info.name, 0);
        if (param_name.len == 0 or buffer.len == 0) return null;
        const len = @min(param_name.len, buffer.len);
        @memcpy(buffer[0..len], param_name[0..len]);
        return buffer[0..len];
    }

    pub fn parameterValue(self: *const Direct, id_value: u32) ?f64 {
        const params = self.paramsExtension() orelse return null;
        var value: f64 = undefined;
        if (!params.get_value(self.plugin, id_value, &value)) return null;
        return value;
    }

    pub fn formatParameter(
        self: *const Direct,
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

    fn pushParameter(self: *Direct, id_value: u32, cookie: ?*anyopaque, value: f64, sample_offset: u32) void {
        self.events.push(.{ .param = .{
            .header = eventHeaderAt(@sizeOf(abi.EventParamValue), abi.event_param_value, sample_offset),
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

    pub fn saveState(self: *Direct, allocator: std.mem.Allocator) !?[]u8 {
        const state = getExt(abi.PluginState, self.plugin, abi.ext_state) orelse return null;
        var writer = StateWriter{ .allocator = allocator };
        errdefer writer.bytes.deinit(allocator);
        var stream = abi.OutputStream{ .ctx = &writer, .write = StateWriter.write };
        if (!state.save(self.plugin, &stream) or writer.failed) return error.PluginStateSaveFailed;
        return try writer.bytes.toOwnedSlice(allocator);
    }

    pub fn loadState(self: *Direct, bytes: []const u8) !bool {
        const state = getExt(abi.PluginState, self.plugin, abi.ext_state) orelse return false;
        var reader = StateReader{ .bytes = bytes };
        var stream = abi.InputStream{ .ctx = &reader, .read = StateReader.read };
        if (!state.load(self.plugin, &stream)) return error.PluginStateLoadFailed;
        self.host_context.state_dirty.store(false, .release);
        return true;
    }

    pub fn latencyFrames(self: *const Direct) u32 {
        const latency = getExt(abi.PluginLatency, self.plugin, abi.ext_latency) orelse return 0;
        return latency.get(self.plugin);
    }

    pub fn tailFrames(self: *const Direct) ?u32 {
        const tail = getExt(abi.PluginTail, self.plugin, abi.ext_tail) orelse return null;
        return tail.get(self.plugin);
    }

    pub fn reset(self: *Direct) void {
        self.events.len = 0;
        if (!self.started) return;
        // `clap_plugin.reset` is [audio-thread], the same rule `deinit`
        // observes for `stop_processing`, and Odin 2 aborts the process when
        // the host's thread check disagrees. Every caller reaches here from
        // the audio thread - the rack resets an FX unit from inside the
        // callback, and the bridge child from its own audio loop - but the
        // flag is only raised inside `processBlock`, so this call arrived
        // with it still clear. Saved and restored rather than cleared, since
        // a device chain can reset from within a block already in flight.
        const was_audio_thread = on_audio_thread;
        on_audio_thread = true;
        defer on_audio_thread = was_audio_thread;
        self.plugin.reset(self.plugin);
    }

    fn guiExtension(self: *const Direct) ?*const abi.PluginGui {
        return getExt(abi.PluginGui, self.plugin, abi.ext_gui);
    }

    pub fn hasGui(self: *const Direct) bool {
        return self.guiExtension() != null;
    }

    pub fn acceptsNotes(self: *const Direct) bool {
        return self.note_dialect != .none;
    }

    pub fn toggleGui(self: *Direct) !bool {
        if (!self.gui_created) {
            try self.createGui();
        } else if (self.gui_visible) {
            const gui = self.guiExtension() orelse return error.GuiUnavailable;
            if (self.gui_window) |*window| {
                _ = gui.hide(self.plugin);
                window.hide();
            } else if (!gui.hide(self.plugin)) return error.GuiHideFailed;
            self.gui_visible = false;
        } else {
            const gui = self.guiExtension() orelse return error.GuiUnavailable;
            if (self.gui_window) |*window| {
                _ = gui.show(self.plugin);
                window.show();
            } else if (!gui.show(self.plugin)) return error.GuiShowFailed;
            self.gui_visible = true;
        }
        return self.gui_visible;
    }

    fn createGui(self: *Direct) !void {
        const gui = self.guiExtension() orelse return error.GuiUnavailable;
        var preferred_api: ?[*:0]const u8 = null;
        var preferred_floating = false;
        var created = false;
        if (gui.get_preferred_api(self.plugin, &preferred_api, &preferred_floating) and preferred_floating) {
            if (preferred_api) |api| {
                if (gui.is_api_supported(self.plugin, api, true))
                    created = gui.create(self.plugin, api, true);
            }
        }
        if (!created) {
            const apis: []const [*:0]const u8 = switch (@import("builtin").os.tag) {
                .windows => &.{abi.window_api_win32},
                .macos => &.{abi.window_api_cocoa},
                else => &.{ abi.window_api_wayland, abi.window_api_x11 },
            };
            for (apis) |api| {
                if (!gui.is_api_supported(self.plugin, api, true)) continue;
                if (gui.create(self.plugin, api, true)) {
                    created = true;
                    break;
                }
            }
        }
        if (!created) try self.createEmbeddedGui(gui);
        self.gui_created = true;
        if (self.gui_window == null) gui.suggest_title(self.plugin, self.plugin.desc.name);
        if (self.gui_window) |*window| window.show();
        if (!gui.show(self.plugin) and self.gui_window == null) {
            gui.destroy(self.plugin);
            if (self.gui_window) |*window| window.close();
            self.gui_window = null;
            self.gui_created = false;
            return error.GuiShowFailed;
        }
        self.gui_visible = true;
    }

    fn createEmbeddedGui(self: *Direct, gui: *const abi.PluginGui) !void {
        const api = switch (@import("builtin").os.tag) {
            .windows => abi.window_api_win32,
            .macos => abi.window_api_cocoa,
            else => abi.window_api_x11,
        };
        if (!gui.is_api_supported(self.plugin, api, false)) return error.GuiUnsupported;
        if (!gui.create(self.plugin, api, false)) return error.GuiCreateFailed;
        errdefer gui.destroy(self.plugin);
        var width: u32 = 640;
        var height: u32 = 480;
        _ = gui.get_size(self.plugin, &width, &height);
        var window = try editor_window.Window.open(@intCast(@max(width, 1)), @intCast(@max(height, 1)), self.plugin.desc.name, gui.can_resize(self.plugin));
        errdefer window.close();
        const parent: abi.Window = .{
            .api = api,
            .handle = switch (window.api()) {
                .win32 => .{ .win32 = @ptrFromInt(window.handle()) },
                .cocoa => .{ .cocoa = @ptrFromInt(window.handle()) },
                .wayland => .{ .ptr = @ptrFromInt(window.handle()) },
                .x11 => .{ .x11 = @intCast(window.handle()) },
            },
        };
        if (!gui.set_parent(self.plugin, &parent)) return error.GuiParentFailed;
        // Ask again now that the editor has a parent. The first answer is
        // whatever the plugin defaults to before it knows where it lives, and
        // plugins that scale to their host, restore a saved editor size, or
        // build their view on parenting all report a different size here. The
        // window has to follow, or the plugin draws at its real size inside a
        // frame sized for the guess.
        var parented_width: u32 = width;
        var parented_height: u32 = height;
        if (gui.get_size(self.plugin, &parented_width, &parented_height) and
            parented_width > 0 and parented_height > 0 and
            (parented_width != width or parented_height != height))
        {
            window.resize(@intCast(parented_width), @intCast(parented_height));
        }
        self.gui_window = window;
    }

    fn destroyGui(self: *Direct) void {
        if (!self.gui_created) return;
        const gui = self.guiExtension() orelse return;
        if (self.gui_visible) _ = gui.hide(self.plugin);
        gui.destroy(self.plugin);
        if (self.gui_window) |*window| window.close();
        self.gui_window = null;
        self.gui_created = false;
        self.gui_visible = false;
    }

    /// Service callbacks whose CLAP contract requires the host's main
    /// thread. Parameter, latency, and tail queries are uncached, so their
    /// change notifications only need acknowledging. Returns whether the
    /// plugin marked its opaque state dirty since the previous service.
    pub fn serviceMainThread(self: *Direct) bool {
        const now = wire.monotonicNs();
        if (getExt(abi.PluginTimerSupport, self.plugin, abi.ext_timer_support)) |timer_support| {
            for (&self.host_context.timers, 0..) |*slot, timer_id| if (slot.*) |*timer| {
                if (now < timer.next_ns) continue;
                timer.next_ns = now + timer.period_ns;
                timer_support.on_timer(self.plugin, @intCast(timer_id));
            };
        }
        const gui_window_open = if (self.gui_window) |*window| window.service() else true;
        if (!gui_window_open) self.destroyGui();
        if (self.gui_window) |*window| if (window.takeResize()) |size| {
            if (size.width > 0 and size.height > 0) if (self.guiExtension()) |gui| if (gui.can_resize(self.plugin)) {
                var width: u32 = @intCast(size.width);
                var height: u32 = @intCast(size.height);
                _ = gui.adjust_size(self.plugin, &width, &height);
                if (gui.set_size(self.plugin, width, height) and (width != size.width or height != size.height))
                    window.resize(@intCast(width), @intCast(height));
            };
        };
        const resize = self.host_context.gui_resize_requested.swap(0, .acquire);
        if (resize != 0 and self.gui_window != null) {
            const width: u32 = @intCast(resize >> 32);
            const height: u32 = @truncate(resize);
            if (self.gui_window) |*window| window.resize(@intCast(width), @intCast(height));
        }
        if (self.restart_ready.swap(false, .acquire)) {
            self.plugin.deactivate(self.plugin);
            self.activated = false;
            const audio_layout: ?AudioPortLayout = validateAudioPorts(self.plugin) catch null;
            if (audio_layout) |layout| {
                const note_support = detectNoteSupport(self.plugin);
                if (self.plugin.activate(self.plugin, @floatFromInt(self.sample_rate), 1, types.max_block_frames)) {
                    self.activated = true;
                    self.audio_inputs_count = layout.input_count;
                    self.input_channels = layout.input_channels;
                    self.output_channels = layout.output_channels;
                    self.note_dialect = note_support.dialect;
                    self.supports_midi = note_support.supports_midi;
                } else std.log.err("CLAP restart activation failed: {s}", .{self.name()});
            } else std.log.err("CLAP restart found unsupported audio ports: {s}", .{self.name()});
            if (self.activated) self.restart_in_progress.store(false, .release);
        }
        if (self.host_context.callback_requested.swap(false, .acquire))
            self.plugin.on_main_thread(self.plugin);
        _ = self.host_context.param_rescan_flags.swap(0, .acquire);
        _ = self.host_context.latency_changed.swap(false, .acquire);
        _ = self.host_context.tail_changed.swap(false, .acquire);
        const closed = self.host_context.gui_closed.swap(0, .acquire);
        if (closed != 0) {
            self.gui_visible = false;
            if (closed == 2 and self.gui_created) {
                if (self.guiExtension()) |gui| gui.destroy(self.plugin);
                if (self.gui_window) |*window| window.close();
                self.gui_window = null;
                self.gui_created = false;
            }
        }
        if (self.host_context.gui_hide_requested.swap(false, .acquire) and self.gui_created and self.gui_visible) {
            if (self.guiExtension()) |gui| {
                if (self.gui_window) |*window| {
                    _ = gui.hide(self.plugin);
                    window.hide();
                    self.gui_visible = false;
                } else self.gui_visible = !gui.hide(self.plugin);
            }
        }
        if (self.host_context.gui_show_requested.swap(false, .acquire)) {
            if (!self.gui_created) {
                self.createGui() catch {};
            } else if (!self.gui_visible) {
                if (self.guiExtension()) |gui| {
                    if (self.gui_window) |*window| {
                        _ = gui.show(self.plugin);
                        window.show();
                        self.gui_visible = true;
                    } else self.gui_visible = gui.show(self.plugin);
                }
            }
        }
        return self.host_context.state_dirty.swap(false, .acq_rel);
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
    const song_beats = transport.positionBeats();
    const meter = transport.currentMeter();
    var flags = abi.transport_has_tempo |
        abi.transport_has_beats_timeline |
        abi.transport_has_seconds_timeline |
        abi.transport_has_time_signature;
    if (transport.playing) flags |= abi.transport_is_playing;
    if (transport.loop_enabled and transport.loop_end_frames > transport.loop_start_frames)
        flags |= abi.transport_is_loop_active;
    const loop_start_beats = transport.beatsAtFrames(transport.loop_start_frames);
    const loop_end_beats = transport.beatsAtFrames(transport.loop_end_frames);
    const bar = transport.positionBarBeat().bar;
    const bar_number: i32 = if (bar >= std.math.maxInt(i32))
        std.math.maxInt(i32)
    else
        @intCast(bar);
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
        .tempo = transport.currentTempo(),
        .tempo_inc = 0,
        .loop_start_beats = fixedTime(loop_start_beats),
        .loop_end_beats = fixedTime(loop_end_beats),
        .loop_start_seconds = fixedTime(@as(f64, @floatFromInt(transport.loop_start_frames)) / sample_rate),
        .loop_end_seconds = fixedTime(@as(f64, @floatFromInt(transport.loop_end_frames)) / sample_rate),
        .bar_start = fixedTime(transport.beatAtBar(bar)),
        .bar_number = bar_number,
        .tsig_num = meter.numerator,
        .tsig_denom = meter.denominator,
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

test "CLAP host timer registration validates and reuses slots" {
    var host = HostContext.init();
    host.bind();
    var timer_id: u32 = undefined;
    try std.testing.expect(!HostContext.registerTimer(&host.host, 0, &timer_id));
    try std.testing.expect(HostContext.registerTimer(&host.host, 20, &timer_id));
    try std.testing.expectEqual(@as(u32, 0), timer_id);
    try std.testing.expect(!HostContext.unregisterTimer(&host.host, 1));
    try std.testing.expect(HostContext.unregisterTimer(&host.host, timer_id));
    try std.testing.expect(HostContext.registerTimer(&host.host, 10, &timer_id));
    try std.testing.expectEqual(@as(u32, 0), timer_id);
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

test "real CLAP GUI smoke when WSTUDIO_TEST_CLAP_GUI is set" {
    const path_z = std.c.getenv("WSTUDIO_TEST_CLAP_GUI") orelse return;
    const plugin = try ClapPlugin.load(std.testing.allocator, std.mem.span(path_z), null, 48_000);
    defer plugin.deinit();
    try std.testing.expect(try plugin.toggleGui());
    _ = plugin.serviceMainThread();
    try std.testing.expect(!try plugin.toggleGui());
}

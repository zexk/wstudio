//! Entry point for `wstudio-plugin-bridge`, the sandboxed-plugin child
//! process spawned by `bridge.zig`. Owns one real (unmodified)
//! `ClapPlugin` or `Vst3Plugin` - this file is the only place that ever
//! constructs one in-process; `bridge.zig`'s parent-side handle only ever
//! talks to it over the shared-memory block and the RPC pipes.
//!
//! argv: kind("clap"|"vst3") path plugin_id_or_class_id sample_rate
//! instrument("0"|"1") shm_fd
//!
//! Three roles, three threads:
//! - this (main) thread: loads the plugin, then loops calling
//!   `serviceMainThread()`. CLAP's main-thread contract only requires a
//!   *stable* thread identity, established at `HostContext.init()` time
//!   inside `load()` - so `load()` runs here, and this thread never does
//!   anything else afterward, matching that identity for the rest of the
//!   process's life.
//! - the audio thread: services the shared-memory block (process/event/
//!   reset/latency), spun up only after load succeeds.
//! - the RPC thread: serves control-path requests (param enumeration,
//!   state save/load, GUI toggle) over stdin/stdout.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const transport = ws.plugin_host.transport;
const rpc = ws.plugin_host.rpc;
const ClapPlugin = ws.clap.ClapPlugin;
const Vst3Plugin = ws.vst3.Vst3Plugin;

const RealPlugin = union(enum) {
    clap: *ClapPlugin,
    vst3: *Vst3Plugin,

    fn ptr(self: RealPlugin) *anyopaque {
        return switch (self) {
            .clap => |p| @ptrCast(p),
            .vst3 => |p| @ptrCast(p),
        };
    }
};

const Shared = struct {
    plugin: RealPlugin,
    block: *transport.SharedBlock,
};

fn parseArgs(gpa: std.mem.Allocator, raw_args: std.process.Args) !struct {
    kind: []const u8,
    path: []const u8,
    id: []const u8,
    sample_rate: u32,
    instrument: bool,
    shm_fd: std.posix.fd_t,
} {
    var it = try std.process.Args.Iterator.initAllocator(raw_args, gpa);
    defer it.deinit();
    _ = it.next();
    const kind = it.next() orelse return error.MissingArgs;
    const path = it.next() orelse return error.MissingArgs;
    const id = it.next() orelse return error.MissingArgs;
    const sample_rate_str = it.next() orelse return error.MissingArgs;
    const instrument_str = it.next() orelse return error.MissingArgs;
    const shm_fd_str = it.next() orelse return error.MissingArgs;
    return .{
        .kind = try gpa.dupe(u8, kind),
        .path = try gpa.dupe(u8, path),
        .id = try gpa.dupe(u8, id),
        .sample_rate = try std.fmt.parseInt(u32, sample_rate_str, 10),
        .instrument = std.mem.eql(u8, instrument_str, "1"),
        .shm_fd = try std.fmt.parseInt(std.posix.fd_t, shm_fd_str, 10),
    };
}

fn loadPlugin(gpa: std.mem.Allocator, kind: []const u8, path: []const u8, id: []const u8, sample_rate: u32, instrument: bool) !RealPlugin {
    if (std.mem.eql(u8, kind, "clap")) {
        const plugin_id: ?[]const u8 = if (id.len == 0) null else id;
        const p = try ClapPlugin.load(gpa, path, plugin_id, sample_rate);
        return .{ .clap = p };
    }
    const p = try Vst3Plugin.load(gpa, path, id, sample_rate, instrument);
    return .{ .vst3 = p };
}

fn writeHandshake(writer: *std.Io.Writer, failed_msg: ?[]const u8, plugin: ?RealPlugin) !void {
    if (failed_msg) |msg| {
        try rpc.send(writer, .ping, true, msg);
        return;
    }
    var hs: transport.Handshake = .{};
    switch (plugin.?) {
        .clap => |p| {
            hs.audio_inputs_count = p.audio_inputs_count;
            hs.has_gui = @intFromBool(p.hasGui());
            hs.has_note_input = @intFromBool(p.acceptsNotes());
            const id = p.id();
            hs.id_len = @intCast(@min(id.len, hs.id.len));
            @memcpy(hs.id[0..hs.id_len], id[0..hs.id_len]);
            const name = p.name();
            hs.name_len = @intCast(@min(name.len, hs.name.len));
            @memcpy(hs.name[0..hs.name_len], name[0..hs.name_len]);
        },
        .vst3 => |p| {
            hs.has_gui = @intFromBool(p.hasGui());
            const id = p.classId();
            hs.id_len = @intCast(@min(id.len, hs.id.len));
            @memcpy(hs.id[0..hs.id_len], id[0..hs.id_len]);
        },
    }
    try rpc.send(writer, .ping, false, std.mem.asBytes(&hs));
}

fn audioLoop(shared: *Shared) void {
    const block = shared.block;
    var last_seq: u64 = 0;
    var buf: [transport.max_frames * 2]f32 = undefined;
    while (true) {
        // Spin for a while, then yield - the same policy (and the same 200)
        // as `transport.waitUntil`, which is what the parent waits with. A
        // pure spin here reads a published block a hair sooner, but it also
        // pegs a core per hosted plugin for as long as the plugin is loaded,
        // so a project with more bridged plugins than the machine has cores
        // starves every child at once: measured at 16 instances on 12 cores,
        // callbacks went from 134us (8 instances) to 25ms, ten times the
        // block deadline, while 16 of the same plugin in-process cost 40us.
        var spins: u32 = 0;
        while (@atomicLoad(u64, &block.input_seq, .acquire) == last_seq) {
            std.atomic.spinLoopHint();
            spins += 1;
            if (spins >= 200) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
        last_seq = @atomicLoad(u64, &block.input_seq, .acquire);

        if (@atomicRmw(u8, &block.reset_requested, .Xchg, 0, .acq_rel) != 0) {
            switch (shared.plugin) {
                inline else => |p| p.reset(),
            }
        }
        // The parent clamps both of these before publishing, but the block is
        // mapped writable in this process and the plugin loaded here is
        // third-party code that can scribble anywhere in it. Clamping again
        // keeps a stray write inside the buffers rather than out of them.
        const frames = @min(block.frames, transport.max_frames);
        const event_count = @min(block.event_count, transport.max_events);
        const self_ptr = shared.plugin.ptr();
        // The parent's `xport` never crosses as a pointer (it wouldn't be
        // valid in this address space) - it rides as `TransportWire` data
        // in the block instead, reconstructed here and re-attached every
        // block, matching how `attachTransport` normally works: the real
        // plugin reads `self.transport` fresh at each `processBlock` call.
        var local_transport = block.xport.toTransport();
        switch (shared.plugin) {
            inline else => |p| p.attachTransport(&local_transport),
        }
        for (block.events[0..event_count]) |wire| {
            if (transport.toDeviceEvent(wire, self_ptr)) |ev| switch (shared.plugin) {
                inline else => |p| p.handleEvent(ev),
            };
        }
        for (0..frames) |i| {
            buf[i * 2] = block.audio_in[0][i];
            buf[i * 2 + 1] = block.audio_in[1][i];
        }
        switch (shared.plugin) {
            inline else => |p| p.processBlock(buf[0 .. frames * 2]),
        }
        for (0..frames) |i| {
            block.audio_out[0][i] = buf[i * 2];
            block.audio_out[1][i] = buf[i * 2 + 1];
        }
        // No latencyFrames()/tailFrames() here (there used to be some):
        // both go through CLAP's get_extension, which is main-thread-only
        // per spec and asserted as such by real plugins (confirmed with
        // Odin2, which aborts the process on the violation) - this thread
        // is deliberately not that thread. See rpc.Kind's `.latency_frames`/
        // `.tail_frames` for the synchronous-RPC replacement.

        @atomicStore(u64, &block.output_seq, last_seq, .release);
    }
}

/// Fixed CLAP param-info payload (matches `clap.abi.ParamInfo`, an
/// `extern struct`) or VST3 (`vst3.abi.ParameterInfo`) - sent as raw
/// bytes; the parent-side guard clause that issued the request already
/// knows which shape to expect since it knows which kind it's bridging.
fn rpcLoop(shared: *Shared, reader: *std.Io.Reader, writer: *std.Io.Writer) void {
    var scratch: [rpc.max_payload]u8 = undefined;
    while (true) {
        const req = rpc.recv(reader, &scratch) catch return; // parent closed the pipe (or protocol error) - nothing left to serve
        dispatch(shared, req, writer) catch return;
        if (req.kind == .shutdown) std.process.exit(0);
    }
}

fn dispatch(shared: *Shared, req: rpc.Received, writer: *std.Io.Writer) !void {
    if (req.payload.len < rpc.requestMinPayload(req.kind)) return error.RpcProtocolError;
    switch (req.kind) {
        .shutdown, .ping => try rpc.send(writer, req.kind, false, &.{}),
        .set_parameter => {
            const id = std.mem.bytesToValue(u32, req.payload[0..4]);
            const value = std.mem.bytesToValue(f64, req.payload[4..12]);
            switch (shared.plugin) {
                .clap => {}, // CLAP doesn't use this RPC - its setParameter stays a queued event
                .vst3 => |p| p.setParameter(id, value),
            }
            try rpc.send(writer, req.kind, false, &.{});
        },
        .latency_frames => {
            const latency: u32 = switch (shared.plugin) {
                inline else => |p| p.latencyFrames(),
            };
            try rpc.send(writer, req.kind, false, std.mem.asBytes(&latency));
        },
        .tail_frames => {
            const tail: ?u32 = switch (shared.plugin) {
                .clap => |p| p.tailFrames(),
                .vst3 => null,
            };
            if (tail) |t| try rpc.send(writer, req.kind, false, std.mem.asBytes(&t)) else try rpc.send(writer, req.kind, true, &.{});
        },
        .service_main_thread => {
            const dirty: bool = switch (shared.plugin) {
                inline else => |p| p.serviceMainThread(),
            };
            var b: [1]u8 = .{@intFromBool(dirty)};
            try rpc.send(writer, req.kind, false, &b);
        },
        .parameter_count => {
            const count: u32 = switch (shared.plugin) {
                .clap => |p| p.parameterCount(),
                .vst3 => |p| @intCast(p.parameterCount()),
            };
            try rpc.send(writer, req.kind, false, std.mem.asBytes(&count));
        },
        .parameter_info => {
            const index = std.mem.bytesToValue(u32, req.payload[0..4]);
            switch (shared.plugin) {
                .clap => |p| if (p.parameterInfo(index)) |info|
                    try rpc.send(writer, req.kind, false, std.mem.asBytes(&info))
                else
                    try rpc.send(writer, req.kind, true, &.{}),
                .vst3 => |p| if (p.parameterInfo(index)) |info|
                    try rpc.send(writer, req.kind, false, std.mem.asBytes(&info))
                else
                    try rpc.send(writer, req.kind, true, &.{}),
            }
        },
        .parameter_name => {
            const index = std.mem.bytesToValue(u32, req.payload[0..4]);
            var buf: [256]u8 = undefined;
            const name: ?[]const u8 = switch (shared.plugin) {
                .clap => |p| p.parameterName(index, &buf),
                .vst3 => |p| p.parameterName(@intCast(index), &buf),
            };
            if (name) |n| try rpc.send(writer, req.kind, false, n) else try rpc.send(writer, req.kind, true, &.{});
        },
        .parameter_value => {
            const id = std.mem.bytesToValue(u32, req.payload[0..4]);
            const value: ?f64 = switch (shared.plugin) {
                .clap => |p| p.parameterValue(id),
                .vst3 => |p| p.parameterValue(id),
            };
            if (value) |v| try rpc.send(writer, req.kind, false, std.mem.asBytes(&v)) else try rpc.send(writer, req.kind, true, &.{});
        },
        .format_parameter => {
            const id = std.mem.bytesToValue(u32, req.payload[0..4]);
            const value = std.mem.bytesToValue(f64, req.payload[4..12]);
            var buf: [256]u8 = undefined;
            const text: ?[]const u8 = switch (shared.plugin) {
                .clap => |p| p.formatParameter(id, value, &buf),
                .vst3 => |p| p.formatParameter(id, value, &buf),
            };
            if (text) |t| try rpc.send(writer, req.kind, false, t) else try rpc.send(writer, req.kind, true, &.{});
        },
        .toggle_gui => {
            switch (shared.plugin) {
                .clap => |p| {
                    const visible = p.toggleGui() catch |err| {
                        try rpc.send(writer, req.kind, true, @errorName(err));
                        return;
                    };
                    var b: [1]u8 = .{@intFromBool(visible)};
                    try rpc.send(writer, req.kind, false, &b);
                },
                .vst3 => |p| {
                    const visible = p.toggleGui() catch |err| {
                        std.log.err("VST3 GUI: {s}, DISPLAY={s}", .{ @errorName(err), if (std.c.getenv("DISPLAY")) |display| std.mem.span(display) else "unset" });
                        try rpc.send(writer, req.kind, true, @errorName(err));
                        return;
                    };
                    var b: [1]u8 = .{@intFromBool(visible)};
                    try rpc.send(writer, req.kind, false, &b);
                },
            }
        },
        .save_state => {
            switch (shared.plugin) {
                .clap => |p| {
                    const state = p.saveState(std.heap.page_allocator) catch {
                        try rpc.send(writer, req.kind, true, &.{});
                        return;
                    };
                    defer if (state) |s| std.heap.page_allocator.free(s);
                    try rpc.send(writer, req.kind, false, state orelse &.{});
                },
                .vst3 => |p| {
                    const component = p.saveComponentState(std.heap.page_allocator) catch {
                        try rpc.send(writer, req.kind, true, &.{});
                        return;
                    };
                    defer std.heap.page_allocator.free(component);
                    const controller = (p.saveControllerState(std.heap.page_allocator) catch null);
                    defer if (controller) |c| std.heap.page_allocator.free(c);
                    var buf: [rpc.max_payload]u8 = undefined;
                    var pos: usize = 0;
                    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(component.len), .little);
                    pos += 4;
                    @memcpy(buf[pos..][0..component.len], component);
                    pos += component.len;
                    const controller_bytes = controller orelse &.{};
                    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(controller_bytes.len), .little);
                    pos += 4;
                    @memcpy(buf[pos..][0..controller_bytes.len], controller_bytes);
                    pos += controller_bytes.len;
                    try rpc.send(writer, req.kind, false, buf[0..pos]);
                },
            }
        },
        .load_state => {
            switch (shared.plugin) {
                .clap => |p| {
                    _ = p.loadState(req.payload) catch {
                        try rpc.send(writer, req.kind, true, &.{});
                        return;
                    };
                    try rpc.send(writer, req.kind, false, &.{});
                },
                .vst3 => |p| {
                    if (req.payload.len < 4) return error.RpcProtocolError;
                    const component_len = std.mem.readInt(u32, req.payload[0..4], .little);
                    if (req.payload.len < 8 or component_len > req.payload.len - 8) return error.RpcProtocolError;
                    const component = req.payload[4..][0..component_len];
                    const controller_len = std.mem.readInt(u32, req.payload[4 + component_len ..][0..4], .little);
                    if (controller_len > req.payload.len - (8 + @as(usize, component_len))) return error.RpcProtocolError;
                    const controller = req.payload[4 + component_len + 4 ..][0..controller_len];
                    p.loadState(component, controller) catch {
                        try rpc.send(writer, req.kind, true, &.{});
                        return;
                    };
                    try rpc.send(writer, req.kind, false, &.{});
                },
            }
        },
        .attach_transport => try rpc.send(writer, req.kind, false, &.{}), // transport rides the shared audio block instead; nothing to do
    }
}

pub fn main(init: std.process.Init) !void {
    // Everything below is POSIX: an inherited shared-memory file descriptor
    // and an mmap of it. Sandboxing is Linux-only anyway (`bridge.zig`'s
    // `sandboxAvailable`, and `spawn` refuses elsewhere), so on other targets
    // this binary exists only to keep one install layout, and the comptime
    // branch keeps the POSIX code from being analysed for them at all.
    if (builtin.os.tag != .linux) return error.SandboxUnsupportedOnThisPlatform;
    // This process IS the sandbox: it must always load the plugin
    // in-process (via ClapPlugin/Vst3Plugin's Direct path), never spawn
    // another bridge for itself. `sandbox_enabled` defaults to true in
    // every fresh process (it's process-local, not inherited from the
    // parent's value), so without this the child would try to spawn a
    // grandchild for the same plugin, recursing.
    ws.plugin_host.bridge.sandbox_enabled.store(false, .release);
    const gpa = init.gpa;
    const args = try parseArgs(gpa, init.minimal.args);

    const shm = try std.posix.mmap(null, transport.SharedBlock.shm_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, args.shm_fd, 0);
    const block: *transport.SharedBlock = @ptrCast(@alignCast(shm.ptr));

    var stdout_write_buf: [rpc.max_payload]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_write_buf);

    const plugin = loadPlugin(gpa, args.kind, args.path, args.id, args.sample_rate, args.instrument) catch |err| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s}", .{@errorName(err)}) catch "load failed";
        try writeHandshake(&stdout_writer.interface, msg, null);
        return;
    };
    try writeHandshake(&stdout_writer.interface, null, plugin);

    var shared = Shared{ .plugin = plugin, .block = block };
    const audio_thread = try std.Thread.spawn(.{}, audioLoop, .{&shared});
    audio_thread.detach();

    // rpcLoop runs on *this* thread rather than a spawned one: CLAP's
    // `HostContext` captured this thread's id as `main_thread_id` a few
    // lines up inside `loadPlugin`, and `serviceMainThread`/`toggleGui`/
    // GUI creation all need to run on that exact thread to honor CLAP's
    // main-thread contract - not just for the request this bug report was
    // about. `main()` has nothing else to do afterward, so blocking here
    // until the parent sends `.shutdown` (or closes the pipe) is the
    // entire remaining lifetime of this process.
    var stdin_read_buf: [rpc.max_payload]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_read_buf);
    rpcLoop(&shared, &stdin_reader.interface, &stdout_writer.interface);
}

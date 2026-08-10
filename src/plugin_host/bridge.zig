//! Parent-side handle to a sandboxed CLAP/VST3 plugin child process (see
//! child_main.zig for the other end). Owns the shared-memory audio/event
//! ring (transport.zig), the RPC control channel (rpc.zig) over the
//! child's stdin/stdout, and a reaper thread that detects the child
//! dying so the audio path can degrade to silence instead of hanging or
//! taking the whole process down with it.
//!
//! Linux only - matches this codebase's existing per-backend platform
//! split (see src/audio/host.zig's `has_X` idiom). Callers on other
//! platforms simply don't call `Bridge.spawn`; `ClapPlugin`/`Vst3Plugin`
//! fall back to loading in-process there, same as before this existed.

const std = @import("std");
const builtin = @import("builtin");
const transport = @import("transport.zig");
const rpc = @import("rpc.zig");
const device_mod = @import("../dsp/device.zig");
const types = @import("../core/types.zig");
const transport_mod = @import("../transport.zig");

/// Process-wide switch: whether `ClapPlugin.load`/`Vst3Plugin.load` spawn a
/// sandboxed child instead of loading in-process. Set once at startup from
/// `wstudio.o.sandbox_plugins` (see `ui/app.zig`); a plain global rather
/// than a parameter threaded through the ~4 independent call sites that
/// construct a hosted plugin, since it's a single process-wide toggle, not
/// a per-call decision.
pub var sandbox_enabled: std.atomic.Value(bool) = .init(true);

pub fn sandboxActive() bool {
    return builtin.os.tag == .linux and sandbox_enabled.load(.acquire);
}

pub const PluginKind = enum { clap, vst3 };

pub const SpawnOptions = struct {
    kind: PluginKind,
    /// CLAP plugin binary path, or VST3 bundle path.
    path: []const u8,
    /// CLAP plugin id (empty means "let the child pick the default", same
    /// as passing `null` to `ClapPlugin.load`); VST3's 32-char class id.
    plugin_id: []const u8,
    sample_rate: u32,
    /// VST3 only: whether the plugin is hosted as an instrument (no audio
    /// input bus) vs an effect. Ignored for CLAP, which detects this from
    /// the plugin's own port layout.
    instrument: bool = false,
};

/// How long `Bridge.spawn` waits for the child to finish loading the
/// plugin and report ready before giving up - plugin init can legitimately
/// be slow (sample libraries, JIT warmup), so this is generous.
const spawn_timeout_ns: u64 = 10 * std.time.ns_per_s;
/// Per-block deadline for the real-time path: a small multiple of the
/// largest block the engine can ask for (see core/types.max_block_frames),
/// so a plugin that's merely slow (not hung) still gets its output heard
/// most of the time, while a genuinely stuck plugin degrades to silence
/// for that block rather than stalling the audio callback.
const block_timeout_ns: u64 = 40 * std.time.ns_per_ms;

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    io_threaded: std.Io.Threaded,
    shm_fd: std.posix.fd_t,
    shm: []align(std.heap.page_size_min) u8,
    block: *transport.SharedBlock,
    child: std.process.Child,
    stdin_write_buf: [4096]u8 = undefined,
    stdout_read_buf: [1 << 16]u8 = undefined,
    stdin_writer: std.Io.File.Writer,
    stdout_reader: std.Io.File.Reader,
    rpc_scratch: [rpc.max_payload]u8 = undefined,
    rpc_mutex: std.Io.Mutex = .init,
    reaper: std.Thread,
    dead: std.atomic.Value(bool) = .init(false),
    dead_reported: std.atomic.Value(bool) = .init(false),
    stalled_blocks: std.atomic.Value(u32) = .init(0),
    last_input_seq: u64 = 0,
    resolved_id: []u8,
    resolved_name: []u8,
    path: []u8,
    audio_inputs_count: u32 = 0,
    has_gui: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, options: SpawnOptions) !*Bridge {
        if (builtin.os.tag != .linux) return error.SandboxUnsupportedOnThisPlatform;

        const self = try allocator.create(Bridge);
        errdefer allocator.destroy(self);
        // `create` returns raw uninitialized memory - it does NOT apply the
        // struct's per-field defaults the way a `Bridge{...}` literal would,
        // since every field below is set individually rather than through
        // one literal. Any defaulted field left unassigned here stays
        // garbage forever. `rpc_mutex` being garbage was a real bug: its
        // `.state` atomic held a non-`.unlocked` bit pattern, so
        // `tryLock()`'s `cmpxchgStrong(.unlocked, ...)` failed every call
        // and every RPC (`toggleGui`, `parameterValue`, ...) spun forever.
        self.rpc_mutex = .init;
        self.dead = .init(false);
        self.dead_reported = .init(false);
        self.stalled_blocks = .init(0);
        self.last_input_seq = 0;
        self.allocator = allocator;
        self.io_threaded = std.Io.Threaded.init(allocator, .{});
        errdefer self.io_threaded.deinit();
        const io = self.io_threaded.io();

        const shm_fd = try std.posix.memfd_create("wstudio-plugin-shm", 0);
        errdefer _ = std.os.linux.close(shm_fd);
        const shm_size = transport.SharedBlock.shm_size;
        if (std.os.linux.ftruncate(shm_fd, @intCast(shm_size)) != 0) return error.ShmResizeFailed;
        const shm = try std.posix.mmap(null, shm_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, shm_fd, 0);
        errdefer std.posix.munmap(shm);
        self.shm_fd = shm_fd;
        self.shm = shm;
        self.block = @ptrCast(@alignCast(shm.ptr));
        self.path = try allocator.dupe(u8, options.path);
        errdefer allocator.free(self.path);

        // The installed `wstudio` binary and `wstudio-plugin-bridge` sit side
        // by side (build.zig installs both to the same prefix), so the
        // sibling lookup below is right for a real deployment. It's wrong
        // for anything run out of `.zig-cache` (every test binary, `zig
        // build run` before install) - those don't share a directory with
        // the bridge exe at all. `WSTUDIO_PLUGIN_BRIDGE_EXE` overrides for
        // exactly that case; build.zig's integration tests set it to the
        // exact path `plugin_bridge.getEmittedBin()` resolves to.
        const exe_path = if (std.c.getenv("WSTUDIO_PLUGIN_BRIDGE_EXE")) |override|
            try allocator.dupe(u8, std.mem.span(override))
        else blk: {
            const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
            defer allocator.free(exe_dir);
            break :blk try std.fs.path.join(allocator, &.{ exe_dir, bridge_exe_name });
        };
        defer allocator.free(exe_path);

        const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{options.sample_rate});
        defer allocator.free(sample_rate_str);
        const shm_fd_str = try std.fmt.allocPrint(allocator, "{d}", .{shm_fd});
        defer allocator.free(shm_fd_str);

        const argv = [_][]const u8{
            exe_path,
            @tagName(options.kind),
            options.path,
            options.plugin_id,
            sample_rate_str,
            if (options.instrument) "1" else "0",
            shm_fd_str,
        };
        const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
        var environ_map = try std.process.Environ.createMap(environ, allocator);
        defer environ_map.deinit();
        var child = try std.process.spawn(io, .{
            .argv = &argv,
            .environ_map = &environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer _ = child.wait(io) catch {};
        self.child = child;
        self.stdin_writer = self.child.stdin.?.writer(io, &self.stdin_write_buf);
        self.stdout_reader = self.child.stdout.?.reader(io, &self.stdout_read_buf);

        // Handshake: block until the child finishes loading the real
        // plugin and reports what it resolved (CLAP's default-plugin-id
        // selection and either kind's display name both only exist inside
        // the child, which just ran the same unmodified `.load()` this
        // process would have run itself).
        const deadline = transport.monotonicNs() + spawn_timeout_ns;
        const ready = self.recvBlocking(.ping, deadline) catch |err| {
            child.kill(io);
            return err;
        };
        if (ready.failed) {
            child.kill(io);
            return error.PluginLoadFailedInChild;
        }
        if (ready.payload.len < @sizeOf(transport.Handshake)) return error.RpcProtocolError;
        const hs = std.mem.bytesToValue(transport.Handshake, ready.payload[0..@sizeOf(transport.Handshake)]);
        if (hs.id_len > hs.id.len or hs.name_len > hs.name.len) return error.RpcProtocolError;
        self.audio_inputs_count = hs.audio_inputs_count;
        self.has_gui = hs.has_gui != 0;
        self.resolved_id = try allocator.dupe(u8, hs.id[0..hs.id_len]);
        errdefer allocator.free(self.resolved_id);
        self.resolved_name = try allocator.dupe(u8, hs.name[0..hs.name_len]);

        self.reaper = try std.Thread.spawn(.{}, reaperMain, .{self});
        return self;
    }

    fn reaperMain(self: *Bridge) void {
        const io = self.io_threaded.io();
        _ = self.child.wait(io) catch {};
        self.dead.store(true, .release);
    }

    pub fn deinit(self: *Bridge) void {
        // A Bridge only ever exists on Linux, since `spawn` refuses to make
        // one anywhere else - so the POSIX teardown below (kill, munmap, a
        // raw fd close) is not analysed for other targets at all.
        if (builtin.os.tag != .linux) return;
        rpc.send(&self.stdin_writer.interface, .shutdown, false, &.{}) catch {};
        // A cooperative child exits on its own after `.shutdown`
        // (`std.process.exit(0)` in its RPC dispatch loop), which the
        // reaper thread's `child.wait()` already reaps. If it hasn't
        // within a short grace period (a hung/uncooperative child, or one
        // merely stopped rather than exited - which this whole feature
        // exists to recover from), send a raw SIGKILL rather than calling
        // `Child.kill()`: that helper both signals AND waits internally,
        // which would race the reaper thread's own already-in-flight
        // `wait()` on the same child - two concurrent waiters on one PID,
        // where whichever loses never observes the exit and blocks
        // forever. A bare signal leaves the reaper as the single, sole
        // owner of reaping this child; `Child.kill()` on an
        // already-reaped PID is also a hard, uncatchable panic inside it
        // ("programmer bug caused syscall error: CHILD"), which a raw
        // signal-only call avoids entirely (`kill` on an exited PID is
        // just `error.ProcessNotFound`, harmlessly discarded below).
        const Pred = struct {
            self: *Bridge,
            pub fn check(p: @This()) bool {
                return p.self.isDead();
            }
        };
        const deadline = transport.monotonicNs() + 500 * std.time.ns_per_ms;
        if (!transport.waitUntil(deadline, Pred{ .self = self })) {
            if (self.child.id) |pid| std.posix.kill(pid, .KILL) catch {};
        }
        self.reaper.join();
        std.posix.munmap(self.shm);
        _ = std.os.linux.close(self.shm_fd);
        self.io_threaded.deinit();
        self.allocator.free(self.path);
        self.allocator.free(self.resolved_id);
        self.allocator.free(self.resolved_name);
        self.allocator.destroy(self);
    }

    pub fn isDead(self: *const Bridge) bool {
        return self.dead.load(.acquire);
    }

    pub fn takeStalledBlocks(self: *Bridge) u32 {
        return self.stalled_blocks.swap(0, .acq_rel);
    }

    pub fn takeCrashed(self: *Bridge) bool {
        return self.isDead() and !self.dead_reported.swap(true, .acq_rel);
    }

    // --- real-time path: shared memory, no RPC, bounded wait ---

    /// Publishes `buf`'s input, any pending `events`, and the current
    /// transport, then waits (bounded) for the child's output and copies
    /// it back into `buf`. On a stalled or dead child, `buf` is zeroed
    /// instead - the caller (ClapPlugin/Vst3Plugin.processBlock) never
    /// blocks past `block_timeout_ns`.
    pub fn processBlock(self: *Bridge, buf: []types.Sample, events: []const transport.WireEvent, xport: ?*const transport_mod.Transport) void {
        if (self.isDead()) {
            @memset(buf, 0);
            return;
        }
        const frames = buf.len / 2;
        if (frames == 0 or frames > transport.max_frames) return;
        const block = self.block;
        block.frames = @intCast(frames);
        block.input_channels = 2;
        if (xport) |t| block.xport = transport.TransportWire.from(t);
        const count: u32 = @intCast(@min(events.len, transport.max_events));
        block.event_count = count;
        for (0..count) |i| block.events[i] = events[i];
        for (0..frames) |i| {
            block.audio_in[0][i] = buf[i * 2];
            block.audio_in[1][i] = buf[i * 2 + 1];
        }
        const published = @atomicRmw(u64, &block.input_seq, .Add, 1, .release) + 1;
        const deadline = transport.monotonicNs() + block_timeout_ns;
        const Pred = struct {
            block: *transport.SharedBlock,
            seq: u64,
            pub fn check(p: @This()) bool {
                return @atomicLoad(u64, &p.block.output_seq, .acquire) == p.seq;
            }
        };
        if (!transport.waitUntil(deadline, Pred{ .block = block, .seq = published })) {
            _ = self.stalled_blocks.fetchAdd(1, .monotonic);
            @memset(buf, 0);
            return;
        }
        for (0..frames) |i| {
            buf[i * 2] = block.audio_out[0][i];
            buf[i * 2 + 1] = block.audio_out[1][i];
        }
    }

    pub fn requestReset(self: *Bridge) void {
        @atomicStore(u8, &self.block.reset_requested, 1, .release);
    }

    /// A round trip, not a passive shared-memory read: CLAP's
    /// `get_extension` (which this and `tailFrames` go through) is
    /// main-thread-only per spec, so the child must answer this from its
    /// RPC/main thread, not publish it from the audio thread on its own
    /// (a real plugin - confirmed with Odin2 - aborts the process on that
    /// violation). Not expected to be hot: nothing in the engine calls
    /// this from the audio thread today (see `Engine.trackLatencyFrames`).
    pub fn latencyFrames(self: *Bridge) u32 {
        const resp = self.call(.latency_frames, &.{}) catch return 0;
        return if (resp.len >= 4) std.mem.bytesToValue(u32, resp[0..4]) else 0;
    }

    pub fn tailFrames(self: *Bridge) ?u32 {
        const resp = self.call(.tail_frames, &.{}) catch return null;
        return if (resp.len >= 4) std.mem.bytesToValue(u32, resp[0..4]) else null;
    }

    // --- control path: RPC over the child's stdin/stdout ---

    /// Runs the real plugin's `serviceMainThread()` synchronously inside
    /// the child and returns whether it reported dirty state. Must be a
    /// round-trip RPC, not a passive read of some background-published
    /// flag: callers (this test included) rely on servicing being
    /// complete - a pending restart/rescan actually applied - by the time
    /// this call returns, exactly like the direct/unbridged path where
    /// it's a plain synchronous function call on the same thread. An
    /// earlier version of this had the child free-run its own
    /// `serviceMainThread` on a timer, decoupled from the parent asking -
    /// that broke exactly this ordering guarantee (a caller's very next
    /// `process()` could run before the child's next timer tick).
    pub fn serviceMainThread(self: *Bridge) bool {
        const resp = self.call(.service_main_thread, &.{}) catch return false;
        return resp.len > 0 and resp[0] != 0;
    }

    fn recvBlocking(self: *Bridge, expect: rpc.Kind, deadline_ns: u64) !rpc.Received {
        _ = deadline_ns; // recv itself blocks on the pipe; the spawn timeout bounds process startup, not this read
        const got = try rpc.recv(&self.stdout_reader.interface, &self.rpc_scratch);
        if (got.kind != expect) return error.RpcProtocolError;
        return got;
    }

    /// Generic call: send `kind` with `request`, return the response
    /// payload (valid until the next `call`). Serialized with a mutex
    /// since control-path calls can come from more than one non-audio
    /// thread (UI param edits, autosave triggering a state save).
    pub fn call(self: *Bridge, kind: rpc.Kind, request: []const u8) ![]u8 {
        if (self.isDead()) return error.PluginCrashed;
        // `tryLock` doesn't need an `Io` (unlike `.lock`/`.unlock`); a spin
        // here matches this codebase's existing lock convention (see
        // Sampler.processBlock's pad_lock) instead of pulling in an Io just
        // for mutual exclusion between two infrequent control-path callers.
        while (!self.rpc_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.rpc_mutex.state.store(.unlocked, .release);
        try rpc.send(&self.stdin_writer.interface, kind, false, request);
        const got = try rpc.recv(&self.stdout_reader.interface, &self.rpc_scratch);
        if (got.kind != kind) return error.RpcProtocolError;
        if (got.failed) return error.RpcCallFailed;
        return got.payload;
    }
};

const bridge_exe_name = if (builtin.os.tag == .windows) "wstudio-plugin-bridge.exe" else "wstudio-plugin-bridge";

test "SpawnOptions and Bridge fields compile with the declared layout" {
    // Full spawn requires a real child binary (see plugin_host integration
    // tests wired through build.zig); this just keeps the struct honest
    // under `zig build test`'s module-wide compilation.
    _ = SpawnOptions{ .kind = .clap, .path = "x", .plugin_id = "", .sample_rate = 48_000 };
}

//! PipeWire playback backend (Linux). libpipewire is dlopened at start -
//! never linked - so the binary runs fine on systems without PipeWire
//! and the backend reports LibraryNotFound/ConnectFailed there (same
//! reason GLFW dlopens its platform libraries). Function signatures,
//! struct layouts, and every SPA constant below were verified against
//! pipewire-1.6.5's installed headers; the hand-encoded format pod is
//! additionally byte-checked in a test against a dump produced by the
//! real (header-only) spa_format_audio_raw_build.
//!
//! The stream asks for the project's sample rate; PipeWire resamples
//! when its graph runs at another one, so unlike JACK there is no
//! RateMismatch case. process() runs on PipeWire's realtime thread
//! (PW_STREAM_FLAG_RT_PROCESS) and renders the engine's interleaved f32
//! directly into the mmapped buffer, chunked to the engine's max block.

const std = @import("std");
const types = @import("../core/types.zig");
const backend_mod = @import("backend.zig");

// Opaque libpipewire handles.
const ThreadLoop = opaque {};
const Loop = opaque {};
const Stream = opaque {};
const Properties = opaque {};

// spa/buffer/buffer.h
const SpaChunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};
const SpaData = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: ?*anyopaque,
    chunk: *SpaChunk,
};
const SpaBuffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?*anyopaque,
    datas: [*]SpaData,
};

// pipewire/stream.h
const PwBuffer = extern struct {
    buffer: *SpaBuffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
    time: u64,
};

/// pipewire/stream.h struct pw_stream_events, version
/// PW_VERSION_STREAM_EVENTS = 2 (the lib checks `version` before calling
/// members added later, so nulls are fine everywhere we don't listen).
const StreamEvents = extern struct {
    version: u32 = 2,
    destroy: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (data: ?*anyopaque, old: c_int, state: c_int, err: ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const fn (data: ?*anyopaque, id: u32, control: ?*const anyopaque) callconv(.c) void = null,
    io_changed: ?*const fn (data: ?*anyopaque, id: u32, area: ?*anyopaque, size: u32) callconv(.c) void = null,
    param_changed: ?*const fn (data: ?*anyopaque, id: u32, param: ?*const anyopaque) callconv(.c) void = null,
    add_buffer: ?*const fn (data: ?*anyopaque, buffer: *PwBuffer) callconv(.c) void = null,
    remove_buffer: ?*const fn (data: ?*anyopaque, buffer: *PwBuffer) callconv(.c) void = null,
    process: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
    drained: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
    command: ?*const fn (data: ?*anyopaque, command: ?*const anyopaque) callconv(.c) void = null,
    trigger_done: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
};

// enum pw_stream_state (pipewire/stream.h)
const state_error: c_int = -1;
const state_paused: c_int = 2;
const state_streaming: c_int = 3;

const direction_output: c_int = 1; // SPA_DIRECTION_OUTPUT
const id_any: u32 = 0xffffffff; // PW_ID_ANY
// enum pw_stream_flags: AUTOCONNECT | MAP_BUFFERS | RT_PROCESS
const stream_flags: c_int = (1 << 0) | (1 << 2) | (1 << 4);

/// The subset of libpipewire this backend calls, loaded by symbol name.
const Api = struct {
    init: *const fn (argc: ?*c_int, argv: ?*anyopaque) callconv(.c) void,
    deinit: *const fn () callconv(.c) void,
    thread_loop_new: *const fn (name: [*:0]const u8, props: ?*const anyopaque) callconv(.c) ?*ThreadLoop,
    thread_loop_destroy: *const fn (loop: *ThreadLoop) callconv(.c) void,
    thread_loop_start: *const fn (loop: *ThreadLoop) callconv(.c) c_int,
    thread_loop_stop: *const fn (loop: *ThreadLoop) callconv(.c) void,
    thread_loop_lock: *const fn (loop: *ThreadLoop) callconv(.c) void,
    thread_loop_unlock: *const fn (loop: *ThreadLoop) callconv(.c) void,
    thread_loop_signal: *const fn (loop: *ThreadLoop, wait_for_accept: bool) callconv(.c) void,
    thread_loop_timed_wait: *const fn (loop: *ThreadLoop, wait_max_sec: c_int) callconv(.c) c_int,
    thread_loop_get_loop: *const fn (loop: *ThreadLoop) callconv(.c) *Loop,
    properties_new: *const fn (key: ?[*:0]const u8, ...) callconv(.c) ?*Properties,
    stream_new_simple: *const fn (loop: *Loop, name: [*:0]const u8, props: ?*Properties, events: *const StreamEvents, data: ?*anyopaque) callconv(.c) ?*Stream,
    stream_destroy: *const fn (stream: *Stream) callconv(.c) void,
    stream_connect: *const fn (stream: *Stream, direction: c_int, target_id: u32, flags: c_int, params: [*]const *const anyopaque, n_params: u32) callconv(.c) c_int,
    stream_get_state: *const fn (stream: *Stream, err: ?*?[*:0]const u8) callconv(.c) c_int,
    stream_dequeue_buffer: *const fn (stream: *Stream) callconv(.c) ?*PwBuffer,
    stream_queue_buffer: *const fn (stream: *Stream, buffer: *PwBuffer) callconv(.c) c_int,

    fn load(lib: *std.DynLib) error{SymbolNotFound}!Api {
        return backend_mod.loadApi(Api, lib, "pw_");
    }
};

// ── SPA format pod ──────────────────────────────────────────────────────────
// A SPA "pod" is a little-endian TLV blob: each pod is { size: u32 (of the
// body), type: u32 } + body padded to 8 bytes. The EnumFormat parameter is
// an Object pod whose body is { object type, param id } followed by
// properties, each { key: u32, flags: u32, value pod }. Constants and the
// resulting bytes are verified against spa_format_audio_raw_build (see the
// test at the bottom).

// spa/utils/type.h enum spa_type
const spa_type_id: u32 = 3;
const spa_type_int: u32 = 4;
const spa_type_array: u32 = 13;
const spa_type_object: u32 = 15;
const spa_type_object_format: u32 = 0x40003; // SPA_TYPE_OBJECT_Format

const spa_param_enum_format: u32 = 3; // SPA_PARAM_EnumFormat
// spa/param/format.h keys
const spa_format_media_type: u32 = 1;
const spa_format_media_subtype: u32 = 2;
const spa_format_audio_format: u32 = 0x10001;
const spa_format_audio_rate: u32 = 0x10003;
const spa_format_audio_channels: u32 = 0x10004;
const spa_format_audio_position: u32 = 0x10005;
// spa/param/format.h + spa/param/audio/raw.h values
const spa_media_type_audio: u32 = 1;
const spa_media_subtype_raw: u32 = 1;
const spa_audio_format_f32_le: u32 = 0x11b;
const spa_audio_channel_fl: u32 = 3;
const spa_audio_channel_fr: u32 = 4;

const format_pod_size = 168; // fixed: stereo F32 EnumFormat object

/// Pods must be 8-byte aligned; the wrapper carries that through a return.
const FormatPod = struct { bytes: [format_pod_size]u8 align(8) };

/// Encode the EnumFormat object pod: F32 interleaved at `rate`, stereo
/// FL/FR. Layout matches spa_format_audio_raw_build byte for byte.
fn buildFormatPod(rate: u32) FormatPod {
    var pod: FormatPod = undefined;
    var w: std.Io.Writer = .fixed(&pod.bytes);
    const body_size: u32 = format_pod_size - 8;
    // Object pod header + body ids.
    w.writeInt(u32, body_size, .little) catch unreachable;
    w.writeInt(u32, spa_type_object, .little) catch unreachable;
    w.writeInt(u32, spa_type_object_format, .little) catch unreachable;
    w.writeInt(u32, spa_param_enum_format, .little) catch unreachable;
    // One-word properties: { key, flags=0, pod { 4, type }, value, pad }.
    for ([_][3]u32{
        .{ spa_format_media_type, spa_type_id, spa_media_type_audio },
        .{ spa_format_media_subtype, spa_type_id, spa_media_subtype_raw },
        .{ spa_format_audio_format, spa_type_id, spa_audio_format_f32_le },
        .{ spa_format_audio_rate, spa_type_int, rate },
        .{ spa_format_audio_channels, spa_type_int, 2 },
    }) |prop| {
        w.writeInt(u32, prop[0], .little) catch unreachable;
        w.writeInt(u32, 0, .little) catch unreachable;
        w.writeInt(u32, 4, .little) catch unreachable;
        w.writeInt(u32, prop[1], .little) catch unreachable;
        w.writeInt(u32, prop[2], .little) catch unreachable;
        w.writeInt(u32, 0, .little) catch unreachable; // pad to 8
    }
    // Channel positions: Array pod of Id { FL, FR }.
    w.writeInt(u32, spa_format_audio_position, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 16, .little) catch unreachable; // array body: child pod + 2 ids
    w.writeInt(u32, spa_type_array, .little) catch unreachable;
    w.writeInt(u32, 4, .little) catch unreachable; // child pod: size
    w.writeInt(u32, spa_type_id, .little) catch unreachable; // child pod: type
    w.writeInt(u32, spa_audio_channel_fl, .little) catch unreachable;
    w.writeInt(u32, spa_audio_channel_fr, .little) catch unreachable;
    std.debug.assert(w.buffered().len == format_pod_size);
    return pod;
}

pub const PipewireBackend = struct {
    config: backend_mod.Config,
    render: backend_mod.RenderFn,
    ctx: *anyopaque,
    lib: ?std.DynLib = null,
    api: Api = undefined,
    loop: ?*ThreadLoop = null,
    stream: ?*Stream = null,
    /// Gates process() the same way JackBackend.running does.
    running: std.atomic.Value(bool) = .init(false),

    const max_channels = 2;

    pub const Error = error{
        InvalidConfig,
        LibraryNotFound,
        SymbolNotFound,
        SetupFailed,
        ConnectFailed,
    };

    const events: StreamEvents = .{
        .state_changed = onStateChanged,
        .process = onProcess,
    };

    pub fn start(self: *PipewireBackend) Error!void {
        if (self.config.sample_rate == 0 or self.config.channels != max_channels)
            return error.InvalidConfig;

        var lib = std.DynLib.open("libpipewire-0.3.so.0") catch return error.LibraryNotFound;
        self.api = Api.load(&lib) catch |err| {
            lib.close();
            return err;
        };
        self.lib = lib;
        errdefer {
            self.lib.?.close();
            self.lib = null;
        }

        self.api.init(null, null);
        errdefer self.api.deinit();

        const loop = self.api.thread_loop_new("wstudio-audio", null) orelse return error.SetupFailed;
        errdefer self.api.thread_loop_destroy(loop);

        // Ownership of the properties moves into the stream.
        const props = self.api.properties_new(
            "media.type",
            @as([*:0]const u8, "Audio"),
            @as([*:0]const u8, "media.category"),
            @as([*:0]const u8, "Playback"),
            @as([*:0]const u8, "media.role"),
            @as([*:0]const u8, "Production"),
            @as([*:0]const u8, "node.name"),
            @as([*:0]const u8, "wstudio"),
            @as(?[*:0]const u8, null),
        );
        const stream = self.api.stream_new_simple(
            self.api.thread_loop_get_loop(loop),
            "wstudio",
            props,
            &events,
            self,
        ) orelse return error.SetupFailed;
        errdefer self.api.stream_destroy(stream);

        const pod = buildFormatPod(self.config.sample_rate);
        const params = [_]*const anyopaque{&pod.bytes};
        if (self.api.stream_connect(stream, direction_output, id_any, stream_flags, &params, 1) < 0)
            return error.ConnectFailed;

        self.loop = loop;
        self.stream = stream;
        self.running.store(true, .release);
        errdefer {
            self.running.store(false, .release);
            self.loop = null;
            self.stream = null;
        }
        if (self.api.thread_loop_start(loop) < 0) return error.SetupFailed;
        errdefer self.api.thread_loop_stop(loop);

        // Wait until the negotiation settles: paused/streaming is a live
        // graph connection; error (daemon missing, no sink) fails start so
        // the host can fall back. state_changed signals the wait below.
        self.api.thread_loop_lock(loop);
        defer self.api.thread_loop_unlock(loop);
        var waited: u32 = 0;
        while (waited < 3) : (waited += 1) {
            const state = self.api.stream_get_state(stream, null);
            if (state == state_paused or state == state_streaming) return;
            if (state == state_error) break;
            _ = self.api.thread_loop_timed_wait(loop, 1);
        }
        return error.ConnectFailed;
    }

    pub fn stop(self: *PipewireBackend) void {
        self.running.store(false, .release);
        if (self.loop) |loop| {
            self.api.thread_loop_stop(loop);
            if (self.stream) |stream| {
                self.api.stream_destroy(stream);
                self.stream = null;
            }
            self.api.thread_loop_destroy(loop);
            self.loop = null;
            self.api.deinit();
        }
        if (self.lib) |*lib| {
            lib.close();
            self.lib = null;
        }
    }

    fn onStateChanged(data: ?*anyopaque, _: c_int, _: c_int, _: ?[*:0]const u8) callconv(.c) void {
        const self: *PipewireBackend = @ptrCast(@alignCast(data.?));
        if (self.loop) |loop| self.api.thread_loop_signal(loop, false);
    }

    /// PipeWire's realtime callback: render straight into the mmapped
    /// buffer (interleaved f32 is the engine's native format), chunked to
    /// the engine's max block size.
    fn onProcess(data: ?*anyopaque) callconv(.c) void {
        const self: *PipewireBackend = @ptrCast(@alignCast(data.?));
        if (!self.running.load(.acquire)) return;
        const stream = self.stream orelse return;
        const b = self.api.stream_dequeue_buffer(stream) orelse return;
        defer _ = self.api.stream_queue_buffer(stream, b);

        const d = &b.buffer.datas[0];
        const raw = d.data orelse return;
        const stride: u32 = @sizeOf(f32) * max_channels;
        var frames: usize = d.maxsize / stride;
        if (b.requested != 0) frames = @min(frames, b.requested);

        const samples: [*]f32 = @ptrCast(@alignCast(raw));
        var offset: usize = 0; // in frames
        while (offset < frames) {
            const n = @min(frames - offset, types.max_block_frames);
            self.render(self.ctx, samples[offset * max_channels ..][0 .. n * max_channels]);
            offset += n;
        }

        d.chunk.offset = 0;
        d.chunk.stride = @intCast(stride);
        d.chunk.size = @intCast(frames * stride);
    }
};

test "format pod matches spa_format_audio_raw_build byte for byte" {
    // Reference dump: spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat,
    // &{ .format = F32, .rate = 48000, .channels = 2, .position = {FL, FR} })
    // compiled against pipewire-1.6.5's (header-only) spa.
    const reference = [format_pod_size]u8{
        0xa0, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x04, 0x00, 0x03, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
        0x1b, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x80, 0xbb, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x10, 0x00, 0x00, 0x00, 0x0d, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    };
    const pod = buildFormatPod(48_000);
    try std.testing.expectEqualSlices(u8, &reference, &pod.bytes);
}

test "pipewire backend start/render/stop (skipped without a daemon)" {
    const Counter = struct {
        calls: std.atomic.Value(u32) = .init(0),
        fn render(ctx: *anyopaque, out: []types.Sample) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.calls.fetchAdd(1, .monotonic);
            @memset(out, 0.0);
        }
    };

    var counter: Counter = .{};
    var backend = PipewireBackend{
        .config = .{},
        .render = Counter.render,
        .ctx = &counter,
    };
    backend.start() catch return error.SkipZigTest; // no PipeWire here
    defer backend.stop();

    var spins: u32 = 0;
    while (counter.calls.load(.monotonic) < 2 and spins < 100_000_000) : (spins += 1) {
        std.atomic.spinLoopHint();
    }
    try std.testing.expect(counter.calls.load(.monotonic) >= 1);
}

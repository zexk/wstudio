//! JACK playback backend (Linux). libjack is dlopened at start - never
//! linked - so the binary runs fine on systems without JACK and the
//! backend simply reports NoServer there (same reason GLFW dlopens its
//! platform libraries). The declarations below mirror libjack2's stable
//! C ABI, verified against jack/jack.h + jack/types.h from libjack2
//! 1.9.22; on PipeWire systems pipewire-jack serves the same ABI.
//!
//! JACK is callback-driven on the server's period size and sample rate.
//! The engine renders interleaved f32 at the project rate, so process()
//! chunks the server's nframes to the engine's max block and
//! deinterleaves into the two port buffers. JACK cannot resample, so a
//! server running at a different rate fails start() with RateMismatch -
//! the host then falls back to ALSA, which can.

const std = @import("std");
const types = @import("../core/types.zig");
const backend_mod = @import("backend.zig");

// jack/types.h (libjack2 1.9.22)
const Client = opaque {};
const Port = opaque {};
const Nframes = u32; // jack_nframes_t
const ProcessCallback = *const fn (nframes: Nframes, arg: ?*anyopaque) callconv(.c) c_int;
const ShutdownCallback = *const fn (arg: ?*anyopaque) callconv(.c) void;

const jack_no_start_server: c_int = 0x01; // JackNoStartServer
const port_is_input: c_ulong = 0x1; // JackPortIsInput
const port_is_output: c_ulong = 0x2; // JackPortIsOutput
const port_is_physical: c_ulong = 0x4; // JackPortIsPhysical
const default_audio_type = "32 bit float mono audio"; // JACK_DEFAULT_AUDIO_TYPE

/// The subset of libjack this backend calls, loaded by symbol name.
const Api = struct {
    client_open: *const fn (name: [*:0]const u8, options: c_int, status: ?*c_int, ...) callconv(.c) ?*Client,
    client_close: *const fn (client: *Client) callconv(.c) c_int,
    get_sample_rate: *const fn (client: *Client) callconv(.c) Nframes,
    set_process_callback: *const fn (client: *Client, cb: ProcessCallback, arg: ?*anyopaque) callconv(.c) c_int,
    on_shutdown: *const fn (client: *Client, cb: ShutdownCallback, arg: ?*anyopaque) callconv(.c) void,
    port_register: *const fn (client: *Client, name: [*:0]const u8, port_type: [*:0]const u8, flags: c_ulong, buffer_size: c_ulong) callconv(.c) ?*Port,
    port_get_buffer: *const fn (port: *Port, nframes: Nframes) callconv(.c) ?*anyopaque,
    port_name: *const fn (port: *Port) callconv(.c) [*:0]const u8,
    activate: *const fn (client: *Client) callconv(.c) c_int,
    deactivate: *const fn (client: *Client) callconv(.c) c_int,
    get_ports: *const fn (client: *Client, name_pattern: ?[*:0]const u8, type_pattern: ?[*:0]const u8, flags: c_ulong) callconv(.c) ?[*:null]?[*:0]const u8,
    connect: *const fn (client: *Client, source: [*:0]const u8, destination: [*:0]const u8) callconv(.c) c_int,
    free: *const fn (ptr: ?*anyopaque) callconv(.c) void,

    fn load(lib: *std.DynLib) error{SymbolNotFound}!Api {
        return backend_mod.loadApi(Api, lib, "jack_");
    }
};

pub const JackBackend = struct {
    config: backend_mod.Config,
    render: backend_mod.RenderFn,
    ctx: *anyopaque,
    lib: ?std.DynLib = null,
    api: Api = undefined,
    client: ?*Client = null,
    ports: [max_channels]*Port = undefined,
    /// The server drives the render thread; this only gates process() so a
    /// stop() mid-callback finishes cleanly before deactivate joins it.
    running: std.atomic.Value(bool) = .init(false),
    /// Engine-format staging: the engine renders interleaved, JACK wants
    /// one mono buffer per port.
    buffer: [types.max_block_frames * max_channels]types.Sample = undefined,

    const max_channels = 2;

    pub const Error = error{
        InvalidConfig,
        LibraryNotFound,
        SymbolNotFound,
        NoServer,
        RateMismatch,
        SetupFailed,
    };

    pub fn start(self: *JackBackend) Error!void {
        if (self.config.sample_rate == 0 or self.config.channels == 0 or
            self.config.channels > max_channels)
            return error.InvalidConfig;

        var lib = std.DynLib.open("libjack.so.0") catch return error.LibraryNotFound;
        errdefer lib.close();
        self.api = try Api.load(&lib);

        const client = self.api.client_open("wstudio", jack_no_start_server, null) orelse
            return error.NoServer;
        errdefer _ = self.api.client_close(client);

        if (self.api.get_sample_rate(client) != self.config.sample_rate)
            return error.RateMismatch;

        const port_names = [max_channels][*:0]const u8{ "out_l", "out_r" };
        for (port_names[0..self.config.channels], 0..) |name, i| {
            self.ports[i] = self.api.port_register(client, name, default_audio_type, port_is_output, 0) orelse
                return error.SetupFailed;
        }
        if (self.api.set_process_callback(client, process, self) != 0)
            return error.SetupFailed;
        // A dying server just leaves the stream silent; the shutdown
        // callback only flips `running` so process() stops touching ports.
        self.api.on_shutdown(client, onShutdown, self);

        self.running.store(true, .release);
        if (self.api.activate(client) != 0) {
            self.running.store(false, .release);
            return error.SetupFailed;
        }

        // Wire the outputs to the first physical playback ports, the same
        // out-of-the-box audibility every JACK client is expected to
        // provide. Failure is fine - a patchbay can connect us later.
        if (self.api.get_ports(client, null, default_audio_type, port_is_physical | port_is_input)) |targets| {
            var i: usize = 0;
            while (targets[i]) |target| : (i += 1) {
                if (i >= self.config.channels) break;
                _ = self.api.connect(client, self.api.port_name(self.ports[i]), target);
            }
            self.api.free(@ptrCast(@constCast(targets)));
        }

        self.client = client;
        self.lib = lib;
    }

    pub fn stop(self: *JackBackend) void {
        self.running.store(false, .release);
        if (self.client) |client| {
            _ = self.api.deactivate(client);
            _ = self.api.client_close(client);
            self.client = null;
        }
        if (self.lib) |*lib| {
            lib.close();
            self.lib = null;
        }
    }

    /// JACK's realtime callback: render interleaved in engine-sized chunks,
    /// fan out to the per-channel port buffers.
    fn process(nframes: Nframes, arg: ?*anyopaque) callconv(.c) c_int {
        const self: *JackBackend = @ptrCast(@alignCast(arg.?));
        if (!self.running.load(.acquire)) return 0;
        const channel_count = self.config.channels;

        var outs: [max_channels][*]f32 = undefined;
        for (0..channel_count) |ch| {
            const buf = self.api.port_get_buffer(self.ports[ch], nframes) orelse return 0;
            outs[ch] = @ptrCast(@alignCast(buf));
        }

        var offset: usize = 0; // in frames
        while (offset < nframes) {
            const frames = @min(@as(usize, nframes) - offset, types.max_block_frames);
            const samples = self.buffer[0 .. frames * channel_count];
            self.render(self.ctx, samples);
            for (0..frames) |f| {
                for (0..channel_count) |ch| outs[ch][offset + f] = samples[f * channel_count + ch];
            }
            offset += frames;
        }
        return 0;
    }

    fn onShutdown(arg: ?*anyopaque) callconv(.c) void {
        const self: *JackBackend = @ptrCast(@alignCast(arg.?));
        self.running.store(false, .release);
    }
};

test "jack backend start/render/stop (skipped without a server)" {
    const Counter = struct {
        calls: std.atomic.Value(u32) = .init(0),
        fn render(ctx: *anyopaque, out: []types.Sample) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.calls.fetchAdd(1, .monotonic);
            @memset(out, 0.0);
        }
    };

    var counter: Counter = .{};
    var backend = JackBackend{
        .config = .{},
        .render = Counter.render,
        .ctx = &counter,
    };
    backend.start() catch return error.SkipZigTest; // no JACK server here
    defer backend.stop();

    var spins: u32 = 0;
    while (counter.calls.load(.monotonic) < 2 and spins < 1_000_000) : (spins += 1) {
        std.atomic.spinLoopHint();
    }
    try std.testing.expect(counter.calls.load(.monotonic) >= 1);
}

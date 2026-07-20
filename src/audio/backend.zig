//! Audio backend abstraction.
//!
//! A backend owns the device/driver thread and calls back into the
//! engine for each block. Native backends (ALSA, PipeWire, JACK,
//! CoreAudio) implement this same interface; today only the offline
//! renderer exists, which is also what export/bounce will use.

const std = @import("std");
const types = @import("../core/types.zig");

pub const Config = struct {
    sample_rate: u32 = types.default_sample_rate,
    block_frames: types.FrameCount = types.default_block_frames,
    channels: u16 = 2,
};

/// Fills `out` (interleaved, out.len = block_frames * channels).
pub const RenderFn = *const fn (ctx: *anyopaque, out: []types.Sample) void;

/// Rejects a config a device backend can't render (zero or over-max
/// sample rate/block size/channel count) - shared by every backend's
/// `start` (ALSA, WASAPI, and this file's own NullBackend). The asserts
/// re-confirm the bound `max_channels`/`max_block_frames` a backend's
/// `buffer` field was sized for, since the caller's `max_channels` is
/// whatever it declared its own buffer against.
pub fn validateConfig(config: Config, comptime max_channels: u16) error{InvalidConfig}!void {
    if (config.sample_rate == 0 or config.block_frames == 0 or
        config.channels == 0 or config.channels > max_channels or
        config.block_frames > types.max_block_frames)
        return error.InvalidConfig;
    std.debug.assert(config.channels <= max_channels);
    std.debug.assert(config.block_frames <= types.max_block_frames);
}

/// Loads every field of `Api` from `lib` by symbol name, prefixing each
/// field name with `prefix` - shared by the dlopen'd backends (JACK,
/// PipeWire) whose client libraries expose a flat `<prefix>_<call>` C ABI.
pub fn loadApi(comptime Api: type, lib: *std.DynLib, comptime prefix: []const u8) error{SymbolNotFound}!Api {
    var api: Api = undefined;
    inline for (@typeInfo(Api).@"struct".fields) |field| {
        const sym = lib.lookup(field.type, prefix ++ field.name) orelse return error.SymbolNotFound;
        @field(api, field.name) = sym;
    }
    return api;
}

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque) anyerror!void,
        stop: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(self: Backend) !void {
        return self.vtable.start(self.ptr);
    }

    pub fn stop(self: Backend) void {
        self.vtable.stop(self.ptr);
    }
};

/// Drives the render callback as fast as possible - used for tests and
/// offline export rather than a sound card.
pub const OfflineBackend = struct {
    config: Config,
    render: RenderFn,
    ctx: *anyopaque,

    /// Renders `total_frames` into `out` (caller-allocated,
    /// total_frames * channels samples) in block-sized chunks, exactly
    /// as a device backend would deliver them.
    pub fn renderAll(self: *OfflineBackend, out: []types.Sample) void {
        const ch = self.config.channels;
        const block_samples: usize = @as(usize, self.config.block_frames) * ch;
        // A zero-sized block cannot advance `offset`; treating an invalid
        // offline configuration as a no-op avoids an otherwise infinite
        // render loop.
        if (block_samples == 0) return;
        var offset: usize = 0;
        while (offset < out.len) {
            const end = @min(offset + block_samples, out.len);
            self.render(self.ctx, out[offset..end]);
            offset = end;
        }
    }
};

test "offline backend ignores a zero-sized render block" {
    const Counter = struct {
        fn render(ctx: *anyopaque, out: []types.Sample) void {
            const calls: *u8 = @ptrCast(@alignCast(ctx));
            calls.* += 1;
            @memset(out, 0.0);
        }
    };

    var calls: u8 = 0;
    var backend = OfflineBackend{
        .config = .{ .block_frames = 0 },
        .render = Counter.render,
        .ctx = &calls,
    };
    var out = [_]types.Sample{0.0} ** 4;
    backend.renderAll(&out);
    try std.testing.expectEqual(@as(u8, 0), calls);
}

/// Real-time pacing without a sound card: a thread calls the render
/// callback at wall-clock block rate and discards the audio. Keeps the
/// transport and meters honest until a native device backend lands -
/// which will replace only the inside of `run`.
pub const NullBackend = struct {
    config: Config,
    render: RenderFn,
    ctx: *anyopaque,
    io: std.Io = undefined,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    buffer: [types.max_block_frames * max_channels]types.Sample = undefined,

    const max_channels = 2;

    pub fn start(self: *NullBackend, io: std.Io) !void {
        try validateConfig(self.config, max_channels);
        self.io = io;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *NullBackend) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn run(self: *NullBackend) void {
        const block_samples = @as(usize, self.config.block_frames) * self.config.channels;
        const block_ns: i96 = @intFromFloat(@as(f64, @floatFromInt(self.config.block_frames)) /
            @as(f64, @floatFromInt(self.config.sample_rate)) * std.time.ns_per_s);
        while (self.running.load(.acquire)) {
            self.render(self.ctx, self.buffer[0..block_samples]);
            // Sleeping the full block duration ignores render time, so
            // this drifts slightly slow - fine for a stand-in clock.
            self.io.sleep(.fromNanoseconds(block_ns), .awake) catch return;
        }
    }
};

test "null backend drives the render callback in real time" {
    const Counter = struct {
        calls: std.atomic.Value(u32) = .init(0),
        fn render(ctx: *anyopaque, out: []types.Sample) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.calls.fetchAdd(1, .monotonic);
            @memset(out, 0.0);
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var counter: Counter = .{};
    var backend = NullBackend{
        .config = .{ .block_frames = 64 }, // ~1.3 ms blocks
        .render = Counter.render,
        .ctx = &counter,
    };
    try backend.start(io);
    defer backend.stop();

    var waited: u32 = 0;
    while (counter.calls.load(.monotonic) < 2 and waited < 200) : (waited += 1) {
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expect(counter.calls.load(.monotonic) >= 2);
}

test "null backend rejects an invalid zero sample rate" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var backend = NullBackend{
        .config = .{ .sample_rate = 0 },
        .render = struct {
            fn render(_: *anyopaque, _: []types.Sample) void {}
        }.render,
        .ctx = @ptrFromInt(1),
    };
    try std.testing.expectError(error.InvalidConfig, backend.start(threaded.io()));
}

test "offline backend delivers every frame exactly once" {
    const Counter = struct {
        calls: u32 = 0,
        fn render(ctx: *anyopaque, out: []types.Sample) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            @memset(out, 1.0);
        }
    };

    var counter: Counter = .{};
    var backend = OfflineBackend{
        .config = .{ .block_frames = 256, .channels = 2 },
        .render = Counter.render,
        .ctx = &counter,
    };

    // 1000 frames stereo: 3 full blocks + 1 partial
    var out: [2000]types.Sample = undefined;
    backend.renderAll(&out);

    try std.testing.expectEqual(@as(u32, 4), counter.calls);
    for (out) |s| try std.testing.expectEqual(@as(types.Sample, 1.0), s);
}

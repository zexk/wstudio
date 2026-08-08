//! Backend selection shared by both frontends. Owns one instance of every
//! backend this OS carries and starts the first that works, so the
//! TUI/GUI run loops stay out of the picking business (they used to
//! duplicate it inline; four backends made that untenable).
//!
//! On Linux `auto` tries PipeWire -> JACK -> ALSA: a PipeWire desktop is
//! served natively rather than through its ALSA shim, a plain JACK box
//! gets JACK, everything else lands on ALSA. Both PipeWire and JACK are
//! dlopened by their backends, so a missing library just moves auto down
//! the list. Whatever fails or is left over falls back to the silent
//! wall-clock NullBackend, which keeps the transport honest with no
//! device at all.

const std = @import("std");
const builtin = @import("builtin");
const backend_mod = @import("backend.zig");

const has_linux_backends = builtin.os.tag == .linux;
const has_wasapi = builtin.os.tag == .windows;
const has_coreaudio = builtin.os.tag == .macos;

const PipewireBackend = if (has_linux_backends) @import("pipewire.zig").PipewireBackend else void;
const JackBackend = if (has_linux_backends) @import("jack.zig").JackBackend else void;
const AlsaBackend = if (has_linux_backends) @import("alsa.zig").AlsaBackend else void;
const WasapiBackend = if (has_wasapi) @import("wasapi.zig").WasapiBackend else void;
const CoreAudioBackend = if (has_coreaudio) @import("coreaudio.zig").CoreAudioBackend else void;

/// The user-facing `audio_backend` option (see docs/lua-api.md). The
/// Linux names are ignored on Windows, where anything but `none` means
/// WASAPI; `none` is the silent backend everywhere.
pub const Choice = enum { auto, pipewire, jack, alsa, none };

pub const Active = enum {
    silent,
    pipewire,
    jack,
    alsa,
    wasapi,
    coreaudio,
};

pub const AudioHost = struct {
    config: backend_mod.Config,
    render: backend_mod.RenderFn,
    ctx: *anyopaque,
    pipewire: PipewireBackend,
    jack: JackBackend,
    alsa: AlsaBackend,
    wasapi: WasapiBackend,
    coreaudio: CoreAudioBackend,
    fallback: backend_mod.NullBackend,
    io: std.Io = undefined,
    callback_deadline_misses: std.atomic.Value(u32) = .init(0),
    peak_callback_ns: std.atomic.Value(u64) = .init(0),
    /// Which backend start() landed on; null while stopped.
    active: ?Active = null,

    pub fn init(config: backend_mod.Config, render: backend_mod.RenderFn, ctx: *anyopaque) AudioHost {
        return .{
            .config = config,
            .render = render,
            .ctx = ctx,
            .pipewire = if (has_linux_backends) .{ .config = config, .render = render, .ctx = ctx } else {},
            .jack = if (has_linux_backends) .{ .config = config, .render = render, .ctx = ctx } else {},
            .alsa = if (has_linux_backends) .{ .config = config, .render = render, .ctx = ctx } else {},
            .wasapi = if (has_wasapi) .{ .config = config, .render = render, .ctx = ctx } else {},
            .coreaudio = if (has_coreaudio) .{ .config = config, .render = render, .ctx = ctx } else {},
            .fallback = .{ .config = config, .render = render, .ctx = ctx },
        };
    }

    /// Start chosen backend. Automatic selection with default device may fall
    /// back to silence; explicit backend or device failures propagate.
    pub fn start(self: *AudioHost, io: std.Io, choice: Choice) !void {
        std.debug.assert(self.active == null);
        self.io = io;
        self.configureRenderCallbacks();
        var last_error: ?anyerror = null;
        if (has_linux_backends) {
            switch (choice) {
                .auto => {
                    if (self.pipewire.start()) {
                        self.active = .pipewire;
                    } else |err| {
                        last_error = err;
                    }
                    if (self.active == null) if (self.jack.start()) {
                        self.active = .jack;
                    } else |err| {
                        last_error = err;
                    };
                    if (self.active == null) if (self.alsa.start()) {
                        self.active = .alsa;
                    } else |err| {
                        last_error = err;
                    };
                },
                .pipewire => {
                    if (self.pipewire.start()) {
                        self.active = .pipewire;
                    } else |err| {
                        last_error = err;
                    }
                },
                .jack => {
                    if (self.jack.start()) {
                        self.active = .jack;
                    } else |err| {
                        last_error = err;
                    }
                },
                .alsa => {
                    if (self.alsa.start()) {
                        self.active = .alsa;
                    } else |err| {
                        last_error = err;
                    }
                },
                .none => {},
            }
        } else if (has_wasapi) {
            if (choice != .none) {
                if (self.wasapi.start()) {
                    self.active = .wasapi;
                } else |err| {
                    last_error = err;
                }
            }
        } else if (has_coreaudio) {
            if (choice != .none) {
                if (self.coreaudio.start()) {
                    self.active = .coreaudio;
                } else |err| {
                    last_error = err;
                }
            }
        }
        if (self.active == null) {
            const explicit = self.config.output_device.len > 0 or (choice != .auto and choice != .none);
            if (explicit) return last_error orelse error.AudioBackendUnavailable;
            try self.fallback.start(io);
            self.active = .silent;
        }
    }

    pub const Health = struct { deadline_misses: u32, peak_callback_ns: u64 };

    pub fn takeHealth(self: *AudioHost) Health {
        return .{
            .deadline_misses = self.callback_deadline_misses.swap(0, .acq_rel),
            .peak_callback_ns = self.peak_callback_ns.swap(0, .acq_rel),
        };
    }

    fn configureRenderCallbacks(self: *AudioHost) void {
        if (has_linux_backends) {
            self.pipewire.render = timedRender;
            self.pipewire.ctx = self;
            self.jack.render = timedRender;
            self.jack.ctx = self;
            self.alsa.render = timedRender;
            self.alsa.ctx = self;
        }
        if (has_wasapi) {
            self.wasapi.render = timedRender;
            self.wasapi.ctx = self;
        }
        if (has_coreaudio) {
            self.coreaudio.render = timedRender;
            self.coreaudio.ctx = self;
        }
        self.fallback.render = timedRender;
        self.fallback.ctx = self;
    }

    fn timedRender(raw: *anyopaque, out: []@import("../core/types.zig").Sample) void {
        const self: *AudioHost = @ptrCast(@alignCast(raw));
        const before = std.Io.Clock.awake.now(self.io).nanoseconds;
        self.render(self.ctx, out);
        const after = std.Io.Clock.awake.now(self.io).nanoseconds;
        const elapsed: u64 = @intCast(@max(after - before, 0));
        _ = self.peak_callback_ns.fetchMax(elapsed, .monotonic);
        const frames = out.len / @max(self.config.channels, 1);
        const deadline: u64 = @intFromFloat(@as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(self.config.sample_rate)) * std.time.ns_per_s);
        if (elapsed > deadline) _ = self.callback_deadline_misses.fetchAdd(1, .monotonic);
    }

    pub fn stop(self: *AudioHost) void {
        const active = self.active orelse return;
        self.active = null;
        switch (active) {
            .silent => self.fallback.stop(),
            .pipewire => if (has_linux_backends) self.pipewire.stop() else unreachable,
            .jack => if (has_linux_backends) self.jack.stop() else unreachable,
            .alsa => if (has_linux_backends) self.alsa.stop() else unreachable,
            .wasapi => if (has_wasapi) self.wasapi.stop() else unreachable,
            .coreaudio => if (has_coreaudio) self.coreaudio.stop() else unreachable,
        }
    }

    /// Status-line text, static lifetime.
    pub fn label(self: *const AudioHost) []const u8 {
        return switch (self.active orelse return "none (silent)") {
            .silent => "none (silent)",
            .pipewire => "pipewire",
            .jack => "jack",
            .alsa => "alsa",
            .wasapi => "wasapi",
            .coreaudio => "coreaudio",
        };
    }
};

test "audio host honors the explicit none choice" {
    const Silent = struct {
        fn render(_: *anyopaque, out: []@import("../core/types.zig").Sample) void {
            @memset(out, 0.0);
        }
    };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var host = AudioHost.init(.{}, Silent.render, @ptrFromInt(16));
    try host.start(threaded.io(), .none);
    defer host.stop();
    try std.testing.expectEqual(@as(?Active, .silent), host.active);
    try std.testing.expectEqualStrings("none (silent)", host.label());
}

test "audio host reports callback deadline misses and resets peak" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Slow = struct {
        fn render(ctx: *anyopaque, out: []@import("../core/types.zig").Sample) void {
            const clock: *std.Io = @ptrCast(@alignCast(ctx));
            clock.sleep(.fromMilliseconds(2), .awake) catch {};
            @memset(out, 0.0);
        }
    };
    var io_copy = io;
    var host = AudioHost.init(.{ .sample_rate = 48_000, .block_frames = 1 }, Slow.render, &io_copy);
    host.io = io;
    var out: [2]@import("../core/types.zig").Sample = undefined;
    host.timedRender(&out);

    const health = host.takeHealth();
    try std.testing.expectEqual(@as(u32, 1), health.deadline_misses);
    try std.testing.expect(health.peak_callback_ns >= std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 0), host.takeHealth().peak_callback_ns);
}

test "audio host propagates explicit backend configuration errors" {
    if (!has_linux_backends) return error.SkipZigTest;
    const Silent = struct {
        fn render(_: *anyopaque, out: []@import("../core/types.zig").Sample) void {
            @memset(out, 0.0);
        }
    };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var host = AudioHost.init(.{ .sample_rate = 0 }, Silent.render, @ptrFromInt(16));
    try std.testing.expectError(error.InvalidConfig, host.start(threaded.io(), .alsa));
    try std.testing.expectEqual(@as(?Active, null), host.active);
}

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

const PipewireBackend = if (has_linux_backends) @import("pipewire.zig").PipewireBackend else void;
const JackBackend = if (has_linux_backends) @import("jack.zig").JackBackend else void;
const AlsaBackend = if (has_linux_backends) @import("alsa.zig").AlsaBackend else void;
const WasapiBackend = if (has_wasapi) @import("wasapi.zig").WasapiBackend else void;

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
};

pub const AudioHost = struct {
    config: backend_mod.Config,
    render: backend_mod.RenderFn,
    ctx: *anyopaque,
    pipewire: PipewireBackend,
    jack: JackBackend,
    alsa: AlsaBackend,
    wasapi: WasapiBackend,
    fallback: backend_mod.NullBackend,
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
            .fallback = .{ .config = config, .render = render, .ctx = ctx },
        };
    }

    /// Start the chosen backend, falling back to the silent NullBackend
    /// when the choice (or every `auto` candidate) fails. Only the
    /// fallback's own failure propagates - a session without a device is
    /// fine, a session without a clock is not.
    pub fn start(self: *AudioHost, io: std.Io, choice: Choice) !void {
        std.debug.assert(self.active == null);
        if (has_linux_backends) {
            switch (choice) {
                .auto => {
                    if (self.pipewire.start()) {
                        self.active = .pipewire;
                    } else |_| if (self.jack.start()) {
                        self.active = .jack;
                    } else |_| if (self.alsa.start()) {
                        self.active = .alsa;
                    } else |_| {}
                },
                .pipewire => if (self.pipewire.start()) {
                    self.active = .pipewire;
                } else |_| {},
                .jack => if (self.jack.start()) {
                    self.active = .jack;
                } else |_| {},
                .alsa => if (self.alsa.start()) {
                    self.active = .alsa;
                } else |_| {},
                .none => {},
            }
        } else if (has_wasapi) {
            if (choice != .none) {
                if (self.wasapi.start()) {
                    self.active = .wasapi;
                } else |_| {}
            }
        }
        if (self.active == null) {
            try self.fallback.start(io);
            self.active = .silent;
        }
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

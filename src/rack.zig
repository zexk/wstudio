const std = @import("std");
const dsp = @import("dsp/device.zig");
const PolySynth = @import("dsp/synth.zig").PolySynth;
const Compressor = @import("dsp/compressor.zig").Compressor;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const GraphicEq = @import("dsp/eq.zig").GraphicEq;

/// A signal source: generates audio from MIDI events.
/// Add new synthesiser/sampler variants here as the engine grows.
pub const Instrument = union(enum) {
    poly_synth: PolySynth,

    /// Returns a dsp.Device fat-pointer whose `.ptr` is stable as long as
    /// the parent Rack (heap-allocated) is alive.
    pub fn device(self: *Instrument) dsp.Device {
        switch (self.*) {
            .poly_synth => |*s| return s.device(),
        }
    }
};

/// Fixed set of optional signal processors applied in series after the
/// instrument. Order in chain(): comp → eq → delay → reverb.
pub const Fx = struct {
    eq: ?GraphicEq = null,
    comp: ?Compressor = null,
    delay: ?StereoDelay = null,
    reverb: ?Reverb = null,

    pub fn deinit(self: *Fx, allocator: std.mem.Allocator) void {
        if (self.delay) |*d| d.deinit(allocator);
        if (self.reverb) |*r| r.deinit(allocator);
    }
};

pub const Rack = struct {
    instrument: Instrument,
    fx: Fx = .{},
    label: []const u8,

    pub fn deinit(self: *Rack, allocator: std.mem.Allocator) void {
        self.fx.deinit(allocator);
    }

    /// Fills `buf` with [instrument, ...fx] in signal-flow order and returns
    /// the used slice. Caller must keep `buf` alive for as long as the slice
    /// is passed to the engine.
    pub fn chain(self: *Rack, buf: *[5]dsp.Device) []const dsp.Device {
        var len: usize = 0;
        buf[len] = self.instrument.device();
        len += 1;
        if (self.fx.comp) |*c| { buf[len] = c.device(); len += 1; }
        if (self.fx.eq)   |*e| { buf[len] = e.device(); len += 1; }
        if (self.fx.delay) |*d| { buf[len] = d.device(); len += 1; }
        if (self.fx.reverb)|*r| { buf[len] = r.device(); len += 1; }
        return buf[0..len];
    }
};

test "chain order is instrument → comp → eq → delay → reverb" {
    const std2 = @import("std");
    _ = std2;
    var rack = Rack{
        .instrument = .{ .poly_synth = PolySynth.init(48_000) },
        .fx = .{
            .comp   = Compressor.init(48_000),
            .eq     = GraphicEq.init(48_000),
        },
        .label = "test",
    };
    var buf: [5]dsp.Device = undefined;
    const ch = rack.chain(&buf);

    try std.testing.expectEqual(@as(usize, 3), ch.len);
    // Instrument first
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.instrument.poly_synth)),
        ch[0].ptr,
    );
    // Compressor before EQ
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.fx.comp.?)),
        ch[1].ptr,
    );
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.fx.eq.?)),
        ch[2].ptr,
    );
}

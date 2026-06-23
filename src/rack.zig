const std = @import("std");
const dsp = @import("dsp/device.zig");
const PolySynth = @import("dsp/synth.zig").PolySynth;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const Compressor = @import("dsp/compressor.zig").Compressor;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const GraphicEq = @import("dsp/eq.zig").GraphicEq;
const PatternPlayer = @import("dsp/pattern.zig").PatternPlayer;

/// A signal source: generates audio from MIDI events.
/// Add new synthesiser/sampler variants here as the engine grows.
pub const Instrument = union(enum) {
    poly_synth: PolySynth,
    /// DrumMachine stores its own allocator; deinit() needs no external one.
    /// The DrumMachine's internal `transport` pointer stays valid because the
    /// engine (and therefore its Transport) is heap-allocated.
    drum_machine: DrumMachine,

    /// Returns a dsp.Device fat-pointer whose `.ptr` is stable as long as
    /// the parent Rack (heap-allocated) is alive.
    pub fn device(self: *Instrument) dsp.Device {
        switch (self.*) {
            .poly_synth    => |*s|  return s.device(),
            .drum_machine  => |*dm| return dm.device(),
        }
    }

    pub fn deinit(self: *Instrument) void {
        switch (self.*) {
            .poly_synth   => {},           // no heap allocations
            .drum_machine => |*dm| dm.deinit(),
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
        if (self.delay)  |*d| d.deinit(allocator);
        if (self.reverb) |*r| r.deinit(allocator);
    }
};

pub const Rack = struct {
    instrument: Instrument,
    fx: Fx = .{},
    label: []const u8,
    /// Piano-roll sequencer. Set after the Rack lands on the heap so the
    /// self-referential synth pointer is stable.
    pattern_player: ?PatternPlayer = null,

    pub fn deinit(self: *Rack, allocator: std.mem.Allocator) void {
        self.instrument.deinit();
        self.fx.deinit(allocator);
    }

    /// Fills `buf` with [pattern_player?, instrument, ...fx] in signal-flow
    /// order and returns the used slice. Caller must keep `buf` alive for as
    /// long as the slice is passed to the engine.
    pub fn chain(self: *Rack, buf: *[6]dsp.Device) []const dsp.Device {
        var len: usize = 0;
        if (self.pattern_player) |*pp| { buf[len] = pp.device(); len += 1; }
        buf[len] = self.instrument.device();
        len += 1;
        if (self.fx.comp)   |*c| { buf[len] = c.device(); len += 1; }
        if (self.fx.eq)     |*e| { buf[len] = e.device(); len += 1; }
        if (self.fx.delay)  |*d| { buf[len] = d.device(); len += 1; }
        if (self.fx.reverb) |*r| { buf[len] = r.device(); len += 1; }
        return buf[0..len];
    }
};

test "chain order is instrument → comp → eq → delay → reverb (no pattern player)" {
    var rack = Rack{
        .instrument = .{ .poly_synth = PolySynth.init(48_000) },
        .fx = .{
            .comp = Compressor.init(48_000),
            .eq   = GraphicEq.init(48_000),
        },
        .label = "test",
    };
    var buf: [6]dsp.Device = undefined;
    const ch = rack.chain(&buf);

    // No pattern_player → synth at [0], comp at [1], eq at [2].
    try std.testing.expectEqual(@as(usize, 3), ch.len);
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.instrument.poly_synth)), ch[0].ptr,
    );
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.fx.comp.?)), ch[1].ptr,
    );
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.fx.eq.?)), ch[2].ptr,
    );
}

test "drum_machine Instrument variant: device ptr stable inside heap Rack" {
    const Transport = @import("transport.zig").Transport;
    var transport: Transport = .{ .sample_rate = 48_000 };

    const rack = try std.testing.allocator.create(Rack);
    defer { rack.deinit(std.testing.allocator); std.testing.allocator.destroy(rack); }

    rack.* = .{
        .instrument = .{ .drum_machine = try DrumMachine.init(
            std.testing.allocator, 48_000, &transport,
        ) },
        .label = "drums",
    };

    var buf: [6]dsp.Device = undefined;
    const ch = rack.chain(&buf);

    try std.testing.expectEqual(@as(usize, 1), ch.len);
    // device() must point into the heap-allocated Rack, not a stack copy
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.instrument.drum_machine)), ch[0].ptr,
    );
}

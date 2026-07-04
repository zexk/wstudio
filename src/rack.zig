const std = @import("std");
const dsp = @import("dsp/device.zig");
const PolySynth = @import("dsp/synth.zig").PolySynth;
const Sampler = @import("dsp/sampler.zig").Sampler;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const Compressor = @import("dsp/compressor.zig").Compressor;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const GraphicEq = @import("dsp/eq.zig").GraphicEq;
const PatternPlayer = @import("dsp/pattern.zig").PatternPlayer;
const Transport = @import("transport.zig").Transport;

/// A signal source: generates audio from MIDI events.
/// Add new synthesiser/sampler variants here as the engine grows.
/// `empty` is a track with no instrument inserted yet — it produces no
/// device, so `chain()` omits it and the engine renders the track silent.
pub const Instrument = union(enum) {
    empty,
    poly_synth: PolySynth,
    /// Single-clip chromatic sampler. Owns its clip; deinit frees it.
    sampler: Sampler,
    /// DrumMachine stores its own allocator; deinit() needs no external one.
    /// The DrumMachine's internal `transport` pointer stays valid because the
    /// engine (and therefore its Transport) is heap-allocated.
    drum_machine: DrumMachine,

    /// Returns a dsp.Device fat-pointer whose `.ptr` is stable as long as
    /// the parent Rack (heap-allocated) is alive, or null for `empty`.
    pub fn device(self: *Instrument) ?dsp.Device {
        switch (self.*) {
            .empty         => return null,
            .poly_synth    => |*s|  return s.device(),
            .sampler       => |*s|  return s.device(),
            .drum_machine  => |*dm| return dm.device(),
        }
    }

    pub fn deinit(self: *Instrument) void {
        switch (self.*) {
            .empty        => {},
            .poly_synth   => {},           // no heap allocations
            .sampler      => |*s|  s.deinit(),
            .drum_machine => |*dm| dm.deinit(),
        }
    }
};

/// The instrument variants, as a plain enum — used by the instrument picker
/// and `Session.setInstrument` to name a kind without a payload.
pub const InstrumentKind = std.meta.Tag(Instrument);

/// Fixed set of optional signal processors applied in series after the
/// instrument. Order in chain(): comp → eq → delay → reverb. Shared by every
/// track's Rack and the engine's master bus (Session.master_fx) — the same
/// four stages plug into either one the same way, in the same order.
pub const Fx = struct {
    eq: ?GraphicEq = null,
    comp: ?Compressor = null,
    delay: ?StereoDelay = null,
    reverb: ?Reverb = null,

    pub fn deinit(self: *Fx, allocator: std.mem.Allocator) void {
        if (self.delay)  |*d| d.deinit(allocator);
        if (self.reverb) |*r| r.deinit(allocator);
    }

    /// Fills `buf` with the active stages in signal-flow order and returns
    /// the used slice.
    pub fn chain(self: *Fx, buf: *[4]dsp.Device) []const dsp.Device {
        var len: usize = 0;
        if (self.comp)   |*c| { buf[len] = c.device(); len += 1; }
        if (self.eq)     |*e| { buf[len] = e.device(); len += 1; }
        if (self.delay)  |*d| { buf[len] = d.device(); len += 1; }
        if (self.reverb) |*r| { buf[len] = r.device(); len += 1; }
        return buf[0..len];
    }
};

pub const Rack = struct {
    instrument: Instrument,
    fx: Fx = .{},
    label: []const u8,
    /// True when `label` was heap-allocated (e.g. loaded from a project file)
    /// and must be freed in deinit. False for string-literal labels.
    owned_label: bool = false,
    /// Piano-roll sequencer. Set after the Rack lands on the heap so the
    /// self-referential synth pointer is stable.
    pattern_player: ?PatternPlayer = null,

    pub fn deinit(self: *Rack, allocator: std.mem.Allocator) void {
        if (self.owned_label) allocator.free(self.label);
        self.instrument.deinit();
        self.fx.deinit(allocator);
    }

    /// Deep-copies this rack for track duplication: fresh heap allocations
    /// for every owned buffer (pad audio, delay/reverb lines) so the two
    /// racks share no memory and can be torn down independently. FX buffer
    /// *contents* (reverb tail, delay line) aren't preserved — only their
    /// parameters — matching what project save/load already does.
    pub fn dupe(self: *const Rack, allocator: std.mem.Allocator, sr: u32, transport: *const Transport) !*Rack {
        const rack = try allocator.create(Rack);
        errdefer allocator.destroy(rack);
        rack.* = .{
            .instrument = .empty,
            .label = try allocator.dupe(u8, self.label),
            .owned_label = true,
        };
        errdefer rack.deinit(allocator);

        switch (self.instrument) {
            .empty => {},
            .poly_synth => |s| rack.instrument = .{ .poly_synth = s },
            .sampler => |*s| rack.instrument = .{ .sampler = try s.dupe() },
            .drum_machine => |*dm| rack.instrument = .{ .drum_machine = try dm.dupe() },
        }
        // Set AFTER the instrument lands in the heap rack — the player holds
        // a pointer into it (same rule as Session.setInstrument).
        if (self.pattern_player) |*pp| {
            var new_pp = PatternPlayer.init(rack.instrument.device().?, transport);
            new_pp.note_count = pp.note_count;
            new_pp.notes = pp.notes;
            new_pp.length_beats = pp.length_beats;
            rack.pattern_player = new_pp;
        }

        if (self.fx.comp) |c| rack.fx.comp = c;
        if (self.fx.eq) |e| rack.fx.eq = e;
        if (self.fx.delay) |d| {
            var nd = try StereoDelay.init(allocator, sr, 2.0);
            nd.delay_frames = d.delay_frames;
            nd.feedback = d.feedback;
            nd.mix = d.mix;
            rack.fx.delay = nd;
        }
        if (self.fx.reverb) |r| {
            var nr = try Reverb.init(allocator, sr);
            nr.mix = r.mix;
            nr.room = r.room;
            nr.damp = r.damp;
            rack.fx.reverb = nr;
        }

        return rack;
    }

    /// Fills `buf` with [pattern_player?, instrument, ...fx] in signal-flow
    /// order and returns the used slice. Caller must keep `buf` alive for as
    /// long as the slice is passed to the engine.
    pub fn chain(self: *Rack, buf: *[6]dsp.Device) []const dsp.Device {
        var len: usize = 0;
        if (self.pattern_player) |*pp| { buf[len] = pp.device(); len += 1; }
        if (self.instrument.device()) |dev| { buf[len] = dev; len += 1; }
        var fx_buf: [4]dsp.Device = undefined;
        for (self.fx.chain(&fx_buf)) |dev| { buf[len] = dev; len += 1; }
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

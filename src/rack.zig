const std = @import("std");
const dsp = @import("dsp/device.zig");
const PolySynth = @import("dsp/synth.zig").PolySynth;
const Sampler = @import("dsp/sampler.zig").Sampler;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const Compressor = @import("dsp/compressor.zig").Compressor;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const GraphicEq = @import("dsp/eq.zig").GraphicEq;
const Gate = @import("dsp/gate.zig").Gate;
const Saturator = @import("dsp/saturator.zig").Saturator;
const Crusher = @import("dsp/crusher.zig").Crusher;
const Chorus = @import("dsp/chorus.zig").Chorus;
const Phaser = @import("dsp/phaser.zig").Phaser;
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

/// One effect processor a chain slot can hold. Add new unit variants here as
/// the engine grows — the TUI's picker and persistence key off `FxKind`.
/// chorus/delay/reverb own heap buffers (mod/delay lines); deinit frees them.
pub const FxPayload = union(enum) {
    gate: Gate,
    comp: Compressor,
    eq: GraphicEq,
    sat: Saturator,
    crush: Crusher,
    chorus: Chorus,
    phaser: Phaser,
    delay: StereoDelay,
    reverb: Reverb,

    /// Returns a dsp.Device fat-pointer whose `.ptr` is stable as long as
    /// the parent FxUnit (heap-allocated by Fx.insert) is alive.
    pub fn device(self: *FxPayload) dsp.Device {
        return switch (self.*) {
            .gate   => |*g| g.device(),
            .comp   => |*c| c.device(),
            .eq     => |*e| e.device(),
            .sat    => |*s| s.device(),
            .crush  => |*c| c.device(),
            .chorus => |*c| c.device(),
            .phaser => |*p| p.device(),
            .delay  => |*d| d.device(),
            .reverb => |*r| r.device(),
        };
    }

    pub fn deinit(self: *FxPayload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .chorus => |*c| c.deinit(allocator),
            .delay  => |*d| d.deinit(allocator),
            .reverb => |*r| r.deinit(allocator),
            else => {},
        }
    }
};

/// The effect variants as a plain enum — names a kind without a payload,
/// same role InstrumentKind plays for instruments.
pub const FxKind = std.meta.Tag(FxPayload);

/// One inserted chain slot. Heap-allocated by `Fx.insert` so the device
/// pointer the engine holds stays stable across chain edits (insert, remove,
/// reorder only shuffle the pointer list, never move the unit itself).
pub const FxUnit = struct {
    payload: FxPayload,
    /// Bypassed units keep their state but are skipped by `chain()`.
    bypassed: bool = false,

    pub fn kind(self: *const FxUnit) FxKind {
        return std.meta.activeTag(self.payload);
    }
};

/// User-built effect chain: an ordered list of inserted units, applied in
/// series after the instrument. Starts empty; the user inserts units where
/// they want them (duplicates allowed), reorders, bypasses, and removes.
/// Shared by every track's Rack and the engine's master bus
/// (Session.master_fx) — the same units plug into either one the same way.
pub const Fx = struct {
    units: std.ArrayListUnmanaged(*FxUnit) = .empty,

    /// Chain slot cap; sizes every `chain()` scratch buffer (and keeps the
    /// TUI's chain strip inside 80 columns).
    pub const max_units = 9;

    /// A fresh payload of `kind` with its defaults. Only chorus/delay/reverb
    /// allocate (their mod/delay lines).
    pub fn initPayload(allocator: std.mem.Allocator, kind: FxKind, sr: u32) !FxPayload {
        return switch (kind) {
            .gate   => .{ .gate = Gate.init(sr) },
            .comp   => .{ .comp = Compressor.init(sr) },
            .eq     => .{ .eq = GraphicEq.init(sr) },
            .sat    => .{ .sat = .{} },
            .crush  => .{ .crush = .{} },
            .chorus => .{ .chorus = try Chorus.init(allocator, sr) },
            .phaser => .{ .phaser = Phaser.init(sr) },
            .delay  => .{ .delay = try StereoDelay.init(allocator, sr, 2.0) },
            .reverb => .{ .reverb = try Reverb.init(allocator, sr) },
        };
    }

    /// Insert a fresh `kind` unit (defaults) at `pos`, clamped to the chain
    /// end. Fails without touching the chain on `error.ChainFull` / OOM.
    pub fn insert(self: *Fx, allocator: std.mem.Allocator, pos: usize, kind: FxKind, sr: u32) !*FxUnit {
        if (self.units.items.len >= max_units) return error.ChainFull;
        const unit = try allocator.create(FxUnit);
        errdefer allocator.destroy(unit);
        unit.* = .{ .payload = try initPayload(allocator, kind, sr) };
        errdefer unit.payload.deinit(allocator);
        try self.units.insert(allocator, @min(pos, self.units.items.len), unit);
        return unit;
    }

    /// Remove and free the unit at `idx`. Push the new chain to the engine
    /// (setTrackChain/syncMasterChain) in the same control-thread breath.
    pub fn remove(self: *Fx, allocator: std.mem.Allocator, idx: usize) void {
        if (idx >= self.units.items.len) return;
        const unit = self.units.orderedRemove(idx);
        unit.payload.deinit(allocator);
        allocator.destroy(unit);
    }

    /// Swap two slots' positions. Unit memory never moves, so the engine's
    /// device pointers stay valid; re-sync the chain to apply the new order.
    pub fn swap(self: *Fx, a: usize, b: usize) void {
        if (a == b or a >= self.units.items.len or b >= self.units.items.len) return;
        std.mem.swap(*FxUnit, &self.units.items[a], &self.units.items[b]);
    }

    /// First unit of `kind` in chain order, or null — for the `:eq` /
    /// `:master-comp` command paths that address a unit by name.
    pub fn find(self: *const Fx, kind: FxKind) ?*FxUnit {
        const i = self.findIdx(kind) orelse return null;
        return self.units.items[i];
    }

    /// Index of the first unit of `kind`, or null.
    pub fn findIdx(self: *const Fx, kind: FxKind) ?usize {
        for (self.units.items, 0..) |u, i| if (u.kind() == kind) return i;
        return null;
    }

    pub fn deinit(self: *Fx, allocator: std.mem.Allocator) void {
        for (self.units.items) |u| {
            u.payload.deinit(allocator);
            allocator.destroy(u);
        }
        self.units.deinit(allocator);
    }

    /// Fills `buf` with the non-bypassed units in chain order and returns
    /// the used slice.
    pub fn chain(self: *Fx, buf: *[max_units]dsp.Device) []const dsp.Device {
        var len: usize = 0;
        for (self.units.items) |u| {
            if (u.bypassed) continue;
            buf[len] = u.payload.device();
            len += 1;
        }
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
            new_pp.swing.store(pp.swing.load(.monotonic), .monotonic);
            rack.pattern_player = new_pp;
        }

        for (self.fx.units.items) |u| {
            const nu = try allocator.create(FxUnit);
            errdefer allocator.destroy(nu);
            nu.* = .{ .payload = try dupePayload(&u.payload, allocator, sr), .bypassed = u.bypassed };
            errdefer nu.payload.deinit(allocator);
            try rack.fx.units.append(allocator, nu);
        }

        return rack;
    }

    /// Deep-copies one FX payload: chorus/delay/reverb get fresh lines (only
    /// their params carry over, same as save/load); the rest are plain value
    /// state and copy directly.
    fn dupePayload(p: *const FxPayload, allocator: std.mem.Allocator, sr: u32) !FxPayload {
        switch (p.*) {
            .chorus => |c| {
                var nc = try Chorus.init(allocator, sr);
                nc.rate_hz = c.rate_hz;
                nc.depth_ms = c.depth_ms;
                nc.mix = c.mix;
                return .{ .chorus = nc };
            },
            .delay => |d| {
                var nd = try StereoDelay.init(allocator, sr, 2.0);
                nd.delay_frames = d.delay_frames;
                nd.feedback = d.feedback;
                nd.mix = d.mix;
                return .{ .delay = nd };
            },
            .reverb => |r| {
                var nr = try Reverb.init(allocator, sr);
                nr.mix = r.mix;
                nr.room = r.room;
                nr.damp = r.damp;
                return .{ .reverb = nr };
            },
            else => return p.*,
        }
    }

    /// Capacity every `chain()` scratch buffer needs: pattern player +
    /// instrument + a full FX chain.
    pub const chain_cap = Fx.max_units + 2;

    /// Fills `buf` with [pattern_player?, instrument, ...fx] in signal-flow
    /// order and returns the used slice. Caller must keep `buf` alive for as
    /// long as the slice is passed to the engine.
    pub fn chain(self: *Rack, buf: *[chain_cap]dsp.Device) []const dsp.Device {
        var len: usize = 0;
        if (self.pattern_player) |*pp| { buf[len] = pp.device(); len += 1; }
        if (self.instrument.device()) |dev| { buf[len] = dev; len += 1; }
        var fx_buf: [Fx.max_units]dsp.Device = undefined;
        for (self.fx.chain(&fx_buf)) |dev| { buf[len] = dev; len += 1; }
        return buf[0..len];
    }
};

test "chain follows insertion order, not a fixed slot order" {
    var rack = Rack{
        .instrument = .{ .poly_synth = PolySynth.init(48_000) },
        .label = "test",
    };
    defer rack.fx.deinit(std.testing.allocator);

    // Insert an EQ, then a comp *in front of it* — the old fixed rack would
    // have forced comp → eq; the chain must play them as ordered.
    const eq   = try rack.fx.insert(std.testing.allocator, 0, .eq, 48_000);
    const comp = try rack.fx.insert(std.testing.allocator, 0, .comp, 48_000);

    var buf: [Rack.chain_cap]dsp.Device = undefined;
    const ch = rack.chain(&buf);

    // No pattern_player → synth at [0], comp at [1], eq at [2].
    try std.testing.expectEqual(@as(usize, 3), ch.len);
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.instrument.poly_synth)), ch[0].ptr,
    );
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&comp.payload.comp)), ch[1].ptr,
    );
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&eq.payload.eq)), ch[2].ptr,
    );
}

test "Fx: duplicates allowed, bypass skips, remove frees, cap enforced" {
    const allocator = std.testing.allocator;
    var fx: Fx = .{};
    defer fx.deinit(allocator);

    // Two saturators in one chain — impossible with the fixed rack.
    _ = try fx.insert(allocator, 0, .sat, 48_000);
    _ = try fx.insert(allocator, 1, .sat, 48_000);
    var buf: [Fx.max_units]dsp.Device = undefined;
    try std.testing.expectEqual(@as(usize, 2), fx.chain(&buf).len);

    fx.units.items[0].bypassed = true;
    try std.testing.expectEqual(@as(usize, 1), fx.chain(&buf).len);

    fx.remove(allocator, 0);
    try std.testing.expectEqual(@as(usize, 1), fx.units.items.len);
    try std.testing.expectEqual(FxKind.sat, fx.units.items[0].kind());

    for (fx.units.items.len..Fx.max_units) |_| _ = try fx.insert(allocator, 0, .crush, 48_000);
    try std.testing.expectError(error.ChainFull, fx.insert(allocator, 0, .gate, 48_000));
}

test "Fx.swap reorders without moving unit memory" {
    const allocator = std.testing.allocator;
    var fx: Fx = .{};
    defer fx.deinit(allocator);

    const a = try fx.insert(allocator, 0, .comp, 48_000);
    const b = try fx.insert(allocator, 1, .eq, 48_000);
    fx.swap(0, 1);
    try std.testing.expectEqual(b, fx.units.items[0]);
    try std.testing.expectEqual(a, fx.units.items[1]);

    var buf: [Fx.max_units]dsp.Device = undefined;
    const ch = fx.chain(&buf);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&b.payload.eq)), ch[0].ptr);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&a.payload.comp)), ch[1].ptr);
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

    var buf: [Rack.chain_cap]dsp.Device = undefined;
    const ch = rack.chain(&buf);

    try std.testing.expectEqual(@as(usize, 1), ch.len);
    // device() must point into the heap-allocated Rack, not a stack copy
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.instrument.drum_machine)), ch[0].ptr,
    );
}

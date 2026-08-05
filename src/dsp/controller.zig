//! Free-floating modulation controllers: an LFO that lives on the project
//! rather than inside one instrument, driving any number of instrument or FX
//! params across any number of tracks.
//!
//! The synth's own mod matrix (dsp/synth.zig) can only reach the voice it
//! belongs to, and an automation lane (dsp/automation.zig) is a hand-drawn
//! shape on one clip. This is the third case: one shared movement - a filter
//! sweep, a tremolo, a slow drift - wired to several knobs at once, so
//! retuning it retunes all of them.
//!
//! Phase comes from the song's beat position, not a free-running
//! accumulator: a controller is a musical shape, so it must land on the same
//! beat every pass and survive a transport jump or a reload. That also makes
//! it stateless, which is why the engine can hold these as plain values with
//! no per-block bookkeeping.

const std = @import("std");
const lfo = @import("lfo.zig");

/// Slots per project. Small fixed bank, same call as the engine's
/// `max_groups`/`max_sends_per_track`: a sweep, a tremolo and a drift is the
/// realistic ceiling, not a growable rack.
pub const max_controllers: u8 = 4;
/// Knobs one controller can drive. Past this a second controller is the
/// clearer answer than a longer list.
pub const max_targets: u8 = 8;

/// One driven param. `instance_id` follows the same convention automation
/// lanes use: 0 targets the track's own instrument (`param_id` is a
/// `setParamAbsolute` id), nonzero targets that `FxUnit` (`param_id` is a
/// `dsp/fx_params.zig` index).
///
/// `center`/`lo`/`hi` are captured when the target is bound, not looked up
/// at render time: the audio thread has no access to the param tables, and
/// the controller overwrites the live value every block, so a re-read would
/// centre the next pass on the last modulated value and walk away.
pub const Target = struct {
    track: u16,
    instance_id: u32 = 0,
    param_id: u32,
    /// The param's value at bind time - the controller swings around this.
    center: f32,
    lo: f32,
    hi: f32,

    /// Absolute param value for a controller output of `out` (-1..1, depth
    /// already applied). Half the param's own range at full depth, so a
    /// centred knob can swing to both ends and one near an end simply
    /// clamps rather than folding back.
    pub fn valueFor(self: Target, out: f32) f32 {
        const span = (self.hi - self.lo) * 0.5;
        return std.math.clamp(self.center + out * span, self.lo, self.hi);
    }
};

pub const Controller = struct {
    shape: lfo.Shape = .sine,
    /// Cycle length in beats. Tempo-synced by construction - see the module
    /// comment on why phase is derived from the song position.
    beats: f32 = 4.0,
    /// 0..1 scale on the bipolar shape, applied before `Target.valueFor`.
    depth: f32 = 0.5,
    /// Cycle offset, 0..1 - two controllers on the same rate a quarter turn
    /// apart is how a circular pan or a chase is built.
    phase: f32 = 0.0,
    targets: [max_targets]?Target = @splat(null),

    /// Bipolar output at song beat `beat`, depth already applied.
    pub fn valueAt(self: *const Controller, beat: f64) f32 {
        const period: f64 = @max(@as(f64, self.beats), 0.01);
        const cycles = beat / period + @as(f64, self.phase);
        const frac = cycles - @floor(cycles);
        const osc: lfo.Lfo = .{ .phase = @floatCast(frac) };
        return osc.sample(self.shape) * std.math.clamp(self.depth, 0.0, 1.0);
    }

    /// First free target slot, or null when full.
    pub fn freeSlot(self: *const Controller) ?u8 {
        for (self.targets, 0..) |t, i| {
            if (t == null) return @intCast(i);
        }
        return null;
    }

    /// Drop every target on `track`, and shift the rest down so the list
    /// stays dense - called when a track is deleted, mirroring how the
    /// engine's own per-track arrays get compacted.
    pub fn dropTrack(self: *Controller, track: u16) void {
        var out: u8 = 0;
        for (self.targets) |t| {
            const keep = t orelse continue;
            if (keep.track == track) continue;
            self.targets[out] = keep;
            out += 1;
        }
        for (self.targets[out..]) |*slot| slot.* = null;
    }

    /// Re-point targets after a track index shift (insert/delete/swap
    /// renumber every track above the edit). `map` returns the new index for
    /// an old one, or null if that track is gone.
    pub fn remapTracks(self: *Controller, ctx: anytype, map: fn (@TypeOf(ctx), u16) ?u16) void {
        var out: u8 = 0;
        for (self.targets) |t| {
            var keep = t orelse continue;
            keep.track = map(ctx, keep.track) orelse continue;
            self.targets[out] = keep;
            out += 1;
        }
        for (self.targets[out..]) |*slot| slot.* = null;
    }
};

test "phase follows the beat, so the same beat always gives the same value" {
    const c: Controller = .{ .shape = .sine, .beats = 4.0, .depth = 1.0 };
    // A sine is 0 at the start of the cycle and +1 a quarter of the way in.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c.valueAt(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.valueAt(1.0), 1e-6);
    // Same beat one and a hundred cycles later reads identically - what a
    // free-running accumulator could not promise across a transport jump.
    try std.testing.expectApproxEqAbs(c.valueAt(1.0), c.valueAt(5.0), 1e-5);
    try std.testing.expectApproxEqAbs(c.valueAt(1.0), c.valueAt(401.0), 1e-4);
}

test "depth scales the output and a target maps it onto its own range" {
    const c: Controller = .{ .shape = .sine, .beats = 4.0, .depth = 0.5 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), c.valueAt(1.0), 1e-6);

    // Cutoff centred at 1 kHz in a 20..20k range: half depth swings half of
    // half the range.
    const t: Target = .{ .track = 0, .param_id = 3, .center = 1000.0, .lo = 20.0, .hi = 20_000.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0 + 0.5 * 9990.0), t.valueFor(c.valueAt(1.0)), 1e-2);
    // ...and clamps rather than leaving the range at the other extreme.
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), t.valueFor(-1.0), 1e-6);
}

test "dropTrack removes a track's targets and keeps the list dense" {
    var c: Controller = .{};
    c.targets[0] = .{ .track = 0, .param_id = 1, .center = 0, .lo = 0, .hi = 1 };
    c.targets[1] = .{ .track = 3, .param_id = 2, .center = 0, .lo = 0, .hi = 1 };
    c.targets[2] = .{ .track = 0, .param_id = 3, .center = 0, .lo = 0, .hi = 1 };
    c.dropTrack(0);
    try std.testing.expectEqual(@as(u16, 3), c.targets[0].?.track);
    try std.testing.expect(c.targets[1] == null);
    try std.testing.expectEqual(@as(u8, 1), c.freeSlot().?);
}

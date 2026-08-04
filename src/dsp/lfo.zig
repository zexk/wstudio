//! Free-running LFO phase accumulator shared by the modulation FX units
//! (chorus, flanger, phaser, tape's wow+flutter). Phase is stored as a
//! 0..1 fraction of a cycle rather than radians, so `tick` is a plain
//! multiply-add-wrap and every unit's per-sample loop looks the same.

const std = @import("std");

/// The four shapes derivable from phase alone (no held/integrated state) -
/// synth.zig's own `LfoShape` adds `sh`/`chaos`/`custom` on top of these for
/// its mod matrix, which need PolySynth-held state `sample` has no access
/// to, so it only covers this subset.
pub const Shape = enum { sine, triangle, saw, square };
/// Row labels for `Shape`, in declaration order - UI tables index this with
/// `@intFromEnum(shape)`, same convention as `dsp/pad.zig`'s
/// `play_mode_names`.
pub const shape_names = [_][]const u8{ "sine", "triangle", "saw", "square" };

pub const Lfo = struct {
    phase: f32 = 0.0,

    /// Repairs a non-finite phase (automation/undo/preset-load edge cases
    /// can leave it NaN/inf) - call once per block, before the sample loop,
    /// not per-sample: `tick`'s own math can't reintroduce non-finiteness
    /// once `phase` starts finite and `inc` is finite.
    pub fn sanitize(self: *Lfo) void {
        if (!std.math.isFinite(self.phase)) self.phase = 0.0;
    }

    /// Advances by `inc` (cycles/sample, i.e. `rate_hz / sample_rate`) and
    /// wraps back into [0, 1).
    pub fn tick(self: *Lfo, inc: f32) void {
        self.phase += inc;
        self.phase -= @floor(self.phase);
    }

    /// Bipolar sine `offset` cycles ahead of the current phase (e.g. -0.25
    /// for a quarter-cycle-behind stereo-widening offset).
    pub fn sine(self: Lfo, offset: f32) f32 {
        return @sin((self.phase + offset) * 2.0 * std.math.pi);
    }

    /// Bipolar sample of any basic `Shape` at the current phase.
    pub fn sample(self: Lfo, shape: Shape) f32 {
        return switch (shape) {
            .sine => self.sine(0.0),
            .triangle => 1.0 - 4.0 * @abs(self.phase - 0.5),
            .saw => 2.0 * self.phase - 1.0,
            .square => if (self.phase < 0.5) 1.0 else -1.0,
        };
    }

    pub fn reset(self: *Lfo) void {
        self.phase = 0.0;
    }
};

test "sample matches synth.zig's lfoSample at cardinal phases" {
    const cases = [_]struct { phase: f32, sine: f32, tri: f32, saw: f32, sq: f32 }{
        .{ .phase = 0.0, .sine = 0.0, .tri = -1.0, .saw = -1.0, .sq = 1.0 },
        .{ .phase = 0.25, .sine = 1.0, .tri = 0.0, .saw = -0.5, .sq = 1.0 },
        .{ .phase = 0.5, .sine = 0.0, .tri = 1.0, .saw = 0.0, .sq = -1.0 },
        .{ .phase = 0.75, .sine = -1.0, .tri = 0.0, .saw = 0.5, .sq = -1.0 },
    };
    for (cases) |c| {
        const lfo: Lfo = .{ .phase = c.phase };
        try std.testing.expectApproxEqAbs(c.sine, lfo.sample(.sine), 1e-6);
        try std.testing.expectApproxEqAbs(c.tri, lfo.sample(.triangle), 1e-6);
        try std.testing.expectApproxEqAbs(c.saw, lfo.sample(.saw), 1e-6);
        try std.testing.expectApproxEqAbs(c.sq, lfo.sample(.square), 1e-6);
    }
}

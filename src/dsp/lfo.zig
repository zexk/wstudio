//! Free-running LFO phase accumulator shared by the modulation FX units
//! (chorus, flanger, phaser, tape's wow+flutter). Phase is stored as a
//! 0..1 fraction of a cycle rather than radians, so `tick` is a plain
//! multiply-add-wrap and every unit's per-sample loop looks the same.

const std = @import("std");

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

    pub fn reset(self: *Lfo) void {
        self.phase = 0.0;
    }
};

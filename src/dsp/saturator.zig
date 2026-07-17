//! Soft-clip saturator: a tanh waveshaper with input drive, output trim,
//! and dry/wet mix. The shaper is peak-normalised (tanh(g·x)/tanh(g)) so
//! cranking the drive adds density and harmonics without also adding
//! level; the output trim is a plain make-up/duck control on top.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Saturator = struct {
    drive_db: f32 = 12.0,
    out_db: f32 = 0.0,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 1.0,

    pub const device = dsp.deviceOf(@This());

    /// Stateless (no filters/lines to clear) - exists only so `deviceOf`
    /// has a `reset` to wire into the vtable.
    pub fn reset(self: *Saturator) void {
        _ = self;
    }

    /// Shape an interleaved stereo buffer in place.
    pub fn processBlock(self: *Saturator, buf: []Sample) void {
        const drive_db = if (std.math.isFinite(self.drive_db)) std.math.clamp(self.drive_db, 0.0, 36.0) else 12.0;
        const out_db = if (std.math.isFinite(self.out_db)) std.math.clamp(self.out_db, -24.0, 24.0) else 0.0;
        const mix = if (std.math.isFinite(self.mix)) std.math.clamp(self.mix, 0.0, 1.0) else 1.0;
        // zig fmt: off
        const pre  = std.math.pow(f32, 10.0, drive_db / 20.0);
        // zig fmt: on
        const post = std.math.pow(f32, 10.0, out_db / 20.0);
        const norm = 1.0 / std.math.tanh(pre); // full-scale in → full-scale out
        for (buf) |*s| {
            const wet = std.math.tanh(s.* * pre) * norm * post;
            s.* = s.* * (1.0 - mix) + wet * mix;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

test "full-scale input maps to full scale at any drive" {
    var sat = Saturator{ .drive_db = 30.0 };
    var buf = [_]Sample{ 1.0, -1.0 };
    sat.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(Sample, 1.0), buf[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(Sample, -1.0), buf[1], 1e-4);
}

test "drive raises the level of small signals" {
    var sat = Saturator{ .drive_db = 24.0 };
    var buf = [_]Sample{ 0.1, -0.1 };
    sat.processBlock(&buf);
    try std.testing.expect(buf[0] > 0.5);
    try std.testing.expect(buf[1] < -0.5);
}

test "mix 0 passes the input untouched" {
    var sat = Saturator{ .drive_db = 36.0, .mix = 0.0 };
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    const expected = buf;
    sat.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "invalid parameters cannot poison output" {
    var sat = Saturator{
        .drive_db = std.math.inf(f32),
        .out_db = -std.math.inf(f32),
        .mix = std.math.nan(f32),
    };
    var buf = [_]Sample{ 0.0, -0.7, 0.05, 0.9 };
    sat.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

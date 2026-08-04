//! Shared fractional-delay read for the ring-buffer-based modulation FX
//! (chorus/flanger/tape/reverb predelay): 4-point, 3rd-order Lagrange
//! interpolation between the samples bracketing a point `delay_frames`
//! behind `write_pos` in a circular buffer. Requires `line.len >= 4`
//! (every caller already sizes for this).
//!
//! Chosen over linear interpolation for its flatter passband (linear rolls
//! off the top octave hard enough to dull a chorus/flanger sweep - see
//! Laakso et al. 1996, "Splitting the Unit Delay"), and over an allpass
//! (Thiran) interpolator because allpass is IIR: its interpolation error is
//! stored in filter memory, so changing the delay a modulated tap needs
//! every sample would click. Lagrange is a pure FIR weighting of the
//! current 4 taps, so a time-varying delay stays artifact-free.

const types = @import("../core/types.zig");
const Sample = types.Sample;

/// `@mod` rather than a single conditional add: Tape's wow+flutter swing
/// can exceed one full ring length at high sample rates (see its "high
/// sample rates wrap taps that span more than one ring" test), so the read
/// position may need more than one wrap back into range.
pub fn readInterp(line: []const Sample, write_pos: usize, delay_frames: f32) Sample {
    const len_f: f32 = @floatFromInt(line.len);
    const pos = @mod(@as(f32, @floatFromInt(write_pos)) - delay_frames, len_f);
    // `pos` is mathematically < len_f, but at large lengths a numerator
    // within one f32 ULP of a multiple of len_f can round the subtraction
    // inside `@mod` up to exactly len_f - one past the valid range (seen on
    // a 12k-frame reverb predelay line; smaller chorus/tape/flanger lines
    // never had the magnitude to trigger it). Clamp defensively.
    const idx0: usize = @min(@as(usize, @intFromFloat(pos)), line.len - 1);
    const t = pos - @as(f32, @floatFromInt(idx0));
    const idx_m1 = (idx0 + line.len - 1) % line.len;
    const idx1 = (idx0 + 1) % line.len;
    const idx2 = (idx0 + 2) % line.len;
    const p0 = line[idx_m1];
    const p1 = line[idx0];
    const p2 = line[idx1];
    const p3 = line[idx2];
    // Lagrange basis polynomials for nodes at t = -1, 0, 1, 2; at t=0 this
    // reduces to exactly p1 and at t=1 to exactly p2, same as linear would.
    const c0 = -t * (t - 1.0) * (t - 2.0) / 6.0;
    const c1 = (t + 1.0) * (t - 1.0) * (t - 2.0) / 2.0;
    const c2 = -(t + 1.0) * t * (t - 2.0) / 2.0;
    const c3 = (t + 1.0) * t * (t - 1.0) / 6.0;
    return p0 * c0 + p1 * c1 + p2 * c2 + p3 * c3;
}

const std = @import("std");

test "interpolates exactly on-grid and stays close on a linear ramp" {
    var line: [8]Sample = .{ 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0 };
    // Exact integer delay must reproduce the sample untouched.
    try std.testing.expectApproxEqAbs(@as(Sample, 5.0), readInterp(&line, 5, 0.0), 1e-6);
    // A straight ramp is inside the interpolator's polynomial order, so the
    // fractional read should land on the ramp value exactly too.
    try std.testing.expectApproxEqAbs(@as(Sample, 3.5), readInterp(&line, 5, 1.5), 1e-5);
}

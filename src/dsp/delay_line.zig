//! Shared fractional-delay read for the ring-buffer-based modulation FX
//! (chorus/flanger/tape): linearly interpolates between the two samples
//! bracketing a point `delay_frames` behind `write_pos` in a circular
//! buffer.

const types = @import("../core/types.zig");
const Sample = types.Sample;

/// `@mod` rather than a single conditional add: Tape's wow+flutter swing
/// can exceed one full ring length at high sample rates (see its "high
/// sample rates wrap taps that span more than one ring" test), so the read
/// position may need more than one wrap back into range.
pub fn readInterp(line: []const Sample, write_pos: usize, delay_frames: f32) Sample {
    const len_f: f32 = @floatFromInt(line.len);
    const pos = @mod(@as(f32, @floatFromInt(write_pos)) - delay_frames, len_f);
    const idx0: usize = @intFromFloat(pos);
    const frac = pos - @as(f32, @floatFromInt(idx0));
    const idx1 = (idx0 + 1) % line.len;
    return line[idx0] * (1.0 - frac) + line[idx1] * frac;
}

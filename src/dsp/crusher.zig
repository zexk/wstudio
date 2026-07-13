//! Bitcrusher: bit-depth quantiser + sample-rate reducer (sample-and-hold).
//! `bits` sets the quantiser depth, `downsample` how many frames each held
//! value repeats for; both stored as f32 so the shared FX param plumbing
//! can nudge them, rounded to integers at use.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Crusher = struct {
    bits: f32 = 8.0,
    downsample: f32 = 4.0,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 1.0,
    /// Sample-and-hold state: last quantised frame + frames until refresh.
    hold: [2]Sample = .{ 0.0, 0.0 },
    counter: u32 = 0,

    pub fn device(self: *Crusher) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .reset = resetOpaque,
    };

    /// Crush an interleaved stereo buffer in place.
    pub fn processBlock(self: *Crusher, buf: []Sample) void {
        // zig fmt: off
        const q    = std.math.pow(f32, 2.0, @round(self.bits) - 1.0);
        const step = @max(@as(u32, @intFromFloat(@round(self.downsample))), 1);
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            if (self.counter == 0) {
                self.hold[0] = @round(buf[i] * q) / q;
                self.hold[1] = @round(buf[i + 1] * q) / q;
            }
            self.counter = (self.counter + 1) % step;
            buf[i]     = buf[i] * (1.0 - self.mix) + self.hold[0] * self.mix;
            // zig fmt: on
            buf[i + 1] = buf[i + 1] * (1.0 - self.mix) + self.hold[1] * self.mix;
        }
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *Crusher = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *Crusher = @ptrCast(@alignCast(ptr));
        self.hold = .{ 0.0, 0.0 };
        self.counter = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests

test "quantiser snaps to the bit grid" {
    var crush = Crusher{ .bits = 3.0, .downsample = 1.0 }; // grid of 1/4
    var buf = [_]Sample{ 0.3, 0.3, -0.6, -0.6 };
    crush.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.25), buf[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(Sample, -0.5), buf[2], 1e-6);
}

test "downsample holds each frame for the factor's duration" {
    var crush = Crusher{ .bits = 16.0, .downsample = 4.0 };
    var buf: [16]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i / 2)) * 0.1;
    crush.processBlock(&buf);
    // Frames 0-3 hold frame 0's value, frames 4-7 hold frame 4's.
    try std.testing.expectApproxEqAbs(buf[0], buf[6], 1e-4);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.4), buf[8], 1e-3);
    try std.testing.expectApproxEqAbs(buf[8], buf[14], 1e-4);
}

test "mix 0 passes the input untouched" {
    var crush = Crusher{ .bits = 1.0, .downsample = 8.0, .mix = 0.0 };
    var buf = [_]Sample{ 0.3, -0.7, 0.05, 0.9 };
    const expected = buf;
    crush.processBlock(&buf);
    for (buf, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

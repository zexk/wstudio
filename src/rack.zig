const std = @import("std");
const dsp = @import("dsp/device.zig");
const PolySynth = @import("dsp/synth.zig").PolySynth;
const Compressor = @import("dsp/compressor.zig").Compressor;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const GraphicEq = @import("dsp/eq.zig").GraphicEq;

pub const Rack = struct {
    synth: PolySynth,
    eq: ?GraphicEq = null,
    comp: ?Compressor = null,
    delay: ?StereoDelay = null,
    reverb: ?Reverb = null,
    label: []const u8,

    pub fn deinit(self: *Rack, allocator: std.mem.Allocator) void {
        if (self.delay) |*d| d.deinit(allocator);
        if (self.reverb) |*r| r.deinit(allocator);
    }

    pub fn chain(self: *Rack, buf: *[5]dsp.Device) []const dsp.Device {
        var len: usize = 0;
        buf[len] = self.synth.device();
        len += 1;
        if (self.comp) |*c| {
            buf[len] = c.device();
            len += 1;
        }
        if (self.eq) |*e| {
            buf[len] = e.device();
            len += 1;
        }
        if (self.delay) |*d| {
            buf[len] = d.device();
            len += 1;
        }
        if (self.reverb) |*r| {
            buf[len] = r.device();
            len += 1;
        }
        return buf[0..len];
    }

    pub fn recreateChain(self: *Rack, buf: *[5]dsp.Device) []const dsp.Device {
        return self.chain(buf);
    }
};

//! Freeverb-style reverb: parallel damped comb filters into series
//! allpasses, per channel, with a slight delay offset on the right
//! channel for stereo width.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

// Classic Freeverb tunings, in frames at 44.1 kHz (scaled at init).
const comb_tunings = [_]usize{ 1116, 1188, 1277, 1356 };
const allpass_tunings = [_]usize{ 556, 441 };
const stereo_spread = 23;
const input_gain = 0.06;

pub const Reverb = struct {
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 0.3,
    /// Comb feedback; higher = longer tail.
    room: f32 = 0.84,
    damp: f32 = 0.25,
    channels: [2]Channel,

    const Comb = struct {
        buf: []Sample,
        idx: usize = 0,
        store: f32 = 0.0,
    };

    const Allpass = struct {
        buf: []Sample,
        idx: usize = 0,
    };

    const Channel = struct {
        combs: [comb_tunings.len]Comb,
        allpasses: [allpass_tunings.len]Allpass,
    };

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Reverb {
        var self: Reverb = .{ .channels = undefined };
        const scale = @as(f64, @floatFromInt(@max(sample_rate, 1))) / 44_100.0;
        for (&self.channels, 0..) |*ch, ch_i| {
            const spread = ch_i * stereo_spread;
            for (&ch.combs, comb_tunings) |*comb, tuning| {
                comb.* = .{ .buf = try allocLine(allocator, tuning + spread, scale) };
            }
            for (&ch.allpasses, allpass_tunings) |*ap, tuning| {
                ap.* = .{ .buf = try allocLine(allocator, tuning + spread, scale) };
            }
        }
        return self;
    }

    fn allocLine(allocator: std.mem.Allocator, frames_44k: usize, scale: f64) ![]Sample {
        const n: usize = @intFromFloat(@as(f64, @floatFromInt(frames_44k)) * scale);
        const buf = try allocator.alloc(Sample, @max(n, 1));
        @memset(buf, 0.0);
        return buf;
    }

    pub fn deinit(self: *Reverb, allocator: std.mem.Allocator) void {
        for (&self.channels) |*ch| {
            for (ch.combs) |comb| allocator.free(comb.buf);
            for (ch.allpasses) |ap| allocator.free(ap.buf);
        }
    }

    pub fn reset(self: *Reverb) void {
        for (&self.channels) |*ch| {
            for (&ch.combs) |*comb| {
                @memset(comb.buf, 0.0);
                comb.store = 0.0;
            }
            for (&ch.allpasses) |*ap| @memset(ap.buf, 0.0);
        }
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *Reverb, buf: []Sample) void {
        // room >= 1 makes each comb's own feedback loop gain >= 1, so
        // energy grows every time a sample cycles back through its delay
        // line instead of decaying.
        const room = dsp.sanitizeParam(self.room, 0.0, 0.98, 0.84);
        const damp = dsp.sanitizeParam(self.damp, 0.0, 1.0, 0.25);
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 0.3);
        const frames = buf.len / 2;
        for (0..frames) |i| {
            inline for (0..2) |ch_i| {
                const ch = &self.channels[ch_i];
                const dry = buf[i * 2 + ch_i];
                const input = dry * input_gain;

                var wet: f32 = 0.0;
                for (&ch.combs) |*comb| {
                    const y = comb.buf[comb.idx];
                    comb.store = y * (1.0 - damp) + comb.store * damp;
                    comb.buf[comb.idx] = input + comb.store * room;
                    comb.idx = (comb.idx + 1) % comb.buf.len;
                    wet += y;
                }
                for (&ch.allpasses) |*ap| {
                    const y = ap.buf[ap.idx];
                    ap.buf[ap.idx] = wet + y * 0.5;
                    ap.idx = (ap.idx + 1) % ap.buf.len;
                    wet = y - wet;
                }

                buf[i * 2 + ch_i] = dry * (1.0 - mix) + wet * mix;
            }
        }
    }
};

test "impulse produces a decaying tail, not an explosion" {
    var reverb = try Reverb.init(std.testing.allocator, 48_000);
    defer reverb.deinit(std.testing.allocator);
    reverb.mix = 1.0; // wet only so we observe the tail directly

    var buf = [_]Sample{0.0} ** (4096 * 2);
    buf[0] = 1.0;
    buf[1] = 1.0;
    reverb.processBlock(&buf);

    var tail_energy: f32 = 0.0;
    var peak: f32 = 0.0;
    for (buf[2048..]) |s| {
        tail_energy += s * s;
        peak = @max(peak, @abs(s));
    }
    try std.testing.expect(tail_energy > 0.0); // reverb tail exists
    try std.testing.expect(peak < 1.0); // and stays bounded
}

test "invalid parameters cannot trap or poison output" {
    var reverb = try Reverb.init(std.testing.allocator, 48_000);
    defer reverb.deinit(std.testing.allocator);
    reverb.room = std.math.inf(f32);
    reverb.damp = std.math.nan(f32);
    reverb.mix = -std.math.inf(f32);

    var buf = [_]Sample{0.0} ** (2048 * 2);
    buf[0] = 1.0;
    buf[1] = 1.0;
    reverb.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

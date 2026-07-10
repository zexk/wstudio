const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const num_eq_bands = 8;

/// Initial per-band center frequencies for a freshly inserted EQ — a
/// log-ish spread across low/mid/high. Every band is fully parametric
/// (freq/Q/gain all adjustable) so these are just starting points, not
/// fixed slots the way a graphic EQ's ISO bands were.
pub const default_frequencies = [_]f32{
    60.0, 150.0, 400.0, 1000.0, 2500.0, 6000.0, 10000.0, 16000.0,
};

const freq_min: f32 = 20.0;
const freq_max: f32 = 20000.0;
const q_min: f32 = 0.1;
const q_max: f32 = 10.0;
const gain_min: f32 = -18.0;
const gain_max: f32 = 18.0;

const EqBand = struct {
    freq: f32,
    gain_db: f32 = 0.0,
    q: f32 = 0.7,

    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,

    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    fn recompute(band: *EqBand, sr: f32) void {
        const a = std.math.pow(f32, 10.0, band.gain_db / 40.0);
        const w0 = 2.0 * std.math.pi * band.freq / sr;
        const cos_w0 = std.math.cos(w0);
        const sin_w0 = std.math.sin(w0);
        const alpha = sin_w0 / (2.0 * band.q);

        const b0_raw = 1.0 + alpha * a;
        const b1_raw = -2.0 * cos_w0;
        const b2_raw = 1.0 - alpha * a;
        const a0_raw = 1.0 + alpha / a;
        const a1_raw = -2.0 * cos_w0;
        const a2_raw = 1.0 - alpha / a;

        const inv_a0 = 1.0 / a0_raw;
        band.b0 = b0_raw * inv_a0;
        band.b1 = b1_raw * inv_a0;
        band.b2 = b2_raw * inv_a0;
        band.a1 = a1_raw * inv_a0;
        band.a2 = a2_raw * inv_a0;
    }

    fn process(band: *EqBand, sample: f32) f32 {
        const y = band.b0 * sample + band.b1 * band.x1 + band.b2 * band.x2
                - band.a1 * band.y1 - band.a2 * band.y2;
        band.x2 = band.x1;
        band.x1 = sample;
        band.y2 = band.y1;
        band.y1 = y;
        return y;
    }

    fn reset(band: *EqBand) void {
        band.x1 = 0.0;
        band.x2 = 0.0;
        band.y1 = 0.0;
        band.y2 = 0.0;
    }
};

pub const ParametricEq = struct {
    sr: f32,
    bands: [num_eq_bands]EqBand,
    bypass: bool = false,

    pub fn init(sample_rate: u32) ParametricEq {
        var self: ParametricEq = .{
            .sr = @floatFromInt(sample_rate),
            .bands = undefined,
        };
        for (&self.bands, &default_frequencies) |*b, f| {
            b.* = .{ .freq = f, .gain_db = 0.0, .q = 0.7 };
            b.recompute(self.sr);
        }
        return self;
    }

    pub fn setGain(self: *ParametricEq, index: usize, gain_db: f32) void {
        if (index >= num_eq_bands) return;
        self.bands[index].gain_db = std.math.clamp(gain_db, gain_min, gain_max);
        self.bands[index].recompute(self.sr);
    }

    pub fn setFreq(self: *ParametricEq, index: usize, freq_hz: f32) void {
        if (index >= num_eq_bands) return;
        self.bands[index].freq = std.math.clamp(freq_hz, freq_min, freq_max);
        self.bands[index].recompute(self.sr);
    }

    pub fn setQ(self: *ParametricEq, index: usize, q: f32) void {
        if (index >= num_eq_bands) return;
        self.bands[index].q = std.math.clamp(q, q_min, q_max);
        self.bands[index].recompute(self.sr);
    }

    pub fn process(self: *ParametricEq, buf: []Sample) void {
        if (self.bypass) return;
        for (&self.bands) |*band| {
            var i: usize = 0;
            while (i < buf.len) : (i += 2) {
                buf[i] = band.process(buf[i]);
                buf[i + 1] = band.process(buf[i + 1]);
            }
        }
    }

    pub fn device(self: *ParametricEq) dsp.Device {
        return .{
            .ptr = self,
            .vtable = &.{
                .process = struct {
                    fn f(ptr: *anyopaque, buf: []Sample) void {
                        const eq: *ParametricEq = @ptrCast(@alignCast(ptr));
                        eq.process(buf);
                    }
                }.f,
                .event = null,
                .reset = struct {
                    fn f(ptr: *anyopaque) void {
                        const eq: *ParametricEq = @ptrCast(@alignCast(ptr));
                        for (&eq.bands) |*b| b.reset();
                    }
                }.f,
            },
        };
    }
};

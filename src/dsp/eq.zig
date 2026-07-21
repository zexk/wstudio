const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const num_eq_bands = 8;

/// Initial per-band center frequencies for a freshly inserted EQ - a
/// log-ish spread across low/mid/high. Every band is fully parametric
/// (freq/Q/gain all adjustable) so these are just starting points, not
/// fixed slots the way a graphic EQ's ISO bands were.
pub const default_frequencies = [_]f32{
    60.0, 150.0, 400.0, 1000.0, 2500.0, 6000.0, 10000.0, 16000.0,
};

/// Per-band response type: peaking and shelf filters use gain, while the
/// low/high-pass filters use `slope` for cascade steepness.
pub const BandKind = enum(u8) { peak, lowpass, highpass, lowshelf, highshelf };

pub fn usesGain(kind: BandKind) bool {
    return switch (kind) {
        .peak, .lowshelf, .highshelf => true,
        .lowpass, .highpass => false,
    };
}

pub fn usesSlope(kind: BandKind) bool {
    return !usesGain(kind);
}

/// Slope cap for the filter kinds, in cascaded second-order sections:
/// each stage adds 12 dB/oct, so 1..4 covers 12/24/36/48 dB/oct.
pub const max_slope = 4;

const freq_min: f32 = 20.0;
const freq_max: f32 = 20000.0;
const q_min: f32 = 0.1;
const q_max: f32 = 10.0;
const gain_min: f32 = -18.0;
const gain_max: f32 = 18.0;

/// One biquad section's delay line. A band keeps a state per cascade
/// stage per channel; the coefficients are shared (identical cascade).
const BiquadState = struct {
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,
};

const EqBand = struct {
    freq: f32,
    gain_db: f32 = 0.0,
    q: f32 = 0.7,
    kind: BandKind = .peak,
    /// Cascade depth for .lowpass/.highpass, 1..max_slope (12 dB/oct per
    /// stage). A .peak band always runs exactly one stage.
    slope: u8 = 1,

    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,

    state: [max_slope][2]BiquadState = std.mem.zeroes([max_slope][2]BiquadState),

    fn recompute(band: *EqBand, sr: f32) void {
        const w0 = 2.0 * std.math.pi * band.freq / sr;
        const cos_w0 = std.math.cos(w0);
        const sin_w0 = std.math.sin(w0);
        const alpha = sin_w0 / (2.0 * band.q);

        var b0_raw: f32 = undefined;
        var b1_raw: f32 = undefined;
        var b2_raw: f32 = undefined;
        var a0_raw: f32 = undefined;
        var a1_raw: f32 = undefined;
        var a2_raw: f32 = undefined;
        switch (band.kind) {
            .peak => {
                const a = std.math.pow(f32, 10.0, band.gain_db / 40.0);
                b0_raw = 1.0 + alpha * a;
                b1_raw = -2.0 * cos_w0;
                b2_raw = 1.0 - alpha * a;
                a0_raw = 1.0 + alpha / a;
                a1_raw = -2.0 * cos_w0;
                a2_raw = 1.0 - alpha / a;
            },
            .lowpass => {
                b0_raw = (1.0 - cos_w0) / 2.0;
                b1_raw = 1.0 - cos_w0;
                b2_raw = b0_raw;
                a0_raw = 1.0 + alpha;
                a1_raw = -2.0 * cos_w0;
                a2_raw = 1.0 - alpha;
            },
            .highpass => {
                b0_raw = (1.0 + cos_w0) / 2.0;
                b1_raw = -(1.0 + cos_w0);
                b2_raw = b0_raw;
                a0_raw = 1.0 + alpha;
                a1_raw = -2.0 * cos_w0;
                a2_raw = 1.0 - alpha;
            },
            .lowshelf, .highshelf => {
                const a = std.math.pow(f32, 10.0, band.gain_db / 40.0);
                const sqrt_a = std.math.sqrt(a);
                const shelf_alpha = sin_w0 / (2.0 * band.q);
                const alpha_term = 2.0 * sqrt_a * shelf_alpha;
                if (band.kind == .lowshelf) {
                    b0_raw = a * ((a + 1.0) - (a - 1.0) * cos_w0 + alpha_term);
                    b1_raw = 2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0);
                    b2_raw = a * ((a + 1.0) - (a - 1.0) * cos_w0 - alpha_term);
                    a0_raw = (a + 1.0) + (a - 1.0) * cos_w0 + alpha_term;
                    a1_raw = -2.0 * ((a - 1.0) + (a + 1.0) * cos_w0);
                    a2_raw = (a + 1.0) + (a - 1.0) * cos_w0 - alpha_term;
                } else {
                    b0_raw = a * ((a + 1.0) + (a - 1.0) * cos_w0 + alpha_term);
                    b1_raw = -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0);
                    b2_raw = a * ((a + 1.0) + (a - 1.0) * cos_w0 - alpha_term);
                    a0_raw = (a + 1.0) - (a - 1.0) * cos_w0 + alpha_term;
                    a1_raw = 2.0 * ((a - 1.0) - (a + 1.0) * cos_w0);
                    a2_raw = (a + 1.0) - (a - 1.0) * cos_w0 - alpha_term;
                }
            },
        }

        const inv_a0 = 1.0 / a0_raw;
        band.b0 = b0_raw * inv_a0;
        band.b1 = b1_raw * inv_a0;
        band.b2 = b2_raw * inv_a0;
        band.a1 = a1_raw * inv_a0;
        band.a2 = a2_raw * inv_a0;
    }

    /// How many cascade stages this band runs per sample.
    fn stages(band: *const EqBand) usize {
        return if (usesSlope(band.kind)) band.slope else 1;
    }

    fn processStage(band: *EqBand, stage: usize, ch: usize, x: f32) f32 {
        const st = &band.state[stage][ch];
        // zig fmt: off
        const y = band.b0 * x + band.b1 * st.x1 + band.b2 * st.x2
                - band.a1 * st.y1 - band.a2 * st.y2;
                // zig fmt: on
        st.x2 = st.x1;
        st.x1 = x;
        st.y2 = st.y1;
        st.y1 = y;
        return y;
    }

    fn reset(band: *EqBand) void {
        band.state = std.mem.zeroes([max_slope][2]BiquadState);
    }
};

pub const ParametricEq = struct {
    sr: f32,
    bands: [num_eq_bands]EqBand,
    bypass: bool = false,

    pub fn init(sample_rate: u32) ParametricEq {
        var self: ParametricEq = .{
            .sr = @floatFromInt(@max(sample_rate, 1)),
            .bands = undefined,
        };
        for (&self.bands, &default_frequencies) |*b, f| {
            b.* = .{ .freq = f, .gain_db = 0.0, .q = 0.7 };
            b.recompute(self.sr);
        }
        return self;
    }

    pub fn setGain(self: *ParametricEq, index: usize, gain_db: f32) void {
        if (index >= num_eq_bands or !std.math.isFinite(gain_db)) return;
        self.bands[index].gain_db = std.math.clamp(gain_db, gain_min, gain_max);
        self.bands[index].recompute(self.sr);
    }

    pub fn setFreq(self: *ParametricEq, index: usize, freq_hz: f32) void {
        if (index >= num_eq_bands or !std.math.isFinite(freq_hz)) return;
        self.bands[index].freq = std.math.clamp(freq_hz, freq_min, freq_max);
        self.bands[index].recompute(self.sr);
    }

    pub fn setQ(self: *ParametricEq, index: usize, q: f32) void {
        if (index >= num_eq_bands or !std.math.isFinite(q)) return;
        self.bands[index].q = std.math.clamp(q, q_min, q_max);
        self.bands[index].recompute(self.sr);
    }

    /// Switch a band's response type and (for the filter kinds) its slope
    /// in cascade stages, clamped to 1..max_slope.
    pub fn setType(self: *ParametricEq, index: usize, kind: BandKind, slope: u8) void {
        if (index >= num_eq_bands) return;
        const band = &self.bands[index];
        band.kind = kind;
        band.slope = std.math.clamp(slope, 1, max_slope);
        band.recompute(self.sr);
    }

    pub fn processBlock(self: *ParametricEq, buf: []Sample) void {
        if (self.bypass) return;
        for (&self.bands) |*band| {
            const n = band.stages();
            var i: usize = 0;
            while (i < buf.len) : (i += 2) {
                inline for (0..2) |ch| {
                    var s = buf[i + ch];
                    for (0..n) |stage| s = band.processStage(stage, ch, s);
                    buf[i + ch] = s;
                }
            }
        }
    }

    pub fn reset(self: *ParametricEq) void {
        for (&self.bands) |*b| b.reset();
    }

    pub const device = dsp.deviceOf(@This());
};

test "parameter setters ignore non-finite values" {
    var eq = ParametricEq.init(48_000);
    const before = eq.bands[0];
    eq.setGain(0, std.math.nan(f32));
    eq.setFreq(0, std.math.inf(f32));
    eq.setQ(0, -std.math.inf(f32));
    try std.testing.expectEqual(before.gain_db, eq.bands[0].gain_db);
    try std.testing.expectEqual(before.freq, eq.bands[0].freq);
    try std.testing.expectEqual(before.q, eq.bands[0].q);
}

test "shelf bands boost the intended side of the spectrum" {
    var eq = ParametricEq.init(48_000);
    const band = &eq.bands[0];
    eq.setFreq(0, 1000.0);
    eq.setGain(0, 12.0);

    eq.setType(0, .lowshelf, 4);
    const low_shelf_low = responseMagnitude(band, 100.0, eq.sr);
    const low_shelf_high = responseMagnitude(band, 10_000.0, eq.sr);
    try std.testing.expect(low_shelf_low > low_shelf_high * 2.5);
    try std.testing.expectEqual(@as(usize, 1), band.stages());

    eq.setType(0, .highshelf, 4);
    const high_shelf_low = responseMagnitude(band, 100.0, eq.sr);
    const high_shelf_high = responseMagnitude(band, 10_000.0, eq.sr);
    try std.testing.expect(high_shelf_high > high_shelf_low * 2.5);
    try std.testing.expectEqual(@as(usize, 1), band.stages());
}

fn responseMagnitude(band: *const EqBand, freq: f32, sample_rate: f32) f32 {
    const omega = 2.0 * std.math.pi * freq / sample_rate;
    const z1_re = std.math.cos(omega);
    const z1_im = -std.math.sin(omega);
    const z2_re = std.math.cos(2.0 * omega);
    const z2_im = -std.math.sin(2.0 * omega);
    const num_re = band.b0 + band.b1 * z1_re + band.b2 * z2_re;
    const num_im = band.b1 * z1_im + band.b2 * z2_im;
    const den_re = 1.0 + band.a1 * z1_re + band.a2 * z2_re;
    const den_im = band.a1 * z1_im + band.a2 * z2_im;
    return std.math.sqrt((num_re * num_re + num_im * num_im) / (den_re * den_re + den_im * den_im));
}

test "highpass band blocks DC, lowpass band passes it" {
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .highpass, 2);
    eq.setFreq(0, 1000.0);

    var buf: [512]Sample = undefined;
    for (0..40) |_| {
        @memset(&buf, 1.0);
        eq.processBlock(&buf);
    }
    try std.testing.expect(@abs(buf[510]) < 0.01);
    try std.testing.expect(@abs(buf[511]) < 0.01);

    eq.setType(0, .lowpass, 4);
    for (0..40) |_| {
        @memset(&buf, 1.0);
        eq.processBlock(&buf);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), buf[510], 0.05);
}

test "steeper highpass slope attenuates a below-cutoff tone harder" {
    // 200 Hz tone under a 2 kHz highpass: 12 dB/oct should leave far more
    // of it standing than 48 dB/oct.
    var peak_by_slope: [2]f32 = undefined;
    for ([_]u8{ 1, 4 }, 0..) |slope, si| {
        var eq = ParametricEq.init(48_000);
        eq.setType(0, .highpass, slope);
        eq.setFreq(0, 2000.0);

        var buf: [512]Sample = undefined;
        var phase: f32 = 0.0;
        var peak: f32 = 0.0;
        for (0..60) |block| {
            var i: usize = 0;
            while (i < buf.len) : (i += 2) {
                const s = std.math.sin(phase);
                buf[i] = s;
                buf[i + 1] = s;
                phase += 2.0 * std.math.pi * 200.0 / 48_000.0;
            }
            eq.processBlock(&buf);
            // zig fmt: off
            if (block >= 50) for (buf) |s| { peak = @max(peak, @abs(s)); };
            // zig fmt: on
        }
        peak_by_slope[si] = peak;
    }
    try std.testing.expect(peak_by_slope[1] < peak_by_slope[0] / 10.0);
}

test "channels filter independently (no shared biquad state)" {
    // L carries DC, R stays silent; a lowpass must keep R at zero. The
    // old single-state-per-band code smeared L into R here.
    var eq = ParametricEq.init(48_000);
    eq.setType(0, .lowpass, 1);
    eq.setFreq(0, 500.0);

    var buf: [512]Sample = undefined;
    for (0..20) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            buf[i] = 1.0;
            buf[i + 1] = 0.0;
        }
        eq.processBlock(&buf);
    }
    try std.testing.expect(@abs(buf[511]) < 1e-6);
    try std.testing.expect(buf[510] > 0.9);
}

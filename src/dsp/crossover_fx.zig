//! Three-band Linkwitz-Riley crossover with per-band gain and solo.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const crossover = @import("crossover.zig");

/// LR4 lowpass magnitude at `hz` for a crossover at `fc`: two Butterworth
/// stages in series, so the second-order `1/sqrt(1 + x^4)` squared. -6 dB at
/// the crossover, which is what makes the pair sum to unity.
fn lr4Low(hz: f32, fc: f32) f32 {
    const x = hz / @max(fc, 1.0);
    const x4 = x * x * x * x;
    return 1.0 / (1.0 + x4);
}

/// The highpass half of the same pair.
fn lr4High(hz: f32, fc: f32) f32 {
    const x = hz / @max(fc, 1.0);
    const x4 = x * x * x * x;
    return x4 / (1.0 + x4);
}

pub const CrossoverFx = struct {
    sample_rate: f32,
    xover_lo_hz: f32 = 200,
    xover_hi_hz: f32 = 2000,
    low_gain_db: f32 = 0,
    mid_gain_db: f32 = 0,
    high_gain_db: f32 = 0,
    low_solo: f32 = 0,
    mid_solo: f32 = 0,
    high_solo: f32 = 0,
    splitters: [2]crossover.Splitter(3) = .{ .{}, .{} },

    pub const device = dsp.deviceOf(@This());

    pub fn init(sample_rate: u32) CrossoverFx {
        var self: CrossoverFx = .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
        self.recompute();
        return self;
    }

    fn recompute(self: *CrossoverFx) void {
        for (&self.splitters) |*splitter| splitter.setFreqs(self.sample_rate, .{ self.xover_lo_hz, self.xover_hi_hz });
    }

    pub fn setXoverLo(self: *CrossoverFx, value: f32) void {
        if (!std.math.isFinite(value)) return;
        self.xover_lo_hz = std.math.clamp(value, 20, self.xover_hi_hz - 20);
        self.recompute();
    }

    pub fn setXoverHi(self: *CrossoverFx, value: f32) void {
        if (!std.math.isFinite(value)) return;
        self.xover_hi_hz = std.math.clamp(value, self.xover_lo_hz + 20, 20_000);
        self.recompute();
    }

    pub fn setXovers(self: *CrossoverFx, lo: f32, hi: f32) void {
        if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return;
        self.xover_lo_hz = std.math.clamp(lo, 20, 19_980);
        self.xover_hi_hz = std.math.clamp(hi, self.xover_lo_hz + 20, 20_000);
        self.recompute();
    }

    pub fn processBlock(self: *CrossoverFx, buf: []types.Sample) void {
        const gains = [3]f32{
            types.dbToGain(dsp.sanitizeParam(self.low_gain_db, -60, 24, 0)),
            types.dbToGain(dsp.sanitizeParam(self.mid_gain_db, -60, 24, 0)),
            types.dbToGain(dsp.sanitizeParam(self.high_gain_db, -60, 24, 0)),
        };
        const solos = [3]bool{
            dsp.sanitizeParam(self.low_solo, 0, 1, 0) >= 0.5,
            dsp.sanitizeParam(self.mid_solo, 0, 1, 0) >= 0.5,
            dsp.sanitizeParam(self.high_solo, 0, 1, 0) >= 0.5,
        };
        const any_solo = solos[0] or solos[1] or solos[2];
        var frame: usize = 0;
        while (frame * 2 + 1 < buf.len) : (frame += 1) {
            // Sanitize going in, same as every other rack unit: the splitters
            // are IIR, so one non-finite sample would poison their state for
            // good rather than for a block.
            const left = self.splitters[0].split(dsp.sanitizeParam(buf[frame * 2], -16, 16, 0));
            const right = self.splitters[1].split(dsp.sanitizeParam(buf[frame * 2 + 1], -16, 16, 0));
            var out_l: f32 = 0;
            var out_r: f32 = 0;
            inline for (0..3) |band| {
                if (!any_solo or solos[band]) {
                    out_l += left[band] * gains[band];
                    out_r += right[band] * gains[band];
                }
            }
            buf[frame * 2] = std.math.clamp(out_l, -16, 16);
            buf[frame * 2 + 1] = std.math.clamp(out_r, -16, 16);
        }
    }

    /// Magnitude of the whole three-band network at `hz`, in dB - the two
    /// crossover points, the three band gains and whichever bands a solo
    /// has muted, which is exactly what this unit is set up by. Only the
    /// GUI's response curve calls it.
    ///
    /// The splitter's bands are cascaded (`dsp/crossover.zig`): low is one
    /// LR4 lowpass, mid is the lower highpass into the upper lowpass, high
    /// is both highpasses. Every band is phase-aligned by construction, so
    /// summing magnitudes is the network's real response and not an
    /// approximation of one. The allpass compensation drops out at unity.
    pub fn responseDb(self: *const CrossoverFx, hz: f32) f32 {
        const lo = std.math.clamp(self.xover_lo_hz, 20, 20_000);
        const hi = std.math.clamp(self.xover_hi_hz, 20, 20_000);
        const gains = [3]f32{
            types.dbToGain(dsp.sanitizeParam(self.low_gain_db, -60, 24, 0)),
            types.dbToGain(dsp.sanitizeParam(self.mid_gain_db, -60, 24, 0)),
            types.dbToGain(dsp.sanitizeParam(self.high_gain_db, -60, 24, 0)),
        };
        const solos = [3]bool{
            dsp.sanitizeParam(self.low_solo, 0, 1, 0) >= 0.5,
            dsp.sanitizeParam(self.mid_solo, 0, 1, 0) >= 0.5,
            dsp.sanitizeParam(self.high_solo, 0, 1, 0) >= 0.5,
        };
        const any_solo = solos[0] or solos[1] or solos[2];

        const bands = [3]f32{
            lr4Low(hz, lo),
            lr4High(hz, lo) * lr4Low(hz, hi),
            lr4High(hz, lo) * lr4High(hz, hi),
        };
        var sum: f32 = 0;
        for (bands, gains, solos) |band, gain, solo| {
            if (!any_solo or solo) sum += band * gain;
        }
        return types.gainToDb(@max(sum, 1e-6));
    }
    pub fn reset(self: *CrossoverFx) void {
        for (&self.splitters) |*splitter| splitter.reset();
    }
};

test "crossover passes unity and solos one band" {
    var effect = CrossoverFx.init(48_000);
    var buf: [8192]types.Sample = undefined;
    for (0..buf.len / 2) |i| {
        const sample = @sin(2.0 * std.math.pi * 1000.0 * @as(f32, @floatFromInt(i)) / 48_000.0);
        buf[i * 2] = sample;
        buf[i * 2 + 1] = sample;
    }
    const input = buf;
    effect.processBlock(&buf);
    var input_power: f32 = 0;
    var output_power: f32 = 0;
    for (buf[2048..], input[2048..]) |got, want| {
        input_power += want * want;
        output_power += got * got;
    }
    try std.testing.expectApproxEqRel(input_power, output_power, 0.03);

    effect.reset();
    effect.low_solo = 1;
    buf = input;
    effect.processBlock(&buf);
    try std.testing.expect(@abs(buf[buf.len - 2]) < 0.25);
}

test "crossover stays finite under hostile input" {
    var effect = CrossoverFx.init(48_000);
    effect.low_gain_db = std.math.inf(f32);
    effect.mid_solo = std.math.nan(f32);
    var buf = [_]types.Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1 };
    effect.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
    // One poisoned block must not leave the splitter's IIR state stuck: the
    // next, clean block has to come back out finite too.
    try dsp.expectBoundedUnderNoise(&effect, 16.1);
}

test "a crossover point above Nyquist does not blow the splitter up" {
    // Every caller clamps its knobs to 20 kHz, which is well past Nyquist on
    // a low-rate device.
    var effect = CrossoverFx.init(8_000);
    effect.setXovers(15_000, 20_000);
    try dsp.expectBoundedUnderNoise(&effect, 16.1);
}

test "the plotted response matches what the crossover actually does" {
    // `responseDb` only feeds the GUI, so nothing else would catch it
    // drifting from the splitter's real topology. Checked by sweeping tones
    // through the unit at settings that move all three bands.
    var effect = CrossoverFx.init(48_000);
    effect.setXovers(200, 2000);
    effect.low_gain_db = -12;
    effect.high_gain_db = 6;
    for ([_]f32{ 60.0, 700.0, 8000.0 }) |hz| {
        var buf: [16384]types.Sample = undefined;
        for (0..buf.len / 2) |i| {
            const s = 0.25 * @sin(2.0 * std.math.pi * hz * @as(f32, @floatFromInt(i)) / 48_000.0);
            buf[i * 2] = s;
            buf[i * 2 + 1] = s;
        }
        effect.reset();
        effect.processBlock(&buf);
        var sum: f64 = 0;
        const from = buf.len * 3 / 4;
        for (buf[from..]) |v| sum += @as(f64, v) * v;
        const rms: f32 = @floatCast(@sqrt(sum / @as(f64, @floatFromInt(buf.len - from))));
        const measured_db = types.gainToDb(rms) - types.gainToDb(0.25 / @sqrt(2.0));
        try std.testing.expectApproxEqAbs(effect.responseDb(hz), measured_db, 1.0);
    }
}

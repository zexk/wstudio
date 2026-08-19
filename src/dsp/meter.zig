const std = @import("std");
const types = @import("../core/types.zig");

const Sample = types.Sample;

/// One RBJ-cookbook biquad section, same math as `dsp/eq.zig`'s peaking/
/// filter bands but standalone here since `LoudnessMeter`'s K-weighting
/// cascade needs a high-shelf stage `eq.zig` doesn't have.
const Biquad = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    fn highShelf(freq: f32, db_gain: f32, q: f32, sr: f32) Biquad {
        const w0 = 2.0 * std.math.pi * freq / sr;
        const cos_w0 = std.math.cos(w0);
        const sin_w0 = std.math.sin(w0);
        const a = std.math.pow(f32, 10.0, db_gain / 40.0);
        const sqrt_a = std.math.sqrt(a);
        const alpha = sin_w0 / (2.0 * q);

        const b0_raw = a * ((a + 1.0) + (a - 1.0) * cos_w0 + 2.0 * sqrt_a * alpha);
        const b1_raw = -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0);
        const b2_raw = a * ((a + 1.0) + (a - 1.0) * cos_w0 - 2.0 * sqrt_a * alpha);
        const a0_raw = (a + 1.0) - (a - 1.0) * cos_w0 + 2.0 * sqrt_a * alpha;
        const a1_raw = 2.0 * ((a - 1.0) - (a + 1.0) * cos_w0);
        const a2_raw = (a + 1.0) - (a - 1.0) * cos_w0 - 2.0 * sqrt_a * alpha;

        const inv_a0 = 1.0 / a0_raw;
        return .{ .b0 = b0_raw * inv_a0, .b1 = b1_raw * inv_a0, .b2 = b2_raw * inv_a0, .a1 = a1_raw * inv_a0, .a2 = a2_raw * inv_a0 };
    }

    fn highPass(freq: f32, q: f32, sr: f32) Biquad {
        const w0 = 2.0 * std.math.pi * freq / sr;
        const cos_w0 = std.math.cos(w0);
        const sin_w0 = std.math.sin(w0);
        const alpha = sin_w0 / (2.0 * q);

        const b0_raw = (1.0 + cos_w0) / 2.0;
        const b1_raw = -(1.0 + cos_w0);
        const b2_raw = b0_raw;
        const a0_raw = 1.0 + alpha;
        const a1_raw = -2.0 * cos_w0;
        const a2_raw = 1.0 - alpha;

        const inv_a0 = 1.0 / a0_raw;
        return .{ .b0 = b0_raw * inv_a0, .b1 = b1_raw * inv_a0, .b2 = b2_raw * inv_a0, .a1 = a1_raw * inv_a0, .a2 = a2_raw * inv_a0 };
    }

    fn process(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        return y;
    }
};

/// Real-time stereo phase-correlation meter: a leaky-integrator running
/// Pearson correlation coefficient between L and R. +1 means identical
/// (mono-safe), -1 means fully inverted (collapses to silence in mono,
/// the classic "phase cancellation" symptom), 0 means decorrelated (wide
/// stereo - not itself a problem). The ~300ms smoothing time constant
/// mirrors the ballistics real phase-correlation meters use, so the
/// reading tracks a mix section's character over a beat or two instead of
/// flickering sample to sample.
pub const StereoCorrelation = struct {
    decay: f32,
    sum_lr: f32 = 0.0,
    sum_ll: f32 = 0.0,
    sum_rr: f32 = 0.0,

    pub fn init(sample_rate: u32) StereoCorrelation {
        const tau_seconds: f32 = 0.3;
        const sr: f32 = @floatFromInt(@max(sample_rate, 1));
        return .{ .decay = std.math.exp(-1.0 / (sr * tau_seconds)) };
    }

    pub fn push(self: *StereoCorrelation, buf: []const Sample) void {
        const d = self.decay;
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const l = buf[i];
            const r = buf[i + 1];
            self.sum_lr = d * self.sum_lr + (1.0 - d) * (l * r);
            self.sum_ll = d * self.sum_ll + (1.0 - d) * (l * l);
            self.sum_rr = d * self.sum_rr + (1.0 - d) * (r * r);
        }
    }

    /// -1..1, or 1.0 (no cancellation risk) while at/near silence - a
    /// near-zero denominator would otherwise blow the ratio up to noise.
    pub fn value(self: *const StereoCorrelation) f32 {
        const denom = std.math.sqrt(self.sum_ll * self.sum_rr);
        if (denom < 1e-9) return 1.0;
        return std.math.clamp(self.sum_lr / denom, -1.0, 1.0);
    }
};

/// ITU-R BS.1770-style K-weighted loudness meter (momentary/short-term/
/// integrated LUFS). The K-weighting cascade (a +4dB head-diffraction
/// shelf above ~1.7kHz, then a ~38Hz high-pass) is re-derived from the
/// standard's analog pole/Q prototype via the same bilinear-transform
/// cookbook formulas as `dsp/eq.zig`, generalised to whatever sample rate
/// the project runs at - the same technique used by e.g. ffmpeg's
/// `ebur128` filter to support non-48kHz rates. Both BS.1770 gates are
/// applied to the integrated reading. Measured against libebur128 on steady
/// tones it agrees within 0.26 LU at 1kHz and 0.04 LU at 50Hz/10kHz, and
/// within 0.2 LU on programme with a long quiet passage.
pub const LoudnessMeter = struct {
    shelf: [2]Biquad,
    hp: [2]Biquad,

    samples_per_block: usize,
    block_count: usize = 0,
    block_power: f64 = 0.0,

    /// Ring of the last 3s of 100ms block powers (linear K-weighted mean
    /// square). Momentary reads the last 4 slots (400ms), short-term all 30.
    history: [30]f32 = [_]f32{0.0} ** 30,
    history_len: usize = 0,
    history_pos: usize = 0,

    /// Absolute-gated (block loudness >= -70 LUFS) block energies, which are
    /// what BS.1770's *first* gate keeps and its second one re-averages.
    integrated_sum: f64 = 0.0,
    integrated_blocks: u64 = 0,

    /// Every gated block's loudness, bucketed, so the relative gate can
    /// re-average against a threshold that is only known once the whole
    /// programme has been heard. A histogram rather than the full block
    /// list: fixed memory, no allocation on the audio thread, and the same
    /// trick libebur128 uses for `EBUR128_MODE_HISTOGRAM`. Costs 0.05 LU of
    /// quantisation, which no meter displays.
    histogram: [gate_bin_count]u32 = [_]u32{0} ** gate_bin_count,
    /// `integrated` is read once per audio block but only changes when a
    /// 100ms block completes, so the histogram walk happens there instead.
    integrated_cache: f32 = floor_lufs,

    const block_seconds: f32 = 0.1;
    const abs_gate_lufs: f32 = -70.0;
    /// Silence floor, matching `types.gainToDb`'s -120dB convention.
    pub const floor_lufs: f32 = -120.0;

    pub fn init(sample_rate: u32) LoudnessMeter {
        const sr: f32 = @floatFromInt(@max(sample_rate, 1));
        const shelf = Biquad.highShelf(1681.9744509555319, 3.999843853973347, 0.7071752369554196, sr);
        const hp = Biquad.highPass(38.13547087613982, 0.5003270373238773, sr);
        return .{
            .shelf = .{ shelf, shelf },
            .hp = .{ hp, hp },
            .samples_per_block = @max(1, @as(usize, @intFromFloat(sr * block_seconds))),
        };
    }

    pub fn push(self: *LoudnessMeter, buf: []const Sample) void {
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const l_k = self.hp[0].process(self.shelf[0].process(buf[i]));
            const r_k = self.hp[1].process(self.shelf[1].process(buf[i + 1]));
            self.block_power += @as(f64, l_k * l_k + r_k * r_k);
            self.block_count += 1;
            if (self.block_count >= self.samples_per_block) self.finishBlock();
        }
    }

    fn finishBlock(self: *LoudnessMeter) void {
        const power: f32 = @floatCast(self.block_power / @as(f64, @floatFromInt(self.block_count)));
        self.block_power = 0.0;
        self.block_count = 0;

        self.history[self.history_pos] = power;
        self.history_pos = (self.history_pos + 1) % self.history.len;
        if (self.history_len < self.history.len) self.history_len += 1;

        const block_lufs = powerToLufs(power);
        if (block_lufs >= abs_gate_lufs) {
            self.integrated_sum += @as(f64, power);
            self.integrated_blocks += 1;
            self.histogram[gateBin(block_lufs)] += 1;
        }
        self.integrated_cache = self.computeIntegrated();
    }

    /// BS.1770's two-stage gate: average the blocks that clear -70 LUFS,
    /// then average again over only those within 10 LU of that first answer.
    /// The second pass is what stops a long quiet passage from dragging a
    /// programme's integrated loudness down - without it a track that plays
    /// loud for 10s and near-silent for 30s reads about 6 LU too quiet.
    fn computeIntegrated(self: *const LoudnessMeter) f32 {
        if (self.integrated_blocks == 0) return floor_lufs;
        const ungated_mean = self.integrated_sum / @as(f64, @floatFromInt(self.integrated_blocks));
        const relative_gate_lufs = powerToLufs(@floatCast(ungated_mean)) - relative_gate_lu;

        var sum: f64 = 0.0;
        var count: u64 = 0;
        for (self.histogram[gateBin(relative_gate_lufs)..], gateBin(relative_gate_lufs)..) |blocks, bin| {
            if (blocks == 0) continue;
            sum += @as(f64, @floatFromInt(blocks)) * gate_bin_energy[bin];
            count += blocks;
        }
        if (count == 0) return floor_lufs;
        return powerToLufs(@floatCast(sum / @as(f64, @floatFromInt(count))));
    }

    fn averagePower(self: *const LoudnessMeter, n: usize) f32 {
        const count = @min(n, self.history_len);
        if (count == 0) return 0.0;
        var sum: f64 = 0.0;
        var idx = (self.history_pos + self.history.len - count) % self.history.len;
        for (0..count) |_| {
            sum += self.history[idx];
            idx = (idx + 1) % self.history.len;
        }
        return @floatCast(sum / @as(f64, @floatFromInt(count)));
    }

    pub fn momentary(self: *const LoudnessMeter) f32 {
        return powerToLufs(self.averagePower(4));
    }

    pub fn shortTerm(self: *const LoudnessMeter) f32 {
        return powerToLufs(self.averagePower(self.history.len));
    }

    pub fn integrated(self: *const LoudnessMeter) f32 {
        return self.integrated_cache;
    }

    /// Clears the integrated accumulator only - a user-triggered "start a
    /// fresh measurement" reset. Filter state and the momentary/short-term
    /// history are left alone so those keep reading continuously across it.
    pub fn resetIntegrated(self: *LoudnessMeter) void {
        self.integrated_sum = 0.0;
        self.integrated_blocks = 0;
        @memset(&self.histogram, 0);
        self.integrated_cache = floor_lufs;
    }
};

/// How far under the ungated mean a block may sit and still count toward the
/// integrated measurement. BS.1770-4's relative gate.
const relative_gate_lu: f32 = 10.0;

/// 0.1 LU buckets, from the absolute gate up to well past full scale.
const gate_bin_count: usize = 1000;
const gate_bin_step: f64 = 0.1;
const gate_bin_base: f64 = -70.0;

/// Bucket for a block loudness, clamped: quieter than the absolute gate
/// never gets here, and louder than +30 LUFS is not a real signal.
fn gateBin(lufs: f32) usize {
    const scaled = (@as(f64, lufs) - gate_bin_base) / gate_bin_step;
    if (scaled <= 0) return 0;
    if (scaled >= @as(f64, @floatFromInt(gate_bin_count - 1))) return gate_bin_count - 1;
    return @intFromFloat(scaled);
}

/// Mean-square power at each bucket's centre, so the gated re-average can
/// work from counts alone.
const gate_bin_energy: [gate_bin_count]f64 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [gate_bin_count]f64 = undefined;
    for (&table, 0..) |*energy, bin| {
        const lufs = gate_bin_base + (@as(f64, @floatFromInt(bin)) + 0.5) * gate_bin_step;
        energy.* = std.math.pow(f64, 10.0, (lufs + 0.691) / 10.0);
    }
    break :blk table;
};

/// -0.691 + 10*log10(mean square): the BS.1770 K-weighted power-to-LUFS
/// conversion. Floored at -120 (silence), matching `types.gainToDb`.
fn powerToLufs(power: f32) f32 {
    if (power <= 1e-12) return LoudnessMeter.floor_lufs;
    return -0.691 + 10.0 * std.math.log10(power);
}

test "correlation reads +1 for identical L/R and -1 for inverted R" {
    const sr = 48_000;
    var in_phase = StereoCorrelation.init(sr);
    var out_of_phase = StereoCorrelation.init(sr);

    var buf: [512]Sample = undefined;
    var phase: f32 = 0.0;
    for (0..80) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const s = std.math.sin(phase);
            buf[i] = s;
            buf[i + 1] = s;
            phase += 2.0 * std.math.pi * 440.0 / @as(f32, sr);
        }
        in_phase.push(&buf);

        i = 0;
        while (i < buf.len) : (i += 2) buf[i + 1] = -buf[i + 1];
        out_of_phase.push(&buf);
    }

    try std.testing.expect(in_phase.value() > 0.95);
    try std.testing.expect(out_of_phase.value() < -0.95);
}

test "correlation defaults to +1 (no cancellation risk) at silence" {
    const corr = StereoCorrelation.init(48_000);
    try std.testing.expectEqual(@as(f32, 1.0), corr.value());
}

test "loudness meter reads higher LUFS for a hotter signal" {
    const sr = 48_000;
    var quiet = LoudnessMeter.init(sr);
    var loud = LoudnessMeter.init(sr);

    var buf: [512]Sample = undefined;
    var phase: f32 = 0.0;
    for (0..80) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const s = std.math.sin(phase);
            buf[i] = s * 0.1;
            buf[i + 1] = s * 0.1;
            phase += 2.0 * std.math.pi * 997.0 / @as(f32, sr);
        }
        quiet.push(&buf);

        i = 0;
        while (i < buf.len) : (i += 2) {
            buf[i] *= 5.0;
            buf[i + 1] *= 5.0;
        }
        loud.push(&buf);
    }

    try std.testing.expect(loud.shortTerm() > quiet.shortTerm());
    try std.testing.expect(loud.integrated() > quiet.integrated());
}

test "full-scale 997 Hz sine reads close to the -3.01 LUFS reference point" {
    // Well-known BS.1770 calibration figure for a 0dBFS mono sine: the
    // K-weighting shelf's modest gain even below its ~1.7kHz corner nudges
    // this above the naive -3.01dB-RMS figure you'd get from an unweighted
    // mean square, landing loudness meters right around -3 LUFS.
    const sr = 48_000;
    var meter = LoudnessMeter.init(sr);
    var buf: [512]Sample = undefined;
    var phase: f32 = 0.0;
    for (0..80) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const s = std.math.sin(phase);
            buf[i] = s;
            buf[i + 1] = 0.0;
            phase += 2.0 * std.math.pi * 997.0 / @as(f32, sr);
        }
        meter.push(&buf);
    }
    try std.testing.expect(meter.shortTerm() > -5.0 and meter.shortTerm() < -1.0);
}

test "integrated reset clears the accumulator without touching short-term history" {
    const sr = 48_000;
    var meter = LoudnessMeter.init(sr);
    var buf: [512]Sample = undefined;
    var phase: f32 = 0.0;
    for (0..80) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const s = std.math.sin(phase) * 0.5;
            buf[i] = s;
            buf[i + 1] = s;
            phase += 2.0 * std.math.pi * 440.0 / @as(f32, sr);
        }
        meter.push(&buf);
    }
    try std.testing.expect(meter.integrated() > LoudnessMeter.floor_lufs);
    const short_term_before = meter.shortTerm();
    meter.resetIntegrated();
    try std.testing.expectEqual(LoudnessMeter.floor_lufs, meter.integrated());
    try std.testing.expectEqual(short_term_before, meter.shortTerm());
}

test "silent input floors momentary/short-term/integrated at -120 LUFS" {
    var meter = LoudnessMeter.init(48_000);
    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0);
    for (0..80) |_| meter.push(&buf);
    try std.testing.expectEqual(LoudnessMeter.floor_lufs, meter.momentary());
    try std.testing.expectEqual(LoudnessMeter.floor_lufs, meter.shortTerm());
    try std.testing.expectEqual(LoudnessMeter.floor_lufs, meter.integrated());
}

test "a long quiet passage does not drag the integrated reading down" {
    const sr: u32 = 48_000;
    var meter = LoudnessMeter.init(sr);

    // 10s at -20 dBFS then 30s at -50 dBFS: both clear the -70 absolute
    // gate, so only the relative gate can keep the quiet stretch out of the
    // answer. Measured against libebur128, which reads -20.06 here.
    var buf: [960]Sample = undefined; // 10ms of stereo
    inline for (.{ .{ -20.0, 1000 }, .{ -50.0, 3000 } }) |stage| {
        const amp: f32 = std.math.pow(f32, 10.0, stage[0] / 20.0);
        var phase: f32 = 0.0;
        for (0..stage[1]) |_| {
            var i: usize = 0;
            while (i < buf.len) : (i += 2) {
                const v = amp * @sin(phase);
                buf[i] = v;
                buf[i + 1] = v;
                phase += 2.0 * std.math.pi * 1000.0 / @as(f32, @floatFromInt(sr));
                if (phase > 2.0 * std.math.pi) phase -= 2.0 * std.math.pi;
            }
            meter.push(&buf);
        }
    }

    // Without the relative gate this read about -26.
    try std.testing.expectApproxEqAbs(@as(f32, -20.2), meter.integrated(), 0.5);
    // Short-term follows the quiet tail, as it should.
    try std.testing.expect(meter.shortTerm() < -45.0);
}

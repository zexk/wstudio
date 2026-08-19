//! 3-band multiband compressor: two Linkwitz-Riley 4th-order (24dB/oct)
//! crossovers split the signal into low/mid/high bands, each squashed by its
//! own feed-forward peak-envelope compressor, then summed back together.
//! `style` toggles between ordinary downward-only compression and the "OTT"
//! variant, which additionally pulls quiet signal UP toward the same
//! threshold - the aggressive, "always moving" character the mode is named
//! after (after Xfer's OTT plugin).

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Compressor = @import("compressor.zig").Compressor;
const crossover = @import("crossover.zig");

const Sample = types.Sample;

pub const num_bands = 3;
pub const low: usize = 0;
pub const mid: usize = 1;
pub const high: usize = 2;

pub const Style = enum(u8) { classic, ott };

/// One band's compressor: same feed-forward peak-envelope/dB-domain gain
/// computer as `Compressor`, plus (in `.ott` style) a mirrored upward stage
/// that boosts signal below the threshold instead of leaving it alone -
/// the two stages share one threshold/ratio pair rather than exposing four,
/// keeping the param count in line with the rest of the FX chain (a plain
/// `Compressor` already spends 7 slots; three of these plus the shared
/// crossover/time controls would blow past that if up/down were independent).
/// The upward formula itself (and its lift ceiling) lives on `Compressor`,
/// which grew an upward mode of its own.
const BandComp = struct {
    threshold_db: f32 = -18.0,
    ratio: f32 = 4.0,
    makeup_db: f32 = 0.0,
    env: f32 = 0.0,

    fn gainFor(self: *BandComp, level: f32, attack: f32, release: f32, knee_db: f32, style: Style) f32 {
        // A ratio near/under 0 sends downwardReductionDb's `1/ratio` toward
        // +-inf, same instability as the plain `Compressor`.
        const threshold_db = dsp.sanitizeParam(self.threshold_db, -60.0, 0.0, -18.0);
        const ratio = dsp.sanitizeParam(self.ratio, 1.0, 20.0, 4.0);
        const makeup_db = dsp.sanitizeParam(self.makeup_db, -24.0, 24.0, 0.0);
        const over_db = Compressor.envelopeOverDb(&self.env, level, attack, release, threshold_db);
        // Downward: pull the excess above threshold down by `ratio` - same
        // envelope/ratio math as the plain `Compressor`.
        var reduction_db = Compressor.downwardReductionDb(over_db, ratio, knee_db);
        if (style == .ott) {
            // Upward (OTT only): push signal below threshold up toward it
            // by the same `ratio` - mirrors the downward formula around the
            // threshold instead of introducing a second ratio param.
            //
            // Added to the downward term rather than replacing it. Replacing
            // it was continuous only at knee 0: with a soft knee the downward
            // computer is already pulling down *below* the threshold, so
            // switching computers at over_db == 0 stepped the gain by
            // slope*knee/4 dB (2.4 dB at knee 24, ratio 5) right where the
            // envelope of real programme sits. `upwardBoostDb` is 0 above the
            // threshold, so the sum is exactly the old curve at knee 0.
            reduction_db += Compressor.upwardBoostDb(over_db, ratio, knee_db);
        }
        return types.dbToGain(reduction_db) * types.dbToGain(makeup_db);
    }

    fn reset(self: *BandComp) void {
        self.env = 0.0;
    }
};

pub const MultibandComp = struct {
    sample_rate: f32 = 48_000.0,
    xover_lo_hz: f32 = 200.0,
    xover_hi_hz: f32 = 2000.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
    /// Soft-knee width, dB, shared across all three bands - see
    /// `Compressor.downwardReductionDb`. 0 = hard knee.
    knee_db: f32 = 0.0,
    style: Style = .classic,
    /// Dry/wet blend, 0 (bypassed sound) .. 1 (fully processed) - lets the
    /// user dial back the OTT extreme without leaving the mode.
    mix: f32 = 1.0,
    bands: [num_bands]BandComp = .{
        .{ .threshold_db = -20.0, .ratio = 3.0 },
        .{ .threshold_db = -18.0, .ratio = 4.0 },
        .{ .threshold_db = -16.0, .ratio = 3.0 },
    },
    /// Most recent wet gain change for each band, before dry/wet mix.
    gain_db: [num_bands]f32 = .{ 0.0, 0.0, 0.0 },
    /// Per-channel crossover networks (L, R) - the split must not smear
    /// stereo state the way a single shared filter would.
    crossover: [2]crossover.Splitter(num_bands) = .{ .{}, .{} },

    pub fn init(sample_rate: u32) MultibandComp {
        var self: MultibandComp = .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
        self.recomputeCrossover();
        return self;
    }

    fn recomputeCrossover(self: *MultibandComp) void {
        for (&self.crossover) |*cx| cx.setFreqs(self.sample_rate, .{ self.xover_lo_hz, self.xover_hi_hz });
    }

    /// Clamped setters keep the two crossover points from crossing (a
    /// degenerate/negative-width mid band would make the crossover math
    /// produce nonsense coefficients).
    pub fn setXoverLo(self: *MultibandComp, hz: f32) void {
        if (!std.math.isFinite(hz)) return;
        self.xover_lo_hz = std.math.clamp(hz, 20.0, self.xover_hi_hz - 20.0);
        self.recomputeCrossover();
    }

    pub fn setXoverHi(self: *MultibandComp, hz: f32) void {
        if (!std.math.isFinite(hz)) return;
        self.xover_hi_hz = std.math.clamp(hz, self.xover_lo_hz + 20.0, 20_000.0);
        self.recomputeCrossover();
    }

    /// Set both crossover points at once from a previously-valid saved pair
    /// (persist load). Unlike calling `setXoverLo` then `setXoverHi`, this
    /// doesn't cross-clamp `lo` against `hi`'s stale pre-load value (still
    /// the struct's just-inserted default) - that clamped a saved
    /// lo=2500/hi=8000 pair down to lo=1980. `lo` is set first against only
    /// the absolute floor, then `hi` clamps against the now-final `lo`.
    pub fn setXovers(self: *MultibandComp, lo: f32, hi: f32) void {
        if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return;
        self.xover_lo_hz = std.math.clamp(lo, 20.0, 20_000.0 - 20.0);
        self.xover_hi_hz = std.math.clamp(hi, self.xover_lo_hz + 20.0, 20_000.0);
        self.recomputeCrossover();
    }

    pub fn processBlock(self: *MultibandComp, buf: []Sample) void {
        const frames = buf.len / 2;
        // A non-positive attack_ms/release_ms flips smoothingCoef's exponent
        // positive (coef >= 1, diverges within a block) - same instability
        // as the plain `Compressor`.
        const attack_ms = dsp.sanitizeParam(self.attack_ms, 0.1, 500.0, 10.0);
        const release_ms = dsp.sanitizeParam(self.release_ms, 1.0, 2000.0, 80.0);
        const knee_db = dsp.sanitizeParam(self.knee_db, 0.0, 24.0, 0.0);
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 1.0);
        const attack = dsp.smoothingCoefMs(attack_ms, self.sample_rate);
        const release = dsp.smoothingCoefMs(release_ms, self.sample_rate);

        for (0..frames) |i| {
            const dry_l = buf[i * 2];
            const dry_r = buf[i * 2 + 1];
            const bands_l = self.crossover[0].split(dry_l);
            const bands_r = self.crossover[1].split(dry_r);

            var wet_l: f32 = 0.0;
            var wet_r: f32 = 0.0;
            inline for (0..num_bands) |b| {
                const level = @max(@abs(bands_l[b]), @abs(bands_r[b]));
                const gain = self.bands[b].gainFor(level, attack, release, knee_db, self.style);
                self.gain_db[b] = types.gainToDb(gain);
                wet_l += bands_l[b] * gain;
                wet_r += bands_r[b] * gain;
            }

            buf[i * 2] = dry_l + (wet_l - dry_l) * mix;
            buf[i * 2 + 1] = dry_r + (wet_r - dry_r) * mix;
        }
    }

    pub const device = dsp.deviceOf(@This());

    /// Clears crossover/envelope state without touching `sample_rate` -
    /// callers embedding a `MultibandComp` by value (e.g. PolySynth's
    /// internal FX section) must use this instead of `= .{}`, which would
    /// reset sample_rate to the struct default and desync it from the real
    /// session rate.
    pub fn reset(self: *MultibandComp) void {
        for (&self.crossover) |*cx| cx.reset();
        for (&self.bands) |*b| b.reset();
        self.gain_db = .{ 0.0, 0.0, 0.0 };
    }
};

test "loud full-spectrum signal is attenuated toward each band's threshold" {
    var mb = MultibandComp.init(48_000);
    for (&mb.bands) |*b| {
        b.threshold_db = -12.0;
        b.ratio = 4.0;
    }
    // One sustained tone per crossover band (100Hz low, 1kHz mid, 6kHz high)
    // at -8dBFS each, so all three bands sit well above the -12dB threshold
    // and every band's envelope settles into real gain reduction. A square
    // wave can't do this: its energy is all at the fundamental and odd
    // harmonics, so a 6kHz square only ever drove the high band and the low
    // and mid bands sat silent at 0dB gain.
    const tau = 2.0 * std.math.pi;
    var buf: [512]Sample = undefined;
    for (0..200) |blk| {
        for (0..256) |i| {
            const n: f32 = @floatFromInt(blk * 256 + i);
            const s: f32 = 0.4 *
                (std.math.sin(tau * 100.0 * n / 48_000.0) +
                    std.math.sin(tau * 1_000.0 * n / 48_000.0) +
                    std.math.sin(tau * 6_000.0 * n / 48_000.0));
            buf[i * 2] = s;
            buf[i * 2 + 1] = s;
        }
        mb.processBlock(&buf);
    }
    try std.testing.expect(@abs(buf[510]) < 0.6);
    for (mb.gain_db) |gain_db| try std.testing.expect(gain_db < 0.0);
}

test "quiet signal passes through nearly untouched in classic style" {
    var mb = MultibandComp.init(48_000);
    var buf: [512]Sample = undefined;
    for (0..40) |_| {
        for (0..256) |i| {
            buf[i * 2] = 0.02;
            buf[i * 2 + 1] = 0.02;
        }
        mb.processBlock(&buf);
    }
    try std.testing.expectApproxEqAbs(@as(Sample, 0.02), buf[510], 0.01);
}

test "OTT style boosts a quiet signal upward, classic style leaves it alone" {
    var classic = MultibandComp.init(48_000);
    classic.style = .classic;
    var ott = MultibandComp.init(48_000);
    ott.style = .ott;
    for ([_]*MultibandComp{ &classic, &ott }) |mb| {
        for (&mb.bands) |*b| {
            b.threshold_db = -12.0;
            b.ratio = 4.0;
        }
    }

    var buf_classic: [512]Sample = undefined;
    var buf_ott: [512]Sample = undefined;
    for (0..200) |_| {
        for (0..256) |i| {
            // -40dBFS-ish broadband signal - well under the -12dB threshold.
            const s: f32 = if (i % 4 < 2) 0.01 else -0.01;
            buf_classic[i * 2] = s;
            buf_classic[i * 2 + 1] = s;
            buf_ott[i * 2] = s;
            buf_ott[i * 2 + 1] = s;
        }
        classic.processBlock(&buf_classic);
        ott.processBlock(&buf_ott);
    }
    try std.testing.expectApproxEqAbs(@as(Sample, 0.01), @abs(buf_classic[510]), 0.005);
    try std.testing.expect(@abs(buf_ott[510]) > @abs(buf_classic[510]) * 1.5);
}

test "the upward stage cannot lift a silent band without bound" {
    var mb = MultibandComp.init(48_000);
    mb.style = .ott;
    var buf: [512]Sample = undefined;
    for (0..200) |_| {
        @memset(&buf, 0.0);
        mb.processBlock(&buf);
    }
    // Silence reads as gainToDb's -120dB floor, a hundred under the default
    // thresholds: unbounded, the mirrored ratio asked for +67dB of boost on
    // whatever noise floor arrived next.
    for (mb.gain_db) |gain_db| try std.testing.expectApproxEqAbs(Compressor.max_upward_db, gain_db, 0.01);
}

test "mix blends between dry and fully-processed" {
    var mb = MultibandComp.init(48_000);
    mb.mix = 0.0;
    for (&mb.bands) |*b| {
        b.threshold_db = -60.0;
        b.ratio = 20.0;
    }
    var buf: [512]Sample = undefined;
    for (0..40) |_| {
        for (0..256) |i| {
            buf[i * 2] = 0.5;
            buf[i * 2 + 1] = 0.5;
        }
        mb.processBlock(&buf);
    }
    // mix=0 must pass the input through unchanged regardless of how hard
    // the (unheard) wet path would otherwise squash it.
    try std.testing.expectApproxEqAbs(@as(Sample, 0.5), buf[510], 1e-4);
}

test "knee_db reaches every band, softening reduction right at threshold" {
    var hard = MultibandComp.init(48_000);
    var soft = MultibandComp.init(48_000);
    soft.knee_db = 12.0;
    for ([_]*MultibandComp{ &hard, &soft }) |mb| {
        for (&mb.bands) |*b| {
            b.threshold_db = -12.0;
            b.ratio = 4.0;
        }
    }
    // A tone sitting exactly at threshold: hard knee applies zero downward
    // reduction there (over_db <= 0), the soft knee has already bent the
    // curve, so its band gains must read strictly lower.
    var buf_hard: [512]Sample = undefined;
    var buf_soft: [512]Sample = undefined;
    for (0..80) |_| {
        for (0..256) |i| {
            const n: f32 = @floatFromInt(i);
            const s: f32 = types.dbToGain(-12.0) * @sin(2.0 * std.math.pi * 1000.0 * n / 48_000.0);
            buf_hard[i * 2] = s;
            buf_hard[i * 2 + 1] = s;
            buf_soft[i * 2] = s;
            buf_soft[i * 2 + 1] = s;
        }
        hard.processBlock(&buf_hard);
        soft.processBlock(&buf_soft);
    }
    try std.testing.expect(soft.gain_db[mid] < hard.gain_db[mid] - 0.1);
}

test "invalid parameters cannot trap or poison output" {
    var mb = MultibandComp.init(48_000);
    mb.attack_ms = -1.0;
    mb.release_ms = std.math.inf(f32);
    mb.knee_db = -std.math.inf(f32);
    mb.mix = std.math.nan(f32);
    for (&mb.bands) |*b| {
        b.threshold_db = std.math.nan(f32);
        b.ratio = 0.0;
        b.makeup_db = std.math.inf(f32);
    }
    var buf: [512]Sample = undefined;
    for (0..256) |i| {
        buf[i * 2] = 0.5;
        buf[i * 2 + 1] = 0.5;
    }
    mb.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "setXoverLo/Hi keep the two crossover points from crossing" {
    var mb = MultibandComp.init(48_000);
    mb.setXoverHi(500.0);
    mb.setXoverLo(1000.0); // would cross 500Hz - must clamp below it instead
    try std.testing.expect(mb.xover_lo_hz < mb.xover_hi_hz);

    mb.setXoverLo(1000.0);
    mb.setXoverHi(200.0); // would cross 1000Hz - must clamp above it instead
    try std.testing.expect(mb.xover_hi_hz > mb.xover_lo_hz);
}

test "crossover setters ignore non-finite values" {
    var mb = MultibandComp.init(48_000);
    const lo = mb.xover_lo_hz;
    const hi = mb.xover_hi_hz;
    mb.setXoverLo(std.math.nan(f32));
    mb.setXoverHi(std.math.inf(f32));
    mb.setXovers(-std.math.inf(f32), 1000.0);
    try std.testing.expectEqual(lo, mb.xover_lo_hz);
    try std.testing.expectEqual(hi, mb.xover_hi_hz);
}

test "reset clears crossover filter state and band envelopes" {
    var mb = MultibandComp.init(48_000);
    var buf: [512]Sample = undefined;
    @memset(&buf, 0.8);
    mb.processBlock(&buf);
    try std.testing.expect(mb.bands[low].env > 0.0 or mb.bands[mid].env > 0.0 or mb.bands[high].env > 0.0);

    mb.device().reset();
    for (&mb.bands) |b| try std.testing.expectEqual(@as(f32, 0.0), b.env);
    // A cleared splitter passes its first sample straight through the
    // lowpass leg's numerator, with no history behind it.
    for (&mb.crossover) |*cx| {
        try std.testing.expectEqual(@as(f32, 0.0), cx.split(0.0)[low]);
    }
}

test "the three bands sum back flat, even with the crossover points close together" {
    const sr: u32 = 48_000;
    // A third of an octave apart: the worst case the setters allow anywhere
    // near the ear's most sensitive range, and where the uncompensated split
    // used to dig a -7 dB hole right at the lower crossover.
    var mb = MultibandComp.init(sr);
    mb.setXovers(500.0, 700.0);
    // Unity compressors: ratio 1 reduces nothing, so anything the output is
    // missing is the crossover's doing, not the gain stage's.
    for (&mb.bands) |*b| {
        b.threshold_db = 0.0;
        b.ratio = 1.0;
    }

    for ([_]f32{ 100, 300, 400, 500, 700, 1000, 4000 }) |freq| {
        var buf: [8192]Sample = undefined;
        for (0..buf.len / 2) |n| {
            const s = @sin(2.0 * std.math.pi * freq * @as(f32, @floatFromInt(n)) / 48_000.0);
            buf[n * 2] = s;
            buf[n * 2 + 1] = s;
        }
        mb.reset();
        mb.processBlock(&buf);

        // Second half only: the first is the filters settling.
        var acc: f64 = 0.0;
        for (buf[4096..]) |s| acc += @as(f64, s) * s;
        const rms = @sqrt(acc / 4096.0);
        // A unit sine's RMS is 1/sqrt(2). Half a dB either way.
        try std.testing.expectApproxEqAbs(@as(f64, 0.70710678), rms, 0.042);
    }
}

test "an OTT band's soft knee stays continuous across the threshold" {
    // The knee exists to remove the corner at the threshold. Switching from
    // the downward computer to the upward one at over_db == 0 put a bigger
    // one back: with a soft knee the downward computer already reduces below
    // the threshold, so the two disagreed by slope*knee/4 dB right where a
    // real envelope sits. Measured 2.4 dB at knee 24 / ratio 5.
    var band: BandComp = .{ .threshold_db = -18.0, .ratio = 5.0 };
    var prev: ?f32 = null;
    var level_db: f32 = -30.0;
    while (level_db <= -6.0) : (level_db += 0.25) {
        band.env = 0.0;
        // attack/release of 0 make the envelope follow the input exactly, so
        // this reads the static transfer curve rather than any ballistics.
        const gain_db = types.gainToDb(band.gainFor(types.dbToGain(level_db), 0.0, 0.0, 24.0, .ott));
        if (prev) |p| try std.testing.expect(@abs(gain_db - p) < 0.5);
        prev = gain_db;
    }
}

test "a hard-kneed OTT band is unchanged by the continuity fix" {
    // knee 0 leaves the downward computer at exactly 0 below the threshold,
    // so summing the two stages has to reproduce the old switch verbatim.
    var band: BandComp = .{ .threshold_db = -18.0, .ratio = 5.0 };
    var level_db: f32 = -40.0;
    while (level_db <= 0.0) : (level_db += 0.5) {
        band.env = 0.0;
        const got = band.gainFor(types.dbToGain(level_db), 0.0, 0.0, 0.0, .ott);
        const over_db = level_db - (-18.0);
        const want_db = if (over_db > 0.0)
            Compressor.downwardReductionDb(over_db, 5.0, 0.0)
        else
            Compressor.upwardBoostDb(over_db, 5.0, 0.0);
        try std.testing.expectApproxEqAbs(types.dbToGain(want_db), got, 1e-4);
    }
}

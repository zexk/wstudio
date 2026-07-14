//! 3-band multiband compressor: two Linkwitz-Riley 4th-order (24dB/oct)
//! crossovers split the signal into low/mid/high bands, each squashed by its
//! own feed-forward peak-envelope compressor, then summed back together.
//! `style` toggles between ordinary downward-only compression and the "OTT"
//! variant, which additionally pulls quiet signal UP toward the same
//! threshold — the aggressive, "always moving" character the mode is named
//! after (after Xfer's OTT plugin).

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Compressor = @import("compressor.zig").Compressor;

const Sample = types.Sample;

pub const num_bands = 3;
pub const low: usize = 0;
pub const mid: usize = 1;
pub const high: usize = 2;

pub const Style = enum(u8) { classic, ott };

/// One RBJ-cookbook lowpass/highpass biquad stage, fixed at Butterworth Q
/// (1/sqrt(2)) — run twice in series (see `LrFilter`) for a 24dB/oct
/// Linkwitz-Riley crossover slope. Deliberately its own tiny copy of the
/// coefficient math `dsp/eq.zig`'s `EqBand` already has (that type isn't
/// exported, and duplicating ~15 lines here is cheaper than exposing an EQ
/// internal to a module with different needs — same call the project made
/// for `dsp/slicer.zig` vs `DrumMachine`'s step sequencer).
const Biquad = struct {
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    const q: f32 = 0.70710678;

    fn setLowpass(self: *Biquad, sr: f32, freq: f32) void {
        const w0 = 2.0 * std.math.pi * freq / sr;
        const cos_w0 = std.math.cos(w0);
        const alpha = std.math.sin(w0) / (2.0 * q);
        const b0r = (1.0 - cos_w0) / 2.0;
        const b1r = 1.0 - cos_w0;
        const a0r = 1.0 + alpha;
        const a1r = -2.0 * cos_w0;
        const a2r = 1.0 - alpha;
        const inv = 1.0 / a0r;
        self.b0 = b0r * inv;
        self.b1 = b1r * inv;
        self.b2 = b0r * inv;
        self.a1 = a1r * inv;
        self.a2 = a2r * inv;
    }

    fn setHighpass(self: *Biquad, sr: f32, freq: f32) void {
        const w0 = 2.0 * std.math.pi * freq / sr;
        const cos_w0 = std.math.cos(w0);
        const alpha = std.math.sin(w0) / (2.0 * q);
        const b0r = (1.0 + cos_w0) / 2.0;
        const b1r = -(1.0 + cos_w0);
        const a0r = 1.0 + alpha;
        const a1r = -2.0 * cos_w0;
        const a2r = 1.0 - alpha;
        const inv = 1.0 / a0r;
        self.b0 = b0r * inv;
        self.b1 = b1r * inv;
        self.b2 = b0r * inv;
        self.a1 = a1r * inv;
        self.a2 = a2r * inv;
    }

    fn process(self: *Biquad, x: f32) f32 {
        // zig fmt: off
        const y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2
            - self.a1 * self.y1 - self.a2 * self.y2;
            // zig fmt: on
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        return y;
    }

    fn reset(self: *Biquad) void {
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }
};

/// Two cascaded Butterworth stages = one Linkwitz-Riley 4th-order filter.
const LrFilter = struct {
    stage: [2]Biquad = .{ .{}, .{} },

    fn setLowpass(self: *LrFilter, sr: f32, freq: f32) void {
        self.stage[0].setLowpass(sr, freq);
        self.stage[1].setLowpass(sr, freq);
    }

    fn setHighpass(self: *LrFilter, sr: f32, freq: f32) void {
        self.stage[0].setHighpass(sr, freq);
        self.stage[1].setHighpass(sr, freq);
    }

    fn process(self: *LrFilter, x: f32) f32 {
        return self.stage[1].process(self.stage[0].process(x));
    }

    fn reset(self: *LrFilter) void {
        self.stage[0].reset();
        self.stage[1].reset();
    }
};

/// Splits one channel into [low, mid, high] via two cascaded LR4 crossover
/// points: first low/high1 at `xover_lo`, then high1 splits again into
/// mid/high at `xover_hi`. Summing the three bands with no per-band gain
/// change reconstructs the input (Linkwitz-Riley's defining property) —
/// exactly the topology a per-band gain (the compressor) is meant to perturb.
const Crossover = struct {
    lo_lp: LrFilter = .{},
    lo_hp: LrFilter = .{},
    hi_lp: LrFilter = .{},
    hi_hp: LrFilter = .{},

    fn setFreqs(self: *Crossover, sr: f32, xover_lo: f32, xover_hi: f32) void {
        self.lo_lp.setLowpass(sr, xover_lo);
        self.lo_hp.setHighpass(sr, xover_lo);
        self.hi_lp.setLowpass(sr, xover_hi);
        self.hi_hp.setHighpass(sr, xover_hi);
    }

    fn split(self: *Crossover, x: f32) [num_bands]f32 {
        const low_band = self.lo_lp.process(x);
        const high1 = self.lo_hp.process(x);
        const mid_band = self.hi_lp.process(high1);
        const high_band = self.hi_hp.process(high1);
        return .{ low_band, mid_band, high_band };
    }

    fn reset(self: *Crossover) void {
        self.lo_lp.reset();
        self.lo_hp.reset();
        self.hi_lp.reset();
        self.hi_hp.reset();
    }
};

/// One band's compressor: same feed-forward peak-envelope/dB-domain gain
/// computer as `Compressor`, plus (in `.ott` style) a mirrored upward stage
/// that boosts signal below the threshold instead of leaving it alone —
/// the two stages share one threshold/ratio pair rather than exposing four,
/// keeping the param count in line with the rest of the FX chain (a plain
/// `Compressor` already spends 7 slots; three of these plus the shared
/// crossover/time controls would blow past that if up/down were independent).
const BandComp = struct {
    threshold_db: f32 = -18.0,
    ratio: f32 = 4.0,
    makeup_db: f32 = 0.0,
    env: f32 = 0.0,

    fn gainFor(self: *BandComp, level: f32, attack: f32, release: f32, style: Style) f32 {
        const over_db = Compressor.envelopeOverDb(&self.env, level, attack, release, self.threshold_db);
        // Downward: pull the excess above threshold down by `ratio` — same
        // envelope/ratio math as the plain `Compressor`.
        var reduction_db = Compressor.downwardReductionDb(over_db, self.ratio);
        if (over_db <= 0.0 and style == .ott) {
            // Upward (OTT only): push signal below threshold up toward it
            // by the same `ratio` — mirrors the downward formula around the
            // threshold instead of introducing a second ratio param.
            reduction_db = -over_db * (1.0 - 1.0 / self.ratio);
        }
        return types.dbToGain(reduction_db) * types.dbToGain(self.makeup_db);
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
    style: Style = .classic,
    /// Dry/wet blend, 0 (bypassed sound) .. 1 (fully processed) — lets the
    /// user dial back the OTT extreme without leaving the mode.
    mix: f32 = 1.0,
    bands: [num_bands]BandComp = .{
        .{ .threshold_db = -20.0, .ratio = 3.0 },
        .{ .threshold_db = -18.0, .ratio = 4.0 },
        .{ .threshold_db = -16.0, .ratio = 3.0 },
    },
    /// Per-channel crossover networks (L, R) — the split must not smear
    /// stereo state the way a single shared filter would.
    crossover: [2]Crossover = .{ .{}, .{} },

    pub fn init(sample_rate: u32) MultibandComp {
        var self: MultibandComp = .{ .sample_rate = @floatFromInt(sample_rate) };
        self.recomputeCrossover();
        return self;
    }

    fn recomputeCrossover(self: *MultibandComp) void {
        for (&self.crossover) |*cx| cx.setFreqs(self.sample_rate, self.xover_lo_hz, self.xover_hi_hz);
    }

    /// Clamped setters keep the two crossover points from crossing (a
    /// degenerate/negative-width mid band would make the crossover math
    /// produce nonsense coefficients).
    pub fn setXoverLo(self: *MultibandComp, hz: f32) void {
        self.xover_lo_hz = std.math.clamp(hz, 20.0, self.xover_hi_hz - 20.0);
        self.recomputeCrossover();
    }

    pub fn setXoverHi(self: *MultibandComp, hz: f32) void {
        self.xover_hi_hz = std.math.clamp(hz, self.xover_lo_hz + 20.0, 20_000.0);
        self.recomputeCrossover();
    }

    /// Set both crossover points at once from a previously-valid saved pair
    /// (persist load). Unlike calling `setXoverLo` then `setXoverHi`, this
    /// doesn't cross-clamp `lo` against `hi`'s stale pre-load value (still
    /// the struct's just-inserted default) — that clamped a saved
    /// lo=2500/hi=8000 pair down to lo=1980. `lo` is set first against only
    /// the absolute floor, then `hi` clamps against the now-final `lo`.
    pub fn setXovers(self: *MultibandComp, lo: f32, hi: f32) void {
        self.xover_lo_hz = std.math.clamp(lo, 20.0, 20_000.0 - 20.0);
        self.xover_hi_hz = std.math.clamp(hi, self.xover_lo_hz + 20.0, 20_000.0);
        self.recomputeCrossover();
    }

    fn smoothingCoef(self: *const MultibandComp, ms: f32) f32 {
        return @exp(-1.0 / (ms * 0.001 * self.sample_rate));
    }

    pub fn processBlock(self: *MultibandComp, buf: []Sample) void {
        const frames = buf.len / 2;
        const attack = self.smoothingCoef(self.attack_ms);
        const release = self.smoothingCoef(self.release_ms);

        for (0..frames) |i| {
            const dry_l = buf[i * 2];
            const dry_r = buf[i * 2 + 1];
            const bands_l = self.crossover[0].split(dry_l);
            const bands_r = self.crossover[1].split(dry_r);

            var wet_l: f32 = 0.0;
            var wet_r: f32 = 0.0;
            inline for (0..num_bands) |b| {
                const level = @max(@abs(bands_l[b]), @abs(bands_r[b]));
                const gain = self.bands[b].gainFor(level, attack, release, self.style);
                wet_l += bands_l[b] * gain;
                wet_r += bands_r[b] * gain;
            }

            buf[i * 2] = dry_l + (wet_l - dry_l) * self.mix;
            buf[i * 2 + 1] = dry_r + (wet_r - dry_r) * self.mix;
        }
    }

    pub const device = dsp.deviceOf(@This());

    /// Clears crossover/envelope state without touching `sample_rate` —
    /// callers embedding a `MultibandComp` by value (e.g. PolySynth's
    /// internal FX section) must use this instead of `= .{}`, which would
    /// reset sample_rate to the struct default and desync it from the real
    /// session rate.
    pub fn reset(self: *MultibandComp) void {
        for (&self.crossover) |*cx| cx.reset();
        for (&self.bands) |*b| b.reset();
    }
};

test "loud full-spectrum signal is attenuated toward each band's threshold" {
    var mb = MultibandComp.init(48_000);
    for (&mb.bands) |*b| {
        b.threshold_db = -12.0;
        b.ratio = 4.0;
    }
    // A few hundred blocks of a 0dBFS square wave (broadband via the sharp
    // edges) so all three bands see plenty of signal and the envelopes settle.
    var buf: [512]Sample = undefined;
    for (0..200) |blk| {
        for (0..256) |i| {
            const s: f32 = if ((blk * 256 + i) % 8 < 4) 1.0 else -1.0;
            buf[i * 2] = s;
            buf[i * 2 + 1] = s;
        }
        mb.processBlock(&buf);
    }
    try std.testing.expect(@abs(buf[510]) < 0.6);
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
            // -40dBFS-ish broadband signal — well under the -12dB threshold.
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

test "setXoverLo/Hi keep the two crossover points from crossing" {
    var mb = MultibandComp.init(48_000);
    mb.setXoverHi(500.0);
    mb.setXoverLo(1000.0); // would cross 500Hz — must clamp below it instead
    try std.testing.expect(mb.xover_lo_hz < mb.xover_hi_hz);

    mb.setXoverLo(1000.0);
    mb.setXoverHi(200.0); // would cross 1000Hz — must clamp above it instead
    try std.testing.expect(mb.xover_hi_hz > mb.xover_lo_hz);
}

test "reset clears crossover filter state and band envelopes" {
    var mb = MultibandComp.init(48_000);
    var buf: [512]Sample = undefined;
    @memset(&buf, 0.8);
    mb.processBlock(&buf);
    try std.testing.expect(mb.bands[low].env > 0.0 or mb.bands[mid].env > 0.0 or mb.bands[high].env > 0.0);

    mb.device().reset();
    for (&mb.bands) |b| try std.testing.expectEqual(@as(f32, 0.0), b.env);
    for (&mb.crossover) |cx| {
        try std.testing.expectEqual(@as(f32, 0.0), cx.lo_lp.stage[0].y1);
    }
}

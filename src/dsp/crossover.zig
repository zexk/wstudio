//! Linkwitz-Riley band splitting, as a type any unit can hold.
//!
//! One channel in, N bands out, split at N-1 crossover points. Summing the
//! bands with no per-band change reconstructs the input - Linkwitz-Riley's
//! defining property, and exactly what a per-band gain (a multiband
//! compressor, a band solo) is meant to perturb.
//!
//! The band count is a comptime parameter rather than a fixed 3 so the same
//! network can back a wider unit later without another copy of this math;
//! what a wider unit would still need is the runtime plumbing for its extra
//! params, not more DSP.

const std = @import("std");

/// One RBJ-cookbook lowpass/highpass biquad stage, fixed at Butterworth Q
/// (1/sqrt(2)) - run twice in series (see `Lr4`) for a 24 dB/oct
/// Linkwitz-Riley slope. Its own small copy of the coefficient math
/// `dsp/eq.zig`'s `EqBand` also has: that type carries a band's gain, kind,
/// slope, dynamics and solo state, none of which a crossover leg wants, and
/// it is not exported.
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

    pub const Kind = enum { lowpass, highpass };

    // RBJ cookbook LP/HP - identical denominators, the numerator flips
    // sign with the passband.
    fn set(self: *Biquad, sr: f32, freq: f32, kind: Kind) void {
        const w0 = 2.0 * std.math.pi * freq / sr;
        const cos_w0 = std.math.cos(w0);
        const alpha = std.math.sin(w0) / (2.0 * q);
        const b0r = switch (kind) {
            .lowpass => (1.0 - cos_w0) / 2.0,
            .highpass => (1.0 + cos_w0) / 2.0,
        };
        const b1r = switch (kind) {
            .lowpass => 1.0 - cos_w0,
            .highpass => -(1.0 + cos_w0),
        };
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
const Lr4 = struct {
    stage: [2]Biquad = .{ .{}, .{} },

    fn set(self: *Lr4, sr: f32, freq: f32, kind: Biquad.Kind) void {
        self.stage[0].set(sr, freq, kind);
        self.stage[1].set(sr, freq, kind);
    }

    fn process(self: *Lr4, x: f32) f32 {
        return self.stage[1].process(self.stage[0].process(x));
    }

    fn reset(self: *Lr4) void {
        self.stage[0].reset();
        self.stage[1].reset();
    }
};

/// An LR4 lowpass and highpass at the same frequency, summed: the pair is an
/// allpass, which is what a band that branched off before a later split has
/// to be run through to arrive in phase with the bands that went through it.
const Allpass = struct {
    lp: Lr4 = .{},
    hp: Lr4 = .{},

    fn set(self: *Allpass, sr: f32, freq: f32) void {
        self.lp.set(sr, freq, .lowpass);
        self.hp.set(sr, freq, .highpass);
    }

    fn process(self: *Allpass, x: f32) f32 {
        return self.lp.process(x) + self.hp.process(x);
    }

    fn reset(self: *Allpass) void {
        self.lp.reset();
        self.hp.reset();
    }
};

/// Splits one channel into `bands` bands at `bands - 1` ascending crossover
/// points. Cascaded: the first point splits off the lowest band and passes
/// the rest along, and so on.
///
/// Each split leaves its LR4 pair's allpass phase on everything that goes
/// through it, so a band that branched off earlier arrives out of step with
/// the bands that did not - measured at -7 dB around the lower crossover of
/// a 3-band split with the points a third of an octave apart. Every band is
/// therefore run through the allpass of every split that came after it,
/// which puts all of them back on one phase.
pub fn Splitter(comptime bands: usize) type {
    comptime std.debug.assert(bands >= 2);
    const splits = bands - 1;
    return struct {
        const Self = @This();

        lp: [splits]Lr4 = @splat(.{}),
        hp: [splits]Lr4 = @splat(.{}),
        /// `phase[b][j]` compensates band `b` for split `j`. Only the
        /// entries with `j > b` are ever used; the square keeps the indexing
        /// obvious, and an unused `Lr4` is 18 floats.
        phase: [splits][splits]Allpass = @splat(@splat(.{})),

        /// `freqs` must be ascending; callers clamp their own params (see
        /// `MultibandComp.setXovers`) rather than have this reorder them.
        pub fn setFreqs(self: *Self, sr: f32, freqs: [splits]f32) void {
            // An RBJ biquad is only well behaved below Nyquist: past it `w0`
            // wraps, `alpha` can come out negative, and the stage turns into
            // an oscillator that runs away to inf within a block. Callers
            // clamp their crossover knobs to 20 kHz, which is already above
            // Nyquist on any device under 44.1k, so the guard belongs here
            // where all of them pass through rather than in each of them.
            var safe: [splits]f32 = undefined;
            const ceiling = @max(20.0, sr * 0.45);
            for (&safe, freqs) |*out, f| out.* = std.math.clamp(f, 20.0, ceiling);
            for (&self.lp, &self.hp, safe) |*lp, *hp, f| {
                lp.set(sr, f, .lowpass);
                hp.set(sr, f, .highpass);
            }
            for (&self.phase, 0..) |*row, b| {
                for (row[b + 1 ..], safe[b + 1 ..]) |*ap, f| ap.set(sr, f);
            }
        }

        pub fn split(self: *Self, x: f32) [bands]f32 {
            var out: [bands]f32 = undefined;
            var rest = x;
            for (0..splits) |b| {
                var band = self.lp[b].process(rest);
                // Catch up on every split this band did not go through.
                for (self.phase[b][b + 1 ..]) |*ap| band = ap.process(band);
                out[b] = band;
                rest = self.hp[b].process(rest);
            }
            out[bands - 1] = rest;
            return out;
        }

        pub fn reset(self: *Self) void {
            for (&self.lp) |*f| f.reset();
            for (&self.hp) |*f| f.reset();
            for (&self.phase) |*row| for (row) |*ap| ap.reset();
        }
    };
}

test "the bands sum back to the input" {
    // Linkwitz-Riley's defining property, and the one the phase
    // compensation above exists to preserve: unity through the split, not
    // the -7 dB notch an uncompensated cascade leaves at a crossover.
    inline for ([_]usize{ 2, 3, 4 }) |n| {
        var sp: Splitter(n) = .{};
        var freqs: [n - 1]f32 = undefined;
        for (&freqs, 0..) |*f, i| f.* = 200.0 * std.math.pow(f32, 3.0, @floatFromInt(i));
        sp.setFreqs(48_000.0, freqs);

        // Right at a crossover, where cancellation would show worst.
        const probe_hz: f32 = freqs[0];
        var peak_in: f32 = 0.0;
        var peak_sum: f32 = 0.0;
        for (0..4096) |i| {
            const t = @as(f32, @floatFromInt(i)) / 48_000.0;
            const x = @sin(2.0 * std.math.pi * probe_hz * t);
            var sum: f32 = 0.0;
            for (sp.split(x)) |band| sum += band;
            if (i > 1024) { // past the filters' fill time
                peak_in = @max(peak_in, @abs(x));
                peak_sum = @max(peak_sum, @abs(sum));
            }
        }
        try std.testing.expectApproxEqAbs(peak_in, peak_sum, 0.05);
    }
}

test "each band keeps its own part of the spectrum" {
    var sp: Splitter(3) = .{};
    sp.setFreqs(48_000.0, .{ 200.0, 2000.0 });

    for ([_]struct { hz: f32, band: usize }{
        .{ .hz = 50.0, .band = 0 },
        .{ .hz = 700.0, .band = 1 },
        .{ .hz = 8000.0, .band = 2 },
    }) |probe| {
        var peak: [3]f32 = @splat(0.0);
        for (0..4096) |i| {
            const t = @as(f32, @floatFromInt(i)) / 48_000.0;
            const bands = sp.split(@sin(2.0 * std.math.pi * probe.hz * t));
            if (i > 1024) for (bands, &peak) |v, *p| {
                p.* = @max(p.*, @abs(v));
            };
        }
        for (peak, 0..) |p, b| {
            if (b == probe.band) {
                try std.testing.expect(p > 0.7);
            } else {
                try std.testing.expect(p < 0.1);
            }
        }
        sp.reset();
    }
}

const std = @import("std");
const types = @import("../core/types.zig");
const fft = @import("fft.zig");

pub const num_bands = 80;
pub const default_fft_size = 2048;
pub const default_hop_size = 1024;

const Sample = types.Sample;

pub const BandRange = struct {
    first_bin: usize,
    last_bin: usize,
};

pub const SpectrumSnapshot = struct {
    bins: [num_bands]f32,
};

pub const SpectrumAnalyzer = struct {
    fft_size: usize,
    hop_size: usize,
    sample_rate: u32,

    buffer: []f32,
    accumulated: usize,

    real: []f32,
    imag: []f32,
    window: []f32,
    mags: []f32,

    bands: [num_bands]BandRange,
    band_mags: [num_bands]f32,

    active: std.atomic.Value(bool),
    gen: std.atomic.Value(u32),
    bin_atomics: [num_bands]std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !SpectrumAnalyzer {
        return initConfig(allocator, sample_rate, default_fft_size, default_hop_size);
    }

    pub fn initConfig(allocator: std.mem.Allocator, sample_rate: u32, fsize: usize, hsize: usize) !SpectrumAnalyzer {
        const buffer = try allocator.alloc(f32, fsize);
        errdefer allocator.free(buffer);
        const real = try allocator.alloc(f32, fsize);
        errdefer allocator.free(real);
        const imag = try allocator.alloc(f32, fsize);
        errdefer allocator.free(imag);
        const window = try allocator.alloc(f32, fsize);
        errdefer allocator.free(window);
        const mags = try allocator.alloc(f32, fsize / 2 + 1);
        errdefer allocator.free(mags);

        var self: SpectrumAnalyzer = .{
            .fft_size = fsize,
            .hop_size = hsize,
            .sample_rate = @max(sample_rate, 1),
            .buffer = buffer,
            .accumulated = 0,
            .real = real,
            .imag = imag,
            .window = window,
            .mags = mags,
            .bands = undefined,
            .band_mags = undefined,
            .active = std.atomic.Value(bool).init(false),
            .gen = std.atomic.Value(u32).init(0),
            // Seed at toDb's silence floor, not bit-pattern 0 (= 0.0dB): a
            // snapshot taken before the first analyze() lands must read as
            // silence, or the view paints every band pinned at the 0dB line.
            .bin_atomics = .{std.atomic.Value(u32).init(@bitCast(@as(f32, -120.0)))} ** num_bands,
        };
        @memset(self.buffer, 0.0);
        for (self.window, 0..) |*w, i| {
            w.* = 0.5 * (1.0 - std.math.cos(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fsize - 1))));
        }
        self.precomputeBands();
        return self;
    }

    pub fn deinit(self: *SpectrumAnalyzer, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        allocator.free(self.real);
        allocator.free(self.imag);
        allocator.free(self.window);
        allocator.free(self.mags);
    }

    fn precomputeBands(self: *SpectrumAnalyzer) void {
        const sr_f: f32 = @floatFromInt(self.sample_rate);
        const n_f: f32 = @floatFromInt(self.fft_size);
        const nyquist = sr_f / 2.0;
        const start_freq: f32 = 20.0;
        const ratio = std.math.pow(f32, nyquist / start_freq, @as(f32, 1.0) / @as(f32, @floatFromInt(num_bands)));

        for (&self.bands, 0..) |*band, d| {
            const low_freq = start_freq * std.math.pow(f32, ratio, @as(f32, @floatFromInt(d)));
            const high_freq = start_freq * std.math.pow(f32, ratio, @as(f32, @floatFromInt(d + 1)));
            const first_bin_f = low_freq * n_f / sr_f;
            const last_bin_f = high_freq * n_f / sr_f;
            const first = @as(usize, @intFromFloat(@ceil(first_bin_f)));
            var last_excl = @as(usize, @intFromFloat(@ceil(last_bin_f)));
            if (last_excl > self.fft_size / 2) last_excl = self.fft_size / 2;
            band.first_bin = @min(first, self.fft_size / 2);
            band.last_bin = if (last_excl > band.first_bin) last_excl - 1 else band.first_bin;
        }
    }

    pub fn push(self: *SpectrumAnalyzer, samples: []const Sample) void {
        if (!self.active.load(.monotonic)) return;
        const frames = samples.len / 2;
        var src: usize = 0;
        while (src < frames and self.accumulated < self.fft_size) : (src += 1) {
            const mono = (samples[src * 2] + samples[src * 2 + 1]) * 0.5;
            self.buffer[self.accumulated] = mono;
            self.accumulated += 1;
        }
    }

    pub fn analyze(self: *SpectrumAnalyzer) void {
        if (!self.active.load(.monotonic) or self.accumulated < self.fft_size) return;

        @memcpy(self.real, self.buffer[0..self.fft_size]);
        @memset(self.imag, 0.0);
        for (self.real, self.window) |*r, w| r.* *= w;
        fft.fft(self.fft_size, self.real, self.imag);

        // Normalise to amplitude: /N for the transform, x2 for the single-sided
        // spectrum's split across +-f, x2 to undo the Hann window's 0.5 coherent
        // gain. A full-scale sine then reads ~0dB regardless of fft_size; raw
        // magnitudes would sit ~54dB hot at N=2048 and pin every display bin.
        const amp_norm = 4.0 / @as(f32, @floatFromInt(self.fft_size));
        for (self.mags, 0..) |*m, k| {
            m.* = fft.magnitude(self.real[k], self.imag[k]) * amp_norm;
        }
        for (&self.band_mags, &self.bands) |*bm, *band| {
            if (band.last_bin <= band.first_bin) {
                bm.* = self.mags[band.first_bin];
            } else {
                var sum: f32 = 0.0;
                const count = band.last_bin - band.first_bin + 1;
                for (self.mags[band.first_bin .. band.last_bin + 1]) |m| sum += m;
                bm.* = sum / @as(f32, @floatFromInt(count));
            }
        }

        fft.toDb(&self.band_mags);

        self.gen.store(self.gen.load(.acquire) +% 1, .release);
        for (&self.bin_atomics, &self.band_mags) |*a, m| {
            a.store(@bitCast(m), .monotonic);
        }
        self.gen.store(self.gen.load(.monotonic) +% 1, .release);

        const hop = self.hop_size;
        if (self.accumulated > hop) {
            std.mem.copyForwards(f32, self.buffer[0 .. self.accumulated - hop], self.buffer[hop..self.accumulated]);
            self.accumulated -= hop;
        } else {
            self.accumulated = 0;
        }
    }

    pub fn snapshot(self: *const SpectrumAnalyzer) ?SpectrumSnapshot {
        if (!self.active.load(.acquire)) return null;
        for (0..3) |_| {
            const gen1 = self.gen.load(.acquire);
            if (gen1 & 1 != 0) continue;
            var snap: SpectrumSnapshot = undefined;
            for (&snap.bins, &self.bin_atomics) |*b, *a| {
                b.* = @bitCast(a.load(.monotonic));
            }
            const gen2 = self.gen.load(.acquire);
            if (gen1 == gen2) return snap;
        }
        return null;
    }
};

test "zero sample rate falls back to a finite analyzer rate" {
    var sa = try SpectrumAnalyzer.init(std.testing.allocator, 0);
    defer sa.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), sa.sample_rate);
}

test "SpectrumAnalyzer produces non-zero output for sine" {
    var sa = try SpectrumAnalyzer.init(std.testing.allocator, 48_000);
    defer sa.deinit(std.testing.allocator);
    sa.active.store(true, .monotonic);

    const freq: f32 = 440.0;
    var block: [512]Sample = undefined;
    const sr: f32 = 48_000;

    // Fill buffer with 440 Hz sine
    for (0..8) |_| {
        for (&block, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i / 2));
            s.* = @sin(2.0 * std.math.pi * freq * t / sr);
        }
        sa.push(&block);
        sa.analyze();
    }

    const snap = sa.snapshot();
    try std.testing.expect(snap != null);

    var max_idx: usize = 0;
    var max_val: f32 = -999.0;
    for (snap.?.bins, 0..) |val, i| {
        if (val > max_val) {
            max_val = val;
            max_idx = i;
        }
    }

    try std.testing.expect(max_val > -30.0);
    _ = &max_idx;
}

const std = @import("std");

fn log2Int(x: usize) usize {
    var n: usize = 0;
    var tmp = x;
    while (tmp > 1) : (tmp >>= 1) n += 1;
    return n;
}

pub fn bitReverse(x: usize, n: usize) usize {
    const bits = log2Int(n);
    var result: usize = 0;
    var tmp = x;
    for (0..bits) |_| {
        result = (result << 1) | (tmp & 1);
        tmp >>= 1;
    }
    return result;
}

pub fn fft(n: usize, real: []f32, imag: []f32) void {
    std.debug.assert(std.math.isPowerOfTwo(n));
    std.debug.assert(real.len >= n);
    std.debug.assert(imag.len >= n);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const j = bitReverse(i, n);
        if (j > i) {
            std.mem.swap(f32, &real[i], &real[j]);
            std.mem.swap(f32, &imag[i], &imag[j]);
        }
    }

    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half = len >> 1;
        // The twiddle advances by repeated complex multiply, up to `half`
        // steps in the last stage, so its own rounding error compounds along
        // the way. Carrying the rotation in f64 keeps that accumulation far
        // below the f32 the samples are stored in; in f32 it is visible.
        const w_re = std.math.cos(std.math.pi / @as(f64, @floatFromInt(half)));
        const w_im = -std.math.sin(std.math.pi / @as(f64, @floatFromInt(half)));

        var ii: usize = 0;
        while (ii < n) : (ii += len) {
            var wr: f64 = 1.0;
            var wi: f64 = 0.0;
            var j: usize = 0;
            while (j < half) : (j += 1) {
                const k = ii + j;
                const wr32: f32 = @floatCast(wr);
                const wi32: f32 = @floatCast(wi);
                const tr = wr32 * real[k + half] - wi32 * imag[k + half];
                const ti = wr32 * imag[k + half] + wi32 * real[k + half];
                real[k + half] = real[k] - tr;
                imag[k + half] = imag[k] - ti;
                real[k] += tr;
                imag[k] += ti;
                const nwr = wr * w_re - wi * w_im;
                wi = wr * w_im + wi * w_re;
                wr = nwr;
            }
        }
    }
}

pub fn hannWindow(buf: []f32) void {
    const n = buf.len;
    if (n == 0) return;
    if (n == 1) return;
    for (buf, 0..) |*s, i| {
        s.* *= 0.5 * (1.0 - std.math.cos(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1))));
    }
}

pub fn magnitude(re: f32, im: f32) f32 {
    return std.math.sqrt(re * re + im * im);
}

pub fn toDb(buf: []f32) void {
    for (buf) |*s| {
        s.* = if (!std.math.isFinite(s.*) or s.* <= 1.0e-6) -120.0 else 20.0 * std.math.log10(s.*);
    }
}

test "fft produces correct peak for 1 kHz sine" {
    const sr = 48_000;
    const N: usize = 1024;
    var real: [N]f32 = undefined;
    var imag: [N]f32 = undefined;
    @memset(&imag, 0.0);

    const freq = 1000.0;
    for (&real, 0..) |*s, i| {
        s.* = @sin(2.0 * std.math.pi * freq * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr)));
    }
    hannWindow(&real);
    fft(N, &real, &imag);

    var mag: [N]f32 = undefined;
    for (&mag, 0..) |*m, i| {
        m.* = magnitude(real[i], imag[i]);
    }

    var max_bin: usize = 0;
    var max_val: f32 = 0.0;
    for (mag[1 .. N / 2], 1..) |m, bin| {
        if (m > max_val) {
            max_val = m;
            max_bin = bin;
        }
    }

    const expected_bin: usize = @intFromFloat(freq * @as(f32, @floatFromInt(N)) / @as(f32, @floatFromInt(sr)) + 0.5);
    try std.testing.expectEqual(expected_bin, max_bin);
}

test "toDb clamps at -120" {
    var buf = [_]f32{ 1.0, 0.5, 1.0e-7, 0.0 };
    toDb(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), buf[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -6.02), buf[1], 0.01);
    try std.testing.expectEqual(@as(f32, -120.0), buf[2]);
    try std.testing.expectEqual(@as(f32, -120.0), buf[3]);
}

test "toDb replaces non-finite magnitudes with the silence floor" {
    var buf = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    toDb(&buf);
    for (buf) |value| try std.testing.expectEqual(@as(f32, -120.0), value);
}

test "hannWindow handles empty and single-sample buffers" {
    var empty: [0]f32 = .{};
    hannWindow(&empty);

    var single = [_]f32{1.0};
    hannWindow(&single);
    try std.testing.expectEqual(@as(f32, 1.0), single[0]);
}

test "bitReverse round-trip" {
    const N: usize = 1024;
    for (0..N) |i| {
        const j = bitReverse(bitReverse(i, N), N);
        try std.testing.expectEqual(i, j);
    }
}

/// Naive O(n^2) DFT in f64, for tests only: the yardstick the fast path is
/// held against.
fn referenceDft(samples: []const f32, bin: usize) struct { re: f64, im: f64 } {
    const n = samples.len;
    var re: f64 = 0;
    var im: f64 = 0;
    for (samples, 0..) |s, i| {
        const angle = -2.0 * std.math.pi * @as(f64, @floatFromInt(bin)) *
            @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        re += @as(f64, s) * std.math.cos(angle);
        im += @as(f64, s) * std.math.sin(angle);
    }
    return .{ .re = re, .im = im };
}

test "1024-point transform tracks the reference DFT across every bin" {
    const N: usize = 1024;
    var real: [N]f32 = undefined;
    var imag = [_]f32{0} ** N;

    // Broadband, so every bin carries something and a twiddle that has
    // drifted shows up wherever the drift is worst, not just at a peak.
    var rng = std.Random.DefaultPrng.init(11);
    for (&real, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i));
        s.* = @sin(0.11 * t) + 0.5 * @sin(0.93 * t + 1.0) + 0.2 * (rng.random().float(f32) * 2.0 - 1.0);
    }
    const input = real;
    fft(N, &real, &imag);

    var peak: f64 = 0;
    var worst: f64 = 0;
    for (0..N / 2) |bin| {
        const want = referenceDft(&input, bin);
        const want_mag = std.math.hypot(want.re, want.im);
        peak = @max(peak, want_mag);
        worst = @max(worst, std.math.hypot(@as(f64, real[bin]) - want.re, @as(f64, imag[bin]) - want.im));
    }
    // Relative to the loudest bin. Measures 4.5e-8 with the f64 twiddle
    // recurrence and 2.5e-6 with an f32 one, so this bound is a tripwire on
    // the recurrence, not just a sanity check on the butterflies.
    try std.testing.expect(worst / peak < 2.0e-7);
}

test "fft with runtime N" {
    const N: usize = 128;
    var real: [N]f32 = undefined;
    var imag: [N]f32 = undefined;
    @memset(&real, 0.0);
    @memset(&imag, 0.0);
    real[0] = 1.0;
    fft(N, &real, &imag);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), real[0], 1e-6);
}

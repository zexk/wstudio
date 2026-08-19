//! Stereo utility: gain, polarity, mono, channel selection, and swap.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const LoudnessMeter = @import("meter.zig").LoudnessMeter;

pub const Utility = struct {
    pub const max_delay_frames: usize = 4096;

    gain_db: f32 = 0,
    invert: f32 = 0,
    mono: f32 = 0,
    /// Sum to mono only below this frequency, leaving the body stereo.
    /// 0 disables it. Bass is kept centred under ~120 Hz because stereo
    /// content down there cancels when a club system sums to mono and
    /// buys nothing either way - the ear cannot place it. `mono` above
    /// collapses the whole band; this collapses only the range where
    /// width is a liability, so a wide detuned bass keeps its body.
    mono_below_hz: f32 = 0,
    /// 0 = stereo, 1 = left, 2 = right.
    channel: f32 = 0,
    swap: f32 = 0,
    delay_frames: f32 = 0,
    noise_on: f32 = 0,
    /// 0 white, 1 pink, 2 brown, 3 blue, 4 violet.
    noise_color: f32 = 0,
    noise_db: f32 = -18,
    autogain_on: f32 = 0,
    autogain_target_lufs: f32 = -18,
    delay_line_l: []types.Sample,
    delay_line_r: []types.Sample,
    write_pos: usize = 0,
    noise_state: u32 = 0x6d2b79f5,
    noise_low: f32 = 0,
    noise_prev: f32 = 0,
    noise_diff_prev: f32 = 0,
    /// Two cascaded one-pole highpasses on the side signal, for
    /// `mono_below_hz`. Each stage keeps its own input and output history.
    side_hp1_x: f32 = 0,
    side_hp1_y: f32 = 0,
    side_hp2_x: f32 = 0,
    side_hp2_y: f32 = 0,
    loudness: LoudnessMeter,
    autogain_db: f32 = 0,
    sample_rate: u32,

    pub const device = dsp.deviceOf(@This());

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Utility {
        const left = try allocator.alloc(types.Sample, max_delay_frames + 1);
        errdefer allocator.free(left);
        const right = try allocator.alloc(types.Sample, max_delay_frames + 1);
        @memset(left, 0);
        @memset(right, 0);
        return .{
            .delay_line_l = left,
            .delay_line_r = right,
            .loudness = LoudnessMeter.init(sample_rate),
            .sample_rate = sample_rate,
        };
    }

    pub fn deinit(self: *Utility, allocator: std.mem.Allocator) void {
        allocator.free(self.delay_line_l);
        allocator.free(self.delay_line_r);
        self.delay_line_l = &.{};
        self.delay_line_r = &.{};
    }

    pub fn reset(self: *Utility) void {
        @memset(self.delay_line_l, 0);
        @memset(self.delay_line_r, 0);
        self.write_pos = 0;
        self.noise_state = 0x6d2b79f5;
        self.noise_low = 0;
        self.noise_prev = 0;
        self.noise_diff_prev = 0;
        self.side_hp1_x = 0;
        self.side_hp1_y = 0;
        self.side_hp2_x = 0;
        self.side_hp2_y = 0;
        self.loudness = LoudnessMeter.init(self.sample_rate);
        self.autogain_db = 0;
    }

    fn noiseSample(self: *Utility, color: u3) f32 {
        var x = self.noise_state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.noise_state = x;
        const white = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(std.math.maxInt(u32))) * 2.0 - 1.0;
        const diff = (white - self.noise_prev) * 0.5;
        const second_diff = (diff - self.noise_diff_prev) * 0.5;
        self.noise_low = self.noise_low * 0.98 + white * 0.02;
        self.noise_prev = white;
        self.noise_diff_prev = diff;
        return switch (color) {
            1 => std.math.clamp(self.noise_low * 3.0 + white * 0.35, -1.0, 1.0),
            2 => std.math.clamp(self.noise_low * 4.0, -1.0, 1.0),
            3 => diff,
            4 => second_diff,
            else => white,
        };
    }

    pub fn processBlock(self: *Utility, buf: []types.Sample) void {
        const autogain_on = dsp.sanitizeParam(self.autogain_on, 0, 1, 0) >= 0.5;
        const autogain_from = self.autogain_db;
        if (autogain_on) {
            self.loudness.push(buf);
            const measured = self.loudness.shortTerm();
            if (measured > LoudnessMeter.floor_lufs) {
                const wanted = std.math.clamp(dsp.sanitizeParam(self.autogain_target_lufs, -36, -6, -18) - measured, -24.0, 24.0);
                const seconds = @as(f32, @floatFromInt(buf.len / 2)) / @as(f32, @floatFromInt(@max(self.sample_rate, 1)));
                const rate: f32 = if (wanted < self.autogain_db) 24.0 else 3.0;
                const step = rate * seconds;
                self.autogain_db += std.math.clamp(wanted - self.autogain_db, -step, step);
            }
        } else {
            self.autogain_db = 0;
        }
        // The autogain move is one figure for the whole block, but applying
        // it as one gain for the whole block is a step, not a ride: falling
        // at 24 dB/s that is a 2 dB jump at every block edge on a 4096-frame
        // host. Ramp across the block instead, in the linear domain so the
        // per-frame cost is an add rather than a `pow`. With autogain off
        // both ends are the same number and this is the old constant gain.
        const trim_db = dsp.sanitizeParam(self.gain_db, -24, 24, 0);
        const gain_from = types.dbToGain(trim_db + autogain_from);
        const gain_to = types.dbToGain(trim_db + self.autogain_db);
        const gain_step = (gain_to - gain_from) / @as(f32, @floatFromInt(@max(buf.len / 2, 1)));
        var gain = gain_from;
        const polarity: f32 = if (dsp.sanitizeParam(self.invert, 0, 1, 0) >= 0.5) -1 else 1;
        const mono = dsp.sanitizeParam(self.mono, 0, 1, 0) >= 0.5;
        const channel: u2 = @intFromFloat(@round(dsp.sanitizeParam(self.channel, 0, 2, 0)));
        const swap = dsp.sanitizeParam(self.swap, 0, 1, 0) >= 0.5;
        const delay: usize = @intFromFloat(@round(dsp.sanitizeParam(self.delay_frames, 0, max_delay_frames, 0)));
        const noise_on = dsp.sanitizeParam(self.noise_on, 0, 1, 0) >= 0.5;
        const noise_color: u3 = @intFromFloat(@round(dsp.sanitizeParam(self.noise_color, 0, 4, 0)));
        const noise_gain = types.dbToGain(dsp.sanitizeParam(self.noise_db, -60, 0, -18));
        // Sanitised to 0 or a usable crossover: below ~20 Hz there is nothing
        // to centre, and above ~500 Hz this stops being a bass tool.
        const bass_mono_hz = dsp.sanitizeParam(self.mono_below_hz, 0, 500, 0);
        const bass_mono = bass_mono_hz >= 20.0;
        const bass_a: f32 = if (bass_mono)
            @exp(-2.0 * std.math.pi * bass_mono_hz / @as(f32, @floatFromInt(@max(self.sample_rate, 1))))
        else
            0;

        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            var left = dsp.sanitizeParam(buf[i], -16, 16, 0);
            var right = dsp.sanitizeParam(buf[i + 1], -16, 16, 0);
            if (noise_on) {
                const noise = self.noiseSample(noise_color) * noise_gain;
                left += noise;
                right += noise;
            }
            switch (channel) {
                1 => right = left,
                2 => left = right,
                else => if (mono) {
                    left = (left + right) * 0.5;
                    right = left;
                },
            }
            if (bass_mono) {
                // Work in mid/side and highpass only the side: the mid passes
                // through untouched, so nothing phase-shifts the part a mono
                // system will hear. (Lowpassing each channel and subtracting
                // is the obvious version and it is wrong - the complementary
                // highpass of a one-pole is not phase-aligned with it, so a
                // large lagged copy of the sub survives on its original side.)
                // Two poles, because one leaves 39% of the side at 50 Hz
                // against a 120 Hz corner where two leave 15%.
                const mid = (left + right) * 0.5;
                const side = (left - right) * 0.5;
                // y = a*(y[-1] + x - x[-1]) - a real one-pole highpass, twice.
                const s1 = bass_a * (self.side_hp1_y + side - self.side_hp1_x);
                self.side_hp1_x = side;
                self.side_hp1_y = s1;
                const s2 = bass_a * (self.side_hp2_y + s1 - self.side_hp2_x);
                self.side_hp2_x = s1;
                self.side_hp2_y = s2;
                left = mid + s2;
                right = mid - s2;
            }
            if (swap) std.mem.swap(f32, &left, &right);
            self.delay_line_l[self.write_pos] = left * gain * polarity;
            self.delay_line_r[self.write_pos] = right * gain * polarity;
            const read_pos = (self.write_pos + self.delay_line_l.len - delay) % self.delay_line_l.len;
            buf[i] = self.delay_line_l[read_pos];
            buf[i + 1] = self.delay_line_r[read_pos];
            self.write_pos = (self.write_pos + 1) % self.delay_line_l.len;
            gain += gain_step;
        }
    }
};

test "utility channel operations and gain compose" {
    var utility = try Utility.init(std.testing.allocator, 48_000);
    defer utility.deinit(std.testing.allocator);
    utility.gain_db = 6.0206;
    utility.invert = 1;
    utility.swap = 1;
    var buf = [_]types.Sample{ 0.25, -0.5 };
    utility.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 1), buf[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), buf[1], 1e-4);

    utility.deinit(std.testing.allocator);
    utility = try Utility.init(std.testing.allocator, 48_000);
    utility.mono = 1;
    buf = .{ 0.25, -0.5 };
    utility.processBlock(&buf);
    try std.testing.expectApproxEqAbs(buf[0], buf[1], 1e-6);

    utility.deinit(std.testing.allocator);
    utility = try Utility.init(std.testing.allocator, 48_000);
    utility.channel = 1;
    buf = .{ 0.25, -0.5 };
    utility.processBlock(&buf);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25 }, &buf);
}

test "utility stays finite under hostile input" {
    var utility = try Utility.init(std.testing.allocator, 48_000);
    defer utility.deinit(std.testing.allocator);
    utility.gain_db = std.math.nan(f32);
    utility.invert = std.math.inf(f32);
    utility.mono = std.math.nan(f32);
    utility.channel = std.math.inf(f32);
    utility.swap = std.math.nan(f32);
    var buf = [_]types.Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1 };
    utility.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "utility delays by exact sample frames" {
    var utility = try Utility.init(std.testing.allocator, 48_000);
    defer utility.deinit(std.testing.allocator);
    utility.delay_frames = 2;
    var buf = [_]types.Sample{ 1, -1, 2, -2, 3, -3, 4, -4 };
    utility.processBlock(&buf);
    try std.testing.expectEqualSlices(types.Sample, &.{ 0, 0, 0, 0, 1, -1, 2, -2 }, &buf);
}

test "utility generates deterministic colored noise" {
    var utility = try Utility.init(std.testing.allocator, 48_000);
    defer utility.deinit(std.testing.allocator);
    utility.noise_on = 1;
    utility.noise_color = 2;
    var first = [_]types.Sample{0} ** 16;
    utility.processBlock(&first);
    try std.testing.expect(first[0] != 0);
    for (first) |sample| try std.testing.expect(std.math.isFinite(sample));

    utility.reset();
    var second = [_]types.Sample{0} ** 16;
    utility.processBlock(&second);
    try std.testing.expectEqualSlices(types.Sample, &first, &second);
}

test "utility autogain moves sustained audio toward target" {
    const sr = 48_000;
    var utility = try Utility.init(std.testing.allocator, sr);
    defer utility.deinit(std.testing.allocator);
    utility.autogain_on = 1;
    utility.autogain_target_lufs = -18;
    var buf: [960]types.Sample = undefined;
    var phase: f32 = 0;
    for (0..500) |_| {
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            const sample = 0.01 * @sin(phase);
            buf[i] = sample;
            buf[i + 1] = sample;
            phase += 2.0 * std.math.pi * 1000.0 / @as(f32, sr);
        }
        utility.processBlock(&buf);
    }
    try std.testing.expect(utility.autogain_db > 10);
    try std.testing.expect(utility.autogain_db <= 24);
}

test "mono below drops sub side energy without narrowing the body" {
    const sr = 48_000;
    // Hard-panned pair: 50 Hz on the left only, 2 kHz on the right only.
    const fill = struct {
        fn go(buf: []types.Sample) void {
            var low_phase: f32 = 0;
            var high_phase: f32 = 0;
            var i: usize = 0;
            while (i + 1 < buf.len) : (i += 2) {
                buf[i] = @sin(low_phase);
                buf[i + 1] = @sin(high_phase);
                low_phase += 2.0 * std.math.pi * 50.0 / @as(f32, sr);
                high_phase += 2.0 * std.math.pi * 2000.0 / @as(f32, sr);
            }
        }
    }.go;
    // Side energy below the crossover, and each channel's total energy.
    const measure = struct {
        fn go(buf: []const types.Sample, low_side: *f64, el: *f64, er: *f64) void {
            const a: f64 = @exp(-2.0 * std.math.pi * 120.0 / @as(f64, sr));
            var lp1: f64 = 0;
            var lp2: f64 = 0;
            var i: usize = 0;
            while (i + 1 < buf.len) : (i += 2) {
                const side = (@as(f64, buf[i]) - buf[i + 1]) * 0.5;
                lp1 = (1.0 - a) * side + a * lp1;
                lp2 = (1.0 - a) * lp1 + a * lp2;
                if (i < buf.len / 2) continue; // let the filters settle
                low_side.* += lp2 * lp2;
                el.* += @as(f64, buf[i]) * buf[i];
                er.* += @as(f64, buf[i + 1]) * buf[i + 1];
            }
        }
    }.go;

    var dry: [19200]types.Sample = undefined;
    fill(&dry);
    var dry_side: f64 = 0;
    var dry_l: f64 = 0;
    var dry_r: f64 = 0;
    measure(&dry, &dry_side, &dry_l, &dry_r);

    var utility = try Utility.init(std.testing.allocator, sr);
    defer utility.deinit(std.testing.allocator);
    utility.mono_below_hz = 120;
    var wet: [19200]types.Sample = undefined;
    fill(&wet);
    utility.processBlock(&wet);
    var wet_side: f64 = 0;
    var wet_l: f64 = 0;
    var wet_r: f64 = 0;
    measure(&wet, &wet_side, &wet_l, &wet_r);

    // The sub stops being a side signal: better than 10 dB down.
    try std.testing.expect(wet_side < dry_side * 0.1);
    // The 2 kHz body is still panned right, not collapsed to the centre.
    try std.testing.expect(wet_r > wet_l * 2.0);
    // And an untouched unit is bit-transparent to the same input.
    var off = try Utility.init(std.testing.allocator, sr);
    defer off.deinit(std.testing.allocator);
    var bypass: [19200]types.Sample = undefined;
    fill(&bypass);
    off.processBlock(&bypass);
    var off_side: f64 = 0;
    var off_l: f64 = 0;
    var off_r: f64 = 0;
    measure(&bypass, &off_side, &off_l, &off_r);
    try std.testing.expectApproxEqAbs(dry_side, off_side, dry_side * 0.01);
}

test "autogain rides across a block instead of stepping at its edge" {
    // One gain for the whole block means the whole move lands as a jump at
    // the block edge - up to 2 dB on a 4096-frame host, since the fall rate
    // is 24 dB/s. A square wave makes the check exact: every frame has the
    // same magnitude, so out/in reads back the gain that frame was given.
    const sr = 48_000;
    var utility = try Utility.init(std.testing.allocator, sr);
    defer utility.deinit(std.testing.allocator);
    utility.autogain_on = 1;
    utility.autogain_target_lufs = -18;

    const frames = 4096;
    var buf: [frames * 2]types.Sample = undefined;
    const fill = struct {
        fn go(b: []types.Sample) void {
            for (b, 0..) |*s, i| s.* = if ((i / 2) % 48 < 24) @as(types.Sample, 0.01) else -0.01;
        }
    }.go;
    // Quiet input, so autogain is still climbing when the block under test
    // runs rather than parked at its target.
    for (0..20) |_| {
        fill(&buf);
        utility.processBlock(&buf);
    }

    fill(&buf);
    const input = buf;
    utility.processBlock(&buf);
    const first = buf[0] / input[0];
    const last = buf[buf.len - 2] / input[buf.len - 2];
    try std.testing.expect(last > first * 1.001);
}

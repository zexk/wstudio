//! Three-band Linkwitz-Riley crossover with per-band gain and solo.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const crossover = @import("crossover.zig");

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
            const left = self.splitters[0].split(buf[frame * 2]);
            const right = self.splitters[1].split(buf[frame * 2 + 1]);
            var out_l: f32 = 0;
            var out_r: f32 = 0;
            inline for (0..3) |band| {
                if (!any_solo or solos[band]) {
                    out_l += left[band] * gains[band];
                    out_r += right[band] * gains[band];
                }
            }
            buf[frame * 2] = out_l;
            buf[frame * 2 + 1] = out_r;
        }
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

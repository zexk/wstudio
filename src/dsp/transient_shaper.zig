//! Envelope-difference transient shaping with output trim.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

pub const TransientShaper = struct {
    sample_rate: f32,
    attack: f32 = 0,
    sustain: f32 = 0,
    output_db: f32 = 0,
    fast_env: f32 = 0,
    slow_env: f32 = 0,
    applied_gain_db: f32 = 0,

    pub fn init(sample_rate: u32) TransientShaper {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *TransientShaper, buf: []types.Sample) void {
        const attack = dsp.sanitizeParam(self.attack, -1, 1, 0);
        const sustain = dsp.sanitizeParam(self.sustain, -1, 1, 0);
        const output = dsp.sanitizeParam(self.output_db, -24, 12, 0);
        self.fast_env = dsp.sanitizeParam(self.fast_env, 0, 16, 0);
        self.slow_env = dsp.sanitizeParam(self.slow_env, 0, 16, 0);
        const fast_coef = dsp.smoothingCoefMs(2, self.sample_rate);
        const slow_coef = dsp.smoothingCoefMs(40, self.sample_rate);

        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const left = dsp.sanitizeParam(buf[i], -16, 16, 0);
            const right = dsp.sanitizeParam(buf[i + 1], -16, 16, 0);
            const level = @max(@abs(left), @abs(right));
            self.fast_env = fast_coef * self.fast_env + (1 - fast_coef) * level;
            self.slow_env = slow_coef * self.slow_env + (1 - slow_coef) * level;
            const transient = std.math.clamp((self.fast_env - self.slow_env) / (self.slow_env + 0.01), 0, 1);
            self.applied_gain_db = output + 12 * (attack * transient + sustain * (1 - transient));
            const gain = types.dbToGain(self.applied_gain_db);
            buf[i] = left * gain;
            buf[i + 1] = right * gain;
        }
    }

    pub fn reset(self: *TransientShaper) void {
        self.fast_env = 0;
        self.slow_env = 0;
        self.applied_gain_db = 0;
    }
};

test "attack boosts onset while sustain boosts steady signal" {
    var attack = TransientShaper.init(48_000);
    attack.attack = 1;
    var onset = [_]types.Sample{ 1, 1 } ** 64;
    attack.processBlock(&onset);
    try std.testing.expect(onset[0] > 1);

    var sustain = TransientShaper.init(48_000);
    sustain.sustain = 1;
    var steady = [_]types.Sample{ 1, 1 } ** 4096;
    sustain.processBlock(&steady);
    try std.testing.expect(steady[steady.len - 1] > 2);
}

test "transient shaper stays finite under hostile input" {
    var effect = TransientShaper.init(0);
    effect.attack = std.math.nan(f32);
    effect.sustain = std.math.inf(f32);
    effect.output_db = -std.math.inf(f32);
    effect.fast_env = std.math.nan(f32);
    effect.slow_env = std.math.inf(f32);
    var buf = [_]types.Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1 };
    effect.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
    try std.testing.expect(std.math.isFinite(effect.applied_gain_db));
}

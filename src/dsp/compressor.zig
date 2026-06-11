//! Feed-forward stereo-linked compressor: peak envelope follower,
//! dB-domain gain computer, makeup gain.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Compressor = struct {
    sample_rate: f32,
    threshold_db: f32 = -18.0,
    ratio: f32 = 4.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
    makeup_db: f32 = 0.0,
    /// Envelope follower state (linear peak).
    env: f32 = 0.0,

    pub fn init(sample_rate: u32) Compressor {
        return .{ .sample_rate = @floatFromInt(sample_rate) };
    }

    pub fn device(self: *Compressor) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .reset = resetOpaque,
    };

    fn smoothingCoef(self: *const Compressor, ms: f32) f32 {
        return @exp(-1.0 / (ms * 0.001 * self.sample_rate));
    }

    pub fn processBlock(self: *Compressor, buf: []Sample) void {
        const frames = buf.len / 2;
        const attack = self.smoothingCoef(self.attack_ms);
        const release = self.smoothingCoef(self.release_ms);
        const makeup = types.dbToGain(self.makeup_db);

        for (0..frames) |i| {
            const level = @max(@abs(buf[i * 2]), @abs(buf[i * 2 + 1]));
            const coef = if (level > self.env) attack else release;
            self.env = coef * self.env + (1.0 - coef) * level;

            const env_db = types.gainToDb(self.env);
            const over_db = env_db - self.threshold_db;
            const reduction_db = if (over_db > 0.0)
                over_db * (1.0 / self.ratio - 1.0)
            else
                0.0;
            const gain = types.dbToGain(reduction_db) * makeup;

            buf[i * 2] *= gain;
            buf[i * 2 + 1] *= gain;
        }
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *Compressor = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *Compressor = @ptrCast(@alignCast(ptr));
        self.env = 0.0;
    }
};

test "attenuates loud signals, passes quiet ones" {
    var comp = Compressor.init(48_000);
    comp.threshold_db = -12.0;
    comp.ratio = 4.0;
    comp.attack_ms = 0.1;

    // loud: 0 dBFS square — should be pulled toward -9 dB
    // (-12 + 12/4), i.e. well below full scale once the envelope settles
    var loud = [_]Sample{1.0} ** 9600;
    comp.processBlock(&loud);
    try std.testing.expect(@abs(loud[loud.len - 2]) < 0.5);

    // quiet: -40 dB — should pass through nearly untouched
    comp.env = 0.0;
    var quiet = [_]Sample{0.01} ** 9600;
    comp.processBlock(&quiet);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.01), quiet[quiet.len - 2], 1e-4);
}

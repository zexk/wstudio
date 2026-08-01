//! Tempo-syncable pan/tremolo from one sine LFO.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Lfo = @import("lfo.zig").Lfo;
const Transport = @import("../transport.zig").Transport;

pub const AutoPan = struct {
    sample_rate: f32,
    rate_hz: f32 = 1,
    sync: f32 = 1,
    beats: f32 = 1,
    depth: f32 = 1,
    /// 0 = tremolo, 1 = auto-pan through a half-cycle right-channel offset.
    phase: f32 = 1,
    lfo: Lfo = .{},
    transport: ?*const Transport = null,

    pub fn init(sample_rate: u32) AutoPan {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
    }

    pub const device = dsp.deviceOf(@This());

    pub fn attachTransport(self: *AutoPan, transport: *const Transport) void {
        self.transport = transport;
    }

    pub fn processBlock(self: *AutoPan, buf: []types.Sample) void {
        const rate_hz = dsp.sanitizeParam(self.rate_hz, 0.05, 20, 1);
        const beats = dsp.sanitizeParam(self.beats, 0.25, 16, 1);
        const depth = dsp.sanitizeParam(self.depth, 0, 1, 1);
        const pan = dsp.sanitizeParam(self.phase, 0, 1, 1) >= 0.5;
        const synced = dsp.sanitizeParam(self.sync, 0, 1, 1) >= 0.5;
        const rate = if (synced and self.transport != null)
            @as(f32, @floatCast(1.0 / (self.transport.?.framesPerBeat() * beats)))
        else
            rate_hz / self.sample_rate;
        self.lfo.sanitize();

        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const left_lfo = (self.lfo.sine(0) + 1) * 0.5;
            const right_lfo = (self.lfo.sine(if (pan) 0.5 else 0) + 1) * 0.5;
            const left = dsp.sanitizeParam(buf[i], -16, 16, 0);
            const right = dsp.sanitizeParam(buf[i + 1], -16, 16, 0);
            buf[i] = left * (1 - depth * left_lfo);
            buf[i + 1] = right * (1 - depth * right_lfo);
            self.lfo.tick(rate);
        }
    }

    pub fn reset(self: *AutoPan) void {
        self.lfo.reset();
    }
};

test "phase selects tremolo or alternating pan" {
    var effect = AutoPan.init(4);
    effect.sync = 0;
    effect.rate_hz = 1;
    effect.depth = 1;
    var tremolo = [_]types.Sample{ 1, 1 } ** 4;
    effect.phase = 0;
    effect.processBlock(&tremolo);
    for (0..4) |i| try std.testing.expectApproxEqAbs(tremolo[i * 2], tremolo[i * 2 + 1], 1e-6);

    effect.reset();
    effect.lfo.phase = 0.25;
    var pan = [_]types.Sample{ 1, 1 } ** 4;
    effect.phase = 1;
    effect.processBlock(&pan);
    try std.testing.expect(pan[0] < pan[1]);
    try std.testing.expect(pan[4] > pan[5]);
}

test "sync follows transport tempo" {
    var transport: Transport = .{ .sample_rate = 8, .tempo_bpm = 60 };
    var effect = AutoPan.init(8);
    effect.attachTransport(&transport);
    effect.beats = 1;
    var buf = [_]types.Sample{ 1, 1 } ** 8;
    effect.processBlock(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0), effect.lfo.phase, 1e-6);
}

test "auto-pan stays finite under hostile input" {
    var effect = AutoPan.init(0);
    effect.rate_hz = std.math.nan(f32);
    effect.sync = std.math.inf(f32);
    effect.beats = -std.math.inf(f32);
    effect.depth = std.math.nan(f32);
    effect.phase = std.math.inf(f32);
    effect.lfo.phase = std.math.nan(f32);
    var buf = [_]types.Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1 };
    effect.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

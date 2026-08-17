//! Measures every factory drum kit pad, so the kits can be judged as a set
//! the way `presetscan` judges the synth presets.
//!
//! A kit's internal balance is a design choice - a kick should sit above a
//! hat - so what matters here is whether the same role lands in the same
//! place from one kit to the next. Loading a new kit should change the
//! character of a beat, not its gain staging.
//!
//! Usage: `zig build kitcheck`

const std = @import("std");
const ws = @import("wstudio");

const DrumMachine = ws.dsp.DrumMachine;
const drum_kit = ws.dsp.drum_kit;
const Transport = ws.Transport;

const sample_rate: u32 = 48_000;
/// Long enough for a crash to ring out, short enough to stay quick.
const frames: usize = 48_000;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;

    const buf = try allocator.alloc(f32, 1024);
    defer allocator.free(buf);

    try w.print("kit\tpad\tname\tpeak\trms\n", .{});
    for (drum_kit.variants) |variant| {
        for (variant.pads, 0..) |slot, pad| {
            if (slot.kind == null) continue;
            var transport: Transport = .{ .sample_rate = sample_rate };
            var dm = try DrumMachine.init(allocator, sample_rate, &transport);
            defer dm.deinit();
            try dm.loadKitVariant(&variant);
            const dev = dm.device();
            dev.sendEvent(.{ .note_on = .{ .note = @intCast(pad), .velocity = 1.0 } });

            var peak: f32 = 0;
            var energy: f64 = 0;
            var done: usize = 0;
            while (done < frames) : (done += buf.len / 2) {
                @memset(buf, 0);
                dev.process(buf);
                for (buf) |s| {
                    peak = @max(peak, @abs(s));
                    energy += @as(f64, s) * s;
                }
            }
            const rms = @sqrt(energy / @as(f64, @floatFromInt(frames * 2)));
            try w.print("{s}\t{d}\t{s}\t{d:.4}\t{d:.5}\n", .{
                variant.name, pad, slot.name, peak, rms,
            });
        }
    }
    try w.flush();
}

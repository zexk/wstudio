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
    // Whole render kept once so decay/tail can be measured without re-driving
    // the engine a second time.
    const rendered = try allocator.alloc(f32, frames);
    defer allocator.free(rendered);

    // decay_ms is first crossing into -20 dB below the pad's own peak, walking
    // forward from that peak - not from note-on, so a pad with a slow attack
    // doesn't read as an instant decay. tail_db is the last 50 ms of the
    // render relative to peak: this is what caught the pads that used to cut
    // off mid-decay (see genSlot's fadeOut). A high tail_db is only a real
    // finding for a pad meant to ring out; deliberate stops (guiro, screech,
    // dive) are exempt by name, same as the source's own fade-out test.
    const tail_frames: usize = sample_rate / 20; // 50 ms
    try w.print("kit\tpad\tname\tpeak\trms\tdecay_ms\ttail_db\n", .{});
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
            var peak_frame: usize = 0;
            var done: usize = 0;
            while (done < frames) : (done += buf.len / 2) {
                @memset(buf, 0);
                dev.process(buf);
                var i: usize = 0;
                while (i < buf.len) : (i += 2) {
                    const frame = done + i / 2;
                    const s = @max(@abs(buf[i]), @abs(buf[i + 1]));
                    if (frame < frames) {
                        rendered[frame] = s;
                        if (s > peak) {
                            peak = s;
                            peak_frame = frame;
                        }
                    }
                    energy += @as(f64, buf[i]) * buf[i] + @as(f64, buf[i + 1]) * buf[i + 1];
                }
            }
            var decay_frame: ?usize = null;
            if (peak > 1e-6) {
                const floor = peak * 0.1; // -20 dB
                for (rendered[peak_frame..], peak_frame..) |s, frame| {
                    if (s < floor) {
                        decay_frame = frame;
                        break;
                    }
                }
            }
            var tail_energy: f64 = 0;
            for (rendered[frames - tail_frames ..]) |s| tail_energy += @as(f64, s) * s;

            const rms = @sqrt(energy / @as(f64, @floatFromInt(frames * 2)));
            const decay_ms: f32 = if (decay_frame) |f|
                @as(f32, @floatFromInt(f - peak_frame)) * 1000.0 / @as(f32, @floatFromInt(sample_rate))
            else
                -1; // never reached -20 dB inside the window
            const tail_rms: f64 = @sqrt(tail_energy / @as(f64, @floatFromInt(tail_frames)));
            const tail_db: f32 = if (peak > 1e-6 and tail_rms > 1e-9)
                @floatCast(20.0 * @log10(tail_rms / peak))
            else
                -100;
            try w.print("{s}\t{d}\t{s}\t{d:.4}\t{d:.5}\t{d:.0}\t{d:.1}\n", .{
                variant.name, pad, slot.name, peak, rms, decay_ms, tail_db,
            });
        }
    }
    try w.flush();
}

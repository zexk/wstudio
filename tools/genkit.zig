//! Render the drum kit to WAV files under assets/kit/.
//!
//! Run with `zig build genkit`. Each generator in `dsp.drum_kit` is rendered to
//! a mono 16-bit PCM WAV at 48 kHz, which the engine then ships via @embedFile
//! (see drum_sampler.zig). Re-run after editing the generators and commit the
//! refreshed WAVs.

const std = @import("std");
const ws = @import("wstudio");

const sample_rate: u32 = 48_000;
const out_dir = "src/assets/kit";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;

    for (ws.dsp.drum_kit.kit) |def| {
        const samples = try def.gen(gpa, sample_rate);
        defer gpa.free(samples);

        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ out_dir, def.file });

        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(io, &fbuf);
        try ws.wav.write(&fw.interface, sample_rate, 1, samples);
        try fw.interface.flush();

        try stdout.print("  {s: <6} -> {s}  ({d} frames)\n", .{ def.name, path, samples.len });
    }
    try stdout.print("rendered {d} drums at {d} Hz\n", .{ ws.dsp.drum_kit.kit.len, sample_rate });
    try stdout.flush();
}

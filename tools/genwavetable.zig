//! Render the default wavetable to a WAV file under assets/wavetable/.
//!
//! Run with `zig build genwavetable`. Writes 4 concatenated frames (sine,
//! triangle, saw, square) of `wavetable.frame_len` samples each - the
//! oscillator's own frame_pos crossfade at playback time gives the "basic
//! shapes" morph, so there's no need to bake intermediate morph frames
//! here. Re-run after changing the shape math and commit the refreshed WAV.

const std = @import("std");
const ws = @import("wstudio");

const frame_len = ws.dsp.wavetable.frame_len;
const out_path = "src/assets/wavetable/basic_shapes.wav";

fn writeFrame(frames: []f32, index: usize, shape: fn (f32) f32) void {
    const base = index * frame_len;
    for (0..frame_len) |i| {
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frame_len));
        frames[base + i] = shape(phase);
    }
}

fn sine(phase: f32) f32 {
    return @sin(2.0 * std.math.pi * phase);
}
fn triangle(phase: f32) f32 {
    return 1.0 - 4.0 * @abs(phase - 0.5);
}
fn saw(phase: f32) f32 {
    return 2.0 * phase - 1.0;
}
fn square(phase: f32) f32 {
    return if (phase < 0.5) 1.0 else -1.0;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;

    const frames = try gpa.alloc(f32, frame_len * 4);
    defer gpa.free(frames);
    writeFrame(frames, 0, sine);
    writeFrame(frames, 1, triangle);
    writeFrame(frames, 2, saw);
    writeFrame(frames, 3, square);

    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var fbuf: [8192]u8 = undefined;
    var fw = file.writer(io, &fbuf);
    // sample_rate here is a nominal WAV header field, not a playback rate -
    // the reader only cares about the sample data, reshaped by frame_len.
    try ws.wav.write(&fw.interface, 48_000, 1, frames, .pcm16);
    try fw.interface.flush();

    try stdout.print("wrote {s} (4 frames x {d} samples)\n", .{ out_path, frame_len });
    try stdout.flush();
}

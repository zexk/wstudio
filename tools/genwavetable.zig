//! Render bundled wavetables to WAV files under assets/wavetable/.
//!
//! Run with `zig build genwavetable`. Each file holds four 2048-sample
//! frames. Oscillator frame_pos crossfades between them at playback time.
//! Re-run after changing shape math and commit refreshed WAV files.

const std = @import("std");
const ws = @import("wstudio");

const frame_len = 2048;
const Table = struct {
    path: []const u8,
    render: fn ([]f32) void,
};

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

fn additive(phase: f32, harmonic: usize, amplitude: f32) f32 {
    return amplitude * @sin(2.0 * std.math.pi * phase * @as(f32, @floatFromInt(harmonic)));
}

fn normalize(frame: []f32) void {
    var peak: f32 = 0.0;
    for (frame) |sample| peak = @max(peak, @abs(sample));
    if (peak > 0.0) {
        for (frame) |*sample| sample.* /= peak;
    }
}

fn renderBasic(frames: []f32) void {
    writeFrame(frames, 0, sine);
    writeFrame(frames, 1, triangle);
    writeFrame(frames, 2, saw);
    writeFrame(frames, 3, square);
}

fn renderSpectral(frames: []f32) void {
    for (0..4) |frame_index| {
        const frame = frames[frame_index * frame_len ..][0..frame_len];
        for (frame, 0..) |*sample, i| {
            const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frame_len));
            sample.* = 0.0;
            for (1..33) |h| {
                const tilt: f32 = @as(f32, @floatFromInt(frame_index)) * 0.35 + 1.0;
                const hf: f32 = @floatFromInt(h);
                const parity: f32 = if ((h + frame_index) % 2 == 0) 1.0 else 0.18;
                sample.* += additive(phase, h, parity / std.math.pow(f32, hf, tilt));
            }
        }
        normalize(frame);
    }
}

fn renderFormant(frames: []f32) void {
    const centers = [4][3]f32{ .{ 3, 6, 12 }, .{ 2, 9, 13 }, .{ 2, 11, 15 }, .{ 3, 8, 11 } };
    for (centers, 0..) |formants, frame_index| {
        const frame = frames[frame_index * frame_len ..][0..frame_len];
        for (frame, 0..) |*sample, i| {
            const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frame_len));
            sample.* = 0.0;
            for (1..25) |h| {
                const hf: f32 = @floatFromInt(h);
                var weight: f32 = 0.03 / hf;
                for (formants) |center| {
                    const distance = (hf - center) / 1.5;
                    weight += @exp(-0.5 * distance * distance) / hf;
                }
                sample.* += additive(phase, h, weight);
            }
        }
        normalize(frame);
    }
}

fn renderMetallic(frames: []f32) void {
    for (0..4) |frame_index| {
        const frame = frames[frame_index * frame_len ..][0..frame_len];
        const index = 0.8 + @as(f32, @floatFromInt(frame_index)) * 1.25;
        const ratio: f32 = @floatFromInt(frame_index + 2);
        for (frame, 0..) |*sample, i| {
            const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frame_len));
            sample.* = @sin(2.0 * std.math.pi * phase + index * @sin(2.0 * std.math.pi * ratio * phase));
        }
        normalize(frame);
    }
}

fn renderAnalog(frames: []f32) void {
    for (0..4) |frame_index| {
        const frame = frames[frame_index * frame_len ..][0..frame_len];
        for (frame, 0..) |*sample, i| {
            const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frame_len));
            sample.* = 0.0;
            for (1..33) |h| {
                const hf: f32 = @floatFromInt(h);
                const rolloff = 1.0 / (hf * (1.0 + hf * (0.035 + 0.025 * @as(f32, @floatFromInt(frame_index)))));
                const drift = @sin(@as(f32, @floatFromInt(h * 17 + frame_index * 11))) * 0.015;
                sample.* += additive(phase + drift, h, rolloff);
            }
            sample.* = std.math.tanh(sample.* * (1.0 + 0.3 * @as(f32, @floatFromInt(frame_index))));
        }
        normalize(frame);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;

    const frames = try gpa.alloc(f32, frame_len * 4);
    defer gpa.free(frames);
    const tables = [_]Table{
        .{ .path = "src/assets/wavetable/basic_shapes.wav", .render = renderBasic },
        .{ .path = "src/assets/wavetable/spectral.wav", .render = renderSpectral },
        .{ .path = "src/assets/wavetable/formant.wav", .render = renderFormant },
        .{ .path = "src/assets/wavetable/metallic.wav", .render = renderMetallic },
        .{ .path = "src/assets/wavetable/analog.wav", .render = renderAnalog },
    };
    inline for (tables) |table| {
        table.render(frames);
        const file = try std.Io.Dir.cwd().createFile(io, table.path, .{});
        defer file.close(io);
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(io, &fbuf);
        // Sample rate is nominal: loader reshapes sample data by frame_len.
        try ws.wav.write(&fw.interface, 48_000, 1, frames, .pcm16);
        try fw.interface.flush();
        try stdout.print("wrote {s} (4 frames x {d} samples)\n", .{ table.path, frame_len });
    }
    try stdout.flush();
}

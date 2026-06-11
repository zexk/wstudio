//! Minimal WAV (RIFF) writer — enough to bounce the engine's output to
//! disk and hear it. Reading and other formats come later.

const std = @import("std");
const types = @import("types.zig");

/// Writes a 16-bit PCM WAV. `samples` is interleaved f32 in [-1, 1]
/// (values outside are clamped). Caller flushes the writer.
pub fn write(
    w: *std.Io.Writer,
    sample_rate: u32,
    channel_count: u16,
    samples: []const types.Sample,
) std.Io.Writer.Error!void {
    const bytes_per_sample = 2;
    const data_len: u32 = @intCast(samples.len * bytes_per_sample);
    const byte_rate = sample_rate * channel_count * bytes_per_sample;
    const block_align = channel_count * bytes_per_sample;

    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + data_len, .little);
    try w.writeAll("WAVE");

    try w.writeAll("fmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 1, .little); // PCM
    try w.writeInt(u16, channel_count, .little);
    try w.writeInt(u32, sample_rate, .little);
    try w.writeInt(u32, byte_rate, .little);
    try w.writeInt(u16, @intCast(block_align), .little);
    try w.writeInt(u16, bytes_per_sample * 8, .little);

    try w.writeAll("data");
    try w.writeInt(u32, data_len, .little);
    for (samples) |s| {
        const clamped = std.math.clamp(s, -1.0, 1.0);
        try w.writeInt(i16, @intFromFloat(clamped * 32767.0), .little);
    }
}

test "header and sample encoding" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const samples = [_]types.Sample{ 0.0, 1.0, -1.0, 2.0 };
    try write(&w, 48_000, 2, &samples);

    const out = w.buffered();
    try std.testing.expectEqualStrings("RIFF", out[0..4]);
    try std.testing.expectEqualStrings("WAVE", out[8..12]);
    try std.testing.expectEqual(@as(usize, 44 + 8), out.len);
    // data chunk size
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, out[40..44], .little));
    // sample values: 0, max, min, clamped max
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, out[44..46], .little));
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, out[46..48], .little));
    try std.testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, out[48..50], .little));
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, out[50..52], .little));
}

//! WAV (RIFF) I/O: write 16- or 24-bit PCM for export, parse PCM/float WAVs
//! for sample loading.

const std = @import("std");
const types = @import("types.zig");

/// Output PCM bit depth for `write`.
pub const BitDepth = enum(u16) { pcm16 = 16, pcm24 = 24 };

/// Writes a PCM WAV at the given bit depth. `samples` is interleaved f32 in
/// [-1, 1] (values outside are clamped). Caller flushes the writer.
pub fn write(
    w: *std.Io.Writer,
    sample_rate: u32,
    channel_count: u16,
    samples: []const types.Sample,
    bit_depth: BitDepth,
) std.Io.Writer.Error!void {
    const bits_per_sample: u16 = @intFromEnum(bit_depth);
    const bytes_per_sample: u32 = bits_per_sample / 8;
    const data_len: u32 = @intCast(samples.len * bytes_per_sample);
    const data_pad: u32 = data_len & 1;
    const byte_rate = sample_rate * channel_count * bytes_per_sample;
    const block_align = channel_count * bytes_per_sample;

    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + data_len + data_pad, .little);
    try w.writeAll("WAVE");

    try w.writeAll("fmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 1, .little); // PCM
    try w.writeInt(u16, channel_count, .little);
    try w.writeInt(u32, sample_rate, .little);
    try w.writeInt(u32, byte_rate, .little);
    try w.writeInt(u16, @intCast(block_align), .little);
    try w.writeInt(u16, bits_per_sample, .little);

    try w.writeAll("data");
    try w.writeInt(u32, data_len, .little);
    switch (bit_depth) {
        .pcm16 => for (samples) |s| {
            const clamped = std.math.clamp(s, -1.0, 1.0);
            try w.writeInt(i16, @intFromFloat(clamped * 32767.0), .little);
        },
        .pcm24 => for (samples) |s| {
            const clamped = std.math.clamp(s, -1.0, 1.0);
            const v: i32 = @intFromFloat(clamped * 8_388_607.0);
            try w.writeInt(u8, @truncate(@as(u32, @bitCast(v))), .little);
            try w.writeInt(u8, @truncate(@as(u32, @bitCast(v)) >> 8), .little);
            try w.writeInt(u8, @truncate(@as(u32, @bitCast(v)) >> 16), .little);
        },
    }
    if (data_pad != 0) try w.writeByte(0);
}

// ---------------------------------------------------------------------------
// Reader

pub const ParseError = error{
    NotWav,
    BadFmt,
    UnsupportedFormat,
    UnsupportedBitDepth,
    DataBeforeFmt,
    NoData,
    Truncated,
};

pub const ReadResult = struct {
    /// Mono f32 samples, regardless of the WAV's channel count.
    /// Caller must free with the same allocator.
    samples: []f32,
    sample_rate: u32,
};

/// Parse a WAV file from raw bytes. Handles 16-bit PCM (format 1) and
/// 32-bit IEEE float (format 3), mono or stereo. Stereo is mixed to mono.
pub fn parseAlloc(
    allocator: std.mem.Allocator,
    data: []const u8,
) (ParseError || std.mem.Allocator.Error)!ReadResult {
    if (data.len < 12) return error.Truncated;
    if (!std.mem.eql(u8, data[0..4], "RIFF")) return error.NotWav;
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return error.NotWav;
    const riff_size = std.mem.readInt(u32, data[4..8], .little);
    if (riff_size < 4) return error.Truncated;
    const riff_end = 8 + @as(usize, riff_size);
    if (riff_end > data.len) return error.Truncated;

    var pos: usize = 12;
    var fmt_ok = false;
    var audio_format: u16 = 0;
    var num_channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var out: ?[]f32 = null;
    errdefer if (out) |s| allocator.free(s);

    while (pos + 8 <= riff_end) {
        const id = data[pos..][0..4];
        const chunk_size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        pos += 8;
        if (chunk_size > riff_end - pos) return error.Truncated;
        const chunk = data[pos .. pos + chunk_size];

        if (std.mem.eql(u8, id, "fmt ")) {
            if (fmt_ok) return error.BadFmt;
            if (chunk_size < 16) return error.BadFmt;
            audio_format = std.mem.readInt(u16, chunk[0..2], .little);
            num_channels = std.mem.readInt(u16, chunk[2..4], .little);
            sample_rate = std.mem.readInt(u32, chunk[4..8], .little);
            bits_per_sample = std.mem.readInt(u16, chunk[14..16], .little);
            if (audio_format != 1 and audio_format != 3) return error.UnsupportedFormat;
            const supported_depth = switch (audio_format) {
                1 => bits_per_sample == 16 or bits_per_sample == 24 or bits_per_sample == 32,
                3 => bits_per_sample == 32,
                else => unreachable,
            };
            if (!supported_depth)
                return error.UnsupportedBitDepth;
            if (num_channels == 0 or sample_rate == 0) return error.BadFmt;
            fmt_ok = true;
        } else if (std.mem.eql(u8, id, "data") and out == null) {
            // First data chunk wins; decoding a second would leak the first.
            if (!fmt_ok) return error.DataBeforeFmt;
            const bytes_per_sample = bits_per_sample / 8;
            const bytes_per_frame = bytes_per_sample * num_channels;
            if (chunk_size % bytes_per_frame != 0) return error.Truncated;
            const total_samples = chunk_size / bytes_per_sample;
            const frame_count = total_samples / num_channels;
            const buf = try allocator.alloc(f32, frame_count);
            errdefer allocator.free(buf);
            for (0..frame_count) |i| {
                if (num_channels == 1) {
                    const sample = decodeSample(chunk[i * bytes_per_sample ..], bits_per_sample, audio_format);
                    if (!std.math.isFinite(sample)) return error.BadFmt;
                    buf[i] = sample;
                } else {
                    const stride = num_channels * bytes_per_sample;
                    var sum: f32 = 0;
                    for (0..num_channels) |ch| {
                        const sample = decodeSample(chunk[i * stride + ch * bytes_per_sample ..], bits_per_sample, audio_format);
                        if (!std.math.isFinite(sample)) return error.BadFmt;
                        sum += sample;
                    }
                    if (!std.math.isFinite(sum)) return error.BadFmt;
                    buf[i] = sum / @as(f32, @floatFromInt(num_channels));
                }
            }
            out = buf;
        }

        pos += chunk_size;
        if (chunk_size & 1 != 0) {
            if (pos >= riff_end) return error.Truncated;
            pos += 1; // WAV chunks are word-aligned
        }
    }

    return .{
        .samples = out orelse return error.NoData,
        .sample_rate = sample_rate,
    };
}

fn decodeSample(data: []const u8, bits: u16, format: u16) f32 {
    return switch (bits) {
        16 => @as(f32, @floatFromInt(std.mem.readInt(i16, data[0..2], .little))) / 32768.0,
        24 => blk: {
            const raw: u32 = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16);
            // sign-extend 24-bit
            const signed: i32 = @as(i32, @bitCast(raw << 8)) >> 8;
            break :blk @as(f32, @floatFromInt(signed)) / 8_388_608.0;
        },
        32 => if (format == 3)
            @bitCast(std.mem.readInt(u32, data[0..4], .little))
        else
            @as(f32, @floatFromInt(std.mem.readInt(i32, data[0..4], .little))) / 2_147_483_648.0,
        else => 0.0,
    };
}

test "header and sample encoding" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const samples = [_]types.Sample{ 0.0, 1.0, -1.0, 2.0 };
    try write(&w, 48_000, 2, &samples, .pcm16);

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

test "24-bit header and sample encoding" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const samples = [_]types.Sample{ 0.0, 1.0, -1.0 };
    try write(&w, 48_000, 1, &samples, .pcm24);

    const out = w.buffered();
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, out[34..36], .little));
    // data chunk size: 3 samples * 3 bytes
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, out[40..44], .little));
    try std.testing.expectEqual(@as(usize, 54), out.len);
    try std.testing.expectEqual(@as(u8, 0), out[out.len - 1]);

    const result = try parseAlloc(std.testing.allocator, out);
    defer std.testing.allocator.free(result.samples);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result.samples[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.samples[1], 1.0 / 8_388_608.0 + 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), result.samples[2], 1.0 / 8_388_608.0 + 1e-6);
}

test "round-trip: write then parse" {
    var raw: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    const src = [_]types.Sample{ 0.5, -0.5, 0.25 };
    try write(&w, 44_100, 1, &src, .pcm16);

    const result = try parseAlloc(std.testing.allocator, w.buffered());
    defer std.testing.allocator.free(result.samples);

    try std.testing.expectEqual(@as(u32, 44_100), result.sample_rate);
    try std.testing.expectEqual(@as(usize, 3), result.samples.len);
    // 16-bit round-trip introduces at most 1/32768 error
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result.samples[0], 1.0 / 32768.0 + 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), result.samples[1], 1.0 / 32768.0 + 1e-6);
}

test "rejects invalid IEEE float bit depth" {
    var raw: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    try write(&w, 48_000, 1, &.{0.5}, .pcm16);

    const wav = w.buffered();
    std.mem.writeInt(u16, wav[20..22], 3, .little);
    try std.testing.expectError(error.UnsupportedBitDepth, parseAlloc(std.testing.allocator, wav));
}

test "rejects non-finite IEEE float samples" {
    var raw: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    try w.writeAll("RIFF");
    try w.writeInt(u32, 40, .little);
    try w.writeAll("WAVEfmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 3, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u32, 48_000, .little);
    try w.writeInt(u32, 192_000, .little);
    try w.writeInt(u16, 4, .little);
    try w.writeInt(u16, 32, .little);
    try w.writeAll("data");
    try w.writeInt(u32, 4, .little);
    try w.writeInt(u32, @bitCast(std.math.nan(f32)), .little);

    try std.testing.expectError(error.BadFmt, parseAlloc(std.testing.allocator, w.buffered()));
}

test "rejects a partial interleaved frame" {
    var raw: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    try write(&w, 48_000, 1, &.{ 0.1, 0.2, 0.3 }, .pcm16);

    const wav = w.buffered();
    std.mem.writeInt(u16, wav[22..24], 2, .little);
    try std.testing.expectError(error.Truncated, parseAlloc(std.testing.allocator, wav));
}

test "rejects duplicate format chunks" {
    var raw: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    try write(&w, 48_000, 1, &.{0.25}, .pcm16);

    try w.writeAll("fmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u32, 96_000, .little);
    try w.writeInt(u32, 192_000, .little);
    try w.writeInt(u16, 2, .little);
    try w.writeInt(u16, 16, .little);
    std.mem.writeInt(u32, w.buffered()[4..8], @intCast(w.buffered().len - 8), .little);

    try std.testing.expectError(error.BadFmt, parseAlloc(std.testing.allocator, w.buffered()));
}

test "rejects a RIFF size larger than the available data" {
    var raw: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    try write(&w, 48_000, 1, &.{0.25}, .pcm16);

    const wav = w.buffered();
    std.mem.writeInt(u32, wav[4..8], std.mem.readInt(u32, wav[4..8], .little) + 1, .little);
    try std.testing.expectError(error.Truncated, parseAlloc(std.testing.allocator, wav));
}

test "rejects an odd chunk without its alignment byte" {
    var raw: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    try w.writeAll("RIFF");
    try w.writeInt(u32, 13, .little);
    try w.writeAll("WAVEJUNK");
    try w.writeInt(u32, 1, .little);
    try w.writeByte(0);

    try std.testing.expectError(error.Truncated, parseAlloc(std.testing.allocator, w.buffered()));
}

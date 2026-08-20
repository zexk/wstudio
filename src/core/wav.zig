//! WAV (RIFF) writing: 16- or 24-bit PCM for export. Ours because bounce
//! streams to disk and needs the exact final header up front.
//!
//! Reading lives in `core/audio_file.zig` and is libsndfile's, so it covers
//! every format rather than only this one. Its parse functions are re-exported
//! here, keeping the call sites that only ever load WAVs reading the way they
//! always did.

const std = @import("std");
const types = @import("types.zig");
const audio_file = @import("audio_file.zig");

pub const ParseError = audio_file.ParseError;
pub const ReadResult = audio_file.ReadResult;
pub const parseAlloc = audio_file.parseAlloc;
pub const parseInterleavedAlloc = audio_file.parseInterleavedAlloc;
pub const encodeFlacAlloc = audio_file.encodeFlacAlloc;
pub const max_decoded_samples = audio_file.max_decoded_samples;

/// Output PCM bit depth for `write`.
pub const BitDepth = enum(u16) { pcm16 = 16, pcm24 = 24 };
pub const WriteError = std.Io.Writer.Error || error{ InvalidFormat, FileTooLarge };

pub const StreamWriter = struct {
    writer: *std.Io.Writer,
    bit_depth: BitDepth,
    samples_left: usize,
    data_pad: bool,

    pub fn init(w: *std.Io.Writer, sample_rate: u32, channel_count: u16, sample_count: usize, bit_depth: BitDepth) WriteError!StreamWriter {
        if (sample_rate == 0 or channel_count == 0 or sample_count % channel_count != 0) return error.InvalidFormat;
        const bits_per_sample: u16 = @intFromEnum(bit_depth);
        const bytes_per_sample: u32 = bits_per_sample / 8;
        const data_len_usize = std.math.mul(usize, sample_count, bytes_per_sample) catch return error.FileTooLarge;
        const riff_size_u64 = @as(u64, 36) + data_len_usize + (data_len_usize & 1);
        if (riff_size_u64 > std.math.maxInt(u32)) return error.FileTooLarge;
        const data_len: u32 = @intCast(data_len_usize);
        const block_align_u32 = @as(u32, channel_count) * bytes_per_sample;
        if (block_align_u32 > std.math.maxInt(u16)) return error.InvalidFormat;
        const byte_rate_u64 = @as(u64, sample_rate) * block_align_u32;
        if (byte_rate_u64 > std.math.maxInt(u32)) return error.InvalidFormat;

        try w.writeAll("RIFF");
        try w.writeInt(u32, @intCast(riff_size_u64), .little);
        try w.writeAll("WAVEfmt ");
        try w.writeInt(u32, 16, .little);
        try w.writeInt(u16, 1, .little);
        try w.writeInt(u16, channel_count, .little);
        try w.writeInt(u32, sample_rate, .little);
        try w.writeInt(u32, @intCast(byte_rate_u64), .little);
        try w.writeInt(u16, @intCast(block_align_u32), .little);
        try w.writeInt(u16, bits_per_sample, .little);
        try w.writeAll("data");
        try w.writeInt(u32, data_len, .little);
        return .{ .writer = w, .bit_depth = bit_depth, .samples_left = sample_count, .data_pad = data_len & 1 != 0 };
    }

    pub fn writeSamples(self: *StreamWriter, samples: []const types.Sample) WriteError!void {
        if (samples.len > self.samples_left) return error.InvalidFormat;
        switch (self.bit_depth) {
            .pcm16 => for (samples) |s| {
                const clamped = if (std.math.isFinite(s)) std.math.clamp(s, -1.0, 1.0) else 0.0;
                try self.writer.writeInt(i16, @intFromFloat(clamped * 32767.0), .little);
            },
            .pcm24 => for (samples) |s| {
                const clamped = if (std.math.isFinite(s)) std.math.clamp(s, -1.0, 1.0) else 0.0;
                const v: u32 = @bitCast(@as(i32, @intFromFloat(clamped * 8_388_607.0)));
                try self.writer.writeByte(@truncate(v));
                try self.writer.writeByte(@truncate(v >> 8));
                try self.writer.writeByte(@truncate(v >> 16));
            },
        }
        self.samples_left -= samples.len;
    }

    pub fn finish(self: *StreamWriter) WriteError!void {
        if (self.samples_left != 0) return error.InvalidFormat;
        if (self.data_pad) try self.writer.writeByte(0);
    }
};

/// Writes a PCM WAV at the given bit depth. `samples` is interleaved f32 in
/// [-1, 1] (values outside are clamped). Caller flushes the writer.
pub fn write(
    w: *std.Io.Writer,
    sample_rate: u32,
    channel_count: u16,
    samples: []const types.Sample,
    bit_depth: BitDepth,
) WriteError!void {
    var stream = try StreamWriter.init(w, sample_rate, channel_count, samples.len, bit_depth);
    try stream.writeSamples(samples);
    try stream.finish();
}

/// WAVE_FORMAT_EXTENSIBLE. Plain PCM or float audio wearing a longer `fmt `
/// chunk: the real format tag moves into the first two bytes of a SubFormat
/// GUID, and the tag field itself becomes this sentinel. Commercial sample
/// packs ship these routinely, so rejecting them rejects ordinary PCM.
const format_extensible: u16 = 0xFFFE;

/// The 14 bytes every KSDATAFORMAT_SUBTYPE GUID ends with - the whole of
/// `XXXX0000-0000-0010-8000-00AA00389B71` past the format tag. Checked so an
/// unrelated GUID can't have its first two bytes read as a format tag.
const ksdataformat_suffix = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
};

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

test "streamed blocks match one-shot WAV output" {
    const samples = [_]types.Sample{ 0.0, 0.5, -0.5, 1.0, -1.0, 0.25 };
    inline for ([_]BitDepth{ .pcm16, .pcm24 }) |depth| {
        var expected_buf: [128]u8 = undefined;
        var expected = std.Io.Writer.fixed(&expected_buf);
        try write(&expected, 48_000, 2, &samples, depth);

        var actual_buf: [128]u8 = undefined;
        var actual = std.Io.Writer.fixed(&actual_buf);
        var stream = try StreamWriter.init(&actual, 48_000, 2, samples.len, depth);
        try stream.writeSamples(samples[0..2]);
        try stream.writeSamples(samples[2..]);
        try stream.finish();

        try std.testing.expectEqualSlices(u8, expected.buffered(), actual.buffered());
    }
}

test "writer replaces non-finite samples with silence" {
    inline for ([_]BitDepth{ .pcm16, .pcm24 }) |depth| {
        var raw: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&raw);
        try write(&w, 48_000, 1, &.{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }, depth);
        const result = try parseAlloc(std.testing.allocator, w.buffered());
        defer std.testing.allocator.free(result.samples);
        try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.0, 0.0 }, result.samples);
    }
}

test "writer rejects invalid and overflowing format metadata" {
    var raw: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    try std.testing.expectError(error.InvalidFormat, write(&w, 0, 1, &.{}, .pcm16));
    try std.testing.expectError(error.InvalidFormat, write(&w, 48_000, 0, &.{}, .pcm16));
    try std.testing.expectError(error.InvalidFormat, write(&w, std.math.maxInt(u32), 2, &.{}, .pcm24));
    try std.testing.expectError(error.InvalidFormat, write(&w, 48_000, 2, &.{0.0}, .pcm16));
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
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

fn writeExtensible(w: *std.Io.Writer, sub_tag: u16, guid_suffix: []const u8) !void {
    try w.writeAll("RIFF");
    try w.writeInt(u32, 4 + 8 + 40 + 8 + 2, .little);
    try w.writeAll("WAVEfmt ");
    try w.writeInt(u32, 40, .little);
    try w.writeInt(u16, format_extensible, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u32, 48_000, .little);
    try w.writeInt(u32, 96_000, .little);
    try w.writeInt(u16, 2, .little);
    try w.writeInt(u16, 16, .little);
    try w.writeInt(u16, 22, .little); // cbSize
    try w.writeInt(u16, 16, .little); // valid bits
    try w.writeInt(u32, 4, .little); // channel mask
    try w.writeInt(u16, sub_tag, .little);
    try w.writeAll(guid_suffix);
    try w.writeAll("data");
    try w.writeInt(u32, 2, .little);
    try w.writeInt(i16, 16384, .little);
}

test "accepts WAVE_FORMAT_EXTENSIBLE by reading the SubFormat tag" {
    var raw: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    try writeExtensible(&w, 1, &ksdataformat_suffix);

    const result = try parseAlloc(std.testing.allocator, w.buffered());
    defer std.testing.allocator.free(result.samples);
    try std.testing.expectEqual(@as(u32, 48_000), result.sample_rate);
    try std.testing.expectEqual(@as(usize, 1), result.samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result.samples[0], 0.0001);
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

test "parses a file with a trailing chunk the RIFF size does not cover" {
    // What a strict parser used to reject and packs ship anyway: metadata
    // appended after the data chunk, with the RIFF size left stale.
    var raw: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    try write(&w, 44_100, 1, &.{ 0.5, -0.5 }, .pcm16);
    try w.writeAll("LIST");
    try w.writeInt(u32, 4, .little);
    try w.writeAll("INFO");

    const result = try parseAlloc(std.testing.allocator, w.buffered());
    defer std.testing.allocator.free(result.samples);
    try std.testing.expectEqual(@as(u32, 44_100), result.sample_rate);
    try std.testing.expectEqual(@as(usize, 2), result.samples.len);
}

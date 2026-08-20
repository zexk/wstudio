//! Sample decoding, for every format libsndfile knows: WAV, FLAC, AIFF, CAF,
//! Ogg Vorbis, Opus. One decoder rather than a per-format branch at each call
//! site, and the format is read out of the bytes rather than off the file
//! name.
//!
//! Callers hand over a whole file already in memory (bundled assets arrive as
//! `@embedFile`, so there is not always a path to hand libsndfile), which is
//! what the virtual-IO shim below is for.
//!
//! Writing WAVs is `core/wav.zig`'s job, not this module's: bounce streams to
//! disk and needs the final header up front.

const std = @import("std");

const c = @cImport(@cInclude("sndfile.h"));

pub const ParseError = error{
    /// libsndfile did not recognize the bytes as audio it can decode.
    NotAudioFile,
    /// Recognized, but describes itself impossibly: no channels, no rate, or
    /// a sample that decoded to something that is not a number.
    BadFmt,
    /// Recognized and well-formed, but holds no frames.
    NoData,
    OutputTooLarge,
};

pub const ReadResult = struct {
    /// Mono f32 samples, unless the caller asked for interleaved.
    /// Caller must free with the same allocator.
    samples: []f32,
    sample_rate: u32,
    channel_count: u16 = 1,
};

pub const max_decoded_samples = 256 * 1024 * 1024 / @sizeOf(f32);

fn decodedSampleCount(frames_raw: c.sf_count_t, channels_raw: c_int) ParseError!usize {
    if (channels_raw <= 0 or channels_raw > std.math.maxInt(u16)) return error.BadFmt;
    if (frames_raw <= 0) return error.NoData;
    const frames = std.math.cast(usize, frames_raw) orelse return error.OutputTooLarge;
    const channels: usize = @intCast(channels_raw);
    const count = std.math.mul(usize, frames, channels) catch return error.OutputTooLarge;
    if (count > max_decoded_samples) return error.OutputTooLarge;
    return count;
}

/// Decode `data`, mixing every channel down to mono.
pub fn parseAlloc(
    allocator: std.mem.Allocator,
    data: []const u8,
) (ParseError || std.mem.Allocator.Error)!ReadResult {
    return parseAllocMode(allocator, data, true);
}

/// Decode `data`, keeping its channels interleaved.
pub fn parseInterleavedAlloc(
    allocator: std.mem.Allocator,
    data: []const u8,
) (ParseError || std.mem.Allocator.Error)!ReadResult {
    return parseAllocMode(allocator, data, false);
}

fn parseAllocMode(
    allocator: std.mem.Allocator,
    data: []const u8,
    downmix: bool,
) (ParseError || std.mem.Allocator.Error)!ReadResult {
    var cursor: Cursor = .{ .bytes = data };
    var vio = virtual_io;
    var info: c.SF_INFO = std.mem.zeroes(c.SF_INFO);
    const snd = c.sf_open_virtual(&vio, c.SFM_READ, &info, &cursor) orelse return error.NotAudioFile;
    defer _ = c.sf_close(snd);

    if (info.samplerate <= 0) return error.BadFmt;
    const sample_count = try decodedSampleCount(info.frames, info.channels);
    const channels: usize = @intCast(info.channels);
    const frames: usize = @intCast(info.frames);

    // Interleaved either way: the downmix pass needs every channel, and when
    // it is off this buffer is already the result.
    const interleaved = try allocator.alloc(f32, sample_count);
    errdefer allocator.free(interleaved);
    const read: usize = @intCast(c.sf_readf_float(snd, interleaved.ptr, info.frames));
    if (read == 0) return error.NoData;
    // A truncated file decodes to fewer frames than its header claimed.
    const decoded = interleaved[0 .. read * channels];
    for (decoded) |sample| if (!std.math.isFinite(sample)) return error.BadFmt;

    if (!downmix) {
        return .{
            .samples = if (read == frames) interleaved else try allocator.realloc(interleaved, decoded.len),
            .sample_rate = @intCast(info.samplerate),
            .channel_count = @intCast(channels),
        };
    }

    for (0..read) |frame| {
        var sum: f64 = 0;
        for (0..channels) |channel| sum += decoded[frame * channels + channel];
        interleaved[frame] = @floatCast(sum / @as(f64, @floatFromInt(channels)));
    }
    return .{
        .samples = if (read == interleaved.len) interleaved else try allocator.realloc(interleaved, read),
        .sample_rate = @intCast(info.samplerate),
        .channel_count = 1,
    };
}

/// Compressed formats this module can write. WAV stays `core/wav.zig`'s job:
/// it streams a header of known size straight to disk and needs no encoder
/// state, while these do.
pub const Encoding = enum {
    flac,
    ogg_vorbis,

    /// What a bounce path's extension asks for, or null for anything else -
    /// which means WAV, the default and the only format with a plain
    /// streaming writer.
    pub fn fromPath(path: []const u8) ?Encoding {
        if (std.ascii.endsWithIgnoreCase(path, ".flac")) return .flac;
        if (std.ascii.endsWithIgnoreCase(path, ".ogg")) return .ogg_vorbis;
        return null;
    }
};

/// Streams samples into libsndfile and holds the encoded file until `finish`.
/// What accumulates here is the *encoded* bitstream, not the raw audio, so a
/// long render costs the size of the output file rather than the size of the
/// render - the reason this does not need the seekable on-disk target
/// libsndfile would otherwise want (it seeks backwards to patch headers once
/// it knows the frame count, which `Sink` supports and a plain
/// `std.Io.Writer` does not).
pub const Encoder = struct {
    sink: Sink,
    snd: ?*c.SNDFILE = null,
    channel_count: u16 = 0,

    /// libsndfile cannot write this format - a build-time property of the
    /// library rather than anything about the input, so callers that have a
    /// WAV path available should fall back rather than fail.
    pub const Error = error{UnsupportedEncoding} || std.mem.Allocator.Error;

    /// Initialized in place because libsndfile keeps the `Sink` pointer for
    /// the lifetime of the handle: an encoder returned by value would hand it
    /// a dangling one. `bits_per_sample` is ignored by the lossy encodings.
    pub fn init(
        self: *Encoder,
        allocator: std.mem.Allocator,
        encoding: Encoding,
        sample_rate: u32,
        channel_count: u16,
        bits_per_sample: u16,
    ) Error!void {
        self.* = .{ .sink = .{ .allocator = allocator } };
        var info: c.SF_INFO = std.mem.zeroes(c.SF_INFO);
        info.samplerate = @intCast(sample_rate);
        info.channels = @intCast(channel_count);
        info.format = switch (encoding) {
            .flac => c.SF_FORMAT_FLAC | @as(c_int, switch (bits_per_sample) {
                24 => c.SF_FORMAT_PCM_24,
                else => c.SF_FORMAT_PCM_16,
            }),
            .ogg_vorbis => c.SF_FORMAT_OGG | c.SF_FORMAT_VORBIS,
        };
        if (c.sf_format_check(&info) == 0) return error.UnsupportedEncoding;

        var vio = write_virtual_io;
        self.snd = c.sf_open_virtual(&vio, c.SFM_WRITE, &info, &self.sink) orelse
            return error.UnsupportedEncoding;
        // Same convention `wav.zig` writes with: full scale is ±1.0.
        _ = c.sf_command(self.snd, c.SFC_SET_CLIPPING, null, c.SF_TRUE);
        self.channel_count = channel_count;
    }

    /// Interleaved, and a whole number of frames.
    pub fn writeSamples(self: *Encoder, samples: []const f32) Error!void {
        const snd = self.snd orelse return error.UnsupportedEncoding;
        const frames: c.sf_count_t = @intCast(samples.len / self.channel_count);
        _ = c.sf_writef_float(snd, samples.ptr, frames);
        if (self.sink.failed) return error.OutOfMemory;
    }

    /// Closes the encoder and hands over the finished file. Callers own the
    /// bytes afterwards; the encoder is spent either way.
    pub fn finish(self: *Encoder, allocator: std.mem.Allocator) Error![]u8 {
        const snd = self.snd orelse return error.UnsupportedEncoding;
        self.snd = null;
        const closed = c.sf_close(snd);
        // Left `.empty` on every failure path so a caller's `errdefer
        // deinit` cannot free the same bytes twice.
        if (self.sink.failed or closed != 0) {
            self.sink.bytes.deinit(allocator);
            self.sink.bytes = .empty;
            return if (self.sink.failed) error.OutOfMemory else error.UnsupportedEncoding;
        }
        return try self.sink.bytes.toOwnedSlice(allocator);
    }

    /// Only for abandoning an encoder that never reached `finish`.
    pub fn deinit(self: *Encoder, allocator: std.mem.Allocator) void {
        if (self.snd) |snd| _ = c.sf_close(snd);
        self.snd = null;
        self.sink.bytes.deinit(allocator);
    }
};

/// Encode mono/interleaved `samples` as a 16-bit FLAC file in memory.
/// Lossless against the 16-bit WAV this replaced in the project audio cache,
/// and about half the size. Returns null if this libsndfile cannot write
/// FLAC at all, which is a build-time thing rather than a bad input - the
/// caller falls back to WAV rather than failing a save.
pub fn encodeFlacAlloc(
    allocator: std.mem.Allocator,
    samples: []const f32,
    sample_rate: u32,
    channel_count: u16,
) std.mem.Allocator.Error!?[]u8 {
    var encoder: Encoder = undefined;
    encoder.init(allocator, .flac, sample_rate, channel_count, 16) catch |err| switch (err) {
        error.UnsupportedEncoding => return null,
        else => |e| return e,
    };
    errdefer encoder.deinit(allocator);
    encoder.writeSamples(samples) catch |err| switch (err) {
        error.UnsupportedEncoding => return null,
        else => |e| return e,
    };
    return encoder.finish(allocator) catch |err| switch (err) {
        error.UnsupportedEncoding => null,
        else => |e| e,
    };
}

/// Where the virtual-IO callbacks below are up to in the caller's bytes.
const Cursor = struct {
    bytes: []const u8,
    pos: u64 = 0,
};

/// The growable counterpart to `Cursor`. libsndfile seeks backwards to patch
/// headers once it knows the frame count, so this has to support writes that
/// land inside what is already there, not only appends.
const Sink = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    pos: usize = 0,
    /// An allocation failed inside a C callback, where there is nothing to
    /// return an error to.
    failed: bool = false,
};

const write_virtual_io: c.SF_VIRTUAL_IO = .{
    .get_filelen = sinkFilelen,
    .seek = sinkSeek,
    .read = sinkRead,
    .write = sinkWrite,
    .tell = sinkTell,
};

fn sinkOf(user_data: ?*anyopaque) *Sink {
    return @ptrCast(@alignCast(user_data.?));
}

fn sinkFilelen(user_data: ?*anyopaque) callconv(.c) c.sf_count_t {
    return @intCast(sinkOf(user_data).bytes.items.len);
}

fn seekTarget(base: i64, offset: i64, len: i64) ?i64 {
    const target = std.math.add(i64, base, offset) catch return null;
    return if (target >= 0 and target <= len) target else null;
}

fn sinkSeek(offset: c.sf_count_t, whence: c_int, user_data: ?*anyopaque) callconv(.c) c.sf_count_t {
    const sink = sinkOf(user_data);
    const len: i64 = @intCast(sink.bytes.items.len);
    const base: i64 = switch (whence) {
        c.SEEK_SET => 0,
        c.SEEK_CUR => @intCast(sink.pos),
        c.SEEK_END => len,
        else => return -1,
    };
    const target = seekTarget(base, offset, len) orelse return -1;
    sink.pos = @intCast(target);
    return target;
}

fn sinkRead(ptr: ?*anyopaque, count: c.sf_count_t, user_data: ?*anyopaque) callconv(.c) c.sf_count_t {
    const sink = sinkOf(user_data);
    if (count <= 0 or ptr == null) return 0;
    const n = @min(@as(usize, @intCast(count)), sink.bytes.items.len - sink.pos);
    const dest: [*]u8 = @ptrCast(ptr.?);
    @memcpy(dest[0..n], sink.bytes.items[sink.pos..][0..n]);
    sink.pos += n;
    return @intCast(n);
}

fn sinkWrite(ptr: ?*const anyopaque, count: c.sf_count_t, user_data: ?*anyopaque) callconv(.c) c.sf_count_t {
    const sink = sinkOf(user_data);
    if (count <= 0 or ptr == null) return 0;
    const n: usize = @intCast(count);
    const end = std.math.add(usize, sink.pos, n) catch {
        sink.failed = true;
        return 0;
    };
    if (end > sink.bytes.items.len) {
        sink.bytes.resize(sink.allocator, end) catch {
            sink.failed = true;
            return 0;
        };
    }
    const src: [*]const u8 = @ptrCast(ptr.?);
    @memcpy(sink.bytes.items[sink.pos..][0..n], src[0..n]);
    sink.pos = end;
    return @intCast(n);
}

fn sinkTell(user_data: ?*anyopaque) callconv(.c) c.sf_count_t {
    return @intCast(sinkOf(user_data).pos);
}

const virtual_io: c.SF_VIRTUAL_IO = .{
    .get_filelen = vioFilelen,
    .seek = vioSeek,
    .read = vioRead,
    .write = vioWrite,
    .tell = vioTell,
};

fn cursorOf(user_data: ?*anyopaque) *Cursor {
    return @ptrCast(@alignCast(user_data.?));
}

fn vioFilelen(user_data: ?*anyopaque) callconv(.c) c.sf_count_t {
    return @intCast(cursorOf(user_data).bytes.len);
}

fn vioSeek(offset: c.sf_count_t, whence: c_int, user_data: ?*anyopaque) callconv(.c) c.sf_count_t {
    const cursor = cursorOf(user_data);
    const len: i64 = @intCast(cursor.bytes.len);
    const base: i64 = switch (whence) {
        c.SEEK_SET => 0,
        c.SEEK_CUR => @intCast(cursor.pos),
        c.SEEK_END => len,
        else => return -1,
    };
    const target = seekTarget(base, offset, len) orelse return -1;
    cursor.pos = @intCast(target);
    return target;
}

fn vioRead(ptr: ?*anyopaque, count: c.sf_count_t, user_data: ?*anyopaque) callconv(.c) c.sf_count_t {
    const cursor = cursorOf(user_data);
    if (count <= 0 or ptr == null) return 0;
    const want: usize = @intCast(count);
    const available = cursor.bytes.len - @as(usize, @intCast(cursor.pos));
    const n = @min(want, available);
    const dest: [*]u8 = @ptrCast(ptr.?);
    @memcpy(dest[0..n], cursor.bytes[@intCast(cursor.pos)..][0..n]);
    cursor.pos += n;
    return @intCast(n);
}

/// Read-only: this shim is only ever handed to `SFM_READ`.
fn vioWrite(_: ?*const anyopaque, _: c.sf_count_t, _: ?*anyopaque) callconv(.c) c.sf_count_t {
    return 0;
}

fn vioTell(user_data: ?*anyopaque) callconv(.c) c.sf_count_t {
    return @intCast(cursorOf(user_data).pos);
}

test "virtual IO rejects overflowing seeks and writes" {
    var cursor = Cursor{ .bytes = "x" };
    try std.testing.expectEqual(@as(c.sf_count_t, -1), vioSeek(std.math.maxInt(i64), c.SEEK_END, &cursor));

    var sink = Sink{ .allocator = std.testing.allocator, .pos = std.math.maxInt(usize) };
    const byte: u8 = 0;
    try std.testing.expectEqual(@as(c.sf_count_t, 0), sinkWrite(&byte, 1, &sink));
    try std.testing.expect(sink.failed);
}

test "decoded audio allocation has a fixed PCM ceiling" {
    try std.testing.expectEqual(max_decoded_samples, try decodedSampleCount(max_decoded_samples, 1));
    try std.testing.expectError(error.OutputTooLarge, decodedSampleCount(max_decoded_samples + 1, 1));
    try std.testing.expectError(error.BadFmt, decodedSampleCount(1, std.math.maxInt(u16) + 1));
}

test "decode VCSL FLAC fixture" {
    const result = try parseAlloc(std.testing.allocator, @embedFile("../fixtures/vcsl-release.flac"));
    defer std.testing.allocator.free(result.samples);
    try std.testing.expectEqual(@as(u32, 44_100), result.sample_rate);
    try std.testing.expect(result.samples.len > 100);
    for (result.samples) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "FLAC encode round-trips losslessly and beats 16-bit PCM on size" {
    const testing = std.testing;
    const frames = 8000;
    const samples = try testing.allocator.alloc(f32, frames);
    defer testing.allocator.free(samples);
    for (samples, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.7 * @sin(t * 0.02) + 0.1 * @sin(t * 0.31);
    }

    const encoded = (try encodeFlacAlloc(testing.allocator, samples, 48_000, 1)).?;
    defer testing.allocator.free(encoded);

    const back = try parseAlloc(testing.allocator, encoded);
    defer testing.allocator.free(back.samples);
    try testing.expectEqual(@as(u32, 48_000), back.sample_rate);
    try testing.expectEqual(samples.len, back.samples.len);
    // 16-bit quantisation is the only loss; the FLAC layer itself adds none.
    for (samples, back.samples) |a, b| try testing.expectApproxEqAbs(a, b, 1e-4);

    try testing.expect(encoded.len < frames * 2);
}

test "declines bytes that are not audio at all" {
    try std.testing.expectError(
        error.NotAudioFile,
        parseAlloc(std.testing.allocator, "not an audio file, not even close"),
    );
}

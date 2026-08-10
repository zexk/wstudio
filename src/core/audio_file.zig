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

    if (info.channels <= 0 or info.samplerate <= 0) return error.BadFmt;
    if (info.frames <= 0) return error.NoData;
    const channels: usize = @intCast(info.channels);
    if (info.frames > @divTrunc(std.math.maxInt(usize), channels)) return error.OutputTooLarge;
    const frames: usize = @intCast(info.frames);

    // Interleaved either way: the downmix pass needs every channel, and when
    // it is off this buffer is already the result.
    const interleaved = try allocator.alloc(f32, frames * channels);
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

    const mono = try allocator.alloc(f32, read);
    errdefer allocator.free(mono);
    for (mono, 0..) |*out, frame| {
        var sum: f32 = 0;
        for (0..channels) |channel| sum += decoded[frame * channels + channel];
        out.* = sum / @as(f32, @floatFromInt(channels));
    }
    allocator.free(interleaved);
    return .{ .samples = mono, .sample_rate = @intCast(info.samplerate), .channel_count = 1 };
}

/// Where the virtual-IO callbacks below are up to in the caller's bytes.
const Cursor = struct {
    bytes: []const u8,
    pos: u64 = 0,
};

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
    const target = base + offset;
    if (target < 0 or target > len) return -1;
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

test "decode VCSL FLAC fixture" {
    const result = try parseAlloc(std.testing.allocator, @embedFile("../fixtures/vcsl-release.flac"));
    defer std.testing.allocator.free(result.samples);
    try std.testing.expectEqual(@as(u32, 44_100), result.sample_rate);
    try std.testing.expect(result.samples.len > 100);
    for (result.samples) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "declines bytes that are not audio at all" {
    try std.testing.expectError(
        error.NotAudioFile,
        parseAlloc(std.testing.allocator, "not an audio file, not even close"),
    );
}

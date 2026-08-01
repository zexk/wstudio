const std = @import("std");
const pad_dsp = @import("../dsp/pad.zig");

const c = @cImport({
    @cDefine("DR_FLAC_NO_STDIO", {});
    @cInclude("dr_flac.h");
});

pub const ReadResult = struct {
    samples: []f32,
    sample_rate: u32,
};

pub fn parseAlloc(allocator: std.mem.Allocator, bytes: []const u8) !ReadResult {
    var channels_c: c_uint = 0;
    var sample_rate_c: c_uint = 0;
    var frames_c: c.drflac_uint64 = 0;
    const interleaved = c.drflac_open_memory_and_read_pcm_frames_f32(bytes.ptr, bytes.len, &channels_c, &sample_rate_c, &frames_c, null) orelse return error.NotFlac;
    defer c.drflac_free(interleaved, null);
    if (channels_c == 0 or sample_rate_c == 0) return error.InvalidFormat;
    if (frames_c > std.math.maxInt(usize)) return error.OutputTooLarge;
    const frames: usize = @intCast(frames_c);
    const channels: usize = channels_c;
    const mono = try allocator.alloc(f32, frames);
    errdefer allocator.free(mono);
    for (mono, 0..) |*out, frame| {
        var sum: f32 = 0;
        for (0..channels) |channel| sum += interleaved[frame * channels + channel];
        out.* = sum / @as(f32, @floatFromInt(channels));
    }
    return .{ .samples = mono, .sample_rate = sample_rate_c };
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, sample_rate: u32) ![]f32 {
    const result = try parseAlloc(allocator, bytes);
    errdefer allocator.free(result.samples);
    if (result.sample_rate == sample_rate) return result.samples;
    const samples = try pad_dsp.resampleLinear(allocator, result.samples, result.sample_rate, sample_rate);
    allocator.free(result.samples);
    return samples;
}

test "decode VCSL FLAC fixture" {
    const result = try parseAlloc(std.testing.allocator, @embedFile("../fixtures/vcsl-release.flac"));
    defer std.testing.allocator.free(result.samples);
    try std.testing.expectEqual(@as(u32, 44_100), result.sample_rate);
    try std.testing.expect(result.samples.len > 100);
    for (result.samples) |sample| try std.testing.expect(std.math.isFinite(sample));
}

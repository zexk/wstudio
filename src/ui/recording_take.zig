const std = @import("std");

pub const recovery_dir = ".wstudio-recovery";

/// Incremental mono float WAV. Header lengths update after every append, so
/// process death leaves a readable partial take in `recovery_dir`.
pub const RecordingTake = struct {
    file: std.Io.File,
    path: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize,
    frames: usize = 0,
    io: std.Io,

    pub fn start(io: std.Io, nonce: u64, sample_rate: u32) !RecordingTake {
        try std.Io.Dir.cwd().createDirPath(io, recovery_dir);
        var self: RecordingTake = undefined;
        self.io = io;
        self.path_len = (try std.fmt.bufPrint(&self.path, recovery_dir ++ "/take-{x}.wav", .{nonce})).len;
        self.frames = 0;
        self.file = try std.Io.Dir.cwd().createFile(io, self.path[0..self.path_len], .{ .exclusive = true });
        errdefer self.file.close(io);
        var header: [44]u8 = undefined;
        wavHeader(&header, sample_rate, 0);
        try self.file.writeStreamingAll(io, &header);
        return self;
    }

    pub fn appendAt(self: *RecordingTake, start_frame: u64, samples: []const f32, sample_rate: u32) !void {
        if (start_frame > self.frames) {
            const silence: [256]f32 = @splat(0.0);
            var missing = start_frame - self.frames;
            while (missing > 0) {
                const count: usize = @intCast(@min(missing, silence.len));
                try self.file.writeStreamingAll(self.io, std.mem.sliceAsBytes(silence[0..count]));
                self.frames += count;
                missing -= count;
            }
        }
        try self.file.writeStreamingAll(self.io, std.mem.sliceAsBytes(samples));
        self.frames += samples.len;
        var header: [44]u8 = undefined;
        wavHeader(&header, sample_rate, self.frames);
        try self.file.writePositionalAll(self.io, header[4..8], 4);
        try self.file.writePositionalAll(self.io, header[40..44], 40);
    }

    pub fn finish(self: *RecordingTake) void {
        self.file.close(self.io);
    }

    pub fn pathSlice(self: *const RecordingTake) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn discard(self: *const RecordingTake) void {
        std.Io.Dir.cwd().deleteFile(self.io, self.pathSlice()) catch {};
    }
};

fn wavHeader(out: *[44]u8, sample_rate: u32, frames: usize) void {
    const data_len: u32 = @intCast(@min(frames *| @sizeOf(f32), std.math.maxInt(u32) - 36));
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 3, .little);
    std.mem.writeInt(u16, out[22..24], 1, .little);
    std.mem.writeInt(u32, out[24..28], sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], sample_rate * @sizeOf(f32), .little);
    std.mem.writeInt(u16, out[32..34], @sizeOf(f32), .little);
    std.mem.writeInt(u16, out[34..36], @bitSizeOf(f32), .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
}

test "partial recording is always a readable WAV" {
    var header: [44]u8 = undefined;
    wavHeader(&header, 48_000, 3);
    try std.testing.expectEqual(@as(u32, 48), std.mem.readInt(u32, header[4..8], .little));
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, header[40..44], .little));
}

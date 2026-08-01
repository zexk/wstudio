//! Bundled acoustic sample-bank catalog. Assets stay as standard SFZ/FLAC
//! files so adding another VCSL instrument needs no new playback code.

const std = @import("std");
const sfz = @import("sfz.zig");
const SampleBank = @import("soundfont.zig").SampleBank;

pub const Id = enum {
    grand,
    upright,
    harpsichord,

    pub fn label(self: Id) []const u8 {
        return switch (self) {
            .grand => "Grand Piano",
            .upright => "Upright Piano",
            .harpsichord => "Italian Harpsichord",
        };
    }

    fn sfzFile(self: Id) []const u8 {
        return switch (self) {
            .grand => "Grand Piano, K.sfz",
            .upright => "Upright Piano, Y.sfz",
            .harpsichord => "Harpsichord, Italian.sfz",
        };
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, id: Id, sample_rate: u32) !SampleBank {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try findRoot(allocator, io, &path_buf);
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    const text = try dir.readFileAlloc(io, id.sfzFile(), allocator, .limited(1024 * 1024));
    defer allocator.free(text);
    return sfz.parse(allocator, io, dir, text, id.label(), sample_rate);
}

fn findRoot(allocator: std.mem.Allocator, io: std.Io, buf: []u8) ![]const u8 {
    const dev = "src/assets/library/vcsl";
    if (std.Io.Dir.cwd().access(io, dev, .{})) |_| return dev else |_| {}
    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);
    return std.fmt.bufPrint(buf, "{s}/../share/wstudio/library/vcsl", .{exe_dir});
}

test "bundled VCSL catalog loads every patch" {
    inline for (std.enums.values(Id)) |id| {
        var bank = try load(std.testing.allocator, std.testing.io, id, 48_000);
        defer bank.deinit();
        try std.testing.expectEqual(@as(usize, 1), bank.presets.len);
        try std.testing.expect(bank.presets[0].regions.len > 10);
        try std.testing.expect(bank.sample_data.len > 48_000);
        var peak: f32 = 0;
        for (bank.sample_data) |sample| {
            try std.testing.expect(std.math.isFinite(sample));
            peak = @max(peak, @abs(sample));
        }
        try std.testing.expect(peak > 0.01);
    }
}

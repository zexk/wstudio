//! Bundled acoustic sample-bank catalog. Assets stay as standard SFZ/FLAC
//! files so adding another VCSL instrument needs no new playback code.

const std = @import("std");
const sfz = @import("sfz.zig");
const SampleBank = @import("soundfont.zig").SampleBank;

pub const Id = enum {
    grand,
    upright,
    harpsichord,
    pipe_organ,
    concert_harp,
    glockenspiel,
    marimba,
    vibraphone,
    xylophone,
    kalimba,

    pub fn label(self: Id) []const u8 {
        return specs[@intFromEnum(self)].label;
    }

    fn sfzFile(self: Id) []const u8 {
        return specs[@intFromEnum(self)].sfz;
    }
};

/// Every `Id` tag joined by `|`, for the `:library` usage string and its help
/// row. Built from the enum so adding a bank can't leave either one listing a
/// subset of what `stringToEnum` actually accepts (it did: both named three of
/// the ten, so seven working banks were undiscoverable).
pub const id_names = blk: {
    var s: []const u8 = "";
    for (@typeInfo(Id).@"enum".fields, 0..) |f, i| {
        s = s ++ (if (i == 0) "" else "|") ++ f.name;
    }
    break :blk s;
};

/// Display name and on-disk SFZ filename per `Id`, in tag order.
// zig fmt: off
const specs = [_]struct { label: []const u8, sfz: []const u8 }{
    .{ .label = "Grand Piano",         .sfz = "Grand Piano, K.sfz" },
    .{ .label = "Upright Piano",       .sfz = "Upright Piano, Y.sfz" },
    .{ .label = "Italian Harpsichord", .sfz = "Harpsichord, Italian.sfz" },
    .{ .label = "Pipe Organ",          .sfz = "Pipe Organ - Quiet.sfz" },
    .{ .label = "Concert Harp",        .sfz = "Concert Harp.sfz" },
    .{ .label = "Glockenspiel",        .sfz = "Glockenspiel.sfz" },
    .{ .label = "Marimba",             .sfz = "Marimba.sfz" },
    .{ .label = "Vibraphone",          .sfz = "Vibraphone - Soft Mallets.sfz" },
    .{ .label = "Xylophone",           .sfz = "Xylophone - Medium Mallets.sfz" },
    .{ .label = "Kenyan Kalimba",      .sfz = "Kalimba, Kenya.sfz" },
};
// zig fmt: on

comptime {
    if (specs.len != @typeInfo(Id).@"enum".fields.len) @compileError("specs must cover every Id");
}

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

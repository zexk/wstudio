//! Bundled acoustic sample-bank catalog. Assets stay as standard SFZ/FLAC
//! files so adding another instrument needs no new playback code. Each bank
//! names the pack it came from, because the two upstreams (VCSL and FreePats,
//! both CC0) ship under their own licence file and their own directory.

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
    harmonica,
    nylon_guitar,
    ukulele,
    finger_bass,
    picked_bass,
    honky_tonk,
    tenor_sax,
    clarinet,
    recorder,

    pub fn label(self: Id) []const u8 {
        return specs[@intFromEnum(self)].label;
    }

    pub fn pack(self: Id) Pack {
        return specs[@intFromEnum(self)].pack;
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

/// The upstream a bank came from. Both are CC0, but they ship separately and
/// the preset browser credits them separately.
pub const Pack = enum {
    vcsl,
    freepats,

    /// Directory under the library root, which is also the tag name.
    pub fn dir(self: Pack) []const u8 {
        return @tagName(self);
    }

    pub fn author(self: Pack) []const u8 {
        return self.tags()[0];
    }

    /// Preset-picker tags, author first: the picker shares its display path
    /// with the factory synth tables, and `writeGenreTags` there skips index 0
    /// as the author. Static so the returned slice outlives the row buffer.
    pub fn tags(self: Pack) []const []const u8 {
        const vcsl_tags = [_][]const u8{ "Versilian Studios", "acoustic" };
        const freepats_tags = [_][]const u8{ "FreePats", "acoustic" };
        return switch (self) {
            .vcsl => &vcsl_tags,
            .freepats => &freepats_tags,
        };
    }
};

/// Display name, pack and on-disk SFZ filename per `Id`, in tag order. A label
/// is at most 20 bytes: `sfz.parse` truncates it there.
// zig fmt: off
const specs = [_]struct { label: []const u8, pack: Pack, sfz: []const u8 }{
    .{ .label = "Grand Piano",         .pack = .vcsl,      .sfz = "Grand Piano, K.sfz" },
    .{ .label = "Upright Piano",       .pack = .vcsl,      .sfz = "Upright Piano, Y.sfz" },
    .{ .label = "Italian Harpsichord", .pack = .vcsl,      .sfz = "Harpsichord, Italian.sfz" },
    .{ .label = "Pipe Organ",          .pack = .vcsl,      .sfz = "Pipe Organ - Quiet.sfz" },
    .{ .label = "Concert Harp",        .pack = .vcsl,      .sfz = "Concert Harp.sfz" },
    .{ .label = "Glockenspiel",        .pack = .vcsl,      .sfz = "Glockenspiel.sfz" },
    .{ .label = "Marimba",             .pack = .vcsl,      .sfz = "Marimba.sfz" },
    .{ .label = "Vibraphone",          .pack = .vcsl,      .sfz = "Vibraphone - Soft Mallets.sfz" },
    .{ .label = "Xylophone",           .pack = .vcsl,      .sfz = "Xylophone - Medium Mallets.sfz" },
    .{ .label = "Kenyan Kalimba",      .pack = .vcsl,      .sfz = "Kalimba, Kenya.sfz" },
    .{ .label = "Harmonica",           .pack = .vcsl,      .sfz = "Harmonica.sfz" },
    .{ .label = "Nylon String Guitar", .pack = .freepats,  .sfz = "Nylon String Guitar.sfz" },
    .{ .label = "Tenor Ukulele",       .pack = .freepats,  .sfz = "Tenor Ukulele.sfz" },
    .{ .label = "Finger Bass",         .pack = .freepats,  .sfz = "Finger Bass.sfz" },
    .{ .label = "Picked Bass",         .pack = .freepats,  .sfz = "Picked Bass.sfz" },
    .{ .label = "Honky-Tonk Piano",    .pack = .freepats,  .sfz = "Honky-Tonk Piano.sfz" },
    .{ .label = "Tenor Saxophone",     .pack = .freepats,  .sfz = "Tenor Saxophone.sfz" },
    .{ .label = "Clarinet",            .pack = .freepats,  .sfz = "Clarinet.sfz" },
    .{ .label = "Soprano Recorder",    .pack = .freepats,  .sfz = "Soprano Recorder.sfz" },
};
// zig fmt: on

comptime {
    if (specs.len != @typeInfo(Id).@"enum".fields.len) @compileError("specs must cover every Id");
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, id: Id, sample_rate: u32) !SampleBank {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try findRoot(allocator, io, &path_buf);
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    // The pack directory, not the library root: an SFZ names its samples
    // relative to itself, so it has to be read and resolved from there.
    var dir = try root_dir.openDir(io, id.pack().dir(), .{});
    defer dir.close(io);
    const text = try dir.readFileAlloc(io, id.sfzFile(), allocator, .limited(1024 * 1024));
    defer allocator.free(text);
    return sfz.parse(allocator, io, dir, text, id.label(), sample_rate);
}

fn findRoot(allocator: std.mem.Allocator, io: std.Io, buf: []u8) ![]const u8 {
    const dev = "src/assets/library";
    if (std.Io.Dir.cwd().access(io, dev, .{})) |_| return dev else |_| {}
    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);
    return std.fmt.bufPrint(buf, "{s}/../share/wstudio/library", .{exe_dir});
}

test "bundled catalog loads every patch" {
    inline for (std.enums.values(Id)) |id| {
        var bank = try load(std.testing.allocator, std.testing.io, id, 48_000);
        defer bank.deinit();
        try std.testing.expectEqual(@as(usize, 1), bank.presets.len);
        // Enough to be a real multisample rather than one stretched note. The
        // sparsest bank shipped is the harmonica at 8 regions - a diatonic
        // instrument has fewer notes to sample than a piano has.
        try std.testing.expect(bank.presets[0].regions.len >= 8);
        try std.testing.expect(bank.sample_data.len > 48_000);
        var peak: f32 = 0;
        for (bank.sample_data) |sample| {
            try std.testing.expect(std.math.isFinite(sample));
            peak = @max(peak, @abs(sample));
        }
        try std.testing.expect(peak > 0.01);
    }
}

test "bundled wind banks sustain on a loop" {
    // A blown instrument was recorded for a few seconds and has to loop to
    // hold a longer note; a struck one must not, or its tail repeats. This
    // catches a re-vendored pack that dropped its loop points, which sounds
    // like the note stopping early rather than like a parse failure.
    inline for ([_]struct { Id, bool }{
        .{ .tenor_sax, true },
        .{ .clarinet, true },
        .{ .recorder, true },
        .{ .grand, false },
        .{ .nylon_guitar, false },
    }) |case| {
        var bank = try load(std.testing.allocator, std.testing.io, case[0], 48_000);
        defer bank.deinit();
        var looping: usize = 0;
        for (bank.presets[0].regions) |r| {
            if (!r.loops) continue;
            looping += 1;
            try std.testing.expect(r.loop_start >= r.start);
            try std.testing.expect(r.loop_end > r.loop_start);
            try std.testing.expect(r.loop_end <= r.end);
        }
        if (case[1]) {
            try std.testing.expectEqual(bank.presets[0].regions.len, looping);
        } else {
            try std.testing.expectEqual(@as(usize, 0), looping);
        }
    }
}

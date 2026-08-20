const std = @import("std");
const persist_types = @import("persist/types.zig");

pub fn write(writer: *std.Io.Writer, path: []const u8, err: anyerror) !void {
    switch (err) {
        error.UnsupportedVersion => try writer.print(
            "cannot open project '{s}': incompatible .wsj format; this build reads version {d}. Use the wstudio release that created this file.",
            .{ path, persist_types.file_version },
        ),
        error.CorruptProjectFile => try writer.print(
            "cannot open project '{s}': file is corrupt or incomplete. Restore '{s}~' or another backup.",
            .{ path, path },
        ),
        error.FileNotFound => try writer.print(
            "cannot open project '{s}': file not found. Check the path.",
            .{path},
        ),
        error.AccessDenied => try writer.print(
            "cannot open project '{s}': permission denied. Check file permissions.",
            .{path},
        ),
        else => try writer.print(
            "cannot open project '{s}': {s}. Keep the source file unchanged and check its path and permissions.",
            .{ path, @errorName(err) },
        ),
    }
}

pub fn message(buf: []u8, path: []const u8, err: anyerror) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    write(&writer, path, err) catch {};
    return writer.buffered();
}

test "project load errors name the file and recovery" {
    var actual_buf: [512]u8 = undefined;
    const actual = message(&actual_buf, "old.wsj", error.UnsupportedVersion);

    var expected_buf: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "cannot open project 'old.wsj': incompatible .wsj format; this build reads version {d}. Use the wstudio release that created this file.",
        .{persist_types.file_version},
    );
    try std.testing.expectEqualStrings(expected, actual);

    try std.testing.expectEqualStrings(
        "cannot open project 'song.wsj': file is corrupt or incomplete. Restore 'song.wsj~' or another backup.",
        message(&actual_buf, "song.wsj", error.CorruptProjectFile),
    );
}

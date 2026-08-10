//! Load the shipped demo project and report its version. Wired into
//! `zig build test` because a `file_version` bump that forgets
//! `zig build gendemo` ships a demo the build cannot open at all - loads
//! pin to one exact version. That went unnoticed for months more than once,
//! and nothing in the Zig test suite reaches a file outside the module root.

const std = @import("std");
const ws = @import("wstudio");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse "demo.wsj";

    var session = ws.persist.load(init.gpa, init.io, path) catch |err| {
        var buf: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buf);
        try stderr.interface.print(
            "{s}: {t} - regenerate it with `zig build gendemo` (current file_version is {d})\n",
            .{ path, err, ws.persist.file_version },
        );
        try stderr.interface.flush();
        return err;
    };
    session.deinit();
}

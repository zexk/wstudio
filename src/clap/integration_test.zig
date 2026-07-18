const std = @import("std");
const ws = @import("wstudio");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const plugin_path = args.next() orelse return error.MissingPluginPath;

    const plugin = try ws.dsp.ClapPlugin.load(init.gpa, plugin_path, null, 48_000);
    defer plugin.deinit();
    var samples = [_]f32{ 0.25, -0.5, 1.0, -1.0 };
    plugin.device().process(&samples);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, -1.0, 2.0, -2.0 }, &samples);

    plugin.device().sendEvent(.{ .note_on = .{ .note = 60, .velocity = 0.8 } });
    plugin.device().sendEvent(.{ .note_off = .{ .note = 60 } });
    plugin.device().reset();
}

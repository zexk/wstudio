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
    try std.testing.expectEqual(@as(u32, 1), plugin.parameterCount());
    const param = plugin.parameterInfo(0).?;
    try std.testing.expectEqual(@as(u32, 7), param.id);
    var name_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Gain", plugin.parameterName(0, &name_buffer).?);
    try std.testing.expectEqual(@as(f64, 2), plugin.parameterValue(7).?);
    var text_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2.00x", plugin.formatParameter(7, 2, &text_buffer).?);
    try std.testing.expectEqual(@as(u32, 16), plugin.latencyFrames());
    try std.testing.expectEqual(@as(?u32, 48_000), plugin.tailFrames());

    plugin.device().sendEvent(.{ .note_on = .{ .note = 60, .velocity = 0.8 } });
    plugin.device().sendEvent(.{ .note_off = .{ .note = 60 } });
    plugin.setParameter(7, null, 3);
    samples = .{ 1, 1, 1, 1 };
    plugin.device().process(&samples);
    try std.testing.expectEqualSlices(f32, &.{ 3, 3, 3, 3 }, &samples);
    const state = (try plugin.saveState(init.gpa)).?;
    defer init.gpa.free(state);
    plugin.setParameter(7, null, 1);
    plugin.device().process(&samples);
    try std.testing.expectEqual(@as(f64, 1), plugin.parameterValue(7).?);
    try std.testing.expect(try plugin.loadState(state));
    try std.testing.expectEqual(@as(f64, 3), plugin.parameterValue(7).?);

    const project_path = ".zig-cache/clap-integration.wsj";
    {
        var session = try ws.Session.initDefault(init.gpa);
        defer session.deinit();
        try session.setClapInstrument(0, plugin_path, "studio.wstudio.test.instrument");
        const instrument = session.racks.items[0].instrument.clap;
        instrument.setParameter(7, null, 3);
        var silent = [_]f32{0} ** 4;
        instrument.device().process(&silent);
        try ws.persist.save(init.gpa, &session, init.io, project_path);
    }
    defer std.Io.Dir.cwd().deleteFile(init.io, project_path) catch {};
    var loaded = try ws.persist.load(init.gpa, init.io, project_path);
    defer loaded.deinit();
    const loaded_plugin = loaded.racks.items[0].instrument.clap;
    try std.testing.expectEqualStrings("studio.wstudio.test.instrument", loaded_plugin.id());
    try std.testing.expectEqual(@as(f64, 3), loaded_plugin.parameterValue(7).?);
}

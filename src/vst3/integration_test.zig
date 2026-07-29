const std = @import("std");
const ws = @import("wstudio");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const module_path = args.next() orelse return error.MissingPluginPath;

    var registry = ws.vst3.scan.Registry.init(init.gpa);
    defer registry.deinit();
    try registry.scanModule(module_path, "wstudio-test.vst3");
    try std.testing.expectEqual(@as(usize, 2), registry.plugins.items.len);
    var instruments: usize = 0;
    for (registry.plugins.items) |plugin| instruments += @intFromBool(plugin.instrument);
    try std.testing.expectEqual(@as(usize, 1), instruments);
    try std.testing.expectEqualStrings("wstudio", registry.plugins.items[0].vendor);
}

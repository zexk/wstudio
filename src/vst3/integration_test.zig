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

    var instrument = try ws.vst3.Vst3Plugin.loadModule(init.gpa, module_path, "wstudio-test.vst3", "575354494e535452554d454e54000001", 48_000, true);
    defer instrument.deinit();
    var instrument_audio = [_]ws.types.Sample{0} ** 8;
    instrument.processBlock(&instrument_audio);
    try std.testing.expectEqual(@as(f32, 0.25), instrument_audio[0]);
    try std.testing.expectEqual(@as(u32, 7), instrument.latencySamples());

    var effect = try ws.vst3.Vst3Plugin.loadModule(init.gpa, module_path, "wstudio-test.vst3", "57535445464645435400000000000001", 48_000, false);
    defer effect.deinit();
    var effect_audio = [_]ws.types.Sample{ 0.1, -0.2, 0.3, -0.4 };
    effect.processBlock(&effect_audio);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), effect_audio[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.4), effect_audio[1], 0.0001);
}

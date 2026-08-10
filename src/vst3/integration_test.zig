const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");

fn runScenario(gpa: std.mem.Allocator, io: std.Io, module_path: []const u8, bundle_path: []const u8, has_display: bool) !void {
    var registry = ws.vst3.scan.Registry.init(gpa);
    defer registry.deinit();
    try registry.scanModule(module_path, bundle_path);
    try std.testing.expectEqual(@as(usize, 3), registry.plugins.items.len);
    var instruments: usize = 0;
    for (registry.plugins.items) |plugin| instruments += @intFromBool(plugin.instrument);
    try std.testing.expectEqual(@as(usize, 1), instruments);
    try std.testing.expectEqualStrings("wstudio", registry.plugins.items[0].vendor);

    for (0..3) |_| {
        const repeated = try ws.vst3.Vst3Plugin.loadModule(gpa, module_path, bundle_path, "57535445464645435400000000000001", 48_000, false);
        repeated.deinit();
    }

    var instrument = try ws.vst3.Vst3Plugin.loadModule(gpa, module_path, bundle_path, "575354494e535452554d454e54000001", 48_000, true);
    defer instrument.deinit();
    var transport: ws.Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120, .position_frames = 48_000, .playing = true };
    instrument.attachTransport(&transport);
    instrument.handleEvent(.{ .note_on = .{ .note = 60, .velocity = 1 } });
    var instrument_audio = [_]ws.types.Sample{0} ** 8;
    instrument.processBlock(&instrument_audio);
    try std.testing.expectEqual(@as(f32, 0.25), instrument_audio[0]);
    try std.testing.expectEqual(@as(usize, 1), instrument.automationParams().len);
    instrument.handleEvent(.{ .automation_param = .{ .id = 100, .value = 0.75 } });
    instrument.handleEvent(.{ .note_on = .{ .note = 60, .velocity = 1 } });
    @memset(&instrument_audio, 0);
    instrument.processBlock(&instrument_audio);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1875), instrument_audio[0], 0.0001);
    try std.testing.expectEqual(@as(u32, 7), instrument.latencySamples());
    try std.testing.expectEqual(@as(u32, 7), instrument.device().latencyFrames());

    var effect = try ws.vst3.Vst3Plugin.loadModule(gpa, module_path, bundle_path, "57535445464645435400000000000001", 48_000, false);
    defer effect.deinit();
    // Editor embedding is Linux-only (`vst3/editor.zig`'s `supported`) and the
    // test plugin only advertises X11EmbedWindowID, so an editor is reported
    // there and nowhere else.
    try std.testing.expectEqual(builtin.os.tag == .linux, effect.hasGui());
    if (builtin.os.tag == .linux and has_display) {
        try std.testing.expect(try effect.toggleGui());
        try std.testing.expect(!try effect.toggleGui());
    }
    try std.testing.expectEqual(@as(usize, 1), effect.parameterCount());
    try std.testing.expectEqual(@as(u32, 100), effect.parameterInfo(0).?.id);
    effect.setParameter(100, 0.5);
    try std.testing.expectEqual(@as(f64, 0.5), effect.parameterValue(100).?);
    const component_state = try effect.saveComponentState(gpa);
    defer gpa.free(component_state);
    const controller_state = (try effect.saveControllerState(gpa)).?;
    defer gpa.free(controller_state);
    effect.setParameter(100, 0.25);
    var restart_audio = [_]ws.types.Sample{ 0, 0 };
    effect.processBlock(&restart_audio);
    _ = effect.serviceMainThread();
    try effect.loadState(component_state, controller_state);
    try std.testing.expectEqual(@as(f64, 0.5), effect.parameterValue(100).?);
    var effect_audio = [_]ws.types.Sample{ 0.1, -0.2, 0.3, -0.4 };
    effect.processBlock(&effect_audio);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), effect_audio[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.2), effect_audio[1], 0.0001);
    effect.handleEvent(.{ .cc = .{ .cc = 1, .value = 127 } });
    effect.processBlock(&effect_audio);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), effect_audio[0], 0.0001);

    // A hosted plugin's output is untrusted: non-finite samples never leave
    // the wrapper, or one of them sticks in the next effect's feedback ring
    // forever.
    effect_audio = .{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 0.25 };
    effect.processBlock(&effect_audio);
    for (effect_audio[0..3]) |s| try std.testing.expectEqual(@as(f32, 0), s);
    try std.testing.expect(std.math.isFinite(effect_audio[3]));

    var fx: ws.Fx = .{};
    defer fx.deinit(gpa);
    const automated = try fx.insertVst3(gpa, 0, bundle_path, "57535445464645435400000000000001", 48_000);
    automated.device().sendEvent(.{ .automation_param = .{ .instance_id = automated.instance_id, .id = 0, .value = 0.75 } });
    var automated_audio = [_]f32{ 1, 1 };
    automated.device().process(&automated_audio);
    try std.testing.expectEqual(@as(f64, 0.75), automated.payload.vst3.parameterValue(100).?);

    const project_path = ".zig-cache/vst3-integration.wsj";
    {
        var session = try ws.Session.initDefault(gpa);
        defer session.deinit();
        try session.setVst3Instrument(0, bundle_path, "575354494e535452554d454e54000001", "wstudio VST3 Test Instrument");
        const saved_plugin = session.racks.items[0].instrument.vst3;
        saved_plugin.setParameter(100, 0.75);
        try ws.persist.save(gpa, &session, io, project_path);
    }
    defer std.Io.Dir.cwd().deleteFile(io, project_path) catch {};
    var loaded = try ws.persist.load(gpa, io, project_path);
    defer loaded.deinit();
    const loaded_plugin = loaded.racks.items[0].instrument.vst3;
    try std.testing.expectEqualStrings("575354494e535452554d454e54000001", loaded_plugin.classId());
    try std.testing.expectEqual(@as(f64, 0.75), loaded_plugin.parameterValue(100).?);

    var mono = try ws.vst3.Vst3Plugin.loadModule(gpa, module_path, bundle_path, "5753544d4f4e4f465800000000000001", 48_000, false);
    defer mono.deinit();
    var mono_audio = [_]ws.types.Sample{ 0.2, 0.6 };
    mono.processBlock(&mono_audio);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), mono_audio[0], 0.0001);
    try std.testing.expectApproxEqAbs(mono_audio[0], mono_audio[1], 0.0001);
}

/// Runs the same scenario twice: once with sandboxing forced off (the
/// `Direct`/in-process path - unchanged code, but otherwise unexercised by
/// this binary now that sandboxing defaults on) and once at whatever the
/// module default is (bridged on Linux). Same assertions either way -
/// this is the "bridged round-trip matches the unbridged path" check.
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const module_path = args.next() orelse return error.MissingPluginPath;
    const bundle_path = args.next() orelse return error.MissingBundlePath;

    ws.plugin_host.bridge.sandbox_enabled.store(false, .release);
    const has_display = std.process.Environ.containsUnemptyConstant(init.minimal.environ, "DISPLAY");
    try runScenario(init.gpa, init.io, module_path, bundle_path, has_display);

    ws.plugin_host.bridge.sandbox_enabled.store(true, .release);
    try runScenario(init.gpa, init.io, module_path, bundle_path, has_display);
}

const std = @import("std");
const ws = @import("wstudio");

fn runScenario(gpa: std.mem.Allocator, io: std.Io, plugin_path: []const u8) !void {
    const plugin = try ws.dsp.ClapPlugin.load(gpa, plugin_path, null, 48_000);
    defer plugin.deinit();
    try std.testing.expect(plugin.serviceMainThread());
    try std.testing.expect(plugin.hasGui());
    try std.testing.expect(try plugin.toggleGui());
    try std.testing.expect(!try plugin.toggleGui());
    try std.testing.expect(try plugin.toggleGui());
    try std.testing.expectEqual(@as(f64, 2.25), plugin.parameterValue(7).?);
    var samples = [_]f32{ 0.25, -0.5, 1.0, -1.0 };
    plugin.device().process(&samples);
    try std.testing.expectEqualSlices(f32, &.{ 0.75, -1.5, 3, -3 }, &samples);
    samples = .{ 1, 2, 3, 4 };
    plugin.device().process(&samples);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, &samples);
    _ = plugin.serviceMainThread();
    plugin.device().process(&samples);
    try std.testing.expectEqualSlices(f32, &.{ 3, 6, 9, 12 }, &samples);
    try std.testing.expectEqual(@as(u32, 1), plugin.parameterCount());
    const param = plugin.parameterInfo(0).?;
    try std.testing.expectEqual(@as(u32, 7), param.id);
    var name_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Gain", plugin.parameterName(0, &name_buffer).?);
    try std.testing.expectEqual(@as(f64, 3), plugin.parameterValue(7).?);
    var text_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2.50x", plugin.formatParameter(7, 2.5, &text_buffer).?);
    try std.testing.expectEqual(@as(u32, 16), plugin.latencyFrames());
    try std.testing.expectEqual(@as(?u32, 48_000), plugin.tailFrames());

    const tuning_instrument = try ws.dsp.ClapPlugin.load(gpa, plugin_path, "studio.wstudio.test.instrument", 48_000);
    defer tuning_instrument.deinit();
    tuning_instrument.device().sendEvent(.{ .note_on = .{ .note = 60, .velocity = 1 } });
    tuning_instrument.device().sendEvent(.{ .midi2_per_note_pitch_bend = .{ .note = 60, .value = 0.5 } });
    var tuning_audio = [_]f32{0} ** 2;
    tuning_instrument.device().process(&tuning_audio);
    try std.testing.expectEqualSlices(f32, &.{ 1, 1 }, &tuning_audio);

    plugin.device().sendEvent(.{ .note_on = .{ .note = 60, .velocity = 0.8 } });
    plugin.device().sendEvent(.{ .note_off = .{ .note = 60 } });
    plugin.setParameter(7, null, 3);
    samples = .{ 1, 1, 1, 1 };
    plugin.device().process(&samples);
    try std.testing.expectEqualSlices(f32, &.{ 3, 3, 3, 3 }, &samples);
    const state = (try plugin.saveState(gpa)).?;
    defer gpa.free(state);
    plugin.setParameter(7, null, 1);
    plugin.device().process(&samples);
    try std.testing.expectEqual(@as(f64, 1), plugin.parameterValue(7).?);
    try std.testing.expect(try plugin.loadState(state));
    try std.testing.expectEqual(@as(f64, 3), plugin.parameterValue(7).?);

    // A hosted plugin's output is untrusted: non-finite samples never leave
    // the wrapper, or one of them sticks in the next effect's feedback ring
    // forever. Gain is 3 here, so the finite sample still passes through.
    samples = .{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 0.5 };
    plugin.device().process(&samples);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 1.5 }, &samples);

    const mono = try ws.dsp.ClapPlugin.load(gpa, plugin_path, "studio.wstudio.test.mono", 48_000);
    defer mono.deinit();
    mono.setParameter(7, null, 2);
    var mono_samples = [_]f32{ 1, 3, 2, 4 };
    mono.device().process(&mono_samples);
    try std.testing.expectEqualSlices(f32, &.{ 4, 4, 6, 6 }, &mono_samples);

    var fx: ws.Fx = .{};
    defer fx.deinit(gpa);
    try std.testing.expectError(
        error.ClapPluginIsNotEffect,
        fx.insertClap(gpa, 0, plugin_path, "studio.wstudio.test.instrument", 48_000),
    );
    {
        // An instrument that also takes audio in belongs in the instrument
        // slot just the same. The slot used to demand zero audio inputs,
        // which locked out Surge XT, Odin2 and every LSP sampler.
        var session = try ws.Session.initDefault(gpa);
        defer session.deinit();
        try session.setClapInstrument(0, plugin_path, "studio.wstudio.test.hybrid");
        const hybrid = session.racks.items[0].instrument.clap;
        try std.testing.expect(hybrid.acceptsNotes());
        try std.testing.expectEqual(@as(u32, 1), hybrid.audio_inputs_count);
    }
    const automated = try fx.insertClap(gpa, 0, plugin_path, "studio.wstudio.test.double", 48_000);
    automated.device().sendEvent(.{ .automation_param = .{ .instance_id = automated.instance_id, .id = 0, .value = 2 } });
    var automated_audio = [_]f32{ 1, 1 };
    automated.device().process(&automated_audio);
    try std.testing.expectEqual(@as(f64, 2), automated.payload.clap.parameterValue(7).?);

    {
        // Loading a plugin instrument onto a track that already has music on
        // it keeps that music: clap counts as a melodic kind, so the swap
        // migrates like any other melodic-to-melodic one. It used to clear
        // both the live pattern and the arrangement lane, which is how a
        // hosted synth ended up silent in every render of the project.
        var session = try ws.Session.initDefault(gpa);
        defer session.deinit();
        try session.setInstrument(0, .poly_synth);
        session.racks.items[0].pattern_player.?.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.5 });
        const lane = session.arrangement.lane(0).?;
        const notes = [_]ws.dsp.pattern.Note{.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.5 }};
        try lane.place(gpa, try ws.arrangement.Clip.initMelodic(gpa, 0, 4 * ws.time_grid.ticks_per_beat, &notes, 4.0));

        try session.setClapInstrument(0, plugin_path, "studio.wstudio.test.instrument");

        const pp = &session.racks.items[0].pattern_player.?;
        try std.testing.expectEqual(@as(usize, 1), pp.note_count);
        try std.testing.expectEqual(@as(u7, 64), pp.notes[0].pitch);
        try std.testing.expectEqual(@as(usize, 1), session.arrangement.lane(0).?.clips.items.len);
    }

    const project_path = ".zig-cache/clap-integration.wsj";
    {
        var session = try ws.Session.initDefault(gpa);
        defer session.deinit();
        try session.setClapInstrument(0, plugin_path, "studio.wstudio.test.instrument");
        const instrument = session.racks.items[0].instrument.clap;
        instrument.setParameter(7, null, 3);
        var silent = [_]f32{0} ** 4;
        instrument.device().process(&silent);
        try ws.persist.save(gpa, &session, io, project_path);
    }
    defer std.Io.Dir.cwd().deleteFile(io, project_path) catch {};
    var loaded = try ws.persist.load(gpa, io, project_path);
    defer loaded.deinit();
    const loaded_plugin = loaded.racks.items[0].instrument.clap;
    try std.testing.expectEqualStrings("studio.wstudio.test.instrument", loaded_plugin.id());
    try std.testing.expectEqual(@as(f64, 3), loaded_plugin.parameterValue(7).?);
}

/// Runs the same scenario twice: once with sandboxing forced off (the
/// `Direct`/in-process path - unchanged code, but otherwise unexercised by
/// this binary now that sandboxing defaults on) and once at whatever the
/// module default is (bridged on Linux). Same assertions either way -
/// this is the "bridged round-trip matches the unbridged path" check.
pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const plugin_path = args.next() orelse return error.MissingPluginPath;

    ws.plugin_host.bridge.sandbox_enabled.store(false, .release);
    try runScenario(init.gpa, init.io, plugin_path);

    ws.plugin_host.bridge.sandbox_enabled.store(true, .release);
    try runScenario(init.gpa, init.io, plugin_path);
}

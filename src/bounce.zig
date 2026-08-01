//! Offline session rendering shared by frontends and command-line export.

const std = @import("std");
const types = @import("core/types.zig");
const engine_mod = @import("audio/engine.zig");
const dsp = @import("dsp/device.zig");
const time_grid = @import("time_grid.zig");
const wav = @import("core/wav.zig");
const Session = @import("session.zig").Session;

pub const Range = struct { start_frame: u64, total_frames: u64, has_loop_region: bool };

/// Prefix one-based track index, then reduce name to filesystem-safe chars.
/// Index keeps cloned or identically named tracks from overwriting each other.
pub fn stemName(buf: []u8, name: []const u8, index: usize) []const u8 {
    const prefix = std.fmt.bufPrint(buf, "{d}-", .{index + 1}) catch return buf[0..0];
    var len: usize = prefix.len;
    for (name) |c| {
        if (len >= buf.len) break;
        buf[len] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ' ' => c,
            else => '_',
        };
        len += 1;
    }
    if (len == prefix.len) {
        const fallback = "track";
        const end = @min(len + fallback.len, buf.len);
        @memcpy(buf[len..end], fallback[0 .. end - len]);
        len = end;
    }
    return buf[0..len];
}

pub fn contentBeats(session: *const Session) f64 {
    var max_beats: f64 = 0;
    for (session.racks.items) |rack| {
        if (rack.pattern_player) |pp| max_beats = @max(max_beats, pp.length_beats);
        switch (rack.instrument) {
            .drum_machine => |*dm| max_beats = @max(max_beats, @as(f64, @floatFromInt(dm.step_count)) / @as(f64, @floatFromInt(dm.steps_per_beat))),
            .slicer => |*sl| max_beats = @max(max_beats, @as(f64, @floatFromInt(sl.step_count)) / @as(f64, @floatFromInt(sl.steps_per_beat))),
            else => {},
        }
    }
    return max_beats;
}

pub fn range(session: *const Session, tail_seconds: f32) Range {
    const transport = session.engine.transport;
    const has_loop_region = transport.loop_enabled and transport.loop_end_frames > transport.loop_start_frames;
    const start_frame: u64 = if (has_loop_region) transport.loop_start_frames else 0;
    const content_frames: u64 = if (has_loop_region) transport.loop_end_frames - transport.loop_start_frames else blk: {
        const max_beats = if (session.song_mode)
            @max(1.0, time_grid.tickToBeat(session.arrangement.lengthTicks()))
        else
            @max(1.0, contentBeats(session));
        break :blk @intFromFloat(transport.framesPerBeat() * max_beats);
    };
    return .{
        .start_frame = start_frame,
        .total_frames = content_frames +| types.secondsToFrames(tail_seconds, session.project.sample_rate),
        .has_loop_region = has_loop_region,
    };
}

/// Render from `start_frame`, then restore transport and device state.
/// Caller must own engine; frontends park realtime audio first.
pub fn render(session: *Session, buffer: []types.Sample, start_frame: u64) void {
    const engine = session.engine;
    const was_playing = engine.transport.playing;
    const saved_pos = engine.transport.position_frames;
    const was_looping = engine.transport.loop_enabled;
    engine.transport.loop_enabled = false;

    resetDevices(session);
    engine.limiter.reset();
    engine.transport.seekFrames(start_frame);
    engine.transport.play();

    const block = types.default_block_frames * engine_mod.channels;
    var offset: usize = 0;
    while (offset < buffer.len) {
        const end = @min(offset + block, buffer.len);
        engine.process(buffer[offset..end]);
        offset = end;
    }

    resetDevices(session);
    engine.limiter.reset();
    engine.transport.seekFrames(saved_pos);
    engine.transport.loop_enabled = was_looping;
    if (was_playing) engine.transport.play() else engine.transport.stop();
}

/// Render directly to PCM WAV using one fixed audio block of memory.
pub fn writeWav(session: *Session, writer: *std.Io.Writer, bounce_range: Range, bit_depth: wav.BitDepth) wav.WriteError!void {
    const engine = session.engine;
    const was_playing = engine.transport.playing;
    const saved_pos = engine.transport.position_frames;
    const was_looping = engine.transport.loop_enabled;
    defer {
        resetDevices(session);
        engine.limiter.reset();
        engine.transport.seekFrames(saved_pos);
        engine.transport.loop_enabled = was_looping;
        if (was_playing) engine.transport.play() else engine.transport.stop();
    }

    engine.transport.loop_enabled = false;
    resetDevices(session);
    engine.limiter.reset();
    engine.transport.seekFrames(bounce_range.start_frame);
    engine.transport.play();

    const frame_count = std.math.cast(usize, bounce_range.total_frames) orelse return error.FileTooLarge;
    const sample_count = std.math.mul(usize, frame_count, engine_mod.channels) catch return error.FileTooLarge;
    var wav_writer = try wav.StreamWriter.init(writer, session.project.sample_rate, engine_mod.channels, sample_count, bit_depth);
    var block: [types.default_block_frames * engine_mod.channels]types.Sample = undefined;
    var frames_left = bounce_range.total_frames;
    while (frames_left > 0) {
        const frames: usize = @intCast(@min(frames_left, types.default_block_frames));
        const samples = block[0 .. frames * engine_mod.channels];
        engine.process(samples);
        try wav_writer.writeSamples(samples);
        frames_left -= frames;
    }
    try wav_writer.finish();
}

/// Stream to sibling temporary file, then replace destination atomically.
pub fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    session: *Session,
    bounce_range: Range,
    bit_depth: wav.BitDepth,
) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        var file_buffer: [8192]u8 = undefined;
        var file_writer = file.writer(io, &file_buffer);
        try writeWav(session, &file_writer.interface, bounce_range, bit_depth);
        try file_writer.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

fn resetDevices(session: *Session) void {
    var buf: [@import("rack.zig").Rack.chain_cap]dsp.Device = undefined;
    for (session.racks.items) |rack| {
        for (rack.chain(&buf)) |dev| dev.reset();
    }
}

test "range uses longest pattern and preserves loop selection" {
    var session = try Session.initDefaultWithSampleRate(std.testing.allocator, 48_000);
    defer session.deinit();
    try session.setInstrument(0, .poly_synth);
    session.racks.items[0].pattern_player.?.length_beats = 8;

    try std.testing.expectEqual(@as(u64, 192_000), range(&session, 0).total_frames);

    session.engine.transport.loop_enabled = true;
    session.engine.transport.loop_start_frames = 12_000;
    session.engine.transport.loop_end_frames = 36_000;
    const selected = range(&session, 0);
    try std.testing.expectEqual(@as(u64, 12_000), selected.start_frame);
    try std.testing.expectEqual(@as(u64, 24_000), selected.total_frames);
}

test "contentBeats includes drum resolution and slicer length" {
    var session = try Session.initDefaultWithSampleRate(std.testing.allocator, 48_000);
    defer session.deinit();

    try session.setInstrument(0, .drum_machine);
    session.racks.items[0].instrument.drum_machine.step_count = 12;
    session.racks.items[0].instrument.drum_machine.steps_per_beat = 3;
    try std.testing.expectEqual(@as(f64, 4.0), contentBeats(&session));

    try session.setInstrument(0, .slicer);
    session.racks.items[0].instrument.slicer.setStepCount(20);
    session.racks.items[0].instrument.slicer.steps_per_beat = 8;
    try std.testing.expectEqual(@as(f64, 2.5), contentBeats(&session));
}

test "range saturates overflowing render length" {
    var session = try Session.initDefaultWithSampleRate(std.testing.allocator, 48_000);
    defer session.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), range(&session, std.math.inf(f32)).total_frames);
}

test "stemName sanitizes paths and handles empty names" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1-bass_lead", stemName(&buf, "bass/lead", 0));
    try std.testing.expectEqualStrings("3-track", stemName(&buf, "", 2));
}

test "failed export preserves destination and removes temporary file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/bounce.wav", .{&tmp.sub_path});
    var tmp_path_buf: [260]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path});
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "existing");
    }

    var session = try Session.initDefaultWithSampleRate(std.testing.allocator, 48_000);
    defer session.deinit();
    const too_large: Range = .{ .start_frame = 0, .total_frames = std.math.maxInt(u32), .has_loop_region = false };
    try std.testing.expectError(error.FileTooLarge, writeFile(std.testing.allocator, std.testing.io, path, &session, too_large, .pcm16));

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("existing", data);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, tmp_path, .{}));
}

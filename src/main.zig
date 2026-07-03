//! CLI frontend. `wstudio` launches the TUI; `wstudio render` runs the
//! offline pipeline demo: keystrokes -> modal input -> note events ->
//! synth -> compressor -> delay -> reverb, bounced to a WAV.

const std = @import("std");
const ws = @import("wstudio");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // argv0
    var init_path: ?[]const u8 = null;
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "render")) return renderDemo(init.gpa, init.io);
        init_path = cmd; // treat as project file
    }
    return @import("tui/app.zig").run(init.gpa, init.io, init_path);
}

const out_path = "out.wav";
/// Played on the a-row piano layout in insert mode (octave 4).
const melody = "asdfds";
const note_seconds = 0.25; // eighth notes at 120 bpm
const tail_seconds = 2.0;

fn renderDemo(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // --- project + engine -----------------------------------------------
    var project = ws.Project.init(allocator);
    defer project.deinit();
    _ = try project.addTrack(.{ .name = "lead", .gain_db = -3.0 });
    const sr = project.sample_rate;

    var engine = try ws.Engine.init(allocator, sr);
    defer engine.deinit();
    engine.loadProject(&project);

    // --- device chain: synth -> compressor -> delay -> reverb ------------
    var synth = ws.dsp.PolySynth.init(sr);
    var comp = ws.dsp.Compressor.init(sr);
    var delay = try ws.dsp.StereoDelay.init(allocator, sr, 2.0);
    defer delay.deinit(allocator);
    delay.setTime(0.375); // dotted eighth at 120 bpm
    var reverb = try ws.dsp.Reverb.init(allocator, sr);
    defer reverb.deinit(allocator);

    engine.setTrackChain(0, &.{
        synth.device(),
        comp.device(),
        delay.device(),
        reverb.device(),
    });

    // --- melody: keystrokes -> modal input -> engine commands ------------
    const Timed = struct { frame: u64, cmd: ws.engine.Command };
    var score: std.ArrayList(Timed) = .empty;
    defer score.deinit(allocator);

    try score.append(allocator, .{ .frame = 0, .cmd = .play });
    var modal: ws.ModalInput = .{};
    _ = modal.handle(.{ .char = 'i' }); // enter insert mode: keys are notes now
    const note_frames = ws.types.secondsToFrames(note_seconds, sr);
    for (melody, 0..) |key, i| {
        const action = modal.handle(.{ .char = key });
        if (action != .note) continue;
        const pitch = action.note.pitch;
        const start = note_frames * i;
        try score.append(allocator, .{ .frame = start, .cmd = .{
            .note_on = .{ .track = 0, .note = pitch, .velocity = 0.9 },
        } });
        try score.append(allocator, .{ .frame = start + note_frames * 4 / 5, .cmd = .{
            .note_off = .{ .track = 0, .note = pitch },
        } });
    }

    // --- offline render ---------------------------------------------------
    const total_frames = note_frames * melody.len + ws.types.secondsToFrames(tail_seconds, sr);
    const buffer = try allocator.alloc(ws.types.Sample, total_frames * ws.engine.channels);
    defer allocator.free(buffer);

    const block_samples = ws.types.default_block_frames * ws.engine.channels;
    var next_event: usize = 0;
    var offset: usize = 0;
    while (offset < buffer.len) {
        const frame_pos = offset / ws.engine.channels;
        while (next_event < score.items.len and score.items[next_event].frame <= frame_pos) {
            _ = engine.send(score.items[next_event].cmd);
            next_event += 1;
        }
        const end = @min(offset + block_samples, buffer.len);
        engine.process(buffer[offset..end]);
        offset = end;
    }

    // --- bounce to disk ----------------------------------------------------
    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var file_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try ws.wav.write(&file_writer.interface, sr, ws.engine.channels, buffer);
    try file_writer.interface.flush();

    try stdout.print(
        "played \"{s}\" through synth -> comp -> delay -> reverb\n" ++
            "rendered {d:.2}s ({d} frames) at {d} Hz -> {s}\n" ++
            "transport: {d:.2} beats @ {d:.0} bpm\n",
        .{
            melody,
            ws.types.framesToSeconds(total_frames, sr),
            total_frames,
            sr,
            out_path,
            engine.transport.positionBeats(),
            engine.transport.tempo_bpm,
        },
    );
    try stdout.flush();
}

test {
    _ = @import("tui/app.zig");
    _ = @import("tui/tui.zig");
    _ = @import("tui/terminal.zig");
    _ = @import("tui/icons.zig");
}

test "frontend links against the engine library" {
    var engine = try ws.Engine.init(std.testing.allocator, ws.types.default_sample_rate);
    defer engine.deinit();
    _ = engine.send(.play);
    var block: [64]ws.types.Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.transport.playing);
}

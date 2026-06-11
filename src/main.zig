//! CLI frontend. Proves the pitch end to end: keystrokes go through
//! the modal input layer, become note events, and play through a
//! synth -> compressor -> delay -> reverb chain, bounced to a WAV.

const std = @import("std");
const ws = @import("wstudio");

const out_path = "out.wav";
/// Played on the z-row piano layout in insert mode (octave 4).
const melody = "zcb,bc";
const note_seconds = 0.25; // eighth notes at 120 bpm
const tail_seconds = 2.0;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // --- project + engine -----------------------------------------------
    var project = ws.Project.init(allocator);
    defer project.deinit();
    _ = try project.addTrack(.{ .name = "lead", .gain_db = -3.0 });
    const sr = project.sample_rate;

    var engine = ws.Engine.init(sr);
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

test "frontend links against the engine library" {
    var engine = ws.Engine.init(ws.types.default_sample_rate);
    _ = engine.send(.play);
    var block: [64]ws.types.Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.transport.playing);
}

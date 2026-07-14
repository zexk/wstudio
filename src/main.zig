//! CLI frontend. `wstudio` launches the TUI; `wstudio render` runs the
//! offline pipeline demo: keystrokes -> modal input -> note events ->
//! synth -> compressor -> delay -> reverb, bounced to a WAV.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const app = @import("tui/app.zig");

/// Restore the terminal (cooked mode, mouse tracking off, alternate screen
/// closed) before handing off to the normal trace printer — otherwise a
/// panic mid-session leaves raw mode + SGR mouse reporting on, so the shell
/// reads garbled and the panic message itself never renders straight.
/// `app.active_terminal` is only set while `App.run`'s raw-mode session is
/// live, so `render`/`--version`/`--help` panics fall straight through.
pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (app.active_terminal) |t| t.deinit();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip(); // argv0

    // Copied out of the iterator's own buffer (freed by defer above, and
    // owned by the OS on POSIX) rather than borrowed, so it stays valid
    // for the life of the run below.
    var path_buf: [256]u8 = undefined;
    var init_path: ?[]const u8 = null;
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "render")) return renderDemo(init.gpa, init.io);
        if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) return printVersion(init.io);
        if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return printHelp(init.io);
        const len = @min(cmd.len, path_buf.len);
        @memcpy(path_buf[0..len], cmd[0..len]);
        init_path = path_buf[0..len];
    }
    return @import("tui/app.zig").run(init.gpa, init.io, init_path);
}

const version = "1.0.0";

fn printVersion(io: std.Io) !void {
    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("wstudio {s}\n", .{version});
    try stdout.flush();
}

fn printHelp(io: std.Io) !void {
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "wstudio {s} — terminal DAW\n\n" ++
            "Usage:\n" ++
            "  wstudio [path]     Launch the TUI, optionally opening a .wsj project\n" ++
            "  wstudio render      Render the built-in demo melody to out.wav\n" ++
            "  wstudio --version   Print the version\n" ++
            "  wstudio --help      Print this message\n",
        .{version},
    );
    try stdout.flush();
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
    var synth = try ws.dsp.PolySynth.init(allocator, sr);
    defer synth.deinit();
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
    try ws.wav.write(&file_writer.interface, sr, ws.engine.channels, buffer, .pcm16);
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
    _ = @import("tui/input_decode.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("tui/terminal_windows.zig");
    } else {
        _ = @import("tui/terminal.zig");
    }
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

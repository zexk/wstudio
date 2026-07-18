//! Executable entry point. `wstudio` launches the frontend picked by
//! init.lua's `wstudio.o.preferred_frontend` (default: TUI), `--tui` and
//! `--gui` force one, and `wstudio render` runs the
//! offline pipeline demo: keystrokes -> modal input -> note events ->
//! synth -> compressor -> delay -> reverb, bounced to a WAV.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const build_options = @import("build_options");
const config_mod = @import("config.zig");

/// Restore the terminal (cooked mode, mouse tracking off, alternate screen
/// closed) before handing off to the normal trace printer - otherwise a
/// panic mid-session leaves raw mode + SGR mouse reporting on, so the shell
/// reads garbled and the panic message itself never renders straight.
/// `app.active_terminal` is only set while `App.run`'s raw-mode session is
/// live, so `render`/`--version`/`--help` panics fall straight through.
pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (build_options.tui) {
        const app = @import("tui/main.zig");
        if (app.active_terminal) |t| t.deinit();
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip(); // argv0

    // `-u {path}` (Neovim's own flag name) can appear anywhere in the
    // command line, so it's pulled out in its own pass rather than the
    // simple positional handling below - the rest of argv is collected
    // as-is and dispatched exactly like before `-u` existed.
    var init_override: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(init.gpa);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-u")) {
            init_override = args.next() orelse return missingInitArg(init.io);
            continue;
        }
        try rest.append(init.gpa, a);
    }

    if (rest.items.len > 0) {
        const cmd = rest.items[0];
        const path: ?[]const u8 = if (rest.items.len > 1) rest.items[1] else null;
        if (std.mem.eql(u8, cmd, "render")) return renderDemo(init.gpa, init.io);
        if (std.mem.eql(u8, cmd, "clap-scan")) return scanClap(init);
        if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) return printVersion(init.io);
        if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return printHelp(init.io);
        if (std.mem.eql(u8, cmd, "--gui")) return runFrontend(init, .gui, init_override, path);
        if (std.mem.eql(u8, cmd, "--tui")) return runFrontend(init, .tui, init_override, path);
        return runPreferred(init, init_override, cmd);
    }
    return runPreferred(init, init_override, null);
}

fn missingInitArg(io: std.Io) !void {
    var stderr_buffer: [64]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    try stderr_writer.interface.print("wstudio: -u requires a path (or NONE)\n", .{});
    try stderr_writer.interface.flush();
    return error.MissingArgument;
}

/// Launch an explicitly requested frontend, erroring if it was disabled at
/// build time.
fn runFrontend(init: std.process.Init, frontend: config_mod.Frontend, init_override: ?[]const u8, path: ?[]const u8) !void {
    switch (frontend) {
        .gui => if (!build_options.gui) return frontendDisabled(init.io, "GUI"),
        .tui => if (!build_options.tui) return frontendDisabled(init.io, "TUI"),
    }
    var runtime = try config_mod.Runtime.init(frontend);
    defer runtime.deinit();
    runtime.init_override = init_override;
    // A broken init.lua reports (see Runtime.luaError) and falls back to
    // defaults - it must never prevent startup.
    _ = runtime.loadUserConfig(init.io) catch false;
    return startFrontend(init, frontend, path, &runtime);
}

/// No frontend flag: init.lua's `wstudio.o.preferred_frontend` picks the
/// frontend, constrained to what this build carries. The runtime starts
/// provisional on the single-flavor default (config still has to load to
/// read the option), then `setFrontend` corrects it before launch.
fn runPreferred(init: std.process.Init, init_override: ?[]const u8, path: ?[]const u8) !void {
    if (!build_options.tui and !build_options.gui) return frontendDisabled(init.io, "TUI");
    if (!build_options.tui) return runFrontend(init, .gui, init_override, path);
    if (!build_options.gui) return runFrontend(init, .tui, init_override, path);
    var runtime = try config_mod.Runtime.init(.tui);
    defer runtime.deinit();
    runtime.init_override = init_override;
    _ = runtime.loadUserConfig(init.io) catch false;
    const frontend = runtime.config.preferred_frontend;
    runtime.setFrontend(frontend);
    return startFrontend(init, frontend, path, &runtime);
}

/// The `build_options` guards are comptime-known, so a disabled frontend's
/// module is never analyzed (callers already ruled the branch out).
fn startFrontend(init: std.process.Init, frontend: config_mod.Frontend, path: ?[]const u8, runtime: *config_mod.Runtime) !void {
    switch (frontend) {
        .gui => if (build_options.gui) {
            return @import("gui/gui.zig").run(init, path, runtime);
        } else unreachable,
        .tui => if (build_options.tui) {
            const init_path: ?[]u8 = if (path) |p| try dupeInitPath(init.gpa, p) else null;
            defer if (init_path) |p| init.gpa.free(p);
            return @import("tui/main.zig").run(init.gpa, init.io, init_path, runtime);
        } else unreachable,
    }
}

fn frontendDisabled(io: std.Io, name: []const u8) !void {
    var stderr_buffer: [128]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    try stderr_writer.interface.print("wstudio: {s} frontend was disabled at build time\n", .{name});
    try stderr_writer.interface.flush();
    return error.FrontendDisabled;
}

fn dupeInitPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return allocator.dupe(u8, path);
}

const version = "1.0.0-beta.1";

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
        "wstudio {s} - digital audio workstation\n\n" ++
            "Usage:\n" ++
            "  wstudio [path]      Launch the preferred frontend (wstudio.o.preferred_frontend,\n" ++
            "                      default tui), optionally opening a .wsj project\n" ++
            "  wstudio --tui [path] Launch the TUI, optionally opening a .wsj project\n" ++
            "  wstudio --gui [path] Launch the GUI, optionally opening a .wsj project\n" ++
            "  wstudio render      Render the built-in demo melody to out.wav\n" ++
            "  wstudio clap-scan   List installed CLAP plugin IDs and paths\n" ++
            "  wstudio --version   Print the version\n" ++
            "  wstudio --help      Print this message\n\n" ++
            "  -u {{path}}           Load this init.lua instead of the usual search\n" ++
            "                      (~/.config/wstudio/init.lua, then /etc/xdg/wstudio/init.lua);\n" ++
            "                      -u NONE skips loading any config file. May appear\n" ++
            "                      anywhere on the command line.\n",
        .{version},
    );
    try stdout.flush();
}

fn scanClap(init: std.process.Init) !void {
    var paths = try ws.dsp.clap_scan.searchPaths(init.gpa, init.environ_map);
    defer ws.dsp.clap_scan.freeSearchPaths(init.gpa, &paths);
    var registry = ws.dsp.clap_scan.Registry.init(init.gpa);
    defer registry.deinit();
    try registry.scanPaths(init.io, paths.items);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    for (registry.plugins.items) |plugin| {
        try stdout.print("{s}\t{s}\t{s}\n", .{ plugin.id, plugin.name, plugin.path });
    }
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
    _ = config_mod;
    _ = @import("ui/app.zig");
    _ = @import("tui/main.zig");
    _ = @import("tui/tui.zig");
    _ = @import("tui/input_decode.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("tui/terminal_windows.zig");
    } else {
        _ = @import("tui/terminal.zig");
    }
    _ = @import("ui/icons.zig");
}

test "frontend links against the engine library" {
    var engine = try ws.Engine.init(std.testing.allocator, ws.types.default_sample_rate);
    defer engine.deinit();
    _ = engine.send(.play);
    var block: [64]ws.types.Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.transport.playing);
}

test "project paths are not truncated" {
    const path = "nested/" ++ ("a" ** 512) ++ "/song.wsj";
    const owned = try dupeInitPath(std.testing.allocator, path);
    defer std.testing.allocator.free(owned);

    try std.testing.expectEqualStrings(path, owned);
}

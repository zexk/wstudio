//! The `:command` layer — every command-prompt action lives here, dispatched
//! through the `cmds` table by `run`. Handlers are free functions taking the
//! owning `*App`; they read/write App fields directly and call back into the
//! shared App helpers (`setStatus`, `doTrackAdd`, …) that the rest of the UI
//! also uses.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const eq_mod = ws.dsp.eq;
const dsp = ws.dsp.device;
const DrumMachine = ws.dsp.DrumMachine;
const Sampler = ws.dsp.Sampler;
const cmd_mod = @import("cmd.zig");
const App = @import("app.zig").App;

fn wrap(comptime f: fn (*App, []const u8) void) *const fn (*anyopaque, []const u8) void {
    return struct {
        fn call(ctx: *anyopaque, args: []const u8) void {
            f(@ptrCast(@alignCast(ctx)), args);
        }
    }.call;
}

pub const cmds: []const cmd_mod.Def = &.{
    .{ .name = "q",           .desc = "quit wstudio",                        .run = wrap(cmdQuit) },
    .{ .name = "q!",          .desc = "quit wstudio (alias for :q)",         .run = wrap(cmdQuit) },
    .{ .name = "quit",        .desc = "quit wstudio",                        .run = wrap(cmdQuit) },
    .{ .name = "qa",          .desc = "quit wstudio (alias for :q)",         .run = wrap(cmdQuit) },
    .{ .name = "qa!",         .desc = "quit wstudio (alias for :q)",         .run = wrap(cmdQuit) },
    .{ .name = "bpm",         .desc = "[<value>]  tempo in BPM (20–400)",    .run = wrap(cmdBpm) },
    .{ .name = "sig",         .desc = "[<n>[/4]]  time signature (1–16 beats per bar)", .run = wrap(cmdSig) },
    .{ .name = "gain",        .desc = "<track> [<dB>]  track gain",          .run = wrap(cmdGain) },
    .{ .name = "pan",         .desc = "<track> [<-1..1>]  track pan",        .run = wrap(cmdPan) },
    .{ .name = "vol",         .desc = "[<dB>]  master volume (–40 to +6)",   .run = wrap(cmdVol) },
    .{ .name = "seek",        .desc = "<bar>  move playhead to bar",         .run = wrap(cmdSeek) },
    .{ .name = "load-pad",    .desc = "<0-7> <file>  load WAV into pad",     .run = wrap(cmdLoadPad) },
    .{ .name = "load-sample", .desc = "<file>  load WAV into sampler track",  .run = wrap(cmdLoadSample) },
    .{ .name = "help",        .desc = "list all commands",                   .run = wrap(cmdHelp) },
    .{ .name = "h",           .desc = "list all commands (alias for :help)", .run = wrap(cmdHelp) },
    .{ .name = "eq",          .desc = "<track> [<band> <db>]  EQ control",   .run = wrap(cmdEq) },
    .{ .name = "track-add",   .desc = "[name]  add a synth track",           .run = wrap(cmdTrackAdd) },
    .{ .name = "track-del",   .desc = "[n]  delete track n (default: cursor)", .run = wrap(cmdTrackDel) },
    .{ .name = "d",           .desc = "[n]  delete track n (alias for :track-del)", .run = wrap(cmdTrackDel) },
    .{ .name = "track-rename",.desc = "<n> <name>  rename track n",          .run = wrap(cmdTrackRename) },
    .{ .name = "save",        .desc = "[file]  save project (default: project.wsj)", .run = wrap(cmdSave) },
    .{ .name = "w",           .desc = "[file]  save project (alias for :save)",      .run = wrap(cmdSave) },
    .{ .name = "wa",          .desc = "[file]  save project (alias for :save)",      .run = wrap(cmdSave) },
    .{ .name = "wq",          .desc = "[file]  save project and quit",               .run = wrap(cmdWriteQuit) },
    .{ .name = "x",           .desc = "[file]  save project and quit (alias for :wq)", .run = wrap(cmdWriteQuit) },
    .{ .name = "wq!",         .desc = "[file]  save project and quit (alias for :wq)", .run = wrap(cmdWriteQuit) },
    .{ .name = "xa",          .desc = "[file]  save project and quit (alias for :wq)", .run = wrap(cmdWriteQuit) },
    .{ .name = "bounce",      .desc = "[file]  render session to WAV (default: bounce.wav)", .run = wrap(cmdBounce) },
    .{ .name = "export",      .desc = "[file]  render session to WAV (alias for :bounce)",   .run = wrap(cmdBounce) },
    .{ .name = "clear",       .desc = "erase all notes in the piano-roll pattern",          .run = wrap(cmdClear) },
    .{ .name = "%d",          .desc = "erase all notes in the pattern (alias for :clear)",  .run = wrap(cmdClear) },
};

/// Look up `text` in the command table and run it, reporting unknown commands
/// in the status line.
pub fn run(app: *App, text: []const u8) void {
    if (!cmd_mod.dispatch(cmds, app, text)) {
        app.setStatus("not a command: {s}  (try :help)", .{text});
    }
}

fn cmdQuit(app: *App, _: []const u8) void { app.should_quit = true; }

fn cmdClear(app: *App, _: []const u8) void {
    // In the piano roll, clear the pattern being edited; elsewhere, the
    // cursor track's pattern.
    const track: usize = if (app.view == .piano_roll) app.piano_track else app.cursor;
    if (track >= app.session.racks.items.len or
        app.session.racks.items[track].pattern_player == null)
    {
        app.setStatus("clear: no piano-roll pattern", .{});
        return;
    }
    const pp = &app.session.racks.items[track].pattern_player.?;
    const n = pp.note_count;
    pp.clearNotes();
    app.setStatus("cleared {d} notes", .{n});
}

pub fn cmdHelp(app: *App, _: []const u8) void {
    app.prev_view = app.view;
    app.help_scroll = 0;
    app.view = .help;
}

fn cmdTrackAdd(app: *App, args: []const u8) void {
    const name = std.mem.trim(u8, args, " ");
    app.doTrackAdd(if (name.len > 0) name else null);
}

fn cmdTrackDel(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const idx: usize = if (trimmed.len == 0) blk: {
        break :blk app.cursor;
    } else blk: {
        const n = std.fmt.parseInt(usize, trimmed, 10) catch {
            app.setStatus("track-del: expected a track number", .{});
            return;
        };
        if (n == 0 or n > app.session.project.tracks.items.len) {
            app.setStatus("track-del: track must be 1–{d}", .{app.session.project.tracks.items.len});
            return;
        }
        break :blk n - 1;
    };
    app.doTrackDel(idx);
}

fn cmdTrackRename(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const n_str = it.next() orelse {
        app.setStatus("usage: track-rename <n> <name>", .{});
        return;
    };
    const name = std.mem.trim(u8, it.rest(), " ");
    if (name.len == 0) {
        app.setStatus("usage: track-rename <n> <name>", .{});
        return;
    }
    const n = std.fmt.parseInt(usize, n_str, 10) catch {
        app.setStatus("track-rename: expected a track number", .{});
        return;
    };
    if (n == 0 or n > app.session.project.tracks.items.len) {
        app.setStatus("track-rename: track must be 1–{d}", .{app.session.project.tracks.items.len});
        return;
    }
    app.session.project.renameTrack(n - 1, name) catch {
        app.setStatus("out of memory", .{});
        return;
    };
    app.setStatus("track {d} renamed to \"{s}\"", .{ n, name });
}

fn cmdLoadPad(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, args, ' ');
    const pad_str = it.next() orelse {
        app.setStatus("usage: load-pad <0-7> <file.wav>", .{});
        return;
    };
    const path = it.rest();
    const pad_idx = std.fmt.parseInt(u8, pad_str, 10) catch {
        app.setStatus("load-pad: bad pad index '{s}'", .{pad_str});
        return;
    };
    if (pad_idx >= DrumMachine.max_pads) {
        app.setStatus("load-pad: pad index must be 0-7", .{});
        return;
    }
    const data = std.Io.Dir.cwd().readFileAlloc(
        app.io,
        path,
        app.allocator,
        .limited(64 * 1024 * 1024),
    ) catch |e| {
        app.setStatus("load-pad: cannot read '{s}': {s}", .{ path, @errorName(e) });
        return;
    };
    defer app.allocator.free(data);
    const dm = cursorDrumMachine(app) orelse {
        app.setStatus("load-pad: select a drum-machine track first", .{});
        return;
    };
    const basename = std.fs.path.basename(path);
    const stem = if (std.mem.lastIndexOf(u8, basename, ".")) |dot| basename[0..dot] else basename;
    dm.loadPadWav(pad_idx, data, stem) catch |e| {
        app.setStatus("load-pad: parse error: {s}", .{@errorName(e)});
        return;
    };
    app.setStatus("pad {d} loaded: {s}", .{ pad_idx, stem });
}

/// The drum machine on the cursor's track, or — if the drum grid is open —
/// the one being edited. Null when neither is a drum machine.
fn cursorDrumMachine(app: *App) ?*DrumMachine {
    if (app.cursor < app.session.racks.items.len) {
        switch (app.session.racks.items[app.cursor].instrument) {
            .drum_machine => |*dm| return dm,
            else => {},
        }
    }
    if (app.view == .drum_grid and app.drum_track < app.session.racks.items.len) {
        switch (app.session.racks.items[app.drum_track].instrument) {
            .drum_machine => |*dm| return dm,
            else => {},
        }
    }
    return null;
}

/// The standalone Sampler on the cursor's track, or null.
fn cursorSampler(app: *App) ?*Sampler {
    if (app.cursor >= app.session.racks.items.len) return null;
    return switch (app.session.racks.items[app.cursor].instrument) {
        .sampler => |*s| s, else => null,
    };
}

fn cmdLoadSample(app: *App, args: []const u8) void {
    const path = std.mem.trim(u8, args, " ");
    if (path.len == 0) {
        app.setStatus("usage: load-sample <file.wav>", .{});
        return;
    }
    const s = cursorSampler(app) orelse {
        app.setStatus("load-sample: select a sampler track first", .{});
        return;
    };
    const data = std.Io.Dir.cwd().readFileAlloc(
        app.io,
        path,
        app.allocator,
        .limited(64 * 1024 * 1024),
    ) catch |e| {
        app.setStatus("load-sample: cannot read '{s}': {s}", .{ path, @errorName(e) });
        return;
    };
    defer app.allocator.free(data);
    const basename = std.fs.path.basename(path);
    const stem = if (std.mem.lastIndexOf(u8, basename, ".")) |dot| basename[0..dot] else basename;
    s.loadWav(data, stem) catch |e| {
        app.setStatus("load-sample: parse error: {s}", .{@errorName(e)});
        return;
    };
    app.setStatus("sample loaded: {s}", .{stem});
}

/// Explicit :save argument, else the file the session was loaded from /
/// last saved to, else "project.wsj".
fn savePath(app: *App, args: []const u8) []const u8 {
    const arg = std.mem.trim(u8, args, " ");
    if (arg.len > 0) return arg;
    return app.projectPath() orelse "project.wsj";
}

fn cmdSave(app: *App, args: []const u8) void {
    const path = savePath(app, args);
    ws.persist.save(app.allocator, &app.session, app.io, path) catch |e| {
        app.setStatus("save: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    app.setProjectPath(path);
    app.setStatus("saved: {s}", .{path});
}

/// Vim-style write-and-quit: save the project, then exit. Only quits when
/// the save succeeds so a failed write leaves the session intact.
fn cmdWriteQuit(app: *App, args: []const u8) void {
    const path = savePath(app, args);
    ws.persist.save(app.allocator, &app.session, app.io, path) catch |e| {
        app.setStatus("save: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    app.setProjectPath(path);
    app.should_quit = true;
}

/// Render the live session (patterns + synth params + drum grid) offline to
/// a 16-bit PCM WAV. Length = the longest loop plus a 2s tail for reverb and
/// release. The realtime backend is parked for the duration so the UI thread
/// can drive the engine without racing the audio thread.
fn cmdBounce(app: *App, args: []const u8) void {
    const path = if (std.mem.trim(u8, args, " ").len > 0)
        std.mem.trim(u8, args, " ")
    else
        "bounce.wav";

    const engine = app.session.engine;
    const sr = app.session.project.sample_rate;

    // Song mode renders the whole arrangement; pattern mode the longest loop.
    const max_beats = if (app.session.song_mode) blk: {
        const bpb: f64 = @floatFromInt(app.session.project.beats_per_bar);
        break :blk @max(1.0, @as(f64, @floatFromInt(app.session.arrangement.lengthBars())) * bpb);
    } else @max(1.0, app.contentBeats());
    const content_frames: u64 = @intFromFloat(engine.transport.framesPerBeat() * max_beats);
    const total_frames = content_frames + types.secondsToFrames(2.0, sr);
    const buffer = app.allocator.alloc(
        types.Sample,
        @as(usize, @intCast(total_frames)) * engine_mod.channels,
    ) catch {
        app.setStatus("bounce: out of memory", .{});
        return;
    };
    defer app.allocator.free(buffer);

    if (!parkAudio(app)) {
        engine.bounce_active.store(false, .release);
        app.setStatus("bounce: audio thread did not park", .{});
        return;
    }
    renderBounce(app, buffer);
    engine.bounce_active.store(false, .release);
    engine.bounce_parked.store(false, .release);

    const file = std.Io.Dir.cwd().createFile(app.io, path, .{}) catch |e| {
        app.setStatus("bounce: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    defer file.close(app.io);
    var fbuf: [8192]u8 = undefined;
    var fw = file.writer(app.io, &fbuf);
    ws.wav.write(&fw.interface, sr, engine_mod.channels, buffer) catch |e| {
        app.setStatus("bounce: write failed: {s}", .{@errorName(e)});
        return;
    };
    fw.interface.flush() catch {};

    app.setStatus("bounced {d:.1}s -> {s}", .{ types.framesToSeconds(total_frames, sr), path });
}

/// Signal the realtime backend to park and wait until it confirms. Returns
/// false on timeout — the caller must NOT touch the engine then, or the two
/// threads would call process() concurrently. (The TUI always runs a backend
/// — ALSA or Null — so the timeout only fires if that thread is wedged.)
fn parkAudio(app: *App) bool {
    const engine = app.session.engine;
    engine.bounce_parked.store(false, .release);
    engine.bounce_active.store(true, .release);
    const start = std.Io.Timestamp.now(app.io, .awake).nanoseconds;
    while (!engine.bounce_parked.load(.acquire)) {
        const elapsed = std.Io.Timestamp.now(app.io, .awake).nanoseconds - start;
        if (elapsed > 100 * std.time.ns_per_ms) return false;
        std.atomic.spinLoopHint();
    }
    return true;
}

/// Render the session from beat 0 into `buffer` (interleaved stereo), then
/// restore the live transport position and playing state. Assumes the caller
/// owns the engine (audio thread parked).
pub fn renderBounce(app: *App, buffer: []types.Sample) void {
    const engine = app.session.engine;
    const was_playing = engine.transport.playing;
    const saved_pos = engine.transport.position_frames;

    resetDevices(app);
    engine.limiter.reset();
    engine.transport.seekFrames(0);
    engine.transport.play();

    const block = types.default_block_frames * engine_mod.channels;
    var offset: usize = 0;
    while (offset < buffer.len) {
        const end = @min(offset + block, buffer.len);
        engine.process(buffer[offset..end]);
        offset = end;
    }

    resetDevices(app);
    engine.limiter.reset();
    engine.transport.seekFrames(saved_pos);
    if (was_playing) engine.transport.play() else engine.transport.stop();
}

/// Clear every device's tails/voices/sequencer state across all racks.
fn resetDevices(app: *App) void {
    var buf: [6]dsp.Device = undefined;
    for (app.session.racks.items) |rack| {
        for (rack.chain(&buf)) |dev| dev.reset();
    }
}

fn cmdBpm(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("bpm: {d:.1}", .{app.session.project.tempo_bpm});
        return;
    }
    const bpm = std.fmt.parseFloat(f64, trimmed) catch {
        app.setStatus("bpm: expected a number, e.g. :bpm 140", .{});
        return;
    };
    if (bpm < 20.0 or bpm > 400.0) {
        app.setStatus("bpm: must be between 20 and 400", .{});
        return;
    }
    app.session.project.tempo_bpm = bpm;
    _ = app.session.engine.send(.{ .set_tempo = bpm });
    app.setStatus("bpm: {d:.1}", .{bpm});
}

/// `:sig [<n>[/4]]` — beats per bar. The beat unit is fixed at /4 (a beat is
/// always a quarter note, matching the 16th-note step grid everywhere).
fn cmdSig(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("sig: {d}/4", .{app.session.project.beats_per_bar});
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, '/');
    const n = std.fmt.parseInt(u8, it.first(), 10) catch {
        app.setStatus("sig: expected beats per bar, e.g. :sig 3", .{});
        return;
    };
    if (it.next()) |unit| {
        if (!std.mem.eql(u8, unit, "4")) {
            app.setStatus("sig: only /4 signatures are supported", .{});
            return;
        }
    }
    if (n < 1 or n > 16) {
        app.setStatus("sig: beats per bar must be 1–16", .{});
        return;
    }
    app.session.project.beats_per_bar = n;
    _ = app.session.engine.send(.{ .set_time_signature = n });
    // Bar boundaries moved; refit the song timeline if it's driving playback.
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("sig: {d}/4", .{n});
}

fn cmdGain(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, args, ' ');
    const track_str = it.next() orelse {
        app.setStatus("usage: gain <track> [<dB>]", .{});
        return;
    };
    const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
        app.setStatus("gain: bad track number '{s}'", .{track_str});
        return;
    };
    if (track_1 == 0 or track_1 > app.session.project.tracks.items.len) {
        app.setStatus("gain: track must be 1–{d}", .{app.session.project.tracks.items.len});
        return;
    }
    const track_idx = track_1 - 1;
    const track = &app.session.project.tracks.items[track_idx];
    const db_str = std.mem.trim(u8, it.rest(), " ");
    if (db_str.len == 0) {
        app.setStatus("track {d} gain: {d:.1}dB", .{ track_1, track.gain_db });
        return;
    }
    const db = std.fmt.parseFloat(f32, db_str) catch {
        app.setStatus("gain: expected a dB value, e.g. :gain 2 -6", .{});
        return;
    };
    const clamped = std.math.clamp(db, -60.0, 12.0);
    track.gain_db = clamped;
    _ = app.session.engine.send(.{ .set_track_gain = .{
        .track = @intCast(track_idx),
        .gain = types.dbToGain(clamped),
    } });
    app.setStatus("track {d} gain: {d:.1}dB", .{ track_1, clamped });
}

fn cmdPan(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const track_str = it.next() orelse {
        app.setStatus("usage: pan <track> [<-1..1>]", .{});
        return;
    };
    const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
        app.setStatus("pan: bad track number '{s}'", .{track_str});
        return;
    };
    if (track_1 == 0 or track_1 > app.session.project.tracks.items.len) {
        app.setStatus("pan: track must be 1–{d}", .{app.session.project.tracks.items.len});
        return;
    }
    const track_idx = track_1 - 1;
    const track = &app.session.project.tracks.items[track_idx];
    const val_str = std.mem.trim(u8, it.rest(), " ");
    if (val_str.len == 0) {
        const pct: i32 = @intFromFloat(@abs(track.pan) * 100.0);
        if (pct == 0) app.setStatus("track {d} pan: center", .{track_1})
        else if (track.pan < 0) app.setStatus("track {d} pan: L{d}%", .{ track_1, pct })
        else app.setStatus("track {d} pan: R{d}%", .{ track_1, pct });
        return;
    }
    const val = std.fmt.parseFloat(f32, val_str) catch {
        app.setStatus("pan: expected a value between -1.0 and 1.0", .{});
        return;
    };
    track.pan = std.math.clamp(val, -1.0, 1.0);
    _ = app.session.engine.send(.{ .set_track_pan = .{ .track = @intCast(track_idx), .pan = track.pan } });
    const pct: i32 = @intFromFloat(@abs(track.pan) * 100.0);
    if (pct == 0) app.setStatus("track {d} pan: center", .{track_1})
    else if (track.pan < 0) app.setStatus("track {d} pan: L{d}%", .{ track_1, pct })
    else app.setStatus("track {d} pan: R{d}%", .{ track_1, pct });
}

fn cmdSeek(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const bar_1 = std.fmt.parseInt(u64, trimmed, 10) catch {
        app.setStatus("seek: expected a bar number, e.g. :seek 5", .{});
        return;
    };
    if (bar_1 == 0) {
        app.setStatus("seek: bar number starts at 1", .{});
        return;
    }
    const sr = @as(f64, @floatFromInt(app.session.project.sample_rate));
    const bpm = @max(app.session.project.tempo_bpm, 1.0);
    const beats_per_bar: f64 = @floatFromInt(app.session.project.beats_per_bar);
    const frames_per_bar: u64 = @intFromFloat(sr * 60.0 / bpm * beats_per_bar);
    _ = app.session.engine.send(.{ .seek_frames = (bar_1 - 1) * frames_per_bar });
    app.setStatus("seek → bar {d}", .{bar_1});
}

fn cmdVol(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        const sign: []const u8 = if (app.master_gain_db >= 0) "+" else "";
        app.setStatus("master vol: {s}{d:.1}dB  ([ / ] to adjust)", .{ sign, app.master_gain_db });
        return;
    }
    const db = std.fmt.parseFloat(f32, trimmed) catch {
        app.setStatus("vol: expected a dB value, e.g. :vol -6", .{});
        return;
    };
    app.master_gain_db = std.math.clamp(db, -40.0, 6.0);
    _ = app.session.engine.send(.{ .set_master_gain = types.dbToGain(app.master_gain_db) });
    const sign: []const u8 = if (app.master_gain_db >= 0) "+" else "";
    app.setStatus("master vol: {s}{d:.1}dB", .{ sign, app.master_gain_db });
}

fn cmdEq(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, args, ' ');
    const track_str = it.next() orelse {
        app.setStatus("usage: eq <track> [<band> <db>]", .{});
        return;
    };
    const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
        app.setStatus("eq: bad track number '{s}'", .{track_str});
        return;
    };
    if (track_1 == 0 or track_1 > app.session.racks.items.len) {
        app.setStatus("eq: track must be 1–{d}", .{app.session.racks.items.len});
        return;
    }
    const track_idx = track_1 - 1;
    const rest = std.mem.trim(u8, it.rest(), " ");
    if (rest.len == 0) {
        if (app.session.racks.items[track_idx].fx.eq) |*eq| {
            app.setStatus("track {d}: bypass={}", .{ track_1, eq.bypass });
        } else {
            app.setStatus("track {d}: no EQ", .{track_1});
        }
        return;
    }
    var rit = std.mem.splitScalar(u8, rest, ' ');
    const band_str = rit.next() orelse {
        app.setStatus("eq: usage eq <track> <band> <db>", .{});
        return;
    };
    const band = std.fmt.parseInt(usize, band_str, 10) catch {
        app.setStatus("eq: bad band number", .{});
        return;
    };
    if (band >= eq_mod.num_eq_bands) {
        app.setStatus("eq: band must be 0–{d}", .{eq_mod.num_eq_bands - 1});
        return;
    }
    const db = std.fmt.parseFloat(f32, rit.rest()) catch {
        app.setStatus("eq: expected dB value", .{});
        return;
    };
    app.setEqBand(@intCast(track_idx), band, db);
    app.setStatus("track {d} eq band {d}: {d:.1}dB", .{ track_1, band, db });
}

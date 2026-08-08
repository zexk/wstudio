//! Mixing/transport/bounce `:` commands split out of commands.zig - save/
//! quit, bounce to file or stems, tempo/meter/gain/pan, mute/solo, seek,
//! and song-section markers.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const dsp = ws.dsp.device;
const DrumMachine = ws.dsp.DrumMachine;
const Sampler = ws.dsp.Sampler;
const Slicer = ws.dsp.Slicer;
const cmd_mod = @import("cmd.zig");
const config_mod = @import("../config.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const history = @import("history.zig");
const piano_ed = @import("editors/piano.zig");
const preset_ed = @import("editors/preset_picker.zig");
const spectrum_ed = @import("editors/fx_editor.zig");
const theory = ws.theory;
const pattern_mod = ws.dsp.pattern;
const user_presets = @import("user_presets.zig");
const user_drum_kits = @import("user_drum_kits.zig");
const help_view = @import("help.zig");
const cu = @import("commands_util.zig");
const commands = @import("commands.zig");
const path_buf_len = commands.path_buf_len;
const parseFiniteFloat = commands.parseFiniteFloat;
const expandHome = commands.expandHome;

const cursorTrackIdx = cu.cursorTrackIdx;

/// Explicit :save argument (with `~` expanded), else the file the session
/// was loaded from / last saved to (already resolved - see `setProjectPath`),
/// else "project.wsj". Always copies into `buf` rather than returning
/// `app.projectPath()` directly: callers pass the result straight back into
/// `setProjectPath`, whose `@memcpy` panics ("arguments alias") if src and
/// dst are the same backing buffer - which `app.project_path_buf` is.
fn savePath(app: *App, args: []const u8, buf: []u8) []const u8 {
    const arg = std.mem.trim(u8, args, " ");
    if (arg.len > 0) return expandHome(buf, arg);
    const p = app.projectPath() orelse app.defaultProjectPath();
    const len = @min(p.len, buf.len);
    @memcpy(buf[0..len], p[0..len]);
    return buf[0..len];
}

pub fn cmdSave(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const path = savePath(app, args, &path_buf);
    app.emitEvent(.{ .ProjectSavePre = .{ .path = path } });
    ws.persist.save(app.allocator, &app.session, app.io, path) catch |e| {
        app.setStatus("save: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    app.deleteBackupIfPresent(); // stale for the path we just moved off of
    app.setProjectPath(path);
    app.dirty = false;
    app.setStatus("saved: {s}", .{path});
    app.emitEvent(.{ .ProjectSavePost = .{ .path = path } });
}

/// Vim-style write-and-quit: save the project, then exit. Only quits when
/// the save succeeds so a failed write leaves the session intact.
pub fn cmdWriteQuit(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const path = savePath(app, args, &path_buf);
    app.emitEvent(.{ .ProjectSavePre = .{ .path = path } });
    ws.persist.save(app.allocator, &app.session, app.io, path) catch |e| {
        app.setStatus("save: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    app.deleteBackupIfPresent(); // stale for the path we just moved off of
    app.setProjectPath(path);
    app.dirty = false;
    app.emitEvent(.{ .ProjectSavePost = .{ .path = path } });
    app.should_quit = true;
}

/// Splits a `:bounce`-family arg string into the leading path/dir (possibly
/// empty - caller supplies the default) and an optional trailing `16`/`24`
/// bit-depth token, defaulting to `wstudio.o.bounce_bit_depth`.
pub fn parseBounceArgs(app: *App, args: []const u8) struct { path: []const u8, bit_depth: ws.wav.BitDepth } {
    var trimmed = std.mem.trim(u8, args, " ");
    var bit_depth: ws.wav.BitDepth = app.bounce_bit_depth;
    if (std.mem.lastIndexOfScalar(u8, trimmed, ' ')) |sp| {
        const tail = std.mem.trim(u8, trimmed[sp + 1 ..], " ");
        if (std.mem.eql(u8, tail, "24")) {
            bit_depth = .pcm24;
            trimmed = std.mem.trim(u8, trimmed[0..sp], " ");
        } else if (std.mem.eql(u8, tail, "16")) {
            trimmed = std.mem.trim(u8, trimmed[0..sp], " ");
        }
    } else if (std.mem.eql(u8, trimmed, "24")) {
        bit_depth = .pcm24;
        trimmed = "";
    } else if (std.mem.eql(u8, trimmed, "16")) {
        trimmed = "";
    }
    return .{ .path = trimmed, .bit_depth = bit_depth };
}

/// An armed A/B loop region bounces exactly that span (e.g. exporting one
/// section to try in another tool); otherwise song mode renders the whole
/// arrangement and pattern mode the longest loop. Both cases append
/// `wstudio.o.bounce_tail_seconds` so reverb and release ring out.
pub fn computeBounceRange(app: *App) ws.bounce.Range {
    return ws.bounce.range(&app.session, app.bounce_tail_seconds);
}

/// Render the live session (patterns + synth params + drum grid) offline to
/// a PCM WAV (`wstudio.o.bounce_bit_depth`, overridden by a trailing
/// `16`/`24` argument). Length = the longest loop plus
/// `wstudio.o.bounce_tail_seconds` for reverb and release. The realtime
/// backend is parked for the duration so the UI thread can drive the engine
/// without racing the audio thread.
pub fn cmdBounce(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const parsed = parseBounceArgs(app, args);
    const requested = if (parsed.path.len > 0) parsed.path else app.default_bounce_path.slice();
    const path = expandHome(&path_buf, requested);
    const bit_depth = parsed.bit_depth;

    const sr = app.session.project.sample_rate;
    const range = computeBounceRange(app);
    writeParkedBounce(app, path, range, bit_depth) catch |e| {
        app.setStatus("bounce: {s}: {s}", .{ path, @errorName(e) });
        return;
    };

    if (range.has_loop_region) {
        app.setStatus("bounced {d:.1}s (loop region) -> {s}", .{ types.framesToSeconds(range.total_frames, sr), path });
    } else {
        app.setStatus("bounced {d:.1}s -> {s}", .{ types.framesToSeconds(range.total_frames, sr), path });
    }
}

/// `:bounce-stems [dir] [16|24]` - renders every non-empty track soloed in
/// turn to `<dir>/<N>-<track-name>.wav` (default dir: `wstudio.o.default_stems_dir`),
/// using the same length/range rules as `:bounce` (armed loop region, else
/// full song/pattern). Solo state is restored exactly afterward, whatever it
/// was before this ran.
pub fn cmdBounceStems(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const parsed = parseBounceArgs(app, args);
    const requested = if (parsed.path.len > 0) parsed.path else app.default_stems_dir.slice();
    const dir = expandHome(&path_buf, requested);
    const bit_depth = parsed.bit_depth;

    const engine = app.session.engine;
    const range = computeBounceRange(app);
    std.Io.Dir.cwd().createDirPath(app.io, dir) catch |e| {
        app.setStatus("bounce-stems: {s}: {s}", .{ dir, @errorName(e) });
        return;
    };

    const tracks = app.session.project.tracks.items;
    const saved_solo = app.allocator.alloc(bool, tracks.len) catch {
        app.setStatus("bounce-stems: out of memory", .{});
        return;
    };
    defer app.allocator.free(saved_solo);
    for (tracks, 0..) |t, i| saved_solo[i] = t.soloed;
    defer for (tracks, 0..) |*t, i| {
        t.soloed = saved_solo[i];
        _ = engine.send(.{ .set_track_solo = .{ .track = @intCast(i), .soloed = saved_solo[i] } });
    };

    var stem_buf: [64]u8 = undefined;
    var file_path_buf: [path_buf_len]u8 = undefined;
    var rendered: usize = 0;
    for (tracks, 0..) |t, i| {
        if (std.meta.activeTag(app.session.racks.items[i].instrument) == .empty) continue;

        for (tracks, 0..) |*t2, j| {
            t2.soloed = (j == i);
            _ = engine.send(.{ .set_track_solo = .{ .track = @intCast(j), .soloed = t2.soloed } });
        }

        const stem_name = ws.bounce.stemName(&stem_buf, t.name, i);
        const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}.wav", .{ dir, stem_name }) catch {
            app.setStatus("bounce-stems: path too long for track {d}", .{i + 1});
            continue;
        };
        writeParkedBounce(app, file_path, range, bit_depth) catch |e| {
            app.setStatus("bounce-stems: write failed for {s}: {s}", .{ stem_name, @errorName(e) });
            continue;
        };
        rendered += 1;
    }

    if (rendered == 0) {
        app.setStatus("bounce-stems: no non-empty tracks to render", .{});
    } else {
        app.setStatus("bounce-stems: {d} track(s) -> {s}/", .{ rendered, dir });
    }
}

/// Signal the realtime backend to park and wait until it confirms. Returns
/// false on timeout - the caller must NOT touch the engine then, or the two
/// threads would call process() concurrently. (The TUI always runs a backend
/// - ALSA or Null - so the timeout only fires if that thread is wedged.)
pub fn parkAudio(app: *App) bool {
    const engine = app.session.engine;
    engine.bounce_parked.store(false, .release);
    engine.bounce_active.store(true, .release);
    const start = std.Io.Timestamp.now(app.io, .awake).nanoseconds;
    while (!engine.bounce_parked.load(.acquire)) {
        const elapsed = std.Io.Timestamp.now(app.io, .awake).nanoseconds - start;
        if (elapsed > 100 * std.time.ns_per_ms) return false;
        app.io.sleep(.fromMilliseconds(1), .awake) catch return false;
    }
    return true;
}

pub fn writeParkedBounce(app: *App, path: []const u8, range: ws.bounce.Range, bit_depth: ws.wav.BitDepth) !void {
    const engine = app.session.engine;
    if (!parkAudio(app)) return error.AudioThreadDidNotPark;
    defer {
        engine.bounce_active.store(false, .release);
        engine.bounce_parked.store(false, .release);
    }

    try ws.bounce.writeFile(app.allocator, app.io, path, &app.session, range, bit_depth);
}

/// Render the session from `start_frame` into `buffer` (interleaved stereo),
/// then restore the live transport position and playing state. Assumes the
/// caller owns the engine (audio thread parked).
pub fn renderBounce(app: *App, buffer: []types.Sample, start_frame: u64) void {
    ws.bounce.render(&app.session, buffer, start_frame);
}

pub fn cmdBpm(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("bpm: {d:.1}", .{app.session.project.tempo_bpm});
        return;
    }
    const bpm = parseFiniteFloat(f64, trimmed) catch {
        app.setStatus("bpm: expected a number, e.g. :bpm 140", .{});
        return;
    };
    if (bpm < 20.0 or bpm > 400.0) {
        app.setStatus("bpm: must be between 20 and 400", .{});
        return;
    }
    app.session.project.tempo_bpm = bpm;
    _ = app.session.engine.send(.{ .set_tempo = bpm });
    // The loop region is stored in bars; its frame mirror just moved.
    app.session.syncLoop();
    app.dirty = true;
    app.setStatus("bpm: {d:.1}", .{bpm});
}

/// `:sig [<n>[/4]]` - beats per bar. The beat unit is fixed at /4 (a beat is
/// always a quarter note, matching the 16th-note step grid everywhere).
pub fn cmdSig(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("sig: {d}/4", .{app.session.project.beats_per_bar});
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, '/');
    const n = std.fmt.parseInt(u8, it.first(), 10) catch {
        app.setStatus("signature: expected beats per bar, e.g. :signature 3", .{});
        return;
    };
    if (it.next()) |unit| {
        if (!std.mem.eql(u8, unit, "4")) {
            app.setStatus("sig: only /4 signatures are supported", .{});
            return;
        }
        if (it.next() != null) {
            app.setStatus("signature: expected beats per bar, e.g. :signature 3/4", .{});
            return;
        }
    }
    if (n < 1 or n > 16) {
        app.setStatus("sig: beats per bar must be 1–16", .{});
        return;
    }
    app.session.project.beats_per_bar = n;
    _ = app.session.engine.send(.{ .set_time_signature = n });
    // Bar boundaries moved; refit the song timeline if it's driving playback,
    // and re-derive the loop region's frame mirror.
    if (app.session.song_mode) app.session.rebuildSongData();
    app.session.syncLoop();
    app.dirty = true;
    app.setStatus("sig: {d}/4", .{n});
}

pub fn cmdGain(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const track_str = it.next() orelse "";
    // No leading arg at all: fall back to the cursor track, same
    // convenience :track-del's cursor fallback already established.
    const track_idx: usize = if (track_str.len == 0)
        cursorTrackIdx(app) orelse {
            app.setStatus("usage: gain <track> [<dB>]", .{});
            return;
        }
    else blk: {
        const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
            app.setStatus("gain: bad track number '{s}'", .{track_str});
            return;
        };
        if (track_1 == 0 or track_1 > app.session.project.tracks.items.len) {
            app.setStatus("gain: track must be 1–{d}", .{app.session.project.tracks.items.len});
            return;
        }
        break :blk track_1 - 1;
    };
    const track_1 = track_idx + 1;
    const track = &app.session.project.tracks.items[track_idx];
    const db_str = std.mem.trim(u8, it.rest(), " ");
    if (db_str.len == 0) {
        app.setStatus("track {d} gain: {d:.1}dB", .{ track_1, track.gain_db });
        return;
    }
    const db = parseFiniteFloat(f32, db_str) catch {
        app.setStatus("gain: expected a dB value, e.g. :gain 2 -6", .{});
        return;
    };
    const before = track.gain_db;
    app.apiSetTrackGainDb(track_idx, db);
    history.recordTrackMixer(app, @intCast(track_idx), .gain, before);
    app.setStatus("track {d} gain: {d:.1}dB", .{ track_1, track.gain_db });
}

pub fn cmdPan(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const track_str = it.next() orelse "";
    const track_idx: usize = if (track_str.len == 0)
        cursorTrackIdx(app) orelse {
            app.setStatus("usage: pan <track> [<-1..1>]", .{});
            return;
        }
    else blk: {
        const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
            app.setStatus("pan: bad track number '{s}'", .{track_str});
            return;
        };
        if (track_1 == 0 or track_1 > app.session.project.tracks.items.len) {
            app.setStatus("pan: track must be 1–{d}", .{app.session.project.tracks.items.len});
            return;
        }
        break :blk track_1 - 1;
    };
    const track_1 = track_idx + 1;
    const track = &app.session.project.tracks.items[track_idx];
    const val_str = std.mem.trim(u8, it.rest(), " ");
    if (val_str.len == 0) {
        // zig fmt: off
        const pct: i32 = @intFromFloat(@abs(track.pan) * 100.0);
        if (pct == 0) app.setStatus("track {d} pan: center", .{track_1})
        else if (track.pan < 0) app.setStatus("track {d} pan: L{d}%", .{ track_1, pct })
        else app.setStatus("track {d} pan: R{d}%", .{ track_1, pct });
        return;
    }
    const val = parseFiniteFloat(f32, val_str) catch {
        app.setStatus("pan: expected a value between -1.0 and 1.0", .{});
        return;
    };
    const before = track.pan;
    app.apiSetTrackPan(track_idx, val);
    history.recordTrackMixer(app, @intCast(track_idx), .pan, before);
    const pct: i32 = @intFromFloat(@abs(track.pan) * 100.0);
    if (pct == 0) app.setStatus("track {d} pan: center", .{track_1})
    else if (track.pan < 0) app.setStatus("track {d} pan: L{d}%", .{ track_1, pct })
    else app.setStatus("track {d} pan: R{d}%", .{ track_1, pct });
    // zig fmt: on
}

/// `:unmute` - clear mute on every track in one shot. `m` only toggles the
/// cursor track, so this is the fast way back to "everything audible" after
/// muting several while working. Not undo-tracked, matching `m` itself - a
/// mixer-style live param.
pub fn cmdUnmute(app: *App, _: []const u8) void {
    var n: usize = 0;
    for (app.session.project.tracks.items, 0..) |track, i| {
        if (!track.muted) continue;
        app.apiSetTrackMuted(i, false);
        n += 1;
    }
    if (n == 0) {
        app.setStatus("unmute: nothing was muted", .{});
        return;
    }
    app.setStatus("unmuted {d} track{s}", .{ n, if (n == 1) "" else "s" });
}

/// `:unsolo` - clear solo on every track in one shot, the counterpart to
/// `:unmute` - the fast way back to normal monitoring after soloing several
/// tracks to audition them. Not undo-tracked, matching `S` itself.
pub fn cmdUnsolo(app: *App, _: []const u8) void {
    var n: usize = 0;
    for (app.session.project.tracks.items, 0..) |track, i| {
        if (!track.soloed) continue;
        app.apiSetTrackSoloed(i, false);
        n += 1;
    }
    if (n == 0) {
        app.setStatus("unsolo: nothing was soloed", .{});
        return;
    }
    app.setStatus("unsoloed {d} track{s}", .{ n, if (n == 1) "" else "s" });
}

pub fn cmdSeek(app: *App, args: []const u8) void {
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
    const frames = std.math.mul(u64, bar_1 - 1, frames_per_bar) catch {
        app.setStatus("seek: bar number is too large", .{});
        return;
    };
    _ = app.session.engine.send(.{ .seek_frames = frames });
    app.setStatus("seek → bar {d}", .{bar_1});
}

pub fn cmdSection(app: *App, args: []const u8) void {
    if (app.view != .arrangement) {
        app.setStatus("section: open arrangement first", .{});
        return;
    }
    const name = std.mem.trim(u8, args, " ");
    if (name.len == 0) {
        app.setStatus("usage: section <name>", .{});
        return;
    }
    const tick = app.arr_cursor_bar *| app.arr_grid.ticks();
    app.session.project.setSection(tick, name) catch {
        app.setStatus("section failed (out of memory)", .{});
        return;
    };
    app.dirty = true;
    app.setStatus("section \"{s}\" at tick {d}", .{ name, tick });
}

pub fn cmdSectionDel(app: *App, _: []const u8) void {
    if (app.view != .arrangement) {
        app.setStatus("section-del: open arrangement first", .{});
        return;
    }
    const tick = app.arr_cursor_bar *| app.arr_grid.ticks();
    if (!app.session.project.removeSection(tick)) {
        app.setStatus("no section at cursor", .{});
        return;
    }
    app.dirty = true;
    app.setStatus("section deleted", .{});
}

fn audioRegionAtCursor(app: *App, command: []const u8) ?*ws.Clip.AudioRegion {
    if (app.view != .arrangement) {
        app.setStatus("{s}: open arrangement first", .{command});
        return null;
    }
    const lane = app.session.arrangement.lane(app.cursor) orelse return null;
    const clip = lane.clipAt(app.arr_cursor_bar *| app.arr_grid.ticks()) orelse {
        app.setStatus("{s}: no clip at cursor", .{command});
        return null;
    };
    switch (clip.content) {
        .audio => {},
        else => {
            app.setStatus("{s}: clip is not audio", .{command});
            return null;
        },
    }
    return &clip.content.audio;
}

pub fn cmdClipGain(app: *App, args: []const u8) void {
    const audio = audioRegionAtCursor(app, "clip-gain") orelse return;
    const arg = std.mem.trim(u8, args, " ");
    if (arg.len == 0) {
        app.setStatus("clip gain: {d:.1}dB", .{audio.gain_db});
        return;
    }
    const db = parseFiniteFloat(f32, arg) catch {
        app.setStatus("clip-gain: expected -60 to 24 dB", .{});
        return;
    };
    if (db < -60.0 or db > 24.0) {
        app.setStatus("clip-gain: expected -60 to 24 dB", .{});
        return;
    }
    history.recordLane(app, @intCast(app.cursor));
    audio.gain_db = db;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("clip gain: {d:.1}dB", .{db});
}

pub fn cmdClipFade(app: *App, args: []const u8) void {
    const audio = audioRegionAtCursor(app, "clip-fade") orelse return;
    const arg = std.mem.trim(u8, args, " ");
    if (arg.len == 0) {
        const sr: f64 = @floatFromInt(app.session.project.sample_rate);
        app.setStatus("clip fades: {d:.3}s in, {d:.3}s out", .{
            @as(f64, @floatFromInt(audio.fade_in_frames)) / sr,
            @as(f64, @floatFromInt(audio.fade_out_frames)) / sr,
        });
        return;
    }
    var it = std.mem.tokenizeScalar(u8, arg, ' ');
    const in_s = parseFiniteFloat(f64, it.next() orelse "") catch {
        app.setStatus("clip-fade: expected <in-seconds> <out-seconds>", .{});
        return;
    };
    const out_s = parseFiniteFloat(f64, it.next() orelse "") catch {
        app.setStatus("clip-fade: expected <in-seconds> <out-seconds>", .{});
        return;
    };
    if (it.next() != null or in_s < 0 or out_s < 0 or in_s > 3600 or out_s > 3600) {
        app.setStatus("clip-fade: seconds must be between 0 and 3600", .{});
        return;
    }
    const sr: f64 = @floatFromInt(app.session.project.sample_rate);
    history.recordLane(app, @intCast(app.cursor));
    audio.fade_in_frames = @intFromFloat(@round(in_s * sr));
    audio.fade_out_frames = @intFromFloat(@round(out_s * sr));
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("clip fades: {d:.3}s in, {d:.3}s out", .{ in_s, out_s });
}

pub fn cmdVol(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        const sign: []const u8 = if (app.master_gain_db >= 0) "+" else "";
        app.setStatus("master vol: {s}{d:.1}dB  ([ / ] to adjust)", .{ sign, app.master_gain_db });
        return;
    }
    const db = parseFiniteFloat(f32, trimmed) catch {
        app.setStatus("volume: expected a dB value, e.g. :volume -6", .{});
        return;
    };
    app.apiSetMasterGainDb(db);
    const sign: []const u8 = if (app.master_gain_db >= 0) "+" else "";
    app.setStatus("master vol: {s}{d:.1}dB", .{ sign, app.master_gain_db });
}

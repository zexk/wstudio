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
const cmd_mod = @import("../cmd.zig");
const config_mod = @import("../../config.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const history = @import("../history.zig");
const piano_ed = @import("../editors/piano.zig");
const preset_ed = @import("../editors/preset_picker.zig");
const spectrum_ed = @import("../editors/fx_editor.zig");
const theory = ws.theory;
const pattern_mod = ws.dsp.pattern;
const user_presets = @import("../user_presets.zig");
const user_drum_kits = @import("../user_drum_kits.zig");
const help_view = @import("../help.zig");
const cu = @import("util.zig");
const commands = @import("../commands.zig");
const path_buf_len = commands.path_buf_len;
const parseFiniteFloat = commands.parseFiniteFloat;
const expandHome = commands.expandHome;

const cursorTrackIdx = cu.cursorTrackIdx;

fn compFrameCount(source_frames: u64, source_rate: u32, project_rate: u32, channels: u16) ?usize {
    if (source_rate == 0 or project_rate == 0 or channels == 0) return null;
    const frames = @as(u128, source_frames) * project_rate / source_rate;
    const max_frames = ws.dsp.audio_file.max_decoded_samples / @as(usize, channels);
    if (frames == 0 or frames > max_frames) return null;
    return @intCast(frames);
}

fn beatFrameBound(beat: f64, frames_per_beat: f64, limit: usize) usize {
    const frames = @round(beat * frames_per_beat);
    if (!std.math.isFinite(frames) or frames >= @as(f64, @floatFromInt(limit))) return limit;
    return @intFromFloat(@max(frames, 0));
}

fn audioFrameCount(frames: f64, channels: u16) ?usize {
    if (!std.math.isFinite(frames) or channels == 0) return null;
    const max_frames = ws.dsp.audio_file.max_decoded_samples / @as(usize, channels);
    if (frames > @as(f64, @floatFromInt(max_frames))) return null;
    return @intFromFloat(@max(frames, 1));
}

/// Explicit :save argument (with `~` expanded), else the file the session
/// was loaded from / last saved to (already resolved - see `setProjectPath`),
/// else "project.wsj". Always copies into `buf` rather than returning
/// `app.projectPath()` directly: callers pass the result straight back into
/// `setProjectPath`, whose `@memcpy` panics ("arguments alias") if src and
/// dst are the same backing buffer - which `app.project_path_buf` is.
fn savePath(app: *App, args: []const u8, buf: []u8) []const u8 {
    const arg = std.mem.trim(u8, args, " ");
    if (arg.len > 0) return withDefaultProjectExtension(buf, expandHome(buf, arg));
    const p = app.projectPath() orelse app.defaultProjectPath();
    const len = @min(p.len, buf.len);
    @memcpy(buf[0..len], p[0..len]);
    return buf[0..len];
}

fn withDefaultProjectExtension(buf: []u8, path: []const u8) []const u8 {
    if (std.fs.path.extension(path).len > 0 or path.len + ".wsj".len > buf.len) return path;
    if (path.ptr != buf.ptr) @memcpy(buf[0..path.len], path);
    @memcpy(buf[path.len..][0..".wsj".len], ".wsj");
    return buf[0 .. path.len + ".wsj".len];
}

test "save paths default to wsj extension" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("song.wsj", withDefaultProjectExtension(&buf, "song"));
    try std.testing.expectEqualStrings("song.other", withDefaultProjectExtension(&buf, "song.other"));
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
/// `16`/`24` argument), or to FLAC/Ogg Vorbis when the path ends in `.flac`
/// or `.ogg` - the extension is the only place the format is chosen, since
/// the file name already says it. Length = the longest loop plus
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
        if (e == error.RefusingToOverwriteProject) {
            app.setStatus("bounce: refusing to overwrite project file: {s}", .{path});
            return;
        }
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
            if (e == error.RefusingToOverwriteProject) {
                app.setStatus("bounce-stems: refusing to overwrite project file: {s}", .{file_path});
                return;
            }
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
    if (app.session.song_mode) app.session.rebuildSongData();
    // The loop region is stored in bars; its frame mirror just moved.
    app.session.syncLoop();
    app.dirty = true;
    app.setStatus("bpm: {d:.1}", .{bpm});
}

pub fn cmdSig(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("sig: {d}/{d}", .{ app.session.project.beats_per_bar, app.session.project.meter_denominator });
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, '/');
    const n = std.fmt.parseInt(u8, it.next() orelse "", 10) catch {
        app.setStatus("signature: expected beats per bar, e.g. :signature 3", .{});
        return;
    };
    const denominator = if (it.next()) |unit| blk: {
        const parsed = std.fmt.parseInt(u8, unit, 10) catch {
            app.setStatus("signature: expected n/d, e.g. :signature 6/8", .{});
            return;
        };
        if (it.next() != null) {
            app.setStatus("signature: expected n/d, e.g. :signature 6/8", .{});
            return;
        }
        break :blk parsed;
    } else @as(u8, 4);
    if (n < 1 or n > 32 or !std.math.isPowerOfTwo(denominator) or denominator > 32) {
        app.setStatus("sig: numerator 1-32; denominator 1, 2, 4, 8, 16, or 32", .{});
        return;
    }
    app.session.project.beats_per_bar = n;
    app.session.project.meter_denominator = denominator;
    _ = app.session.engine.send(.{ .set_time_signature = n });
    _ = app.session.engine.send(.{ .set_meter_denominator = denominator });
    // Bar boundaries moved; refit the song timeline if it's driving playback,
    // and re-derive the loop region's frame mirror.
    if (app.session.song_mode) app.session.rebuildSongData();
    app.session.syncLoop();
    app.dirty = true;
    app.setStatus("sig: {d}/{d}", .{ n, denominator });
}

pub fn cmdTempoPoint(app: *App, args: []const u8) void {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const beat = parseFiniteFloat(f64, words.next() orelse "") catch {
        app.setStatus("tempo-point: expected <beat> <bpm> [step|ramp]", .{});
        return;
    };
    const bpm = parseFiniteFloat(f64, words.next() orelse "") catch {
        app.setStatus("tempo-point: expected <beat> <bpm> [step|ramp]", .{});
        return;
    };
    const shape = words.next() orelse "step";
    if (words.next() != null or (!std.mem.eql(u8, shape, "step") and !std.mem.eql(u8, shape, "ramp"))) {
        app.setStatus("tempo-point: shape must be step or ramp", .{});
        return;
    }
    const point: ws.time_map.TempoPoint = .{ .beat = beat, .bpm = bpm, .ramp_to_next = std.mem.eql(u8, shape, "ramp") };
    app.session.project.setTempoPoint(point) catch {
        app.setStatus("tempo-point: beat >= 0, BPM 20-400, max 64 points", .{});
        return;
    };
    _ = app.session.engine.send(.{ .set_tempo_point = point });
    if (app.session.song_mode) app.session.rebuildSongData();
    app.session.syncLoop();
    app.dirty = true;
    app.setStatus("tempo point: beat {d:.2}, {d:.1} BPM, {s}", .{ beat, bpm, shape });
}

pub fn cmdMeterPoint(app: *App, args: []const u8) void {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const beat = parseFiniteFloat(f64, words.next() orelse "") catch {
        app.setStatus("meter-point: expected <beat> <n>/<d>", .{});
        return;
    };
    const signature = words.next() orelse "";
    if (words.next() != null) {
        app.setStatus("meter-point: expected <beat> <n>/<d>", .{});
        return;
    }
    var parts = std.mem.splitScalar(u8, signature, '/');
    const numerator = std.fmt.parseInt(u8, parts.first(), 10) catch {
        app.setStatus("meter-point: expected <beat> <n>/<d>", .{});
        return;
    };
    const denominator = std.fmt.parseInt(u8, parts.next() orelse "", 10) catch {
        app.setStatus("meter-point: expected <beat> <n>/<d>", .{});
        return;
    };
    if (parts.next() != null) {
        app.setStatus("meter-point: expected <beat> <n>/<d>", .{});
        return;
    }
    const point: ws.time_map.MeterPoint = .{ .beat = beat, .numerator = numerator, .denominator = denominator };
    app.session.project.setMeterPoint(point) catch {
        app.setStatus("meter-point: invalid meter or max 64 points", .{});
        return;
    };
    _ = app.session.engine.send(.{ .set_meter_point = point });
    app.session.syncLoop();
    app.dirty = true;
    app.setStatus("meter point: beat {d:.2}, {d}/{d}", .{ beat, numerator, denominator });
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

/// `:unmute`/`:unsolo` - clear mute/solo on every track in one shot. `m`
/// and `S` only toggle the cursor track, so these are the fast way back to
/// "everything audible" / normal monitoring after flagging several while
/// working. Not undo-tracked, matching `m`/`S` themselves - mixer-style
/// live params.
pub fn cmdUnmute(app: *App, _: []const u8) void {
    clearTrackFlag(app, .mute);
}

pub fn cmdUnsolo(app: *App, _: []const u8) void {
    clearTrackFlag(app, .solo);
}

/// `:reference [track|off]`: designate a track, then toggle between it and
/// the current mix. A Utility unit on the reference track matches the
/// short-term master loudness captured when the track is designated.
pub fn cmdReference(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (std.mem.eql(u8, trimmed, "off")) {
        leaveReference(app);
        app.reference_track = null;
        app.setStatus("reference: off", .{});
        return;
    }
    if (trimmed.len > 0) {
        const track_1 = std.fmt.parseInt(usize, trimmed, 10) catch {
            app.setStatus("reference: expected track number or off", .{});
            return;
        };
        if (track_1 == 0 or track_1 > app.session.racks.items.len) {
            app.setStatus("reference: track must be 1–{d}", .{app.session.racks.items.len});
            return;
        }
        leaveReference(app);
        const track: u16 = @intCast(track_1 - 1);
        const rack = app.session.racks.items[track];
        const unit = rack.fx.find(.utility) orelse rack.fx.insert(app.allocator, rack.fx.units.items.len, .utility, app.session.project.sample_rate) catch {
            app.setStatus("reference: FX chain full or out of memory", .{});
            return;
        };
        const measured = app.session.engine.uiSnapshot().lufs_short_term;
        unit.payload.utility.autogain_on = 1;
        unit.payload.utility.autogain_target_lufs = if (measured > ws.dsp.LoudnessMeter.floor_lufs) measured else -18;
        app.session.syncTrackChain(track, rack);
        app.reference_track = track;
        app.dirty = true;
    }

    const reference = app.reference_track orelse {
        app.setStatus("usage: reference <track|off>", .{});
        return;
    };
    if (app.reference_active) {
        leaveReference(app);
        app.setStatus("reference: mix", .{});
        return;
    }

    for (app.session.project.tracks.items, 0..) |track, i| {
        app.reference_saved_solo[i] = track.soloed;
        app.apiSetTrackSoloed(i, i == reference);
    }
    for (&app.session.groups, 0..) |group, i| {
        app.reference_saved_group_solo[i] = if (group) |g| g.soloed else false;
        if (group != null) app.session.setGroupSoloed(@intCast(i), false);
    }
    app.reference_active = true;
    app.setStatus("reference: track {d}", .{reference + 1});
}

fn leaveReference(app: *App) void {
    if (!app.reference_active) return;
    for (app.session.project.tracks.items, 0..) |_, i| app.apiSetTrackSoloed(i, app.reference_saved_solo[i]);
    for (&app.session.groups, 0..) |group, i| if (group != null)
        app.session.setGroupSoloed(@intCast(i), app.reference_saved_group_solo[i]);
    app.reference_active = false;
}

fn clearTrackFlag(app: *App, flag: enum { mute, solo }) void {
    var n: usize = 0;
    for (app.session.project.tracks.items, 0..) |track, i| {
        if (!(if (flag == .mute) track.muted else track.soloed)) continue;
        if (flag == .mute) app.apiSetTrackMuted(i, false) else app.apiSetTrackSoloed(i, false);
        n += 1;
    }
    const name = if (flag == .mute) "mute" else "solo";
    const past = if (flag == .mute) "muted" else "soloed";
    if (n == 0) {
        app.setStatus("un{s}: nothing was {s}", .{ name, past });
        return;
    }
    app.setStatus("un{s} {d} track{s}", .{ past, n, if (n == 1) "" else "s" });
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
    if (bar_1 - 1 > std.math.maxInt(u32)) {
        app.setStatus("seek: bar number is too large", .{});
        return;
    }
    const frames = app.session.project.frameAtBar(@intCast(bar_1 - 1));
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
    history.recordSections(app);
    app.session.project.setSection(tick, name) catch {
        app.setStatus("section failed (out of memory)", .{});
        return;
    };
    app.dirty = true;
    app.setStatus("section \"{s}\" at bar {d}", .{ name, app.session.project.barAtTick(tick).bar + 1 });
}

pub fn cmdSectionDel(app: *App, _: []const u8) void {
    if (app.view != .arrangement) {
        app.setStatus("section-del: open arrangement first", .{});
        return;
    }
    const tick = app.arr_cursor_bar *| app.arr_grid.ticks();
    // Probe before snapshotting: an undo step for a no-op delete would make
    // `u` look like it did nothing.
    const present = for (app.session.project.sections.items) |section| {
        if (section.tick == tick) break true;
    } else false;
    if (!present) {
        app.setStatus("no section at cursor", .{});
        return;
    }
    history.recordSections(app);
    _ = app.session.project.removeSection(tick);
    app.dirty = true;
    app.setStatus("section deleted", .{});
}

/// The clip under the arrangement cursor, or null with the reason on the
/// status line. Every clip command routes its preconditions through here so
/// none of them can fail silently.
fn clipAtCursor(app: *App, command: []const u8) ?*ws.Clip {
    if (app.view != .arrangement) {
        app.setStatus("{s}: open arrangement first", .{command});
        return null;
    }
    const lane = app.session.arrangement.lane(app.cursor) orelse {
        app.setStatus("{s}: no track at cursor", .{command});
        return null;
    };
    return lane.clipAt(app.arr_cursor_bar *| app.arr_grid.ticks()) orelse {
        app.setStatus("{s}: no clip at cursor", .{command});
        return null;
    };
}

fn audioRegionAtCursor(app: *App, command: []const u8) ?*ws.Clip.AudioRegion {
    const clip = clipAtCursor(app, command) orelse return null;
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
        app.setStatus("clip fades: {d:.3}s in, {d:.3}s out, {s}", .{
            @as(f64, @floatFromInt(audio.fade_in_frames)) / sr,
            @as(f64, @floatFromInt(audio.fade_out_frames)) / sr,
            @tagName(audio.fade_curve),
        });
        return;
    }
    var it = std.mem.tokenizeScalar(u8, arg, ' ');
    const in_s = parseFiniteFloat(f64, it.next() orelse "") catch {
        app.setStatus("clip-fade: expected <in-seconds> <out-seconds>", .{});
        return;
    };
    const out_s = parseFiniteFloat(f64, it.next() orelse "") catch {
        app.setStatus("clip-fade: expected <in-seconds> <out-seconds> [linear|equal_power]", .{});
        return;
    };
    const curve = if (it.next()) |name| std.meta.stringToEnum(ws.arrangement.FadeCurve, name) orelse {
        app.setStatus("clip-fade: curve must be linear or equal_power", .{});
        return;
    } else audio.fade_curve;
    if (it.next() != null or in_s < 0 or out_s < 0 or in_s > 3600 or out_s > 3600) {
        app.setStatus("clip-fade: seconds must be between 0 and 3600", .{});
        return;
    }
    const sr: f64 = @floatFromInt(app.session.project.sample_rate);
    history.recordLane(app, @intCast(app.cursor));
    audio.fade_in_frames = @intFromFloat(@round(in_s * sr));
    audio.fade_out_frames = @intFromFloat(@round(out_s * sr));
    audio.fade_curve = curve;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("clip fades: {d:.3}s in, {d:.3}s out, {s}", .{ in_s, out_s, @tagName(curve) });
}

pub fn cmdClipStretch(app: *App, args: []const u8) void {
    const audio = audioRegionAtCursor(app, "clip-stretch") orelse return;
    const arg = std.mem.trim(u8, args, " ");
    if (arg.len == 0) {
        app.setStatus("clip stretch: {d:.3}x", .{audio.stretch_ratio});
        return;
    }
    const ratio = parseFiniteFloat(f32, arg) catch {
        app.setStatus("clip-stretch: expected 0.125 to 8", .{});
        return;
    };
    if (ratio < 0.125 or ratio > 8.0) {
        app.setStatus("clip-stretch: expected 0.125 to 8", .{});
        return;
    }
    history.recordLane(app, @intCast(app.cursor));
    audio.stretch_ratio = ratio;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("clip stretch: {d:.3}x", .{ratio});
}

pub fn cmdClipReverse(app: *App, _: []const u8) void {
    const audio = audioRegionAtCursor(app, "clip-reverse") orelse return;
    history.recordLane(app, @intCast(app.cursor));
    audio.reverse = !audio.reverse;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("clip reverse: {s}", .{if (audio.reverse) "on" else "off"});
}

fn slippedFrame(start: u64, seconds: f64, sample_rate: u32) u64 {
    const magnitude_f = @round(@abs(seconds) * @as(f64, @floatFromInt(sample_rate)));
    if (!std.math.isFinite(magnitude_f) or magnitude_f >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
        return if (seconds < 0) 0 else std.math.maxInt(u64);
    const magnitude: u64 = @intFromFloat(magnitude_f);
    return if (seconds < 0) start -| magnitude else start +| magnitude;
}

pub fn cmdClipSlip(app: *App, args: []const u8) void {
    const audio = audioRegionAtCursor(app, "clip-slip") orelse return;
    const seconds = parseFiniteFloat(f64, std.mem.trim(u8, args, " ")) catch {
        app.setStatus("clip-slip: expected signed seconds", .{});
        return;
    };
    history.recordLane(app, @intCast(app.cursor));
    audio.source_start_frame = slippedFrame(audio.source_start_frame, seconds, app.session.project.sample_rate);
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("clip slipped to source frame {d}", .{audio.source_start_frame});
}

test "clip slip saturates extreme offsets" {
    try std.testing.expectEqual(@as(u64, 130), slippedFrame(100, 3, 10));
    try std.testing.expectEqual(@as(u64, 70), slippedFrame(100, -3, 10));
    try std.testing.expectEqual(std.math.maxInt(u64), slippedFrame(100, 1e308, 48_000));
    try std.testing.expectEqual(@as(u64, 0), slippedFrame(100, -1e308, 48_000));
}

pub fn cmdClipLayer(app: *App, args: []const u8) void {
    const clip = clipAtCursor(app, "clip-layer") orelse return;
    const arg = std.mem.trim(u8, args, " ");
    if (arg.len == 0) {
        app.setStatus("clip layer: {d}", .{clip.layer});
        return;
    }
    const layer = std.fmt.parseInt(u8, arg, 10) catch {
        app.setStatus("clip-layer: expected 0 to 255", .{});
        return;
    };
    history.recordLane(app, @intCast(app.cursor));
    clip.layer = layer;
    app.dirty = true;
    app.setStatus("clip layer: {d}", .{layer});
}

pub fn cmdCrossfade(app: *App, _: []const u8) void {
    const selected = clipAtCursor(app, "crossfade") orelse return;
    if (selected.content != .audio) {
        app.setStatus("crossfade: clip is not audio", .{});
        return;
    }
    const lane = app.session.arrangement.lane(app.cursor).?; // clipAtCursor resolved it
    var other: ?*ws.Clip = null;
    for (lane.clips.items) |*candidate| {
        if (candidate == selected or candidate.content != .audio) continue;
        if (candidate.start_tick < selected.endTick() and selected.start_tick < candidate.endTick()) {
            other = candidate;
            break;
        }
    }
    const peer = other orelse {
        app.setStatus("crossfade: no overlapping audio layer", .{});
        return;
    };
    const overlap_start = @max(selected.start_tick, peer.start_tick);
    const overlap_end = @min(selected.endTick(), peer.endTick());
    const frames = app.session.project.framesAtBeat(ws.time_grid.tickToBeat(overlap_end)) -|
        app.session.project.framesAtBeat(ws.time_grid.tickToBeat(overlap_start));
    history.recordLane(app, @intCast(app.cursor));
    if (selected.start_tick >= peer.start_tick) {
        selected.content.audio.fade_in_frames = frames;
        peer.content.audio.fade_out_frames = frames;
    } else {
        selected.content.audio.fade_out_frames = frames;
        peer.content.audio.fade_in_frames = frames;
    }
    selected.content.audio.fade_curve = .equal_power;
    peer.content.audio.fade_curve = .equal_power;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("crossfade: {d} frames", .{frames});
}

pub fn cmdConsolidate(app: *App, _: []const u8) void {
    const clip = clipAtCursor(app, "consolidate") orelse return;
    const audio = switch (clip.content) {
        .audio => |region| region,
        else => {
            app.setStatus("consolidate: clip is not audio", .{});
            return;
        },
    };
    const source = app.session.project.audioSource(audio.source_id) orelse {
        app.setStatus("consolidate: missing audio source", .{});
        return;
    };
    const frames_per_beat = app.session.engine.transport.framesPerBeat();
    const channels = source.channel_count;
    const frame_count = audioFrameCount(ws.time_grid.tickToBeat(clip.length_ticks) * frames_per_beat, channels) orelse {
        app.setStatus("consolidate: output is too large; shorten the clip", .{});
        return;
    };
    const rendered = app.allocator.alloc(f32, frame_count * channels) catch {
        app.setStatus("consolidate: out of memory", .{});
        return;
    };
    defer app.allocator.free(rendered);
    const source_frames = source.samples.len / channels;
    // Bake with the same clamps `Session.syncAudioRegions` applies before
    // playback, so the consolidated source sounds like what was heard.
    const gain = ws.types.dbToGain(std.math.clamp(audio.gain_db, -60.0, 24.0));
    const stretch_ratio = std.math.clamp(audio.stretch_ratio, 0.125, 8.0);
    const fade_in_frames = @min(audio.fade_in_frames, frame_count);
    const fade_out_frames = @min(audio.fade_out_frames, frame_count);
    for (0..frame_count) |i| {
        const out = rendered[i * channels ..][0..channels];
        const offset: u64 = @intFromFloat(@as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(source.sample_rate)) / @as(f64, @floatFromInt(app.session.project.sample_rate)) / stretch_ratio);
        const source_frame = ws.arrangement.audioSourceFrame(audio.source_start_frame, audio.source_length_frames, offset, audio.reverse) orelse {
            @memset(out, 0);
            continue;
        };
        if (source_frame >= source_frames) {
            @memset(out, 0);
            continue;
        }
        const fade_in = if (fade_in_frames > 0) ws.arrangement.fadeGain(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fade_in_frames)), audio.fade_curve) else 1.0;
        const remaining = frame_count - i - 1;
        const fade_out = if (fade_out_frames > 0) ws.arrangement.fadeGain(@as(f32, @floatFromInt(remaining)) / @as(f32, @floatFromInt(fade_out_frames)), audio.fade_curve) else 1.0;
        const frame_gain = gain * @min(fade_in, fade_out);
        const source_index: usize = @intCast(source_frame * channels);
        for (out, 0..) |*sample, channel| sample.* = source.samples[source_index + channel] * frame_gain;
    }
    const source_id = app.session.project.addAudioSource("consolidated", app.session.project.sample_rate, channels, rendered) catch {
        app.setStatus("consolidate: failed to create source", .{});
        return;
    };
    history.recordLane(app, @intCast(app.cursor));
    // The fresh region has no alternate takes, so say how many the bake
    // replaced - saving no longer keeps their audio around either.
    const dropped_takes = audio.takeCount() - 1;
    clip.content.audio = .{ .source_id = source_id, .source_start_frame = 0, .source_length_frames = @intCast(frame_count) };
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    if (dropped_takes > 0)
        app.setStatus("consolidated audio region, dropping {d} alternate take(s)", .{dropped_takes})
    else
        app.setStatus("consolidated audio region", .{});
}

const AudioConversion = struct { track: u16, clip: *ws.Clip };

fn audioConversionClip(app: *App, name: []const u8) ?AudioConversion {
    if (app.view == .audio_editor) {
        const lane = app.session.arrangement.lane(app.audio_track) orelse return null;
        if (lane.clips.items.len == 0) {
            app.setStatus("{s}: no audio clip selected", .{name});
            return null;
        }
        app.audio_clip = @min(app.audio_clip, lane.clips.items.len - 1);
        return .{ .track = app.audio_track, .clip = &lane.clips.items[app.audio_clip] };
    }
    return .{ .track = @intCast(app.cursor), .clip = clipAtCursor(app, name) orelse return null };
}

fn audioToInstrument(app: *App, kind: ws.InstrumentKind, name: []const u8) void {
    const selected = audioConversionClip(app, name) orelse return;
    const clip = selected.clip;
    const audio = switch (clip.content) {
        .audio => |region| region,
        else => {
            app.setStatus("{s}: clip is not audio", .{name});
            return;
        },
    };
    const source = app.session.project.audioSource(audio.source_id) orelse {
        app.setStatus("{s}: missing audio source", .{name});
        return;
    };
    const channels = source.channel_count;
    const frame_count = audioFrameCount(ws.time_grid.tickToBeat(clip.length_ticks) * app.session.engine.transport.framesPerBeat(), channels) orelse {
        app.setStatus("{s}: output is too large; shorten the clip", .{name});
        return;
    };
    const samples = app.allocator.alloc(f32, frame_count) catch {
        app.setStatus("{s}: out of memory", .{name});
        return;
    };
    const source_frames = source.samples.len / channels;
    const gain = ws.types.dbToGain(std.math.clamp(audio.gain_db, -60.0, 24.0));
    const stretch_ratio = std.math.clamp(audio.stretch_ratio, 0.125, 8.0);
    const fade_in_frames = @min(audio.fade_in_frames, frame_count);
    const fade_out_frames = @min(audio.fade_out_frames, frame_count);
    for (samples, 0..) |*sample, i| {
        const offset: u64 = @intFromFloat(@as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(source.sample_rate)) / @as(f64, @floatFromInt(app.session.project.sample_rate)) / stretch_ratio);
        const source_frame = ws.arrangement.audioSourceFrame(audio.source_start_frame, audio.source_length_frames, offset, audio.reverse) orelse {
            sample.* = 0;
            continue;
        };
        if (source_frame >= source_frames) {
            sample.* = 0;
            continue;
        }
        const fade_in = if (fade_in_frames > 0) ws.arrangement.fadeGain(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fade_in_frames)), audio.fade_curve) else 1.0;
        const remaining = frame_count - i - 1;
        const fade_out = if (fade_out_frames > 0) ws.arrangement.fadeGain(@as(f32, @floatFromInt(remaining)) / @as(f32, @floatFromInt(fade_out_frames)), audio.fade_curve) else 1.0;
        const source_index: usize = @intCast(source_frame * channels);
        var mono: f32 = 0;
        for (source.samples[source_index..][0..channels]) |channel| mono += channel;
        sample.* = mono / @as(f32, @floatFromInt(channels)) * gain * @min(fade_in, fade_out);
    }

    var backup = history.captureTrackKindSwap(app, selected.track);
    _ = app.session.changeInstrumentKind(selected.track, kind) catch |err| {
        if (backup) |*b| b.deinit(app.allocator);
        app.allocator.free(samples);
        app.setStatus("{s}: {s}", .{ name, @errorName(err) });
        return;
    };
    history.push(app, backup);
    const stem = std.fs.path.stem(source.path);
    switch (kind) {
        .sampler => {
            const sampler = &app.session.racks.items[selected.track].instrument.sampler;
            sampler.setSamples(samples, stem);
            sampler.pad.user_sample = true;
            _ = sampler.detectRootNote();
        },
        .slicer => app.session.racks.items[selected.track].instrument.slicer.setSamples(samples, stem),
        else => unreachable,
    }
    app.cursor = selected.track;
    app.exitStaleEditors();
    app.dirty = true;
    app.setStatus("track {d}: audio clip loaded into {s}", .{ selected.track + 1, @tagName(kind) });
}

pub fn cmdAudioToSampler(app: *App, _: []const u8) void {
    audioToInstrument(app, .sampler, "audio-to-sampler");
}

pub fn cmdAudioToSlicer(app: *App, _: []const u8) void {
    audioToInstrument(app, .slicer, "audio-to-slicer");
}

pub fn cmdResample(app: *App, args: []const u8) void {
    if (app.cursor >= app.session.racks.items.len or app.session.racks.items[app.cursor].instrument != .audio) {
        app.setStatus("resample: select an Audio track first", .{});
        return;
    }
    const arg = std.mem.trim(u8, args, " ");
    const source: ws.engine.ResampleSource = if (std.mem.eql(u8, arg, "off"))
        .off
    else if (std.mem.eql(u8, arg, "master"))
        .master
    else if (std.mem.startsWith(u8, arg, "track:")) blk: {
        const n = std.fmt.parseInt(u16, arg[6..], 10) catch {
            app.setStatus("resample: expected track:<n>, group:<n>, master, or off", .{});
            return;
        };
        if (n == 0 or n > app.session.racks.items.len or n - 1 == app.cursor) {
            app.setStatus("resample: source must be another track (1-{d})", .{app.session.racks.items.len});
            return;
        }
        break :blk .{ .track = n - 1 };
    } else if (std.mem.startsWith(u8, arg, "group:")) blk: {
        const n = std.fmt.parseInt(u8, arg[6..], 10) catch {
            app.setStatus("resample: expected track:<n>, group:<n>, master, or off", .{});
            return;
        };
        if (n == 0 or n > ws.engine.max_groups or app.session.groups[n - 1] == null) {
            app.setStatus("resample: group {d} does not exist", .{n});
            return;
        }
        break :blk .{ .group = n - 1 };
    } else {
        app.setStatus("usage: resample <track:n|group:n|master|off>", .{});
        return;
    };
    app.resample_source = source;
    app.setStatus("resample input: {s}", .{arg});
}

pub fn cmdTake(app: *App, args: []const u8) void {
    const clip = clipAtCursor(app, "take") orelse return;
    const arg = std.mem.trim(u8, args, " ");
    const delta: i32 = if (arg.len == 0 or std.mem.eql(u8, arg, "next"))
        1
    else if (std.mem.eql(u8, arg, "prev"))
        -1
    else {
        app.setStatus("take: expected next or prev", .{});
        return;
    };
    const take_count = switch (clip.content) {
        .audio => |audio| audio.takeCount(),
        else => 0,
    };
    if (take_count <= 1) {
        app.setStatus("take: clip has no alternate takes", .{});
        return;
    }
    history.recordLane(app, @intCast(app.cursor));
    std.debug.assert(clip.cycleAudioTake(delta));
    // Takes carry their own length, so cycling can grow the clip - reseat it
    // so a longer take evicts what it now covers instead of overlapping it.
    if (app.session.arrangement.lane(app.cursor)) |lane| {
        const cursor_tick = app.arr_cursor_bar *| app.arr_grid.ticks();
        if (lane.clipIndexAt(cursor_tick)) |idx| lane.reseat(app.allocator, idx) catch {
            app.setStatus("take: out of memory", .{});
            return;
        };
    }
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("take: cycled {s} ({d} total)", .{ if (delta > 0) "next" else "previous", take_count });
}

pub fn cmdComp(app: *App, args: []const u8) void {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const take_number = std.fmt.parseInt(usize, words.next() orelse "", 10) catch {
        app.setStatus("comp: expected <take> <start-beat> <end-beat>", .{});
        return;
    };
    const start_beat = parseFiniteFloat(f64, words.next() orelse "") catch {
        app.setStatus("comp: expected <take> <start-beat> <end-beat>", .{});
        return;
    };
    const end_beat = parseFiniteFloat(f64, words.next() orelse "") catch {
        app.setStatus("comp: expected <take> <start-beat> <end-beat>", .{});
        return;
    };
    if (words.next() != null or take_number < 2 or start_beat < 0 or end_beat <= start_beat) {
        app.setStatus("comp: expected alternate take and increasing beat range", .{});
        return;
    }
    const clip = clipAtCursor(app, "comp") orelse return;
    const audio = switch (clip.content) {
        .audio => |region| region,
        else => {
            app.setStatus("comp: clip is not audio", .{});
            return;
        },
    };
    const alternate_index = take_number - 2;
    if (alternate_index >= audio.alternate_takes.len or audio.alternate_takes[alternate_index] == null) {
        app.setStatus("comp: no such alternate take", .{});
        return;
    }
    const alternate = audio.alternate_takes[alternate_index].?;
    const active_source = app.session.project.audioSource(audio.source_id) orelse {
        app.setStatus("comp: missing audio source", .{});
        return;
    };
    const alternate_source = app.session.project.audioSource(alternate.source_id) orelse {
        app.setStatus("comp: missing audio source for that take", .{});
        return;
    };
    const project_rate = app.session.project.sample_rate;
    const channels = @max(active_source.channel_count, alternate_source.channel_count);
    const output_frames = compFrameCount(audio.source_length_frames, active_source.sample_rate, project_rate, channels) orelse {
        app.setStatus("comp: output is too large; shorten the clip", .{});
        return;
    };
    const result = app.allocator.alloc(f32, output_frames * @as(usize, channels)) catch {
        app.setStatus("comp: out of memory", .{});
        return;
    };
    defer app.allocator.free(result);
    const frames_per_beat = app.session.engine.transport.framesPerBeat();
    const range_start = beatFrameBound(start_beat, frames_per_beat, output_frames);
    const range_end = beatFrameBound(end_beat, frames_per_beat, output_frames);
    if (range_end <= range_start) {
        app.setStatus("comp: range falls outside clip", .{});
        return;
    }
    for (0..output_frames) |frame| {
        const out = result[frame * channels ..][0..channels];
        const use_alternate = frame >= range_start and frame < range_end;
        const source = if (use_alternate) alternate_source else active_source;
        const start = if (use_alternate) alternate.source_start_frame else audio.source_start_frame;
        const length = if (use_alternate) alternate.source_length_frames else audio.source_length_frames;
        const source_offset: u64 = @intFromFloat(@as(f64, @floatFromInt(frame)) * @as(f64, @floatFromInt(source.sample_rate)) / @as(f64, @floatFromInt(project_rate)));
        const source_frame = ws.arrangement.audioSourceFrame(start, length, source_offset, false) orelse {
            @memset(out, 0);
            continue;
        };
        if (source_frame >= source.samples.len / source.channel_count) {
            @memset(out, 0);
            continue;
        }
        const base: usize = @intCast(source_frame * source.channel_count);
        // A mono take spliced against a stereo one feeds both output channels.
        for (out, 0..) |*sample, channel| sample.* = source.samples[base + @min(channel, source.channel_count - 1)];
    }
    const source_id = app.session.project.addAudioSource("comp", project_rate, channels, result) catch {
        app.setStatus("comp: failed to create source", .{});
        return;
    };
    history.recordLane(app, @intCast(app.cursor));
    clip.content.audio.source_id = source_id;
    clip.content.audio.source_start_frame = 0;
    clip.content.audio.source_length_frames = output_frames;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("comp: take {d}, beats {d:.2}-{d:.2}", .{ take_number, start_beat, end_beat });
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

pub fn cmdAutomationMode(app: *App, args: []const u8) void {
    const text = std.mem.trim(u8, args, " ");
    if (text.len == 0) {
        app.setStatus("automation mode: {s}", .{@tagName(app.session.automation_record_mode)});
        return;
    }
    app.session.automation_record_mode = std.meta.stringToEnum(ws.dsp.automation.RecordMode, text) orelse {
        app.setStatus("automation-mode: expected off, write, touch, or latch", .{});
        return;
    };
    app.setStatus("automation mode: {s}", .{text});
}

pub fn cmdAutomationPoint(app: *App, args: []const u8) void {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const target_text = words.next() orelse {
        app.setStatus("automation-point: expected target, beat, and dB", .{});
        return;
    };
    const beat = parseFiniteFloat(f64, words.next() orelse "") catch {
        app.setStatus("automation-point: beat must be non-negative", .{});
        return;
    };
    const db = parseFiniteFloat(f32, words.next() orelse "") catch {
        app.setStatus("automation-point: dB must be -60 to 12", .{});
        return;
    };
    if (beat < 0 or db < -60 or db > 12) {
        app.setStatus("automation-point: beat must be non-negative; dB must be -60 to 12", .{});
        return;
    }
    const curve = if (words.next()) |name| std.meta.stringToEnum(ws.dsp.automation.Curve, name) orelse {
        app.setStatus("automation-point: curve must be linear, hold, or ease", .{});
        return;
    } else .linear;
    if (words.next() != null) {
        app.setStatus("automation-point: too many arguments", .{});
        return;
    }
    const target: ws.dsp.automation.MixTarget = parseMixTarget(app, target_text) orelse return;
    app.session.setMixAutomationPoint(target, .{ .beat = beat, .value = db, .curve = curve }) catch {
        app.setStatus("automation-point: out of memory", .{});
        return;
    };
    app.dirty = true;
    app.setStatus("automation point: {s} beat {d:.2}, {d:.1}dB", .{ target_text, beat, db });
}

fn parseMixTarget(app: *App, text: []const u8) ?ws.dsp.automation.MixTarget {
    if (std.mem.eql(u8, text, "master")) return .master_gain;
    if (std.mem.startsWith(u8, text, "group:")) {
        const group = std.fmt.parseInt(u8, text[6..], 10) catch 0;
        if (group > 0 and group <= engine_mod.max_groups and app.session.groups[group - 1] != null) return .{ .group_gain = group - 1 };
    } else if (std.mem.startsWith(u8, text, "send:")) {
        var fields = std.mem.splitScalar(u8, text[5..], ':');
        const track = std.fmt.parseInt(u16, fields.next() orelse "", 10) catch 0;
        const slot = std.fmt.parseInt(u8, fields.next() orelse "", 10) catch 0;
        if (fields.next() == null and track > 0 and track <= app.session.project.tracks.items.len and slot > 0 and slot <= ws.max_sends_per_track)
            return .{ .send_level = .{ .track = track - 1, .slot = slot - 1 } };
    }
    app.setStatus("automation-point: target must be master, group:n, or send:track:slot", .{});
    return null;
}

test "audio edit frame bounds reject oversized clips and beats" {
    try std.testing.expectEqual(@as(?usize, 96_000), compFrameCount(48_000, 24_000, 48_000, 2));
    try std.testing.expectEqual(null, compFrameCount(std.math.maxInt(u64), 1, 192_000, 2));
    try std.testing.expectEqual(@as(usize, 48_000), beatFrameBound(1.0, 48_000, 96_000));
    try std.testing.expectEqual(@as(usize, 96_000), beatFrameBound(1e308, 48_000, 96_000));
    try std.testing.expectEqual(@as(?usize, 48_000), audioFrameCount(48_000, 2));
    try std.testing.expectEqual(null, audioFrameCount(1e308, 2));
}

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
const history = @import("history.zig");
const piano_ed = @import("editors/piano.zig");
const spectrum_ed = @import("editors/spectrum.zig");
const theory = ws.theory;

fn wrap(comptime f: fn (*App, []const u8) void) *const fn (*anyopaque, []const u8) void {
    return struct {
        fn call(ctx: *anyopaque, args: []const u8) void {
            f(@ptrCast(@alignCast(ctx)), args);
        }
    }.call;
}

/// Big enough for any real filesystem path; see `expandHome`.
const path_buf_len: usize = 1024;

/// Expand a leading `~` — the shell does this for CLI args, but paths typed
/// into the `:` prompt never pass through a shell. Handles bare `~` and
/// `~/rest`; `~otheruser` is left alone (not worth the /etc/passwd lookup for
/// a single-user TUI). Returns `path` unchanged when there's nothing to
/// expand, when $HOME isn't set, or when the expansion wouldn't fit `buf`.
fn expandHome(buf: []u8, path: []const u8) []const u8 {
    if (path.len == 0 or path[0] != '~') return path;
    if (path.len > 1 and path[1] != '/') return path;
    const home = std.c.getenv("HOME") orelse return path;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ std.mem.sliceTo(home, 0), path[1..] }) catch path;
}

pub const cmds: []const cmd_mod.Def = &.{
    .{ .name = "q",           .desc = "quit (refuses if unsaved changes)",   .run = wrap(cmdQuit) },
    .{ .name = "q!",          .desc = "quit, discarding unsaved changes",    .run = wrap(cmdQuitForce) },
    .{ .name = "quit",        .desc = "quit (alias for :q)",                 .run = wrap(cmdQuit) },
    .{ .name = "qa",          .desc = "quit (alias for :q)",                 .run = wrap(cmdQuit) },
    .{ .name = "qa!",         .desc = "quit, discarding changes (alias for :q!)", .run = wrap(cmdQuitForce) },
    .{ .name = "bpm",         .desc = "[<value>]  tempo in BPM (20–400)",    .run = wrap(cmdBpm) },
    .{ .name = "sig",         .desc = "[<n>[/4]]  time signature (1–16 beats per bar)", .run = wrap(cmdSig) },
    .{ .name = "gain",        .desc = "<track> [<dB>]  track gain",          .run = wrap(cmdGain) },
    .{ .name = "pan",         .desc = "<track> [<-1..1>]  track pan",        .run = wrap(cmdPan) },
    .{ .name = "vol",         .desc = "[<dB>]  master volume (–40 to +6)",   .run = wrap(cmdVol) },
    .{ .name = "seek",        .desc = "<bar>  move playhead to bar",         .run = wrap(cmdSeek) },
    .{ .name = "load-pad",    .desc = "<0-7> [file]  load WAV into pad (omit the file to browse)",     .run = wrap(cmdLoadPad) },
    .{ .name = "load-sample", .desc = "[file]  load WAV into sampler track (omit the file to browse)",  .run = wrap(cmdLoadSample) },
    .{ .name = "e",           .desc = "[file]  open a project (refuses if unsaved changes; omit the file to browse)", .run = wrap(cmdEdit) },
    .{ .name = "e!",          .desc = "[file]  open a project, discarding changes; no file reverts the current one", .run = wrap(cmdEditForce) },
    .{ .name = "new",         .desc = "start a blank project (refuses if unsaved changes)", .run = wrap(cmdNew) },
    .{ .name = "new!",        .desc = "start a blank project, discarding unsaved changes", .run = wrap(cmdNewForce) },
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
    .{ .name = "metronome",   .desc = "[on|off]  toggle the click track",                   .run = wrap(cmdMetronome) },
    .{ .name = "scale",       .desc = "[<root> [<type>]|off]  piano-roll scale highlight + chord-stamp key", .run = wrap(cmdScale) },
    .{ .name = "master-eq",   .desc = "[<band> <db>]  master bus EQ (see M in the tracks view)", .run = wrap(cmdMasterEq) },
    .{ .name = "master-comp", .desc = "[on|off|thresh|ratio|attack|release|makeup <value>]  master bus compressor", .run = wrap(cmdMasterComp) },
    .{ .name = "synth-preset", .desc = "[name]  apply a factory synth patch to the cursor track (no args: list names)", .run = wrap(cmdSynthPreset) },
    .{ .name = "drum-kit",    .desc = "[name]  regenerate the cursor drum machine's pads from a kit variant (no args: list names)", .run = wrap(cmdDrumKit) },
};

/// Look up `text` in the command table and run it, reporting unknown commands
/// in the status line.
pub fn run(app: *App, text: []const u8) void {
    if (!cmd_mod.dispatch(cmds, app, text)) {
        app.setStatus("not a command: {s}  (try :help)", .{text});
    }
}

/// Vim-style quit guard: refuse while the session holds edits the project
/// file doesn't (`App.dirty`). :q! / :qa! force, ctrl-c always exits.
fn cmdQuit(app: *App, _: []const u8) void {
    if (app.dirty) {
        app.setStatus("unsaved changes — :w to save, :q! to discard", .{});
        return;
    }
    app.should_quit = true;
}

fn cmdQuitForce(app: *App, _: []const u8) void { app.should_quit = true; }

fn cmdEdit(app: *App, args: []const u8) void { editOrRevert(app, args, false); }
fn cmdEditForce(app: *App, args: []const u8) void { editOrRevert(app, args, true); }

/// `:e <file>` swaps in a different project (refusing on unsaved changes,
/// like `:q`). `:e!` forces it; `:e!` alone (no path) reverts the current
/// project to its last-saved state, vim's plain-`:e!` convention. The actual
/// swap happens in `run()` — see `App.requestReload`.
fn editOrRevert(app: *App, args: []const u8, force: bool) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (!force and app.dirty) {
        app.setStatus("unsaved changes — :w to save, :e! to discard", .{});
        return;
    }
    if (trimmed.len == 0 and !force) {
        app.openBrowser(.open_project);
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    const path: []const u8 = if (trimmed.len > 0)
        expandHome(&path_buf, trimmed)
    else
        app.projectPath() orelse {
            app.setStatus("e!: no project loaded yet — :e! needs a path", .{});
            return;
        };
    app.requestReload(path);
}

fn cmdNew(app: *App, _: []const u8) void { newOrForce(app, false); }
fn cmdNewForce(app: *App, _: []const u8) void { newOrForce(app, true); }

/// `:new` starts a blank session (refusing on unsaved changes); `:new!` forces
/// it. Same reload path as `:e` — see `App.requestReload`.
fn newOrForce(app: *App, force: bool) void {
    if (!force and app.dirty) {
        app.setStatus("unsaved changes — :w to save, :new! to discard", .{});
        return;
    }
    app.requestReload(null);
}

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
    history.recordMelodic(app, @intCast(track));
    pp.clearNotes();
    app.setStatus("cleared {d} notes", .{n});
    piano_ed.syncLinkedClip(app);
}

pub fn cmdHelp(app: *App, _: []const u8) void {
    app.prev_view = app.view;
    app.help_scroll = 0;
    app.view = .help;
}

fn cmdMetronome(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const on = if (std.mem.eql(u8, trimmed, "on"))
        true
    else if (std.mem.eql(u8, trimmed, "off"))
        false
    else
        !app.session.metronome_enabled;
    app.session.setMetronome(on);
    app.setStatus("metronome {s}", .{if (on) "on" else "off"});
}

/// `:scale [<root> [<type>]|off]` — sets or clears the piano roll's active
/// scale (see `App.piano_scale`). With no args, reports the current setting.
/// `<type>` alone (root omitted) keeps the existing root, defaulting to C.
fn cmdScale(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        if (app.piano_scale) |s|
            app.setStatus("scale: {s} {s}", .{ theory.pitchClassName(s.root), s.kind.label() })
        else
            app.setStatus("scale: off", .{});
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
        app.piano_scale = null;
        app.setStatus("scale: off", .{});
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const first = it.next().?;
    const rest = std.mem.trim(u8, it.rest(), " ");
    // A bare type name (e.g. `:scale dorian`) keeps the existing root.
    var root: u4 = if (app.piano_scale) |s| s.root else 0;
    var type_str: []const u8 = first;
    if (theory.ScaleType.parse(first) == null) {
        root = theory.parsePitchClass(first) orelse {
            app.setStatus("scale: unknown root or type '{s}'", .{first});
            return;
        };
        type_str = rest;
    }
    const kind: theory.ScaleType = if (type_str.len > 0)
        theory.ScaleType.parse(type_str) orelse {
            app.setStatus("scale: unknown type '{s}' (try major/minor/dorian/…)", .{type_str});
            return;
        }
    else if (app.piano_scale) |s|
        s.kind
    else
        .major;
    app.piano_scale = .{ .root = root, .kind = kind };
    app.setStatus("scale: {s} {s}", .{ theory.pitchClassName(root), kind.label() });
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
    app.dirty = true;
    app.setStatus("track {d} renamed to \"{s}\"", .{ n, name });
}

fn cmdLoadPad(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, args, ' ');
    const pad_str = it.next() orelse {
        app.setStatus("usage: load-pad <0-7> [file.wav]  (omit the file to browse)", .{});
        return;
    };
    const pad_idx = std.fmt.parseInt(u8, pad_str, 10) catch {
        app.setStatus("load-pad: bad pad index '{s}'", .{pad_str});
        return;
    };
    if (pad_idx >= DrumMachine.max_pads) {
        app.setStatus("load-pad: pad index must be 0-7", .{});
        return;
    }
    const rest = std.mem.trim(u8, it.rest(), " ");
    if (rest.len == 0) {
        if (cursorDrumMachine(app) == null) {
            app.setStatus("load-pad: select a drum-machine track first", .{});
            return;
        }
        app.openBrowser(.{ .load_pad = pad_idx });
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    loadPadFromPath(app, pad_idx, expandHome(&path_buf, rest));
}

/// Shared by `:load-pad <n> <file>` and the file browser's pad-load purpose
/// (the browser hands over an already-resolved path — no `~` to expand).
pub fn loadPadFromPath(app: *App, pad_idx: u8, path: []const u8) void {
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
    if (dm.pads[pad_idx]) |*p| p.user_sample = true;
    app.dirty = true;
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

/// The PolySynth on the cursor's track, or null.
fn cursorSynth(app: *App) ?*ws.dsp.PolySynth {
    if (app.cursor >= app.session.racks.items.len) return null;
    return switch (app.session.racks.items[app.cursor].instrument) {
        .poly_synth => |*s| s, else => null,
    };
}

/// `:synth-preset [name]` — apply a factory patch (see `dsp/synth_presets.zig`)
/// to the cursor track's synth. No args, or an unknown name, lists the
/// available preset names instead of guessing.
fn cmdSynthPreset(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (ws.dsp.synth_presets.presets, 0..) |p, i| {
            if (i > 0) w.writeAll(", ") catch break;
            w.writeAll(p.name) catch break;
        }
        app.setStatus("synth presets: {s}", .{w.buffered()});
        return;
    }
    const patch = ws.dsp.synth_presets.find(trimmed) orelse {
        app.setStatus("synth-preset: unknown '{s}' — :synth-preset lists names", .{trimmed});
        return;
    };
    const s = cursorSynth(app) orelse {
        app.setStatus("synth-preset: select a synth track first", .{});
        return;
    };
    s.applyPatch(patch);
    app.dirty = true;
    app.setStatus("synth preset: {s}", .{trimmed});
}

/// `:drum-kit [name]` — regenerate all 8 pads of the cursor track's drum
/// machine from a procedural kit variant (see `dsp/drum_kit.zig`'s
/// `variants` table). No args, or an unknown name, lists the available kit
/// names. Overwrites any user-loaded pad samples on that track.
fn cmdDrumKit(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (ws.dsp.drum_kit.variants, 0..) |v, i| {
            if (i > 0) w.writeAll(", ") catch break;
            w.writeAll(v.name) catch break;
        }
        app.setStatus("drum kits: {s}", .{w.buffered()});
        return;
    }
    const variant = for (&ws.dsp.drum_kit.variants) |*v| {
        if (std.ascii.eqlIgnoreCase(v.name, trimmed)) break v;
    } else {
        app.setStatus("drum-kit: unknown '{s}' — :drum-kit lists names", .{trimmed});
        return;
    };
    const dm = cursorDrumMachine(app) orelse {
        app.setStatus("drum-kit: select a drum-machine track first", .{});
        return;
    };
    dm.loadKitVariant(variant) catch |e| {
        app.setStatus("drum-kit: {s}", .{@errorName(e)});
        return;
    };
    app.dirty = true;
    app.setStatus("drum kit: {s}", .{trimmed});
}

fn cmdLoadSample(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        if (cursorSampler(app) == null) {
            app.setStatus("load-sample: select a sampler track first", .{});
            return;
        }
        app.openBrowser(.load_sample);
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    loadSampleFromPath(app, expandHome(&path_buf, trimmed));
}

/// Shared by `:load-sample <file>` and the file browser's sample-load
/// purpose (the browser hands over an already-resolved path — no `~` to
/// expand).
pub fn loadSampleFromPath(app: *App, path: []const u8) void {
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
    s.pad.user_sample = true;
    app.dirty = true;
    app.setStatus("sample loaded: {s}", .{stem});
}

/// Explicit :save argument (with `~` expanded), else the file the session
/// was loaded from / last saved to (already resolved — see `setProjectPath`),
/// else "project.wsj".
fn savePath(app: *App, args: []const u8, buf: []u8) []const u8 {
    const arg = std.mem.trim(u8, args, " ");
    if (arg.len > 0) return expandHome(buf, arg);
    return app.projectPath() orelse "project.wsj";
}

fn cmdSave(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const path = savePath(app, args, &path_buf);
    ws.persist.save(app.allocator, &app.session, app.io, path) catch |e| {
        app.setStatus("save: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    app.setProjectPath(path);
    app.dirty = false;
    app.setStatus("saved: {s}", .{path});
}

/// Vim-style write-and-quit: save the project, then exit. Only quits when
/// the save succeeds so a failed write leaves the session intact.
fn cmdWriteQuit(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const path = savePath(app, args, &path_buf);
    ws.persist.save(app.allocator, &app.session, app.io, path) catch |e| {
        app.setStatus("save: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    app.setProjectPath(path);
    app.dirty = false;
    app.should_quit = true;
}

/// Render the live session (patterns + synth params + drum grid) offline to
/// a 16-bit PCM WAV. Length = the longest loop plus a 2s tail for reverb and
/// release. The realtime backend is parked for the duration so the UI thread
/// can drive the engine without racing the audio thread.
fn cmdBounce(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const trimmed = std.mem.trim(u8, args, " ");
    const path = if (trimmed.len > 0) expandHome(&path_buf, trimmed) else "bounce.wav";

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
    // An armed A/B loop would render the region forever; bounce the song.
    const was_looping = engine.transport.loop_enabled;
    engine.transport.loop_enabled = false;

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
    engine.transport.loop_enabled = was_looping;
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
    // The loop region is stored in bars; its frame mirror just moved.
    app.session.syncLoop();
    app.dirty = true;
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
    // Bar boundaries moved; refit the song timeline if it's driving playback,
    // and re-derive the loop region's frame mirror.
    if (app.session.song_mode) app.session.rebuildSongData();
    app.session.syncLoop();
    app.dirty = true;
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
    app.dirty = true;
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
    app.dirty = true;
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
    spectrum_ed.setEqBand(app, @intCast(track_idx), band, db);
    app.setStatus("track {d} eq band {d}: {d:.1}dB", .{ track_1, band, db });
}

/// `:master-eq [<band> <db>]` — same shape as `:eq` but for the master bus
/// (no track index). The interactive editor is `M` in the tracks view.
fn cmdMasterEq(app: *App, args: []const u8) void {
    const rest = std.mem.trim(u8, args, " ");
    if (rest.len == 0) {
        if (app.session.master_fx.eq) |*eq| {
            app.setStatus("master eq: bypass={}", .{eq.bypass});
        } else {
            app.setStatus("master: no EQ", .{});
        }
        return;
    }
    var it = std.mem.splitScalar(u8, rest, ' ');
    const band_str = it.next() orelse {
        app.setStatus("usage: master-eq <band> <db>", .{});
        return;
    };
    const band = std.fmt.parseInt(usize, band_str, 10) catch {
        app.setStatus("master-eq: bad band number", .{});
        return;
    };
    if (band >= eq_mod.num_eq_bands) {
        app.setStatus("master-eq: band must be 0–{d}", .{eq_mod.num_eq_bands - 1});
        return;
    }
    const db = std.fmt.parseFloat(f32, it.rest()) catch {
        app.setStatus("master-eq: expected dB value", .{});
        return;
    };
    spectrum_ed.setMasterEqBand(app, band, db);
    app.setStatus("master eq band {d}: {d:.1}dB", .{ band, db });
}

/// `:master-comp [on|off|<param> <value>]` — the master bus compressor.
/// `on` adds it with its defaults if not already present; `off` removes it;
/// `thresh`/`ratio`/`attack`/`release`/`makeup <value>` tweak one field,
/// creating the compressor with defaults first if needed. No args reports
/// the current settings.
fn cmdMasterComp(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        if (app.session.master_fx.comp) |c| {
            app.setStatus("master comp: thresh {d:.1}dB  ratio {d:.1}:1  atk {d:.0}ms  rel {d:.0}ms  makeup {d:.1}dB", .{
                c.threshold_db, c.ratio, c.attack_ms, c.release_ms, c.makeup_db,
            });
        } else {
            app.setStatus("master comp: off", .{});
        }
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
        app.session.master_fx.comp = null;
        app.dirty = true;
        app.session.syncMasterChain();
        app.setStatus("master comp: off", .{});
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const first = it.next().?;
    if (std.ascii.eqlIgnoreCase(first, "on")) {
        app.session.master_fx.comp = ws.dsp.Compressor.init(app.session.project.sample_rate);
        app.dirty = true;
        app.session.syncMasterChain();
        app.setStatus("master comp: on (defaults)", .{});
        return;
    }
    const val_str = std.mem.trim(u8, it.rest(), " ");
    const val = std.fmt.parseFloat(f32, val_str) catch {
        app.setStatus("usage: master-comp on|off|thresh|ratio|attack|release|makeup <value>", .{});
        return;
    };
    if (app.session.master_fx.comp == null)
        app.session.master_fx.comp = ws.dsp.Compressor.init(app.session.project.sample_rate);
    const c = &app.session.master_fx.comp.?;
    if (std.ascii.eqlIgnoreCase(first, "thresh")) {
        c.threshold_db = std.math.clamp(val, -60.0, 0.0);
    } else if (std.ascii.eqlIgnoreCase(first, "ratio")) {
        c.ratio = std.math.clamp(val, 1.0, 20.0);
    } else if (std.ascii.eqlIgnoreCase(first, "attack")) {
        c.attack_ms = std.math.clamp(val, 0.1, 500.0);
    } else if (std.ascii.eqlIgnoreCase(first, "release")) {
        c.release_ms = std.math.clamp(val, 1.0, 2000.0);
    } else if (std.ascii.eqlIgnoreCase(first, "makeup")) {
        c.makeup_db = std.math.clamp(val, -24.0, 24.0);
    } else {
        app.setStatus("master-comp: unknown param '{s}' (thresh/ratio/attack/release/makeup)", .{first});
        return;
    }
    app.dirty = true;
    app.session.syncMasterChain();
    app.setStatus("master comp: {s} {d:.2}", .{ first, val });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "expandHome expands ~ and ~/rest via $HOME; leaves other forms alone" {
    const testing = std.testing;
    const home_c = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.sliceTo(home_c, 0);

    var buf: [path_buf_len]u8 = undefined;
    try testing.expectEqualStrings(home, expandHome(&buf, "~"));

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/song.wsj", .{home});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, expandHome(&buf, "~/song.wsj"));

    // Another user's home, and paths without a leading ~, pass through.
    try testing.expectEqualStrings("~otheruser/x", expandHome(&buf, "~otheruser/x"));
    try testing.expectEqualStrings("relative/path.wav", expandHome(&buf, "relative/path.wav"));
    try testing.expectEqualStrings("/abs/path.wav", expandHome(&buf, "/abs/path.wav"));
    try testing.expectEqualStrings("", expandHome(&buf, ""));

    // A buffer too small to hold the expansion falls back to the original.
    var tiny: [1]u8 = undefined;
    try testing.expectEqualStrings("~/song.wsj", expandHome(&tiny, "~/song.wsj"));
}

test ":save reports the expanded path, not the literal ~, on failure" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    const home_c = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.sliceTo(home_c, 0);

    // A directory that doesn't exist under $HOME — save fails, but the
    // status must show where it actually tried to write.
    var cmd_buf: [80]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":save ~/__wstudio_missing__/p.wsj", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, home) != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "~") == null);
}

test ":synth-preset applies a factory patch to the cursor track's synth" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .poly_synth);

    var cmd_buf: [80]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":synth-preset acid-bass", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    const s = &app.session.racks.items[0].instrument.poly_synth;
    const expected = ws.dsp.synth_presets.find("acid-bass").?;
    try std.testing.expectEqual(expected.voice_mode, s.voice_mode);
    try std.testing.expectApproxEqAbs(expected.filter_res, s.filter_res, 1e-6);
    try std.testing.expect(app.dirty);
}

test ":synth-preset with no args lists names without touching the synth" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .poly_synth);

    var cmd_buf: [40]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":synth-preset", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "init") != null);
    try std.testing.expect(!app.dirty);
}

test ":drum-kit regenerates the cursor drum machine's pads" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .drum_machine);

    var cmd_buf: [40]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":drum-kit analog", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    const dm = &app.session.racks.items[0].instrument.drum_machine;
    try std.testing.expect(dm.pads[0] != null);
    try std.testing.expect(!dm.pads[0].?.user_sample);
    try std.testing.expect(app.dirty);
    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "analog") != null);
}

test ":load-pad reports the expanded path on a missing file" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .drum_machine);
    const home_c = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.sliceTo(home_c, 0);

    var cmd_buf: [80]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":load-pad 0 ~/__wstudio_missing__.wav", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, home) != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "~") == null);
}

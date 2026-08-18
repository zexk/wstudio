//! Shared cursor/scope-resolution helpers used by command handlers across
//! several of commands.zig's split-out group files (pattern/tracks/load/
//! mixer) - kept in one place instead of duplicated per group, since e.g.
//! `cursorDrumMachine` alone is called from all four.

const std = @import("std");
const ws = @import("wstudio");
const DrumMachine = ws.dsp.DrumMachine;
const Slicer = ws.dsp.Slicer;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const pattern_mod = ws.dsp.pattern;
const history = @import("../history.zig");
const undo_mod = @import("../undo.zig");

/// The track a pattern-transform command (`:clear`, `:humanize`, `:reverse`,
/// `:vel-ramp`, `:quantize`, `:legato`, `:transpose`, `:strum`,
/// `:import-midi`, `:export-midi`) should act on: the piano roll's pattern
/// while it's open, otherwise the cursor track.
pub fn resolveTrack(app: *App) usize {
    return if (app.view == .piano_roll) app.piano_track else app.cursor;
}

/// The melodic pattern at `resolveTrack`, or null if that track isn't one -
/// e.g. the cursor's on a drum machine, or off the end of the track list.
/// Shared by every pattern-transform command above.
pub fn resolveMelodic(app: *App) ?struct { track: usize, pp: *pattern_mod.PatternPlayer } {
    const track = resolveTrack(app);
    if (app.view == .drum_grid or track >= app.session.racks.items.len) return null;
    if (app.session.racks.items[track].pattern_player == null) return null;
    return .{ .track = track, .pp = &app.session.racks.items[track].pattern_player.? };
}

/// The track index of the drum machine on the cursor's track, or - if the
/// drum grid is open - the one being edited. Null when neither is a drum
/// machine. The index (not just the `*DrumMachine`) is what undo snapshots
/// need, hence the split from `cursorDrumMachine`.
pub fn cursorDrumTrack(app: *App) ?u16 {
    if (app.cursor < app.session.racks.items.len) {
        switch (app.session.racks.items[app.cursor].instrument) {
            .drum_machine => return @intCast(app.cursor),
            else => {},
        }
    }
    if (app.view == .drum_grid and app.drum_track < app.session.racks.items.len) {
        switch (app.session.racks.items[app.drum_track].instrument) {
            .drum_machine => return @intCast(app.drum_track),
            else => {},
        }
    }
    return null;
}

/// The drum machine on the cursor's track, or - if the drum grid is open -
/// the one being edited. Null when neither is a drum machine.
pub fn cursorDrumMachine(app: *App) ?*DrumMachine {
    const track = cursorDrumTrack(app) orelse return null;
    return switch (app.session.racks.items[track].instrument) {
        .drum_machine => |*dm| dm,
        else => unreachable, // cursorDrumTrack only returns drum-machine tracks
    };
}

/// Either of the two step-sequenced instruments. They hold the identical
/// `[64][]?MidiNote` grid and carry the same lane-neutral pattern edits
/// (`clearGrid`, `euclidLane`, `rotateLane`, …), so a command that transforms
/// a pattern reaches both through one `inline else` rather than growing a
/// drum arm and a slicer arm.
pub const StepInstrument = union(enum) {
    drum: *DrumMachine,
    slicer: *Slicer,
};

/// The step grid a pattern-transform command should act on, with the track
/// index its undo snapshot needs and the lane its cursor sits on: the cursor
/// track, or - if one of the two grids is open - the instrument being edited.
/// Null when neither resolves to a step instrument.
pub fn cursorStepGrid(app: *App) ?struct { track: u16, lane: u8, inst: StepInstrument } {
    if (cursorDrumTrack(app)) |track| {
        return .{ .track = track, .lane = @intCast(app.drum_cursor[0]), .inst = .{ .drum = cursorDrumMachine(app).? } };
    }
    const track: u16 = blk: {
        if (app.cursor < app.session.racks.items.len and
            app.session.racks.items[app.cursor].instrument == .slicer) break :blk @intCast(app.cursor);
        if (app.view == .slicer_grid and app.slicer_track < app.session.racks.items.len and
            app.session.racks.items[app.slicer_track].instrument == .slicer) break :blk app.slicer_track;
        return null;
    };
    return .{
        .track = track,
        .lane = @intCast(app.slicer_cursor[0]),
        .inst = .{ .slicer = &app.session.racks.items[track].instrument.slicer },
    };
}

/// Snapshot whichever step instrument `cursorStepGrid` resolved, so the
/// transform that follows is undoable.
pub fn recordStepGrid(app: *App, g: anytype) void {
    switch (g.inst) {
        .drum => history.recordDrum(app, g.track),
        .slicer => history.recordSlicer(app, g.track),
    }
}

/// `recordStepGrid`'s deferred half, for a transform that may turn out to be
/// a no-op and shouldn't leave an undo entry behind when it does.
pub fn captureStepGrid(app: *App, g: anytype) ?undo_mod.Entry {
    return switch (g.inst) {
        .drum => history.captureDrum(app, g.track),
        .slicer => history.captureSlicer(app, g.track),
    };
}

/// The lane's display name, for the status line a transform prints.
pub fn laneName(g: anytype) []const u8 {
    return switch (g.inst) {
        .drum => |dm| dm.padName(g.lane),
        .slicer => |sl| sl.clipName(),
    };
}

/// Reads a `:load`-family source file, setting status and returning `null`
/// on failure. Shared by every `load*FromPath` handler below, plus
/// `:import-midi` and the browser's audition key, which is why the caller
/// names itself rather than every failure reading as `load:`.
pub fn readFileForLoad(app: *App, cmd: []const u8, path: []const u8) ?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(
        app.io,
        path,
        app.allocator,
        .limited(64 * 1024 * 1024),
    ) catch |e| {
        app.setStatus("{s}: cannot read '{s}': {s}", .{ cmd, path, @errorName(e) });
        return null;
    };
    // Every `:load`-family read lands here, so this is the one place that
    // has to remember where the browser reopens - see `App.last_load_dir`.
    app.noteLoadDir(path);
    return data;
}

/// The filename minus its extension, for status messages and clip naming.
pub fn stemOf(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    return if (std.mem.lastIndexOf(u8, basename, ".")) |dot| basename[0..dot] else basename;
}

/// Shared by `:load`'s drum-track branch and the file browser's
/// pad-load purpose (the browser hands over an already-resolved path - no
/// `~` to expand).
pub fn loadPadFromPath(app: *App, pad_idx: u8, path: []const u8) void {
    const data = readFileForLoad(app, "load", path) orelse return;
    defer app.allocator.free(data);
    const dm = cursorDrumMachine(app) orelse {
        app.setStatus("load: select a drum-machine track first", .{});
        return;
    };
    const stem = stemOf(path);
    dm.loadPadWav(pad_idx, data, stem) catch |e| {
        app.setStatus("load: parse error: {s}", .{@errorName(e)});
        return;
    };
    dm.pads[pad_idx].?.pad.user_sample = true; // loadPadWav above materialized it
    app.dirty = true;
    app.setStatus("pad {d} loaded: {s}", .{ pad_idx + 1, stem });
}

/// The file browser's visual-mode enter: load every file in the selected
/// range into consecutive drum pads, starting at the drum grid's cursor pad
/// and walking up. Always top-down in list order, whichever direction the
/// selection was extended. Directories inside the range are skipped, as is
/// any file that fails to decode - one bad WAV in a folder shouldn't cost
/// the other fifteen. `entries` are names relative to `app.browser_dir`.
pub fn loadPadsFromEntries(app: *App, entries: []const app_mod.BrowserEntry) void {
    const dm = cursorDrumMachine(app) orelse {
        app.setStatus("load: select a drum-machine track first", .{});
        return;
    };
    var pad: u8 = @intCast(app.drum_cursor[0]);
    var loaded: u16 = 0;
    var failed: u16 = 0;
    var no_room: u16 = 0;
    for (entries) |entry| {
        if (entry.is_dir) continue;
        if (pad >= DrumMachine.max_pads) {
            no_room += 1;
            continue;
        }
        const path = std.fs.path.join(app.allocator, &.{ app.browser_dir, entry.name }) catch continue;
        defer app.allocator.free(path);
        const data = readFileForLoad(app, "load", path) orelse {
            failed += 1;
            continue;
        };
        defer app.allocator.free(data);
        dm.loadPadWav(pad, data, stemOf(path)) catch {
            failed += 1;
            continue;
        };
        dm.pads[pad].?.pad.user_sample = true; // loadPadWav above materialized it
        pad += 1;
        loaded += 1;
    }
    if (loaded > 0) app.dirty = true;
    if (failed == 0 and no_room == 0) {
        app.setStatus("loaded {d} pads from {s}", .{ loaded, std.fs.path.basename(app.browser_dir) });
    } else {
        app.setStatus("loaded {d} pads from {s} ({d} failed, {d} past the last pad)", .{
            loaded,
            std.fs.path.basename(app.browser_dir),
            failed,
            no_room,
        });
    }
}

/// The track index of the slicer the command should act on: the cursor's
/// track, or - if the slicer grid (or one of its slices' params) is open -
/// the one being edited. Null when neither is a slicer. Mirrors
/// `cursorDrumMachine`'s two-fallback shape.
pub fn cursorSlicerTrack(app: *App) ?u16 {
    if (app.cursor < app.session.racks.items.len and
        app.session.racks.items[app.cursor].instrument == .slicer)
        return @intCast(app.cursor);
    if (app.view == .slicer_grid and app.slicer_track < app.session.racks.items.len and
        app.session.racks.items[app.slicer_track].instrument == .slicer)
        return app.slicer_track;
    // The slice editor is a slicer view too - it just reaches the machine
    // through its own target rather than `slicer_track`.
    if (app.view == .sampler_editor) {
        if (app.sampler_target == .slice) {
            const t = app.sampler_target.slice;
            if (t < app.session.racks.items.len and app.session.racks.items[t].instrument == .slicer) return t;
        }
    }
    return null;
}

pub fn cursorSlicer(app: *App) ?*Slicer {
    const t = cursorSlicerTrack(app) orelse return null;
    return &app.session.racks.items[t].instrument.slicer;
}

/// The cursor's track index, or null when it's on the master row (or out
/// of range). Shared fallback for commands whose leading `<track>` arg is
/// now optional - same "no args: act on the selection" convenience
/// `:track-del`'s cursor fallback already established.
pub fn cursorTrackIdx(app: *App) ?usize {
    if (app.cursor >= app.session.project.tracks.items.len) return null;
    return app.cursor;
}

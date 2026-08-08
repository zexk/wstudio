//! Track/group management `:` commands split out of commands.zig - add/
//! delete/rename tracks and groups, instrument swaps, sends, and the pad
//! rename command.

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

const cursorDrumMachine = cu.cursorDrumMachine;
const cursorSlicer = cu.cursorSlicer;
const cursorTrackIdx = cu.cursorTrackIdx;

pub fn cmdTrackAdd(app: *App, args: []const u8) void {
    const name = std.mem.trim(u8, args, " ");
    app.doTrackAdd(if (name.len > 0) name else null);
}

pub fn cmdSplitDrums(app: *App, args: []const u8) void {
    if (std.mem.trim(u8, args, " ").len != 0) {
        app.setStatus("split-drums: takes no arguments", .{});
        return;
    }
    if (app.cursor >= app.session.racks.items.len) {
        app.setStatus("split-drums: select a drum track", .{});
        return;
    }
    const count = app.session.splitDrumTrack(app.cursor) catch |err| {
        app.setStatus("split-drums: {s}", .{@errorName(err)});
        return;
    };
    app.dirty = true;
    app.setStatus("split into {d} sampler tracks", .{count});
}

pub fn cmdTrackDel(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const idx: usize = if (trimmed.len == 0) blk: {
        if (app.cursor >= app.session.project.tracks.items.len) {
            app.setStatus("track-del: cursor is on the master row - give a track number", .{});
            return;
        }
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

/// Adaptive like `:load`: renames whatever the open editor is editing - a
/// pad in the drum grid, the loaded clip in a slicer or sampler editor, a
/// group when the tracks-view cursor sits on a group row, otherwise the
/// cursor track. `[<n>]` targets a different one of that same kind without
/// moving the cursor there first.
pub fn cmdRename(app: *App, args: []const u8) void {
    switch (app.view) {
        .drum_grid => return cmdRenamePad(app, args),
        .slicer_grid => return cmdRenameSlicerClip(app, args),
        // The sampler editor is opened on one of three things; it renames
        // whichever it was pointed at, not the track hosting it.
        .sampler_editor => switch (app.sampler_target) {
            .drum => return cmdRenamePad(app, args),
            .slice => return cmdRenameSlicerClip(app, args),
            .sampler => return cmdRenameSamplerClip(app, args),
        },
        else => {},
    }
    if (app.cursorGroup()) |g| return cmdRenameGroup(app, g, args);
    cmdRenameTrack(app, args);
}

/// `:rename` while a slicer grid (or a slice's params) is open. A slicer has
/// one clip shared by every slice, so there is exactly one name to set - no
/// `[<n>]` target, unlike the drum grid's per-pad names.
pub fn cmdRenameSlicerClip(app: *App, args: []const u8) void {
    const name = std.mem.trim(u8, args, " ");
    if (name.len == 0) {
        app.setStatus("usage: rename <name>", .{});
        return;
    }
    const sl = cursorSlicer(app) orelse {
        app.setStatus("rename: no slicer here", .{});
        return;
    };
    sl.rename(name);
    app.dirty = true;
    app.setStatus("slicer clip renamed: {s}", .{sl.clipName()});
}

/// Same shape for a standalone sampler track's own clip.
pub fn cmdRenameSamplerClip(app: *App, args: []const u8) void {
    const name = std.mem.trim(u8, args, " ");
    if (name.len == 0) {
        app.setStatus("usage: rename <name>", .{});
        return;
    }
    const sampler = app.editingSampler() orelse {
        app.setStatus("rename: no sampler here", .{});
        return;
    };
    sampler.rename(name);
    app.dirty = true;
    app.setStatus("sample renamed: {s}", .{sampler.clipName()});
}

/// The `:rename [<n>] <name>` argument shape, shared by the track, group and
/// pad variants. A lone token that isn't a bare number is a forgotten
/// `<name>` far more often than someone renaming a thing to a numeral, so it
/// names whatever the cursor is on (`index` null) - the same "no index: act
/// on the selection" convenience gain/pan/eq share. Sets status and returns
/// null on a malformed argument.
const RenameArgs = struct { index: ?[]const u8, name: []const u8 };

fn parseRenameArgs(app: *App, args: []const u8) ?RenameArgs {
    const trimmed = std.mem.trim(u8, args, " ");
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const first = it.next().?;
    const rest = std.mem.trim(u8, it.rest(), " ");
    const first_is_number = std.fmt.parseInt(usize, first, 10) catch null;
    if (rest.len == 0 and first.len > 0 and first_is_number == null)
        return .{ .index = null, .name = first };
    if (rest.len == 0) {
        app.setStatus("usage: rename [<n>] <name>", .{});
        return null;
    }
    return .{ .index = first, .name = rest };
}

pub fn cmdRenameTrack(app: *App, args: []const u8) void {
    const parsed = parseRenameArgs(app, args) orelse return;
    const idx = if (parsed.index) |tok| blk: {
        const n = std.fmt.parseInt(usize, tok, 10) catch {
            app.setStatus("rename: expected a track number", .{});
            return;
        };
        if (n == 0 or n > app.session.project.tracks.items.len) {
            app.setStatus("rename: track must be 1–{d}", .{app.session.project.tracks.items.len});
            return;
        }
        break :blk n - 1;
    } else cursorTrackIdx(app) orelse {
        app.setStatus("rename: cursor is on the master row - give a track number", .{});
        return;
    };
    app.session.project.renameTrack(idx, parsed.name) catch {
        app.setStatus("out of memory", .{});
        return;
    };
    app.dirty = true;
    app.setStatus("track {d} renamed to \"{s}\"", .{ idx + 1, parsed.name });
}

/// Swap the cursor track's instrument kind. Unlike the instrument picker
/// (which only ever fires on a blank track), this runs on a live track and
/// asks `Session.changeInstrumentKind` to carry the notes over when the old
/// and new kinds are compatible - see that function's doc comment for
/// exactly which pairings qualify.
pub fn cmdTrackInstrument(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("usage: track-instrument [<n>] <synth|sampler|drum|slicer|soundfont|acoustic>", .{});
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const first = it.next().?;
    const rest = std.mem.trim(u8, it.rest(), " ");

    // No second token: a single arg is always the kind for the cursor
    // track - unlike :rename, a kind name can never be confused with
    // a bare track number, so there's no ambiguity to resolve.
    const idx: usize, const kind_str: []const u8 = if (rest.len == 0) blk: {
        const cursor_idx = cursorTrackIdx(app) orelse {
            app.setStatus("track-instrument: cursor is on the master row - give a track number", .{});
            return;
        };
        break :blk .{ cursor_idx, first };
    } else blk: {
        const n = std.fmt.parseInt(usize, first, 10) catch {
            app.setStatus("track-instrument: expected a track number", .{});
            return;
        };
        if (n == 0 or n > app.session.project.tracks.items.len) {
            app.setStatus("track-instrument: track must be 1–{d}", .{app.session.project.tracks.items.len});
            return;
        }
        break :blk .{ n - 1, rest };
    };
    const kind = app_mod.apiKindFromName(kind_str) orelse {
        app.setStatus("track-instrument: unknown kind '{s}' (synth/sampler/drum/slicer/soundfont/acoustic)", .{kind_str});
        return;
    };
    if (std.meta.activeTag(app.session.racks.items[idx].instrument) == kind) {
        app.setStatus("track {d} is already {s}", .{ idx + 1, kind_str });
        return;
    }
    var backup = history.captureTrackKindSwap(app, idx);
    const preserved = app.session.changeInstrumentKind(idx, kind) catch |err| {
        if (backup) |*b| b.deinit(app.allocator);
        app.setStatus("track-instrument: {s}", .{@errorName(err)});
        return;
    };
    history.push(app, backup);
    app.dirty = true;
    if (kind == .acoustic) app.loadDefaultAcoustic(idx);
    // The swapped track may be the one an instrument editor is open on -
    // `:track-instrument 2 synth` runs just as well from the slicer grid as
    // from the tracks view. Leaving the view up would send the next keypress
    // through `slicerInst()` (or `drumMachine()`) on a rack that now holds a
    // different union field. The picker path avoids this by returning to
    // `.tracks` outright; here the view is whatever the user was in.
    app.exitStaleEditors();
    if (preserved) {
        app.setStatus("track {d}: now {s} (notes kept)", .{ idx + 1, kind_str });
    } else {
        app.setStatus("track {d}: now {s} (no compatible mapping - notes cleared)", .{ idx + 1, kind_str });
    }
}

pub fn cmdGroupAdd(app: *App, args: []const u8) void {
    if (std.mem.trim(u8, args, " ").len != 0) {
        app.setStatus("usage: group-add", .{});
        return;
    }
    const name = "untitled group";
    const idx = app.session.addGroup(name) catch |err| {
        switch (err) {
            error.GroupLimitReached => app.setStatus("group-add: bank full ({d} groups)", .{ws.engine.max_groups}),
            error.OutOfMemory => app.setStatus("group-add: out of memory", .{}),
        }
        return;
    };
    app.dirty = true;
    app.setStatus("group {d} \"{s}\" created", .{ idx + 1, name });
}

/// Group index from a 1-based command argument, or null with a status
/// message already set - shared by every `:group-*`/`:track-group` command
/// that takes one.
fn parseGroupArg(app: *App, name: []const u8, s: []const u8) ?u8 {
    const n = std.fmt.parseInt(u8, s, 10) catch {
        app.setStatus("{s}: expected a group number", .{name});
        return null;
    };
    if (n == 0 or n > ws.engine.max_groups) {
        app.setStatus("{s}: group must be 1–{d}", .{ name, ws.engine.max_groups });
        return null;
    }
    return n - 1;
}

fn existingGroupArg(app: *App, name: []const u8, s: []const u8) ?u8 {
    const idx = parseGroupArg(app, name, s) orelse return null;
    if (app.session.groups[idx] == null) {
        app.setStatus("{s}: group {d} doesn't exist", .{ name, idx + 1 });
        return null;
    }
    return idx;
}

/// `cursor_group` is the group the tracks-view cursor already sits on
/// (`cmdRename` only calls this once `app.cursorGroup()` confirms it).
pub fn cmdRenameGroup(app: *App, cursor_group: u8, args: []const u8) void {
    const parsed = parseRenameArgs(app, args) orelse return;
    const idx = if (parsed.index) |tok|
        parseGroupArg(app, "rename", tok) orelse return
    else
        cursor_group;
    const name = parsed.name;

    if (app.session.groups[idx] == null) {
        app.setStatus("rename: group {d} doesn't exist", .{idx + 1});
        return;
    }
    app.session.renameGroup(idx, name) catch {
        app.setStatus("out of memory", .{});
        return;
    };
    app.dirty = true;
    app.setStatus("group {d} renamed to \"{s}\"", .{ idx + 1, name });
}

pub fn cmdGroupGain(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const idx_str = it.next() orelse "";
    if (idx_str.len == 0) {
        app.setStatus("usage: group-gain <n> [<dB>]", .{});
        return;
    }
    const idx = existingGroupArg(app, "group-gain", idx_str) orelse return;
    const db_str = std.mem.trim(u8, it.rest(), " ");
    if (db_str.len == 0) {
        app.setStatus("group {d} gain: {d:.1}dB", .{ idx + 1, app.session.groups[idx].?.gain_db });
        return;
    }
    const db = parseFiniteFloat(f32, db_str) catch {
        app.setStatus("group-gain: expected a dB value, e.g. :group-gain 1 -6", .{});
        return;
    };
    const before = app.session.groups[idx].?.gain_db;
    app.session.setGroupGain(idx, db);
    history.recordGroupGain(app, idx, before);
    app.setStatus("group {d} gain: {d:.1}dB", .{ idx + 1, app.session.groups[idx].?.gain_db });
}

pub fn cmdGroupDel(app: *App, args: []const u8) void {
    const idx_str = std.mem.trim(u8, args, " ");
    if (idx_str.len == 0) {
        app.setStatus("usage: group-del <n>", .{});
        return;
    }
    const idx = existingGroupArg(app, "group-del", idx_str) orelse return;
    if (app.view == .group_spectrum and app.eq_group == idx) app.view = .tracks;
    // Must run BEFORE deleteGroup frees the slot: the very next addGroup
    // can reuse `idx`, and any undo entry still naming it would otherwise
    // silently retarget onto the new group's chain.
    _ = history.dropGroupPending(app, idx);
    app.session.deleteGroup(idx);
    app.dirty = true;
    app.setStatus("group {d} deleted", .{idx + 1});
}

pub fn cmdGroupFx(app: *App, args: []const u8) void {
    const idx_str = std.mem.trim(u8, args, " ");
    if (idx_str.len == 0) {
        app.setStatus("usage: group-fx <n>", .{});
        return;
    }
    const idx = existingGroupArg(app, "group-fx", idx_str) orelse return;
    spectrum_ed.switchToGroup(app, idx);
}

pub fn cmdTrackGroup(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const track_str = it.next() orelse "";
    const group_str = std.mem.trim(u8, it.rest(), " ");
    if (track_str.len == 0 or group_str.len == 0) {
        app.setStatus("usage: track-group <track> <group|none>", .{});
        return;
    }
    const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
        app.setStatus("track-group: bad track number '{s}'", .{track_str});
        return;
    };
    if (track_1 == 0 or track_1 > app.session.project.tracks.items.len) {
        app.setStatus("track-group: track must be 1–{d}", .{app.session.project.tracks.items.len});
        return;
    }
    const track_idx = track_1 - 1;
    if (std.ascii.eqlIgnoreCase(group_str, "none")) {
        app.session.assignTrackGroup(track_idx, null);
        app.dirty = true;
        app.setStatus("track {d}: ungrouped", .{track_1});
        return;
    }
    const idx = existingGroupArg(app, "track-group", group_str) orelse return;
    app.session.assignTrackGroup(track_idx, idx);
    app.dirty = true;
    app.setStatus("track {d} → group {d}", .{ track_1, idx + 1 });
}

/// `:track-send <track> <slot> none` clears a slot; `:track-send <track>
/// <slot> master|<group> <dB>` sets it - a parallel, independently-leveled
/// tap alongside the track's one primary route (`:track-group`/ungrouped).
/// Slot is 1-based, same convention as track/group numbers throughout.
pub fn cmdTrackSend(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const track_str = it.next() orelse "";
    const slot_str = it.next() orelse "";
    const target_str = it.next() orelse "";
    if (track_str.len == 0 or slot_str.len == 0 or target_str.len == 0) {
        app.setStatus("usage: track-send <track> <slot 1-{d}> none|master|<group> [<dB>]", .{ws.max_sends_per_track});
        return;
    }
    const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
        app.setStatus("track-send: bad track number '{s}'", .{track_str});
        return;
    };
    if (track_1 == 0 or track_1 > app.session.project.tracks.items.len) {
        app.setStatus("track-send: track must be 1–{d}", .{app.session.project.tracks.items.len});
        return;
    }
    const track_idx: u16 = @intCast(track_1 - 1);

    const slot_1 = std.fmt.parseInt(u8, slot_str, 10) catch {
        app.setStatus("track-send: bad slot number '{s}'", .{slot_str});
        return;
    };
    if (slot_1 == 0 or slot_1 > ws.max_sends_per_track) {
        app.setStatus("track-send: slot must be 1–{d}", .{ws.max_sends_per_track});
        return;
    }
    const slot = slot_1 - 1;

    if (std.ascii.eqlIgnoreCase(target_str, "none")) {
        app.session.clearTrackSend(track_idx, slot);
        app.dirty = true;
        app.setStatus("track {d} send {d}: cleared", .{ track_1, slot_1 });
        return;
    }

    const level_str = std.mem.trim(u8, it.rest(), " ");
    const level_db = if (level_str.len == 0) -6.0 else std.fmt.parseFloat(f32, level_str) catch {
        app.setStatus("track-send: bad level '{s}'", .{level_str});
        return;
    };

    if (std.ascii.eqlIgnoreCase(target_str, "master")) {
        app.session.setTrackSend(track_idx, slot, .master, level_db);
        app.dirty = true;
        app.setStatus("track {d} send {d} → master @ {d:.1}dB", .{ track_1, slot_1, level_db });
        return;
    }
    const idx = existingGroupArg(app, "track-send", target_str) orelse return;
    app.session.setTrackSend(track_idx, slot, .{ .group = idx }, level_db);
    app.dirty = true;
    app.setStatus("track {d} send {d} → group {d} @ {d:.1}dB", .{ track_1, slot_1, idx + 1, level_db });
}

/// `cmdRename` only reaches this while the drum grid is actually open, so
/// `app.drum_cursor[0]` (the grid's own pad cursor) is always the sensible
/// default.
pub fn cmdRenamePad(app: *App, args: []const u8) void {
    const parsed = parseRenameArgs(app, args) orelse return;
    const pad_idx: u8 = if (parsed.index) |tok| blk: {
        const pad_num = std.fmt.parseInt(u8, tok, 10) catch {
            app.setStatus("rename: bad pad index '{s}'", .{tok});
            return;
        };
        if (pad_num < 1 or pad_num > DrumMachine.max_pads) {
            app.setStatus("rename: pad index must be 1-{d}", .{DrumMachine.max_pads});
            return;
        }
        break :blk pad_num - 1;
    } else @intCast(app.drum_cursor[0]);
    const name = parsed.name;

    const dm = cursorDrumMachine(app) orelse {
        app.setStatus("rename: select a drum-machine track first", .{});
        return;
    };
    if (dm.pads[pad_idx] == null) {
        app.setStatus("rename: pad {d} is empty - :load it first", .{pad_idx + 1});
        return;
    }
    dm.pads[pad_idx].?.rename(name);
    app.dirty = true;
    app.setStatus("pad {d} renamed: {s}", .{ pad_idx + 1, dm.pads[pad_idx].?.clipName() });
}

// ---------------------------------------------------------------------------
// Modulation controllers (see dsp/controller.zig)

const controller_mod = ws.dsp.controller;
const lfo_mod = ws.dsp.lfo;

/// The param the open editor's cursor is sitting on, as a controller target
/// would address it - the synth/sampler editors' cursors are already raw
/// param ids, and the FX chain view pairs its focused unit's `instance_id`
/// with the row index. Null (with a status set) when the current view has no
/// bindable param under the cursor.
///
/// Ranges and the current value come from the same tables the automation
/// editor and the FX editor already use, so a param that can't be automated
/// can't be bound either.
fn focusedControllerTarget(app: *App) ?controller_mod.Target {
    switch (app.view) {
        .track_spectrum => {
            if (app.eq_track >= app.session.racks.items.len) return null;
            const fx = &app.session.racks.items[app.eq_track].fx;
            const unit = spectrum_ed.focusedUnit(app, fx) orelse {
                app.setStatus("ctrl-bind: this chain is empty", .{});
                return null;
            };
            if (!ws.dsp.fx_params.isPayloadAutomatable(&unit.payload, app.fx_param)) {
                app.setStatus("ctrl-bind: this param can't be modulated", .{});
                return null;
            }
            const range = ws.dsp.fx_params.paramRange(&unit.payload, app.fx_param);
            if (!(range[1] > range[0])) return null;
            return .{
                .track = app.eq_track,
                .instance_id = unit.instance_id,
                .param_id = @intCast(app.fx_param),
                .center = ws.dsp.fx_params.getParam(&unit.payload, app.fx_param),
                .lo = range[0],
                .hi = range[1],
            };
        },
        .synth_editor, .sampler_editor => {
            const track = if (app.view == .synth_editor) app.synth_track else app.sampler_target.track();
            const id: u16 = if (app.view == .synth_editor)
                @intCast(app.synth_cursor)
            else
                @intCast(app.sampler_param);
            if (track >= app.session.racks.items.len) return null;
            const params = app.session.racks.items[track].instrument.automatableParams();
            for (params) |p| {
                if (p.id != id) continue;
                if (!(p.range[1] > p.range[0])) return null;
                return .{
                    .track = track,
                    .param_id = id,
                    .center = history.liveParamValue(app, track, id) orelse p.range[0],
                    .lo = p.range[0],
                    .hi = p.range[1],
                };
            }
            app.setStatus("ctrl-bind: this param can't be modulated", .{});
            return null;
        },
        else => {
            app.setStatus("ctrl-bind: open a synth, sampler or FX editor first", .{});
            return null;
        },
    }
}

/// Parse and bounds-check a 1-based controller number.
fn controllerArg(app: *App, cmd: []const u8, tok: []const u8) ?u8 {
    const n = std.fmt.parseInt(u8, tok, 10) catch {
        app.setStatus("{s}: bad controller number '{s}'", .{ cmd, tok });
        return null;
    };
    if (n == 0 or n > controller_mod.max_controllers) {
        app.setStatus("{s}: controller must be 1-{d}", .{ cmd, controller_mod.max_controllers });
        return null;
    }
    return n - 1;
}

/// `:ctrl` lists the bank; `:ctrl <n> [shape] [beats] [depth] [phase]`
/// creates or retunes controller `n`. Every argument past the number is
/// optional and keeps whatever the slot already had (or the default on a
/// fresh slot), so retuning just the rate is `:ctrl 1 sine 2`.
pub fn cmdController(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        listControllers(app);
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const idx = controllerArg(app, "ctrl", it.next() orelse "") orelse return;
    const slot = &app.session.project.controllers[idx];
    var c: controller_mod.Controller = slot.* orelse .{};

    if (it.next()) |shape_str| {
        if (shape_str.len > 0) {
            c.shape = std.meta.stringToEnum(lfo_mod.Shape, shape_str) orelse {
                app.setStatus("ctrl: shape must be one of sine, triangle, saw, square", .{});
                return;
            };
        }
    }
    if (it.next()) |beats_str| {
        if (beats_str.len > 0) {
            const beats = parseFiniteFloat(f32, beats_str) catch {
                app.setStatus("ctrl: bad cycle length '{s}'", .{beats_str});
                return;
            };
            if (beats < 0.01 or beats > 128.0) {
                app.setStatus("ctrl: cycle length must be 0.01-128 beats", .{});
                return;
            }
            c.beats = beats;
        }
    }
    if (it.next()) |depth_str| {
        if (depth_str.len > 0) {
            const depth = parseFiniteFloat(f32, depth_str) catch {
                app.setStatus("ctrl: bad depth '{s}'", .{depth_str});
                return;
            };
            c.depth = std.math.clamp(depth, 0.0, 1.0);
        }
    }
    if (it.next()) |phase_str| {
        if (phase_str.len > 0) {
            const phase = parseFiniteFloat(f32, phase_str) catch {
                app.setStatus("ctrl: bad phase '{s}'", .{phase_str});
                return;
            };
            c.phase = std.math.clamp(phase, 0.0, 1.0);
        }
    }

    slot.* = c;
    app.session.syncModulation();
    app.dirty = true;
    app.setStatus("ctrl {d}: {s}, {d:.2} beats, depth {d:.2}, phase {d:.2}", .{
        idx + 1, @tagName(c.shape), c.beats, c.depth, c.phase,
    });
}

fn listControllers(app: *App) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var any = false;
    for (app.session.project.controllers, 0..) |maybe, i| {
        const c = maybe orelse continue;
        var bound: usize = 0;
        for (c.targets) |t| {
            if (t != null) bound += 1;
        }
        if (any) w.writeAll("  ") catch break;
        w.print("{d}: {s} {d:.2}b d{d:.2} → {d} knob(s)", .{
            i + 1, @tagName(c.shape), c.beats, c.depth, bound,
        }) catch break;
        any = true;
    }
    if (!any) {
        app.setStatus("no controllers - ':ctrl 1 sine 4 0.5' makes one, then 'ctrl-bind 1' on a param", .{});
        return;
    }
    app.setStatus("controllers: {s}", .{w.buffered()});
}

/// `:ctrl-bind <n>` wires controller `n` to the param under the open
/// editor's cursor. The param's current value becomes the centre the
/// controller swings around, so binding never jumps the sound.
pub fn cmdControllerBind(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("usage: ctrl-bind <controller 1-{d}>", .{controller_mod.max_controllers});
        return;
    }
    const idx = controllerArg(app, "ctrl-bind", trimmed) orelse return;
    const slot = &app.session.project.controllers[idx];
    if (slot.* == null) {
        app.setStatus("ctrl-bind: controller {d} doesn't exist yet - ':ctrl {d}' makes it", .{ idx + 1, idx + 1 });
        return;
    }
    const target = focusedControllerTarget(app) orelse return;

    // Re-binding the same knob retunes it (fresh centre) rather than
    // stacking a second target that would fight the first every block.
    for (&slot.*.?.targets) |*existing| {
        const e = existing.* orelse continue;
        if (e.track != target.track or e.instance_id != target.instance_id or e.param_id != target.param_id) continue;
        existing.* = target;
        app.session.syncModulation();
        app.dirty = true;
        app.setStatus("ctrl {d}: re-centred on this param", .{idx + 1});
        return;
    }
    const free = slot.*.?.freeSlot() orelse {
        app.setStatus("ctrl {d}: full ({d} targets)", .{ idx + 1, controller_mod.max_targets });
        return;
    };
    slot.*.?.targets[free] = target;
    app.session.syncModulation();
    app.dirty = true;
    app.setStatus("ctrl {d} → track {d} param {d}", .{ idx + 1, target.track + 1, target.param_id });
}

/// `:ctrl-clear <n>` frees a whole slot, targets and all. There is no
/// per-target unbind: with a bank this small, rebuilding a controller is
/// two commands, and a knob left at whatever value the controller last
/// wrote is easier to fix than a half-cleared list is to reason about.
pub fn cmdControllerClear(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("usage: ctrl-clear <controller 1-{d}>", .{controller_mod.max_controllers});
        return;
    }
    const idx = controllerArg(app, "ctrl-clear", trimmed) orelse return;
    app.session.project.controllers[idx] = null;
    app.session.syncModulation();
    app.dirty = true;
    app.setStatus("ctrl {d}: cleared", .{idx + 1});
}

/// `:cc` lists learned MIDI bindings; `:cc <number>` binds that controller
/// number to the param under the open editor's cursor outright, for when
/// the number is already known.
pub fn cmdCc(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        listCcBindings(app);
        return;
    }
    const cc = std.fmt.parseInt(u8, trimmed, 10) catch {
        app.setStatus("cc: bad controller number '{s}'", .{trimmed});
        return;
    };
    if (cc > 127) {
        app.setStatus("cc: controller number must be 0-127", .{});
        return;
    }
    const target = focusedControllerTarget(app) orelse return;
    bindCc(app, @intCast(cc), target);
}

fn listCcBindings(app: *App) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var any = false;
    for (app.session.project.cc_bindings) |maybe| {
        const b = maybe orelse continue;
        if (any) w.writeAll("  ") catch break;
        w.print("CC{d}→t{d}p{d}", .{ b.cc, b.target.track + 1, b.target.param_id }) catch break;
        any = true;
    }
    if (!any) {
        app.setStatus("no MIDI bindings - put the cursor on a param and run ':cc-learn'", .{});
        return;
    }
    app.setStatus("midi: {s}", .{w.buffered()});
}

/// Store `target` under `cc`, replacing whatever that number already drove -
/// one hardware knob moving two params at once is never what a re-learn
/// meant. Shared by the explicit `:cc <n>` form and the learn path.
fn bindCc(app: *App, cc: u7, target: controller_mod.Target) void {
    var free: ?usize = null;
    for (&app.session.project.cc_bindings, 0..) |*slot, i| {
        if (slot.*) |b| {
            if (b.cc == cc) {
                slot.* = .{ .cc = cc, .target = target };
                app.session.syncModulation();
                app.dirty = true;
                app.setStatus("CC{d} → track {d} param {d} (was bound, re-pointed)", .{ cc, target.track + 1, target.param_id });
                return;
            }
        } else if (free == null) {
            free = i;
        }
    }
    const idx = free orelse {
        app.setStatus("cc: all {d} binding slots are in use", .{controller_mod.max_cc_bindings});
        return;
    };
    app.session.project.cc_bindings[idx] = .{ .cc = cc, .target = target };
    app.session.syncModulation();
    app.dirty = true;
    app.setStatus("CC{d} → track {d} param {d}", .{ cc, target.track + 1, target.param_id });
}

/// `:cc-learn` arms MIDI learn on the param under the cursor: the next
/// controller message that arrives binds it. The target is resolved now
/// rather than when the message lands, so the player can look away from the
/// screen and reach for the hardware without the cursor mattering any more.
pub fn cmdCcLearn(app: *App, args: []const u8) void {
    _ = args;
    if (app.cc_learn != null) {
        app.cc_learn = null;
        app.cc_learn_seq = null;
        app.setStatus("cc-learn: cancelled", .{});
        return;
    }
    const target = focusedControllerTarget(app) orelse return;
    app.cc_learn = target;
    // Only a message arriving after this counts - see `App.cc_learn_seq`.
    app.cc_learn_seq = if (app.session.engine.lastCc()) |last| last.seq else 0;
    app.setStatus("cc-learn: move a knob on your controller ( :cc-learn again to cancel )", .{});
}

/// Called once a frame from `App.tick`. Does nothing until learn is armed,
/// then watches the engine's last-seen controller number - the engine
/// records it for every CC regardless of routing or existing bindings, so a
/// knob that already drives something can still be re-learned.
pub fn pollCcLearn(app: *App) void {
    const target = app.cc_learn orelse return;
    const last = app.session.engine.lastCc() orelse return;
    if (app.cc_learn_seq) |armed| {
        if (last.seq == armed) return;
    }
    app.cc_learn = null;
    app.cc_learn_seq = null;
    bindCc(app, last.cc, target);
}

/// `:cc-clear` drops every binding; `:cc-clear <number>` drops just that
/// one. The param keeps whatever value the knob last wrote - the same way a
/// cleared automation lane leaves the param where it stood.
pub fn cmdCcClear(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.session.project.cc_bindings = @splat(null);
        app.session.syncModulation();
        app.dirty = true;
        app.setStatus("midi bindings: all cleared", .{});
        return;
    }
    const cc = std.fmt.parseInt(u8, trimmed, 10) catch {
        app.setStatus("cc-clear: bad controller number '{s}'", .{trimmed});
        return;
    };
    for (&app.session.project.cc_bindings) |*slot| {
        const b = slot.* orelse continue;
        if (b.cc != cc) continue;
        slot.* = null;
        app.session.syncModulation();
        app.dirty = true;
        app.setStatus("CC{d}: unbound", .{cc});
        return;
    }
    app.setStatus("cc-clear: CC{d} isn't bound", .{cc});
}

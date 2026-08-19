//! The `wstudio.api.*` validated entry points App exposes to the Lua
//! runtime (docs/lua-api.md phase 6) - split out of ui/app.zig. Each
//! mirrors the exact code path the equivalent UI gesture takes, so
//! scripts and keys can't diverge. App re-exports every method and
//! error/info type here under its original name, since
//! config/lua_api.zig reaches them as `App.ApiPatternError` etc.

const std = @import("std");
const types = ws.types;
const ws = @import("wstudio");
const pattern_mod = ws.dsp.pattern;
const DrumMachine = ws.dsp.DrumMachine;
const undo_mod = @import("../undo.zig");
const history = @import("../history.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const apiKindName = app_mod.apiKindName;
const spectrum_ed = @import("../editors/fx_editor.zig");
const reload_path_buf_len = app_mod.reload_path_buf_len;
const currentTrack = App.currentTrack;
const doTrackAddKind = App.doTrackAddKind;

// ------------------------------------------------------------------
// wstudio.api surface (docs/lua-api.md phase 6). Validated entry points
// for the Lua runtime - each mirrors the exact code path the equivalent
// UI gesture takes, so scripts and keys can't diverge. Writes go
// through the same engine.send commands, reads hit the control-side
// project mirror.

pub fn apiIsPlaying(self: *App) bool {
    return self.session.engine.uiSnapshot().playing;
}

pub fn apiPlay(self: *App) void {
    _ = self.session.engine.send(.play);
}

pub fn apiStop(self: *App) void {
    _ = self.session.engine.send(.stop);
}

pub const ApiTransportInfo = struct {
    playing: bool,
    tempo: f64,
    position_beats: f64,
    position_seconds: f64,
    position_frames: u64,
    sample_rate: u32,
    beats_per_bar: u8,
    song_mode: bool,
    metronome: bool,
    loop_enabled: bool,
    loop_start_bar: u32,
    loop_end_bar: u32,
};

pub fn apiTransportInfo(self: *const App) ApiTransportInfo {
    const snap = self.session.engine.uiSnapshot();
    const sr: f64 = @floatFromInt(self.session.project.sample_rate);
    const seconds = @as(f64, @floatFromInt(snap.position_frames)) / sr;
    const position_beats = self.session.project.beatAtFrames(snap.position_frames);
    return .{
        .playing = snap.playing,
        .tempo = ws.time_map.tempoAt(self.session.project.tempo_points.items, self.session.project.tempo_bpm, position_beats),
        .position_beats = position_beats,
        .position_seconds = seconds,
        .position_frames = snap.position_frames,
        .sample_rate = self.session.project.sample_rate,
        .beats_per_bar = self.session.project.beats_per_bar,
        .song_mode = self.session.song_mode,
        .metronome = self.session.metronome_enabled,
        .loop_enabled = self.session.project.loop_enabled,
        .loop_start_bar = self.session.project.loop_start_bar,
        .loop_end_bar = self.session.project.loop_end_bar,
    };
}

pub fn apiSeekBeats(self: *App, beats: f64) bool {
    if (!std.math.isFinite(beats) or beats < 0) return false;
    _ = self.session.engine.send(.{ .seek_frames = self.session.project.framesAtBeat(beats) });
    return true;
}

pub fn apiSetSongMode(self: *App, on: bool) void {
    self.session.setSongMode(on);
}

pub fn apiSetMetronome(self: *App, on: bool) void {
    self.session.setMetronome(on);
}

/// Bars are internal: zero-based start and exclusive end. The Lua
/// boundary presents them as the 1-based labels shown in the UI.
pub fn apiSetLoop(self: *App, enabled: bool, start_bar: u32, end_bar: u32) void {
    const p = &self.session.project;
    p.loop_enabled = enabled;
    p.loop_start_bar = start_bar;
    p.loop_end_bar = end_bar;
    self.session.syncLoop();
    self.dirty = true;
}

pub fn apiGetTempo(self: *const App) f64 {
    return self.session.project.tempo_bpm;
}

/// The editor context exposed to Lua. The active track follows the
/// open editor rather than the tracks-view cursor, matching the same
/// resolution used by mute, solo, and note preview.
pub fn apiCurrentTrack(self: *App) ?usize {
    const idx = self.currentTrack();
    return if (idx < self.session.project.tracks.items.len) idx else null;
}

/// False when out of the :bpm command's 20-400 range (or not finite).
pub fn apiSetTempo(self: *App, bpm: f64) bool {
    if (!std.math.isFinite(bpm) or bpm < 20.0 or bpm > 400.0) return false;
    self.session.project.tempo_bpm = bpm;
    _ = self.session.engine.send(.{ .set_tempo = bpm });
    // The loop region is stored in bars; its frame mirror just moved.
    self.session.syncLoop();
    self.dirty = true;
    return true;
}

pub const ApiTrackInfo = struct {
    name: []const u8,
    kind: []const u8,
    gain_db: f32,
    pan: f32,
    muted: bool,
    soloed: bool,
    armed: bool,
    /// 1-based for Lua, like track indices.
    group: ?u8,
};

pub fn apiTrackInfo(self: *const App, idx: usize) ApiTrackInfo {
    const t = self.session.project.tracks.items[idx];
    return .{
        .name = t.name,
        .kind = apiKindName(std.meta.activeTag(self.session.racks.items[idx].instrument)),
        .gain_db = t.gain_db,
        .pan = t.pan,
        .muted = t.muted,
        .soloed = t.soloed,
        .armed = self.session.isArmed(idx),
        .group = if (t.group) |g| g + 1 else null,
    };
}

pub fn apiSetTrackGainDb(self: *App, idx: usize, db: f32) void {
    const t = &self.session.project.tracks.items[idx];
    t.gain_db = std.math.clamp(db, -60.0, 12.0);
    self.dirty = true;
    _ = self.session.engine.send(.{ .set_track_gain = .{ .track = @intCast(idx), .gain = types.dbToGain(t.gain_db) } });
}

pub fn apiSetTrackPan(self: *App, idx: usize, pan: f32) void {
    const t = &self.session.project.tracks.items[idx];
    t.pan = std.math.clamp(pan, -1.0, 1.0);
    self.dirty = true;
    _ = self.session.engine.send(.{ .set_track_pan = .{ .track = @intCast(idx), .pan = t.pan } });
}

pub fn apiSetTrackMuted(self: *App, idx: usize, muted: bool) void {
    const t = &self.session.project.tracks.items[idx];
    t.muted = muted;
    self.dirty = true;
    _ = self.session.engine.send(.{ .set_track_mute = .{ .track = @intCast(idx), .muted = muted } });
}

pub fn apiSetTrackSoloed(self: *App, idx: usize, soloed: bool) void {
    const t = &self.session.project.tracks.items[idx];
    t.soloed = soloed;
    self.dirty = true;
    _ = self.session.engine.send(.{ .set_track_solo = .{ .track = @intCast(idx), .soloed = soloed } });
}

pub fn apiSetTrackArmed(self: *App, idx: usize, armed: bool) void {
    if (self.session.isArmed(idx) != armed) self.session.toggleArm(idx);
}

pub fn apiSelectTrack(self: *App, idx: usize) void {
    self.cursor = idx;
}

pub fn apiRenameTrack(self: *App, idx: usize, name: []const u8) bool {
    self.session.project.renameTrack(idx, name) catch return false;
    self.dirty = true;
    return true;
}

/// Null when the track limit is hit. TrackAdd fires after the requested
/// instrument exists, so every observer sees the committed state.
pub fn apiTrackAdd(self: *App, kind: ws.InstrumentKind, name: ?[]const u8) ?usize {
    const before = self.session.project.tracks.items.len;
    self.doTrackAddKind(name, kind);
    if (self.session.project.tracks.items.len == before) return null;
    return self.cursor;
}

/// False when the delete was refused (the last remaining track).
pub fn apiTrackDel(self: *App, idx: usize) bool {
    const before = self.session.project.tracks.items.len;
    self.doTrackDel(idx);
    return self.session.project.tracks.items.len < before;
}

pub fn apiTrackDuplicate(self: *App, idx: usize) ?usize {
    const before = self.session.project.tracks.items.len;
    self.doTrackDup(idx);
    return if (self.session.project.tracks.items.len > before) self.cursor else null;
}

pub fn apiTrackMove(self: *App, idx: usize, target: usize) usize {
    self.cursor = idx;
    while (self.cursor < target) self.doTrackMove(1);
    while (self.cursor > target) self.doTrackMove(-1);
    return self.cursor;
}

// ------------------------------------------------------------------
// Pattern content (docs/lua-api.md phase 8). Reads hand out the
// validated live pattern; writes wrap it in the same undo capture and
// song-rebuild the editors use, so one Lua call is one undo entry.

pub const ApiPatternError = error{ NoInstrument, NotMelodic, NotDrum, TooManyNotes };

pub const ApiPatternInfo = struct {
    /// "melodic", "drum", "slicer", or "none" - what the content
    /// functions below will accept for this track.
    kind: []const u8,
    length_beats: f64,
    /// Grid shape, present only for the step-sequenced kinds.
    steps_per_beat: ?u8 = null,
    step_count: ?u16 = null,
};

pub fn apiPatternInfo(self: *const App, idx: usize) ApiPatternInfo {
    const rack = self.session.racks.items[idx];
    switch (rack.instrument) {
        .empty, .audio => return .{ .kind = "none", .length_beats = 0 },
        .drum_machine => |*dm| return .{
            .kind = "drum",
            .length_beats = @as(f64, @floatFromInt(dm.step_count)) / @as(f64, @floatFromInt(dm.steps_per_beat)),
            .steps_per_beat = dm.steps_per_beat,
            .step_count = dm.step_count,
        },
        .slicer => |*sl| return .{
            .kind = "slicer",
            .length_beats = @as(f64, @floatFromInt(sl.step_count)) / @as(f64, @floatFromInt(sl.steps_per_beat)),
            .steps_per_beat = sl.steps_per_beat,
            .step_count = sl.step_count,
        },
        else => {},
    }
    const pp = if (rack.pattern_player) |*p| p else return .{ .kind = "none", .length_beats = 0 };
    return .{ .kind = "melodic", .length_beats = pp.length_beats };
}

/// The live melodic pattern, or an error naming why this track has none.
pub fn apiPatternPlayer(self: *App, idx: usize) ApiPatternError!*pattern_mod.PatternPlayer {
    const rack = self.session.racks.items[idx];
    return switch (rack.instrument) {
        .empty, .audio => error.NoInstrument,
        .drum_machine, .slicer => error.NotMelodic,
        else => if (rack.pattern_player) |*pp| pp else error.NoInstrument,
    };
}

pub fn apiDrumMachine(self: *App, idx: usize) ApiPatternError!*DrumMachine {
    return switch (self.session.racks.items[idx].instrument) {
        .drum_machine => |*dm| dm,
        .empty, .audio => error.NoInstrument,
        else => error.NotDrum,
    };
}

/// Take the pre-edit undo snapshot for a drum grid rewrite and hand back
/// the machine to write into. `apiPatternChanged` closes the edit.
pub fn apiDrumEdit(self: *App, idx: usize) ApiPatternError!*DrumMachine {
    const dm = try self.apiDrumMachine(idx);
    history.recordDrum(self, @intCast(idx));
    return dm;
}

/// Shared tail of every content write: song mode plays the flattened
/// arrangement, so an edit to a live pattern only lands once the clips
/// referencing it are rebuilt.
pub fn apiPatternChanged(self: *App) void {
    self.dirty = true;
    if (self.session.song_mode) self.session.rebuildSongData();
}

pub fn apiSetNotes(self: *App, idx: usize, notes: []const pattern_mod.Note) ApiPatternError!void {
    const pp = try self.apiPatternPlayer(idx);
    if (notes.len > pattern_mod.max_notes) return error.TooManyNotes;
    history.recordMelodic(self, @intCast(idx));
    pp.setNotes(notes, pp.length_beats);
    self.apiPatternChanged();
}

pub const ApiPatternUpdate = struct {
    length_beats: ?f64 = null,
    step_count: ?u16 = null,
    steps_per_beat: ?u8 = null,
};

/// A melodic track only has a loop length. Drum data uses 32 musical ticks
/// per beat; `steps_per_beat` remains accepted as input-unit metadata for
/// callers sending a `step_count` from another grid.
pub fn apiSetPattern(self: *App, idx: usize, update: ApiPatternUpdate) ApiPatternError!void {
    switch (self.session.racks.items[idx].instrument) {
        .drum_machine => {
            const dm = try self.apiDrumEdit(idx);
            const source_spb = std.math.clamp(update.steps_per_beat orelse DrumMachine.ticks_per_beat, 1, 32);
            if (update.step_count) |n| dm.setStepCount(@intCast(@min(
                @as(u32, n) * DrumMachine.ticks_per_beat / source_spb,
                DrumMachine.max_steps,
            )));
            if (update.length_beats) |beats| {
                const steps = beats * @as(f64, @floatFromInt(dm.steps_per_beat));
                dm.setStepCount(@max(pattern_mod.clampStep(steps), 1));
            }
        },
        else => {
            const pp = try self.apiPatternPlayer(idx);
            if (update.step_count != null or update.steps_per_beat != null) return error.NotDrum;
            const beats = update.length_beats orelse return;
            history.recordMelodic(self, @intCast(idx));
            pp.length_beats = if (std.math.isFinite(beats)) @max(1.0, beats) else 4.0;
        },
    }
    self.apiPatternChanged();
}

// ------------------------------------------------------------------
// FX chains (docs/lua-api.md phase 9). Targets are `undo.FxTarget`, the
// index-explicit form undo/redo already uses, so none of this depends
// on which chain the user happens to have open - unlike the editor's
// own helpers, which resolve through `app.eq_track`/`app.eq_group`.

pub const ApiFxError = error{ NoChain, SlotOutOfRange, ChainFull, ClapNeedsPath, OutOfMemory };

pub fn apiFxChain(self: *App, target: undo_mod.FxTarget) ApiFxError!*ws.Fx {
    return history.fxPtrFor(self, target) orelse error.NoChain;
}

pub fn apiFxUnit(self: *App, target: undo_mod.FxTarget, slot: usize) ApiFxError!*ws.FxUnit {
    const fx = try self.apiFxChain(target);
    if (slot >= fx.units.items.len) return error.SlotOutOfRange;
    return fx.units.items[slot];
}

/// Insert at `pos` (clamped to the chain's current end) and return the
/// slot it landed in. Mirrors the picker's insert: capture first, push
/// the undo entry only if the insert actually took.
pub fn apiFxAdd(self: *App, target: undo_mod.FxTarget, kind: ws.FxKind, pos: usize) ApiFxError!usize {
    const fx = try self.apiFxChain(target);
    const at = @min(pos, fx.units.items.len);
    history.flushFxNudge(self);
    const before = history.captureFxRaw(self, target);
    _ = fx.insert(self.session.allocator, at, kind, self.session.project.sample_rate) catch |err| {
        history.pushFxIfOk(self, before, false);
        return switch (err) {
            error.ChainFull => error.ChainFull,
            error.OutOfMemory => error.OutOfMemory,
            error.ClapPluginRequiresPath => error.ClapNeedsPath,
            error.Vst3PluginRequiresPath => error.ClapNeedsPath,
        };
    };
    history.pushFxIfOk(self, before, true);
    self.dirty = true;
    history.syncFxTarget(self, target);
    return at;
}

pub fn apiFxDel(self: *App, target: undo_mod.FxTarget, slot: usize) ApiFxError!void {
    const fx = try self.apiFxChain(target);
    if (slot >= fx.units.items.len) return error.SlotOutOfRange;
    history.flushFxNudge(self);
    history.push(self, history.captureFxRaw(self, target));
    fx.remove(self.session.allocator, slot);
    if (self.fx_focus >= fx.units.items.len) self.fx_focus = fx.units.items.len -| 1;
    history.syncFxTarget(self, target);
}

/// Adjacent swaps until the unit reaches `to`, the same walk the editor's
/// `[`/`]` does, so nothing that indexes chain slots can skip a step.
pub fn apiFxMove(self: *App, target: undo_mod.FxTarget, slot: usize, to: usize) ApiFxError!usize {
    const fx = try self.apiFxChain(target);
    if (slot >= fx.units.items.len or to >= fx.units.items.len) return error.SlotOutOfRange;
    if (slot == to) return slot;
    history.flushFxNudge(self);
    history.push(self, history.captureFxRaw(self, target));
    var at = slot;
    while (at < to) : (at += 1) fx.swap(at, at + 1);
    while (at > to) : (at -= 1) fx.swap(at, at - 1);
    history.syncFxTarget(self, target);
    return to;
}

pub fn apiFxBypass(self: *App, target: undo_mod.FxTarget, slot: usize, on: bool) ApiFxError!void {
    const unit = try self.apiFxUnit(target, slot);
    if (unit.bypassed == on) return;
    history.flushFxNudge(self);
    history.push(self, history.captureFxRaw(self, target));
    unit.bypassed = on;
    history.syncFxTarget(self, target);
}

/// Param count for a unit, narrowed the same way the editor narrows it
/// (CLAP reports its own count; `comp`'s scpad row only exists when the
/// sidechain track is a drum machine).
pub fn apiFxParamCount(self: *App, target: undo_mod.FxTarget, slot: usize) ApiFxError!usize {
    const unit = try self.apiFxUnit(target, slot);
    return spectrum_ed.visibleParamCount(self, unit.kind(), &unit.payload);
}

/// Values are clamped to the param's range by the same setter the editor
/// nudges through, so a script can't push a unit somewhere the UI can't.
pub fn apiFxParamSet(self: *App, target: undo_mod.FxTarget, slot: usize, param: usize, value: f32) ApiFxError!void {
    const unit = try self.apiFxUnit(target, slot);
    if (param >= spectrum_ed.visibleParamCount(self, unit.kind(), &unit.payload)) return error.SlotOutOfRange;
    history.flushFxNudge(self);
    history.push(self, history.captureFxRaw(self, target));
    spectrum_ed.setParam(self, &unit.payload, param, value);
    history.syncFxTarget(self, target);
}

// ------------------------------------------------------------------
// Arrangement clips and sections (docs/lua-api.md phase 10). Clips are
// stamped from the track's live pattern, the same way the arrangement
// editor's `enter` does - a script builds the pattern with the phase-8
// functions, then places it.

pub const ApiClipError = error{ NoLane, NoClip, NothingToStamp, OutOfMemory };

pub fn apiLane(self: *App, idx: usize) ApiClipError!*ws.arrangement.Lane {
    return self.session.arrangement.lane(idx) orelse error.NoLane;
}

pub fn apiClipAdd(self: *App, idx: usize, start_bar: u32) ApiClipError!void {
    _ = try self.apiLane(idx);
    // The same length the editor previews before stamping; 0 means the
    // track has no instrument (or no pattern), so nothing would land.
    if (self.session.stampLengthTicks(idx) == 0) return error.NothingToStamp;
    history.recordLane(self, @intCast(idx));
    self.session.stampClip(idx, start_bar) catch return error.OutOfMemory;
    self.apiPatternChanged();
}

pub fn apiClipDel(self: *App, idx: usize, bar: u32) ApiClipError!void {
    const lane = try self.apiLane(idx);
    const at = self.session.project.tickAtBar(bar);
    if (lane.clipAt(at) == null) return error.NoClip;
    history.recordLane(self, @intCast(idx));
    _ = lane.removeAt(self.allocator, at);
    self.apiPatternChanged();
}

pub fn apiClipClear(self: *App, idx: usize) ApiClipError!void {
    const lane = try self.apiLane(idx);
    history.recordLane(self, @intCast(idx));
    lane.clear(self.allocator);
    self.apiPatternChanged();
}

pub fn apiSectionSet(self: *App, at: u32, name: []const u8) !void {
    history.recordSections(self);
    try self.session.project.setSection(at, name);
    self.dirty = true;
}

pub fn apiSectionDel(self: *App, at: u32) bool {
    const present = for (self.session.project.sections.items) |section| {
        if (section.tick == at) break true;
    } else false;
    if (!present) return false;
    history.recordSections(self);
    _ = self.session.project.removeSection(at);
    self.dirty = true;
    return true;
}

pub fn apiProjectSave(self: *App, requested_path: []const u8) !void {
    var path_buf: [reload_path_buf_len]u8 = undefined;
    const source = if (requested_path.len > 0) requested_path else self.projectPath() orelse self.defaultProjectPath();
    if (source.len > path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..source.len], source);
    const path = path_buf[0..source.len];
    self.emitEvent(.{ .ProjectSavePre = .{ .path = path } });
    try ws.persist.save(self.allocator, &self.session, self.io, path);
    self.deleteBackupIfPresent();
    self.setProjectPath(path);
    self.dirty = false;
    self.setStatus("saved: {s}", .{path});
    self.emitEvent(.{ .ProjectSavePost = .{ .path = path } });
}

pub fn apiProjectOpen(self: *App, path: []const u8, force: bool) bool {
    if (self.dirty and !force) return false;
    self.requestReload(path);
    return true;
}

pub fn apiProjectNew(self: *App, force: bool) bool {
    if (self.dirty and !force) return false;
    self.requestReload(null);
    return true;
}

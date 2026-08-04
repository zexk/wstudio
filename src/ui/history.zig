//! App-side undo/redo glue over the model in undo.zig: pre-edit captures
//! (melodic pattern, drum bank, arrangement lane), swap-restore application,
//! and the u/U entry points shared by every editing view.

const std = @import("std");
const ws = @import("wstudio");
const pattern_mod = ws.dsp.pattern;
const undo_mod = @import("undo.zig");
const App = @import("app.zig").App;
const piano = @import("editors/piano.zig");
const spectrum = @import("editors/spectrum.zig");

/// Record a pre-edit snapshot; null (capture failed / target invalid)
/// simply records nothing - undo is best-effort, never blocks the edit.
/// The edit that follows happens either way, so the session goes dirty here.
pub fn push(app: *App, entry: ?undo_mod.Entry) void {
    app.dirty = true;
    if (entry) |e| app.history.push(app.allocator, e);
}

/// Snapshot one track's live melodic pattern, remembering an active
/// clip link on that track so undo restores the clip as well.
pub fn captureMelodic(app: *App, track: u16) ?undo_mod.Entry {
    if (track >= app.session.racks.items.len or
        app.session.racks.items[track].pattern_player == null) return null;
    const pp = &app.session.racks.items[track].pattern_player.?;
    var buf: [pattern_mod.max_notes]pattern_mod.Note = undefined;
    const count = pp.copyNotes(&buf);
    const notes = app.allocator.dupe(pattern_mod.Note, buf[0..count]) catch return null;
    const link_bar: ?u32 = if (app.piano_clip_link) |l|
        (if (l.track == track) l.start_bar else null)
    else
        null;
    return .{ .melodic = .{
        .track = track,
        .length_beats = pp.length_beats,
        .notes = notes,
        .clip_start_bar = link_bar,
    } };
}

/// Pre-edit wrapper for command-layer callers (`:clear`).
pub fn recordMelodic(app: *App, track: u16) void {
    push(app, captureMelodic(app, track));
}

/// Snapshot one drum machine's whole pattern bank. Every captured slot's
/// `midi` is a fresh, independent heap copy (`variantData` itself returns a
/// borrowed view into the live machine, so this dupes before storing) -
/// the undo entry must own its own data, since the live pattern keeps
/// changing (and its old buffers keep getting freed) underneath it.
pub fn captureDrum(app: *App, track: u16) ?undo_mod.Entry {
    if (track >= app.session.racks.items.len) return null;
    const dm = switch (app.session.racks.items[track].instrument) {
        .drum_machine => |*d| d,
        else => return null,
    };
    var st: undo_mod.DrumState = .{
        .track = track,
        .variants = [_]ws.dsp.DrumMachine.Variant{.{}} ** ws.dsp.DrumMachine.max_variants,
        .variant_count = dm.variant_count,
        .variant = dm.variant,
        .pad_len = dm.pad_len,
    };
    for (0..dm.variant_count) |i| {
        const v = dm.variantData(@intCast(i)); // borrowed view - dupe before storing
        st.variants[i] = .{
            .midi = ws.dsp.DrumMachine.dupeMidi(app.allocator, &v.midi) catch {
                for (st.variants[0..i]) |*done| ws.dsp.DrumMachine.freeMidi(app.allocator, &done.midi);
                return null;
            },
            .step_count = v.step_count,
            .steps_per_beat = v.steps_per_beat,
        };
    }
    return .{ .drum = st };
}

/// Pre-edit wrapper for command-layer callers (`:euclid`, `:rotate`, ...).
pub fn recordDrum(app: *App, track: u16) void {
    push(app, captureDrum(app, track));
}

/// Snapshot one slicer's chop layout + whole variant bank (see
/// SlicerState). The active bank slot is stale; read it live via
/// variantData - same rule captureDrum applies.
pub fn captureSlicer(app: *App, track: u16) ?undo_mod.Entry {
    if (track >= app.session.racks.items.len) return null;
    const sl = switch (app.session.racks.items[track].instrument) {
        .slicer => |*s| s,
        else => return null,
    };
    var st: undo_mod.SlicerState = .{
        .track = track,
        .slice_count = sl.slice_count,
        .slices = sl.slices,
        .variants = [_]ws.dsp.Slicer.Variant{.{}} ** ws.dsp.Slicer.max_variants,
        .variant_count = sl.variant_count,
        .variant = sl.variant,
        .slice_len = sl.slice_len,
    };
    for (0..sl.variant_count) |i| {
        const v = sl.variantData(@intCast(i)); // borrowed view - dupe before storing
        st.variants[i] = .{
            .midi = ws.dsp.Slicer.dupeMidi(app.allocator, &v.midi) catch {
                for (st.variants[0..i]) |*done| ws.dsp.Slicer.freeMidi(app.allocator, &done.midi);
                return null;
            },
            .step_count = v.step_count,
            .steps_per_beat = v.steps_per_beat,
        };
    }
    return .{ .slicer = st };
}

/// Pre-edit wrapper for command-layer callers.
pub fn recordSlicer(app: *App, track: u16) void {
    push(app, captureSlicer(app, track));
}

fn swingValue(app: *App, track: u16) ?f32 {
    if (track >= app.session.racks.items.len) return null;
    const rack = app.session.racks.items[track];
    return switch (rack.instrument) {
        .drum_machine => |*dm| dm.swing.load(.monotonic),
        .slicer => |*sl| sl.swing.load(.monotonic),
        else => if (rack.pattern_player) |*pp| pp.swing.load(.monotonic) else null,
    };
}

pub fn recordSwing(app: *App, track: u16, before: f32) void {
    if (swingValue(app, track) != before) push(app, .{ .swing = .{ .track = track, .value = before } });
}

pub fn recordTrackMixer(app: *App, track: u16, field: undo_mod.MixerField, before: f32) void {
    if (track >= app.session.project.tracks.items.len) return;
    const t = app.session.project.tracks.items[track];
    const after = switch (field) {
        .gain => t.gain_db,
        .pan => t.pan,
    };
    if (after != before) push(app, .{ .mixer = .{ .target = .{ .track = track }, .field = field, .value = before } });
}

pub fn recordGroupGain(app: *App, group: u8, before: f32) void {
    const after = (app.session.groups[group] orelse return).gain_db;
    if (after != before) push(app, .{ .mixer = .{ .target = .{ .group = group }, .field = .gain, .value = before } });
}

/// Deep-copies `src` into a freshly-allocated slice, or null on OOM (with
/// every already-duped clip and the slice itself cleaned up first) - shared
/// by captureLane and captureTrackFull's own clip-copy step.
fn dupeClips(allocator: std.mem.Allocator, src: []const ws.Clip) ?[]ws.Clip {
    const out = allocator.alloc(ws.Clip, src.len) catch return null;
    for (src, 0..) |c, i| {
        out[i] = c.dupe(allocator) catch {
            for (out[0..i]) |*done| done.deinit(allocator);
            allocator.free(out);
            return null;
        };
    }
    return out;
}

const RackAndClips = struct {
    rack: *ws.Rack,
    clips: []ws.Clip,
};

fn dupeRackAndClips(app: *App, track_idx: usize) ?RackAndClips {
    if (track_idx >= app.session.racks.items.len) return null;
    const rack = app.session.racks.items[track_idx].dupe(
        app.allocator,
        app.session.project.sample_rate,
        &app.session.engine.transport,
    ) catch return null;
    const lane = app.session.arrangement.lane(track_idx) orelse return .{ .rack = rack, .clips = &.{} };
    const clips = dupeClips(app.allocator, lane.clips.items) orelse {
        rack.deinit(app.allocator);
        app.allocator.destroy(rack);
        return null;
    };
    return .{ .rack = rack, .clips = clips };
}

/// Snapshot one arrangement lane's clips (deep copies).
pub fn captureLane(app: *App, track: u16) ?undo_mod.Entry {
    const lane = app.session.arrangement.lane(track) orelse return null;
    const clips = dupeClips(app.allocator, lane.clips.items) orelse return null;
    return .{ .lane = .{ .track = @intCast(track), .clips = clips } };
}

/// Pre-edit wrapper for command-layer callers.
pub fn recordLane(app: *App, track: u16) void {
    push(app, captureLane(app, track));
}

/// Snapshot the named lanes as one entry, so an arrangement-wide edit
/// undoes in a single step (see `undo.MultiLaneState`). Lanes that don't
/// resolve are skipped; null if none did, which keeps the caller's `push` a
/// no-op rather than recording an empty step. Takes an explicit track list
/// rather than a range because an entry's lanes stop being contiguous once
/// `History.retarget` has dropped a deleted track out of the middle.
pub fn captureLanesOf(app: *App, tracks: []const u16) ?undo_mod.Entry {
    var list: std.ArrayListUnmanaged(undo_mod.LaneState) = .empty;
    for (tracks) |track| {
        const lane = app.session.arrangement.lane(track) orelse continue;
        const clips = dupeClips(app.allocator, lane.clips.items) orelse continue;
        list.append(app.allocator, .{ .track = @intCast(track), .clips = clips }) catch {
            var orphan: undo_mod.LaneState = .{ .track = @intCast(track), .clips = clips };
            orphan.deinit(app.allocator);
            continue;
        };
    }
    if (list.items.len == 0) {
        list.deinit(app.allocator);
        return null;
    }
    const sections = app.allocator.alloc(ws.Section, app.session.project.sections.items.len) catch {
        for (list.items) |*lane| lane.deinit(app.allocator);
        list.deinit(app.allocator);
        return null;
    };
    var copied: usize = 0;
    for (app.session.project.sections.items, sections) |section, *copy| {
        const name = app.allocator.dupe(u8, section.name) catch {
            for (sections[0..copied]) |done| app.allocator.free(done.name);
            app.allocator.free(sections);
            for (list.items) |*lane| lane.deinit(app.allocator);
            list.deinit(app.allocator);
            return null;
        };
        copy.* = .{ .tick = section.tick, .name = name };
        copied += 1;
    }
    return .{ .lanes = .{ .lanes = list, .sections = sections } };
}

/// `captureLanesOf` over a contiguous lane band - what a visual-mode range
/// selection produces.
pub fn captureLanes(app: *App, lo: usize, hi: usize) ?undo_mod.Entry {
    if (hi < lo) return null;
    const tracks = app.allocator.alloc(u16, hi - lo + 1) catch return null;
    defer app.allocator.free(tracks);
    for (tracks, lo..) |*t, track| t.* = @intCast(track);
    return captureLanesOf(app, tracks);
}

/// Pre-edit wrapper for a multi-lane edit.
pub fn recordLanes(app: *App, lo: usize, hi: usize) void {
    push(app, captureLanes(app, lo, hi));
}

/// Install one captured lane's clips over whatever is live there, taking
/// ownership of `l.clips`. Shared by the `.lane` and `.lanes` apply arms;
/// the caller owns the song-data rebuild (a multi-lane restore only wants
/// one at the end).
fn restoreLane(app: *App, l: undo_mod.LaneState) void {
    const lane = app.session.arrangement.lane(l.track) orelse {
        for (l.clips) |*c| c.deinit(app.allocator);
        app.allocator.free(l.clips);
        return;
    };
    lane.clear(app.allocator);
    for (l.clips, 0..) |c, i| {
        // Ownership moves into the lane (captured order is sorted).
        lane.clips.append(app.allocator, c) catch {
            for (l.clips[i..]) |*rest| rest.deinit(app.allocator);
            break;
        };
    }
    app.allocator.free(l.clips);
    // A linked clip may have been replaced or removed.
    if (app.piano_clip_link) |link| {
        if (link.track == l.track) app.piano_clip_link = null;
    }
}

/// Snapshot `track_idx`'s full state (mixer metadata, deep-copied rack,
/// deep-copied arrangement clips) for whole-track undo. Same deep-copy
/// machinery `Session.duplicateTrack` uses (`Rack.dupe`), just captured
/// into an owned undo entry instead of a live sibling track.
pub fn captureTrackFull(app: *App, track_idx: usize) ?undo_mod.TrackFullState {
    if (track_idx >= app.session.racks.items.len) return null;
    const src = app.session.project.tracks.items[track_idx];

    const name = app.allocator.dupe(u8, src.name) catch return null;
    const content = dupeRackAndClips(app, track_idx) orelse {
        app.allocator.free(name);
        return null;
    };

    return .{
        .track = @intCast(track_idx),
        .name = name,
        .gain_db = src.gain_db,
        .pan = src.pan,
        .muted = src.muted,
        .soloed = src.soloed,
        .color = src.color,
        .group = src.group,
        .sends = src.sends,
        .rack = content.rack,
        .clips = content.clips,
    };
}

/// Snapshot `track_idx`'s current rack + arrangement clips (deep copies) -
/// the same `Rack.dupe`/`dupeClips` machinery `captureTrackFull` uses, minus
/// the mixer metadata a `changeInstrumentKind` swap never touches. Feeds
/// `Session.restoreRackAt` to undo/redo `:track-instrument`/`I`.
pub fn captureTrackKindSwap(app: *App, track_idx: usize) ?undo_mod.Entry {
    const content = dupeRackAndClips(app, track_idx) orelse return null;
    return .{ .track_kind_swap = .{ .track = @intCast(track_idx), .rack = content.rack, .clips = content.clips } };
}

/// The live `Fx` chain a stored `FxTarget` points at, or null if the track/
/// group it named is gone. Unlike `spectrum.fxPtr`, this resolves the
/// index baked into the entry rather than `app`'s current eq_track/
/// eq_group cursor, so undo/redo apply correctly even from a different view.
pub fn fxPtrFor(app: *App, target: undo_mod.FxTarget) ?*ws.Fx {
    return switch (target) {
        .track => |t| if (t >= app.session.racks.items.len) null else &app.session.racks.items[t].fx,
        .master => &app.session.master_fx,
        .group => |g| if (g >= ws.engine.max_groups) null else if (app.session.groups[g]) |*grp| &grp.fx else null,
    };
}

/// Push a chain resync to the engine for a stored `FxTarget` - same idea as
/// `spectrum.syncChain` but keyed off the entry's own index instead of
/// `app`'s current cursor.
pub fn syncFxTarget(app: *App, target: undo_mod.FxTarget) void {
    switch (target) {
        .track => |t| if (t < app.session.racks.items.len) app.session.syncTrackChain(t, app.session.racks.items[t]),
        .master => app.session.syncMasterChain(),
        .group => |g| app.session.syncGroupChain(g),
    }
}

/// Snapshot one FX chain's whole unit list (deep copy).
pub fn captureFxRaw(app: *App, target: undo_mod.FxTarget) ?undo_mod.Entry {
    const fx = fxPtrFor(app, target) orelse return null;
    const dup = fx.dupe(app.allocator, app.session.project.sample_rate) catch return null;
    return .{ .fx = .{ .target = target, .fx = dup } };
}

/// Snapshot the FX chain in view, resolving `app`'s current eq_track/
/// eq_group into the concrete target baked into the entry.
pub fn captureFx(app: *App, target: spectrum.EqTarget) ?undo_mod.Entry {
    return captureFxRaw(app, switch (target) {
        .track => .{ .track = app.eq_track },
        .master => .master,
        .group => .{ .group = app.eq_group },
    });
}

/// Push a `captureFx` result only if the edit it preceded actually
/// succeeded; otherwise discard it. For structural edits that can fail
/// after already needing to capture "before" state (e.g. a picker insert
/// that turns out chain-full), so a failed edit doesn't leave a spurious
/// no-op undo step.
pub fn pushFxIfOk(app: *App, entry: ?undo_mod.Entry, ok: bool) void {
    const e = entry orelse return;
    if (ok) {
        push(app, e);
    } else {
        var owned = e;
        owned.deinit(app.allocator);
    }
}

/// Pre-edit wrapper for a structural FX-chain edit (insert/remove/reorder/
/// bypass) - each such edit is its own undo step, so any open param-nudge
/// batch on the same chain is flushed first (closing it as a separate step)
/// rather than folding the structural edit into it.
pub fn recordFx(app: *App, target: spectrum.EqTarget) void {
    flushFxNudge(app);
    push(app, captureFx(app, target));
}

/// Note one nudge of unit `focus`'s param `param` in the chain `target`
/// points at, called right before the caller mutates it. Continues the
/// open batch if it's the same (target, focus, param); otherwise flushes
/// whatever was open and captures a fresh "before" snapshot for the new one.
pub fn noteFxNudge(app: *App, target: spectrum.EqTarget, focus: usize, param: usize) void {
    const t: undo_mod.FxTarget = switch (target) {
        .track => .{ .track = app.eq_track },
        .master => .master,
        .group => .{ .group = app.eq_group },
    };
    if (app.pending_fx_nudge) |p| {
        if (undo_mod.FxTarget.eql(p.target, t) and p.focus == focus and p.param == param) return;
        flushFxNudge(app);
    }
    if (captureFxRaw(app, t)) |entry| {
        app.pending_fx_nudge = .{ .target = t, .focus = focus, .param = param, .before = entry.fx };
    }
}

/// Commit the in-flight FX param-nudge batch (if any) to the undo stack.
/// Call on any focus/param/view change so a batch never silently drops.
pub fn flushFxNudge(app: *App) void {
    const p = app.pending_fx_nudge orelse return;
    app.pending_fx_nudge = null;
    app.dirty = true;
    app.history.push(app.allocator, .{ .fx = p.before });
}

/// The live value of instrument param `id` on `track`, in the encoding
/// `set_track_param_abs` restores (see each instrument's `paramValue`).
/// A control-thread read of the rack's live DSP struct - same
/// race-tolerant convention the editors' own row rendering uses. Null
/// when the track is gone or its instrument has no such param (e.g. the
/// instrument was swapped since the entry was captured - the undo/redo
/// then skips rather than writing a foreign id).
fn liveParamValue(app: *App, track: u16, id: u16) ?f32 {
    if (track >= app.session.racks.items.len) return null;
    return switch (app.session.racks.items[track].instrument) {
        .poly_synth => |*s| s.paramValue(id),
        .sampler => |*s| s.paramValue(id),
        .soundfont, .acoustic => |*sf| sf.paramValue(id),
        .drum_machine => |*dm| dm.paramValue(id),
        .slicer => |*sl| sl.paramValue(id),
        .clap => null,
        .vst3 => null,
        .empty => null,
    };
}

/// Note one nudge (`steps`, already signed) of param `id` on `track`,
/// called right BEFORE the caller sends the live `set_track_param` command
/// (so the captured before-value predates the nudge). Continues the open
/// batch if it's the same (track, id); otherwise flushes whatever was open
/// and starts a new one by capturing the param's current absolute value.
pub fn noteParamNudge(app: *App, track: u16, id: u16, steps: i32) void {
    if (app.pending_param_nudge) |*p| {
        if (p.track == track and p.id == id) {
            p.steps += steps;
            return;
        }
        flushParamNudge(app);
    }
    const before = liveParamValue(app, track, id) orelse return;
    app.pending_param_nudge = .{ .track = track, .id = id, .before = before, .steps = steps };
}

/// Record a one-shot absolute param write - a command that sets a value
/// outright (`:bpm-sync`) rather than nudging it - so undo puts the old
/// value back. Flushes any open nudge batch first, same ordering the
/// editors use before any other history push.
pub fn recordParamSet(app: *App, track: u16, id: u16) void {
    flushParamNudge(app);
    const before = liveParamValue(app, track, id) orelse return;
    app.dirty = true;
    app.history.push(app.allocator, .{ .param_nudge = .{ .track = track, .id = id, .value = before } });
}

/// Commit the in-flight param-nudge batch (if any) to the undo stack,
/// storing the absolute before-value - see `ParamNudgeState`'s doc
/// comment. A batch that netted zero steps is dropped rather than pushed
/// as a no-op step; that check uses the synchronous steps accumulator,
/// NOT a re-read of the live value, because the nudges themselves are
/// queued commands the audio thread may not have applied yet. Call on any
/// cursor/track/view change so a batch never silently drops.
pub fn flushParamNudge(app: *App) void {
    const p = app.pending_param_nudge orelse return;
    app.pending_param_nudge = null;
    if (p.steps == 0) return;
    app.dirty = true;
    app.history.push(app.allocator, .{ .param_nudge = .{ .track = p.track, .id = p.id, .value = p.before } });
}

/// Remap or drop the in-flight param/FX nudge batch (if any) after a
/// structural track change - same rule `undo.History.retarget` applies to
/// the stacks, so a batch still open on a track that's about to shift
/// doesn't keep writing into the wrong track once it flushes. Call BEFORE
/// the track change lands (delete/swap), same ordering `retarget` needs.
pub fn retargetPending(app: *App, remap: undo_mod.TrackRemap) void {
    if (app.pending_param_nudge) |*p| {
        if (remap.apply(p.track)) |nt| {
            p.track = nt;
        } else {
            app.pending_param_nudge = null;
        }
    }
    if (app.pending_fx_nudge) |*p| {
        switch (p.target) {
            .track => |t| if (remap.apply(t)) |nt| {
                // `before` embeds its own copy of the target (it's the
                // Entry flushFxNudge will push verbatim) - remap both or
                // the flushed entry still names the old index.
                p.target = .{ .track = nt };
                p.before.target = .{ .track = nt };
            } else {
                p.deinit(app.allocator);
                app.pending_fx_nudge = null;
            },
            else => {},
        }
    }
}

/// Drop an open FX param-nudge batch if it targets group `idx`, and drop
/// every stacked `.fx` entry naming it - the group-delete counterpart to
/// `retargetPending`+`history.retarget`. Call BEFORE `Session.deleteGroup`,
/// same ordering `retargetPending` needs for track deletes, since the
/// slot it frees can be reused by the very next `addGroup` (see
/// `project_code_review_2026_07_11_full_codebase` finding #2).
pub fn dropGroupPending(app: *App, idx: u8) usize {
    if (app.pending_fx_nudge) |*p| {
        if (p.target == .group and p.target.group == idx) {
            p.deinit(app.allocator);
            app.pending_fx_nudge = null;
        }
    }
    return app.history.dropGroup(app.allocator, idx);
}

/// Swap `entry`'s state with the live one. On success the entry is
/// consumed and the displaced state is returned for the opposite stack;
/// null means the target no longer accepts it (track gone, kind changed)
/// and the entry was left untouched for the caller to free.
fn applyEntry(app: *App, entry: undo_mod.Entry) ?undo_mod.Entry {
    switch (entry) {
        .melodic => |m| {
            const displaced = captureMelodic(app, m.track) orelse return null;
            const pp = &app.session.racks.items[m.track].pattern_player.?;
            pp.setNotes(m.notes, m.length_beats);
            app.allocator.free(m.notes);
            if (m.clip_start_bar) |bar| {
                // The edit lived in a clip: re-link and write it back.
                app.piano_track = m.track;
                app.piano_clip_link = .{ .track = m.track, .start_bar = bar };
                piano.syncLinkedClip(app);
            } else if (app.piano_clip_link) |link| {
                // Restored an unlinked state over an active link: drop the
                // link so the next edit can't clobber the clip.
                if (link.track == m.track) app.piano_clip_link = null;
            }
            return displaced;
        },
        .drum => |d| {
            const displaced = captureDrum(app, d.track) orelse return null;
            const dm = &app.session.racks.items[d.track].instrument.drum_machine;
            // `d` is being consumed here (see this function's doc comment):
            // free the live bank's current slices, then transfer ownership
            // of `d`'s own (already deep-copied by captureDrum) slices
            // directly into `dm.variants` - no further dupe needed for the
            // bank itself. `applyVariant` dupes the active slot again to
            // build the live `dm.midi`, so `d`'s copy stays intact as the
            // bank's own.
            for (dm.variants[0..dm.variant_count]) |*slot| ws.dsp.DrumMachine.freeMidi(app.allocator, &slot.midi);
            dm.variants = d.variants;
            dm.variant_count = d.variant_count;
            dm.variant = @min(d.variant, d.variant_count - 1);
            dm.applyVariant(dm.variants[dm.variant]);
            // After applyVariant: the restored pattern's step count is what
            // decides whether a length is still an override.
            for (d.pad_len, 0..) |len, pad| dm.setPadLen(@intCast(pad), len);
            if (app.drum_cursor[1] >= dm.step_count) app.drum_cursor[1] = dm.step_count - 1;
            return displaced;
        },
        .slicer => |d| {
            const displaced = captureSlicer(app, d.track) orelse return null;
            const sl = &app.session.racks.items[d.track].instrument.slicer;
            // Restore the chop layout under the sample lock (processBlock
            // holds it for the whole block), re-pointing every slice at the
            // CURRENT buffer - captured `samples` aliases may predate a
            // :load in the slicer view (see SlicerState's doc comment).
            while (!sl.sample_lock.tryLock()) std.atomic.spinLoopHint();
            sl.slice_count = d.slice_count;
            sl.slices = d.slices;
            for (&sl.slices) |*p| p.samples = sl.samples;
            sl.sample_lock.unlock();
            // Same ownership transfer the `.drum` arm above documents: `d` is
            // consumed here, so the live bank's rows are freed and `d`'s
            // already-deep-copied rows become the bank's own.
            for (sl.variants[0..sl.variant_count]) |*slot| ws.dsp.Slicer.freeMidi(app.allocator, &slot.midi);
            sl.variants = d.variants;
            sl.variant_count = d.variant_count;
            sl.variant = @min(d.variant, d.variant_count - 1);
            sl.applyVariant(sl.variants[sl.variant]);
            for (d.slice_len, 0..) |len, s| sl.setSliceLen(@intCast(s), len); // after applyVariant, as the drum arm notes
            sl.resetAll(); // ringing tails would finish through relocated slices
            app.slicer_cursor[0] = @min(app.slicer_cursor[0], sl.slice_count -| 1);
            app.slicer_cursor[1] = @min(app.slicer_cursor[1], sl.step_count -| 1);
            return displaced;
        },
        .lane => |l| {
            const displaced = captureLane(app, l.track) orelse return null;
            restoreLane(app, l);
            if (app.session.song_mode) app.session.rebuildSongData();
            return displaced;
        },
        .lanes => |ml| {
            // Capture every lane the entry names BEFORE restoring any of
            // them, or the displaced entry (what redo replays) would
            // describe lanes this apply has already overwritten. Bailing on
            // OOM leaves the entry untouched on its stack, same as every
            // other `orelse return null` here.
            const tracks = app.allocator.alloc(u16, ml.lanes.items.len) catch return null;
            defer app.allocator.free(tracks);
            for (ml.lanes.items, tracks) |l, *t| t.* = l.track;
            const displaced = captureLanesOf(app, tracks) orelse return null;
            app.session.project.sections.ensureTotalCapacity(app.allocator, ml.sections.len) catch {
                var orphan = displaced;
                orphan.deinit(app.allocator);
                return null;
            };
            for (ml.lanes.items) |l| restoreLane(app, l);
            var owned = ml.lanes;
            owned.deinit(app.allocator);
            for (app.session.project.sections.items) |section| app.allocator.free(section.name);
            app.session.project.sections.clearRetainingCapacity();
            for (ml.sections) |section| app.session.project.sections.appendAssumeCapacity(section);
            app.allocator.free(ml.sections);
            if (app.session.song_mode) app.session.rebuildSongData();
            return displaced;
        },
        .fx => |f| {
            const displaced = captureFxRaw(app, f.target) orelse return null;
            const fx = fxPtrFor(app, f.target).?; // captureFxRaw above already resolved it
            // Install the snapshot and push it to the audio thread BEFORE
            // freeing the displaced units: the engine's chain still holds
            // device pointers into them until the resync lands (same
            // sync-then-free rule spectrum.zig's removeFocused documents).
            const old = fx.*;
            fx.* = f.fx;
            app.fx_focus = if (fx.units.items.len == 0) 0 else @min(app.fx_focus, fx.units.items.len - 1);
            app.fx_param = 0;
            syncFxTarget(app, f.target);
            app.session.retireFxChain(old);
            return displaced;
        },
        .param_nudge => |p| {
            // Read the value being displaced (for the opposite stack) on
            // the control thread, then restore the stored one through the
            // audio thread's own event path - absolute, so it lands exactly
            // regardless of clamps or enum/toggle params (see
            // ParamNudgeState). liveParamValue doubles as the target check:
            // null (track gone, instrument swapped) skips the entry.
            const displaced = liveParamValue(app, p.track, p.id) orelse return null;
            _ = app.session.engine.setTrackParam(p.track, p.id, p.value);
            return .{ .param_nudge = .{ .track = p.track, .id = p.id, .value = displaced } };
        },
        .swing => |s| {
            const displaced = swingValue(app, s.track) orelse return null;
            const rack = app.session.racks.items[s.track];
            switch (rack.instrument) {
                .drum_machine => |*dm| dm.swing.store(s.value, .monotonic),
                .slicer => |*sl| sl.swing.store(s.value, .monotonic),
                else => if (rack.pattern_player) |*pp| pp.swing.store(s.value, .monotonic) else return null,
            }
            return .{ .swing = .{ .track = s.track, .value = displaced } };
        },
        .mixer => |m| {
            const displaced: f32 = switch (m.target) {
                .track => |track| blk: {
                    if (track >= app.session.project.tracks.items.len) return null;
                    const t = app.session.project.tracks.items[track];
                    const old = switch (m.field) {
                        .gain => t.gain_db,
                        .pan => t.pan,
                    };
                    switch (m.field) {
                        .gain => app.apiSetTrackGainDb(track, m.value),
                        .pan => app.apiSetTrackPan(track, m.value),
                    }
                    break :blk old;
                },
                .group => |group| blk: {
                    if (m.field != .gain or group >= ws.engine.max_groups or app.session.groups[group] == null) return null;
                    const old = app.session.groups[group].?.gain_db;
                    app.session.setGroupGain(group, m.value);
                    break :blk old;
                },
            };
            return .{ .mixer = .{ .target = m.target, .field = m.field, .value = displaced } };
        },
        .track_insert => |state| {
            var s = state;
            app.session.restoreTrack(s.track, s.name, .{
                // zig fmt: off
                .gain_db = s.gain_db, .pan = s.pan, .muted = s.muted,
                .soloed = s.soloed, .color = s.color, .group = s.group,
                .sends = s.sends,
                // zig fmt: on
            }, s.rack, s.clips) catch {
                s.deinit(app.allocator);
                return null;
            };
            app.allocator.free(s.name);
            app.shiftFieldsForInsert(s.track);
            const remap: undo_mod.TrackRemap = .{ .insert = s.track };
            retargetPending(app, remap);
            _ = app.history.retarget(app.allocator, remap);
            app.cursor = s.track;
            app.invalidateTrackRow();
            app.emitEvent(.{ .TrackAdd = .{ .track = s.track + 1 } });
            return .{ .track_delete = s.track };
        },
        .track_delete => |idx| {
            if (idx >= app.session.racks.items.len) return null;
            var state = captureTrackFull(app, idx) orelse return null;
            app.session.deleteTrack(idx) catch {
                state.deinit(app.allocator);
                return null;
            };
            app.shiftFieldsForDelete(idx);
            const remap: undo_mod.TrackRemap = .{ .delete = idx };
            retargetPending(app, remap);
            _ = app.history.retarget(app.allocator, remap);
            const last = app.session.project.tracks.items.len - 1;
            app.cursor = @min(app.cursor, last);
            app.invalidateTrackRow();
            app.exitStaleEditors();
            app.emitEvent(.{ .TrackDel = .{ .track = idx + 1 } });
            return .{ .track_insert = state };
        },
        .track_kind_swap => |state| {
            const displaced = captureTrackKindSwap(app, state.track) orelse return null;
            app.session.restoreRackAt(state.track, state.rack, state.clips) catch {
                var d = displaced;
                d.deinit(app.allocator);
                var owned = state;
                owned.deinit(app.allocator);
                return null;
            };
            app.exitStaleEditors();
            return displaced;
        },
    }
}

/// Shared body of doUndo/doRedo: pop an entry off the requested stack,
/// apply it, and either park the displaced entry on the opposite stack or
/// discard the entry with a "gone" status if its target no longer exists.
/// `is_undo` is comptime so each direction still compiles to its own
/// straight-line code (same pop/park calls and status wording as the two
/// functions had separately, just written once).
fn applyAndPark(app: *App, comptime is_undo: bool) void {
    var entry = (if (is_undo) app.history.popUndo() else app.history.popRedo()) orelse {
        app.setStatus(if (is_undo) "nothing to undo" else "nothing to redo", .{});
        return;
    };
    const what = entry.label();
    if (applyEntry(app, entry)) |displaced| {
        if (is_undo) app.history.parkRedo(app.allocator, displaced) else app.history.parkUndo(app.allocator, displaced);
        app.dirty = true;
        if (is_undo)
            app.setStatus("undid {s} edit ({d} left)", .{ what, app.history.undo_stack.items.len })
        else
            app.setStatus("redid {s} edit", .{what});
    } else {
        entry.deinit(app.allocator);
        app.setStatus(if (is_undo) "undo target is gone - skipped" else "redo target is gone - skipped", .{});
    }
}

pub fn doUndo(app: *App) void {
    // A still-open coalescing batch (param nudge / FX nudge) hasn't reached
    // the undo stack yet - flush it first so `u` right after nudging (with
    // no intervening cursor move) undoes the edit just made, not an older
    // one. Same "a fresh edit clears redo" rule as any other flush; doRedo
    // does NOT do this, since flushing there would wipe the very redo
    // entry it's about to pop.
    flushParamNudge(app);
    flushFxNudge(app);
    applyAndPark(app, true);
}

pub fn doRedo(app: *App) void {
    applyAndPark(app, false);
}

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
/// simply records nothing — undo is best-effort, never blocks the edit.
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

/// Snapshot one drum machine's whole pattern bank.
pub fn captureDrum(app: *App, track: u16) ?undo_mod.Entry {
    if (track >= app.session.racks.items.len) return null;
    const dm = switch (app.session.racks.items[track].instrument) {
        .drum_machine => |*d| d,
        else => return null,
    };
    var st: undo_mod.DrumState = .{
        .track = track,
        .variants = dm.variants,
        .variant_count = dm.variant_count,
        .variant = dm.variant,
    };
    // The active slot in the bank is stale; read the live atomics.
    st.variants[dm.variant] = dm.variantData(dm.variant);
    return .{ .drum = st };
}

/// Snapshot one arrangement lane's clips (deep copies).
pub fn captureLane(app: *App, track: u16) ?undo_mod.Entry {
    const lane = app.session.arrangement.lane(track) orelse return null;
    const clips = app.allocator.alloc(ws.Clip, lane.clips.items.len) catch return null;
    for (lane.clips.items, 0..) |c, i| {
        clips[i] = c.dupe(app.allocator) catch {
            for (clips[0..i]) |*done| done.deinit(app.allocator);
            app.allocator.free(clips);
            return null;
        };
    }
    return .{ .lane = .{ .track = @intCast(track), .clips = clips } };
}

/// The live `Fx` chain a stored `FxTarget` points at, or null if the track/
/// group it named is gone. Unlike `spectrum.fxPtr`, this resolves the
/// index baked into the entry rather than `app`'s current eq_track/
/// eq_group cursor, so undo/redo apply correctly even from a different view.
fn fxPtrFor(app: *App, target: undo_mod.FxTarget) ?*ws.Fx {
    return switch (target) {
        .track => |t| if (t >= app.session.racks.items.len) null else &app.session.racks.items[t].fx,
        .master => &app.session.master_fx,
        .group => |g| if (g >= ws.engine.max_groups) null else if (app.session.groups[g]) |*grp| &grp.fx else null,
    };
}

/// Push a chain resync to the engine for a stored `FxTarget` — same idea as
/// `spectrum.syncChain` but keyed off the entry's own index instead of
/// `app`'s current cursor.
fn syncFxTarget(app: *App, target: undo_mod.FxTarget) void {
    switch (target) {
        .track => |t| if (t < app.session.racks.items.len) app.session.syncTrackChain(t, app.session.racks.items[t]),
        .master => app.session.syncMasterChain(),
        .group => |g| app.session.syncGroupChain(g),
    }
}

/// Snapshot one FX chain's whole unit list (deep copy).
fn captureFxRaw(app: *App, target: undo_mod.FxTarget) ?undo_mod.Entry {
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

/// Pre-edit capture for command-layer callers (`:eq`, `:master-eq`,
/// `:master-comp`) that name their target explicitly instead of going
/// through the chain editor's cursor. Flushes any open FX nudge batch
/// first, same as recordFx, so undo steps land in true edit order even
/// when a command interleaves with live editor nudges on the same chain.
/// Pair the result with `pushFxIfOk` once the edit's outcome is known.
pub fn captureFxCmd(app: *App, target: undo_mod.FxTarget) ?undo_mod.Entry {
    flushFxNudge(app);
    return captureFxRaw(app, target);
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
/// bypass) — each such edit is its own undo step, so any open param-nudge
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
/// A control-thread read of the rack's live DSP struct — same
/// race-tolerant convention the editors' own row rendering uses. Null
/// when the track is gone or its instrument has no such param (e.g. the
/// instrument was swapped since the entry was captured — the undo/redo
/// then skips rather than writing a foreign id).
fn liveParamValue(app: *App, track: u16, id: u16) ?f32 {
    if (track >= app.session.racks.items.len) return null;
    return switch (app.session.racks.items[track].instrument) {
        .poly_synth => |*s| if (id <= 0xFF) s.paramValue(@intCast(id)) else null,
        .sampler => |*s| if (id <= 0xFF) s.paramValue(@intCast(id)) else null,
        .drum_machine => |*dm| dm.paramValue(id),
        else => null,
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

/// Commit the in-flight param-nudge batch (if any) to the undo stack,
/// storing the absolute before-value — see `ParamNudgeState`'s doc
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
            dm.variants = d.variants;
            dm.variant_count = d.variant_count;
            dm.variant = @min(d.variant, d.variant_count - 1);
            dm.applyVariant(d.variants[dm.variant]);
            if (app.drum_cursor[1] >= dm.step_count) app.drum_cursor[1] = dm.step_count - 1;
            return displaced;
        },
        .lane => |l| {
            const displaced = captureLane(app, l.track) orelse return null;
            const lane = app.session.arrangement.lane(l.track).?;
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
            var old = fx.*;
            fx.* = f.fx;
            app.fx_focus = if (fx.units.items.len == 0) 0 else @min(app.fx_focus, fx.units.items.len - 1);
            app.fx_param = 0;
            syncFxTarget(app, f.target);
            old.deinit(app.allocator);
            return displaced;
        },
        .param_nudge => |p| {
            // Read the value being displaced (for the opposite stack) on
            // the control thread, then restore the stored one through the
            // audio thread's own event path — absolute, so it lands exactly
            // regardless of clamps or enum/toggle params (see
            // ParamNudgeState). liveParamValue doubles as the target check:
            // null (track gone, instrument swapped) skips the entry.
            const displaced = liveParamValue(app, p.track, p.id) orelse return null;
            _ = app.session.engine.send(.{ .set_track_param_abs = .{ .track = p.track, .id = p.id, .value = p.value } });
            return .{ .param_nudge = .{ .track = p.track, .id = p.id, .value = displaced } };
        },
    }
}

pub fn doUndo(app: *App) void {
    // A still-open coalescing batch (param nudge / FX nudge) hasn't reached
    // the undo stack yet — flush it first so `u` right after nudging (with
    // no intervening cursor move) undoes the edit just made, not an older
    // one. Same "a fresh edit clears redo" rule as any other flush; doRedo
    // does NOT do this, since flushing there would wipe the very redo
    // entry it's about to pop.
    flushParamNudge(app);
    flushFxNudge(app);
    var entry = app.history.popUndo() orelse {
        app.setStatus("nothing to undo", .{});
        return;
    };
    const what = entry.label();
    if (applyEntry(app, entry)) |displaced| {
        app.history.parkRedo(app.allocator, displaced);
        app.dirty = true;
        app.setStatus("undid {s} edit ({d} left)", .{ what, app.history.undo_stack.items.len });
    } else {
        entry.deinit(app.allocator);
        app.setStatus("undo target is gone — skipped", .{});
    }
}

pub fn doRedo(app: *App) void {
    var entry = app.history.popRedo() orelse {
        app.setStatus("nothing to redo", .{});
        return;
    };
    const what = entry.label();
    if (applyEntry(app, entry)) |displaced| {
        app.history.parkUndo(app.allocator, displaced);
        app.dirty = true;
        app.setStatus("redid {s} edit", .{what});
    } else {
        entry.deinit(app.allocator);
        app.setStatus("redo target is gone — skipped", .{});
    }
}

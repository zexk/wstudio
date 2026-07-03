//! App-side undo/redo glue over the model in undo.zig: pre-edit captures
//! (melodic pattern, drum bank, arrangement lane), swap-restore application,
//! and the u/U entry points shared by every editing view.

const std = @import("std");
const ws = @import("wstudio");
const pattern_mod = ws.dsp.pattern;
const undo_mod = @import("undo.zig");
const App = @import("app.zig").App;
const piano = @import("editors/piano.zig");

/// Record a pre-edit snapshot; null (capture failed / target invalid)
/// simply records nothing — undo is best-effort, never blocks the edit.
pub fn push(app: *App, entry: ?undo_mod.Entry) void {
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
        clips[i] = dupClip(app, c) catch {
            for (clips[0..i]) |*done| done.deinit(app.allocator);
            app.allocator.free(clips);
            return null;
        };
    }
    return .{ .lane = .{ .track = @intCast(track), .clips = clips } };
}

fn dupClip(app: *App, c: ws.Clip) !ws.Clip {
    return switch (c.content) {
        .melodic => |m| try ws.Clip.initMelodic(
            app.allocator, c.start_bar, c.length_bars, m.notes, m.length_beats,
        ),
        .drum => c, // plain value, no owned memory
    };
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
    }
}

pub fn doUndo(app: *App) void {
    var entry = app.history.popUndo() orelse {
        app.setStatus("nothing to undo", .{});
        return;
    };
    const what = entry.label();
    if (applyEntry(app, entry)) |displaced| {
        app.history.parkRedo(app.allocator, displaced);
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
        app.setStatus("redid {s} edit", .{what});
    } else {
        entry.deinit(app.allocator);
        app.setStatus("redo target is gone — skipped", .{});
    }
}

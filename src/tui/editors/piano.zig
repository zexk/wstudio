//! Piano-roll input: note cursor, insert/delete/resize, velocity, yank/paste,
//! loop length, and the Ableton-style clip-link writeback (edits on a linked
//! arrangement clip land in the clip itself). The render half lives in
//! views/piano.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const pattern_mod = ws.dsp.pattern;
const midi = ws.midi;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PianoClip = app_mod.PianoClip;
const history = @import("../history.zig");
const spectrum = @import("spectrum.zig");
const synth = @import("synth.zig");

pub fn switchTo(app: *App, track: u16) void {
    if (track >= app.session.racks.items.len) return;
    switch (app.session.racks.items[track].instrument) {
        .poly_synth, .sampler => {},
        else => {
            app.setStatus("piano roll: melodic tracks only", .{});
            return;
        },
    }
    app.piano_track = track;
    app.piano_cursor_step = 0;
    app.piano_scroll_step = 0;
    // Center the 16-row viewport on the cursor pitch.
    app.piano_scroll_pitch = @intCast(@min(@as(u32, app.piano_cursor_pitch) + 8, 127));
    // A plain open edits the live pattern; the arrangement's editClip re-links after.
    app.piano_clip_link = null;
    app.view = .piano_roll;
}

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    if (app.piano_track >= app.session.racks.items.len) return false;
    const rack = app.session.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null) &app.session.racks.items[app.piano_track].pattern_player.? else return false;

    const max_step: u16 = @intFromFloat(pp.length_beats * 4.0);
    switch (key) {
        .escape => { app.view = .tracks; return true; },
        // enter toggles the note; space falls through to transport play/pause.
        .enter => { toggleNote(app); return true; },
        .char => |c| switch (c) {
            // Block insert mode — piano keys collide with roll navigation (j/k/h/d/…).
            'i' => return true,
            // fine move by one step; shift (HL) jumps one beat (4 steps)
            'h' => {
                if (app.piano_cursor_step > 0) app.piano_cursor_step -= 1;
                ensureVisible(app);
                return true;
            },
            'l' => {
                if (app.piano_cursor_step + 1 < max_step) app.piano_cursor_step += 1;
                ensureVisible(app);
                return true;
            },
            'H' => {
                app.piano_cursor_step -|= 4;
                ensureVisible(app);
                return true;
            },
            'L' => {
                if (max_step > 0)
                    app.piano_cursor_step = @min(app.piano_cursor_step + 4, max_step - 1);
                ensureVisible(app);
                return true;
            },
            'j' => {
                if (app.piano_cursor_pitch > 0) app.piano_cursor_pitch -= 1;
                ensureVisible(app);
                return true;
            },
            'k' => {
                if (app.piano_cursor_pitch < 127) app.piano_cursor_pitch += 1;
                ensureVisible(app);
                return true;
            },
            // J/K jump an octave (mirrors h/l → H/L coarse-move pattern).
            'J' => {
                app.piano_cursor_pitch = @intCast(app.piano_cursor_pitch -| 12);
                ensureVisible(app);
                return true;
            },
            'K' => {
                app.piano_cursor_pitch = @intCast(@min(@as(u32, app.piano_cursor_pitch) + 12, 127));
                ensureVisible(app);
                return true;
            },
            // g/G jump the cursor to loop start / last step.
            'g' => {
                app.piano_cursor_step = 0;
                ensureVisible(app);
                return true;
            },
            'G' => {
                if (max_step > 0) app.piano_cursor_step = max_step - 1;
                ensureVisible(app);
                return true;
            },
            // </> nudge the velocity of the note under the cursor.
            '<' => { nudgeVelocity(app, -0.1); return true; },
            '>' => { nudgeVelocity(app, 0.1); return true; },
            'y' => { yank(app); return true; },
            'P' => { paste(app); return true; },
            's' => { spectrum.switchToTrack(app, app.piano_track); return true; },
            // n/d kept as aliases for muscle memory; enter is the canonical toggle.
            'n' => { insertNote(app); return true; },
            'd' => { deleteNote(app); return true; },
            'p' => {
                app.playNote(app.piano_track, app.piano_cursor_pitch, app.now_ns);
                var nbuf: [5]u8 = undefined;
                app.setStatus("preview: {s}", .{midi.noteName(app.piano_cursor_pitch, &nbuf)});
                return true;
            },
            'e' => {
                // Jump to the instrument editor for this track (synth or sampler).
                switch (app.session.racks.items[app.piano_track].instrument) {
                    .sampler => {
                        app.sampler_target = .{ .sampler = app.piano_track };
                        app.sampler_param = 0;
                        app.view = .sampler_editor;
                    },
                    else => {
                        app.synth_track = app.piano_track;
                        app.synth_cursor = 0;
                        synth.updateScroll(app);
                        app.view = .synth_editor;
                    },
                }
                return true;
            },
            // [/] resize the note under the cursor if one starts here;
            // otherwise they set the default length for newly placed notes.
            '[' => { resizeOrLen(app, -0.25); return true; },
            ']' => { resizeOrLen(app, 0.25); return true; },
            '+' => {
                const bar: f64 = @floatFromInt(app.session.project.beats_per_bar);
                history.push(app, history.captureMelodic(app, app.piano_track));
                pp.length_beats += bar;
                app.setStatus("loop: {d:.0} beats", .{pp.length_beats});
                syncLinkedClip(app);
                return true;
            },
            '-' => {
                const bar: f64 = @floatFromInt(app.session.project.beats_per_bar);
                history.push(app, history.captureMelodic(app, app.piano_track));
                pp.length_beats = @max(bar, pp.length_beats - bar);
                app.setStatus("loop: {d:.0} beats", .{pp.length_beats});
                syncLinkedClip(app);
                return true;
            },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            else => return false,
        },
        else => return false,
    }
}

fn ensureVisible(app: *App) void {
    const vis_cols: u16 = 16;
    const vis_rows: u8  = 16;
    // horizontal
    if (app.piano_cursor_step < app.piano_scroll_step) {
        app.piano_scroll_step = app.piano_cursor_step;
    }
    if (app.piano_cursor_step >= app.piano_scroll_step + vis_cols) {
        app.piano_scroll_step = app.piano_cursor_step - vis_cols + 1;
    }
    // vertical (pitch)
    const top: i32 = @intCast(app.piano_scroll_pitch);
    const bot: i32 = top - @as(i32, vis_rows) + 1;
    const cur: i32 = @intCast(app.piano_cursor_pitch);
    if (cur > top) app.piano_scroll_pitch = @intCast(cur);
    if (cur < bot) app.piano_scroll_pitch = @intCast(cur + @as(i32, vis_rows) - 1);
}

/// Toggle the note at the cursor: remove it if one starts here on this pitch,
/// otherwise add one with the current note length. Mirrors the drum grid's
/// enter-to-toggle so both grid editors share the same place/erase gesture.
fn toggleNote(app: *App) void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const pp = if (app.session.racks.items[app.piano_track].pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;
    const start_beat = @as(f64, @floatFromInt(app.piano_cursor_step)) * 0.25;
    if (pp.noteStartsAt(app.piano_cursor_pitch, start_beat)) {
        deleteNote(app);
    } else {
        insertNote(app);
    }
}

fn insertNote(app: *App) void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const pp = if (app.session.racks.items[app.piano_track].pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;
    const start_beat = @as(f64, @floatFromInt(app.piano_cursor_step)) * 0.25;
    // Don't insert if a note already starts here on this pitch
    if (pp.noteStartsAt(app.piano_cursor_pitch, start_beat)) return;
    history.push(app, history.captureMelodic(app, app.piano_track));
    pp.addNote(.{
        .pitch        = app.piano_cursor_pitch,
        .start_beat   = start_beat,
        .duration_beat = app.piano_note_len,
    });
    var nbuf: [5]u8 = undefined;
    app.setStatus("added {s}", .{midi.noteName(app.piano_cursor_pitch, &nbuf)});
    syncLinkedClip(app);
}

/// Resize the note starting under the cursor by `delta` beats (clamped to
/// the loop length), or — if no note starts here — change the default length
/// applied to newly placed notes.
fn resizeOrLen(app: *App, delta: f64) void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const pp = if (app.session.racks.items[app.piano_track].pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;
    const start_beat = @as(f64, @floatFromInt(app.piano_cursor_step)) * 0.25;
    if (pp.noteAt(app.piano_cursor_pitch, start_beat)) |n| {
        history.push(app, history.captureMelodic(app, app.piano_track));
        n.duration_beat = std.math.clamp(n.duration_beat + delta, 0.25, pp.length_beats);
        app.setStatus("note len: {d:.2} beats", .{n.duration_beat});
        syncLinkedClip(app);
    } else {
        app.piano_note_len = std.math.clamp(app.piano_note_len + delta, 0.25, pp.length_beats);
        app.setStatus("default len: {d:.2} beats", .{app.piano_note_len});
    }
}

/// Nudge the velocity of the note under the cursor by `delta` (clamped 0.05–1).
fn nudgeVelocity(app: *App, delta: f32) void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const pp = if (app.session.racks.items[app.piano_track].pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;
    const start_beat = @as(f64, @floatFromInt(app.piano_cursor_step)) * 0.25;
    if (pp.noteAt(app.piano_cursor_pitch, start_beat)) |n| {
        history.push(app, history.captureMelodic(app, app.piano_track));
        n.velocity = std.math.clamp(n.velocity + delta, 0.05, 1.0);
        app.setStatus("velocity: {d:.0}%", .{n.velocity * 100.0});
        syncLinkedClip(app);
    } else {
        app.setStatus("no note under cursor", .{});
    }
}

/// Clip-editing writeback: copy the pattern player's notes into the
/// linked arrangement clip (the clip owns the data; the player is its
/// working copy). Cheap no-op when nothing is linked; drops the link if
/// the clip vanished from under us (deleted, evicted, lane cleared).
pub fn syncLinkedClip(app: *App) void {
    const link = app.piano_clip_link orelse return;
    if (link.track != app.piano_track) return;
    if (link.track >= app.session.racks.items.len or
        app.session.racks.items[link.track].pattern_player == null)
    {
        app.piano_clip_link = null;
        return;
    }
    const pp = &app.session.racks.items[link.track].pattern_player.?;
    const lane = app.session.arrangement.lane(link.track) orelse {
        app.piano_clip_link = null;
        return;
    };
    const clip = lane.clipAt(link.start_bar) orelse {
        app.piano_clip_link = null;
        app.setStatus("clip gone — editing the live pattern now", .{});
        return;
    };
    if (std.meta.activeTag(clip.content) != .melodic) {
        app.piano_clip_link = null;
        return;
    }
    const mel = &clip.content.melodic;

    var buf: [pattern_mod.max_notes]pattern_mod.Note = undefined;
    const count = pp.copyNotes(&buf);
    const owned = app.allocator.dupe(pattern_mod.Note, buf[0..count]) catch {
        app.setStatus("clip sync failed (out of memory)", .{});
        return;
    };
    app.allocator.free(mel.notes);
    mel.notes = owned;
    mel.length_beats = pp.length_beats;
    // Hear the edit if the song timeline is what's playing.
    if (app.session.song_mode) app.session.rebuildSongData();
}

/// Yank the piano roll's whole pattern (notes + loop length) to the
/// app clipboard.
fn yank(app: *App) void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const pp = if (app.session.racks.items[app.piano_track].pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;
    var clip: PianoClip = .{ .notes = undefined, .count = 0, .length_beats = pp.length_beats };
    clip.count = pp.copyNotes(&clip.notes);
    app.piano_clip = clip;
    app.setStatus("yanked {d} notes ({d:.0} beats)", .{ clip.count, clip.length_beats });
}

/// Replace this track's pattern with the yanked one.
fn paste(app: *App) void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const pp = if (app.session.racks.items[app.piano_track].pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;
    if (app.piano_clip) |*clip| {
        history.push(app, history.captureMelodic(app, app.piano_track));
        pp.setNotes(clip.notes[0..clip.count], clip.length_beats);
        app.setStatus("pasted {d} notes ({d:.0} beats)", .{ clip.count, clip.length_beats });
        syncLinkedClip(app);
    } else app.setStatus("nothing yanked — y copies the pattern", .{});
}

fn deleteNote(app: *App) void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const pp = if (app.session.racks.items[app.piano_track].pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;
    const start_beat = @as(f64, @floatFromInt(app.piano_cursor_step)) * 0.25;
    if (!pp.noteStartsAt(app.piano_cursor_pitch, start_beat)) return;
    history.push(app, history.captureMelodic(app, app.piano_track));
    pp.removeNote(app.piano_cursor_pitch, start_beat);
    var nbuf: [5]u8 = undefined;
    app.setStatus("removed {s}", .{midi.noteName(app.piano_cursor_pitch, &nbuf)});
    syncLinkedClip(app);
}

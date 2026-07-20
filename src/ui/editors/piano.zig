//! Piano-roll input: note cursor, insert/delete/resize, velocity, yank/paste,
//! loop length, the shared vim grammar (docs/editing-grammar.md), and the
//! Ableton-style clip-link writeback (edits on a linked arrangement clip
//! land in the clip itself). The render half lives in views/piano.zig.

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
const theory = ws.theory;
const step_grid = @import("step_grid.zig");

/// Steps per beat as f64, driven by `App.piano_grid` (`T` toggles it).
fn stepsPerBeatF(app: *App) f64 {
    return @floatFromInt(app.pianoStepsPerBeat());
}

/// Convert a step index to a beat position under the current grid.
fn stepToBeat(app: *App, step: u16) f64 {
    return @as(f64, @floatFromInt(step)) / stepsPerBeatF(app);
}

/// `app.piano_track`'s PatternPlayer, or null if the track index is stale
/// (a deleted track) or the track isn't a melodic instrument - the guard
/// every piano-roll edit/query starts with, used as `orelse return`/
/// `orelse return false` at each call site.
fn currentPatternPlayer(app: *App) ?*pattern_mod.PatternPlayer {
    if (app.piano_track >= app.session.racks.items.len) return null;
    const rack = app.session.racks.items[app.piano_track];
    if (rack.pattern_player == null) return null;
    return &app.session.racks.items[app.piano_track].pattern_player.?;
}

pub fn switchTo(app: *App, track: u16) void {
    if (track >= app.session.racks.items.len) return;
    switch (app.session.racks.items[track].instrument) {
        .poly_synth, .sampler, .soundfont => {},
        else => {
            app.setStatus("piano roll: melodic tracks only", .{});
            return;
        },
    }
    app.piano_track = track;
    app.piano_cursor_step = 0;
    app.piano_scroll_step = 0;
    // Existing patterns should open on musical content instead of an empty
    // C4 viewport. The earliest note is a stable, useful starting point and
    // leaves genuinely empty patterns at the familiar C4 origin.
    if (app.session.racks.items[track].pattern_player) |*pp| {
        if (pp.note_count > 0) {
            var first = pp.notes[0];
            for (pp.notes[1..pp.note_count]) |note| {
                if (note.start_beat < first.start_beat) first = note;
            }
            app.piano_cursor_step = @intFromFloat(@round(first.start_beat * stepsPerBeatF(app)));
            app.piano_cursor_pitch = first.pitch;
        }
    }
    // Center the 16-row viewport on the cursor pitch.
    app.piano_scroll_pitch = @intCast(@min(@as(u32, app.piano_cursor_pitch) + 8, 127));
    // A plain open edits the live pattern; the arrangement's editClip re-links after.
    app.piano_clip_link = null;
    app.piano_grab = false;
    app.piano_stamp = false;
    app.view = .piano_roll;
}

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const pp = currentPatternPlayer(app) orelse return false;

    const max_step: u16 = @intFromFloat(pp.length_beats * stepsPerBeatF(app));

    // Visual mode: a step-range selection spanning every pitch. Motions and
    // range y/d/p live in handleVisual; everything else is swallowed so a
    // stray keypress can't jump views mid-selection.
    if (app.modal.mode == .visual) return handleVisual(app, key, pp, max_step);

    // zig fmt: off
    // Operator-pending: d/y + time motion, shared grammar
    // (docs/editing-grammar.md). Line tier is per-pitch here: dd clears
    // just the cursor pitch's row; yy stays the whole-pattern yank.
    if (app.piano_op_pending) |op| {
        app.piano_op_pending = null;
        switch (key) {
            .escape => { app.piano_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            .char => |c| switch (c) {
                '0'...'9' => { app.piano_op_pending = op; return false; },
                'd', 'y' => {
                    if (c == op) {
                        if (op == 'd') clearPitchRow(app) else yank(app);
                    } else app.setStatus("cancelled", .{});
                    return true;
                },
                'h' => { moveStep(app, max_step, -app.takeCount()); finishOperator(app, pp, op); return true; },
                'l' => { moveStep(app, max_step, app.takeCount()); finishOperator(app, pp, op); return true; },
                'H' => { moveStep(app, max_step, -4 * app.takeCount()); finishOperator(app, pp, op); return true; },
                'L' => { moveStep(app, max_step, 4 * app.takeCount()); finishOperator(app, pp, op); return true; },
                'g' => { app.piano_cursor_step = 0; ensureVisible(app); finishOperator(app, pp, op); return true; },
                'G' => {
                    if (max_step > 0) app.piano_cursor_step = max_step - 1;
                    ensureVisible(app);
                    finishOperator(app, pp, op);
                    return true;
                },
                // dw/yw act on exactly the beat(s) from the cursor through
                // the end of the nth beat forward - not through w's raw
                // landing step (the *next* beat's first step), which would
                // bleed one step into it. Mirrors vim's own dw: the motion
                // still lands past the boundary for plain navigation, but
                // an operator stops just short of it.
                'w' => { operatorBarForward(app, max_step, app.takeCount()); finishOperator(app, pp, op); return true; },
                // db/yb act on the beat(s) from the start of the nth beat
                // back through the original cursor (inclusive) - the
                // anchor already holds that original position.
                'b' => { operatorBarBackward(app, max_step, app.takeCount()); finishOperator(app, pp, op); return true; },
                else => { app.piano_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            },
            else => { app.piano_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
        }
    }

    // Note-grab mode: M holds the note under the cursor and h/l/j/k drag it
    // (the cursor follows). esc or M drop it; any other key drops it first
    // and is then handled normally below.
    if (app.piano_grab) {
        switch (key) {
            .escape => { dropGrab(app); app.setStatus("note dropped", .{}); return true; },
            .char => |c| switch (c) {
                'h' => { dragNote(app, pp, max_step, -1, 0); return true; },
                'l' => { dragNote(app, pp, max_step, 1, 0); return true; },
                'j' => { dragNote(app, pp, max_step, 0, -1); return true; },
                'k' => { dragNote(app, pp, max_step, 0, 1); return true; },
                'M' => { dropGrab(app); app.setStatus("note dropped", .{}); return true; },
                else => dropGrab(app),
            },
            else => dropGrab(app),
        }
    }

    // Note-stamp mode: enter on an empty cell inserts a note and starts a
    // live-shaping session mirroring grab mode above - j/k drag its pitch
    // (cursor follows, via the same dragNote), h/l resize its length (via
    // the same resizeOrLen `[`/`]` already use). enter/esc drop it; any
    // other key drops it first and is then handled normally below.
    if (app.piano_stamp) {
        switch (key) {
            .escape => { dropStamp(app); app.setStatus("note dropped", .{}); return true; },
            .enter => { dropStamp(app); app.setStatus("note dropped", .{}); return true; },
            .char => |c| switch (c) {
                'j' => { dragNote(app, pp, max_step, 0, -1); return true; },
                'k' => { dragNote(app, pp, max_step, 0, 1); return true; },
                'h' => { resizeOrLen(app, -1.0 / stepsPerBeatF(app)); return true; },
                'l' => { resizeOrLen(app, 1.0 / stepsPerBeatF(app)); return true; },
                else => dropStamp(app),
            },
            else => dropStamp(app),
        }
    }

    switch (key) {
        .escape => { app.view = .tracks; return true; },
        // enter toggles the note; a fresh insert starts a stamp session
        // (see above); space falls through to transport play/pause.
        .enter => { toggleOrStamp(app, pp); return true; },
        .ctrl_r => { history.doRedo(app); return true; },
        .char => |c| switch (c) {
            // 'i' falls through to modal.handle below, which enters insert
            // mode - App.handleKey then stops routing keys through this
            // switch at all (see the piano_roll case) so the piano-keyboard
            // layout owns h/j/k/l instead of roll navigation. That's what
            // makes recordNote below reachable: play a take while the
            // transport rolls and it's written into the pattern, quantized
            // to the same grid as every other roll edit.
            // fine move by one step; shift (HL) jumps one beat (4 steps).
            // All motions take a vim count prefix (3l, 12h, …).
            'h' => { moveStep(app, max_step, -app.takeCount()); return true; },
            'l' => { moveStep(app, max_step, app.takeCount()); return true; },
            'H' => { moveStep(app, max_step, -4 * app.takeCount()); return true; },
            'L' => { moveStep(app, max_step, 4 * app.takeCount()); return true; },
            'j' => { movePitch(app, -app.takeCount()); return true; },
            'k' => { movePitch(app, app.takeCount()); return true; },
            // J/K jump an octave (mirrors h/l → H/L coarse-move pattern).
            'J' => { movePitch(app, -12 * app.takeCount()); return true; },
            'K' => { movePitch(app, 12 * app.takeCount()); return true; },
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
            // w/b: vim's word motion, one tier up from h/l's step ("char")
            // granularity - jump to the start of the next/current-or-
            // previous beat (matches the drum grid's own w/b granularity).
            'w' => { jumpBar(app, max_step, app.takeCount()); return true; },
            'b' => { jumpBar(app, max_step, -app.takeCount()); return true; },
            // M grabs the note under the cursor for dragging (see above).
            'M' => {
                const start_beat = stepToBeat(app, app.piano_cursor_step);
                if (pp.noteAt(app.piano_cursor_pitch, start_beat) == null) {
                    app.setStatus("no note under cursor", .{});
                    return true;
                }
                // One grab = one undo entry, however far the drag goes.
                history.push(app, history.captureMelodic(app, app.piano_track));
                app.piano_grab = true;
                app.piano_grab_delta = .{};
                app.setStatus("moving note - h/l/j/k drag, esc drops", .{});
                return true;
            },
            // </> nudge the velocity of the note under the cursor (count-scaled).
            '<' => { nudgeVelocity(app, -0.1 * @as(f32, @floatFromInt(app.takeCount()))); return true; },
            '>' => { nudgeVelocity(app, 0.1 * @as(f32, @floatFromInt(app.takeCount()))); return true; },
            '.' => { repeatLastEdit(app, pp, max_step); return true; },
            'c' => { stampChord(app, false); return true; },
            'C' => { stampChord(app, true); return true; },
            'y' => { armOperator(app, 'y'); return true; },
            // p/P both paste the most recent yank (no linewise before/after
            // distinction): after yy a whole-pattern replace, after a
            // visual/operator range yank the range lands at the cursor step.
            'p', 'P' => {
                if (app.piano_last_yank == .range) pasteSelection(app, pp) else paste(app);
                return true;
            },
            'v' => {
                app.piano_visual_anchor = app.piano_cursor_step;
                app.modal.mode = .visual;
                app.setStatus("visual: hjkl extend, y/d/p act on the range, esc cancels", .{});
                return true;
            },
            's' => { spectrum.switchToTrack(app, app.piano_track); return true; },
            // Step entry: n places a note and advances by its length; N leaves
            // a rest of the same size. Enter remains the stationary toggle.
            'n' => { stepEnter(app, max_step, true); return true; },
            'N' => { stepEnter(app, max_step, false); return true; },
            // x: vim's char-delete - the note under the cursor, instantly,
            // no operator needed (the "char" tier of the note/beat/pattern
            // hierarchy; see the operator-pending block above).
            'x' => { deleteNote(app); return true; },
            // d is an operator (see armOperator) - dd clears the cursor
            // pitch's row, d + a motion (h/l/H/L/g/G/w/b) clears the range
            // it covers.
            'd' => { armOperator(app, 'd'); return true; },
            'a' => {
                app.playNote(app.piano_track, app.piano_cursor_pitch, app.now_ns);
                var nbuf: [5]u8 = undefined;
                app.setStatus("preview: {s}", .{midi.noteName(app.piano_cursor_pitch, &nbuf)});
                return true;
            },
            'e' => {
                // Jump to the instrument editor for this track (synth, sampler, or soundfont).
                switch (app.session.racks.items[app.piano_track].instrument) {
                    .sampler => {
                        app.sampler_target = .{ .sampler = app.piano_track };
                        app.sampler_param = 0;
                        app.view = .sampler_editor;
                    },
                    .soundfont => {
                        app.soundfont_track = app.piano_track;
                        app.soundfont_param = 0;
                        app.view = .soundfont_editor;
                    },
                    else => {
                        app.synth_track = app.piano_track;
                        app.synth_cursor = 0;
                        app.synth_subview = .main;
                        synth.updateScroll(app);
                        app.view = .synth_editor;
                    },
                }
                return true;
            },
            // [/] resize the note under the cursor if one starts here;
            // otherwise they set the default length for newly placed notes.
            // Count-scaled, like </>.
            '[' => { resizeOrLen(app, -1.0 / stepsPerBeatF(app) * @as(f64, @floatFromInt(app.takeCount()))); return true; },
            ']' => { resizeOrLen(app, 1.0 / stepsPerBeatF(app) * @as(f64, @floatFromInt(app.takeCount()))); return true; },
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
            'T' => { toggleGrid(app); return true; },
            'z' => { zoom(app, 1); return true; },
            'Z' => { zoom(app, -1); return true; },
            else => return false,
        },
        else => return false,
    }
}
// zig fmt: on

/// Drag the grabbed note by `dstep` steps / `dpitch` semitones, cursor in
/// tow, and write the edit through to a linked clip. Ends the grab if the
/// note vanished from under the cursor (shouldn't happen - belt and braces).
/// Accumulates the session's total offset in `piano_grab_delta` so `.` can
/// repeat the whole drag (as one transformation) once it's dropped.
fn dragNote(app: *App, pp: *pattern_mod.PatternPlayer, max_step: u16, dstep: i32, dpitch: i32) void {
    const start_beat = stepToBeat(app, app.piano_cursor_step);
    const n = pp.noteAt(app.piano_cursor_pitch, start_beat) orelse {
        app.piano_grab = false;
        app.setStatus("no note under cursor", .{});
        return;
    };
    const top = @max(@as(i32, max_step) - 1, 0);
    const new_step: u16 = @intCast(std.math.clamp(@as(i32, app.piano_cursor_step) + dstep, 0, top));
    const new_pitch: u7 = @intCast(std.math.clamp(@as(i32, app.piano_cursor_pitch) + dpitch, 0, 127));
    n.start_beat = stepToBeat(app, new_step);
    n.pitch = new_pitch;
    app.piano_cursor_step = new_step;
    app.piano_cursor_pitch = new_pitch;
    app.piano_grab_delta.dstep += dstep;
    app.piano_grab_delta.dpitch += dpitch;
    ensureVisible(app);
    var nbuf: [5]u8 = undefined;
    app.setStatus("moving {s} @ step {d}", .{ midi.noteName(new_pitch, &nbuf), new_step + 1 });
    syncLinkedClip(app);
}

/// Drop the grabbed note, committing the session's total offset as the
/// repeatable edit if the note actually moved.
fn dropGrab(app: *App) void {
    app.piano_grab = false;
    if (app.piano_grab_delta.dstep != 0 or app.piano_grab_delta.dpitch != 0) {
        app.last_edit = .{ .piano_drag = .{
            .dstep = app.piano_grab_delta.dstep,
            .dpitch = app.piano_grab_delta.dpitch,
        } };
    }
}

/// `.` after a drag: move whichever note sits under the CURRENT cursor by
/// the same (dstep, dpitch) offset the last drag ended with.
fn repeatDrag(app: *App, pp: *pattern_mod.PatternPlayer, max_step: u16, dstep: i32, dpitch: i32) void {
    const start_beat = stepToBeat(app, app.piano_cursor_step);
    const n = pp.noteAt(app.piano_cursor_pitch, start_beat) orelse {
        app.setStatus("no note under cursor to repeat the move on", .{});
        return;
    };
    history.push(app, history.captureMelodic(app, app.piano_track));
    const top = @max(@as(i32, max_step) - 1, 0);
    const new_step: u16 = @intCast(std.math.clamp(@as(i32, app.piano_cursor_step) + dstep, 0, top));
    const new_pitch: u7 = @intCast(std.math.clamp(@as(i32, app.piano_cursor_pitch) + dpitch, 0, 127));
    n.start_beat = stepToBeat(app, new_step);
    n.pitch = new_pitch;
    app.piano_cursor_step = new_step;
    app.piano_cursor_pitch = new_pitch;
    ensureVisible(app);
    syncLinkedClip(app);
    app.setStatus("repeated move", .{});
}

/// `.`: replay the last compound edit (nudge, resize, drag, or a visual
/// range delete/paste) at the current cursor. No-op ("nothing to repeat")
/// if the last edit came from a different editor or there wasn't one.
fn repeatLastEdit(app: *App, pp: *pattern_mod.PatternPlayer, max_step: u16) void {
    switch (app.last_edit) {
        .piano_nudge_velocity => |v| nudgeVelocity(app, v.delta),
        .piano_resize => |v| resizeOrLen(app, v.delta),
        .piano_drag => |v| repeatDrag(app, pp, max_step, v.dstep, v.dpitch),
        .piano_range_delete => |v| {
            const hi: u16 = @min(if (max_step > 0) max_step - 1 else 0, app.piano_cursor_step + v.width - 1);
            app.piano_visual_anchor = hi;
            deleteSelection(app, pp);
        },
        .piano_range_paste => pasteSelection(app, pp),
        else => app.setStatus("nothing to repeat", .{}),
    }
}

/// Move the step cursor by `delta` steps, clamped to the loop.
fn moveStep(app: *App, max_step: u16, delta: i32) void {
    const top = @max(@as(i64, max_step) - 1, 0);
    app.piano_cursor_step = @intCast(clampDelta(app.piano_cursor_step, delta, top));
    ensureVisible(app);
}

fn clampDelta(value: anytype, delta: i32, top: i64) i64 {
    return std.math.clamp(@as(i64, value) + @as(i64, delta), 0, top);
}

/// Move the pitch cursor by `delta` semitones, clamped to the MIDI range.
fn movePitch(app: *App, delta: i32) void {
    app.piano_cursor_pitch = @intCast(clampDelta(app.piano_cursor_pitch, delta, 127));
    ensureVisible(app);
}

/// `T`: toggle the piano-roll grid between straight sixteenths (4 steps/
/// beat) and sixteenth-note triplets (6 steps/beat). Rescales the cursor
/// step by its beat position so the view stays put on the same instant
/// rather than jumping to an unrelated step index, and resets the default
/// note length to one step of the new grid. Not undoable - a display/
/// editing-grid setting, not song content (mirrors `piano_scale`).
fn toggleGrid(app: *App) void {
    const old_beat = stepToBeat(app, app.piano_cursor_step);
    app.piano_grid = if (app.piano_grid == .straight) .triplet else .straight;
    app.piano_cursor_step = @intFromFloat(@round(old_beat * stepsPerBeatF(app)));
    app.piano_note_len = 1.0 / stepsPerBeatF(app);
    ensureVisible(app);
    app.setStatus("grid: {s}", .{if (app.piano_grid == .triplet) "triplet (6/beat)" else "straight (4/beat)"});
}

/// `z`/`Z`: enlarge/compact horizontal cells without moving step indices.
fn zoom(app: *App, delta: i8) void {
    const old_beat = stepToBeat(app, app.piano_cursor_step);
    app.piano_grid = .straight;
    app.piano_division = if (delta > 0) app.piano_division.finer() else app.piano_division.coarser();
    app.piano_cursor_step = @intFromFloat(@round(old_beat * stepsPerBeatF(app)));
    app.piano_note_len = 1.0 / stepsPerBeatF(app);
    ensureVisible(app);
    app.setStatus("grid: {s}", .{app.piano_division.label()});
}

// zig fmt: off
fn ensureVisible(app: *App) void {
    // Compact packs 3x the steps into the same screen width, so widen the
    // autoscroll window to match (both are rough approximations, independent
    // of the real terminal width like the pre-existing `16` was).
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
/// otherwise add one with the current note length and start a live-shaping
/// stamp session (see the `piano_stamp` block in handleKey) so a drawing
/// pass can shape each note right after placing it instead of coming back
/// later. Mirrors the drum grid's enter-to-toggle so both grid editors
/// share the same place/erase gesture.
fn toggleOrStamp(app: *App, pp: *pattern_mod.PatternPlayer) void {
    const start_beat = stepToBeat(app, app.piano_cursor_step);
    if (pp.noteStartsAt(app.piano_cursor_pitch, start_beat)) {
        deleteNote(app);
        return;
    }
    insertNote(app);
    app.piano_stamp = true;
    app.piano_grab_delta = .{};
    app.setStatus("stamping - j/k pitch, h/l length, enter/esc drops", .{});
}

/// Drop a live-shaping stamp session, recording its accumulated pitch drag
/// (if any) as the repeatable edit - shares `piano_grab`'s own delta/
/// last_edit bookkeeping since stamp's j/k reuses `dragNote` verbatim.
fn dropStamp(app: *App) void {
    app.piano_stamp = false;
    dropGrab(app);
}

/// `c`/`C`: stamp a diatonic triad (`c`) or seventh chord (`C`) rooted at the
/// cursor pitch, using the active `:scale` to harmonize it correctly (e.g.
/// `c` on the 2nd degree of C major stacks D-F-A). With no scale set,
/// defaults to a plain major shape rooted at the cursor note. A single-key
/// edit - like insert/toggle/delete - so it's not part of `.` repeat; press
/// it again at a new cursor.
fn stampChord(app: *App, seventh: bool) void {
    const pp = currentPatternPlayer(app) orelse return;
    const scale = app.piano_scale orelse
        theory.Scale{ .root = @intCast(app.piano_cursor_pitch % 12), .kind = .major };
    const chord = scale.chordAt(app.piano_cursor_pitch, seventh);
    history.push(app, history.captureMelodic(app, app.piano_track));
    const start_beat = stepToBeat(app, app.piano_cursor_step);
    for (chord.pitches[0..chord.count]) |pitch| {
        pp.removeNote(pitch, start_beat);
        pp.addNote(.{ .pitch = pitch, .start_beat = start_beat, .duration_beat = app.piano_note_len });
    }
    app.setStatus("chord: {d} notes", .{chord.count});
    syncLinkedClip(app);
}

/// Live recording: called from `App.applyAction`'s `.note` handler whenever
/// insert mode plays a note on `app.piano_track`. Only writes something if
/// the transport is actually rolling - a stopped transport has no playhead
/// to quantize against, so insert mode is pure audition in that case, same
/// as everywhere else it's used. Quantizes to the playhead's current 16th
/// step (the same grid `insertNote`/step-edit use) and skips a step that
/// already has a note starting on this pitch rather than stacking a
/// duplicate. Cursor follows the recorded note so the roll shows where the
/// take is landing in real time.
pub fn recordNote(app: *App, pitch: u7, velocity: f32) void {
    const pp = currentPatternPlayer(app) orelse return;
    const snap = app.session.engine.uiSnapshot();
    if (!snap.playing) return;
    const sr: f64 = @floatFromInt(app.session.project.sample_rate);
    const bpm: f64 = app.session.project.tempo_bpm;
    const raw_beats: f64 = @as(f64, @floatFromInt(snap.position_frames)) / (sr * 60.0 / bpm);
    const step: u16 = @intFromFloat(@mod(raw_beats, pp.length_beats) * stepsPerBeatF(app));
    const start_beat = stepToBeat(app, step);
    if (pp.noteStartsAt(pitch, start_beat)) return;
    history.push(app, history.captureMelodic(app, app.piano_track));
    pp.addNote(.{ .pitch = pitch, .start_beat = start_beat, .duration_beat = app.piano_note_len, .velocity = velocity });
    app.piano_cursor_step = step;
    app.piano_cursor_pitch = pitch;
    ensureVisible(app);
    syncLinkedClip(app);
}

fn insertNote(app: *App) void {
    const pp = currentPatternPlayer(app) orelse return;
    const start_beat = stepToBeat(app, app.piano_cursor_step);
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

/// `n`/`N`: enter a note or rest, then advance by the current default note
/// length. This makes a monophonic line a single-key workflow while Enter
/// remains available for stationary toggles and chord construction.
fn stepEnter(app: *App, max_step: u16, place_note: bool) void {
    if (place_note) insertNote(app);
    const advance: i32 = @max(1, @as(i32, @intFromFloat(@round(app.piano_note_len * stepsPerBeatF(app)))));
    moveStep(app, max_step, advance);
    if (!place_note) {
        app.setStatus("rest: advanced {d} step{s}", .{ advance, if (advance == 1) "" else "s" });
    }
}

/// Resize the note starting under the cursor by `delta` beats (clamped to
/// the loop length), or - if no note starts here - change the default length
/// applied to newly placed notes.
fn resizeOrLen(app: *App, delta: f64) void {
    const pp = currentPatternPlayer(app) orelse return;
    const start_beat = stepToBeat(app, app.piano_cursor_step);
    app.last_edit = .{ .piano_resize = .{ .delta = delta } };
    if (pp.noteAt(app.piano_cursor_pitch, start_beat)) |n| {
        history.push(app, history.captureMelodic(app, app.piano_track));
        n.duration_beat = std.math.clamp(n.duration_beat + delta, 1.0 / stepsPerBeatF(app), pp.length_beats);
        app.setStatus("note len: {d:.2} beats", .{n.duration_beat});
        syncLinkedClip(app);
    } else {
        app.piano_note_len = std.math.clamp(app.piano_note_len + delta, 1.0 / stepsPerBeatF(app), pp.length_beats);
        app.setStatus("default len: {d:.2} beats", .{app.piano_note_len});
    }
}

/// GUI drag adapter: move one note through the same history, cursor, status,
/// and linked-clip path as keyboard grab mode.
pub fn moveNoteTo(app: *App, source_pitch: u7, source_step: u16, target_pitch: u7, target_step: u16) bool {
    const pp = currentPatternPlayer(app) orelse return false;
    const max_step: u16 = @intFromFloat(pp.length_beats * stepsPerBeatF(app));
    app.piano_cursor_pitch = source_pitch;
    app.piano_cursor_step = source_step;
    if (pp.noteAt(source_pitch, stepToBeat(app, source_step)) == null) return false;
    const dstep = @as(i32, target_step) - @as(i32, source_step);
    const dpitch = @as(i32, target_pitch) - @as(i32, source_pitch);
    if (dstep == 0 and dpitch == 0) return false;
    history.push(app, history.captureMelodic(app, app.piano_track));
    app.piano_grab = true;
    app.piano_grab_delta = .{};
    dragNote(app, pp, max_step, dstep, dpitch);
    dropGrab(app);
    return true;
}

/// GUI resize adapter: set a note's grid length with one undo entry and the
/// same linked-clip writeback used by `[` and `]`.
pub fn resizeNoteSteps(app: *App, pitch: u7, start_step: u16, duration_steps: u16) bool {
    const pp = currentPatternPlayer(app) orelse return false;
    app.piano_cursor_pitch = pitch;
    app.piano_cursor_step = start_step;
    const note = pp.noteAt(pitch, stepToBeat(app, start_step)) orelse return false;
    const wanted = @as(f64, @floatFromInt(@max(duration_steps, 1))) / stepsPerBeatF(app);
    const delta = wanted - note.duration_beat;
    if (@abs(delta) < 1e-9) return false;
    resizeOrLen(app, delta);
    return true;
}

/// Nudge the velocity of the note under the cursor by `delta` (clamped 0.05–1).
fn nudgeVelocity(app: *App, delta: f32) void {
    const pp = currentPatternPlayer(app) orelse return;
    const start_beat = stepToBeat(app, app.piano_cursor_step);
    if (pp.noteAt(app.piano_cursor_pitch, start_beat)) |n| {
        history.push(app, history.captureMelodic(app, app.piano_track));
        n.velocity = std.math.clamp(n.velocity + delta, 0.05, 1.0);
        app.last_edit = .{ .piano_nudge_velocity = .{ .delta = delta } };
        app.setStatus("velocity: {d:.0}%", .{n.velocity * 100.0});
        syncLinkedClip(app);
    } else {
        app.setStatus("no note under cursor", .{});
    }
}
// zig fmt: on

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
        app.setStatus("clip gone - editing the live pattern now", .{});
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

// zig fmt: off
/// Yank the piano roll's whole pattern (notes + loop length) to the
/// app clipboard.
fn yank(app: *App) void {
    const pp = currentPatternPlayer(app) orelse return;
    var clip: PianoClip = .{ .notes = undefined, .count = 0, .length_beats = pp.length_beats };
    clip.count = pp.copyNotes(&clip.notes);
    app.piano_clip = clip;
    app.piano_last_yank = .pattern;
    app.setStatus("yanked {d} notes ({d:.0} beats)", .{ clip.count, clip.length_beats });
}

/// dd: delete every note on the cursor pitch's row - vim's line-delete,
/// where a "line" is one pitch across the whole pattern. Whole-pattern
/// clears are :clear or a full-range visual d; pitch-by-time selections
/// are visual mode's job.
fn clearPitchRow(app: *App) void {
    const pp = currentPatternPlayer(app) orelse return;
    var nbuf: [8]u8 = undefined;
    const name = midi.noteName(app.piano_cursor_pitch, &nbuf);
    // Capture before the edit, but only push it if something was actually
    // removed - a dd on an empty row shouldn't dirty or record a no-op step.
    var entry = history.captureMelodic(app, app.piano_track);
    const removed = pp.removeNotesAtPitch(app.piano_cursor_pitch);
    if (removed == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("no notes on {s}", .{name});
        return;
    }
    history.push(app, entry);
    app.setStatus("cleared {d} notes on {s}", .{ removed, name });
    syncLinkedClip(app);
}
// zig fmt: on

/// "Bar" length in steps under the current grid (straight/triplet) - despite
/// the name, this is one BEAT (stepsPerBeatF steps), matching the drum
/// grid's own hardcoded 4-step word-tier group and the status line's own
/// "bar X.Y" reading (which is a beat count, not a real musical bar - see
/// drawPianoRollStatus in views/piano.zig). Previously multiplied by
/// beats_per_bar for a real musical bar, but that made w/b jump 4x further
/// than the status line's own "bar" number implied and than the drum grid's
/// equivalent motion - user correction: w/b should match the drum machine's
/// granularity, one displayed unit at a time.
fn barLenSteps(app: *App) u16 {
    return app.pianoStepsPerBeat();
}

/// w/b: jump the cursor `delta` beats forward/back (vim's word motion, one
/// tier up from h/l's step granularity) - snaps to the nearest beat boundary
/// first, then moves whole beats from there.
fn jumpBar(app: *App, max_step: u16, delta: i32) void {
    step_grid.jumpBar(&app.piano_cursor_step, delta, max_step, barLenSteps(app));
    ensureVisible(app);
}

/// dw/yw's range end: the last step of the nth beat forward (inclusive),
/// not w's own landing step (the *next* beat's first step): vim's dw
/// word-end nuance, see docs/editing-grammar.md.
fn operatorBarForward(app: *App, max_step: u16, n: i32) void {
    step_grid.operatorBarForward(&app.piano_cursor_step, n, max_step, barLenSteps(app));
}

/// db/yb's range start: the first step of the nth beat back - the anchor
/// (the cursor's position when `d`/`y` was pressed) stays the range's other
/// (inclusive) end, so this covers "back to the start of this-or-an-
/// earlier beat, through where you started."
fn operatorBarBackward(app: *App, max_step: u16, n: i32) void {
    step_grid.operatorBarBackward(&app.piano_cursor_step, n, max_step, barLenSteps(app));
}

/// Arm `d`/`y` as a pending operator (see the operator-pending block in
/// handleKey): remembers the cursor as the range anchor, same field visual
/// mode's `v` sets, so the eventual delete/yank reuses selectionRange as-is.
fn armOperator(app: *App, op: u8) void {
    app.piano_visual_anchor = app.piano_cursor_step;
    app.piano_op_pending = op;
    if (op == 'd')
        app.setStatus("d: h/l/H/L/g/G/w/b act on the range, dd clears the cursor pitch's row", .{})
    else
        app.setStatus("y: h/l/H/L/g/G/w/b act on the range, yy yanks the whole pattern", .{});
}

/// Complete an operator+motion: run the range delete/yank between the
/// anchor `armOperator` set and the cursor's new position.
fn finishOperator(app: *App, pp: *pattern_mod.PatternPlayer, op: u8) void {
    if (op == 'd') deleteSelection(app, pp) else yankSelection(app, pp);
}

// zig fmt: off
/// Visual mode's reduced key set: motions extend the selection, y/d/p act
/// on it and return to normal, escape cancels. Everything else is
/// swallowed (returns true) so it can't jump views or open another editor
/// mid-selection; digits fall through (return false) so modal.handleNormal
/// keeps accumulating the count prefix.
fn handleVisual(app: *App, key: modal_mod.Key, pp: *pattern_mod.PatternPlayer, max_step: u16) bool {
    switch (key) {
        .escape => { exitVisual(app); app.setStatus("selection cancelled", .{}); return true; },
        .char => |c| switch (c) {
            'h' => { moveStep(app, max_step, -app.takeCount()); return true; },
            'l' => { moveStep(app, max_step, app.takeCount()); return true; },
            'H' => { moveStep(app, max_step, -4 * app.takeCount()); return true; },
            'L' => { moveStep(app, max_step, 4 * app.takeCount()); return true; },
            'j' => { movePitch(app, -app.takeCount()); return true; },
            'k' => { movePitch(app, app.takeCount()); return true; },
            'J' => { movePitch(app, -12 * app.takeCount()); return true; },
            'K' => { movePitch(app, 12 * app.takeCount()); return true; },
            'w' => { jumpBar(app, max_step, app.takeCount()); return true; },
            'b' => { jumpBar(app, max_step, -app.takeCount()); return true; },
            'g' => { app.piano_cursor_step = 0; ensureVisible(app); return true; },
            'G' => { if (max_step > 0) app.piano_cursor_step = max_step - 1; ensureVisible(app); return true; },
            'y' => { yankSelection(app, pp); return true; },
            'd' => { deleteSelection(app, pp); return true; },
            'p', 'P' => { pasteSelection(app, pp); return true; },
            '0'...'9' => return false,
            else => return true,
        },
        else => return true,
    }
}
// zig fmt: on

/// Leave visual mode, clearing the anchor so the selection can't linger.
fn exitVisual(app: *App) void {
    _ = app.modal.setMode(.normal);
    app.piano_visual_anchor = null;
}

fn selectionRange(app: *App) step_grid.StepRange(u16) {
    return step_grid.selectionRange(u16, app.piano_visual_anchor, app.piano_cursor_step);
}

/// Yank every note starting within the selected step range (any pitch) into
/// the range clipboard, rebased so the range's first step is beat 0.
fn yankSelection(app: *App, pp: *pattern_mod.PatternPlayer) void {
    const r = selectionRange(app);
    const lo_beat = stepToBeat(app, r.lo);
    const hi_beat = stepToBeat(app, r.hi) + 1.0 / stepsPerBeatF(app);
    var clip: PianoClip = .{ .notes = undefined, .count = 0, .length_beats = hi_beat - lo_beat };
    clip.count = pp.copyNotesInRange(lo_beat, hi_beat, &clip.notes);
    app.piano_range_clip = clip;
    app.piano_last_yank = .range;
    app.setStatus("yanked {d} notes ({d} steps)", .{ clip.count, r.hi - r.lo + 1 });
    exitVisual(app);
}

/// Delete every note starting within the selected step range (any pitch).
fn deleteSelection(app: *App, pp: *pattern_mod.PatternPlayer) void {
    const r = selectionRange(app);
    const lo_beat = stepToBeat(app, r.lo);
    const hi_beat = stepToBeat(app, r.hi) + 1.0 / stepsPerBeatF(app);
    history.push(app, history.captureMelodic(app, app.piano_track));
    const removed = pp.removeNotesInRange(lo_beat, hi_beat);
    app.last_edit = .{ .piano_range_delete = .{ .width = r.hi - r.lo + 1 } };
    app.setStatus("deleted {d} notes", .{removed});
    syncLinkedClip(app);
    exitVisual(app);
}

/// Paste the range clipboard starting at the cursor step, overwriting
/// whatever already sits at each destination pitch/step.
fn pasteSelection(app: *App, pp: *pattern_mod.PatternPlayer) void {
    const clip = app.piano_range_clip orelse {
        app.setStatus("nothing yanked - select a range and y first", .{});
        exitVisual(app);
        return;
    };
    history.push(app, history.captureMelodic(app, app.piano_track));
    const base_beat = stepToBeat(app, app.piano_cursor_step);
    for (clip.notes[0..clip.count]) |n| {
        var note = n;
        note.start_beat = std.math.clamp(base_beat + n.start_beat, 0, @max(0, pp.length_beats - 1.0 / stepsPerBeatF(app)));
        pp.removeNote(note.pitch, note.start_beat);
        pp.addNote(note);
    }
    app.last_edit = .piano_range_paste;
    app.setStatus("pasted {d} notes", .{clip.count});
    syncLinkedClip(app);
    exitVisual(app);
}

// zig fmt: off
/// Replace this track's pattern with the yanked one.
fn paste(app: *App) void {
    const pp = currentPatternPlayer(app) orelse return;
    if (app.piano_clip) |*clip| {
        history.push(app, history.captureMelodic(app, app.piano_track));
        pp.setNotes(clip.notes[0..clip.count], clip.length_beats);
        app.setStatus("pasted {d} notes ({d:.0} beats)", .{ clip.count, clip.length_beats });
        syncLinkedClip(app);
    } else app.setStatus("nothing yanked - y copies the pattern", .{});
}

fn deleteNote(app: *App) void {
    const pp = currentPatternPlayer(app) orelse return;
    const start_beat = stepToBeat(app, app.piano_cursor_step);
    if (!pp.noteStartsAt(app.piano_cursor_pitch, start_beat)) return;
    history.push(app, history.captureMelodic(app, app.piano_track));
    pp.removeNote(app.piano_cursor_pitch, start_beat);
    var nbuf: [5]u8 = undefined;
    app.setStatus("removed {s}", .{midi.noteName(app.piano_cursor_pitch, &nbuf)});
    syncLinkedClip(app);
}
// zig fmt: on

// Column/row layout mirrors views/piano.zig's drawPianoRoll exactly: a
// 6-char prefix (pitch label + "│"), then one cell per step, `App.pianoCellWidth()`
// chars wide (no interleaved separators inside the cell width, unlike the
// drum grid). 3 header rows (title, beat ruler, loop/playhead marker)
// precede the note rows.
const gutter: usize = 6;
const header_rows: usize = 3;

fn stepAt(scroll_step: u16, x: usize, cw: usize) ?u16 {
    if (x < gutter) return null;
    const col: u16 = @intCast((x - gutter) / cw);
    return scroll_step + col;
}

/// Click an empty cell to insert a note there (same as enter); click an
/// existing note to grab it, same as pressing `M` - dragging then moves it
/// (reusing `dragNote`), releasing without ever dragging is a plain click
/// and toggles the note off instead (matching enter's toggle). Scroll moves
/// the pitch cursor; **shift**+scroll moves the step cursor instead.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16) void {
    _ = cols; // column count is derived from scroll + cell width, not terminal-width-dependent
    const pp = currentPatternPlayer(app) orelse return;
    const max_step: u16 = @intFromFloat(pp.length_beats * stepsPerBeatF(app));

    // zig fmt: off
    switch (ev.kind) {
        .scroll_up => { if (ev.shift) moveStep(app, max_step, -1) else movePitch(app, 1); return; },
        .scroll_down => { if (ev.shift) moveStep(app, max_step, 1) else movePitch(app, -1); return; },
        else => {},
    }
    // zig fmt: on

    if (row < header_rows) return;
    const r = row - header_rows;
    const pitch_i: i32 = @as(i32, app.piano_scroll_pitch) - @as(i32, @intCast(r));
    if (pitch_i < 0 or pitch_i > 127) return;
    const pitch: u7 = @intCast(pitch_i);
    const step = stepAt(app.piano_scroll_step, ev.x, app.pianoCellWidth()) orelse return;
    if (step >= max_step) return;

    switch (ev.kind) {
        .press => {
            // A click elsewhere ends any active grab/stamp session first -
            // otherwise it stays set (mouse input skips the keyboard-only
            // stamp/grab block in handleKey) and silently reinterprets the
            // next ordinary keystroke as a drag/resize on whatever note the
            // cursor now sits on.
            if (app.piano_stamp) dropStamp(app);
            if (app.piano_grab) dropGrab(app);
            app.piano_cursor_step = step;
            app.piano_cursor_pitch = pitch;
            const start_beat = stepToBeat(app, step);
            if (pp.noteAt(pitch, start_beat) != null) {
                app.piano_grab = true;
                app.piano_grab_delta = .{};
            } else {
                insertNote(app);
            }
        },
        .drag => {
            if (!app.piano_grab) return;
            const dstep: i32 = @as(i32, step) - @as(i32, app.piano_cursor_step);
            const dpitch: i32 = @as(i32, pitch) - @as(i32, app.piano_cursor_pitch);
            if (dstep == 0 and dpitch == 0) return;
            if (!app.piano_grab_delta.moved) {
                // First real motion of this grab - one undo entry covers
                // the whole drag, same as the keyboard `M` path.
                history.push(app, history.captureMelodic(app, app.piano_track));
                app.piano_grab_delta.moved = true;
            }
            dragNote(app, pp, max_step, dstep, dpitch);
        },
        .release => {
            if (!app.piano_grab) return;
            if (app.piano_grab_delta.moved) {
                dropGrab(app);
            } else {
                app.piano_grab = false;
                const start_beat = stepToBeat(app, app.piano_cursor_step);
                if (pp.noteStartsAt(app.piano_cursor_pitch, start_beat)) deleteNote(app);
            }
        },
        else => {},
    }
}

test "cursor deltas saturate for maximum command counts" {
    try std.testing.expectEqual(@as(i64, 127), clampDelta(@as(u7, 60), std.math.maxInt(i32), 127));
    try std.testing.expectEqual(@as(i64, 0), clampDelta(@as(u16, 12), std.math.minInt(i32), 63));
}

/// How a piano-roll row should read against the active scale (or, with no
/// scale, the plain black/white keyboard look). `.root` and `.in_scale` are
/// both scale members - a black-key scale tone (e.g. Ab in F minor) must
/// classify the same as a white-key one, or the highlight can't show scales
/// that lean on black keys (most non-C-major ones).
pub const ScaleTone = enum { root, in_scale, out_scale, unscaled_black, unscaled_white };

pub fn scaleTone(scale: ?theory.Scale, pitch: u7) ScaleTone {
    if (scale) |active| {
        if (pitch % 12 == active.root) return .root;
        return if (active.contains(pitch)) .in_scale else .out_scale;
    }
    return if (theory.isBlackKey(pitch)) .unscaled_black else .unscaled_white;
}

test "scaleTone keeps black-key scale members off the out-of-scale dim path" {
    const f_minor: theory.Scale = .{ .root = 5, .kind = .minor };
    try std.testing.expectEqual(ScaleTone.root, scaleTone(f_minor, 65));
    try std.testing.expectEqual(ScaleTone.in_scale, scaleTone(f_minor, 68));
    try std.testing.expectEqual(ScaleTone.out_scale, scaleTone(f_minor, 66));
    try std.testing.expectEqual(ScaleTone.unscaled_black, scaleTone(null, 68));
    try std.testing.expectEqual(ScaleTone.unscaled_white, scaleTone(null, 60));
}

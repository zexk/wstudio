//! Drum-grid input: step/pad cursor, step + velocity toggles, pattern
//! variants, swing, choke groups, yank/paste, visual-mode range select
//! (v, then y/d/p), and operator+motion grammar (x/w/b/d/y — see the
//! step/bar/pattern hierarchy on the operator-pending block below). The
//! render half lives in views/drum.zig; the machine itself in
//! dsp/drum_sampler.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const DrumMachine = ws.dsp.DrumMachine;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const DrumRangeClip = app_mod.DrumRangeClip;
const history = @import("../history.zig");
const spectrum = @import("spectrum.zig");

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const pad = &app.drum_cursor[0];
    const step = &app.drum_cursor[1];

    // Visual mode: a step-range selection spanning every pad. Motions and
    // range y/d/p live in handleVisual; everything else is swallowed so a
    // stray keypress can't jump views mid-selection.
    if (app.modal.mode == .visual) return handleVisual(app, key);

    // Operator-pending mode: `d`/`y` arm here (armOperator below), then a
    // step motion (h/l/H/L/g/G/w/b) deletes/yanks the range from the
    // arming point (every pad, matching the visual-mode range) — j/k (pad
    // motion) aren't valid here, same time-range-only restriction visual
    // mode's own range select has. Vim's char/word/line hierarchy maps onto
    // this editor as step (x, below) / 4-step group (w/b, dw/yw) / whole
    // pattern (dd/yy) — the same operator key again (dd/yy) clears/yanks the
    // entire pattern (every pad) rather than a zero-width range. Anything
    // else cancels.
    if (app.drum_op_pending) |op| {
        app.drum_op_pending = null;
        switch (key) {
            .escape => { app.drum_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            .char => |c| switch (c) {
                '0'...'9' => { app.drum_op_pending = op; return false; },
                'd', 'y' => {
                    if (c == op) {
                        if (op == 'd') clearWholePattern(app) else yankWholePattern(app);
                    } else app.setStatus("cancelled", .{});
                    return true;
                },
                'h' => { moveStep(app, -app.takeCount()); finishOperator(app, op); return true; },
                'l' => { moveStep(app, app.takeCount()); finishOperator(app, op); return true; },
                'H' => { moveStep(app, -4 * app.takeCount()); finishOperator(app, op); return true; },
                'L' => { moveStep(app, 4 * app.takeCount()); finishOperator(app, op); return true; },
                'g' => { app.drum_cursor[1] = 0; finishOperator(app, op); return true; },
                'G' => {
                    const dm = app.drumMachine();
                    if (dm.step_count > 0) step.* = dm.step_count - 1;
                    finishOperator(app, op);
                    return true;
                },
                // dw/yw act on exactly the bar(s) through the end of the
                // nth bar forward, not w's raw landing step (see
                // piano.zig's identical comment — same vim dw nuance).
                'w' => { operatorBarForward(app, app.takeCount()); finishOperator(app, op); return true; },
                'b' => { operatorBarBackward(app, app.takeCount()); finishOperator(app, op); return true; },
                else => { app.drum_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            },
            else => { app.drum_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
        }
    }

    switch (key) {
        .escape => { app.view = .tracks; return true; },
        // enter toggles the step; space falls through to transport play/pause.
        .enter => {
            history.push(app, history.captureDrum(app, app.drum_track));
            app.drumMachine().toggleStep(pad.*, step.*);
            return true;
        },
        .ctrl_r => { history.doRedo(app); return true; },
        .char => |c| {
            switch (c) {
                // 'i' falls through to modal.handle below (see the .char
                // default at the bottom of this switch), which enters insert
                // mode — App.handleKey then stops routing keys through this
                // switch entirely while insert mode lasts (mirrors the piano
                // roll's identical comment), so the qwerty piano-key layout
                // owns h/j/k/l instead of grid navigation. That's what makes
                // recordNote below reachable: play a take while the
                // transport rolls and pad hits land as steps, quantized to
                // the machine's own live playhead (DrumMachine.currentStep).
                // fine move by one step; shift (HL) jumps one beat (4 steps).
                // All motions take a vim count prefix (3l, 2j, …).
                'h' => moveStep(app, -app.takeCount()),
                'l' => moveStep(app, app.takeCount()),
                'H' => moveStep(app, -4 * app.takeCount()),
                'L' => moveStep(app, 4 * app.takeCount()),
                'k' => movePad(app, -app.takeCount()),
                'j' => movePad(app, app.takeCount()),
                // J/K jump a whole bank of 8 pads at once — MPC-style paging
                // rather than a smooth scroll (views/drum.zig windows the
                // grid to the cursor's bank, floor(pad/8)).
                'K' => movePad(app, -8 * app.takeCount()),
                'J' => movePad(app, 8 * app.takeCount()),
                // g/G jump the step cursor to pattern start/end, matching
                // the piano roll's convention. Choke-group cycling — that
                // used to squat on 'G' — lives on 'C' instead (see below).
                'g' => app.drum_cursor[1] = 0,
                'G' => {
                    const dm = app.drumMachine();
                    if (dm.step_count > 0) step.* = dm.step_count - 1;
                },
                // w/b: vim's word motion, one tier up from h/l's step
                // ("char") granularity — jump to the start of the
                // next/current-or-previous 4-step group (see barLenSteps).
                'w' => jumpBar(app, app.takeCount()),
                'b' => jumpBar(app, -app.takeCount()),
                'a' => {
                    _ = app.session.engine.send(.{ .note_on = .{
                        .track = app.drum_track,
                        .note = @intCast(pad.*),
                        .velocity = 0.9,
                    } });
                    app.setStatus("preview: pad {d}", .{pad.* + 1});
                },
                '-' => {
                    const dm = app.drumMachine();
                    history.push(app, history.captureDrum(app, app.drum_track));
                    dm.setStepCount(dm.step_count - 1);
                    if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                },
                '+' => {
                    history.push(app, history.captureDrum(app, app.drum_track));
                    app.drumMachine().setStepCount(app.drumMachine().step_count + 1);
                },
                'c' => {
                    const dm = app.drumMachine();
                    if (dm.stepActive(pad.*, step.*)) {
                        history.push(app, history.captureDrum(app, app.drum_track));
                        dm.cycleStepVel(pad.*, step.*);
                        app.setStatus("vel {d}%", .{DrumMachine.velPercent(dm.stepVel(pad.*, step.*))});
                    } else app.setStatus("no step here — enter places one", .{});
                },
                'v' => {
                    app.drum_visual_anchor = step.*;
                    app.modal.mode = .visual;
                    app.setStatus("visual: hjkl extend, y/d/p act on the range, esc cancels", .{});
                },
                // x: vim's char-delete — clears just the (pad, step) under
                // the cursor, instantly, no operator needed.
                'x' => clearCursorStep(app),
                // d is an operator (see armOperator) — dd clears the whole
                // pattern, d + a motion (h/l/H/L/g/G/w/b) clears the range
                // it covers.
                'd' => armOperator(app, 'd'),
                '<' => adjustSwing(app, -1.0),
                '>' => adjustSwing(app, 1.0),
                'C' => cycleChokeGroup(app, pad.*),
                'X' => {
                    history.push(app, history.captureDrum(app, app.drum_track));
                    app.drumMachine().clearPad(pad.*);
                },
                'F' => {
                    history.push(app, history.captureDrum(app, app.drum_track));
                    app.drumMachine().fillPad(pad.*);
                },
                'u' => history.doUndo(app),
                'U' => history.doRedo(app),
                'y' => armOperator(app, 'y'),
                // p/P both paste (no linewise before/after distinction for a
                // whole-pattern replace) — p is the canonical vim paste key.
                'p', 'P' => {
                    if (app.drum_clip) |clip| {
                        const dm = app.drumMachine();
                        history.push(app, history.captureDrum(app, app.drum_track));
                        dm.applyVariant(clip);
                        if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                        app.setStatus("pasted into pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
                    } else app.setStatus("nothing yanked — y copies the pattern", .{});
                },
                '.' => repeatLastEdit(app),
                '[' => { cycleVariant(app, -1); },
                ']' => { cycleVariant(app, 1); },
                'N' => {
                    const dm = app.drumMachine();
                    const src = dm.variant;
                    if (dm.variant_count < DrumMachine.max_variants)
                        history.push(app, history.captureDrum(app, app.drum_track));
                    if (dm.addVariant())
                        app.setStatus("new pattern {c} (copy of {c})", .{
                            DrumMachine.variantLetter(dm.variant),
                            DrumMachine.variantLetter(src),
                        })
                    else
                        app.setStatus("pattern bank full ({d} max)", .{DrumMachine.max_variants});
                },
                'D' => {
                    const dm = app.drumMachine();
                    if (dm.variant_count > 1)
                        history.push(app, history.captureDrum(app, app.drum_track));
                    if (dm.removeVariant()) {
                        if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                        app.setStatus("deleted pattern — now on {c}", .{DrumMachine.variantLetter(dm.variant)});
                    } else app.setStatus("can't delete the only pattern", .{});
                },
                's' => { spectrum.switchToTrack(app, app.drum_track); return true; },
                'R' => { startPadRenamePrompt(app); return true; },
                'e' => {
                    app.sampler_target = .{ .drum = app.drum_track };
                    app.sampler_param = 0;
                    app.view = .sampler_editor;
                    return true;
                },
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

/// Live recording: called from `App.applyAction`'s `.note` handler whenever
/// insert mode plays a pad on `app.drum_track` (see `App.currentTrack`'s
/// `.drum_grid` case — the note's pitch already carries the pad index,
/// wrapped mod `DrumMachine.max_pads`, same mapping the plain-audition path
/// used before this). Only writes something if the transport is actually
/// rolling — a stopped transport has no playhead to quantize against, so
/// insert mode is pure audition in that case, mirroring piano.zig's
/// `recordNote`. Quantizes to `DrumMachine.currentStep()`, the audio
/// thread's own live step counter (already correct under swing and
/// song/live mode alike, unlike recomputing from frames/tempo by hand), and
/// skips a step that's already active rather than stacking a duplicate hit.
/// Cursor follows the recorded hit so the grid shows where the take is
/// landing in real time.
pub fn recordNote(app: *App, pitch: u7) void {
    if (app.drum_track >= app.session.racks.items.len) return;
    if (app.session.racks.items[app.drum_track].instrument != .drum_machine) return;
    const snap = app.session.engine.uiSnapshot();
    if (!snap.playing) return;
    const dm = app.drumMachine();
    const pad: u8 = @intCast(pitch % DrumMachine.max_pads);
    const step = dm.currentStep();
    if (dm.stepActive(pad, step)) return;
    history.push(app, history.captureDrum(app, app.drum_track));
    setStep(dm, pad, step, true, 0);
    app.drum_cursor = .{ pad, step };
    app.setStatus("rec: pad {d} step {d}", .{ pad + 1, step + 1 });
}

/// Move the step cursor by `delta` steps, clamped to the pattern length.
fn moveStep(app: *App, delta: i32) void {
    const top = @as(i32, app.drumMachine().step_count) - 1;
    app.drum_cursor[1] = @intCast(std.math.clamp(@as(i32, app.drum_cursor[1]) + delta, 0, top));
}

/// Move the pad cursor by `delta` rows, clamped to the pad count.
fn movePad(app: *App, delta: i32) void {
    app.drum_cursor[0] = @intCast(std.math.clamp(@as(i32, app.drum_cursor[0]) + delta, 0, DrumMachine.max_pads - 1));
}

/// w/b's jump granularity: 4 steps, matching the grid's own `│` separators
/// (views/drum.zig draws one every 4 steps, independent of time signature).
/// A full musical bar (beats_per_bar * 4 steps) turned out to be too coarse
/// in practice — with the default 16-step pattern that's the whole visible
/// grid in one jump, so w/b now move by the same "decorative bar" grouping
/// the separators already show on screen.
fn barLenSteps(app: *App) u8 {
    _ = app;
    return 4;
}

/// w/b: jump the step cursor `delta` 4-step groups forward/back (vim's word
/// motion, one tier up from h/l's step granularity) — snaps to the nearest
/// group boundary first, then moves whole groups from there.
fn jumpBar(app: *App, delta: i32) void {
    const bar_len = barLenSteps(app);
    if (bar_len == 0) return;
    const cur_bar = @divFloor(@as(i32, app.drum_cursor[1]), @as(i32, bar_len));
    const target_step = (cur_bar + delta) * @as(i32, bar_len);
    const top = @as(i32, app.drumMachine().step_count) - 1;
    app.drum_cursor[1] = @intCast(std.math.clamp(target_step, 0, top));
}

/// dw/yw's range end: the last step of the nth bar forward (inclusive),
/// not w's own landing step — see piano.zig's `operatorBarForward`.
fn operatorBarForward(app: *App, n: i32) void {
    const bar_len = barLenSteps(app);
    if (bar_len == 0) return;
    const cur_bar = @divFloor(@as(i32, app.drum_cursor[1]), @as(i32, bar_len));
    const hi = (cur_bar + n) * @as(i32, bar_len) - 1;
    const top = @as(i32, app.drumMachine().step_count) - 1;
    app.drum_cursor[1] = @intCast(std.math.clamp(hi, 0, top));
}

/// db/yb's range start: the first step of the nth bar back, paired with
/// the anchor (original cursor) as the range's other end — see piano.zig's
/// `operatorBarBackward`.
fn operatorBarBackward(app: *App, n: i32) void {
    const bar_len = barLenSteps(app);
    if (bar_len == 0) return;
    const cur_bar = @divFloor(@as(i32, app.drum_cursor[1]), @as(i32, bar_len));
    const lo = (cur_bar - n + 1) * @as(i32, bar_len);
    const top = @as(i32, app.drumMachine().step_count) - 1;
    app.drum_cursor[1] = @intCast(std.math.clamp(lo, 0, top));
}

/// Arm `d`/`y` as a pending operator (see the operator-pending block in
/// handleKey): remembers the cursor step as the range anchor, same field
/// visual mode's `v` sets, so the eventual delete/yank reuses
/// selectionRange as-is.
fn armOperator(app: *App, op: u8) void {
    app.drum_visual_anchor = app.drum_cursor[1];
    app.drum_op_pending = op;
    app.setStatus("{c}: h/l/H/L/g/G/w/b act on the range, {c}{c} acts on the whole pattern", .{ op, op, op });
}

/// Complete an operator+motion: run the range delete/yank between the
/// anchor `armOperator` set and the cursor's new position.
fn finishOperator(app: *App, op: u8) void {
    if (op == 'd') deleteSelection(app) else yankSelection(app);
}

/// `x`: vim's char-delete — clears just the (pad, step) under the cursor,
/// instantly, no operator needed.
fn clearCursorStep(app: *App) void {
    const dm = app.drumMachine();
    const pad = app.drum_cursor[0];
    const step = app.drum_cursor[1];
    if (!dm.stepActive(pad, step)) { app.setStatus("no step here", .{}); return; }
    history.push(app, history.captureDrum(app, app.drum_track));
    setStep(dm, pad, step, false, 0);
    app.setStatus("cleared step", .{});
}

/// `dd`: clear the whole pattern variant (every pad) — vim's whole-line dd,
/// one tier coarser than x's single-step delete and w/b's bar range.
fn clearWholePattern(app: *App) void {
    const dm = app.drumMachine();
    history.push(app, history.captureDrum(app, app.drum_track));
    for (0..DrumMachine.max_pads) |pad_i| {
        var s: u8 = 0;
        while (s < dm.step_count) : (s += 1) setStep(dm, @intCast(pad_i), s, false, 0);
    }
    app.setStatus("cleared pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
}

/// `yy`: yank the whole current pattern variant (the pre-grammar instant
/// `y` action).
fn yankWholePattern(app: *App) void {
    const dm = app.drumMachine();
    app.drum_clip = dm.variantData(dm.variant);
    app.setStatus("yanked pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
}

/// Visual mode's reduced key set: motions extend the selection, y/d/p act
/// on it and return to normal, escape cancels. Everything else is
/// swallowed (returns true) so it can't jump views or open another editor
/// mid-selection; digits fall through (return false) so modal.handleNormal
/// keeps accumulating the count prefix.
fn handleVisual(app: *App, key: modal_mod.Key) bool {
    switch (key) {
        .escape => { exitVisual(app); app.setStatus("selection cancelled", .{}); return true; },
        .char => |c| switch (c) {
            'h' => { moveStep(app, -app.takeCount()); return true; },
            'l' => { moveStep(app, app.takeCount()); return true; },
            'H' => { moveStep(app, -4 * app.takeCount()); return true; },
            'L' => { moveStep(app, 4 * app.takeCount()); return true; },
            'j' => { movePad(app, app.takeCount()); return true; },
            'k' => { movePad(app, -app.takeCount()); return true; },
            'g' => { app.drum_cursor[1] = 0; return true; },
            'G' => {
                const dm = app.drumMachine();
                if (dm.step_count > 0) app.drum_cursor[1] = dm.step_count - 1;
                return true;
            },
            'y' => { yankSelection(app); return true; },
            'd' => { deleteSelection(app); return true; },
            'p', 'P' => { pasteSelection(app); return true; },
            '0'...'9' => return false,
            else => return true,
        },
        else => return true,
    }
}

/// Leave visual mode, clearing the anchor so the selection can't linger.
fn exitVisual(app: *App) void {
    app.modal.mode = .normal;
    app.modal.count = 0;
    app.modal.pending = null;
    app.drum_visual_anchor = null;
}

const StepRange = struct { lo: u8, hi: u8 };

fn selectionRange(app: *App) StepRange {
    const anchor = app.drum_visual_anchor orelse app.drum_cursor[1];
    return .{ .lo = @min(anchor, app.drum_cursor[1]), .hi = @max(anchor, app.drum_cursor[1]) };
}

/// Force one step to a given active/velocity state via the public toggle +
/// velocity API (no direct bitmask poking, so this stays in step with
/// whatever DrumMachine does internally on toggle). Also used by handleMouse
/// to paint a drag stroke.
pub fn setStep(dm: *DrumMachine, pad: u8, step: u8, active: bool, vel: u2) void {
    if (dm.stepActive(pad, step) != active) dm.toggleStep(pad, step);
    if (active) dm.setStepVel(pad, step, vel);
}

/// Yank every pad's steps within the selected range into the range
/// clipboard, rebased so the range's first step is bit 0.
fn yankSelection(app: *App) void {
    const dm = app.drumMachine();
    const r = selectionRange(app);
    var clip: DrumRangeClip = .{ .width = r.hi - r.lo + 1 };
    for (0..DrumMachine.max_pads) |pad| {
        var s: u8 = r.lo;
        while (s <= r.hi) : (s += 1) {
            if (!dm.stepActive(@intCast(pad), s)) continue;
            const bit = @as(u32, 1) << @intCast(s - r.lo);
            clip.active[pad] |= bit;
            const vel = dm.stepVel(@intCast(pad), s);
            if (vel & 1 != 0) clip.vel_lo[pad] |= bit;
            if (vel & 2 != 0) clip.vel_hi[pad] |= bit;
        }
    }
    app.drum_range_clip = clip;
    app.setStatus("yanked {d} steps", .{clip.width});
    exitVisual(app);
}

/// Clear every pad's steps within the selected range.
fn deleteSelection(app: *App) void {
    const dm = app.drumMachine();
    const r = selectionRange(app);
    history.push(app, history.captureDrum(app, app.drum_track));
    for (0..DrumMachine.max_pads) |pad| {
        var s: u8 = r.lo;
        while (s <= r.hi) : (s += 1) setStep(dm, @intCast(pad), s, false, 0);
    }
    app.last_edit = .{ .drum_range_delete = .{ .width = r.hi - r.lo + 1 } };
    app.setStatus("cleared {d} steps", .{r.hi - r.lo + 1});
    exitVisual(app);
}

/// Paste the range clipboard starting at the cursor step, overwriting
/// whatever already sits at each destination step (all pads).
fn pasteSelection(app: *App) void {
    const clip = app.drum_range_clip orelse {
        app.setStatus("nothing yanked — select a range and y first", .{});
        exitVisual(app);
        return;
    };
    const dm = app.drumMachine();
    history.push(app, history.captureDrum(app, app.drum_track));
    const base = app.drum_cursor[1];
    var i: u8 = 0;
    while (i < clip.width) : (i += 1) {
        const target = base +| i;
        if (target >= dm.step_count) break;
        for (0..DrumMachine.max_pads) |pad| {
            const bit = @as(u32, 1) << @intCast(i);
            const active = clip.active[pad] & bit != 0;
            const vel: u2 = (@as(u2, @intCast((clip.vel_hi[pad] & bit) >> @intCast(i))) << 1) |
                @as(u2, @intCast((clip.vel_lo[pad] & bit) >> @intCast(i)));
            setStep(dm, @intCast(pad), target, active, vel);
        }
    }
    app.last_edit = .drum_range_paste;
    app.setStatus("pasted {d} steps", .{i});
    exitVisual(app);
}

/// `.`: replay the last compound edit (a visual range delete/paste) at the
/// current cursor. No-op ("nothing to repeat") if the last edit came from a
/// different editor or there wasn't one.
fn repeatLastEdit(app: *App) void {
    switch (app.last_edit) {
        .drum_range_delete => |v| {
            const dm = app.drumMachine();
            const hi: u8 = @min(dm.step_count -| 1, app.drum_cursor[1] +| (v.width - 1));
            app.drum_visual_anchor = hi;
            deleteSelection(app);
        },
        .drum_range_paste => pasteSelection(app),
        else => app.setStatus("nothing to repeat", .{}),
    }
}

/// R opens the command prompt pre-filled with `:pad-rename <n> ` for the
/// cursor pad — type the new name and hit enter (esc cancels), same
/// mechanism as the tracks view's own rename prompt. Pad index is 1-based,
/// matching `:load-pad`'s convention and the 1-8 direct pad-select keys.
fn startPadRenamePrompt(app: *App) void {
    app.modal.mode = .command;
    app.cmd_history_pos = app.cmd_history.items.len;
    const text = std.fmt.bufPrint(&app.modal.cmd_buf, "pad-rename {d} ", .{app.drum_cursor[0] + 1}) catch return;
    app.modal.cmd_len = text.len;
    app.modal.cmd_cursor = text.len;
}

/// Nudge the drum machine's swing and echo the new value.
fn adjustSwing(app: *App, delta: f32) void {
    const dm = app.drumMachine();
    dm.adjustSwing(delta);
    app.dirty = true;
    app.setStatus("swing {d:.0}%", .{dm.swing.load(.monotonic)});
}

/// Step the cursor pad's choke group forward (none → 1..max → none). A
/// mixer-style param like swing — not undo-tracked.
fn cycleChokeGroup(app: *App, pad: u8) void {
    const dm = app.drumMachine();
    dm.cycleChokeGroup(pad);
    app.dirty = true;
    const g = dm.choke_group[pad];
    if (g == 0) app.setStatus("choke group: none", .{}) else app.setStatus("choke group: {d}", .{g});
}

/// Cycle the drum grid's active pattern variant, keeping the step cursor
/// inside the new variant's step count.
fn cycleVariant(app: *App, delta: i32) void {
    const dm = app.drumMachine();
    if (dm.variant_count <= 1) {
        app.setStatus("one pattern — N creates another", .{});
        return;
    }
    dm.cycleVariant(delta);
    app.dirty = true;
    if (app.drum_cursor[1] >= dm.step_count) app.drum_cursor[1] = dm.step_count - 1;
    app.setStatus("pattern {c} ({d}/{d})", .{
        DrumMachine.variantLetter(dm.variant), dm.variant + 1, dm.variant_count,
    });
}

/// Left-gutter width before the step grid starts — matches views/drum.zig's
/// `" {s: <8} "` pad-name column in drawDrumGrid.
const gutter: usize = 10;

/// Step index at column `x` within a pad row, or null if `x` falls in the
/// gutter or past the last visible step. Replays the exact column math
/// views/drum.zig's render loop uses (starting from `scroll`, a 1-char "│"
/// every 4 steps, then a 3-char cell) rather than deriving a closed form.
fn stepAt(scroll: u32, step_count: u8, x: usize) ?u8 {
    if (x < gutter) return null;
    var col = gutter;
    var s: u32 = scroll;
    while (s < step_count) : (s += 1) {
        if (s % 4 == 0) col += 1;
        if (x < col + 3) return if (x < col) null else @intCast(s); // `x < col`: landed on the separator itself
        col += 3;
    }
    return null;
}

/// Click a step cell to toggle it (same as enter); click the pad-name
/// gutter to just select that pad row. Dragging with the button held paints
/// (rather than toggles) every newly-entered cell to the state the initial
/// click produced — `setStep` is idempotent, so repeated motion events over
/// the same cell are harmless. Scroll moves the step cursor, or — over the
/// gutter — the pad cursor, regardless of which row the mouse sits on.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize) void {
    switch (ev.kind) {
        .scroll_up, .scroll_down => {
            const delta: i32 = if (ev.kind == .scroll_up) -1 else 1;
            if (ev.x < gutter) movePad(app, delta) else moveStep(app, delta);
            return;
        },
        else => {},
    }

    if (row < 2) return; // title / step-number header rows — see views/drum.zig
    // Row 2 is the current bank's first pad, not absolute pad 0 — mirrors
    // views/drum.zig's own bank_start = (cur_pad/8)*8 windowing.
    const bank_start = (app.drum_cursor[0] / 8) * 8;
    const pad = bank_start + (row - 2);
    if (row - 2 >= 8 or pad >= DrumMachine.max_pads) return;

    switch (ev.kind) {
        .press => {
            app.drum_cursor[0] = @intCast(pad);
            const dm = app.drumMachine();
            const step = stepAt(app.drum_step_scroll, dm.step_count, ev.x) orelse {
                app.drum_paint_state = null;
                return;
            };
            app.drum_cursor[1] = step;
            history.push(app, history.captureDrum(app, app.drum_track));
            dm.toggleStep(@intCast(pad), step);
            app.drum_paint_state = dm.stepActive(@intCast(pad), step);
        },
        .drag => {
            const state = app.drum_paint_state orelse return;
            const dm = app.drumMachine();
            const step = stepAt(app.drum_step_scroll, dm.step_count, ev.x) orelse return;
            app.drum_cursor[0] = @intCast(pad);
            app.drum_cursor[1] = step;
            setStep(dm, @intCast(pad), step, state, 0);
        },
        .release => app.drum_paint_state = null,
        else => {},
    }
}

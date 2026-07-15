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
const preset_picker = @import("preset_picker.zig");
const drum_view = @import("../views/drum.zig");
const step_grid = @import("step_grid.zig");

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const pad = &app.drum_cursor[0];
    const step = &app.drum_cursor[1];

    // Visual mode: a step-range selection spanning every pad. Motions and
    // range y/d/p live in handleVisual; everything else is swallowed so a
    // stray keypress can't jump views mid-selection.
    if (app.modal.mode == .visual) return handleVisual(app, key);

    // Operator-pending: d/y + time motion, shared grammar
    // (docs/editing-grammar.md). Line tier is per-pad here: dd clears just
    // the cursor pad's row (same as X); yy stays the whole-pattern yank.
    if (app.drum_op_pending) |op| {
        app.drum_op_pending = null;
        switch (key) {
            // zig fmt: off
            .escape => { app.drum_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            .char => |c| switch (c) {
                '0'...'9' => { app.drum_op_pending = op; return false; },
                'd', 'y' => {
                    if (c == op) {
                        if (op == 'd') clearPadRow(app) else yankWholePattern(app);
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
        // zig fmt: on
        .char => |c| {
            switch (c) {
                // 'i' falls through to modal.handle (the .char default
                // below): insert mode then owns every key as qwerty pad
                // triggers, which is what makes recordNote reachable.
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
                        app.setStatus("vel {d}", .{dm.stepVel(pad.*, step.*)});
                    } else app.setStatus("no step here — enter places one", .{});
                },
                // {/}: fine velocity nudge (±1, count-scaled) over the full
                // 1-127 range — 'c' above only cycles the named presets.
                '{' => {
                    const dm = app.drumMachine();
                    if (dm.stepActive(pad.*, step.*)) {
                        history.push(app, history.captureDrum(app, app.drum_track));
                        dm.nudgeStepVel(pad.*, step.*, -app.takeCount());
                        app.setStatus("vel {d}", .{dm.stepVel(pad.*, step.*)});
                    } else app.setStatus("no step here — enter places one", .{});
                },
                '}' => {
                    const dm = app.drumMachine();
                    if (dm.stepActive(pad.*, step.*)) {
                        history.push(app, history.captureDrum(app, app.drum_track));
                        dm.nudgeStepVel(pad.*, step.*, app.takeCount());
                        app.setStatus("vel {d}", .{dm.stepVel(pad.*, step.*)});
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
                // d is an operator (see armOperator) — dd clears the cursor
                // pad's row (like X), d + a motion (h/l/H/L/g/G/w/b) clears
                // the range it covers.
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
                // p/P both paste the most recent yank (no linewise before/
                // after distinction): after yy a whole-pattern replace,
                // after a visual/operator range yank the range lands at the
                // cursor step.
                'p', 'P' => {
                    if (app.drum_last_yank == .range) {
                        pasteSelection(app);
                    } else if (app.drum_clip) |clip| {
                        const dm = app.drumMachine();
                        history.push(app, history.captureDrum(app, app.drum_track));
                        dm.applyVariant(clip);
                        if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                        app.setStatus("pasted into pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
                    } else app.setStatus("nothing yanked — y copies the pattern", .{});
                },
                '.' => repeatLastEdit(app),
                // zig fmt: off
                '[' => { cycleVariant(app, -1); },
                ']' => { cycleVariant(app, 1); },
                // zig fmt: on
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
                // zig fmt: off
                's' => { spectrum.switchToTrack(app, app.drum_track); return true; },
                // f browses kit variants — same apply path as :drum-kit.
                'f' => { preset_picker.open(app, .drum, app.drum_track); return true; },
                'R' => { startPadRenamePrompt(app); return true; },
                // zig fmt: on
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

/// Live recording: insert-mode pad hits land here (via `App.applyAction`'s
/// `.note` handler; the pitch carries the pad index mod max_pads) while
/// the transport rolls; stopped transport = pure audition. Quantizes to
/// `DrumMachine.currentStep()`, the audio thread's own step counter
/// (already correct under swing and song/live mode alike, unlike
/// recomputing from frames/tempo by hand), skips already-active steps,
/// and moves the cursor to where the take lands.
pub fn recordNote(app: *App, pitch: u7, vel: u8) void {
    if (app.drum_track >= app.session.racks.items.len) return;
    if (app.session.racks.items[app.drum_track].instrument != .drum_machine) return;
    const snap = app.session.engine.uiSnapshot();
    if (!snap.playing) return;
    const dm = app.drumMachine();
    const pad: u8 = @intCast(pitch % DrumMachine.max_pads);
    const step = dm.currentStep();
    if (dm.stepActive(pad, step)) return;
    history.push(app, history.captureDrum(app, app.drum_track));
    setStep(dm, pad, step, true, vel);
    app.drum_cursor = .{ pad, step };
    app.setStatus("rec: pad {d} step {d}", .{ pad + 1, step + 1 });
}

/// Move the step cursor by `delta` steps, clamped to the pattern length.
fn moveStep(app: *App, delta: i32) void {
    step_grid.moveClamped(&app.drum_cursor[1], delta, app.drumMachine().step_count);
}

/// Move the pad cursor by `delta` rows, clamped to the pad count.
fn movePad(app: *App, delta: i32) void {
    step_grid.moveClamped(&app.drum_cursor[0], delta, DrumMachine.max_pads);
}

/// w/b: jump the step cursor `delta` 4-step groups forward/back — see
/// step_grid.jumpBar for the bar-width rationale.
fn jumpBar(app: *App, delta: i32) void {
    step_grid.jumpBar(&app.drum_cursor[1], delta, app.drumMachine().step_count);
}

/// dw/yw's range end — see step_grid.operatorBarForward.
fn operatorBarForward(app: *App, n: i32) void {
    step_grid.operatorBarForward(&app.drum_cursor[1], n, app.drumMachine().step_count);
}

/// db/yb's range start — see step_grid.operatorBarBackward.
fn operatorBarBackward(app: *App, n: i32) void {
    step_grid.operatorBarBackward(&app.drum_cursor[1], n, app.drumMachine().step_count);
}

/// Arm `d`/`y` as a pending operator (see the operator-pending block in
/// handleKey): remembers the cursor step as the range anchor, same field
/// visual mode's `v` sets, so the eventual delete/yank reuses
/// selectionRange as-is.
fn armOperator(app: *App, op: u8) void {
    app.drum_visual_anchor = app.drum_cursor[1];
    app.drum_op_pending = op;
    if (op == 'd')
        app.setStatus("d: h/l/H/L/g/G/w/b act on the range, dd clears the cursor pad's row", .{})
    else
        app.setStatus("y: h/l/H/L/g/G/w/b act on the range, yy yanks the whole pattern", .{});
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
    // zig fmt: off
    if (!dm.stepActive(pad, step)) { app.setStatus("no step here", .{}); return; }
    // zig fmt: on
    history.push(app, history.captureDrum(app, app.drum_track));
    setStep(dm, pad, step, false, 0);
    app.setStatus("cleared step", .{});
}

/// `dd`: clear every step on the cursor pad's row — vim's line-delete,
/// where a "line" is one pad across the whole pattern (the same clear `X`
/// does). Whole-pattern clears are a full-range visual d; pad-by-time
/// selections are visual mode's job.
fn clearPadRow(app: *App) void {
    const dm = app.drumMachine();
    const pad = app.drum_cursor[0];
    history.push(app, history.captureDrum(app, app.drum_track));
    dm.clearPad(pad);
    app.setStatus("cleared pad {d}'s row", .{@as(u32, pad) + 1});
}

/// `yy`: yank the whole current pattern variant (the pre-grammar instant
/// `y` action).
fn yankWholePattern(app: *App) void {
    const dm = app.drumMachine();
    app.drum_clip = dm.variantData(dm.variant);
    app.drum_last_yank = .pattern;
    app.setStatus("yanked pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
}

/// Visual mode's reduced key set: motions extend the selection, y/d/p act
/// on it and return to normal, escape cancels. Everything else is
/// swallowed (returns true) so it can't jump views or open another editor
/// mid-selection; digits fall through (return false) so modal.handleNormal
/// keeps accumulating the count prefix.
fn handleVisual(app: *App, key: modal_mod.Key) bool {
    switch (key) {
        // zig fmt: off
        .escape => { exitVisual(app); app.setStatus("selection cancelled", .{}); return true; },
        .char => |c| switch (c) {
            'h' => { moveStep(app, -app.takeCount()); return true; },
            'l' => { moveStep(app, app.takeCount()); return true; },
            'H' => { moveStep(app, -4 * app.takeCount()); return true; },
            'L' => { moveStep(app, 4 * app.takeCount()); return true; },
            'j' => { movePad(app, app.takeCount()); return true; },
            'k' => { movePad(app, -app.takeCount()); return true; },
            'J' => { movePad(app, 8 * app.takeCount()); return true; },
            'K' => { movePad(app, -8 * app.takeCount()); return true; },
            'w' => { jumpBar(app, app.takeCount()); return true; },
            'b' => { jumpBar(app, -app.takeCount()); return true; },
            'g' => { app.drum_cursor[1] = 0; return true; },
            'G' => {
                const dm = app.drumMachine();
                if (dm.step_count > 0) app.drum_cursor[1] = dm.step_count - 1;
                return true;
            },
            'y' => { yankSelection(app); return true; },
            'd' => { deleteSelection(app); return true; },
            'p', 'P' => { pasteSelection(app); return true; },
            // zig fmt: on
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

const StepRange = step_grid.StepRange;

fn selectionRange(app: *App) StepRange {
    return step_grid.selectionRange(app.drum_visual_anchor, app.drum_cursor[1]);
}

/// Force one step to a given active/velocity state via the public toggle +
/// velocity API (no direct bitmask poking, so this stays in step with
/// whatever DrumMachine does internally on toggle). Also used by handleMouse
/// to paint a drag stroke.
pub fn setStep(dm: *DrumMachine, pad: u8, step: u8, active: bool, vel: u8) void {
    step_grid.setStep(dm, pad, step, active, vel);
}

/// Yank every pad's steps within the selected range into the range
/// clipboard, rebased so the range's first step is bit 0.
fn yankSelection(app: *App) void {
    const dm = app.drumMachine();
    const r = selectionRange(app);
    const clip = step_grid.yankRange(DrumRangeClip, dm, DrumMachine.max_pads, r);
    app.drum_range_clip = clip;
    app.drum_last_yank = .range;
    app.setStatus("yanked {d} steps", .{clip.width});
    exitVisual(app);
}

/// Clear every pad's steps within the selected range.
fn deleteSelection(app: *App) void {
    const dm = app.drumMachine();
    const r = selectionRange(app);
    history.push(app, history.captureDrum(app, app.drum_track));
    step_grid.clearRange(dm, DrumMachine.max_pads, r);
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
    const n = step_grid.pasteRange(dm, DrumMachine.max_pads, clip, app.drum_cursor[1]);
    app.last_edit = .drum_range_paste;
    app.setStatus("pasted {d} steps", .{n});
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
/// matching the 1-8 direct pad-select keys.
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

/// Step index at column `x` within a pad row — see step_grid.stepAt.
fn stepAt(scroll: u32, step_count: u8, x: usize) ?u8 {
    return step_grid.stepAt(drum_view.gutter, scroll, step_count, x);
}

/// Click a step cell to toggle it (same as enter); click the pad-name
/// gutter to just select that pad row. Dragging with the button held paints
/// (rather than toggles) every newly-entered cell to the state the initial
/// click produced — `setStep` is idempotent, so repeated motion events over
/// the same cell are harmless. Scroll moves the step cursor, or — over the
/// gutter — the pad cursor, regardless of which row the mouse sits on.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, view_rows: usize) void {
    switch (ev.kind) {
        .scroll_up, .scroll_down => {
            const delta: i32 = if (ev.kind == .scroll_up) -1 else 1;
            if (ev.x < drum_view.gutter) movePad(app, delta) else moveStep(app, delta);
            return;
        },
        else => {},
    }

    if (row < 2) return; // title / step-number header rows — see views/drum.zig
    // Row 2 is the visible bank window's first pad, not absolute pad 0 —
    // mirrors views/drum.zig's bankWindowStart/banksShown windowing. A dim
    // rule separates stacked banks, so banks occupy pads_per_bank + 1 rows
    // past the first; the rule rows themselves map to no pad.
    const per_bank = drum_view.pads_per_bank;
    const rel = row - 2;
    const block = rel / (per_bank + 1);
    const within = rel % (per_bank + 1);
    if (within == per_bank) return; // the rule between stacked banks
    if (block >= drum_view.banksShown(view_rows)) return;
    const bank_start = drum_view.bankWindowStart(app.drum_cursor[0], view_rows);
    const pad = bank_start + block * per_bank + within;
    if (pad >= DrumMachine.max_pads) return;

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
            setStep(dm, @intCast(pad), step, state, DrumMachine.vel_full);
        },
        .release => app.drum_paint_state = null,
        else => {},
    }
}

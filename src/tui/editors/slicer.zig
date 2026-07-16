//! Slicer-grid input: slice/step cursor, step + velocity edits, swing,
//! chop refinement (split/merge, boundary nudges), insert-mode qwerty
//! triggering, yank/paste, visual-mode range select, and operator+motion
//! grammar - the same editing surface the drum grid gives its pads
//! (editors/drum.zig), on top of the chop-specific gestures. The render
//! half lives in views/slicer.zig; the machine itself in dsp/slicer.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const Slicer = ws.dsp.Slicer;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const SlicerRangeClip = app_mod.SlicerRangeClip;
const history = @import("../history.zig");
const slicer_view = @import("../views/slicer.zig");
const step_grid = @import("step_grid.zig");

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const slice = &app.slicer_cursor[0];
    const step = &app.slicer_cursor[1];
    const sl = app.slicerInst();

    if (app.modal.mode == .visual) return handleVisual(app, key);

    // Operator-pending: d/y + time motion, shared grammar
    // (docs/editing-grammar.md). Line tier is per-slice: dd clears just the
    // cursor slice's row (same as X); yy yanks the whole pattern as a
    // full-width range.
    if (app.slicer_op_pending) |op| {
        app.slicer_op_pending = null;
        switch (key) {
            // zig fmt: off
            .escape => { app.slicer_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            .char => |c| switch (c) {
                '0'...'9' => { app.slicer_op_pending = op; return false; },
                'd', 'y' => {
                    if (c == op) {
                        if (op == 'd') clearSliceRow(app) else yankWholePattern(app);
                    } else app.setStatus("cancelled", .{});
                    return true;
                },
                'h' => { moveStep(app, -app.takeCount()); finishOperator(app, op); return true; },
                'l' => { moveStep(app, app.takeCount()); finishOperator(app, op); return true; },
                'H' => { moveStep(app, -4 * app.takeCount()); finishOperator(app, op); return true; },
                'L' => { moveStep(app, 4 * app.takeCount()); finishOperator(app, op); return true; },
                'g' => { step.* = 0; finishOperator(app, op); return true; },
                'G' => {
                    if (sl.step_count > 0) step.* = sl.step_count - 1;
                    finishOperator(app, op);
                    return true;
                },
                'w' => { operatorBarForward(app, app.takeCount()); finishOperator(app, op); return true; },
                'b' => { operatorBarBackward(app, app.takeCount()); finishOperator(app, op); return true; },
                else => { app.slicer_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            },
            else => { app.slicer_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
        }
    }

    switch (key) {
        .escape => { app.view = .tracks; return true; },
        // enter toggles the step; space falls through to transport play/pause.
        .enter => {
            history.push(app, history.captureSlicer(app, app.slicer_track));
            sl.toggleStep(slice.*, step.*);
            return true;
        },
        .ctrl_r => { history.doRedo(app); return true; },
        // zig fmt: on
        .char => |c| {
            switch (c) {
                // 'i' falls through to modal.handle: insert mode then owns
                // every key as qwerty slice triggers (see recordNote).
                'h' => moveStep(app, -app.takeCount()),
                'l' => moveStep(app, app.takeCount()),
                'H' => moveStep(app, -4 * app.takeCount()),
                'L' => moveStep(app, 4 * app.takeCount()),
                'j' => moveSlice(app, app.takeCount()),
                'k' => moveSlice(app, -app.takeCount()),
                // J/K jump a whole bank of 8 slices - same MPC-style paging
                // as the drum grid's pads.
                'J' => moveSlice(app, 8 * app.takeCount()),
                'K' => moveSlice(app, -8 * app.takeCount()),
                'g' => step.* = 0,
                // zig fmt: off
                'G' => { if (sl.step_count > 0) step.* = sl.step_count - 1; },
                // zig fmt: on
                'n' => stepEnter(app),
                'w' => jumpBar(app, app.takeCount()),
                'b' => jumpBar(app, -app.takeCount()),
                'a' => {
                    _ = app.session.engine.send(.{ .note_on = .{
                        .track = app.slicer_track,
                        .note = @intCast(slice.*),
                        .velocity = 0.9,
                    } });
                    app.setStatus("preview: slice {d}", .{slice.* + 1});
                },
                '-' => {
                    history.push(app, history.captureSlicer(app, app.slicer_track));
                    sl.setStepCount(sl.step_count -| 1);
                    if (step.* >= sl.step_count) step.* = sl.step_count - 1;
                },
                '+' => {
                    history.push(app, history.captureSlicer(app, app.slicer_track));
                    sl.setStepCount(sl.step_count + 1);
                },
                'E' => doublePattern(app),
                'O' => sequenceSourceOrder(app),
                // Chop refinement: split the cursor slice in half / merge it
                // into the one after it - the interactive loop that turns a
                // rough :chop into the chops you actually wanted.
                's' => {
                    // Preconditions checked here so a refused split doesn't
                    // push a no-op undo entry (the capture must predate the
                    // edit, so success can't be tested first).
                    if (slice.* >= sl.slice_count) {
                        app.setStatus("nothing to split", .{});
                    } else if (sl.slice_count >= Slicer.max_slices) {
                        app.setStatus("slice limit reached ({d})", .{Slicer.max_slices});
                    } else {
                        history.push(app, history.captureSlicer(app, app.slicer_track));
                        _ = sl.splitSlice(slice.*);
                        app.setStatus("split slice {d} - now {d} slices", .{ slice.* + 1, sl.slice_count });
                    }
                },
                'm' => {
                    if (slice.* + 1 >= sl.slice_count) {
                        app.setStatus("no slice to the right to merge", .{});
                    } else {
                        history.push(app, history.captureSlicer(app, app.slicer_track));
                        _ = sl.mergeSliceRight(slice.*);
                        app.setStatus("merged into slice {d} - now {d} slices", .{ slice.* + 1, sl.slice_count });
                    }
                },
                // Per-slice boundary/reverse nudges, routed over the command
                // queue like every other instrument param (undo coalesces a
                // run on the same boundary) - the top waveform tracks them
                // live. Deeper per-slice params (pitch/ADSR/gain/pan) live
                // in the slice editor on 'e'.
                'r' => nudgeSliceParam(app, 9, 1),
                // zig fmt: off
                '[' => nudgeSliceParam(app, 0, -app.takeCount()),
                ']' => nudgeSliceParam(app, 0, app.takeCount()),
                '{' => nudgeSliceParam(app, 1, -app.takeCount()),
                '}' => nudgeSliceParam(app, 1, app.takeCount()),
                '<' => adjustSwing(app, -1.0),
                '>' => adjustSwing(app, 1.0),
                // zig fmt: on
                'c' => {
                    if (sl.stepActive(slice.*, step.*)) {
                        history.push(app, history.captureSlicer(app, app.slicer_track));
                        sl.cycleStepVel(slice.*, step.*);
                        app.setStatus("vel {d}", .{sl.stepVel(slice.*, step.*)});
                    } else app.setStatus("no step here - enter places one", .{});
                },
                '_' => nudgeVel(app, -app.takeCount()),
                '=' => nudgeVel(app, app.takeCount()),
                'v' => {
                    app.slicer_visual_anchor = step.*;
                    app.modal.mode = .visual;
                    app.setStatus("visual: hjkl extend, y/d/p act on the range, esc cancels", .{});
                },
                'x' => clearCursorStep(app),
                'd' => armOperator(app, 'd'),
                'y' => armOperator(app, 'y'),
                'X' => {
                    history.push(app, history.captureSlicer(app, app.slicer_track));
                    sl.clearSlice(slice.*);
                },
                'F' => {
                    history.push(app, history.captureSlicer(app, app.slicer_track));
                    sl.fillSlice(slice.*);
                },
                'u' => history.doUndo(app),
                'U' => history.doRedo(app),
                'p', 'P' => pasteSelection(app),
                '.' => repeatLastEdit(app),
                // (/) cycle the pattern variant - [ and ] (the drum grid's
                // variant keys) belong to boundary nudges here.
                '(' => cycleVariant(app, -1),
                ')' => cycleVariant(app, 1),
                'N' => {
                    if (sl.variant_count < Slicer.max_variants)
                        history.push(app, history.captureSlicer(app, app.slicer_track));
                    if (sl.addVariant())
                        app.setStatus("new pattern {c} (copy of previous)", .{Slicer.variantLetter(sl.variant)})
                    else
                        app.setStatus("pattern bank full ({d} max)", .{Slicer.max_variants});
                },
                'D' => {
                    if (sl.variant_count > 1)
                        history.push(app, history.captureSlicer(app, app.slicer_track));
                    if (sl.removeVariant()) {
                        if (step.* >= sl.step_count) step.* = sl.step_count - 1;
                        app.setStatus("deleted pattern - now on {c}", .{Slicer.variantLetter(sl.variant)});
                    } else app.setStatus("can't delete the only pattern", .{});
                },
                'C' => {
                    sl.cycleChokeGroup(slice.*);
                    app.dirty = true;
                    const g = sl.choke_group[slice.*];
                    if (g == 0)
                        app.setStatus("choke group: none (overlap allowed)", .{})
                    else
                        app.setStatus("choke group: {d} (cuts group-mates)", .{g});
                },
                'e' => {
                    history.flushParamNudge(app);
                    app.sampler_target = .{ .slice = app.slicer_track };
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

/// Nudge one of the cursor slice's params over the command queue, noting it
/// for coalesced undo - same route editors/sampler.zig's adjustParam takes.
fn nudgeSliceParam(app: *App, param: u8, steps: i32) void {
    const sl = app.slicerInst();
    const slice = app.slicer_cursor[0];
    if (slice >= sl.slice_count) return;
    app.dirty = true;
    const id = Slicer.paramId(slice, param);
    history.noteParamNudge(app, app.slicer_track, id, steps);
    _ = app.session.engine.send(.{ .set_track_param = .{ .track = app.slicer_track, .id = id, .steps = steps } });
}

/// Nudge the cursor step's velocity (full 1-127 range; 'c' cycles the
/// named presets).
fn nudgeVel(app: *App, delta: i32) void {
    const sl = app.slicerInst();
    const slice = app.slicer_cursor[0];
    const step = app.slicer_cursor[1];
    // zig fmt: off
    if (!sl.stepActive(slice, step)) { app.setStatus("no step here - enter places one", .{}); return; }
    // zig fmt: on
    history.push(app, history.captureSlicer(app, app.slicer_track));
    sl.nudgeStepVel(slice, step, delta);
    app.setStatus("vel {d}", .{sl.stepVel(slice, step)});
}

/// Cycle the active pattern variant, keeping the step cursor inside the
/// new variant's step count - same shape as the drum grid's.
fn cycleVariant(app: *App, delta: i32) void {
    const sl = app.slicerInst();
    if (sl.variant_count <= 1) {
        app.setStatus("one pattern - N creates another", .{});
        return;
    }
    sl.cycleVariant(delta);
    app.dirty = true;
    if (app.slicer_cursor[1] >= sl.step_count) app.slicer_cursor[1] = sl.step_count - 1;
    app.setStatus("pattern {c} ({d}/{d})", .{
        Slicer.variantLetter(sl.variant), sl.variant + 1, sl.variant_count,
    });
}

/// Nudge the slicer's swing and echo the new value.
fn adjustSwing(app: *App, delta: f32) void {
    const sl = app.slicerInst();
    sl.adjustSwing(delta);
    app.dirty = true;
    app.setStatus("swing {d:.0}%", .{sl.swing.load(.monotonic)});
}

/// Records a hit while the transport is rolling, quantized to the live step
/// (same insert-mode convention as `editors/drum.zig`'s `recordNote`).
pub fn recordNote(app: *App, pitch: u7, vel: u8) void {
    if (app.slicer_track >= app.session.racks.items.len) return;
    if (app.session.racks.items[app.slicer_track].instrument != .slicer) return;
    const snap = app.session.engine.uiSnapshot();
    if (!snap.playing) return;
    const sl = app.slicerInst();
    if (sl.slice_count == 0) return;
    const slice: u8 = @intCast(pitch % sl.slice_count);
    const step = sl.currentStep();
    if (sl.stepActive(slice, step)) return;
    history.push(app, history.captureSlicer(app, app.slicer_track));
    sl.toggleStep(slice, step);
    sl.setStepVel(slice, step, vel);
    app.slicer_cursor = .{ slice, step };
    app.setStatus("rec: slice {d} step {d}", .{ slice + 1, step + 1 });
}

/// Move the step cursor by `delta` steps, clamped to the pattern length.
fn moveStep(app: *App, delta: i32) void {
    step_grid.moveClamped(&app.slicer_cursor[1], delta, app.slicerInst().step_count);
}

/// Move the slice cursor by `delta` rows, clamped to the slice count.
fn moveSlice(app: *App, delta: i32) void {
    step_grid.moveClamped(&app.slicer_cursor[0], delta, app.slicerInst().slice_count);
}

fn stepEnter(app: *App) void {
    const sl = app.slicerInst();
    const slice = app.slicer_cursor[0];
    const step = app.slicer_cursor[1];
    if (!sl.stepActive(slice, step)) {
        history.push(app, history.captureSlicer(app, app.slicer_track));
        step_grid.setStep(sl, slice, step, true, Slicer.vel_full);
    }
    moveStep(app, app.takeCount());
}

fn doublePattern(app: *App) void {
    const sl = app.slicerInst();
    if (sl.step_count > Slicer.max_steps / 2) {
        app.setStatus("can't double {d} steps (64 max)", .{sl.step_count});
        return;
    }
    history.push(app, history.captureSlicer(app, app.slicer_track));
    _ = step_grid.doublePattern(sl, Slicer.max_slices);
    app.setStatus("doubled loop to {d} steps", .{sl.step_count});
}

/// Rebuild the grid as the source-order staircase produced by conventional
/// slice-to-MIDI workflows: slice 1 on step 1, slice 2 on step 2, and so on.
fn sequenceSourceOrder(app: *App) void {
    const sl = app.slicerInst();
    if (sl.slice_count == 0) {
        app.setStatus("no slices to sequence", .{});
        return;
    }
    history.push(app, history.captureSlicer(app, app.slicer_track));
    sl.setStepCount(@max(sl.step_count, sl.slice_count));
    for (0..Slicer.max_slices) |row| sl.clearSlice(@intCast(row));
    for (0..sl.slice_count) |idx| {
        step_grid.setStep(sl, @intCast(idx), @intCast(idx), true, Slicer.vel_full);
    }
    app.slicer_cursor = .{ 0, 0 };
    app.setStatus("sequenced {d} slices in source order", .{sl.slice_count});
}

/// w/b: jump the step cursor by 4-step groups - see step_grid.jumpBar for
/// the bar-width rationale (same tier as the drum grid's w/b).
fn jumpBar(app: *App, delta: i32) void {
    step_grid.jumpBar(&app.slicer_cursor[1], delta, app.slicerInst().step_count);
}

/// dw/yw's range end - see step_grid.operatorBarForward.
fn operatorBarForward(app: *App, n: i32) void {
    step_grid.operatorBarForward(&app.slicer_cursor[1], n, app.slicerInst().step_count);
}

/// db/yb's range start - see step_grid.operatorBarBackward.
fn operatorBarBackward(app: *App, n: i32) void {
    step_grid.operatorBarBackward(&app.slicer_cursor[1], n, app.slicerInst().step_count);
}

/// Arm `d`/`y` as a pending operator, remembering the cursor step as the
/// range anchor - same field visual mode's `v` sets.
fn armOperator(app: *App, op: u8) void {
    app.slicer_visual_anchor = app.slicer_cursor[1];
    app.slicer_op_pending = op;
    if (op == 'd')
        app.setStatus("d: h/l/H/L/g/G/w/b act on the range, dd clears the cursor slice's row", .{})
    else
        app.setStatus("y: h/l/H/L/g/G/w/b act on the range, yy yanks the whole pattern", .{});
}

/// Complete an operator+motion: run the range delete/yank between the
/// anchor `armOperator` set and the cursor's new position.
fn finishOperator(app: *App, op: u8) void {
    if (op == 'd') deleteSelection(app) else yankSelection(app);
}

/// `x`: clears just the (slice, step) under the cursor.
fn clearCursorStep(app: *App) void {
    const sl = app.slicerInst();
    const slice = app.slicer_cursor[0];
    const step = app.slicer_cursor[1];
    // zig fmt: off
    if (!sl.stepActive(slice, step)) { app.setStatus("no step here", .{}); return; }
    // zig fmt: on
    history.push(app, history.captureSlicer(app, app.slicer_track));
    step_grid.setStep(sl, slice, step, false, 0);
    app.setStatus("cleared step", .{});
}

/// `dd`: clear every step on the cursor slice's row (same clear as X).
fn clearSliceRow(app: *App) void {
    history.push(app, history.captureSlicer(app, app.slicer_track));
    app.slicerInst().clearSlice(app.slicer_cursor[0]);
    app.setStatus("cleared slice {d}'s row", .{@as(u32, app.slicer_cursor[0]) + 1});
}

/// `yy`: yank the whole pattern as a full-width range (the slicer has no
/// pattern variants, so range paste at step 0 reproduces it exactly).
fn yankWholePattern(app: *App) void {
    const sl = app.slicerInst();
    const save_cursor = app.slicer_cursor[1];
    app.slicer_visual_anchor = 0;
    app.slicer_cursor[1] = sl.step_count -| 1;
    yankSelection(app);
    app.slicer_cursor[1] = save_cursor;
    app.setStatus("yanked the whole pattern ({d} steps)", .{sl.step_count});
}

/// Visual mode's reduced key set - same shape as the drum grid's.
fn handleVisual(app: *App, key: modal_mod.Key) bool {
    switch (key) {
        // zig fmt: off
        .escape => { exitVisual(app); app.setStatus("selection cancelled", .{}); return true; },
        .char => |c| switch (c) {
            'h' => { moveStep(app, -app.takeCount()); return true; },
            'l' => { moveStep(app, app.takeCount()); return true; },
            'H' => { moveStep(app, -4 * app.takeCount()); return true; },
            'L' => { moveStep(app, 4 * app.takeCount()); return true; },
            'j' => { moveSlice(app, app.takeCount()); return true; },
            'k' => { moveSlice(app, -app.takeCount()); return true; },
            'J' => { moveSlice(app, 8 * app.takeCount()); return true; },
            'K' => { moveSlice(app, -8 * app.takeCount()); return true; },
            'w' => { jumpBar(app, app.takeCount()); return true; },
            'b' => { jumpBar(app, -app.takeCount()); return true; },
            'g' => { app.slicer_cursor[1] = 0; return true; },
            'G' => {
                const sl = app.slicerInst();
                if (sl.step_count > 0) app.slicer_cursor[1] = sl.step_count - 1;
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

fn exitVisual(app: *App) void {
    _ = app.modal.setMode(.normal);
    app.slicer_visual_anchor = null;
}

/// Yank every slice's steps within the selected range into the range
/// clipboard, rebased so the range's first step is bit 0.
fn yankSelection(app: *App) void {
    const sl = app.slicerInst();
    const r = step_grid.selectionRange(app.slicer_visual_anchor, app.slicer_cursor[1]);
    const clip = step_grid.yankRange(SlicerRangeClip, sl, Slicer.max_slices, r);
    app.slicer_range_clip = clip;
    app.setStatus("yanked {d} steps", .{clip.width});
    exitVisual(app);
}

/// Clear every slice's steps within the selected range.
fn deleteSelection(app: *App) void {
    const sl = app.slicerInst();
    const r = step_grid.selectionRange(app.slicer_visual_anchor, app.slicer_cursor[1]);
    history.push(app, history.captureSlicer(app, app.slicer_track));
    step_grid.clearRange(sl, Slicer.max_slices, r);
    app.last_edit = .{ .slicer_range_delete = .{ .width = r.hi - r.lo + 1 } };
    app.setStatus("cleared {d} steps", .{r.hi - r.lo + 1});
    exitVisual(app);
}

/// Paste the range clipboard starting at the cursor step, overwriting
/// whatever already sits at each destination step (all slices).
fn pasteSelection(app: *App) void {
    const clip = app.slicer_range_clip orelse {
        app.setStatus("nothing yanked - select a range and y first", .{});
        exitVisual(app);
        return;
    };
    const sl = app.slicerInst();
    history.push(app, history.captureSlicer(app, app.slicer_track));
    const n = step_grid.pasteRange(sl, Slicer.max_slices, clip, app.slicer_cursor[1]);
    app.last_edit = .slicer_range_paste;
    app.setStatus("pasted {d} steps", .{n});
    exitVisual(app);
}

/// `.`: replay the last compound edit (a visual range delete/paste) at the
/// current cursor.
fn repeatLastEdit(app: *App) void {
    switch (app.last_edit) {
        .slicer_range_delete => |v| {
            const sl = app.slicerInst();
            const hi: u8 = @min(sl.step_count -| 1, app.slicer_cursor[1] +| (v.width - 1));
            app.slicer_visual_anchor = hi;
            deleteSelection(app);
        },
        .slicer_range_paste => pasteSelection(app),
        else => app.setStatus("nothing to repeat", .{}),
    }
}

/// Click a step cell to toggle it; drag to paint. Click inside the
/// waveform pane to jump the cursor to the slice under the mouse (and keep
/// the click quiet otherwise - boundary editing by mouse lives in the
/// slice editor on 'e'). Scroll moves the step cursor, or - over the
/// gutter - the slice cursor.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16, view_rows: usize) void {
    const sl = app.slicerInst();
    switch (ev.kind) {
        .scroll_up, .scroll_down => {
            const delta: i32 = if (ev.kind == .scroll_up) -1 else 1;
            if (ev.x < slicer_view.gutter) moveSlice(app, delta) else moveStep(app, delta);
            return;
        },
        else => {},
    }

    const lay = slicer_view.layout(sl.slice_count, view_rows);
    if (lay.wave_rows > 0 and row >= 1 and row < 1 + lay.wave_rows) {
        // Waveform pane: press selects the slice whose region covers the
        // clicked column.
        if (ev.kind != .press) return;
        const norm = slicer_view.waveNorm(ev.x, cols) orelse return;
        for (0..sl.slice_count) |i| {
            const p = &sl.slices[i];
            if (norm >= p.start_norm and norm < p.end_norm) {
                app.slicer_cursor[0] = @intCast(i);
                return;
            }
        }
        return;
    }

    const grid_top = lay.headerRow() + 1;
    if (row < grid_top) return;
    const bank_start = (@as(usize, app.slicer_cursor[0]) / 8) * 8;
    const slice = bank_start + (row - grid_top);
    if (slice >= sl.slice_count) return;

    switch (ev.kind) {
        .press => {
            app.slicer_cursor[0] = @intCast(slice);
            const step = step_grid.stepAt(slicer_view.gutter, 3, app.slicer_step_scroll, sl.step_count, ev.x) orelse {
                app.slicer_paint_state = null;
                return;
            };
            app.slicer_cursor[1] = step;
            history.push(app, history.captureSlicer(app, app.slicer_track));
            sl.toggleStep(@intCast(slice), step);
            app.slicer_paint_state = sl.stepActive(@intCast(slice), step);
        },
        .drag => {
            const state = app.slicer_paint_state orelse return;
            const step = step_grid.stepAt(slicer_view.gutter, 3, app.slicer_step_scroll, sl.step_count, ev.x) orelse return;
            app.slicer_cursor[0] = @intCast(slice);
            app.slicer_cursor[1] = step;
            step_grid.setStep(sl, @intCast(slice), step, state, Slicer.vel_full);
        },
        .release => app.slicer_paint_state = null,
        else => {},
    }
}

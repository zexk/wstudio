//! Slicer-grid input: slice/step cursor, step toggle, insert-mode qwerty
//! triggering (recorded as steps quantized to the live playhead, same
//! convention as the drum grid's own insert mode), and per-slice param nudges
//! (start/end/gain/pan/reverse). No undo, visual mode, or operator grammar
//! for this first pass — a deliberate scope cut, not an oversight (see
//! dsp/slicer.zig's own doc comment for the same reasoning applied to the
//! sequencer). The render half lives in views/slicer.zig; the machine itself
//! in dsp/slicer.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const Slicer = ws.dsp.Slicer;
const App = @import("../app.zig").App;

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const slice = &app.slicer_cursor[0];
    const step = &app.slicer_cursor[1];
    const sl = app.slicerInst();

    switch (key) {
        .escape => { app.view = .tracks; return true; },
        .enter => { sl.toggleStep(slice.*, step.*); return true; },
        .char => |c| switch (c) {
            'h' => moveStep(app, -app.takeCount()),
            'l' => moveStep(app, app.takeCount()),
            'H' => moveStep(app, -4 * app.takeCount()),
            'L' => moveStep(app, 4 * app.takeCount()),
            'j' => moveSlice(app, app.takeCount()),
            'k' => moveSlice(app, -app.takeCount()),
            // J/K jump a whole bank of 8 slices — same MPC-style paging
            // views/slicer.zig windows the grid to, mirroring the drum
            // grid's own pad banking.
            'J' => moveSlice(app, 8 * app.takeCount()),
            'K' => moveSlice(app, -8 * app.takeCount()),
            'g' => step.* = 0,
            'G' => { if (sl.step_count > 0) step.* = sl.step_count - 1; },
            'x' => sl.toggleStep(slice.*, step.*),
            'a' => {
                _ = app.session.engine.send(.{ .note_on = .{
                    .track = app.slicer_track,
                    .note = @intCast(slice.*),
                    .velocity = 0.9,
                } });
                app.setStatus("preview: slice {d}", .{slice.* + 1});
            },
            '-' => { sl.setStepCount(sl.step_count -| 1); if (step.* >= sl.step_count) step.* = sl.step_count - 1; },
            '+' => sl.setStepCount(sl.step_count + 1),
            // Per-slice param nudges — start/end/gain/pan/reverse, the same
            // fine/coarse shape adjustParam already gives every other
            // per-pad param elsewhere.
            '[' => nudgeSlice(sl, slice.*, 0, -app.takeCount()), // start -
            ']' => nudgeSlice(sl, slice.*, 0, app.takeCount()),  // start +
            '{' => nudgeSlice(sl, slice.*, 1, -app.takeCount()), // end -
            '}' => nudgeSlice(sl, slice.*, 1, app.takeCount()),  // end +
            '<' => nudgeSlice(sl, slice.*, 8, -app.takeCount()), // pan left
            '>' => nudgeSlice(sl, slice.*, 8, app.takeCount()),  // pan right
            '_' => nudgeSlice(sl, slice.*, 7, -app.takeCount()), // gain -
            '=' => nudgeSlice(sl, slice.*, 7, app.takeCount()),  // gain +
            'r' => nudgeSlice(sl, slice.*, 9, 1),                // reverse toggle
            else => return false,
        },
        else => return false,
    }
    return true;
}

fn nudgeSlice(sl: *Slicer, slice: u8, param: u8, steps: i32) void {
    sl.adjustParam(Slicer.paramId(slice, param), steps);
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
    sl.toggleStep(slice, step);
    sl.setStepVel(slice, step, vel);
    app.slicer_cursor = .{ slice, step };
    app.setStatus("rec: slice {d} step {d}", .{ slice + 1, step + 1 });
}

fn moveStep(app: *App, delta: i32) void {
    const sl = app.slicerInst();
    const top = @as(i32, sl.step_count) - 1;
    app.slicer_cursor[1] = @intCast(std.math.clamp(@as(i32, app.slicer_cursor[1]) + delta, 0, top));
}

fn moveSlice(app: *App, delta: i32) void {
    const sl = app.slicerInst();
    const top = @as(i32, sl.slice_count) - 1;
    if (top < 0) { app.slicer_cursor[0] = 0; return; }
    app.slicer_cursor[0] = @intCast(std.math.clamp(@as(i32, app.slicer_cursor[0]) + delta, 0, top));
}

pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize) void {
    _ = app;
    _ = ev;
    _ = row;
    // Mouse support deferred — a deliberate cut for this first pass, same as
    // undo/visual mode (see this file's own doc comment).
}

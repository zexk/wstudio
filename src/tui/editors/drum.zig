//! Drum-grid input: step/pad cursor, step + velocity toggles, pattern
//! variants, swing, yank/paste, visual-mode range select (v, then y/d/P).
//! The render half lives in views/drum.zig; the machine itself in
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
    // range y/d/P live in handleVisual; everything else is swallowed so a
    // stray keypress can't jump views mid-selection.
    if (app.modal.mode == .visual) return handleVisual(app, key);

    switch (key) {
        .escape => { app.view = .tracks; return true; },
        // enter toggles the step; space falls through to transport play/pause.
        .enter => {
            history.push(app, history.captureDrum(app, app.drum_track));
            app.drumMachine().toggleStep(pad.*, step.*);
            return true;
        },
        .char => |c| {
            switch (c) {
                // fine move by one step; shift (HL) jumps one beat (4 steps).
                // All motions take a vim count prefix (3l, 2j, …).
                'h' => moveStep(app, -app.takeCount()),
                'l' => moveStep(app, app.takeCount()),
                'H' => moveStep(app, -4 * app.takeCount()),
                'L' => moveStep(app, 4 * app.takeCount()),
                'k' => movePad(app, -app.takeCount()),
                'j' => movePad(app, app.takeCount()),
                'p' => {
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
                    app.setStatus("visual: hjkl extend, y/d/P act on the range, esc cancels", .{});
                },
                '<' => adjustSwing(app, -1.0),
                '>' => adjustSwing(app, 1.0),
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
                'y' => {
                    const dm = app.drumMachine();
                    app.drum_clip = dm.variantData(dm.variant);
                    app.setStatus("yanked pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
                },
                'P' => {
                    if (app.drum_clip) |clip| {
                        const dm = app.drumMachine();
                        history.push(app, history.captureDrum(app, app.drum_track));
                        dm.applyVariant(clip);
                        if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                        app.setStatus("pasted into pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
                    } else app.setStatus("nothing yanked — y copies the pattern", .{});
                },
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

/// Move the step cursor by `delta` steps, clamped to the pattern length.
fn moveStep(app: *App, delta: i32) void {
    const top = @as(i32, app.drumMachine().step_count) - 1;
    app.drum_cursor[1] = @intCast(std.math.clamp(@as(i32, app.drum_cursor[1]) + delta, 0, top));
}

/// Move the pad cursor by `delta` rows, clamped to the pad count.
fn movePad(app: *App, delta: i32) void {
    app.drum_cursor[0] = @intCast(std.math.clamp(@as(i32, app.drum_cursor[0]) + delta, 0, DrumMachine.max_pads - 1));
}

/// Visual mode's reduced key set: motions extend the selection, y/d/P act
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
            'y' => { yankSelection(app); return true; },
            'd' => { deleteSelection(app); return true; },
            'P' => { pasteSelection(app); return true; },
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
/// whatever DrumMachine does internally on toggle).
fn setStep(dm: *DrumMachine, pad: u8, step: u8, active: bool, vel: u2) void {
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
    app.setStatus("pasted {d} steps", .{i});
    exitVisual(app);
}

/// Nudge the drum machine's swing and echo the new value.
fn adjustSwing(app: *App, delta: f32) void {
    const dm = app.drumMachine();
    dm.adjustSwing(delta);
    app.dirty = true;
    app.setStatus("swing {d:.0}%", .{dm.swing.load(.monotonic)});
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

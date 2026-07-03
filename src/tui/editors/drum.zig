//! Drum-grid input: step/pad cursor, step + velocity toggles, pattern
//! variants, swing, yank/paste. The render half lives in views/drum.zig;
//! the machine itself in dsp/drum_sampler.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const DrumMachine = ws.dsp.DrumMachine;
const App = @import("../app.zig").App;
const history = @import("../history.zig");
const spectrum = @import("spectrum.zig");

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const pad = &app.drum_cursor[0];
    const step = &app.drum_cursor[1];
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
                'v' => {
                    const dm = app.drumMachine();
                    if (dm.stepActive(pad.*, step.*)) {
                        history.push(app, history.captureDrum(app, app.drum_track));
                        dm.cycleStepVel(pad.*, step.*);
                        app.setStatus("vel {d}%", .{DrumMachine.velPercent(dm.stepVel(pad.*, step.*))});
                    } else app.setStatus("no step here — enter places one", .{});
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

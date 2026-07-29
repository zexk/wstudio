//! Drum-grid input: step/pad cursor, step + velocity toggles, pattern
//! variants, swing, choke groups, yank/paste, visual-mode range select
//! (v, then y/d/p), and operator+motion grammar (x/w/b/d/y - see the
//! step/bar/pattern hierarchy on the operator-pending block below). The
//! render half lives in views/drum.zig; the machine itself in
//! dsp/drum_sampler.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const DrumMachine = ws.dsp.DrumMachine;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const StepRangeClip = app_mod.StepRangeClip;
const history = @import("../history.zig");
const spectrum = @import("spectrum.zig");
const preset_picker = @import("preset_picker.zig");
const step_grid = @import("step_grid.zig");

/// Left gutter before the step columns start (mirrored by the TUI drum
/// view's column math) and the 8-pad bank geometry shared between mouse
/// hit-testing here and the bank window the view renders.
pub const gutter: usize = 10;
pub const pads_per_bank = step_grid.rows_per_bank;

/// How many 8-pad banks the grid stacks at once: tall terminals show 2/4/8
/// banks instead of leaving the rows blank. Snapped to divisors of the bank
/// count so the paging groups always align. Every bank after the first
/// costs pads_per_bank + 1 rows (a dim rule marks the bank boundary).
/// `rows` is the view's content-row budget (drawDrumGrid's
/// `rows` / handleMouse's view_rows); pad rows fit while used = title(1) +
/// header(1) + bank rows + 2 stays inside rows - 4.
pub fn banksShown(rows: usize) usize {
    const budget = rows -| 8;
    inline for ([_]usize{ 8, 4, 2 }) |n| {
        if (n * pads_per_bank + (n - 1) <= budget) return n;
    }
    return 1;
}

/// First pad of the window showing the bank group that contains `cur_pad`
/// (always a multiple of pads_per_bank). Shared with views/drum.zig's
/// rendering - keep both on this helper.
pub fn bankWindowStart(cur_pad: u8, rows: usize) usize {
    return step_grid.bankWindow(cur_pad, banksShown(rows));
}

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
                // piano.zig's identical comment - same vim dw nuance).
                'w' => { operatorBarForward(app, app.takeCount()); finishOperator(app, op); return true; },
                'b' => { operatorBarBackward(app, app.takeCount()); finishOperator(app, op); return true; },
                else => { app.drum_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            },
            else => { app.drum_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
        }
    }

    // Step-stamp mode: a HELD enter freshly activating a step live-shapes
    // it for as long as the key stays down, mirroring the piano roll's own
    // note-stamp - j/k nudge the just-placed step's velocity (a one-shot
    // hit has no length to shape, so there's no h/l equivalent here).
    // Releasing enter drops it (`.enter_release`, from frontends that can
    // see key-up), so a quick tap is just a plain stamp with no lingering
    // mode; legacy terminals never send the release, so enter/esc still
    // drop explicitly and any other key drops first and is then handled
    // normally below.
    if (app.drum_stamp) {
        switch (key) {
            .escape => { app.drum_stamp = false; app.setStatus("step dropped", .{}); return true; },
            .enter => { app.drum_stamp = false; app.setStatus("step dropped", .{}); return true; },
            .enter_release => { app.drum_stamp = false; app.setStatus("step dropped", .{}); return true; },
            .char => |c| switch (c) {
                'j' => { stampNudgeVel(app, -1); return true; },
                'k' => { stampNudgeVel(app, 1); return true; },
                else => app.drum_stamp = false,
            },
            else => app.drum_stamp = false,
        }
    }

    switch (key) {
        .escape => { app.view = .tracks; return true; },
        // enter toggles the step; a fresh activation starts a stamp session
        // (see above); space falls through to transport play/pause.
        .enter => {
            history.recordDrum(app, app.drum_track);
            const dm = app.drumMachine();
            dm.toggleStep(@intCast(pad.*), step.*);
            if (dm.stepActive(@intCast(pad.*), step.*)) {
                app.drum_stamp = true;
                app.setStatus("stamping - hold: j/k velocity; release/esc drops", .{});
            }
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
                // J/K jump a whole bank of 8 pads at once - MPC-style paging
                // rather than a smooth scroll (views/drum.zig windows the
                // grid to the cursor's bank, floor(pad/8)).
                'K' => movePad(app, -8 * app.takeCount()),
                'J' => movePad(app, 8 * app.takeCount()),
                // g/G jump the step cursor to pattern start/end, matching
                // the piano roll's convention. Choke-group cycling - that
                // used to squat on 'G' - lives on 'C' instead (see below).
                'g' => app.drum_cursor[1] = 0,
                'G' => {
                    const dm = app.drumMachine();
                    if (dm.step_count > 0) step.* = dm.step_count - 1;
                },
                // Advancing entry complements Enter's stationary toggle: a
                // count leaves space before the next hit (4n = every beat).
                'n' => stepEnter(app),
                // w/b: vim's word motion, one tier up from h/l's step
                // ("char") granularity - jump to the start of the
                // next/current-or-previous 4-step group (see barLenSteps).
                'w' => jumpBar(app, app.takeCount()),
                'b' => jumpBar(app, -app.takeCount()),
                'z' => zoom(app, 1),
                'Z' => zoom(app, -1),
                'a' => {
                    _ = app.session.engine.send(.{ .note_on = .{
                        .track = app.drum_track,
                        .note = @intCast(pad.*),
                        .velocity = app.default_velocity,
                    } });
                    app.setStatus("preview: pad {d}", .{pad.* + 1});
                },
                // Resize by a whole (decorative) bar, not a single step -
                // now that pads hold real MIDI notes rather than on/off
                // bits, nudging the loop by one grid cell at a time is a
                // leftover from the old boolean step sequencer. Trailing
                // notes past a shrink are dropped (see setStepCount's doc).
                '-' => {
                    const dm = app.drumMachine();
                    const delta: u16 = @intCast(step_grid.bar_len * app.takeCount());
                    history.recordDrum(app, app.drum_track);
                    dm.setStepCount(dm.step_count -| delta);
                    if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                },
                '+' => {
                    const dm = app.drumMachine();
                    const delta: u16 = @intCast(step_grid.bar_len * app.takeCount());
                    history.recordDrum(app, app.drum_track);
                    dm.setStepCount(dm.step_count +| delta);
                },
                'E' => doublePattern(app),
                'c' => {
                    const dm = app.drumMachine();
                    if (dm.stepActive(@intCast(pad.*), step.*)) {
                        history.recordDrum(app, app.drum_track);
                        dm.cycleStepVel(@intCast(pad.*), step.*);
                        app.setStatus("vel {d}", .{dm.stepVel(@intCast(pad.*), step.*)});
                    } else app.setStatus("no step here - enter places one", .{});
                },
                // {/}: fine velocity nudge (±1, count-scaled) over the full
                // 1-127 range - 'c' above only cycles the named presets.
                '{' => {
                    const dm = app.drumMachine();
                    if (dm.stepActive(@intCast(pad.*), step.*)) {
                        history.recordDrum(app, app.drum_track);
                        dm.nudgeStepVel(@intCast(pad.*), step.*, -app.takeCount());
                        app.setStatus("vel {d}", .{dm.stepVel(@intCast(pad.*), step.*)});
                    } else app.setStatus("no step here - enter places one", .{});
                },
                '}' => {
                    const dm = app.drumMachine();
                    if (dm.stepActive(@intCast(pad.*), step.*)) {
                        history.recordDrum(app, app.drum_track);
                        dm.nudgeStepVel(@intCast(pad.*), step.*, app.takeCount());
                        app.setStatus("vel {d}", .{dm.stepVel(@intCast(pad.*), step.*)});
                    } else app.setStatus("no step here - enter places one", .{});
                },
                // (/): per-step tune, the same fine-nudge shape {/} has for
                // velocity - one hit detuned without touching the pad every
                // other hit on that row shares.
                '(' => nudgeTune(app, -app.takeCount()),
                ')' => nudgeTune(app, app.takeCount()),
                // m/M: this pad's own loop length, independent of the
                // pattern's (-/+). A shorter row wraps early and drifts
                // against the others - polymeter. :pad-len sets it exactly.
                'm' => nudgePadLen(app, -app.takeCount()),
                'M' => nudgePadLen(app, app.takeCount()),
                // %/T: the two halves of a trig condition on the step under
                // the cursor - fire chance and the conditional rule. ! flips
                // the machine-wide fill switch the FILL rules read.
                // r: pack the step into a roll (off/2/3/4/6/8 hits), spaced
                // across the step's own duration - Elektron's Retrig.
                'r' => cycleStepRetrig(app),
                // ;/': drag this one hit early or late, in percent of a step.
                // Swing shifts every off-beat by the same amount; this is the
                // per-hit version.
                ';' => nudgeMicro(app, -app.takeCount()),
                '\'' => nudgeMicro(app, app.takeCount()),
                '%' => cycleStepProb(app),
                'T' => cycleStepCond(app, app.takeCount()),
                '!' => {
                    const dm = app.drumMachine();
                    const on = dm.toggleFill();
                    app.setStatus("fill {s}", .{if (on) "ON" else "off"});
                },
                // v: blockwise - a (pad, step) rectangle, one pad tall until
                // j/k grow it. V: linewise - the step range across every pad,
                // which is what visual mode did unconditionally before the
                // pad axis existed. See step_grid.rowRange.
                'v' => step_grid.enterVisual(app, &app.drum_visual_anchor, &app.drum_visual_pad_anchor, step.*, @as(u8, @intCast(pad.*)), true, "pad"),
                'V' => step_grid.enterVisual(app, &app.drum_visual_anchor, &app.drum_visual_pad_anchor, step.*, @as(u8, @intCast(pad.*)), false, "pad"),
                // x: vim's char-delete - clears just the (pad, step) under
                // the cursor, instantly, no operator needed.
                'x' => clearCursorStep(app),
                // d is an operator (see armOperator) - dd clears the cursor
                // pad's row (like X), d + a motion (h/l/H/L/g/G/w/b) clears
                // the range it covers.
                'd' => armOperator(app, 'd'),
                '<' => adjustSwing(app, -1.0),
                '>' => adjustSwing(app, 1.0),
                'C' => cycleChokeGroup(app, @intCast(pad.*)),
                'X' => {
                    history.recordDrum(app, app.drum_track);
                    app.drumMachine().clearPad(@intCast(pad.*));
                },
                'F' => {
                    history.recordDrum(app, app.drum_track);
                    app.drumMachine().fillPad(@intCast(pad.*));
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
                        history.recordDrum(app, app.drum_track);
                        dm.applyVariant(clip);
                        if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                        app.setStatus("pasted into pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
                    } else app.setStatus("nothing yanked - y copies the pattern", .{});
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
                        history.recordDrum(app, app.drum_track);
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
                        history.recordDrum(app, app.drum_track);
                    if (dm.removeVariant()) {
                        if (step.* >= dm.step_count) step.* = dm.step_count - 1;
                        app.setStatus("deleted pattern - now on {c}", .{DrumMachine.variantLetter(dm.variant)});
                    } else app.setStatus("can't delete the only pattern", .{});
                },
                // zig fmt: off
                's' => { spectrum.switchToTrack(app, app.drum_track); return true; },
                // f browses kit variants - same apply path as :drum-kit.
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
    history.recordDrum(app, app.drum_track);
    step_grid.setStep(dm, pad, step, true, vel);
    app.drum_cursor = .{ pad, step };
    app.setStatus("rec: pad {d} step {d}", .{ pad + 1, step + 1 });
}

/// j/k during a stamp session (see the `drum_stamp` block in handleKey):
/// nudge the just-placed step's velocity by one, same path `{`/`}` use.
/// Drops the session instead if the step somehow isn't there any more.
fn stampNudgeVel(app: *App, delta: i32) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    const step = app.drum_cursor[1];
    if (!dm.stepActive(pad, step)) {
        app.drum_stamp = false;
        return;
    }
    history.recordDrum(app, app.drum_track);
    dm.nudgeStepVel(pad, step, delta);
    app.setStatus("vel {d}", .{dm.stepVel(pad, step)});
}

/// Move the step cursor by `delta` steps, clamped to the pattern length.
fn moveStep(app: *App, delta: i32) void {
    step_grid.moveClamped(&app.drum_cursor[1], delta, app.drumMachine().step_count);
}

/// Move the pad cursor by `delta` rows, clamped to the pad count.
fn movePad(app: *App, delta: i32) void {
    step_grid.moveClamped(&app.drum_cursor[0], delta, DrumMachine.max_pads);
}

fn stepEnter(app: *App) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    const step = app.drum_cursor[1];
    if (!dm.stepActive(pad, step)) {
        history.recordDrum(app, app.drum_track);
        step_grid.setStep(dm, pad, step, true, DrumMachine.vel_full);
    }
    moveStep(app, app.takeCount());
}

fn doublePattern(app: *App) void {
    const dm = app.drumMachine();
    if (dm.step_count > DrumMachine.max_steps / 2) {
        app.setStatus("can't double {d} steps ({d} max)", .{ dm.step_count, DrumMachine.max_steps });
        return;
    }
    history.recordDrum(app, app.drum_track);
    _ = step_grid.doublePattern(dm, DrumMachine.max_pads, DrumMachine.max_steps);
    app.setStatus("doubled loop to {d} steps", .{dm.step_count});
}

fn zoom(app: *App, delta: i8) void {
    const next = if (delta > 0) app.drum_grid.finer() else app.drum_grid.coarser();
    if (next == app.drum_grid) return;
    const spb = next.denominator() / 4;
    const dm = app.drumMachine();
    const new_count = @as(u32, dm.step_count) * spb / dm.steps_per_beat;
    if (new_count == 0 or new_count > DrumMachine.max_steps) {
        app.setStatus("grid {s} would exceed the step ceiling - shorten the pattern first", .{next.label()});
        return;
    }
    // Capture before mutating (undo needs the pre-change state) but only
    // push it once the resize actually lands - `setStepsPerBeatPreservingTime`
    // refuses in place rather than dropping a hit, and a refusal shouldn't
    // leave a no-op undo entry behind.
    var entry = history.captureDrum(app, app.drum_track);
    if (!dm.setStepsPerBeatPreservingTime(spb)) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("grid {s} would collide two hits onto one step - move or delete one first", .{next.label()});
        return;
    }
    history.push(app, entry);
    app.drum_grid = next;
    app.setStatus("grid: {s} ({d} steps)", .{ app.drum_grid.label(), dm.step_count });
}

/// w/b: jump the step cursor `delta` 4-step groups forward/back - see
/// step_grid.jumpBar for the bar-width rationale.
fn jumpBar(app: *App, delta: i32) void {
    step_grid.jumpBar(&app.drum_cursor[1], delta, app.drumMachine().step_count, step_grid.bar_len);
}

/// dw/yw's range end - see step_grid.operatorBarForward.
fn operatorBarForward(app: *App, n: i32) void {
    step_grid.operatorBarForward(&app.drum_cursor[1], n, app.drumMachine().step_count, step_grid.bar_len);
}

/// db/yb's range start - see step_grid.operatorBarBackward.
fn operatorBarBackward(app: *App, n: i32) void {
    step_grid.operatorBarBackward(&app.drum_cursor[1], n, app.drumMachine().step_count, step_grid.bar_len);
}

/// Arm `d`/`y` as a pending operator - see docs/editing-grammar.md.
fn armOperator(app: *App, op: u8) void {
    step_grid.armOperator(app, &app.drum_visual_anchor, &app.drum_visual_pad_anchor, &app.drum_cursor[1], &app.drum_op_pending, op, "pad");
}

/// Run the armed operator over anchor-to-cursor.
fn finishOperator(app: *App, op: u8) void {
    if (op == 'd') deleteSelection(app) else yankSelection(app);
}

/// `(`/`)`: transpose the hit under the cursor by `delta` semitones, the
/// per-step counterpart to the pad's own pitch param.
fn nudgeTune(app: *App, delta: i32) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    const step = app.drum_cursor[1];
    // zig fmt: off
    if (!dm.stepActive(pad, step)) { app.setStatus("no step here - enter places one", .{}); return; }
    // zig fmt: on
    history.recordDrum(app, app.drum_track);
    dm.nudgeStepTune(pad, step, delta);
    const semis = dm.stepTune(pad, step);
    app.setStatus("tune {s}{d} st", .{ if (semis > 0) "+" else "", semis });
}

/// `;`/`'`: shift the hit under the cursor early or late, in percent of a
/// step (±50, half a step either way).
fn nudgeMicro(app: *App, delta: i32) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    const step = app.drum_cursor[1];
    // zig fmt: off
    if (!dm.stepActive(pad, step)) { app.setStatus("no step here - enter places one", .{}); return; }
    // zig fmt: on
    history.recordDrum(app, app.drum_track);
    dm.nudgeStepMicro(pad, step, delta);
    app.dirty = true;
    const pct = dm.stepMicro(pad, step);
    app.setStatus("micro {s}{d}%", .{ if (pct > 0) "+" else "", pct });
}

/// `r`: step the hit under the cursor through the roll sizes.
fn cycleStepRetrig(app: *App) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    const step = app.drum_cursor[1];
    // zig fmt: off
    if (!dm.stepActive(pad, step)) { app.setStatus("no step here - enter places one", .{}); return; }
    // zig fmt: on
    history.recordDrum(app, app.drum_track);
    dm.cycleStepRetrig(pad, step);
    app.dirty = true;
    const n = dm.stepRetrig(pad, step);
    if (n < 2) app.setStatus("roll off", .{}) else app.setStatus("roll x{d}", .{n});
}

/// `%`: step the hit under the cursor through the fire-chance presets.
fn cycleStepProb(app: *App) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    const step = app.drum_cursor[1];
    // zig fmt: off
    if (!dm.stepActive(pad, step)) { app.setStatus("no step here - enter places one", .{}); return; }
    // zig fmt: on
    history.recordDrum(app, app.drum_track);
    dm.cycleStepProb(pad, step);
    app.dirty = true;
    app.setStatus("chance {d}%", .{dm.stepProb(pad, step)});
}

/// `T`: walk the hit's trig condition (1ST, FILL, the A:B ratios).
fn cycleStepCond(app: *App, delta: i32) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    const step = app.drum_cursor[1];
    // zig fmt: off
    if (!dm.stepActive(pad, step)) { app.setStatus("no step here - enter places one", .{}); return; }
    // zig fmt: on
    history.recordDrum(app, app.drum_track);
    dm.cycleStepCond(pad, step, delta);
    app.dirty = true;
    app.setStatus("cond {s}", .{dm.stepCond(pad, step).label()});
}

/// `m`/`M`: shrink/grow the cursor pad's own loop length. Reaching the
/// pattern length puts the row back on "follows the pattern".
fn nudgePadLen(app: *App, delta: i32) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    history.recordDrum(app, app.drum_track);
    dm.nudgePadLen(pad, delta);
    app.dirty = true;
    if (dm.pad_len[pad] == 0)
        app.setStatus("pad loop: follows pattern ({d})", .{dm.step_count})
    else
        app.setStatus("pad loop: {d}/{d} steps", .{ dm.pad_len[pad], dm.step_count });
}

/// `x`: vim's char-delete - clears just the (pad, step) under the cursor,
/// instantly, no operator needed.
fn clearCursorStep(app: *App) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    const step = app.drum_cursor[1];
    // zig fmt: off
    if (!dm.stepActive(pad, step)) { app.setStatus("no step here", .{}); return; }
    // zig fmt: on
    history.recordDrum(app, app.drum_track);
    step_grid.setStep(dm, pad, step, false, 0);
    app.setStatus("cleared step", .{});
}

/// `dd`: clear every step on the cursor pad's row - vim's line-delete,
/// where a "line" is one pad across the whole pattern (the same clear `X`
/// does). Whole-pattern clears are a full-range visual d; pad-by-time
/// selections are visual mode's job.
fn clearPadRow(app: *App) void {
    const dm = app.drumMachine();
    const pad: u8 = @intCast(app.drum_cursor[0]);
    history.recordDrum(app, app.drum_track);
    dm.clearPad(pad);
    app.setStatus("cleared pad {d}'s row", .{@as(u32, pad) + 1});
}

/// `yy`: yank the whole current pattern variant (the pre-grammar instant
/// `y` action). `variantData` returns a borrowed view into the live
/// machine - dupe it before storing, or clearing/editing the live pad
/// afterward would silently corrupt the yanked clip too (they'd share the
/// same heap slices). Frees whatever was yanked before.
fn yankWholePattern(app: *App) void {
    const dm = app.drumMachine();
    const v = dm.variantData(dm.variant);
    const fresh = DrumMachine.dupeMidi(app.allocator, &v.midi) catch return;
    if (app.drum_clip) |*old| DrumMachine.freeMidi(app.allocator, &old.midi);
    app.drum_clip = .{ .midi = fresh, .step_count = v.step_count, .steps_per_beat = v.steps_per_beat };
    app.drum_last_yank = .pattern;
    app.setStatus("yanked pattern {c}", .{DrumMachine.variantLetter(dm.variant)});
}

/// Visual mode's reduced key set - see docs/editing-grammar.md for the
/// swallow-everything-else and digits-fall-through rules every editor shares.
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
            // vim's `o`: bounce the cursor to the selection's other corner so
            // it can extend in the opposite direction (same in every grid
            // editor's visual mode). Blockwise selections bounce both axes,
            // so the opposite corner of the rectangle is what you land on.
            'o' => {
                if (app.drum_visual_anchor) |a| {
                    app.drum_visual_anchor = app.drum_cursor[1];
                    app.drum_cursor[1] = a;
                }
                if (app.drum_visual_pad_anchor) |a| {
                    app.drum_visual_pad_anchor = @intCast(app.drum_cursor[0]);
                    app.drum_cursor[0] = a;
                }
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

/// Leave visual mode, clearing the anchors so the selection can't linger.
fn exitVisual(app: *App) void {
    step_grid.exitVisual(app, &app.drum_visual_anchor, &app.drum_visual_pad_anchor);
}

/// The pad band the selection covers: the anchor-to-cursor block under `v`,
/// every pad under `V` (a null anchor) - and every pad for the operator
/// forms too, which never set one.
fn padRange(app: *App) step_grid.RowRange {
    return step_grid.rowRange(u8, app.drum_visual_pad_anchor, @intCast(app.drum_cursor[0]), DrumMachine.max_pads);
}

/// Yank the selected pad band's steps within the selected range into the
/// range clipboard, rebased so the range's first step is bit 0. No width cap
/// - the clipboard is heap-allocated to fit the range (see `StepRangeClip`).
fn yankSelection(app: *App) void {
    const dm = app.drumMachine();
    const r = step_grid.selectionRange(u16, app.drum_visual_anchor, app.drum_cursor[1]);
    const rows = padRange(app);
    const clip = step_grid.yankRangeDyn(StepRangeClip, app.allocator, dm, rows, r) catch {
        app.setStatus("yank failed - out of memory", .{});
        exitVisual(app);
        return;
    };
    if (app.drum_range_clip) |*old| old.deinit(app.allocator);
    app.drum_range_clip = clip;
    app.drum_last_yank = .range;
    app.setStatus("yanked {d} steps x {d} pad(s)", .{ clip.width, rows.height() });
    exitVisual(app);
}

/// Clear the selected pad band's steps within the selected range.
fn deleteSelection(app: *App) void {
    const dm = app.drumMachine();
    const r = step_grid.selectionRange(u16, app.drum_visual_anchor, app.drum_cursor[1]);
    history.recordDrum(app, app.drum_track);
    step_grid.clearRange(dm, padRange(app), r);
    const width: u16 = r.hi - r.lo + 1;
    app.last_edit = .{ .drum_range_delete = .{ .width = width } };
    app.setStatus("cleared {d} steps", .{width});
    exitVisual(app);
}

/// Paste the range clipboard starting at the cursor step, overwriting
/// whatever already sits at each destination cell. A linewise (`V`) yank
/// keeps its own pad rows; a blockwise (`v`) one lands with its top row on
/// the cursor pad - see `step_grid.pasteBaseRow`.
fn pasteSelection(app: *App) void {
    const clip = app.drum_range_clip orelse {
        app.setStatus("nothing yanked - select a range and y first", .{});
        exitVisual(app);
        return;
    };
    const dm = app.drumMachine();
    history.recordDrum(app, app.drum_track);
    const base_row = step_grid.pasteBaseRow(clip, app.drum_cursor[0], DrumMachine.max_pads);
    const n = step_grid.pasteRangeDyn(dm, DrumMachine.max_pads, clip, app.drum_cursor[1], base_row);
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
            const hi: u16 = @min(dm.step_count -| 1, app.drum_cursor[1] +| (v.width -| 1));
            app.drum_visual_anchor = hi;
            deleteSelection(app);
        },
        .drum_range_paste => pasteSelection(app),
        else => app.setStatus("nothing to repeat", .{}),
    }
}

/// R opens the command prompt pre-filled with `:rename <n> ` for the
/// cursor pad - type the new name and hit enter (esc cancels), same
/// mechanism as the tracks view's own rename prompt. Pad index is 1-based,
/// matching the 1-8 direct pad-select keys.
fn startPadRenamePrompt(app: *App) void {
    app.modal.mode = .command;
    app.cmd_history_pos = app.cmd_history.items.len;
    const text = std.fmt.bufPrint(&app.modal.cmd_buf, "rename {d} ", .{app.drum_cursor[0] + 1}) catch return;
    app.modal.cmd_len = text.len;
    app.modal.cmd_cursor = text.len;
}

/// Nudge the drum machine's swing and echo the new value.
fn adjustSwing(app: *App, delta: f32) void {
    const dm = app.drumMachine();
    const before = dm.swing.load(.monotonic);
    dm.adjustSwing(delta);
    history.recordSwing(app, app.drum_track, before);
    app.setStatus("swing {d:.0}%", .{dm.swing.load(.monotonic)});
}

/// Step the cursor pad's choke group forward (none → 1..max → none). A
/// mixer-style param like swing - not undo-tracked.
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
        app.setStatus("one pattern - N creates another", .{});
        return;
    }
    dm.cycleVariant(delta);
    app.dirty = true;
    if (app.drum_cursor[1] >= dm.step_count) app.drum_cursor[1] = dm.step_count - 1;
    app.setStatus("pattern {c} ({d}/{d})", .{
        DrumMachine.variantLetter(dm.variant), dm.variant + 1, dm.variant_count,
    });
}

/// Click a step cell to toggle it (same as enter); click the pad-name
/// gutter to just select that pad row. Dragging with the button held paints
/// (rather than toggles) every newly-entered cell to the state the initial
/// click produced - `setStep` is idempotent, so repeated motion events over
/// the same cell are harmless. **Right**-click always forces the cell off
/// instead of toggling, so a right-drag reliably erases a run of steps
/// regardless of each cell's starting state - unlike a left-drag, whose
/// paint state depends on whatever the first cell under the cursor happened
/// to be. Scroll moves the step cursor, or - over the gutter - the pad
/// cursor, regardless of which row the mouse sits on.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, view_rows: usize) void {
    switch (ev.kind) {
        .scroll_up, .scroll_down => {
            const delta: i32 = if (ev.kind == .scroll_up) -1 else 1;
            if (ev.x < gutter) movePad(app, delta) else moveStep(app, delta);
            return;
        },
        else => {},
    }

    if (row < 2) return; // title / step-number header rows - see views/drum.zig
    // Row 2 is the visible bank window's first pad, not absolute pad 0 -
    // mirrors views/drum.zig's bankWindowStart/banksShown windowing. A dim
    // rule separates stacked banks, so banks occupy pads_per_bank + 1 rows
    // past the first; the rule rows themselves map to no pad.
    const per_bank = pads_per_bank;
    const rel = row - 2;
    const block = rel / (per_bank + 1);
    const within = rel % (per_bank + 1);
    if (within == per_bank) return; // the rule between stacked banks
    if (block >= banksShown(view_rows)) return;
    const bank_start = bankWindowStart(@intCast(app.drum_cursor[0]), view_rows);
    const pad = bank_start + block * per_bank + within;
    if (pad >= DrumMachine.max_pads) return;

    switch (ev.kind) {
        .press => {
            // A click elsewhere ends any active velocity-stamp session
            // first - mouse input skips the keyboard-only stamp block in
            // handleKey, so otherwise it stays set and silently
            // reinterprets the next ordinary keystroke as a velocity nudge
            // on whatever step the cursor now sits on.
            app.drum_stamp = false;
            app.drum_cursor[0] = @intCast(pad);
            const dm = app.drumMachine();
            const step = step_grid.stepAt(u16, gutter, app.drumCellWidth(), app.drum_step_scroll, dm.step_count, ev.x) orelse {
                app.drum_paint_state = null;
                return;
            };
            app.drum_cursor[1] = step;
            history.recordDrum(app, app.drum_track);
            if (ev.button == .right) {
                step_grid.setStep(dm, @intCast(pad), step, false, DrumMachine.vel_full);
            } else {
                dm.toggleStep(@intCast(pad), step);
            }
            app.drum_paint_state = dm.stepActive(@intCast(pad), step);
        },
        .drag => {
            const state = app.drum_paint_state orelse return;
            const dm = app.drumMachine();
            const step = step_grid.stepAt(u16, gutter, app.drumCellWidth(), app.drum_step_scroll, dm.step_count, ev.x) orelse return;
            app.drum_cursor[0] = @intCast(pad);
            app.drum_cursor[1] = step;
            step_grid.setStep(dm, @intCast(pad), step, state, DrumMachine.vel_full);
        },
        .release => app.drum_paint_state = null,
        else => {},
    }
}

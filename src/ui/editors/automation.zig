//! Per-clip gain/pan/instrument-param automation editor: a breakpoint
//! grid, vim-style. The cursor walks the clip's beat axis in 16th steps;
//! j/k nudge the value at the cursor's exact beat, creating a point from
//! the curve's interpolated value there (so a nudge on a bare stretch
//! doesn't jump to an arbitrary default). tab cycles gain -> pan -> the
//! instrument params already automated on this clip; `p` opens the param
//! picker (see `instrumentAutomatableParams`), so paste is `P` here.
//! Motions, operators, visual mode and `.` follow the shared grammar
//! (docs/editing-grammar.md); range ops act on breakpoints only, not the
//! interpolated shape between them. Render half: views/automation.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const automation_mod = ws.dsp.automation;
const AutomationPoint = automation_mod.AutomationPoint;
const App = @import("../app.zig").App;

pub fn playheadBeat(clip: *const ws.Clip, global: f64, playing: bool) ?f64 {
    if (!playing) return null;
    const start = ws.time_grid.tickToBeat(clip.start_tick);
    const local = global - start;
    const length = ws.time_grid.tickToBeat(clip.length_ticks);
    return if (local >= 0 and local < length) local else null;
}
const history = @import("../history.zig");
const fuzzy = @import("../fuzzy.zig");
const step_grid = @import("step_grid.zig");

/// Left indent before the step columns start - shared with the TUI view's
/// draw path so a click/scroll's column maps to the same step the bar
/// graph/caret row actually draw it at.
pub const gutter: usize = 3;

/// Which curve h/l + j/k currently edit. `gain`/`pan` are the two universal
/// targets, always available on any clip (mix-bus params). `synth_param`
/// names either the current track's instrument's continuous params
/// (`instance_id == 0`, `param_id` a `setParamAbsolute` id - despite the
/// name (kept from when only PolySynth had automatable params), it covers
/// Sampler, drum machine, SoundFont, and plugin tracks too; `instrumentAutomatableParams`/
/// `findAutomatableParam` below resolve the id against whichever instrument
/// the track actually holds) or a specific FX unit's param (`instance_id`
/// != 0, `param_id` a `dsp.fx_params` local index - see
/// `arrangement.Clip.Automation.SynthParamCurve`'s doc comment for the
/// addressing convention).
pub const SynthParamTarget = struct { instance_id: u32 = 0, param_id: u32 };

pub const AutomationFocus = union(enum) {
    gain,
    pan,
    synth_param: SynthParamTarget,
};

/// Gain (dB, matches `:gain`/`Track.gain_db`) and pan (-1..1, matches
/// `Track.pan`) ranges/steps - same clamps `persist.zig`'s loader enforces.
/// Synth-param ranges/steps come from the current track's instrument's own
/// `automatable_params` table instead (one entry per param, not two
/// constants) - see `instrumentAutomatableParams`.
const gain_range = [2]f32{ -60.0, 12.0 };
const pan_range = [2]f32{ -1.0, 1.0 };

/// Open the automation editor on the clip under the arrangement cursor.
/// `cursor_tick` need only fall inside the clip's span - the link is stored
/// against the clip's own `start_tick` (see `App.automation_clip`'s doc
/// comment), matching `piano_clip_link`'s convention.
pub fn switchTo(app: *App, track: u16, cursor_tick: u32) void {
    const lane = app.session.arrangement.lane(track) orelse return;
    const clip = lane.clipAt(cursor_tick) orelse {
        app.setStatus("no clip here - enter stamps one, then 'a' automates it", .{});
        return;
    };
    app.automation_clip = .{ .track = track, .start_tick = clip.start_tick };
    app.automation_track = track;
    // A previous clip may have left the editor on a synth param this one
    // doesn't have a lane for yet - fall back to gain rather than opening on
    // a curve this clip has no data for.
    if (std.meta.activeTag(app.automation_focus) == .synth_param) {
        const t = app.automation_focus.synth_param;
        if (clip.automation.findSynthParam(t.instance_id, t.param_id) == null) {
            app.automation_focus = .gain;
        }
    }
    app.automation_cursor_step = 0;
    app.automation_scroll = 0;
    app.view = .automation;
}

/// Resolve `app.automation_clip` to a live pointer, relocating by (track,
/// start_tick) since clip storage can move as the lane is edited. Null if the
/// clip vanished from under the editor (deleted, moved) - `App.exitStaleEditors`
/// bounces the view back to arrangement in that case.
pub fn currentClip(app: anytype) ?*ws.Clip {
    const link = app.automation_clip orelse return null;
    const lane = app.session.arrangement.lane(link.track) orelse return null;
    return lane.clipAt(link.start_tick);
}

/// Last valid cursor step: the clip's own end, inclusive - lets a fade
/// resolve exactly at the clip's last instant, not one step short of it.
fn maxStep(_: *App, clip: *const ws.Clip) u32 {
    return @max(1, clip.length_ticks / 8);
}

/// The mutable points-slice pointer for `target`, creating an empty synth-
/// param lane on demand if none exists yet. In practice a `.synth_param`
/// focus is only ever reached via the picker (which creates the lane before
/// switching focus) or `nextTarget` (which only offers params that already
/// have one) - the on-demand create here is just defence in depth, not the
/// primary path.
pub fn curvePoints(app: *App, clip: *ws.Clip, target: AutomationFocus) !*[]AutomationPoint {
    return switch (target) {
        .gain => &clip.automation.gain,
        .pan => &clip.automation.pan,
        .synth_param => |t| try clip.automation.synthParamPoints(app.allocator, t.instance_id, t.param_id),
    };
}

pub fn curvePointsConst(clip: *const ws.Clip, target: AutomationFocus) []const AutomationPoint {
    return switch (target) {
        .gain => clip.automation.gain,
        .pan => clip.automation.pan,
        .synth_param => |t| clip.automation.findSynthParam(t.instance_id, t.param_id) orelse &.{},
    };
}

/// The current automation track's own `automatable_params` table - PolySynth,
/// Sampler, drum machine, slicer, SoundFont, CLAP, or VST3 params, and empty for any other instrument kind
/// (drum machine and slicer use current row's packed id space; empty stays empty,
/// matching the picker's own gate in `openParamPicker`). `pub` so app.zig's picker key/mouse
/// handling can resolve the same table without duplicating the instrument
/// dispatch.
pub fn instrumentAutomatableParams(app: *App) []const ws.dsp.device.AutomatableParam {
    if (app.automation_track >= app.session.racks.items.len) return &.{};
    return switch (app.session.racks.items[app.automation_track].instrument) {
        .drum_machine => ws.dsp.DrumMachine.automatableParams(@intCast(app.drum_cursor[0])),
        .slicer => ws.dsp.Slicer.automatableParams(@intCast(app.slicer_cursor[0])),
        else => |*instrument| instrument.automatableParams(),
    };
}

pub fn findAutomatableParam(app: *App, id: u32) ?*const ws.dsp.device.AutomatableParam {
    if (app.automation_track < app.session.racks.items.len and app.session.racks.items[app.automation_track].instrument == .drum_machine)
        return if (id <= std.math.maxInt(u16)) ws.dsp.DrumMachine.findAutomatableParam(@intCast(id)) else null;
    if (app.automation_track < app.session.racks.items.len and app.session.racks.items[app.automation_track].instrument == .slicer)
        return if (id <= std.math.maxInt(u16)) ws.dsp.Slicer.findAutomatableParam(@intCast(id)) else null;
    for (instrumentAutomatableParams(app)) |*param| if (param.id == id) return param;
    return null;
}

/// The FX unit `instance_id` names, if it's still in the current automation
/// track's chain - null if the unit was removed since the lane was created
/// (a stale lane then just reads/shows as "?", same "vanished target" case
/// `nextTarget` already handles for instrument params).
pub fn findFxUnit(app: *App, instance_id: u32) ?*ws.FxUnit {
    if (app.automation_track >= app.session.racks.items.len) return null;
    return app.session.racks.items[app.automation_track].fx.findInstance(instance_id);
}

/// Display label for `target` - an instrument param's own label, or an FX
/// unit's local param name (no per-unit label table exists, unlike
/// instrument params - `dsp.fx_params.paramName` is the short knob name the
/// FX chain editor itself uses).
pub fn targetLabel(app: *App, target: SynthParamTarget) []const u8 {
    if (target.instance_id == 0)
        return if (findAutomatableParam(app, target.param_id)) |info| info.label else "?";
    const unit = findFxUnit(app, target.instance_id) orelse return "?";
    return ws.dsp.fx_params.paramName(&unit.payload, target.param_id);
}

/// [min, max] for `target`, instrument or FX unit.
pub fn targetRange(app: *App, target: SynthParamTarget) [2]f32 {
    if (target.instance_id == 0)
        return if (findAutomatableParam(app, target.param_id)) |info| info.range else .{ 0.0, 1.0 };
    const unit = findFxUnit(app, target.instance_id) orelse return .{ 0.0, 1.0 };
    return ws.dsp.fx_params.paramRange(&unit.payload, target.param_id);
}

pub fn curveRange(app: *App, target: AutomationFocus) [2]f32 {
    return switch (target) {
        .gain => gain_range,
        .pan => pan_range,
        .synth_param => |t| targetRange(app, t),
    };
}

fn curveStep(app: *App, target: AutomationFocus) f32 {
    return switch (target) {
        .gain => app.automation_gain_step_db,
        .pan => app.automation_pan_step,
        .synth_param => |t| if (t.instance_id == 0)
            (if (findAutomatableParam(app, t.param_id)) |info| info.step else 0.01)
        else if (findFxUnit(app, t.instance_id)) |unit|
            ws.dsp.fx_params.paramStep(&unit.payload, t.param_id, false)
        else
            0.01,
    };
}

/// `tab`'s cycle: gain -> pan -> whichever synth/FX params already have a
/// lane on THIS clip (in the order they were first added) -> back to gain.
/// Unlike gain/pan, a param with no lane yet isn't offered - that's what the
/// picker (`p`) is for, since offering every candidate via tab would make
/// the common case (a handful of active lanes) slow to cycle through.
fn nextTarget(clip: *const ws.Clip, cur: AutomationFocus) AutomationFocus {
    const items = clip.automation.synth_params.items;
    switch (cur) {
        .gain => return .pan,
        .pan => return if (items.len > 0) .{ .synth_param = .{ .instance_id = items[0].instance_id, .param_id = items[0].param_id } } else .gain,
        .synth_param => |t| {
            for (items, 0..) |sp, i| {
                if (sp.instance_id != t.instance_id or sp.param_id != t.param_id) continue;
                return if (i + 1 < items.len)
                    .{ .synth_param = .{ .instance_id = items[i + 1].instance_id, .param_id = items[i + 1].param_id } }
                else
                    .gain;
            }
            return .gain; // the focused param vanished from this clip - bounce home
        },
    }
}

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const clip = currentClip(app) orelse return false;

    // Visual mode: a step-range selection on the currently-edited curve.
    // Motions and range y/d/p live in handleVisual; everything else is
    // swallowed so a stray keypress can't jump views or switch curves
    // mid-selection.
    if (app.modal.mode == .visual) return handleVisual(app, key, clip);

    // Operator-pending: d/y + time motion, shared grammar
    // (docs/editing-grammar.md), through the same delete/yankSelection
    // path visual mode uses. Line tier (dd/yy) is the whole curve, which
    // is simply the full [0, maxStep] range through those same functions.
    if (app.automation_op_pending) |op| {
        app.automation_op_pending = null;
        switch (key) {
            // zig fmt: off
            .escape => { app.automation_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            .char => |c| switch (c) {
                '0' => {
                    if (app.modal.count > 0) { app.automation_op_pending = op; return false; }
                    app.automation_cursor_step = 0;
                    finishOperator(app, clip, op);
                    return true;
                },
                '1'...'9' => { app.automation_op_pending = op; return false; },
                // zig fmt: on
                'd', 'y' => {
                    if (c == op) {
                        const saved = app.automation_cursor_step;
                        app.automation_visual_anchor = 0;
                        app.automation_cursor_step = maxStep(app, clip);
                        if (op == 'd') deleteSelection(app, clip) else yankSelection(app, clip);
                        app.automation_cursor_step = saved;
                    } else app.setStatus("cancelled", .{});
                    return true;
                },
                // zig fmt: off
                'h' => { moveCursor(app, clip, -app.takeCount()); finishOperator(app, clip, op); return true; },
                'l' => { moveCursor(app, clip, app.takeCount()); finishOperator(app, clip, op); return true; },
                'H' => { moveCursor(app, clip, -4 * app.takeCount()); finishOperator(app, clip, op); return true; },
                'L' => { moveCursor(app, clip, 4 * app.takeCount()); finishOperator(app, clip, op); return true; },
                'g' => { app.automation_cursor_step = 0; finishOperator(app, clip, op); return true; },
                'G' => { app.automation_cursor_step = maxStep(app, clip); finishOperator(app, clip, op); return true; },
                // dw/yw act on exactly the beat(s) through the end of the nth
                // beat forward, not w's raw landing step (see piano.zig's
                // identical comment - same vim dw nuance).
                'w' => { operatorBarForward(app, clip, app.takeCount()); finishOperator(app, clip, op); return true; },
                'b' => { operatorBarBackward(app, clip, app.takeCount()); finishOperator(app, clip, op); return true; },
                else => { app.automation_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
            },
            else => { app.automation_visual_anchor = null; app.setStatus("cancelled", .{}); return true; },
        }
    }

    // Multi-key prefixes (docs/editing-grammar.md): `g` armed below drains
    // on the next key (gg = clip start, gG = clip end). An unknown pair
    // falls through, so a prefix never eats a key it doesn't own.
    if (app.takePrefix(key)) |p| switch (p) {
        'g' => switch (key.char) {
            'g' => { app.automation_cursor_step = 0; return true; },
            '0' => {
                if (app.modal.count > 0) return false;
                app.automation_cursor_step = 0;
                return true;
            },
            'G' => { app.automation_cursor_step = maxStep(app, clip); return true; },
            else => {},
        },
        else => {},
    };

    switch (key) {
        .escape => { app.view = .arrangement; return true; },
        .ctrl_r => { history.doRedo(app); return true; },
        .tab => {
            app.automation_focus = nextTarget(clip, app.automation_focus);
            return true;
        },
        .char => |c| switch (c) {
            // Block insert mode - piano keys conflict with cursor/nudge navigation.
            'i' => return true,
            'h' => { moveCursor(app, clip, -app.takeCount()); return true; },
            'l' => { moveCursor(app, clip, app.takeCount()); return true; },
            'H' => { moveCursor(app, clip, -4 * app.takeCount()); return true; },
            'L' => { moveCursor(app, clip, 4 * app.takeCount()); return true; },
            'j' => { nudgeValue(app, clip, -app.takeCount()); return true; },
            'k' => { nudgeValue(app, clip, app.takeCount()); return true; },
            'J' => { nudgeValue(app, clip, -10 * app.takeCount()); return true; },
            'K' => { nudgeValue(app, clip, 10 * app.takeCount()); return true; },
            '0' => {
                if (app.modal.count > 0) return false;
                app.automation_cursor_step = 0;
                return true;
            },
            // g/G are a two-key pair (gg = clip start, gG = clip end),
            // matching the piano roll and drum grid's convention: 'g' arms
            // the prefix, the follow-up key drains it above.
            'g' => { _ = app.armPrefix('g'); return true; },
            // w/b: vim's word motion, one tier up from h/l's step
            // ("char") granularity - jump to the start of the
            // next/current-or-previous beat.
            'w' => { jumpBar(app, clip, app.takeCount()); return true; },
            'b' => { jumpBar(app, clip, -app.takeCount()); return true; },
            'x' => { deletePoint(app, clip); return true; },
            // c: cycle the shape of the ramp leaving the point under the
            // cursor (linear -> hold -> ease). The graph redraws through
            // `interpolate`, so the new shape is visible immediately.
            'c' => { cycleCurve(app, clip); return true; },
            // d/y are operators (see armOperator) - dd/yy act on the whole
            // curve.
            'd' => { armOperator(app, 'd'); return true; },
            'y' => { armOperator(app, 'y'); return true; },
            // Open the synth-param picker (poly_synth tracks only) to start
            // automating a param that isn't on this clip yet - tab only
            // cycles curves that already have a lane (see nextTarget).
            'p' => { openParamPicker(app); return true; },
            // 'p' is already the param-picker key (above), so paste - which
            // piano/drum/arrangement all bind to plain p/P - lives on 'P'
            // here instead. Calls the same pasteSelection visual mode's p/P
            // use; it doesn't require actually being in visual mode.
            'P' => { pasteSelection(app, clip); return true; },
            // One curve at a time: there is no second axis to bound, so
            // `v` and `V` are the same selection here. `V` is accepted
            // anyway so the grammar reads the same in every editor.
            'v', 'V' => {
                app.automation_visual_anchor = app.automation_cursor_step;
                app.modal.mode = .visual;
                app.setStatus("visual: hjkl extend, y/d/p act on the range, esc cancels", .{});
                return true;
            },
            '.' => { repeatLastEdit(app, clip); return true; },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            // zig fmt: on
            else => return false,
        },
        else => return false,
    }
}

/// Visual mode's reduced key set - see docs/editing-grammar.md for the
/// swallow-everything-else and digits-fall-through rules every editor shares.
fn handleVisual(app: *App, key: modal_mod.Key, clip: *ws.Clip) bool {
    switch (key) {
        // zig fmt: off
        .escape => { exitVisual(app); app.setStatus("selection cancelled", .{}); return true; },
        .char => |c| switch (c) {
            'h' => { moveCursor(app, clip, -app.takeCount()); return true; },
            'l' => { moveCursor(app, clip, app.takeCount()); return true; },
            'H' => { moveCursor(app, clip, -4 * app.takeCount()); return true; },
            'L' => { moveCursor(app, clip, 4 * app.takeCount()); return true; },
            'g' => { app.automation_cursor_step = 0; return true; },
            'G' => { app.automation_cursor_step = maxStep(app, clip); return true; },
            'w' => { jumpBar(app, clip, app.takeCount()); return true; },
            'b' => { jumpBar(app, clip, -app.takeCount()); return true; },
            // vim's `o`: bounce the cursor to the selection's other end
            // (see the drum grid's identical arm).
            'o' => {
                if (app.automation_visual_anchor) |a| {
                    app.automation_visual_anchor = app.automation_cursor_step;
                    app.automation_cursor_step = a;
                }
                return true;
            },
            'y' => { yankSelection(app, clip); return true; },
            'd' => { deleteSelection(app, clip); return true; },
            'p', 'P' => { pasteSelection(app, clip); return true; },
            // zig fmt: on
            '1'...'9' => return false,
            else => return true,
        },
        else => return true,
    }
}

/// Leave visual mode, clearing the anchor so the selection can't linger.
fn exitVisual(app: *App) void {
    _ = app.modal.setMode(.normal);
    app.automation_visual_anchor = null;
}

fn selectionRange(app: *App) step_grid.StepRange(u32) {
    return step_grid.selectionRange(u32, app.automation_visual_anchor, app.automation_cursor_step);
}

/// Yank every breakpoint on the current curve whose beat falls within the
/// selected step range, rebased so the range's first step becomes beat 0.
fn yankSelection(app: *App, clip: *ws.Clip) void {
    const r = selectionRange(app);
    const lo_beat = @as(f64, @floatFromInt(r.lo)) * 0.25;
    const hi_beat = @as(f64, @floatFromInt(r.hi)) * 0.25 + 0.25;
    const points = (curvePoints(app, clip, app.automation_focus) catch {
        app.setStatus("yank failed (out of memory)", .{});
        return;
    }).*;
    var list: std.ArrayListUnmanaged(AutomationPoint) = .empty;
    for (points) |p| {
        if (p.beat < lo_beat or p.beat >= hi_beat) continue;
        list.append(app.allocator, .{ .beat = p.beat - lo_beat, .value = p.value }) catch {
            list.deinit(app.allocator);
            app.setStatus("yank failed (out of memory)", .{});
            return;
        };
    }
    const owned = list.toOwnedSlice(app.allocator) catch {
        list.deinit(app.allocator);
        app.setStatus("yank failed (out of memory)", .{});
        return;
    };
    if (app.automation_range_clip) |old| app.allocator.free(old.points);
    app.automation_range_clip = .{ .points = owned };
    app.setStatus("yanked {d} point(s) ({d} steps)", .{ owned.len, r.hi - r.lo + 1 });
    exitVisual(app);
}

/// Delete every breakpoint on the current curve whose beat falls within the
/// selected step range.
fn deleteSelection(app: *App, clip: *ws.Clip) void {
    const r = selectionRange(app);
    const lo_beat = @as(f64, @floatFromInt(r.lo)) * 0.25;
    const hi_beat = @as(f64, @floatFromInt(r.hi)) * 0.25 + 0.25;
    history.recordLane(app, app.automation_track);
    const points = curvePoints(app, clip, app.automation_focus) catch {
        app.setStatus("delete failed (out of memory)", .{});
        return;
    };
    var removed: usize = 0;
    var i: usize = 0;
    while (i < points.len) {
        if (points.*[i].beat >= lo_beat and points.*[i].beat < hi_beat) {
            _ = automation_mod.removePoint(app.allocator, points, points.*[i].beat) catch {
                app.setStatus("delete failed (out of memory)", .{});
                return;
            };
            removed += 1;
        } else i += 1;
    }
    app.last_edit = .{ .automation_range_delete = .{ .width = r.hi - r.lo + 1 } };
    app.setStatus("deleted {d} point(s)", .{removed});
    if (app.session.song_mode) app.session.rebuildSongData();
    exitVisual(app);
}

/// Paste the range clipboard's breakpoints onto the curve active *now*
/// (`automation_focus`, which may differ from the one yanked if `tab` was
/// pressed since), starting at the cursor step.
fn pasteSelection(app: *App, clip: *ws.Clip) void {
    const rc = app.automation_range_clip orelse {
        app.setStatus("nothing yanked - select a range and y first", .{});
        exitVisual(app);
        return;
    };
    history.recordLane(app, app.automation_track);
    const points = curvePoints(app, clip, app.automation_focus) catch {
        app.setStatus("paste failed (out of memory)", .{});
        return;
    };
    const base_beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;
    const max_beat: f64 = @as(f64, @floatFromInt(maxStep(app, clip))) * 0.25;
    // Points are rebased in beat order (see yankSelection), so once one
    // clamps against `max_beat` every point after it clamps to the exact
    // same beat too - setPoint overwrites rather than adding a second point
    // there, silently collapsing the run to one unless it's called out.
    var placed: usize = 0;
    var last_beat: ?f64 = null;
    for (rc.points) |p| {
        const beat = std.math.clamp(base_beat + p.beat, 0, max_beat);
        automation_mod.setPoint(app.allocator, points, beat, p.value) catch {
            app.setStatus("paste failed (out of memory)", .{});
            return;
        };
        if (last_beat == null or @abs(beat - last_beat.?) >= 1e-9) placed += 1;
        last_beat = beat;
    }
    app.last_edit = .automation_range_paste;
    if (app.session.song_mode) app.session.rebuildSongData();
    if (placed < rc.points.len)
        app.setStatus("pasted {d} of {d} point(s) - ran out of pattern", .{ placed, rc.points.len })
    else
        app.setStatus("pasted {d} point(s)", .{placed});
    exitVisual(app);
}

/// `.`: replay the last nudge or visual range delete/paste at the current
/// cursor. No-op ("nothing to repeat") if the last edit came from a
/// different editor or there wasn't one.
fn repeatLastEdit(app: *App, clip: *ws.Clip) void {
    switch (app.last_edit) {
        .automation_nudge => |v| nudgeValue(app, clip, v.delta),
        .automation_range_delete => |v| {
            app.automation_visual_anchor = app.automation_cursor_step + (v.width - 1);
            deleteSelection(app, clip);
        },
        .automation_range_paste => pasteSelection(app, clip),
        else => app.setStatus("nothing to repeat", .{}),
    }
}

/// The step under screen column `x`, or null if `x` falls in the left
/// gutter or past the clip's own end. Shared logic for click and scroll.
fn stepAt(app: *App, clip: *const ws.Clip, x: u16) ?u32 {
    const g: u32 = @intCast(gutter);
    if (x < g) return null;
    const step = app.automation_scroll + (@as(u32, x) - g);
    if (step > maxStep(app, clip)) return null;
    return step;
}

/// Click or drag in the graph to paint points. Right-drag erases explicit
/// points. Ruler/caret clicks only move the cursor. Scroll moves it and
/// nudges the value; **Ctrl** nudges coarsely, **Shift** moves one step, and
/// **Alt** jumps one beat.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, view_rows: usize) void {
    // The paint stroke outlives the guards below - a release on the title
    // row, or after the clip went away mid-gesture, still has to end it, or
    // the next press keeps painting. Same rule piano.zig spells out.
    if (ev.kind == .release) {
        app.automation_mouse_edit = false;
        app.automation_mouse_erase = false;
        return;
    }
    const clip = currentClip(app) orelse return;
    if (row == 0) return;
    const graph_rows: usize = @max(1, @min(18, view_rows -| 7));
    const in_graph = row >= 2 and row < 2 + graph_rows;
    switch (ev.kind) {
        .press => {
            const step = stepAt(app, clip, ev.x) orelse return;
            app.automation_cursor_step = step;
            if (!in_graph) return;
            history.recordLane(app, app.automation_track);
            app.automation_mouse_edit = true;
            app.automation_mouse_erase = ev.button == .right;
            paintMouse(app, clip, row, graph_rows);
        },
        .drag => if (app.automation_mouse_edit) {
            const step = stepAt(app, clip, ev.x) orelse return;
            app.automation_cursor_step = step;
            paintMouse(app, clip, row, graph_rows);
        },
        .scroll_up, .scroll_down => {
            const step = stepAt(app, clip, ev.x) orelse return;
            app.automation_cursor_step = step;
            const dir: i32 = if (ev.kind == .scroll_up) 1 else -1;
            if (ev.alt)
                jumpBar(app, clip, -dir)
            else if (ev.shift)
                moveCursor(app, clip, -dir)
            else
                nudgeValue(app, clip, dir * (if (ev.ctrl) @as(i32, 10) else 1));
        },
        .release => unreachable, // handled above, before the guards
    }
}

fn paintMouse(app: *App, clip: *ws.Clip, row: usize, graph_rows: usize) void {
    if (row < 2 or row >= 2 + graph_rows) return;
    const beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;
    const points = curvePoints(app, clip, app.automation_focus) catch return;
    if (app.automation_mouse_erase) {
        _ = automation_mod.removePoint(app.allocator, points, beat) catch return;
    } else {
        const range = curveRange(app, app.automation_focus);
        const norm = @as(f32, @floatFromInt(2 + graph_rows - row)) / @as(f32, @floatFromInt(graph_rows));
        const value = range[0] + (range[1] - range[0]) * norm;
        automation_mod.setPoint(app.allocator, points, beat, value) catch return;
    }
    app.dirty = true;
    if (app.session.song_mode) app.session.rebuildSongData();
}

fn moveCursor(app: *App, clip: *const ws.Clip, delta: i32) void {
    const max_step: i64 = maxStep(app, clip);
    const cur: i64 = @as(i64, app.automation_cursor_step) + delta;
    app.automation_cursor_step = @intCast(std.math.clamp(cur, 0, max_step));
}

/// "Bar" length in steps - despite the name, this is one beat (4 steps,
/// always straight 16ths - automation has no grid toggle like the piano
/// roll's `T`), matching the drum grid's own hardcoded word-tier group and
/// the piano roll's `barLenSteps` (see its own note on the earlier bug this
/// mirrors: a real beats-per-bar multiply here would make w/b jump a full
/// bar, 4x further than the drum grid's equivalent motion).
fn barLenSteps(app: *App) u32 {
    _ = app;
    return 4;
}

/// w/b: jump the cursor `delta` beats forward/back (vim's word motion, one
/// tier up from h/l's step granularity) - snaps to the nearest beat boundary
/// first, then moves whole beats from there. `maxStep(app, clip) + 1` turns
/// the clip's inclusive last-step into the step_count step_grid expects.
fn jumpBar(app: *App, clip: *const ws.Clip, delta: i32) void {
    step_grid.jumpBar(&app.automation_cursor_step, delta, maxStep(app, clip) + 1, barLenSteps(app));
}

/// dw/yw's range end: the last step of the nth beat forward (inclusive), not
/// w's own landing step (the *next* beat's first step) - see the
/// operator-pending block's comment on 'w'.
fn operatorBarForward(app: *App, clip: *const ws.Clip, n: i32) void {
    step_grid.operatorBarForward(&app.automation_cursor_step, n, maxStep(app, clip) + 1, barLenSteps(app));
}

/// db/yb's range start: the first step of the nth beat back - the anchor
/// (the cursor's position when `d`/`y` was pressed) stays the range's other
/// (inclusive) end, so this covers "back to the start of this-or-an-earlier
/// beat, through where you started."
fn operatorBarBackward(app: *App, clip: *const ws.Clip, n: i32) void {
    step_grid.operatorBarBackward(&app.automation_cursor_step, n, maxStep(app, clip) + 1, barLenSteps(app));
}

/// Arm `d`/`y` as a pending operator - see docs/editing-grammar.md.
fn armOperator(app: *App, op: u8) void {
    app.automation_visual_anchor = app.automation_cursor_step;
    app.automation_op_pending = op;
    app.setStatus("{c}: h/l/H/L/g/G/w/b act on the range, {c}{c} acts on the whole curve", .{ op, op, op });
}

/// Run the armed operator over anchor-to-cursor.
fn finishOperator(app: *App, clip: *ws.Clip, op: u8) void {
    if (op == 'd') deleteSelection(app, clip) else yankSelection(app, clip);
}

/// Nudge the curve's value at the cursor's exact beat by `steps`, creating a
/// point there if none exists - starting from whatever the curve currently
/// interpolates to at that beat (0 if the curve is empty), so the first nudge
/// on a bare stretch moves relative to what's already playing, not an
/// arbitrary default.
fn nudgeValue(app: *App, clip: *ws.Clip, steps: i32) void {
    if (steps == 0) return;
    const target = app.automation_focus;
    const beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;
    const points = curvePoints(app, clip, target) catch {
        app.setStatus("automation edit failed (out of memory)", .{});
        return;
    };
    const range = curveRange(app, target);
    const cur = automation_mod.interpolate(points.*, beat) orelse 0.0;
    const new_val = std.math.clamp(
        cur + @as(f32, @floatFromInt(steps)) * curveStep(app, target),
        // zig fmt: off
        range[0], range[1],
        // zig fmt: on
    );
    // Captured before the mutation - the whole lane, same granularity the
    // arrangement's own clip edits (move/delete) undo at.
    history.recordLane(app, app.automation_track);
    automation_mod.setPoint(app.allocator, points, beat, new_val) catch {
        app.setStatus("automation edit failed (out of memory)", .{});
        return;
    };
    app.last_edit = .{ .automation_nudge = .{ .delta = steps } };
    if (app.session.song_mode) app.session.rebuildSongData();
}

/// `c`: walk the point under the cursor through the segment shapes. Needs an
/// explicit point - an interpolated step has no shape of its own to set, it
/// is already being drawn by the shape of the point behind it.
fn cycleCurve(app: *App, clip: *ws.Clip) void {
    const beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;
    const points = curvePoints(app, clip, app.automation_focus) catch {
        app.setStatus("automation edit failed (out of memory)", .{});
        return;
    };
    const cur = automation_mod.curveAt(points.*, beat) orelse {
        app.setStatus("no point exactly here", .{});
        return;
    };
    const next: automation_mod.Curve = switch (cur) {
        .linear => .hold,
        .hold => .ease,
        .ease => .linear,
    };
    history.recordLane(app, app.automation_track);
    _ = automation_mod.setCurve(points.*, beat, next);
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("curve {s}", .{@tagName(next)});
}

fn deletePoint(app: *App, clip: *ws.Clip) void {
    const target = app.automation_focus;
    const beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;
    const points = curvePoints(app, clip, target) catch {
        app.setStatus("automation edit failed (out of memory)", .{});
        return;
    };
    if (!automation_mod.hasPointAt(points.*, beat)) {
        app.setStatus("no point exactly here", .{});
        return;
    }
    history.recordLane(app, app.automation_track);
    _ = automation_mod.removePoint(app.allocator, points, beat) catch {
        app.setStatus("automation edit failed (out of memory)", .{});
        return;
    };
    if (app.session.song_mode) app.session.rebuildSongData();
    app.setStatus("point removed", .{});
}

/// Open the instrument-param picker (`p`) for any track kind exposing a
/// `setParamAbsolute` id space. Drum machine/slicer params remain per-pad or
/// per-slice rather than a single track curve. CLAP remains outside this picker.
/// Places the cursor on the currently-focused param if there is one, else 0,
/// so re-opening the picker on an already-automated param starts there.
fn openParamPicker(app: *App) void {
    const params = instrumentAutomatableParams(app);
    if (params.len == 0) {
        app.setStatus("no automatable parameters on this track kind", .{});
        return;
    }
    if (std.meta.activeTag(app.automation_focus) == .synth_param) {
        const cur = app.automation_focus.synth_param;
        if (cur.instance_id == 0) {
            for (params, 0..) |p, i| {
                // zig fmt: off
                if (p.id == cur.param_id) { app.automation_param_cursor = @intCast(i); break; }
                // zig fmt: on
            }
        }
    }
    app.automation_param_scroll = 0;
    app.automation_param_filter_len = 0;
    app.view = .automation_param_picker;
}

/// Chosen from the picker (enter/click) - creates an empty lane for the
/// param on the current clip if none exists yet, switches focus to it, and
/// returns to the automation view.
pub fn selectParam(app: *App, param_id: u32) void {
    const clip = currentClip(app) orelse return;
    _ = clip.automation.synthParamPoints(app.allocator, 0, param_id) catch {
        app.setStatus("couldn't add param lane (out of memory)", .{});
        return;
    };
    app.automation_focus = .{ .synth_param = .{ .param_id = param_id } };
    app.view = .automation;
}

/// Create (or focus, if it already exists) an automation lane for FX unit
/// `instance_id`'s param `param_id`, on the clip the automation editor was
/// last opened on for `track` - the FX-chain-view counterpart to
/// `selectParam`, reached from there (spectrum_ed's `A` key) instead of the
/// instrument picker, since an FX unit's params aren't shaped like
/// `AutomatableParam` (no shared section/label/range table across every FX
/// kind) so they don't fit that picker. Automation is clip-scoped, so this
/// needs a clip already selected via the arrangement's own `a` - there's no
/// clip to attach a lane to otherwise (matches master/group FX chains never
/// being automatable at all: they have no clip).
pub fn addFxParamLane(app: *App, track: u16, instance_id: u32, param_id: u32) void {
    if (app.automation_clip == null or app.automation_track != track) {
        app.setStatus("open automation on a clip first ('a' in the arrangement)", .{});
        return;
    }
    const clip = currentClip(app) orelse {
        app.setStatus("that clip is gone", .{});
        return;
    };
    _ = clip.automation.synthParamPoints(app.allocator, instance_id, param_id) catch {
        app.setStatus("couldn't add param lane (out of memory)", .{});
        return;
    };
    app.automation_focus = .{ .synth_param = .{ .instance_id = instance_id, .param_id = param_id } };
    app.view = .automation;
}

/// One printed row of the param picker: either a section header (dim label
/// row, not selectable) or a param (index into the instrument's own
/// `automatable_params` table - PolySynth's or Sampler's, whichever `params`
/// the caller resolved via `instrumentAutomatableParams`). Shared by the
/// picker's render (views/automation.zig) and its mouse hit-testing
/// (App.automationParamPickerMouse) so the two can't drift out of sync -
/// same "shared row math" convention views/synth.zig's import of
/// editors/synth.zig's `paramRow` already uses.
pub const ParamDisplayRow = union(enum) {
    header: []const u8,
    param: usize,
};

/// Room for every param plus one header per distinct section - generous
/// fixed cap, not a computed expression, so it doesn't need updating if
/// either instrument's `automatable_params` grows a little. PolySynth alone
/// is past 100 params across 30+ sections now, so this has real headroom
/// above that, not just above the old 64 (which one FX-chain-params batch
/// silently overflowed: `buf[n] = ...` with no bounds check, an out-of-
/// bounds write that panics under the default Debug build the moment a
/// synth track's picker had enough rows).
pub const max_param_display_rows = 256;

/// The `/` filter narrowing the param picker right now: the modal search
/// buffer while it's being typed (live narrowing), else the last submitted
/// pattern - same shape as `preset_ed.activeFilter`.
pub fn activeParamFilter(app: *App) []const u8 {
    return app.pickerFilterText(.automation_param_picker, &app.automation_param_filter_buf, app.automation_param_filter_len);
}

fn paramMatches(p: ws.dsp.device.AutomatableParam, filter: []const u8) bool {
    if (filter.len == 0) return true;
    return fuzzy.matches(filter, p.label) or fuzzy.matches(filter, p.section);
}

/// `params` is the current track's own `automatable_params` table (see
/// `instrumentAutomatableParams`) - the caller resolves it, since views/
/// automation.zig can't import `App` to call that helper itself (see its own
/// `currentClip` doc comment for why view renderers take `app: anytype`).
/// `filter` narrows to params (and their section) matching the fuzzy `/`
/// pattern; a section with no matching params drops its header too.
/// Mod-destination-only params never list: see `AutomatableParam.modDestOnly`
/// for why an automation lane on one would write a field nothing plays.
pub fn buildParamDisplayRows(params: []const ws.dsp.device.AutomatableParam, filter: []const u8, buf: *[max_param_display_rows]ParamDisplayRow) []ParamDisplayRow {
    var n: usize = 0;
    var last_section: []const u8 = "";
    for (params, 0..) |p, i| {
        if (p.modDestOnly()) continue;
        if (!paramMatches(p, filter)) continue;
        if (!std.mem.eql(u8, p.section, last_section)) {
            if (n >= buf.len) return buf[0..n];
            buf[n] = .{ .header = p.section };
            n += 1;
            last_section = p.section;
        }
        if (n >= buf.len) return buf[0..n];
        buf[n] = .{ .param = i };
        n += 1;
    }
    return buf[0..n];
}

/// Move the picker cursor by `delta` among displayed (filter-matching) rows
/// only, so j/k never lands on something the current filter is hiding.
pub fn moveParamCursor(app: *App, delta: i32) void {
    const params = instrumentAutomatableParams(app);
    var buf: [max_param_display_rows]ParamDisplayRow = undefined;
    const rows_list = buildParamDisplayRows(params, activeParamFilter(app), &buf);
    var pos: usize = 0;
    var count: usize = 0;
    for (rows_list) |r| switch (r) {
        .param => |i| {
            if (i == app.automation_param_cursor) pos = count;
            count += 1;
        },
        .header => {},
    };
    if (count == 0) return;
    const cur: i64 = @intCast(pos);
    const new_pos: usize = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(count - 1))));
    var n: usize = 0;
    for (rows_list) |r| switch (r) {
        .param => |i| {
            if (n == new_pos) {
                app.automation_param_cursor = @intCast(i);
                return;
            }
            n += 1;
        },
        .header => {},
    };
}

/// `g`/`G`: first/last displayed param, mirroring preset_ed's ordinal jump.
pub fn firstParamCursor(app: *App) u8 {
    var buf: [max_param_display_rows]ParamDisplayRow = undefined;
    const rows_list = buildParamDisplayRows(instrumentAutomatableParams(app), activeParamFilter(app), &buf);
    for (rows_list) |r| switch (r) {
        .param => |i| return @intCast(i),
        .header => {},
    };
    return app.automation_param_cursor;
}

pub fn lastParamCursor(app: *App) u8 {
    var buf: [max_param_display_rows]ParamDisplayRow = undefined;
    const rows_list = buildParamDisplayRows(instrumentAutomatableParams(app), activeParamFilter(app), &buf);
    var last: usize = app.automation_param_cursor;
    for (rows_list) |r| switch (r) {
        .param => |i| last = i,
        .header => {},
    };
    return @intCast(last);
}

test "playhead beat is clip-relative and only visible inside clip" {
    const clip = ws.Clip{
        .start_tick = ws.time_grid.ticks_per_beat * 4,
        .length_ticks = ws.time_grid.ticks_per_beat * 2,
        .content = .{ .melodic = .{ .notes = &.{}, .length_beats = 2 } },
    };
    try std.testing.expect(playheadBeat(&clip, 3, true) == null);
    try std.testing.expectApproxEqAbs(@as(f64, 1), playheadBeat(&clip, 5, true).?, 1e-6);
    try std.testing.expect(playheadBeat(&clip, 6, true) == null);
    try std.testing.expect(playheadBeat(&clip, 5, false) == null);
}

//! Sampler-editor input for both targets - a drum machine pad or a standalone
//! Sampler: param row navigation, h/l nudges (routed to the audio thread),
//! pad jumps and audition. The render half lives in views/sampler.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const DrumMachine = ws.dsp.DrumMachine;
const Sampler = ws.dsp.Sampler;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const SamplerMarker = app_mod.SamplerMarker;
const history = @import("../history.zig");
/// Waveform panel caps, shared with the TUI render half (views/sampler.zig):
/// width in columns and height in rows (min'd against the leftover row
/// budget). The mouse hit-testing below mirrors the draw path exactly.
pub const wave_max_w: usize = 240;
pub const wave_max_rows: usize = 14;

/// Number of editable params for the sampler editor's current target.
/// A slice carries the same 10 pad params a drum pad does (start..reverse),
/// minus nothing - root/mono stay sampler-only.
fn paramCount(app: *App) u8 {
    return switch (app.sampler_target) {
        .drum => DrumMachine.pad_param_count,
        .sampler => Sampler.param_count,
        .slice => DrumMachine.pad_param_count,
    };
}

// zig fmt: off
/// Sampler editor: j/k pick a param row, h/l/H/L nudge it. For a drum pad
/// or a slice, 1–8 jump to that slot within the current bank (shared
/// `drum_cursor[0]`/`slicer_cursor[0]`, see movePadBank's doc comment) and
/// esc/e return to the grid that opened it; for a standalone Sampler,
/// esc/e return to the tracks view. a auditions the current pad/slice /
/// the sampler's root note (mirrors the piano roll/drum grid's own
/// audition key - 'p' is reserved for paste elsewhere, so it's kept free
/// here rather than meaning something different per view).
pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const is_drum = app.sampler_target == .drum;
    const is_slice = app.sampler_target == .slice;
    switch (key) {
        .escape => {
            history.flushParamNudge(app);
            app.view = returnView(app);
            return true;
        },
        .ctrl_r => { history.doRedo(app); return true; },
        .char => |c| switch (c) {
            // Block insert mode - piano keys conflict with param navigation.
            'i' => return true,
            'e' => {
                history.flushParamNudge(app);
                app.view = returnView(app);
                return true;
            },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            // j/k rows and h/l nudges take a vim count prefix (3j, 5l, …),
            // matching the synth editor's equivalent.
            'j' => { moveCursor(app, app.takeCount()); return true; },
            'k' => { moveCursor(app, -app.takeCount()); return true; },
            'h' => { adjustParam(app, -app.takeCount()); return true; },
            'l' => { adjustParam(app, app.takeCount()); return true; },
            'H' => { adjustParam(app, -10 * app.takeCount()); return true; },
            'L' => { adjustParam(app, 10 * app.takeCount()); return true; },
            'g' => { history.flushParamNudge(app); app.sampler_param = 0; return true; },
            'G' => { history.flushParamNudge(app); app.sampler_param = paramCount(app) - 1; return true; },
            // J/K jump a whole bank of 8 pads/slices - same MPC-style
            // paging as the drum grid's own J/K (editors/drum.zig).
            'K' => {
                if (!is_drum and !is_slice) return false;
                history.flushParamNudge(app);
                movePadBank(app, -8 * app.takeCount());
                return true;
            },
            'J' => {
                if (!is_drum and !is_slice) return false;
                history.flushParamNudge(app);
                movePadBank(app, 8 * app.takeCount());
                return true;
            },
            '1'...'8' => {
                // Only a meaningful jump on a drum pad's or a slice's
                // sampler - a standalone Sampler has no pads, so let the
                // digit fall through to become a count prefix instead
                // (matches j/k now honoring `app.takeCount()` above).
                // Bank-relative: "1" always means the first pad of
                // whichever bank of 8 is currently showing, not absolute
                // pad 0.
                if (!is_drum and !is_slice) return false;
                history.flushParamNudge(app);
                if (is_slice) {
                    const bank = app.slicer_cursor[0] / 8;
                    const slice: u8 = bank * 8 + (c - '1');
                    if (slice < app.slicerInst().slice_count) app.slicer_cursor[0] = slice;
                } else {
                    const bank = app.drum_cursor[0] / 8;
                    const pad: u8 = @intCast(bank * 8 + (c - '1'));
                    if (pad < DrumMachine.max_pads) app.drum_cursor[0] = pad;
                }
                return true;
            },
            'a' => { preview(app); return true; },
            else => return false,
        },
        else => return false,
    }
}

/// Where esc/e land: back to the grid that opened this editor, or the
/// tracks view for a standalone Sampler.
fn returnView(app: *App) app_mod.AppView {
    return switch (app.sampler_target) {
        .drum => .drum_grid,
        .slice => .slicer_grid,
        .sampler => .tracks,
    };
}

/// Move the pad/slice cursor by `delta`, clamped to the target's slot count
/// - shared by J/K here and editors/drum.zig's own movePad (kept separate
/// since the two files don't share a common cursor-motion module).
fn movePadBank(app: *App, delta: i32) void {
    if (app.sampler_target == .slice) {
        const top = @as(i64, app.slicerInst().slice_count) - 1;
        // zig fmt: off
        if (top < 0) { app.slicer_cursor[0] = 0; return; }
        // zig fmt: on
        app.slicer_cursor[0] = @intCast(clampCursor(app.slicer_cursor[0], delta, top));
        return;
    }
    app.drum_cursor[0] = @intCast(clampCursor(@intCast(app.drum_cursor[0]), delta, DrumMachine.max_pads - 1));
}

fn clampCursor(value: u8, delta: i32, top: i64) i64 {
    return std.math.clamp(@as(i64, value) + @as(i64, delta), 0, top);
}

/// Move the param cursor by `delta` rows, clamped to the param list -
/// mirrors the synth editor's equivalent.
fn moveCursor(app: *App, delta: i32) void {
    app.sampler_param = @intCast(clampCursor(app.sampler_param, delta, @as(i64, paramCount(app)) - 1));
}

/// Audition the sampler editor's current target.
fn preview(app: *App) void {
    switch (app.sampler_target) {
        .drum => |t| {
            _ = app.session.engine.send(.{ .note_on = .{
                .track = t,
                .note = @intCast(app.drum_cursor[0]),
                .velocity = 0.9,
            } });
        },
        .slice => |t| {
            _ = app.session.engine.send(.{ .note_on = .{
                .track = t,
                .note = @intCast(app.slicer_cursor[0]),
                .velocity = 0.9,
            } });
        },
        .sampler => |t| {
            const root: u7 = if (app.editingSampler()) |s| s.root_note else 60;
            app.playNote(t, root, app.now_ns);
        },
    }
}
// zig fmt: on

/// Nudge the selected sampler param. Routed over the command queue so the
/// edit lands on the audio thread (DrumMachine/Sampler.adjustParam), never
/// racing the block reader - mirrors the synth editor's adjustParam. Also
/// notes the nudge for undo (history.noteParamNudge), coalescing a run of
/// h/l presses on the same param into one undo step.
pub fn adjustParam(app: *App, steps: i32) void {
    app.dirty = true;
    switch (app.sampler_target) {
        .drum => |t| {
            const id = DrumMachine.paramId(@intCast(app.drum_cursor[0]), app.sampler_param);
            history.noteParamNudge(app, t, id, steps);
            _ = app.session.engine.send(.{ .set_track_param = .{ .track = t, .id = id, .steps = steps } });
        },
        .slice => |t| {
            const id = ws.dsp.Slicer.paramId(app.slicer_cursor[0], app.sampler_param);
            history.noteParamNudge(app, t, id, steps);
            _ = app.session.engine.send(.{ .set_track_param = .{ .track = t, .id = id, .steps = steps } });
        },
        .sampler => |t| {
            history.noteParamNudge(app, t, app.sampler_param, steps);
            _ = app.session.engine.send(.{ .set_track_param = .{ .track = t, .id = app.sampler_param, .steps = steps } });
        },
    }
}

// Row layout mirrors views/sampler.zig's drawSamplerEditor exactly: title,
// then (if there's room) a variable-height waveform panel, then fixed
// section-header/param rows in a constant order. `waveRows` and
// `paramRelRow` replicate that sizing/ordering rather than re-deriving it.

/// Rows the waveform panel actually occupies (0 if there isn't room for
/// one - drawSamplerEditor skips it below 2 rows). `body` is the view's
/// content-row budget (`rows -| 5`, matching drawSamplerEditor).
/// `pad_target` = drum pad or slice: 10 params, no KEY section.
fn waveRows(pad_target: bool, body: usize) usize {
    const param_lines: usize = if (pad_target) 13 else 17;
    const wr = @min(wave_max_rows, body -| (1 + param_lines));
    return if (wr >= 2) wr else 0;
}

// zig fmt: off
/// Row of param `idx` relative to right after the waveform panel (title +
/// waveform rows already excluded) - one row per section header, matching
/// drawSamplerEditor's emission order (SAMPLE's 3 params, AMP ENV's 4, OUT's
/// 3, then KEY's 1 for a standalone sampler).
fn paramRelRow(idx: u8) usize {
    return switch (idx) {
        0 => 1, 1 => 2, 2 => 3, // SAMPLE (header at 0): start, end, pitch
        3 => 5, 4 => 6, 5 => 7, 6 => 8, // AMP ENV (header at 4): attack..release
        7 => 10, 8 => 11, 9 => 12, // OUT (header at 9): gain, pan, reverse
        10 => 14, 11 => 15, // KEY (header at 13): root, voice - standalone sampler only
        else => 0,
    };
}
// zig fmt: on

/// The param row (in view-content-relative rows) at `row`, or null for the
/// title/waveform rows or a section-header line.
fn paramAtRow(app: *App, row: usize, view_rows: usize) ?u8 {
    const pad_target = app.sampler_target != .sampler;
    const w_rows = waveRows(pad_target, view_rows -| 5);
    if (row < 1 + w_rows) return null;
    const rel = row - (1 + w_rows);
    const count: u8 = if (pad_target) 10 else 12;
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        if (paramRelRow(i) == rel) return i;
    }
    return null;
}

/// Normalized 0..1 position at column `x` within the waveform panel (which
/// starts after drawWaveformPad's 2-column indent), or null outside it.
/// Mirrors drawWaveformPad's own `gutter`/`width`.
fn waveformNorm(x: usize, cols: u16) ?f32 {
    const gutter = 2;
    if (x < gutter) return null;
    const width = @min(@as(usize, cols) -| gutter, wave_max_w);
    if (width == 0) return null;
    const rel = x - gutter;
    if (rel >= width) return null;
    return std.math.clamp(@as(f32, @floatFromInt(rel)) / @as(f32, @floatFromInt(width)), 0.0, 1.0);
}

/// The current target's start/end markers, read straight off its Pad -
/// same values views/sampler.zig's drawWaveformPad renders.
fn currentNorms(app: *App) ?struct { start: f32, end: f32 } {
    switch (app.sampler_target) {
        .drum => {
            const s = app.drumMachine().pads[app.drum_cursor[0]] orelse return null;
            return .{ .start = s.pad.start_norm, .end = s.pad.end_norm };
        },
        .slice => {
            const sl = app.slicerInst();
            if (app.slicer_cursor[0] >= sl.slice_count) return null;
            const p = &sl.slices[app.slicer_cursor[0]];
            return .{ .start = p.start_norm, .end = p.end_norm };
        },
        .sampler => {
            const s = app.editingSampler() orelse return null;
            return .{ .start = s.pad.start_norm, .end = s.pad.end_norm };
        },
    }
}

/// Move `marker` to `target_norm` via the same discrete steps the keyboard
/// uses - start/end move in exactly 0.01 increments (dsp/sampler.zig's
/// Sampler.adjustParam) - so a click/drag never bypasses that clamping.
fn moveMarkerTo(app: *App, marker: SamplerMarker, target_norm: f32) void {
    const norms = currentNorms(app) orelse return;
    const current: f32 = if (marker == .start) norms.start else norms.end;
    const steps: i32 = @intFromFloat(@round((target_norm - current) / 0.01));
    if (steps == 0) return;
    app.sampler_param = if (marker == .start) 0 else 1;
    adjustParam(app, steps);
}

/// Press inside the waveform: grab whichever marker (start/end) is nearer to
/// the clicked position and move it there immediately.
fn startWaveformDrag(app: *App, x: usize, cols: u16) void {
    const norm = waveformNorm(x, cols) orelse return;
    const norms = currentNorms(app) orelse return;
    const marker: SamplerMarker = if (@abs(norm - norms.start) <= @abs(norm - norms.end)) .start else .end;
    app.sampler_drag_marker = marker;
    moveMarkerTo(app, marker, norm);
}

/// Click a param row to select it (like j/k landing there); click inside the
/// waveform panel to grab and move the nearer start/end marker, continuing
/// to follow the mouse while the button stays held. Scroll over a param row
/// nudges it via `adjustParam` (**ctrl**+scroll = coarse, matching H/L).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16, view_rows: usize) void {
    const pad_target = app.sampler_target != .sampler;
    const w_rows = waveRows(pad_target, view_rows -| 5);
    const in_waveform = w_rows > 0 and row >= 1 and row < 1 + w_rows;

    switch (ev.kind) {
        .press => {
            if (in_waveform) {
                startWaveformDrag(app, ev.x, cols);
            } else if (paramAtRow(app, row, view_rows)) |p| {
                history.flushParamNudge(app);
                app.sampler_param = p;
            }
        },
        .drag => {
            const marker = app.sampler_drag_marker orelse return;
            const norm = waveformNorm(ev.x, cols) orelse return;
            moveMarkerTo(app, marker, norm);
        },
        .release => app.sampler_drag_marker = null,
        .scroll_up, .scroll_down => {
            if (paramAtRow(app, row, view_rows)) |p| app.sampler_param = p else return;
            const dir: i32 = if (ev.kind == .scroll_up) 1 else -1;
            adjustParam(app, dir * (if (ev.ctrl) @as(i32, 10) else 1));
        },
    }
}

test "sampler cursor motions saturate for maximum counts" {
    try std.testing.expectEqual(@as(i64, 63), clampCursor(4, std.math.maxInt(i32), 63));
    try std.testing.expectEqual(@as(i64, 0), clampCursor(4, std.math.minInt(i32), 63));
}

//! Sampler-editor input for both targets - a drum machine pad or a standalone
//! Sampler: param row navigation, h/l nudges (routed to the audio thread),
//! pad jumps and audition. The render half lives in views/sampler.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const DrumMachine = ws.dsp.DrumMachine;
const Sampler = ws.dsp.Sampler;
const icons = @import("../icons.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const SamplerTarget = app_mod.SamplerTarget;
const SamplerMarker = app_mod.SamplerMarker;
const history = @import("../history.zig");
const commands_load = @import("../commands/load.zig");
const commands = @import("../commands.zig");
const format = @import("../format.zig");
const spectrum = @import("fx_editor.zig");

/// Waveform panel caps, shared with the TUI render half (views/sampler.zig):
/// width in columns and height in rows (min'd against the leftover row
/// budget). The mouse hit-testing below mirrors the draw path exactly.
pub const wave_max_w: usize = 240;
pub const wave_max_rows: usize = 14;

pub const ParamRow = struct {
    id: u8,
    label: []const u8,
    gui_format: [:0]const u8,
};

pub const SectionKind = enum { sample, envelope, output, fade, mod, key };
pub const Section = struct { kind: SectionKind, title: [:0]const u8, rows: []const ParamRow };

// zig fmt: off
pub const pad_sections = [_]Section{
    .{ .kind = .sample, .title = "SAMPLE", .rows = &.{
        .{ .id = 0,  .label = "Start",   .gui_format = "%.3f" },
        .{ .id = 1,  .label = "End",     .gui_format = "%.3f" },
        .{ .id = 2,  .label = "Pitch",   .gui_format = "%.0f st" },
        .{ .id = 12, .label = "Stretch", .gui_format = "%.2fx" },
        .{ .id = 20, .label = "Warp",    .gui_format = "%.0f" },
        .{ .id = 14, .label = "Gate",    .gui_format = "%.0f" },
        .{ .id = 19, .label = "Loop",    .gui_format = "%.0f" },
    } },
    .{ .kind = .envelope, .title = "AMP ENV", .rows = &.{
        .{ .id = 3, .label = "Attack",  .gui_format = "%.3f s" },
        .{ .id = 4, .label = "Decay",   .gui_format = "%.3f s" },
        .{ .id = 5, .label = "Sustain", .gui_format = "%.2f" },
        .{ .id = 6, .label = "Release", .gui_format = "%.3f s" },
    } },
    .{ .kind = .output, .title = "OUT", .rows = &.{
        .{ .id = 7, .label = "Gain",    .gui_format = "%.2f" },
        .{ .id = 8, .label = "Pan",     .gui_format = format.pan_cfmt },
        .{ .id = 9, .label = "Reverse", .gui_format = "%.0f" },
        .{ .id = 13, .label = "Filter",  .gui_format = format.filter_cfmt },
    } },
    .{ .kind = .fade, .title = "FADE", .rows = &.{
        .{ .id = 10, .label = "Fade in",  .gui_format = "%.3f s" },
        .{ .id = 11, .label = "Fade out", .gui_format = "%.3f s" },
    } },
    .{ .kind = .mod, .title = "MOD", .rows = &.{
        .{ .id = 15, .label = "Rate",  .gui_format = "%.2f Hz" },
        .{ .id = 16, .label = "Depth", .gui_format = "%.2f" },
        .{ .id = 17, .label = "Shape", .gui_format = "%.0f" },
        .{ .id = 18, .label = "Dest",  .gui_format = "%.0f" },
    } },
};
pub const key_section: Section = .{ .kind = .key, .title = "KEY", .rows = &.{
    .{ .id = Sampler.root_note_id, .label = "Root note", .gui_format = format.note_cfmt },
    .{ .id = Sampler.mono_id,      .label = "Voice",     .gui_format = "%.0f" },
} };
// zig fmt: on

/// Upper bound on paramOrder's output - derived, so adding a row to the
/// tables above can never outgrow the caller's stack buffer again.
pub const max_param_rows = blk: {
    var n: usize = key_section.rows.len;
    for (pad_sections) |section| n += section.rows.len;
    break :blk n;
};

/// The glyph a section heads up with, keyed off the same `kind` both
/// frontends already switch on for its color - one mapping, so the GUI's
/// heading and the TUI's divider never disagree about what a section is.
pub fn sectionIcon(kind: SectionKind) []const u8 {
    return switch (kind) {
        .sample => icons.sampler,
        .envelope => icons.envelope,
        .output => icons.audio,
        .fade => icons.fade,
        .mod => icons.modulation,
        .key => icons.keys,
    };
}

pub fn paramLineCount(pad_target: bool) usize {
    var count: usize = 0;
    for (pad_sections) |section| count += 1 + section.rows.len;
    // Keep one breathing row after the standalone-only KEY section.
    if (!pad_target) count += 2 + key_section.rows.len;
    return count;
}

/// Number of editable params for the sampler editor's current target.
/// A slice carries the same shared pad params a drum pad does (start..gate),
/// minus nothing - root/mono stay sampler-only.
fn paramCount(app: *App) u8 {
    return switch (app.sampler_target) {
        .drum => DrumMachine.pad_param_count,
        .sampler => Sampler.param_count,
        .slice => DrumMachine.pad_param_count,
    };
}

pub fn engineParamId(target: SamplerTarget, index: u8, id: u8) u16 {
    return switch (target) {
        .drum => DrumMachine.paramId(index, id),
        .slice => ws.dsp.Slicer.paramId(index, id),
        .sampler => id,
    };
}

test "sampler targets map local params onto engine ids" {
    try std.testing.expectEqual(DrumMachine.paramId(3, 5), engineParamId(.{ .drum = 0 }, 3, 5));
    try std.testing.expectEqual(ws.dsp.Slicer.paramId(3, 5), engineParamId(.{ .slice = 0 }, 3, 5));
    try std.testing.expectEqual(@as(u16, 5), engineParamId(.{ .sampler = 0 }, 3, 5));
}

// zig fmt: off
/// Sampler editor: j/k pick a param row, h/l nudge it, H/L curve envelope
/// and fade durations (coarse-nudge other params). For a drum pad
/// or a slice, [/] move between adjacent slots and 1–8 jump to that slot
/// within the current bank (shared `drum_cursor[0]`/`slicer_cursor[0]`).
/// esc/e return to whichever view opened this one (`app.sampler_return`):
/// the tracks view, or the grid that sequences the pad/slice. a auditions
/// the current pad/slice / the sampler's root note (mirrors the piano
/// roll/drum grid's own audition key).
pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const is_drum = app.sampler_target == .drum;
    const is_slice = app.sampler_target == .slice;
    // Multi-key prefixes (docs/editing-grammar.md): `g` armed below drains
    // on the next key (gg = first param, gG = last). An unknown pair falls
    // through, so a prefix never eats a key it doesn't own.
    if (app.takePrefix(key)) |p| switch (p) {
        'g' => switch (key.char) {
            'g' => { history.flushParamNudge(app); app.sampler_param = edgeParam(app, false); return true; },
            'G' => { history.flushParamNudge(app); app.sampler_param = edgeParam(app, true); return true; },
            else => {},
        },
        else => {},
    };
    switch (key) {
        .escape => {
            history.flushParamNudge(app);
            app.view = returnView(app);
            return true;
        },
        .ctrl_r => { history.doRedo(app); return true; },
        // Empty targets open their browser. Loaded-but-unchopped slicers go
        // to the grid where chop controls live.
        .enter => {
            if (is_slice) {
                if (app.slicerInst().slice_count > 0) return false;
                if (app.slicerInst().hasAudio()) {
                    app.openStepEditor(app.sampler_target.track());
                    return true;
                }
            } else if (targetHasAudio(app)) {
                return false;
            }
            commands_load.cmdLoad(app, "");
            return true;
        },
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
            'B' => {
                if (is_drum) return false;
                history.flushParamNudge(app);
                commands.run(app, "bpm-sync");
                return true;
            },
            // s/p reach this track's FX chain and note editor without a
            // detour through the tracks view - the same two keys the synth
            // editor binds, so every instrument editor sideways-navigates
            // alike. p is the piano roll on a standalone Sampler and the
            // step grid on a pad/slice (App.openStepEditor).
            's' => {
                history.flushParamNudge(app);
                spectrum.switchToTrack(app, app.sampler_target.track());
                return true;
            },
            'p' => {
                history.flushParamNudge(app);
                app.openStepEditor(app.sampler_target.track());
                return true;
            },
            // j/k rows and h/l nudges take a vim count prefix (3j, 5l, …),
            // matching the synth editor's equivalent.
            'j' => { moveCursor(app, app.takeCount()); return true; },
            'k' => { moveCursor(app, -app.takeCount()); return true; },
            'h' => { adjustParam(app, -app.takeCount()); return true; },
            'l' => { adjustParam(app, app.takeCount()); return true; },
            'H' => { adjustModifiedParam(app, -app.takeCount()); return true; },
            'L' => { adjustModifiedParam(app, app.takeCount()); return true; },
            // g/G are a two-key pair (gg = first param, gG = last): 'g'
            // arms the prefix, the follow-up key drains it above.
            'g' => { _ = app.armPrefix('g'); return true; },
            // J/K jump a whole bank of 8 pads/slices - same MPC-style
            // paging as the drum grid's own J/K (editors/drum.zig).
            'K' => {
                if (!is_drum and !is_slice) return false;
                history.flushParamNudge(app);
                movePad(app, -8 * app.takeCount());
                return true;
            },
            'J' => {
                if (!is_drum and !is_slice) return false;
                history.flushParamNudge(app);
                movePad(app, 8 * app.takeCount());
                return true;
            },
            '[' => {
                if (!is_drum and !is_slice) return false;
                history.flushParamNudge(app);
                movePad(app, -app.takeCount());
                return true;
            },
            ']' => {
                if (!is_drum and !is_slice) return false;
                history.flushParamNudge(app);
                movePad(app, app.takeCount());
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
                    const slice: u8 = @intCast(bank * 8 + (c - '1'));
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
    return app.sampler_return;
}

fn targetHasAudio(app: *App) bool {
    switch (app.sampler_target) {
        .drum => {
            const idx: u8 = @intCast(app.drum_cursor[0]);
            if (idx >= DrumMachine.max_pads) return false;
            // Pads are lazily allocated: an unmaterialized slot has no audio.
            if (app.drumMachine().pads[idx]) |*s| return s.pad.samples.len > 0;
            return false;
        },
        .slice => return app.slicerInst().hasAudio(),
        .sampler => {
            const s = app.editingSampler() orelse return true;
            return s.pad.samples.len > 0;
        },
    }
}

fn targetIsEditable(app: *App) bool {
    return switch (app.sampler_target) {
        .drum => app.drum_cursor[0] < DrumMachine.max_pads and app.drumMachine().pads[app.drum_cursor[0]] != null,
        .slice => app.slicer_cursor[0] < app.slicerInst().slice_count or (app.slicerInst().slice_count == 0 and app.slicerInst().hasAudio()),
        .sampler => app.editingSampler() != null,
    };
}

/// Move the pad/slice cursor by `delta`, clamped to the target's slot count.
fn movePad(app: *App, delta: i32) void {
    if (app.sampler_target == .slice) {
        const top = @as(i64, app.slicerInst().slice_count) - 1;
        // zig fmt: off
        if (top < 0) { app.slicer_cursor[0] = 0; return; }
        // zig fmt: on
        app.slicer_cursor[0] = @intCast(modal_mod.clampDelta(app.slicer_cursor[0], delta, top));
        return;
    }
    app.drum_cursor[0] = @intCast(modal_mod.clampDelta(app.drum_cursor[0], delta, DrumMachine.max_pads - 1));
}

/// Param ids in the order the editor draws them. `sampler_param` holds a
/// param *id*, and the ids past 11 were appended to dsp/pad.zig's space
/// after the rows they draw between (stretch sits in SAMPLE, root/voice in
/// KEY), so row moves have to walk this list - counting ids straight up
/// skips the stretch row and lands on the next section instead.
fn paramOrder(pad_target: bool, count: u8, out: *[max_param_rows]u8) []const u8 {
    var n: usize = 0;
    for (pad_sections) |section| {
        for (section.rows) |row| {
            if (row.id < count) {
                out[n] = row.id;
                n += 1;
            }
        }
    }
    if (!pad_target) {
        for (key_section.rows) |row| {
            if (row.id < count) {
                out[n] = row.id;
                n += 1;
            }
        }
    }
    return out[0..n];
}

/// Move the param cursor by `delta` rows, clamped to the param list -
/// mirrors the synth editor's equivalent.
fn moveCursor(app: *App, delta: i32) void {
    if (!targetIsEditable(app)) return;
    var buf: [max_param_rows]u8 = undefined;
    const order = paramOrder(app.sampler_target != .sampler, paramCount(app), &buf);
    var idx: u8 = 0;
    for (order, 0..) |id, i| {
        if (id == app.sampler_param) idx = @intCast(i);
    }
    app.sampler_param = order[@intCast(modal_mod.clampDelta(idx, delta, @as(i64, @intCast(order.len)) - 1))];
}

/// First/last param row the editor draws, for g/G.
fn edgeParam(app: *App, last: bool) u8 {
    if (!targetIsEditable(app)) return app.sampler_param;
    var buf: [max_param_rows]u8 = undefined;
    const order = paramOrder(app.sampler_target != .sampler, paramCount(app), &buf);
    return if (last) order[order.len - 1] else order[0];
}

test "param row order follows the drawn rows, not the raw id space" {
    var buf: [max_param_rows]u8 = undefined;
    // A drum pad / slice: stretch (id 12) draws inside SAMPLE, so j from
    // pitch has to land on it rather than skipping to the AMP ENV section.
    const pad = paramOrder(true, DrumMachine.pad_param_count, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 12, 20, 14, 19, 3, 4, 5, 6, 7, 8, 9, 13, 10, 11, 15, 16, 17, 18 }, pad);

    var buf2: [max_param_rows]u8 = undefined;
    // A standalone Sampler adds the KEY section at the bottom.
    const sampler = paramOrder(false, Sampler.param_count, &buf2);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 12, 20, 14, 19, 3, 4, 5, 6, 7, 8, 9, 13, 10, 11, 15, 16, 17, 18, Sampler.root_note_id, Sampler.mono_id }, sampler);
}

pub fn curveParam(id: u8) ?u8 {
    return switch (id) {
        3, 4, 6 => ws.dsp.pad.env_curve_id,
        10, 11 => ws.dsp.pad.fade_curve_id,
        else => null,
    };
}

test "modified sampler params select envelope and fade curves" {
    try std.testing.expectEqual(ws.dsp.pad.env_curve_id, curveParam(3).?);
    try std.testing.expectEqual(ws.dsp.pad.env_curve_id, curveParam(6).?);
    try std.testing.expectEqual(ws.dsp.pad.fade_curve_id, curveParam(10).?);
    try std.testing.expect(curveParam(5) == null);
}

fn adjustModifiedParam(app: *App, steps: i32) void {
    const original = app.sampler_param;
    app.sampler_param = curveParam(original) orelse {
        adjustParam(app, steps * 10);
        return;
    };
    adjustParam(app, steps);
    app.sampler_param = original;
}

/// Audition the sampler editor's current target.
fn preview(app: *App) void {
    if (!targetIsEditable(app)) return;
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
    if (!targetIsEditable(app)) return;
    app.dirty = true;
    switch (app.sampler_target) {
        .drum => |t| {
            const id = engineParamId(app.sampler_target, @intCast(app.drum_cursor[0]), app.sampler_param);
            history.noteParamNudge(app, t, id, steps);
            _ = app.session.engine.send(.{ .set_track_param = .{ .track = t, .id = id, .steps = steps } });
        },
        .slice => |t| {
            const id = engineParamId(app.sampler_target, @intCast(app.slicer_cursor[0]), app.sampler_param);
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

/// Rows before the waveform: title, plus the pad bank or slice map when shown.
fn prefixRows(app: *App) usize {
    return switch (app.sampler_target) {
        .drum => 4,
        .slice => if (targetHasAudio(app)) 4 else 1,
        .sampler => 1,
    };
}

/// Rows the waveform panel actually occupies (0 if there isn't room for
/// one). `body` is the view's content-row budget (`rows -| 5`).
fn waveRows(app: *App, body: usize) usize {
    const wr = @min(wave_max_rows, body -| (prefixRows(app) + paramLineCount(app.sampler_target != .sampler)));
    return if (wr >= 2) wr else 0;
}

/// Row of param `idx` relative to right after the waveform panel (title +
/// waveform rows already excluded) - one row per section header, matching
/// drawSamplerEditor's emission order (SAMPLE's 4 params, AMP ENV's 4, OUT's
/// 3, FADE's 2, then KEY's 2 for a standalone sampler).
fn paramRelRow(idx: u8) usize {
    var rel: usize = 0;
    for (pad_sections) |section| {
        rel += 1;
        for (section.rows) |row| {
            if (row.id == idx) return rel;
            rel += 1;
        }
    }
    rel += 1;
    for (key_section.rows) |row| {
        if (row.id == idx) return rel;
        rel += 1;
    }
    return 0;
}

/// The param row (in view-content-relative rows) at `row`, or null for the
/// title/waveform rows or a section-header line.
fn paramAtRow(app: *App, row: usize, view_rows: usize) ?u8 {
    const prefix = prefixRows(app);
    const w_rows = waveRows(app, view_rows -| 5);
    if (row < prefix + w_rows) return null;
    const rel = row - (prefix + w_rows);
    const count: u8 = paramCount(app);
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
            if (app.slicer_cursor[0] >= sl.slice_count and !(sl.slice_count == 0 and sl.hasAudio())) return null;
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
fn startWaveformDrag(app: *App, x: usize, cols: u16, ev: modal_mod.MouseEvent) void {
    const norm = waveformNorm(x, cols) orelse return;
    const norms = currentNorms(app) orelse return;
    if (ev.shift) {
        app.sampler_drag_window = true;
        app.sampler_drag_norm = norm;
        return;
    }
    const marker: SamplerMarker = if (ev.button == .middle)
        .start
    else if (ev.button == .right)
        .end
    else if (@abs(norm - norms.start) <= @abs(norm - norms.end))
        .start
    else
        .end;
    app.sampler_drag_marker = marker;
    moveMarkerTo(app, marker, norm);
}

fn moveWindow(app: *App, delta: f32) void {
    const norms = currentNorms(app) orelse return;
    const d = std.math.clamp(delta, -norms.start, 1.0 - norms.end);
    moveMarkerTo(app, .start, norms.start + d);
    moveMarkerTo(app, .end, norms.end + d);
}

/// Click a param row to select it (like j/k landing there); click inside the
/// waveform panel to grab and move the nearer marker; middle picks start,
/// right picks end, and **Shift**+drag moves both. Wheel zooms the window;
/// **Ctrl**+wheel scrolls it. Scroll over a param row
/// nudges it via `adjustParam` (**ctrl**+scroll curves envelope/fade time
/// params and coarse-nudges everything else, matching H/L).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16, view_rows: usize) void {
    if (!targetIsEditable(app)) {
        // Both halves of the gesture, not just the marker: leaving the
        // window drag armed would resume it on the next press.
        app.sampler_drag_marker = null;
        app.sampler_drag_window = false;
        return;
    }
    const prefix = prefixRows(app);
    const w_rows = waveRows(app, view_rows -| 5);
    const in_waveform = w_rows > 0 and row >= prefix and row < prefix + w_rows;

    switch (ev.kind) {
        .press => {
            if (in_waveform) {
                startWaveformDrag(app, ev.x, cols, ev);
            } else if (paramAtRow(app, row, view_rows)) |p| {
                history.flushParamNudge(app);
                app.sampler_param = p;
                if (ev.button == .middle) resetMouseParam(app);
            }
        },
        .drag => {
            if (app.sampler_drag_window) {
                const norm = waveformNorm(ev.x, cols) orelse return;
                moveWindow(app, norm - app.sampler_drag_norm);
                app.sampler_drag_norm = norm;
                return;
            }
            const marker = app.sampler_drag_marker orelse return;
            const norm = waveformNorm(ev.x, cols) orelse return;
            moveMarkerTo(app, marker, norm);
        },
        .release => {
            app.sampler_drag_marker = null;
            app.sampler_drag_window = false;
        },
        .scroll_up, .scroll_down => {
            if (in_waveform) {
                const dir: f32 = if (ev.kind == .scroll_up) 0.01 else -0.01;
                if (ev.ctrl) {
                    moveWindow(app, dir);
                } else {
                    const norms = currentNorms(app) orelse return;
                    moveMarkerTo(app, .start, norms.start + dir);
                    moveMarkerTo(app, .end, norms.end - dir);
                }
                return;
            }
            if (paramAtRow(app, row, view_rows)) |p| app.sampler_param = p else return;
            const dir: i32 = if (ev.kind == .scroll_up) 1 else -1;
            if (ev.ctrl) adjustModifiedParam(app, dir) else adjustParam(app, dir);
        },
    }
}

/// Resets `app.sampler_param` (on whichever target `app.sampler_target`
/// names) to its patch-init default. Shared by the TUI's middle-click and
/// the GUI knob's "Reset to default" menu item - see `widgets.Knob`'s doc
/// comment.
pub fn resetMouseParam(app: *App) void {
    var fresh = ws.dsp.Sampler.init(app.allocator, app.session.project.sample_rate) catch return;
    defer fresh.deinit();
    const value = fresh.paramValue(app.sampler_param) orelse return;
    const track = app.sampler_target.track();
    const id = switch (app.sampler_target) {
        .drum => engineParamId(app.sampler_target, @intCast(app.drum_cursor[0]), app.sampler_param),
        .slice => engineParamId(app.sampler_target, @intCast(app.slicer_cursor[0]), app.sampler_param),
        .sampler => app.sampler_param,
    };
    history.recordParamSet(app, track, id);
    _ = app.session.engine.send(.{ .set_track_param_abs = .{ .track = track, .id = id, .value = value } });
}

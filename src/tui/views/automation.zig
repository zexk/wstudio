//! Per-clip gain/pan automation view + its status bar. The input half lives
//! in editors/automation.zig.

const std = @import("std");
const ws = @import("wstudio");
const engine_mod = ws.engine;
const automation_mod = ws.dsp.automation;
const AutomationPoint = automation_mod.AutomationPoint;
const synth_mod = ws.dsp.synth;
const automation_ed = @import("../../ui/editors/automation.zig");
const AutomationFocus = automation_ed.AutomationFocus;
const style = @import("../style.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const sel = style.sel;
const blu = style.blu;
const yel = style.yel;
const endLine = style.endLine;

// Lower-eighths block glyphs, shortest to tallest - same idea as
// views/spectrum.zig's `eq_glyphs`, generalised to an arbitrary [lo, hi].
const level_glyphs = [_][]const u8{
    "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
    "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}",
};

/// Sub-cell levels a value fills, out of `graph_rows * 8` eighth-blocks -
/// the bar graph's whole vertical resolution. A null value (no automation
/// on the curve yet) sits on the baseline.
fn valueLevel(val: ?f32, range: [2]f32, graph_rows: usize) usize {
    const v = val orelse return 1;
    const norm = std.math.clamp((v - range[0]) / (range[1] - range[0]), 0.0, 1.0);
    const total: f32 = @floatFromInt(graph_rows * 8);
    const lvl: usize = @intFromFloat(@round(norm * total));
    return @max(lvl, 1); // floor values keep a visible ▁ baseline
}

// Left indent lives with the editor (ui/editors/automation.zig) so its mouse
// handler and this draw path agree on the step columns.
const gutter = automation_ed.gutter;

/// Resolve the clip the view (and editors/automation.zig) are both bound to.
/// Duplicated here rather than imported (see tui.zig's doc comment: view
/// renderers take `app: anytype` and never import app.zig, so they can't
/// share a helper typed against the concrete `*App`).
fn currentClip(app: anytype) ?*const ws.Clip {
    const link = app.automation_clip orelse return null;
    const lane = app.session.arrangement.lane(link.track) orelse return null;
    return lane.clipAt(link.start_bar);
}

/// Duplicated from editors/automation.zig's own `instrumentAutomatableParams`
/// rather than imported - view renderers take `app: anytype` and never
/// import app.zig (see `currentClip`'s doc comment above), so they can't
/// share a helper typed against the concrete `*App` either.
fn instrumentAutomatableParams(app: anytype) []const ws.dsp.device.AutomatableParam {
    if (app.automation_track >= app.session.racks.items.len) return &.{};
    return switch (app.session.racks.items[app.automation_track].instrument) {
        .poly_synth => &synth_mod.PolySynth.automatable_params,
        .sampler => &ws.dsp.Sampler.automatable_params,
        .drum_machine, .slicer, .empty => &.{},
    };
}

fn findAutomatableParam(app: anytype, id: u8) ?*const ws.dsp.device.AutomatableParam {
    for (instrumentAutomatableParams(app)) |*p| if (p.id == id) return p;
    return null;
}

fn curveRange(app: anytype, target: AutomationFocus) [2]f32 {
    return switch (target) {
        .gain => .{ -40.0, 12.0 }, // wider than the persisted -60 floor - a
        // fade all the way to -60dB would otherwise pin the whole graph flat
        .pan => .{ -1.0, 1.0 },
        .synth_param => |id| if (findAutomatableParam(app, id)) |info| info.range else .{ 0.0, 1.0 },
    };
}

fn curvePoints(clip: *const ws.Clip, target: AutomationFocus) []const AutomationPoint {
    return switch (target) {
        .gain => clip.automation.gain,
        .pan => clip.automation.pan,
        .synth_param => |id| clip.automation.findSynthParam(id) orelse &.{},
    };
}

pub fn drawAutomation(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
) !void {
    _ = snap;
    const clip = currentClip(app) orelse {
        try w.writeAll(bold ++ " AUTOMATION" ++ rst ++ dim ++ "  clip gone - esc" ++ rst);
        try endLine(w);
        for (1..@max(1, rows -| 4)) |_| try endLine(w);
        return;
    };

    const track_name = if (app.automation_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.automation_track].name
    else
        "?";
    const target = app.automation_focus;
    const target_label: []const u8 = switch (target) {
        .gain => "GAIN",
        .pan => "PAN",
        .synth_param => |id| if (findAutomatableParam(app, id)) |info| info.label else "?",
    };

    try w.writeAll(bold ++ " AUTOMATION" ++ rst);
    try w.print("  \"{s}\"", .{track_name});
    const ticks_per_bar = ws.time_grid.barTicks(app.session.project.beats_per_bar);
    const start_bar = clip.start_tick / ticks_per_bar + 1;
    const end_bar = (clip.endTick() -| 1) / ticks_per_bar + 1;
    try w.writeAll(dim ++ "  bars " ++ rst);
    if (start_bar == end_bar) {
        try w.print("{d}", .{start_bar});
    } else {
        try w.print("{d}\u{2192}{d}", .{ start_bar, end_bar });
    }
    try w.writeAll(dim ++ "  " ++ rst ++ acc ++ bold);
    try w.print(" {s} ", .{target_label});
    try w.writeAll(rst ++ dim ++ " (tab: switch curve, p: pick param)" ++ rst);
    try endLine(w);

    const bpb = app.session.project.beats_per_bar;
    const steps_per_bar: u32 = @as(u32, bpb) * 4;
    const total_steps = @max(1, (clip.length_ticks + 7) / 8);
    const visible: u32 = @intCast(@max(1, cols -| gutter));

    if (app.automation_cursor_step < app.automation_scroll) app.automation_scroll = app.automation_cursor_step;
    if (app.automation_cursor_step >= app.automation_scroll + visible)
        app.automation_scroll = app.automation_cursor_step - visible + 1;
    const scroll = app.automation_scroll;

    const points = curvePoints(clip, target);
    const range = curveRange(app, target);

    // Visual-mode selection: a step range on the current curve only.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.automation_visual_anchor orelse app.automation_cursor_step;
    const sel_lo: u32 = @min(sel_anchor, app.automation_cursor_step);
    const sel_hi: u32 = @max(sel_anchor, app.automation_cursor_step);

    // Ruler: bar boundaries.
    try w.writeAll(dim ++ "   " ++ rst);
    var col: u32 = 0;
    while (col < visible and scroll + col <= total_steps) : (col += 1) {
        const step = scroll + col;
        try w.writeAll(if (step % steps_per_bar == 0) blu ++ "|" ++ rst else " ");
    }
    try endLine(w);

    // Bar graph: each step is a column rising to its value, drawn over
    // several rows of eighth-blocks for real vertical resolution (one row
    // gave gain's 52dB span only 8 levels). Explicit points are bold+accent,
    // interpolated-only steps are dim, the cursor is reverse-video, a
    // visual-mode selection tints its range yellow (matching the piano
    // roll's `in_sel` convention).
    const graph_rows: usize = @max(1, @min(18, rows -| 7));
    for (0..graph_rows) |line| {
        const row_base = (graph_rows - 1 - line) * 8; // eighth-blocks below this row
        try w.writeAll("   ");
        col = 0;
        while (col < visible and scroll + col <= total_steps) : (col += 1) {
            const step = scroll + col;
            const beat = @as(f64, @floatFromInt(step)) * 0.25;
            const is_cursor = step == app.automation_cursor_step;
            const is_point = automation_mod.hasPointAt(points, beat);
            const in_sel = visual_active and step >= sel_lo and step <= sel_hi;
            const val = automation_mod.interpolate(points, beat);
            const rem = @min(valueLevel(val, range, graph_rows) -| row_base, 8);
            if (rem == 0) {
                // hairline above the cursor's bar so the column reads at
                // any height; other empty cells stay blank
                if (is_cursor) try w.writeAll(dim ++ "\u{2502}" ++ rst) else try w.writeByte(' ');
                continue;
            }
            if (is_cursor) {
                try w.writeAll(sel);
            } else if (is_point) {
                try w.writeAll(bold);
                try w.writeAll(if (in_sel) yel else acc);
            } else if (in_sel) {
                try w.writeAll(yel);
            } else {
                try w.writeAll(dim);
            }
            try w.writeAll(level_glyphs[rem - 1]);
            if (is_cursor or is_point or in_sel) try w.writeAll(rst);
        }
        try endLine(w);
    }

    // Caret row marking the cursor column.
    try w.writeAll("   ");
    col = 0;
    while (col < visible and scroll + col <= total_steps) : (col += 1) {
        try w.writeAll(if (scroll + col == app.automation_cursor_step) acc ++ "^" ++ rst else " ");
    }
    try endLine(w);

    const used = 3 + graph_rows;
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

/// Synth-param automation picker (`p` in the automation editor): every
/// continuous param in the current track's own `automatable_params` table
/// (PolySynth's or Sampler's - see `instrumentAutomatableParams`), grouped by
/// section header. A leading bullet marks a param that already has a lane on
/// the current clip (so re-opening the picker shows what's already active).
/// Row math (title(1) + blank(1) before the display-row list) is shared with
/// `App.automationParamPickerMouse` via `automation_ed.buildParamDisplayRows`
/// - keep the two in sync if this layout ever changes.
pub fn drawAutomationParamPicker(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    const track_name = if (app.automation_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.automation_track].name
    else
        "?";
    const clip = currentClip(app);
    const params = instrumentAutomatableParams(app);
    const filter = automation_ed.activeParamFilter(app);

    var buf: [automation_ed.max_param_display_rows]automation_ed.ParamDisplayRow = undefined;
    const rows_list = automation_ed.buildParamDisplayRows(params, filter, &buf);
    const match_count = blk: {
        var n: usize = 0;
        for (rows_list) |r| if (r == .param) {
            n += 1;
        };
        break :blk n;
    };

    try w.writeAll(bold ++ " AUTOMATE PARAM" ++ rst);
    try w.writeAll(acc);
    try w.print("  \"{s}\"", .{track_name});
    try w.writeAll(rst ++ dim);
    try w.print("  {d} match{s}", .{ match_count, if (match_count == 1) "" else "es" });
    if (filter.len > 0) {
        try w.writeAll(rst ++ yel);
        try w.print("  /{s}", .{filter});
    }
    try w.writeAll(rst);
    try endLine(w);
    try endLine(w);

    // Scroll clamp keyed on the cursor's display row (headers count too) -
    // same "clamped at draw" convention drawTracks' vis_rows uses.
    var cursor_row: usize = 0;
    for (rows_list, 0..) |r, ri| {
        switch (r) {
            // zig fmt: off
            .param => |i| if (i == app.automation_param_cursor) { cursor_row = ri; break; },
            // zig fmt: on
            .header => {},
        }
    }
    // 2 rows of preamble (title + blank) already printed above, plus the
    // same 3-row bottom margin every other view's pad loop reserves - same
    // "vis_rows = rows - preamble - 3" shape drawTracks' vis_rows uses.
    const vis_rows: usize = rows -| 6;
    if (cursor_row < app.automation_param_scroll) app.automation_param_scroll = cursor_row;
    if (vis_rows > 0 and cursor_row >= app.automation_param_scroll + vis_rows)
        app.automation_param_scroll = cursor_row - vis_rows + 1;
    const scroll = app.automation_param_scroll;
    const last_visible = @min(rows_list.len, scroll + vis_rows);

    for (rows_list[scroll..last_visible]) |r| {
        switch (r) {
            .header => |name| {
                try w.writeAll(dim ++ bold);
                try w.print(" {s}", .{name});
                try w.writeAll(rst);
                try endLine(w);
            },
            .param => |i| {
                const p = params[i];
                const is_sel = i == app.automation_param_cursor;
                const has_lane = if (clip) |c| c.automation.findSynthParam(p.id) != null else false;
                if (is_sel) try w.writeAll(sel);
                try w.writeAll(if (is_sel) "  > " else "    ");
                try w.writeAll(if (has_lane) "\u{2022} " else "  ");
                try w.print("{s: <12}", .{p.label});
                if (!is_sel) try w.writeAll(dim);
                try w.print(" {d:.2} .. {d:.2}", .{ p.range[0], p.range[1] });
                try w.writeAll(rst);
                try endLine(w);
            },
        }
    }
    if (match_count == 0) {
        try w.writeAll(dim);
        try w.print("    no match for /{s}", .{filter});
        try w.writeAll(rst);
        try endLine(w);
    }

    const used = 2 + (last_visible - scroll) + @intFromBool(match_count == 0);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

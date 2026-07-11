//! Slicer-grid view + its status bar. The input half lives in
//! editors/slicer.zig.

const std = @import("std");
const ws = @import("wstudio");
const Slicer = ws.dsp.Slicer;
const cmd_mod = @import("../cmd.zig");
const engine_mod = ws.engine;
const style = @import("../style.zig");
const icons = @import("../icons.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const sel = style.sel;
const blu = style.blu;
const endLine = style.endLine;

/// Left gutter before the step columns start (matches views/drum.zig's own
/// gutter/cell-width shape).
pub const gutter: usize = 10;
const cell_width: usize = 3;

fn visibleSteps(cols: usize) u32 {
    if (cols <= gutter) return 1;
    const avail = cols - gutter;
    var n: u32 = 0;
    while (n < Slicer.max_steps) {
        const next = n + 1;
        const sep = (next + 3) / 4;
        if (next * cell_width + sep > avail) break;
        n = next;
    }
    return @max(1, n);
}

pub fn drawSlicerGrid(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    const sl = app.slicerInst();
    const playing_step = sl.currentStep();
    const is_playing = app.session.engine.uiSnapshot().playing;
    const cur_slice = app.slicer_cursor[0];
    const cur_step = app.slicer_cursor[1];
    const step_count_u32: u32 = sl.step_count;
    const track_name = app.session.project.tracks.items[app.slicer_track].name;

    const visible = visibleSteps(cols);
    const cur_step_u32: u32 = cur_step;
    if (cur_step_u32 < app.slicer_step_scroll) app.slicer_step_scroll = cur_step_u32;
    if (cur_step_u32 >= app.slicer_step_scroll + visible) app.slicer_step_scroll = cur_step_u32 - visible + 1;
    const scroll = app.slicer_step_scroll;

    // MPC-style slice banking, same shape the drum grid uses for its 64 pads.
    const slices_per_bank = 8;
    const slice_count = sl.slice_count;
    const bank_count = if (slice_count == 0) 1 else (slice_count + slices_per_bank - 1) / slices_per_bank;
    const bank = cur_slice / slices_per_bank;
    const bank_start = bank * slices_per_bank;
    const bank_end = @min(bank_start + slices_per_bank, slice_count);

    try w.writeAll(bold ++ " " ++ icons.slicer ++ " SLICER" ++ rst);
    try w.print(" \"{s}\"", .{track_name});
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("\"{s}\"", .{sl.clipName()});
    try w.writeAll(dim ++ "  slices " ++ rst);
    try w.print("{d}", .{slice_count});
    try w.writeAll(dim ++ "  bank " ++ rst);
    try w.print("{d}/{d}", .{ bank + 1, bank_count });
    try endLine(w);

    if (slice_count == 0) {
        try w.writeAll(dim ++ "  no slices yet — :slice <n> chops the loaded sample (:load-slice first)" ++ rst);
        try endLine(w);
        for (2..@max(2, rows -| 3)) |_| try endLine(w);
        return;
    }

    // step header — only the visible scroll window is shown
    try w.writeAll(dim ++ "          ");
    var col: u32 = 0;
    while (col < visible and scroll + col < step_count_u32) : (col += 1) {
        const s = scroll + col;
        if (s % 4 == 0) try w.writeAll("│");
        try w.print("{d:>2} ", .{s + 1});
    }
    try endLine(w);

    for (bank_start..bank_end) |sIdx| {
        try w.writeAll(dim);
        try w.print(" #{d: <3}    ", .{sIdx + 1});
        try w.writeAll(rst);
        col = 0;
        while (col < visible and scroll + col < step_count_u32) : (col += 1) {
            const s = scroll + col;
            if (s % 4 == 0) try w.writeAll(dim ++ "│" ++ rst);
            const active = sl.stepActive(@intCast(sIdx), @intCast(s));
            const is_cursor = (sIdx == cur_slice and s == cur_step_u32);
            const is_play = is_playing and (s == playing_step);

            if (is_cursor) {
                try w.writeAll(sel);
            } else if (is_play) {
                try w.writeAll(grn ++ bold);
            } else if (active) {
                try w.writeAll(acc);
            } else {
                try w.writeAll(dim);
            }
            try w.writeAll(if (active) "[X]" else "[ ]");
            try w.writeAll(rst);
        }
        try endLine(w);
    }

    const used = 2 + (bank_end - bank_start);
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawSlicerStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer, cmds: []const cmd_mod.Def) !void {
    if (app.modal.mode == .command) {
        try cmd_mod.writePrompt(w, cmds, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor, 60);
        return;
    }
    if (app.modal.mode == .search) {
        try cmd_mod.writeSearchPrompt(w, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor);
        return;
    }
    const sl = app.slicerInst();
    const sIdx = app.slicer_cursor[0];
    const s = app.slicer_cursor[1];
    try style.writeModeBadge(w, app.modal.mode);
    try style.writeViewBadge(right, "SLICER", app.modal.mode);
    try w.writeAll(dim ++ "  slice " ++ rst);
    try w.print("{d}/{d}", .{ sIdx + 1, sl.slice_count });
    try w.writeAll(dim ++ "  step " ++ rst);
    try w.print("{d}/{d}", .{ s + 1, sl.step_count });
    try w.writeAll(dim ++ "  swing " ++ rst);
    try w.print("{d:.0}%", .{sl.swing.load(.monotonic)});
    if (sIdx < sl.slice_count) {
        const pad = &sl.slices[sIdx];
        try w.writeAll(dim ++ "  " ++ rst);
        try w.print("{d:.0}%-{d:.0}%", .{ pad.start_norm * 100.0, pad.end_norm * 100.0 });
        try w.writeAll(dim ++ "  gain " ++ rst);
        try w.print("{d:.2}", .{pad.gain});
        try w.writeAll(dim ++ "  pan " ++ rst);
        try w.print("{d:.2}", .{pad.pan});
        if (pad.reverse) try w.writeAll(dim ++ "  " ++ blu ++ "rev" ++ rst);
    }
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

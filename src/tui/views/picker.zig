//! Instrument-picker and FX-picker views.

const std = @import("std");
const ws = @import("wstudio");
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");
const synth_ed = @import("../../ui/editors/synth.zig");
const spectrum_ed = @import("../../ui/editors/spectrum.zig");
const app_mod = @import("../../ui/app.zig");

// Aliases so the moved render bodies reference the shared palette/primitives
// by their original bare names.
const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const yel = style.yel;
const sel = style.sel;
const endLine = style.endLine;

pub fn drawInstrumentPicker(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    const track_name = if (app.cursor < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.cursor].name
    else
        "?";

    const title: []const u8 = if (app.picker_replace) " REPLACE INSTRUMENT" else " INSERT INSTRUMENT";
    try w.writeAll(bold);
    try w.writeAll(title);
    try w.writeAll(rst);
    try w.writeAll(acc);
    try w.print("  \"{s}\"", .{track_name});
    try w.writeAll(rst);
    try endLine(w);
    if (app.picker_replace) {
        try w.writeAll(dim ++ " > select  " ++ rst ++ "j/k move  enter swap (keeps notes when possible)  esc close");
    } else {
        try w.writeAll(dim ++ " > select  " ++ rst ++ "j/k move  enter choose  esc close");
    }
    try endLine(w);

    try w.writeAll(bold ++ " INTERNAL" ++ rst);
    try endLine(w);
    for (app_mod.instrument_picker_items, 0..) |item, i| {
        const is_sel = (i == app.picker_cursor);
        const icon = switch (item.kind) {
            .poly_synth => icons.synth,
            .sampler => icons.sampler,
            .drum_machine => icons.drum,
            .slicer => icons.slicer,
            .soundfont => icons.soundfont,
            else => "",
        };
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.writeAll(icons.iconOr(icon, ""));
        try w.writeByte(' ');
        try w.print("{s: <14}", .{item.label});
        if (!is_sel) try w.writeAll(dim);
        try w.print(" {s}", .{item.description});
        try w.writeAll(rst);
        try endLine(w);
    }
    try w.writeAll(bold ++ " EXTERNAL" ++ rst ++ dim ++ "  CLAP");
    try endLine(w);
    const external_count = app.external_plugins.count(.instrument);
    for (0..external_count) |external_i| {
        const plugin = app.external_plugins.at(.instrument, external_i).?;
        const i = app_mod.instrument_picker_items.len + external_i;
        const is_sel = (i == app.picker_cursor);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.print("{s: <15}", .{plugin.name});
        if (!is_sel) try w.writeAll(dim);
        try w.print(" CLAP  {s}", .{plugin.vendor});
        try w.writeAll(rst);
        try endLine(w);
    }
    if (external_count == 0) {
        try w.writeAll(dim ++ "    no external instruments found" ++ rst);
        try endLine(w);
    }

    const used = 4 + app_mod.instrument_picker_items.len + @max(external_count, 1);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

pub fn drawFxPicker(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    const target: []const u8 = switch (app.fx_picker_return) {
        .track_spectrum => if (app.eq_track < app.session.project.tracks.items.len)
            app.session.project.tracks.items[app.eq_track].name
        else
            "?",
        .group_spectrum => if (app.eq_group < app.session.groups.len) blk: {
            break :blk if (app.session.groups[app.eq_group]) |g| g.name else "?";
        } else "?",
        else => "MASTER",
    };

    var buf: [spectrum_ed.picker_kinds.len]ws.FxKind = undefined;
    const kinds = spectrum_ed.filteredPickerKinds(app, &buf);
    const external_count = spectrum_ed.externalPickerCount(app);
    const total_count = kinds.len + external_count;
    const filter = spectrum_ed.activeFilter(app);

    try w.writeAll(bold ++ " INSERT EFFECT" ++ rst);
    try w.writeAll(acc);
    try w.print("  \"{s}\"", .{target});
    try w.writeAll(rst ++ dim);
    try w.print("  {d} match{s}", .{ total_count, if (total_count == 1) "" else "es" });
    if (filter.len > 0) {
        try w.writeAll(rst ++ yel);
        try w.print("  /{s}", .{filter});
    }
    try w.writeAll(rst);
    try endLine(w);
    try w.writeAll(dim ++ " > /" ++ rst);
    if (filter.len > 0) try w.writeAll(filter) else try w.writeAll(dim ++ "type to filter" ++ rst);
    try endLine(w);

    try w.writeAll(bold ++ " INTERNAL" ++ rst);
    try endLine(w);
    for (kinds, 0..) |k, i| {
        const is_sel = (i == app.fx_picker_cursor);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.print("{s: <12}", .{spectrum_ed.unitLabel(k)});
        if (!is_sel) try w.writeAll(dim);
        try w.print(" {s}", .{spectrum_ed.pickerDescription(k)});
        try w.writeAll(rst);
        try endLine(w);
    }
    try w.writeAll(bold ++ " EXTERNAL" ++ rst ++ dim ++ "  CLAP");
    try endLine(w);
    for (0..external_count) |external_i| {
        const plugin = spectrum_ed.externalPickerAt(app, external_i).?;
        const i = kinds.len + external_i;
        const is_sel = (i == app.fx_picker_cursor);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.print("{s: <13}", .{plugin.name});
        if (!is_sel) try w.writeAll(dim);
        try w.print("CLAP  {s}", .{plugin.vendor});
        try w.writeAll(rst);
        try endLine(w);
    }
    if (total_count == 0) {
        try w.writeAll(dim);
        try w.print("    no match for /{s}", .{filter});
        try w.writeAll(rst);
        try endLine(w);
    }

    // zig fmt: off
    const used = 5 + @max(total_count, 1);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

// zig fmt: on

/// The synth-internal FX chain's insert picker - same shape as
/// `drawFxPicker`, just over `synth_ed.synthFxPickerKinds` (the currently-
/// off units) instead of the track chain's fixed `fx_picker_menu`, and
/// without the description column (the user already has each unit's full
/// param section on screen once inserted).
pub fn drawSynthFxPicker(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    const name = if (app.synth_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.synth_track].name
    else
        "?";

    var buf: [14]ws.dsp.synth.FxUnitKind = undefined;
    const kinds = synth_ed.filteredSynthFxPickerKinds(app, &buf);
    const filter = synth_ed.activeFxFilter(app);

    try w.writeAll(bold ++ " INSERT FX UNIT" ++ rst);
    try w.writeAll(acc);
    try w.print("  \"{s}\"", .{name});
    try w.writeAll(rst ++ dim);
    try w.print("  {d} match{s}", .{ kinds.len, if (kinds.len == 1) "" else "es" });
    if (filter.len > 0) {
        try w.writeAll(rst ++ yel);
        try w.print("  /{s}", .{filter});
    }
    try w.writeAll(rst);
    try endLine(w);
    try w.writeAll(dim ++ " > /" ++ rst);
    if (filter.len > 0) try w.writeAll(filter) else try w.writeAll(dim ++ "type to filter" ++ rst);
    try endLine(w);

    for (kinds, 0..) |kind, i| {
        const is_sel = (i == app.synth_fx_picker_cursor);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.print("{s}", .{spectrum_ed.unitLabel(synth_ed.asFxKind(kind))});
        try w.writeAll(rst);
        try endLine(w);
    }
    if (kinds.len == 0) {
        try w.writeAll(dim);
        try w.print("    no match for /{s}", .{filter});
        try w.writeAll(rst);
        try endLine(w);
    }

    const used = 3 + @max(kinds.len, 1);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

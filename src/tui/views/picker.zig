//! Instrument-picker and FX-picker views.

const std = @import("std");
const ws = @import("wstudio");
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");
const spectrum_ed = @import("../../ui/editors/fx_editor.zig");
const app_mod = @import("../../ui/app.zig");

// Bare-name aliases for the shared palette/primitives.
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
        try w.writeAll(dim ++ " compatible notes stay" ++ rst);
    } else {
        try w.writeAll(dim ++ " choose track sound" ++ rst);
    }
    try endLine(w);

    var item_buf: [app_mod.instrument_picker_items.len]app_mod.InstrumentPickerItem = undefined;
    const items = app.filteredInstrumentPickerItems(&item_buf);
    const external_count = app.filteredInstrumentPluginCount();
    const filter = app.activeInstrumentFilter();

    // Section headers ride the same scrolled list as the entries, so a long
    // plugin list stays reachable - see app_mod.pickerDisplayRow for the
    // layout both this loop and pickerMouse decode.
    const list_len = 2 + items.len + external_count + @intFromBool(external_count == 0);
    const cursor_row = app_mod.pickerDisplayRow(app.picker_cursor, items.len);
    const vis_rows: usize = rows -| 6;
    if (cursor_row < app.picker_scroll) app.picker_scroll = cursor_row;
    if (vis_rows > 0 and cursor_row >= app.picker_scroll + vis_rows)
        app.picker_scroll = cursor_row - vis_rows + 1;
    if (app.picker_scroll >= list_len) app.picker_scroll = 0;
    const scroll = app.picker_scroll;
    const last_visible = @min(list_len, scroll + vis_rows);

    for (scroll..last_visible) |r| {
        if (r == 0) {
            try w.writeAll(bold ++ " INTERNAL" ++ rst);
        } else if (r == items.len + 1) {
            try w.writeAll(bold ++ " EXTERNAL" ++ rst ++ dim ++ "  CLAP / VST3" ++ rst);
        } else if (r <= items.len) {
            const item = items[r - 1];
            const is_sel = (r - 1 == app.picker_cursor);
            const icon = switch (item.kind) {
                .poly_synth => icons.synth,
                .sampler => icons.sampler,
                .drum_machine => icons.drum,
                .slicer => icons.slicer,
                .soundfont, .acoustic => icons.soundfont,
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
        } else if (r - 2 < items.len + external_count) {
            const i = r - 2;
            const plugin = app.filteredInstrumentPluginAt(i - items.len).?;
            const is_sel = (i == app.picker_cursor);
            if (is_sel) try w.writeAll(sel);
            try w.writeAll(if (is_sel) "  > " else "    ");
            try w.print("{s: <15}", .{plugin.name});
            if (!is_sel) try w.writeAll(dim);
            try w.print(" {s}  {s}", .{ ws.plugin_catalog.formatLabel(plugin.format), plugin.vendor });
            try w.writeAll(rst);
        } else {
            try w.writeAll(dim);
            if (items.len == 0 and filter.len > 0)
                try w.print("    no match for /{s}", .{filter})
            else
                try w.writeAll("    no external instruments found");
            try w.writeAll(rst);
        }
        try endLine(w);
    }

    const used = 2 + (last_visible - scroll);
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

    // Section headers ride the same scrolled list as the entries - 24 built-in
    // units alone overflow a short terminal. Layout shared with the
    // instrument picker and decoded by fxPickerMouse: app_mod.pickerDisplayRow.
    const list_len = 2 + total_count + @intFromBool(total_count == 0);
    const cursor_row = app_mod.pickerDisplayRow(app.fx_picker_cursor, kinds.len);
    const vis_rows: usize = rows -| 6;
    if (cursor_row < app.fx_picker_scroll) app.fx_picker_scroll = cursor_row;
    if (vis_rows > 0 and cursor_row >= app.fx_picker_scroll + vis_rows)
        app.fx_picker_scroll = cursor_row - vis_rows + 1;
    if (app.fx_picker_scroll >= list_len) app.fx_picker_scroll = 0;
    const scroll = app.fx_picker_scroll;
    const last_visible = @min(list_len, scroll + vis_rows);

    for (scroll..last_visible) |r| {
        if (r == 0) {
            try w.writeAll(bold ++ " INTERNAL" ++ rst);
        } else if (r == kinds.len + 1) {
            try w.writeAll(bold ++ " EXTERNAL" ++ rst ++ dim ++ "  CLAP / VST3" ++ rst);
        } else if (r <= kinds.len) {
            const k = kinds[r - 1];
            const is_sel = (r - 1 == app.fx_picker_cursor);
            try w.writeAll(if (is_sel) sel else style.fxKindColor(k));
            try w.writeAll(if (is_sel) "  > " else "    ");
            try w.print("{s: <12}", .{spectrum_ed.unitLabel(k)});
            if (!is_sel) try w.writeAll(rst ++ dim);
            try w.print(" {s}", .{spectrum_ed.pickerDescription(k)});
            try w.writeAll(rst);
        } else if (r - 2 < total_count) {
            const i = r - 2;
            const plugin = spectrum_ed.externalPickerAt(app, i - kinds.len).?;
            const is_sel = (i == app.fx_picker_cursor);
            if (is_sel) try w.writeAll(sel);
            try w.writeAll(if (is_sel) "  > " else "    ");
            try w.print("{s: <13}", .{plugin.name});
            if (!is_sel) try w.writeAll(dim);
            try w.print("{s}  {s}", .{ ws.plugin_catalog.formatLabel(plugin.format), plugin.vendor });
            try w.writeAll(rst);
        } else {
            try w.writeAll(dim);
            if (filter.len > 0)
                try w.print("    no match for /{s}", .{filter})
            else
                try w.writeAll("    NO EFFECTS AVAILABLE");
            try w.writeAll(rst);
        }
        try endLine(w);
    }

    const used = 2 + (last_visible - scroll);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

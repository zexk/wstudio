//! Preset-picker view (synth patches / drum kits) + its status bar. The
//! input half and the shared row model live in editors/preset_picker.zig.

const std = @import("std");
const preset_ed = @import("../../ui/editors/preset_picker.zig");
const style = @import("../style.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const sel = style.sel;
const yel = style.yel;
const endLine = style.endLine;

/// Genre tags joined "/" - same tags[1..] rule commands.zig's writeGenres
/// uses (index 0 is always the "wstudio" author tag on factory content).
fn writeGenres(w: *std.Io.Writer, tags: []const []const u8) !void {
    if (tags.len <= 1) return;
    for (tags[1..], 0..) |t, i| {
        if (i > 0) try w.writeAll("/");
        try w.writeAll(t);
    }
}

pub fn drawPresetPicker(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    const track_name = if (app.preset_picker_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.preset_picker_track].name
    else
        "?";

    var buf: [preset_ed.max_display_rows]preset_ed.DisplayRow = undefined;
    const rows_list = preset_ed.buildDisplayRows(app, &buf);
    const count = preset_ed.entryCountOf(rows_list);

    const title: []const u8 = switch (app.preset_picker_kind) {
        .synth => " SYNTH PRESETS",
        .drum => " DRUM KITS",
    };
    try w.writeAll(bold);
    try w.writeAll(title);
    try w.writeAll(rst ++ acc);
    try w.print("  \"{s}\"", .{track_name});
    try w.writeAll(rst ++ dim);
    if (count > 0) {
        try w.print("  {d}/{d}", .{ @min(app.preset_picker_cursor + 1, count), count });
    } else {
        try w.writeAll("  0 matches");
    }
    const filter = preset_ed.activeFilter(app);
    if (filter.len > 0) {
        try w.writeAll(rst ++ yel);
        try w.print("  /{s}", .{filter});
    }
    try w.writeAll(rst);
    try endLine(w);
    try endLine(w);

    // Scroll clamp keyed on the cursor entry's display row (headers count
    // too) - same "clamped at draw" convention the automation param picker
    // uses, including its rows-|5 budget (2-row preamble + 3-row footer).
    var cursor_row: usize = 0;
    var n: usize = 0;
    for (rows_list, 0..) |r, ri| {
        switch (r) {
            .entry => {
                // zig fmt: off
                if (n == app.preset_picker_cursor) { cursor_row = ri; break; }
                // zig fmt: on
                n += 1;
            },
            .header => {},
        }
    }
    const vis_rows: usize = rows -| 6;
    if (cursor_row < app.preset_picker_scroll) app.preset_picker_scroll = cursor_row;
    if (vis_rows > 0 and cursor_row >= app.preset_picker_scroll + vis_rows)
        app.preset_picker_scroll = cursor_row - vis_rows + 1;
    if (app.preset_picker_scroll >= rows_list.len) app.preset_picker_scroll = 0;
    const scroll = app.preset_picker_scroll;
    const last_visible = @min(rows_list.len, scroll + vis_rows);

    // Entry ordinal at the top of the visible window, for selection marks.
    var ord: usize = 0;
    for (rows_list[0..scroll]) |r| {
        if (r == .entry) ord += 1;
    }

    for (rows_list[scroll..last_visible]) |r| {
        switch (r) {
            .header => |name| {
                try w.writeAll(dim ++ bold);
                try w.print(" {s}", .{name});
                try w.writeAll(rst);
                try endLine(w);
            },
            .entry => |e| {
                const is_sel = ord == app.preset_picker_cursor;
                ord += 1;
                if (is_sel) try w.writeAll(sel);
                try w.writeAll(if (is_sel) "  > " else "    ");
                try w.print("{s: <18}", .{e.name});
                if (!is_sel) try w.writeAll(dim);
                // Kits list flat (no category headers), so the category
                // rides the row instead.
                if (app.preset_picker_kind == .drum) try w.print(" {s: <11}", .{e.category});
                try w.writeByte(' ');
                try writeGenres(w, e.tags);
                try w.writeAll(rst);
                try endLine(w);
            },
        }
    }
    if (count == 0) {
        try w.writeAll(dim);
        try w.print("    no match for /{s}", .{filter});
        try w.writeAll(rst);
        try endLine(w);
    }

    const printed = (last_visible - scroll) + @intFromBool(count == 0);
    const used = 2 + printed;
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

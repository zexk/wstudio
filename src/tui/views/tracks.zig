//! Tracks view + its status bar.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const Project = ws.Project;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const eq_mod = ws.dsp.eq;
const cmd_mod = @import("../cmd.zig");
const engine_mod = ws.engine;
const pattern_mod = ws.dsp.pattern;
const midi = ws.midi;
const style = @import("../style.zig");
const icons = @import("../icons.zig");

// Aliases so the moved render bodies reference the shared palette/primitives
// by their original bare names.
const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const red = style.red;
const sel = style.sel;
const blu = style.blu;
const mag = style.mag;
const bcyn = style.bcyn;
const bwht = style.bwht;
const endLine = style.endLine;
const hr = style.hr;
const meter = style.meter;
const spectrum_rows = style.spectrum_rows;
const spectrum_band_count = style.spectrum_band_count;
const synth_param_count = style.synth_param_count;
const synthBar = style.synthBar;
const synthSection = style.synthSection;
const rowHead = style.rowHead;
const rowVal = style.rowVal;
const barRow = style.barRow;
const enumRow = style.enumRow;

pub fn drawTracks(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    try w.writeAll(bold ++ " TRACKS" ++ rst);
    try w.writeAll(dim ++ "   [enter:edit  p:piano  A:arrange  s:spectrum  m:mute  S:solo  M:master  a:add  D:del  Y:dup  J/K:move  ?:help]");
    try endLine(w);

    for (app.session.project.tracks.items, 0..) |track, i| {
        const inst_tag = std.meta.activeTag(app.session.racks.items[i].instrument);
        const is_empty = inst_tag == .empty;
        const label: []const u8 = if (is_empty) "-- empty --" else app.session.racks.items[i].label;
        const hint: []const u8 = switch (inst_tag) {
            .empty => " [enter:insert]",
            .drum_machine => " [enter:grid]",
            else => " [enter:edit]",
        };
        const is_sel = (i == app.cursor);
        // muted-but-not-selected rows get a dim wash over everything
        const faded = track.muted and !is_sel;
        const marker: []const u8 = if (is_sel) ">" else " ";

        if (is_sel) try w.writeAll(sel);
        if (faded) try w.writeAll(dim);
        try w.writeByte(' ');
        try w.writeAll(marker);
        try w.writeByte(' ');
        try w.print("{d} ", .{i + 1});
        // name padded — no escape codes inside the padded field
        try w.print("{s: <8}", .{track.name});
        try w.writeByte(' ');
        // instrument-kind icon — a single Mono-font cell either way, so
        // blank tracks' plain space keeps every row's columns aligned.
        const kind_icon: []const u8 = switch (inst_tag) {
            .empty => " ",
            .poly_synth => icons.synth,
            .sampler => icons.sampler,
            .drum_machine => icons.drum,
        };
        try w.writeAll(kind_icon);
        try w.writeByte(' ');
        // muted indicator: yellow only when row isn't already faded
        if (track.muted) {
            if (!faded) try w.writeAll(yel);
            try w.writeByte('M');
            if (!faded) try w.writeAll(rst);
            if (is_sel) try w.writeAll(sel);
        } else {
            try w.writeByte(' ');
        }
        // solo indicator: green
        if (track.soloed) {
            if (!faded) try w.writeAll(grn);
            try w.writeByte('S');
            if (!faded) try w.writeAll(rst);
            if (is_sel) try w.writeAll(sel);
        } else {
            try w.writeByte(' ');
        }
        // instrument / rack label — accent only on active, unselected rows
        if (!is_sel and !faded) try w.writeAll(acc);
        try w.print(" [{s}]", .{label});
        if (!is_sel and !faded) try w.writeAll(rst);
        // FX badges
        if (!is_empty and i < app.session.racks.items.len) {
            const rfx = app.session.racks.items[i].fx;
            const any = rfx.comp != null or rfx.eq != null or rfx.delay != null or rfx.reverb != null;
            if (any) {
                if (!is_sel and !faded) try w.writeAll(acc);
                if (rfx.comp   != null) try w.writeAll(" cmp");
                if (rfx.eq     != null) try w.writeAll(" eq");
                if (rfx.delay  != null) try w.writeAll(" dly");
                if (rfx.reverb != null) try w.writeAll(" rev");
                if (!is_sel and !faded) try w.writeAll(rst);
            }
        }
        // Gain / pan — always shown; dim at defaults, accented when non-default.
        {
            const gdb = track.gain_db;
            const pan = track.pan;
            // gain
            if (gdb == 0.0) {
                if (!is_sel and !faded) try w.writeAll(dim);
                try w.writeAll("  0dB");
                if (!is_sel and !faded) try w.writeAll(rst);
            } else {
                const sign: []const u8 = if (gdb >= 0.0) "+" else "";
                try w.print("  {s}{d:.0}dB", .{ sign, gdb });
            }
            // pan
            if (pan == 0.0) {
                if (!is_sel and !faded) try w.writeAll(dim);
                try w.writeAll("  C");
                if (!is_sel and !faded) try w.writeAll(rst);
            } else {
                const pct: i32 = @intFromFloat(@abs(pan) * 100.0);
                try w.print("  {s}{d}%", .{ if (pan < 0.0) "L" else "R", pct });
            }
        }
        // keybind hint — dim only when not already faded/selected
        if (!is_sel and !faded) try w.writeAll(dim);
        try w.writeAll(hint);
        try endLine(w);
    }

    const used = 3 + app.session.project.tracks.items.len;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawTracksStatus(app: anytype, w: *std.Io.Writer) !void {
    switch (app.modal.mode) {
        .command => {
            try w.writeAll(dim ++ " :" ++ rst);
            try w.print("{s}_", .{app.modal.cmd_buf[0..app.modal.cmd_len]});
        },
        else => {
            const mode_colour: []const u8 = switch (app.modal.mode) {
                .insert => yel,
                else    => grn,
            };
            const mode_name = switch (app.modal.mode) {
                .normal  => "NORMAL",
                .insert  => "INSERT",
                .visual  => "VISUAL",
                .command => unreachable,
            };
            try w.writeAll(mode_colour);
            try w.writeAll(sel);
            try w.print(" {s} ", .{mode_name});
            try w.writeAll(rst);
            // track position
            try w.writeAll(dim ++ "  " ++ rst);
            try w.print("{d}/{d}", .{ app.cursor + 1, app.session.project.tracks.items.len });
            try w.writeAll(dim ++ "  oct " ++ rst);
            try w.print("{d}", .{app.modal.octave});
            if (app.modal.count > 0) try w.print("  {d}", .{app.modal.count});
            if (app.status_len > 0) {
                try w.writeAll(dim ++ "  " ++ rst);
                try w.writeAll(app.status_buf[0..app.status_len]);
            }
        },
    }
}


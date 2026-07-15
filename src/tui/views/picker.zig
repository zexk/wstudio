//! Instrument-picker and FX-picker views.

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
const synth_ed = @import("../editors/synth.zig");
const spectrum_ed = @import("../editors/spectrum.zig");

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

// zig fmt: off
/// Names + one-line descriptions for the instrument picker. Order must match
/// `app.picker_kinds`.
const picker_menu = [_]struct { name: []const u8, desc: []const u8, icon: []const u8 }{
    .{ .name = "Synth",        .desc = "subtractive/FM polysynth — piano-roll sequenceable",   .icon = icons.synth },
    .{ .name = "Sampler",      .desc = "one clip played chromatically — :load-sample to swap", .icon = icons.sampler },
    .{ .name = "Drum Machine", .desc = "64-pad step sequencer with per-pad sampler",            .icon = icons.drum },
    .{ .name = "Slicer",       .desc = "chop one sample into slices, step-sequence the chops",  .icon = icons.slicer },
};
// zig fmt: on

pub fn drawInstrumentPicker(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    const track_name = if (app.cursor < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.cursor].name
    else
        "?";

    try w.writeAll(bold ++ " INSERT INSTRUMENT" ++ rst);
    try w.writeAll(acc);
    try w.print("  \"{s}\"", .{track_name});
    try w.writeAll(rst);
    try endLine(w);
    try endLine(w);

    for (picker_menu, 0..) |item, i| {
        const is_sel = (i == app.picker_cursor);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.writeAll(item.icon);
        try w.writeByte(' ');
        try w.print("{s: <14}", .{item.name});
        if (!is_sel) try w.writeAll(dim);
        try w.print(" {s}", .{item.desc});
        try w.writeAll(rst);
        try endLine(w);
    }

    // used = title(1) + blank(1) actually printed above, plus the menu rows
    // — was "4 +" (stale from before the header/transport hr() rows were
    // removed), leaving 2 rows of dead blank space above the footer.
    const used = 2 + picker_menu.len;
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

// zig fmt: off
/// Names + one-line descriptions for the FX picker. Order must match
/// `editors/spectrum.zig`'s `picker_kinds`.
const fx_picker_menu = [_]struct { name: []const u8, desc: []const u8 }{
    .{ .name = "Gate",       .desc = "cuts signal below a threshold: cleans up noise and bleed" },
    .{ .name = "Compressor", .desc = "evens out dynamics: thresh/ratio/attack/release/makeup" },
    .{ .name = "Multiband",  .desc = "3-band compressor w/ crossover; OTT style adds upward squash too" },
    .{ .name = "OTT",        .desc = "the famous squash, pre-tuned: just depth/time/in/out gain" },
    .{ .name = "EQ",         .desc = "8-band parametric EQ: peak or lowpass/highpass w/ slope per band" },
    .{ .name = "Saturator",  .desc = "soft-clip drive: analog-style warmth through grit" },
    .{ .name = "Crusher",    .desc = "bitcrusher: lo-fi bit depth + sample-rate reduction" },
    .{ .name = "Chorus",     .desc = "modulated doubling: width and shimmer" },
    .{ .name = "Flanger",    .desc = "modulated delay w/ feedback: whoosh to metallic comb" },
    .{ .name = "Tape",       .desc = "wow+flutter: dual-LFO delay wobble for pitch-unstable tape character" },
    .{ .name = "Phaser",     .desc = "sweeping notches: slow swirl to fast wobble" },
    .{ .name = "Freq Shift", .desc = "Bode-style shifter: moves every partial by a fixed Hz, inharmonic" },
    .{ .name = "Delay",      .desc = "stereo echo with feedback and mix" },
    .{ .name = "Reverb",     .desc = "room to hall tails: room/damp/mix" },
};
// zig fmt: on

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
    const filter = spectrum_ed.activeFilter(app);

    try w.writeAll(bold ++ " INSERT EFFECT" ++ rst);
    try w.writeAll(acc);
    try w.print("  \"{s}\"", .{target});
    try w.writeAll(rst ++ dim);
    try w.print("  {d} match{s}", .{ kinds.len, if (kinds.len == 1) "" else "es" });
    if (filter.len > 0) {
        try w.writeAll(rst ++ yel);
        try w.print("  /{s}", .{filter});
    }
    try w.writeAll(rst);
    try endLine(w);
    try endLine(w);

    for (kinds, 0..) |k, i| {
        const is_sel = (i == app.fx_picker_cursor);
        const menu_i = std.mem.indexOfScalar(ws.FxKind, &spectrum_ed.picker_kinds, k) orelse 0;
        const item = fx_picker_menu[menu_i];
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.print("{s: <12}", .{item.name});
        if (!is_sel) try w.writeAll(dim);
        try w.print(" {s}", .{item.desc});
        try w.writeAll(rst);
        try endLine(w);
    }
    if (kinds.len == 0) {
        try w.writeAll(dim);
        try w.print("    no match for /{s}", .{filter});
        try w.writeAll(rst);
        try endLine(w);
    }

    // zig fmt: off
    // used = title(1) + blank(1) actually printed above, plus the menu rows
    // — was "4 +" (stale from before the header/transport hr() rows were
    // removed), leaving 2 rows of dead blank space above the footer.
    const used = 2 + @max(kinds.len, 1);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

// zig fmt: on

/// The synth-internal FX chain's insert picker — same shape as
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

    const used = 2 + @max(kinds.len, 1);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

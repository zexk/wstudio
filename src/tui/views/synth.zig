//! Synth editor view, its row primitives, and its status bar.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const Project = ws.Project;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const PolySynth = ws.dsp.PolySynth;
const engine_mod = ws.engine;
const midi = ws.midi;
const style = @import("../style.zig");
const icons = @import("../icons.zig");
const synth_layout = @import("../synth_layout.zig");

// Aliases so the moved render bodies reference the shared palette/primitives
// by their original bare names.
const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const red = style.red;
const blu = style.blu;
const mag = style.mag;
const bcyn = style.bcyn;
const bwht = style.bwht;
const endLine = style.endLine;
const hr = style.hr;
const synthBar = style.synthBar;
const synthSection = style.synthSection;
const barRow = style.barRow;
const enumRow = style.enumRow;

const synth_ed = @import("../editors/synth.zig");

fn drawSynthTitle(w: *std.Io.Writer, subview: synth_ed.Subview, name: []const u8, focused: bool) !void {
    try w.writeAll(bcyn ++ bold ++ " \u{2593} " ++ icons.synth ++ " SYNTH " ++ rst);
    inline for (.{ synth_ed.Subview.main, synth_ed.Subview.mod, synth_ed.Subview.fx }) |tab| {
        const label = switch (tab) {
            .main => "MAIN",
            .mod => "MOD",
            .fx => "FX",
        };
        if (tab == subview) {
            try w.writeAll(bcyn ++ bold);
            try w.print("[{s}]", .{label});
        } else {
            try w.writeAll(dim);
            try w.print(" {s} ", .{label});
        }
        try w.writeAll(rst);
    }
    if (focused) try w.writeAll(bcyn ++ bold ++ "  FOCUS" ++ rst);
    try w.writeAll("  " ++ acc);
    try w.print("\"{s}\"", .{name});
    try w.writeAll(rst);
    try endLine(w);
}

/// Render the synth editor into `w`, applying vertical scroll so it fits
/// within `max_rows`. Always shows the title line, then slices the current
/// subview's body to keep the cursor in view. `app.synth_subview` picks one
/// of three panes (see synth_ed.Subview): "main"/"mod" each pack their
/// cards into 1-3 columns by terminal width (see `drawSynthMain`/
/// `drawSynthMod`/synth_layout.zig); "fx" is still a single full-width list
/// regardless of width.
pub fn drawSynthEditor(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    // Available rows for the view body (excludes the caller's header +
    // transport + status - 4 rows total, no separate hr() rule rows anymore).
    const max_rows = rows -| 4;
    const subview = app.synth_subview;

    if (subview == .main) {
        try drawSynthMain(app, w, max_rows, cols);
        return;
    }
    if (subview == .mod) {
        try drawSynthMod(app, w, max_rows, cols);
        return;
    }

    // .fx - single full-width list of on (inserted) units only; off units
    // are reachable only through the `a` insert picker, not shown here.
    style.form_bar_w = @min(style.form_bar_w_default + (cols -| 100) / 2, 40);
    style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);

    var kbuf: [14]ws.dsp.synth.FxUnitKind = undefined;
    const fx_order = synth_ed.fxOnOrder(app, &kbuf);

    // Clamp scroll so the cursor row is visible and the window never runs
    // past the layout's last row (the layouts' heights differ per subview,
    // so a stale offset from a different one must not survive a resize or a
    // Tab subview switch).
    const cursor_row = synth_ed.fxRow(app.synth_cursor, fx_order);
    const body_rows: usize = switch (subview) {
        .fx => synth_ed.fxBodyRows(fx_order),
        .main, .mod => unreachable,
    };
    var scroll = @min(app.synth_scroll, (body_rows + 1) -| max_rows);
    if (cursor_row < scroll) scroll = cursor_row;
    if (cursor_row >= scroll + max_rows) scroll = cursor_row -| max_rows + 1;
    // Written back so mouse hit-testing (editors/synth.zig paramAtRow) maps
    // clicks through the same offset this frame actually rendered with.
    app.synth_scroll = scroll;

    if (app.synth_track >= app.session.racks.items.len) {
        for (0..max_rows) |_| try endLine(w);
        return;
    }
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => {
            for (0..max_rows) |_| try endLine(w);
            return;
        },
    }
    const synth = &rack.instrument.poly_synth;
    const c = app.synth_cursor;

    // zig fmt: off
    const name = if (app.synth_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.synth_track].name
    else "?";
    // zig fmt: on

    // Title (row 0) is always emitted outside the scroll window.
    try drawSynthTitle(w, subview, name, false);
    var written: usize = 1;

    // The FX strip is a fixed row above the scrolled section list (like the
    // title above it), not part of `tw`/`scroll` - mirrors the track/master
    // chain's own strip, which likewise sits outside its focused unit's
    // scrollable body. editors/synth.zig's `fxRow`/`handleMouse` account
    // for this same +1 row offset.
    if (subview == .fx and written < max_rows) {
        try drawFxStrip(app, w, c, cols);
        written += 1;
    }
    var tmp: [16 * 1024]u8 = undefined;
    var tw = std.Io.Writer.fixed(&tmp);
    switch (subview) {
        .fx => if (fx_order.len == 0) {
            try tw.writeAll(dim ++ "  no fx: press a to insert" ++ rst);
            try endLine(&tw);
        } else for (fx_order) |kind| {
            switch (kind) {
                .gate => try secFxGate(&tw, synth, c),
                .comp => try secFxComp(&tw, synth, c),
                .mb_comp => try secFxMb(&tw, synth, c),
                .ott => try secFxOtt(&tw, synth, c),
                .eq => try secFxEq(&tw, synth, c),
                .chorus => try secFxChorus(&tw, synth, c),
                .freq_shift => try secFxFreqShift(&tw, synth, c),
                .dist => try secFxDist(&tw, synth, c),
                .crush => try secFxCrush(&tw, synth, c),
                .flanger => try secFxFlanger(&tw, synth, c),
                .tape => try secFxTape(&tw, synth, c),
                .phaser => try secFxPhaser(&tw, synth, c),
                .delay => try secFxDelay(&tw, synth, c),
                .reverb => try secFxReverb(&tw, synth, c),
            }
        },
        .main, .mod => unreachable,
    }

    var line_it = std.mem.splitSequence(u8, tw.buffered(), "\r\n");
    var row: usize = 1;
    while (line_it.next()) |line| : (row += 1) {
        if (written >= max_rows) break;
        if (row < scroll + 1) continue;
        try w.writeAll(line);
        try endLine(w);
        written += 1;
    }
    while (written < max_rows) : (written += 1) try endLine(w);
}

/// `main_sections`' render functions, in the exact same order as the table
/// itself - the single place that maps a `synth_layout.SectionDef` to the
/// code that actually draws it. `sec*` bodies stay ordinary Zig (bespoke
/// formatting/dimming per param); only *which sections exist and in what
/// order* is table-driven.
const RenderFn = *const fn (w: *std.Io.Writer, synth: *const PolySynth, c: u8) anyerror!void;
const main_render_fns = [_]RenderFn{
    secOscA,   secOscB,    secOscC, secSub,  secNoise, secMod,
    secFilter, secFilter2, secEnv,  secFenv, secVoice, secArp,
    secOut,
};
comptime {
    if (main_render_fns.len != synth_layout.main_sections.len)
        @compileError("views/synth.zig: main_render_fns must mirror synth_layout.main_sections 1:1");
}

/// Which column (in the current `n`-column bucket) section `si` was packed
/// into - a small linear scan over the (already comptime-computed) visual
/// order rather than a second table, since `order` already carries this per
/// entry and sections are few (13).
fn sectionCol(order: []const synth_layout.PositionedEntry, si: usize) usize {
    for (order) |pe| {
        if (pe.section == si) return pe.col;
    }
    return 0;
}

/// The "main" subview: every `main_sections` card packed into 1-3 columns
/// by `cols` (see synth_layout.numCols), each column rendered into its own
/// temp buffer and then zipped row-by-row - the same technique the old
/// wide-mode OSC A/B split used, generalized from "2 fixed columns, top
/// block only" to "N columns, every section". The whole grid scrolls
/// together (one `scroll` offset shared by every column), matching
/// `editors/synth.zig`'s `updateScroll`/`moveEntry`.
fn drawSynthMain(app: anytype, w: *std.Io.Writer, max_rows: usize, cols: usize) !void {
    const n = synth_layout.numCols(cols);
    const col_w = synth_layout.colWidth(cols, n);
    style.form_bar_w = @min(style.form_bar_w_default + (col_w -| 100) / 2, 40);
    style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);

    const order = synth_layout.mainOrder(n);
    const heights = synth_layout.mainHeights(n);
    var body_rows: usize = 0;
    for (heights) |h| body_rows = @max(body_rows, h);

    const idx = synth_layout.indexContaining(order, app.synth_cursor) orelse 0;
    const cursor_row = if (order.len > 0) order[idx].row else 0;

    // The scroll window is content rows only - `max_rows` also counts the
    // title row emitted below, which never scrolls. Clamping against
    // `max_rows` directly here left the window one row too tall for what
    // the write loop actually has room for, so the very last content row
    // (whatever the cursor scrolled all the way down to reach) silently
    // never got written even though `scroll` claimed to include it.
    const content_rows = max_rows -| 1;
    var scroll = @min(app.synth_scroll, body_rows -| content_rows);
    if (cursor_row < scroll) scroll = cursor_row;
    if (cursor_row >= scroll + content_rows) scroll = cursor_row -| content_rows + 1;
    app.synth_scroll = scroll;

    if (app.synth_track >= app.session.racks.items.len) {
        for (0..max_rows) |_| try endLine(w);
        return;
    }
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => {
            for (0..max_rows) |_| try endLine(w);
            return;
        },
    }
    const synth = &rack.instrument.poly_synth;
    const c = app.synth_cursor;

    // zig fmt: off
    const name = if (app.synth_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.synth_track].name
    else "?";
    // zig fmt: on

    try drawSynthTitle(w, .main, name, app.synth_section_focus);
    var written: usize = 1;

    if (app.synth_section_focus) {
        const section = order[idx].section;
        style.form_bar_w = @min(style.form_bar_w_default + (cols -| 100) / 2, 40);
        style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);
        var focus_buf: [16 * 1024]u8 = undefined;
        var fw = std.Io.Writer.fixed(&focus_buf);
        try main_render_fns[section](&fw, synth, c);
        var lines = std.mem.splitSequence(u8, fw.buffered(), "\r\n");
        while (lines.next()) |line| {
            if (written >= max_rows) break;
            try style.writeClamped(w, line, cols);
            try endLine(w);
            written += 1;
        }
        while (written < max_rows) : (written += 1) try endLine(w);
        app.synth_scroll = 0;
        return;
    }

    var bufs: [3][16 * 1024]u8 = undefined;
    var writers: [3]std.Io.Writer = undefined;
    for (0..n) |i| writers[i] = std.Io.Writer.fixed(&bufs[i]);
    for (synth_layout.main_sections, 0..) |_, si| {
        const col = sectionCol(order, si);
        try main_render_fns[si](&writers[col], synth, c);
        try endLine(&writers[col]);
    }

    var iters: [3]std.mem.SplitIterator(u8, .sequence) = undefined;
    for (0..n) |i| iters[i] = std.mem.splitSequence(u8, writers[i].buffered(), "\r\n");

    var row: usize = 0;
    while (row < body_rows) : (row += 1) {
        // Every column's iterator must advance once per row regardless of
        // whether the row is about to be skipped by the scroll check below
        // - otherwise a scrolled-past row's lines are never consumed and
        // every column desyncs from `row` for the rest of the frame.
        var lines: [3][]const u8 = .{ "", "", "" };
        for (0..n) |i| {
            if (row < heights[i]) lines[i] = iters[i].next() orelse "";
        }
        if (written >= max_rows) break;
        if (row < scroll) continue;
        for (0..n) |i| {
            if (i + 1 < n) {
                try style.writePadded(w, lines[i], col_w);
            } else {
                try style.writeClamped(w, lines[i], cols -| col_w * (n - 1));
            }
        }
        try endLine(w);
        written += 1;
    }
    while (written < max_rows) : (written += 1) try endLine(w);
}

/// `mod_sections`' render functions - the `.mod` counterpart to
/// `main_render_fns`.
const mod_render_fns = [_]RenderFn{
    secMatrix, secLfo, secLfo2, secLfo3, secEnv3, secMacro,
};
comptime {
    if (mod_render_fns.len != synth_layout.mod_sections.len)
        @compileError("views/synth.zig: mod_render_fns must mirror synth_layout.mod_sections 1:1");
}

/// The "mod" subview: modulation sources - the matrix, LFO 1-3, ENV 3,
/// macros - packed the same way `drawSynthMain` packs MAIN's cards. See
/// that function's doc comment; the only difference is which table/render-fn
/// array it reads.
fn drawSynthMod(app: anytype, w: *std.Io.Writer, max_rows: usize, cols: usize) !void {
    const n = synth_layout.numCols(cols);
    const col_w = synth_layout.colWidth(cols, n);
    style.form_bar_w = @min(style.form_bar_w_default + (col_w -| 100) / 2, 40);
    style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);

    const order = synth_layout.modOrder(n);
    const heights = synth_layout.modHeights(n);
    var body_rows: usize = 0;
    for (heights) |h| body_rows = @max(body_rows, h);

    const idx = synth_layout.indexContaining(order, app.synth_cursor) orelse 0;
    const cursor_row = if (order.len > 0) order[idx].row else 0;

    // See drawSynthMain's matching comment: the scroll window is content
    // rows only, `max_rows` also counts the never-scrolling title row.
    const content_rows = max_rows -| 1;
    var scroll = @min(app.synth_scroll, body_rows -| content_rows);
    if (cursor_row < scroll) scroll = cursor_row;
    if (cursor_row >= scroll + content_rows) scroll = cursor_row -| content_rows + 1;
    app.synth_scroll = scroll;

    if (app.synth_track >= app.session.racks.items.len) {
        for (0..max_rows) |_| try endLine(w);
        return;
    }
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => {
            for (0..max_rows) |_| try endLine(w);
            return;
        },
    }
    const synth = &rack.instrument.poly_synth;
    const c = app.synth_cursor;

    // zig fmt: off
    const name = if (app.synth_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.synth_track].name
    else "?";
    // zig fmt: on

    try drawSynthTitle(w, .mod, name, app.synth_section_focus);
    var written: usize = 1;

    if (app.synth_section_focus) {
        const section = order[idx].section;
        style.form_bar_w = @min(style.form_bar_w_default + (cols -| 100) / 2, 40);
        style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);
        var focus_buf: [16 * 1024]u8 = undefined;
        var fw = std.Io.Writer.fixed(&focus_buf);
        try mod_render_fns[section](&fw, synth, c);
        var lines = std.mem.splitSequence(u8, fw.buffered(), "\r\n");
        while (lines.next()) |line| {
            if (written >= max_rows) break;
            try style.writeClamped(w, line, cols);
            try endLine(w);
            written += 1;
        }
        while (written < max_rows) : (written += 1) try endLine(w);
        app.synth_scroll = 0;
        return;
    }

    var bufs: [3][16 * 1024]u8 = undefined;
    var writers: [3]std.Io.Writer = undefined;
    for (0..n) |i| writers[i] = std.Io.Writer.fixed(&bufs[i]);
    for (synth_layout.mod_sections, 0..) |_, si| {
        const col = sectionCol(order, si);
        try mod_render_fns[si](&writers[col], synth, c);
        try endLine(&writers[col]);
    }

    var iters: [3]std.mem.SplitIterator(u8, .sequence) = undefined;
    for (0..n) |i| iters[i] = std.mem.splitSequence(u8, writers[i].buffered(), "\r\n");

    var row: usize = 0;
    while (row < body_rows) : (row += 1) {
        var lines: [3][]const u8 = .{ "", "", "" };
        for (0..n) |i| {
            if (row < heights[i]) lines[i] = iters[i].next() orelse "";
        }
        if (written >= max_rows) break;
        if (row < scroll) continue;
        for (0..n) |i| {
            if (i + 1 < n) {
                try style.writePadded(w, lines[i], col_w);
            } else {
                try style.writeClamped(w, lines[i], cols -| col_w * (n - 1));
            }
        }
        try endLine(w);
        written += 1;
    }
    while (written < max_rows) : (written += 1) try endLine(w);
}

/// The `.fx` subview's chain strip: `IN▶` + each on unit's short label in
/// `fx_order` sequence + a `+` insert affordance + `▶OUT`, all read from
/// `synth_ed.stripLayout` - the single source of truth this and
/// `editors/synth.zig`'s click handler (`stripSlotAt`) both use, so a click
/// can never land somewhere this didn't draw. The focused unit's label is
/// bold/white; others green. Mirrors the track/master chain's own strip
/// closely enough to feel like the same control, minus the multi-row box
/// border - this one stays a single fixed row above the scrolled section
/// list (see drawSynthEditor's call site).
fn drawFxStrip(app: anytype, w: *std.Io.Writer, c: u8, cols: usize) !void {
    var buf: [14]synth_ed.StripSlot = undefined;
    const slots = synth_ed.stripLayout(app, cols, &buf);
    const focused = synth_ed.fxKindOfId(c);
    try w.writeAll(dim ++ synth_ed.strip_prefix ++ rst);
    for (slots, 0..) |slot, i| {
        if (i > 0) try w.writeAll(dim ++ "\u{25B6}" ++ rst);
        if (slot.kind == null) {
            try w.writeAll(dim ++ rst);
        } else {
            try w.writeAll(if (slot.kind == focused) bwht ++ bold else grn);
        }
        try w.writeAll(slot.label);
        try w.writeAll(rst);
    }
    try w.writeAll(dim ++ synth_ed.strip_suffix ++ rst);
    try endLine(w);
}

// The section renderers below emit one header row + one row per param each.
// Which sections exist per subview, their order, and how they pack into
// columns now lives in synth_layout.zig's comptime tables - see
// drawSynthMain/main_render_fns below for how MAIN consumes them. MOD/FX
// keep their previous per-subview rendering for now (see synth_layout.zig's
// module doc comment).

const wf_names = [_][]const u8{ "sine", "saw", "tri", "sqr", "wt" };

fn secOscA(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC A", acc);

    // zig fmt: off
    const wf_idx: usize = switch (synth.waveform) {
        .sine => 0, .saw => 1, .triangle => 2, .square => 3, .wavetable => 4,
    };
    try enumRow(w, c == 0, false, acc, "waveform", &wf_names, wf_idx);

    // param 1: pulse width (only meaningful for square)
    try barRow(w, c == 1, synth.waveform != .square, acc, "pls.width", synth.pulse_width, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.pulse_width}));

    // params 2–5: detune, unison, uni.det, spread
    try barRow(w, c == 2, false, acc, "detune", synth.detune_cents + 100.0, 200.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ct", .{synth.detune_cents}));
    try barRow(w, c == 3, false, acc, "unison", @floatFromInt(synth.unison), 16.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.unison}));
    try barRow(w, c == 4, false, acc, "uni.det", synth.unison_detune, 100.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ct", .{synth.unison_detune}));
    try barRow(w, c == 5, false, acc, "spread", synth.unison_spread, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.unison_spread}));

    // uni.mode/warp/wt.pos: formerly the standalone UNI MODE/WARP/WAVETABLE
    // sections' "osc a" rows - folded into this card so each oscillator's
    // controls live in one place instead of three cross-cutting sections.
    try enumRow(w, c == 39, synth.unison <= 1, acc, "uni.mode", &uni_mode_names, uniModeIdx(synth.unison_mode));
    const warp_a_idx: usize = switch (synth.warp_mode) {
        .none => 0, .bend => 1, .mirror => 2, .sync => 3,
    };
    try enumRow(w, c == 41, false, acc, "warp", &warp_mode_names, warp_a_idx);
    try barRow(w, c == 42, synth.warp_mode == .none, acc, "warp amt", synth.warp_amount, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.warp_amount}));
    try barRow(w, c == 185, synth.waveform != .wavetable, acc, "wt.pos", synth.wt_pos, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.wt_pos}));
}
// zig fmt: on

fn secOscB(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC B", acc);

    const b_on = synth.osc_b_on;
    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 6, false, acc, "on/off", &on_names, if (b_on) 0 else 1);

    // zig fmt: off
    const wfb_idx: usize = switch (synth.osc_b_waveform) {
        .sine => 0, .saw => 1, .triangle => 2, .square => 3, .wavetable => 4,
    };
    try enumRow(w, c == 7, !b_on, acc, "waveform", &wf_names, wfb_idx);

    try barRow(w, c == 8, !b_on, acc, "pls.width", synth.osc_b_pulse_width, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_pulse_width}));
    try barRow(w, c == 9, !b_on, acc, "semi", synth.osc_b_semi + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.0}", .{synth.osc_b_semi}));
    try barRow(w, c == 10, !b_on, acc, "detune", synth.osc_b_detune_cents + 100.0, 200.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ct", .{synth.osc_b_detune_cents}));
    try barRow(w, c == 11, !b_on, acc, "level", synth.osc_b_level, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_level}));
    try barRow(w, c == 12, !b_on, acc, "unison", @floatFromInt(synth.osc_b_unison), 16.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.osc_b_unison}));
    try barRow(w, c == 13, !b_on, acc, "uni.det", synth.osc_b_unison_detune, 100.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ct", .{synth.osc_b_unison_detune}));

    // uni.mode/warp/wt.pos - see secOscA's matching rows for why these live
    // here now instead of in standalone UNI MODE/WARP/WAVETABLE sections.
    try enumRow(w, c == 40, !b_on or synth.osc_b_unison <= 1, acc, "uni.mode", &uni_mode_names, uniModeIdx(synth.osc_b_unison_mode));
    const warp_b_idx: usize = switch (synth.osc_b_warp_mode) {
        .none => 0, .bend => 1, .mirror => 2, .sync => 3,
    };
    try enumRow(w, c == 43, !b_on, acc, "warp", &warp_mode_names, warp_b_idx);
    try barRow(w, c == 44, !b_on or synth.osc_b_warp_mode == .none, acc, "warp amt", synth.osc_b_warp_amount, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_warp_amount}));
    try barRow(w, c == 186, !b_on or synth.osc_b_waveform != .wavetable, acc, "wt.pos", synth.osc_b_wt_pos, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_wt_pos}));
}

fn secMod(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "MOD  (A \u{2194} B)", mag);

    const mod_on = synth.mod_mode != .none;
    const mod_names = [_][]const u8{ "off", "ring", "AM>B", "AM>A", "FM>B", "FM>A" };
    const mod_idx: usize = switch (synth.mod_mode) {
        .none => 0, .ring => 1, .am_a_to_b => 2, .am_b_to_a => 3,
        .fm_a_to_b => 4, .fm_b_to_a => 5,
    };
    try enumRow(w, c == 14, false, mag, "mode", &mod_names, mod_idx);

    {
        const is_fm = switch (synth.mod_mode) { .fm_a_to_b, .fm_b_to_a => true, else => false };
        const vs = if (is_fm)
            try std.fmt.bufPrint(&buf, "\u{03B2}={d:.2}", .{synth.mod_amount})
        else
            try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.mod_amount});
        try barRow(w, c == 15, !mod_on, mag, "amount", synth.mod_amount, 8.0, vs);
    }
}

fn secEnv(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "AMP ENV", grn);

    try barRow(w, c == 16, false, grn, "attack", synth.attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.attack_s}));
    try barRow(w, c == 17, false, grn, "decay", synth.decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.decay_s}));
    try barRow(w, c == 18, false, grn, "sustain", synth.sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.sustain}));
    try barRow(w, c == 19, false, grn, "release", synth.release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.release_s}));
}

const filter_type_names = [_][]const u8{ "lp", "hp", "bp", "ntch", "ladr", "diod", "comb", "frmt" };

fn filterTypeIdx(ft: anytype) usize {
    return switch (ft) { .lp => 0, .hp => 1, .bp => 2, .notch => 3, .ladder => 4, .diode => 5, .comb => 6, .formant => 7 };
}

fn filterTypeName(ft: anytype) []const u8 {
    return switch (ft) { .lp => "lp", .hp => "hp", .bp => "bp", .notch => "notch", .ladder => "ladder", .diode => "diode", .comb => "comb", .formant => "formant" };
}

fn secFilter(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FILTER 1", yel);

    try enumRow(w, c == 20, false, yel, "type", &filter_type_names, filterTypeIdx(synth.filter_type));

    {
        const log_norm = std.math.log2(synth.filter_cutoff / 20.0) /
            std.math.log2(20_000.0 / 20.0);
        const vs = if (synth.filter_cutoff >= 1_000.0)
            try std.fmt.bufPrint(&buf, "{d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.filter_cutoff});
        try barRow(w, c == 21, false, yel, "cutoff", log_norm, 1.0, vs);
    }
    try barRow(w, c == 22, false, yel, "res", synth.filter_res, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.filter_res}));
}

fn secFenv(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FILTER ENV", grn);

    try barRow(w, c == 24, false, grn, "f.attack", synth.fenv_attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_attack_s}));
    try barRow(w, c == 25, false, grn, "f.decay", synth.fenv_decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_decay_s}));
    try barRow(w, c == 26, false, grn, "f.sustain", synth.fenv_sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.fenv_sustain}));
    try barRow(w, c == 27, false, grn, "f.release", synth.fenv_release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_release_s}));
}

const lfo_shape_names = [_][]const u8{ "sine", "tri", "saw", "sqr", "s&h", "cha" };

fn lfoShapeIdx(shape: anytype) usize {
    return switch (shape) { .sine => 0, .triangle => 1, .saw => 2, .square => 3, .sh => 4, .chaos => 5 };
}

fn lfoShapeName(shape: anytype) []const u8 {
    return switch (shape) { .sine => "sine", .triangle => "tri", .saw => "saw", .square => "sqr", .sh => "s&h", .chaos => "chaos" };
}

/// Shape + rate only: the LFO is a pure mod source, its routing lives on
/// MATRIX rows (the matrix absorbed the old depth/target params).
fn secLfo(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "LFO 1", mag);

    try enumRow(w, c == 28, false, mag, "shape", &lfo_shape_names, lfoShapeIdx(synth.lfo_shape));

    try barRow(w, c == 29, false, mag, "rate", synth.lfo_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.lfo_rate_hz}));
}

fn secLfo2(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "LFO 2", mag);
    try enumRow(w, c == 95, false, mag, "shape", &lfo_shape_names, lfoShapeIdx(synth.lfo2_shape));
    try barRow(w, c == 96, false, mag, "rate", synth.lfo2_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.lfo2_rate_hz}));
}

fn secLfo3(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "LFO 3", mag);
    try enumRow(w, c == 97, false, mag, "shape", &lfo_shape_names, lfoShapeIdx(synth.lfo3_shape));
    try barRow(w, c == 98, false, mag, "rate", synth.lfo3_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.lfo3_rate_hz}));
}

/// Four macro knobs - pure mod sources (mc1-mc4 on MATRIX rows), no sound
/// of their own, automatable as ids 99-102.
fn secMacro(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "MACRO", bcyn);
    const vals = [4]f32{ synth.macro1, synth.macro2, synth.macro3, synth.macro4 };
    for (vals, 0..) |v, k| {
        var lbl: [12]u8 = undefined;
        try barRow(w, c == 99 + @as(u8, @intCast(k)), false, bcyn,
            try std.fmt.bufPrint(&lbl, "macro {d}", .{k + 1}), v, 1.0,
            try std.fmt.bufPrint(&buf, "{d:.2}", .{v}));
    }
}

const arp_mode_names = [_][]const u8{ "up", "down", "up/dn", "dn/up", "played", "random", "chord" };

fn arpModeIdx(mode: anytype) usize {
    return switch (mode) {
        .up => 0, .down => 1, .updown => 2, .downup => 3,
        .played => 4, .random => 5, .chord => 6,
    };
}

fn arpModeName(mode: anytype) []const u8 {
    return switch (mode) {
        .up => "up", .down => "down", .updown => "up/dn", .downup => "dn/up",
        .played => "played", .random => "random", .chord => "chord",
    };
}

/// A step sequencer in front of note triggering - see PolySynth's own ARP
/// doc comment.
fn secArp(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "ARP", bcyn);

    const on = synth.arp_on;
    try enumRow(w, c == 116, false, bcyn, "on/off", &on_off_names, if (on) 0 else 1);
    try enumRow(w, c == 117, !on, bcyn, "mode", &arp_mode_names, arpModeIdx(synth.arp_mode));
    try barRow(w, c == 118, !on or synth.arp_mode == .chord, bcyn, "octaves", @floatFromInt(synth.arp_octaves), 4.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.arp_octaves}));
    try barRow(w, c == 119, !on, bcyn, "rate", synth.arp_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.1} Hz", .{synth.arp_rate_hz}));
    try barRow(w, c == 120, !on, bcyn, "gate", synth.arp_gate, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.arp_gate}));
    try enumRow(w, c == 121, !on, bcyn, "hold", &on_off_names, if (synth.arp_hold) 0 else 1);
}

/// A third ADSR with no fixed destination - a pure MATRIX source (env3),
/// same shape as FENV but not tied to the filter.
fn secEnv3(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "ENV 3", grn);

    try barRow(w, c == 122, false, grn, "attack", synth.env3_attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.env3_attack_s}));
    try barRow(w, c == 123, false, grn, "decay", synth.env3_decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.env3_decay_s}));
    try barRow(w, c == 124, false, grn, "sustain", synth.env3_sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.env3_sustain}));
    try barRow(w, c == 125, false, grn, "release", synth.env3_release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.env3_release_s}));
}

fn secVoice(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "VOICE", blu);

    const vm_names = [_][]const u8{ "poly", "mono", "lgto" };
    const vm_idx: usize = switch (synth.voice_mode) {
        .poly => 0, .mono => 1, .legato => 2,
    };
    try enumRow(w, c == 32, false, blu, "mode", &vm_names, vm_idx);

    try barRow(w, c == 33, false, blu, "glide", synth.glide_s, 10.0,
        if (synth.glide_s == 0.0) "off" else try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.glide_s}));
}

fn secSub(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "SUB", acc);

    try barRow(w, c == 34, false, acc, "level", synth.sub_level, 1.0,
        if (synth.sub_level == 0.0) "off" else try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.sub_level}));
    {
        const sh_names = [_][]const u8{ "sine", "sqr" };
        const sh_idx: usize = switch (synth.sub_shape) { .sine => 0, .square => 1 };
        try enumRow(w, c == 35, synth.sub_level == 0.0, acc, "shape", &sh_names, sh_idx);
    }
}

fn secNoise(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "NOISE", acc);

    try barRow(w, c == 36, false, acc, "level", synth.noise_level, 1.0,
        if (synth.noise_level == 0.0) "off" else try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.noise_level}));
    {
        const hint: []const u8 = if (synth.noise_color < 0.33) "dark"
            else if (synth.noise_color > 0.66) "white" else "warm";
        try barRow(w, c == 37, synth.noise_level == 0.0, acc, "color", synth.noise_color, 1.0,
            try std.fmt.bufPrint(&buf, "{d:.2}  {s}", .{ synth.noise_color, hint }));
    }
}

fn secOut(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OUT", bcyn);

    try barRow(w, c == 38, false, bcyn, "gain", synth.gain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.gain}));
}

const uni_mode_names = [_][]const u8{ "spread", "step", "harm", "ratio" };

fn uniModeIdx(mode: anytype) usize {
    return switch (mode) { .spread => 0, .step => 1, .harmonic => 2, .ratio => 3 };
}

fn uniModeName(mode: anytype) []const u8 {
    return switch (mode) { .spread => "spread", .step => "step", .harmonic => "harmonic", .ratio => "ratio" };
}

const warp_mode_names = [_][]const u8{ "none", "bend", "mirror", "sync" };

fn secFilter2(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FILTER 2", yel);

    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 45, false, yel, "on/off", &on_names, if (synth.filter2_on) 0 else 1);

    const on = synth.filter2_on;
    try enumRow(w, c == 46, !on, yel, "type", &filter_type_names, filterTypeIdx(synth.filter2_type));

    {
        const log_norm = std.math.log2(synth.filter2_cutoff / 20.0) /
            std.math.log2(20_000.0 / 20.0);
        const vs = if (synth.filter2_cutoff >= 1_000.0)
            try std.fmt.bufPrint(&buf, "{d:.2} kHz", .{synth.filter2_cutoff / 1_000.0})
        else
            try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.filter2_cutoff});
        try barRow(w, c == 47, !on, yel, "cutoff", log_norm, 1.0, vs);
    }
    try barRow(w, c == 48, !on, yel, "res", synth.filter2_res, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.filter2_res}));

    const routing_names = [_][]const u8{ "series", "parallel" };
    const routing_idx: usize = switch (synth.filter_routing) { .series => 0, .parallel => 1 };
    try enumRow(w, c == 49, !on, yel, "routing", &routing_names, routing_idx);
}

/// Plain additive 3rd oscillator - same row shape as OSC B, no mod/warp rows
/// since OSC C doesn't participate in either (see PolySynth's own doc comment).
fn secOscC(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC C", acc);

    const c_on = synth.osc_c_on;
    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 50, false, acc, "on/off", &on_names, if (c_on) 0 else 1);

    const wfc_idx: usize = switch (synth.osc_c_waveform) {
        .sine => 0, .saw => 1, .triangle => 2, .square => 3, .wavetable => 4,
    };
    try enumRow(w, c == 51, !c_on, acc, "waveform", &wf_names, wfc_idx);

    try barRow(w, c == 52, !c_on, acc, "pls.width", synth.osc_c_pulse_width, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_c_pulse_width}));
    try barRow(w, c == 53, !c_on, acc, "semi", synth.osc_c_semi + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.0}", .{synth.osc_c_semi}));
    try barRow(w, c == 54, !c_on, acc, "detune", synth.osc_c_detune_cents + 100.0, 200.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ct", .{synth.osc_c_detune_cents}));
    try barRow(w, c == 55, !c_on, acc, "level", synth.osc_c_level, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_c_level}));
    try barRow(w, c == 56, !c_on, acc, "unison", @floatFromInt(synth.osc_c_unison), 16.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.osc_c_unison}));
    try barRow(w, c == 57, !c_on, acc, "uni.det", synth.osc_c_unison_detune, 100.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ct", .{synth.osc_c_unison_detune}));

    try enumRow(w, c == 58, !c_on or synth.osc_c_unison <= 1, acc, "uni.mode", &uni_mode_names, uniModeIdx(synth.osc_c_unison_mode));
    try barRow(w, c == 187, !c_on or synth.osc_c_waveform != .wavetable, acc, "wt.pos", synth.osc_c_wt_pos, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_c_wt_pos}));
}

const mod_src_names = [_][]const u8{ "off", "lfo", "fenv", "aenv", "vel", "key", "whl", "lfo2", "lfo3", "mc1", "mc2", "mc3", "mc4", "env3" };

fn modSrcIdx(src: anytype) usize {
    return @intFromEnum(src);
}

/// 8 mod-matrix rows, 3 editor rows each (source / dest / depth). Dest and
/// depth dim while the row's source is off, mirroring the on/off gating the
/// oscillator sections use.
/// One line per slot: `N  <source>  <dest>  [bar]  <depth>`. `w`/`b` move
/// the cursor between the source/dest/depth fields (see
/// synth_layout.moveField - matrix rows are `fields = 3` entries); `j`/`k`
/// move between slots preserving whichever field was focused. Source/dest
/// dim while the slot is off, matching the oscillator sections' on/off
/// dimming convention.
fn secMatrix(w: *std.Io.Writer, synth: *const PolySynth, c: u8) !void {
    try synthSection(w, "MATRIX", mag);

    for (synth.mod_matrix, 0..) |row, k| {
        const base: u8 = @intCast(59 + k * 3);
        const off = row.source == .none;
        const sel_src = c == base;
        const sel_dst = c == base + 1;
        const sel_dep = c == base + 2;
        const focused = sel_src or sel_dst or sel_dep;

        if (focused) {
            try w.writeAll(bcyn ++ bold);
            try w.print("\u{25B8} {d}  ", .{k + 1});
        } else {
            try w.print("  {d}  ", .{k + 1});
        }
        try w.writeAll(rst);

        if (sel_src) {
            try w.writeAll(bwht ++ bold);
        } else if (off) {
            try w.writeAll(dim);
        }
        try w.print("{s: <5}", .{mod_src_names[modSrcIdx(row.source)]});
        try w.writeAll(rst ++ "  ");

        if (sel_dst) {
            try w.writeAll(bwht ++ bold);
        } else if (off) {
            try w.writeAll(dim);
        }
        try w.print("{s: <14}", .{ws.dsp.PolySynth.modDestLabel(row.dest)});
        try w.writeAll(rst ++ "  ");

        const bc = if (sel_dep) bcyn else if (off) dim else mag;
        try synthBar(w, row.depth + 1.0, 2.0, sel_dep, bc);
        try w.writeAll("  ");
        if (sel_dep) {
            try w.writeAll(bwht ++ bold);
        } else if (off) {
            try w.writeAll(dim);
        }
        const sign: []const u8 = if (row.depth >= 0.0) "+" else "";
        try w.print("{s}{d:.2}", .{ sign, row.depth });
        try w.writeAll(rst);
        try endLine(w);
    }
}

const on_off_names = [_][]const u8{ "on", "off" };

/// Log-normalized 0..1 bar fill for a 20Hz-20kHz frequency param - same
/// formula `secFilter`'s cutoff bar already uses (a linear fill would cram
/// almost the whole audible range into the bar's first few percent).
fn freqBarVal(hz: f32) f32 {
    return std.math.log2(hz / 20.0) / std.math.log2(20_000.0 / 20.0);
}

/// Internal FX sections: post-mix, user-reorderable inside the synth
/// itself, distinct from the track FX chain - these params are matrix and
/// automation targets (see PolySynth's FX field block).
fn secFxGate(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX GATE", red);

    const on = synth.fx_gate_on;
    try enumRow(w, c == 132, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 133, !on, red, "threshold", synth.fx_gate_threshold_db + 80.0, 80.0,
        try std.fmt.bufPrint(&buf, "{d:.0} dB", .{synth.fx_gate_threshold_db}));
    try barRow(w, c == 134, !on, red, "attack", synth.fx_gate_attack_ms, 50.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ms", .{synth.fx_gate_attack_ms}));
    try barRow(w, c == 135, !on, red, "release", synth.fx_gate_release_ms, 1000.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ms", .{synth.fx_gate_release_ms}));
}

fn secFxComp(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX COMP", red);

    const on = synth.fx_comp_on;
    try enumRow(w, c == 137, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 138, !on, red, "threshold", synth.fx_comp_threshold_db + 60.0, 60.0,
        try std.fmt.bufPrint(&buf, "{d:.0} dB", .{synth.fx_comp_threshold_db}));
    try barRow(w, c == 139, !on, red, "ratio", synth.fx_comp_ratio, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.1}:1", .{synth.fx_comp_ratio}));
    try barRow(w, c == 140, !on, red, "attack", synth.fx_comp_attack_ms, 500.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ms", .{synth.fx_comp_attack_ms}));
    try barRow(w, c == 141, !on, red, "release", synth.fx_comp_release_ms, 2000.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ms", .{synth.fx_comp_release_ms}));
    try barRow(w, c == 142, !on, red, "makeup", synth.fx_comp_makeup_db + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_comp_makeup_db}));
}

const mb_style_names = [_][]const u8{ "classic", "OTT" };

fn secFxMb(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX MB", red);

    const on = synth.fx_mb_on;
    try enumRow(w, c == 144, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 145, !on, red, "xover lo", synth.fx_mb_xover_lo, 20_000.0,
        try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.fx_mb_xover_lo}));
    try barRow(w, c == 146, !on, red, "xover hi", synth.fx_mb_xover_hi, 20_000.0,
        try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.fx_mb_xover_hi}));
    try barRow(w, c == 147, !on, red, "attack", synth.fx_mb_attack_ms, 500.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ms", .{synth.fx_mb_attack_ms}));
    try barRow(w, c == 148, !on, red, "release", synth.fx_mb_release_ms, 2000.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ms", .{synth.fx_mb_release_ms}));
    try enumRow(w, c == 149, !on, red, "style", &mb_style_names, @intFromEnum(synth.fx_mb_style));
    try barRow(w, c == 150, !on, red, "mix", synth.fx_mb_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_mb_mix}));
    try barRow(w, c == 151, !on, red, "lo thresh", synth.fx_mb_low_threshold_db + 60.0, 60.0,
        try std.fmt.bufPrint(&buf, "{d:.0} dB", .{synth.fx_mb_low_threshold_db}));
    try barRow(w, c == 152, !on, red, "lo ratio", synth.fx_mb_low_ratio, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.1}:1", .{synth.fx_mb_low_ratio}));
    try barRow(w, c == 153, !on, red, "lo makeup", synth.fx_mb_low_makeup_db + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_mb_low_makeup_db}));
    try barRow(w, c == 154, !on, red, "mid thresh", synth.fx_mb_mid_threshold_db + 60.0, 60.0,
        try std.fmt.bufPrint(&buf, "{d:.0} dB", .{synth.fx_mb_mid_threshold_db}));
    try barRow(w, c == 155, !on, red, "mid ratio", synth.fx_mb_mid_ratio, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.1}:1", .{synth.fx_mb_mid_ratio}));
    try barRow(w, c == 156, !on, red, "mid makeup", synth.fx_mb_mid_makeup_db + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_mb_mid_makeup_db}));
    try barRow(w, c == 157, !on, red, "hi thresh", synth.fx_mb_high_threshold_db + 60.0, 60.0,
        try std.fmt.bufPrint(&buf, "{d:.0} dB", .{synth.fx_mb_high_threshold_db}));
    try barRow(w, c == 158, !on, red, "hi ratio", synth.fx_mb_high_ratio, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.1}:1", .{synth.fx_mb_high_ratio}));
    try barRow(w, c == 159, !on, red, "hi makeup", synth.fx_mb_high_makeup_db + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_mb_high_makeup_db}));
}

fn secFxOtt(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX OTT", red);

    const on = synth.fx_ott_on;
    try enumRow(w, c == 161, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 162, !on, red, "depth", synth.fx_ott_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_ott_depth}));
    try barRow(w, c == 163, !on, red, "time", synth.fx_ott_time, 4.0,
        try std.fmt.bufPrint(&buf, "{d:.2}x", .{synth.fx_ott_time}));
    try barRow(w, c == 164, !on, red, "gain in", synth.fx_ott_gain_in_db + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_ott_gain_in_db}));
    try barRow(w, c == 165, !on, red, "gain out", synth.fx_ott_gain_out_db + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_ott_gain_out_db}));
}

fn secFxEq(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX EQ", red);

    const on = synth.fx_eq_on;
    try enumRow(w, c == 167, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 168, !on, red, "lo freq", freqBarVal(synth.fx_eq_low_freq), 1.0,
        try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.fx_eq_low_freq}));
    try barRow(w, c == 169, !on, red, "lo gain", synth.fx_eq_low_gain_db + 18.0, 36.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_eq_low_gain_db}));
    try barRow(w, c == 170, !on, red, "mid freq", freqBarVal(synth.fx_eq_mid_freq), 1.0,
        try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.fx_eq_mid_freq}));
    try barRow(w, c == 171, !on, red, "mid gain", synth.fx_eq_mid_gain_db + 18.0, 36.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_eq_mid_gain_db}));
    try barRow(w, c == 172, !on, red, "mid Q", synth.fx_eq_mid_q, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_eq_mid_q}));
    try barRow(w, c == 173, !on, red, "hi freq", freqBarVal(synth.fx_eq_high_freq), 1.0,
        try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.fx_eq_high_freq}));
    try barRow(w, c == 174, !on, red, "hi gain", synth.fx_eq_high_gain_db + 18.0, 36.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_eq_high_gain_db}));
}

fn secFxChorus(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX CHOR", red);

    const on = synth.fx_chorus_on;
    try enumRow(w, c == 176, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 177, !on, red, "rate", synth.fx_chorus_rate_hz, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.fx_chorus_rate_hz}));
    try barRow(w, c == 178, !on, red, "depth", synth.fx_chorus_depth_ms, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ms", .{synth.fx_chorus_depth_ms}));
    try barRow(w, c == 179, !on, red, "mix", synth.fx_chorus_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_chorus_mix}));
}

fn secFxFreqShift(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX FRQS", red);

    const on = synth.fx_freq_shift_on;
    try enumRow(w, c == 181, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 182, !on, red, "shift", synth.fx_freq_shift_hz + 2000.0, 4000.0,
        try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.fx_freq_shift_hz}));
    try barRow(w, c == 183, !on, red, "mix", synth.fx_freq_shift_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_freq_shift_mix}));
}

fn secFxDist(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX DIST", red);

    const on = synth.fx_dist_on;
    try enumRow(w, c == 83, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 84, !on, red, "drive", synth.fx_dist_drive_db, 36.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_dist_drive_db}));
    try barRow(w, c == 85, !on, red, "mix", synth.fx_dist_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_dist_mix}));
}

fn secFxCrush(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX CRUSH", red);

    const on = synth.fx_crush_on;
    try enumRow(w, c == 86, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 87, !on, red, "bits", synth.fx_crush_bits, 16.0,
        try std.fmt.bufPrint(&buf, "{d:.0}", .{synth.fx_crush_bits}));
    try barRow(w, c == 88, !on, red, "rate", synth.fx_crush_rate, 64.0,
        try std.fmt.bufPrint(&buf, "1/{d:.0}", .{synth.fx_crush_rate}));
    try barRow(w, c == 89, !on, red, "mix", synth.fx_crush_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_crush_mix}));
}

fn secFxFlanger(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX FLNG", red);

    const on = synth.fx_flanger_on;
    try enumRow(w, c == 90, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 91, !on, red, "rate", synth.fx_flanger_rate_hz, 8.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.fx_flanger_rate_hz}));
    try barRow(w, c == 92, !on, red, "depth", synth.fx_flanger_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_flanger_depth}));
    try barRow(w, c == 93, !on, red, "feedback", synth.fx_flanger_feedback, 0.95,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_flanger_feedback}));
    try barRow(w, c == 94, !on, red, "mix", synth.fx_flanger_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_flanger_mix}));
}

fn secFxTape(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX TAPE", red);

    const on = synth.fx_tape_on;
    try enumRow(w, c == 188, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 189, !on, red, "wow rate", synth.fx_tape_wow_rate_hz, 3.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.fx_tape_wow_rate_hz}));
    try barRow(w, c == 190, !on, red, "wow depth", synth.fx_tape_wow_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_tape_wow_depth}));
    try barRow(w, c == 191, !on, red, "flt rate", synth.fx_tape_flutter_rate_hz, 15.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.fx_tape_flutter_rate_hz}));
    try barRow(w, c == 192, !on, red, "flt depth", synth.fx_tape_flutter_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_tape_flutter_depth}));
    try barRow(w, c == 193, !on, red, "mix", synth.fx_tape_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_tape_mix}));
}

fn secFxPhaser(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX PHSR", red);

    const on = synth.fx_phaser_on;
    try enumRow(w, c == 103, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 104, !on, red, "rate", synth.fx_phaser_rate_hz, 8.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.fx_phaser_rate_hz}));
    try barRow(w, c == 105, !on, red, "depth", synth.fx_phaser_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_phaser_depth}));
    try barRow(w, c == 106, !on, red, "feedback", synth.fx_phaser_feedback, 0.95,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_phaser_feedback}));
    try barRow(w, c == 107, !on, red, "mix", synth.fx_phaser_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_phaser_mix}));
}

fn secFxDelay(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX DELAY", red);

    const on = synth.fx_delay_on;
    try enumRow(w, c == 108, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 109, !on, red, "time", synth.fx_delay_time_s, ws.dsp.synth.Delay.max_time_s,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fx_delay_time_s}));
    try barRow(w, c == 110, !on, red, "feedback", synth.fx_delay_feedback, 0.95,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_delay_feedback}));
    try barRow(w, c == 111, !on, red, "mix", synth.fx_delay_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_delay_mix}));
}

fn secFxReverb(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX VERB", red);

    const on = synth.fx_reverb_on;
    try enumRow(w, c == 112, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 113, !on, red, "room", synth.fx_reverb_room, 0.98,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_reverb_room}));
    try barRow(w, c == 114, !on, red, "damp", synth.fx_reverb_damp, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_reverb_damp}));
    try barRow(w, c == 115, !on, red, "mix", synth.fx_reverb_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_reverb_mix}));
}

pub fn drawSynthStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => return,
    }
    const synth = &rack.instrument.poly_synth;

    try style.writeModeBadge(w, app.modal.mode);
    try style.writeViewBadge(right, "SYNTH", app.modal.mode);
    try w.writeAll(dim ++ "  " ++ rst);
    var label_buf: [24]u8 = undefined;
    try w.writeAll(synth_ed.paramLabel(app.synth_cursor, &label_buf));
    try w.writeAll(dim ++ ": " ++ rst);
    try w.writeAll(acc);
    switch (app.synth_cursor) {
        0 => try w.writeAll(switch (synth.waveform) {
            .sine => "sine",
            .saw => "saw",
            .triangle => "tri",
            .square => "sqr",
            .wavetable => "wt",
        }),
        1 => try w.print("{d:.2}", .{synth.pulse_width}),
        2 => try w.print("{d:.0} ct", .{synth.detune_cents}),
        3 => try w.print("{d}", .{synth.unison}),
        4 => try w.print("{d:.1} ct", .{synth.unison_detune}),
        5 => try w.print("{d:.2}", .{synth.unison_spread}),
        6 => try w.writeAll(if (synth.osc_b_on) "on" else "off"),
        7 => try w.writeAll(switch (synth.osc_b_waveform) {
            .sine => "sine",
            .saw => "saw",
            .triangle => "tri",
            .square => "sqr",
            .wavetable => "wt",
        }),
        8 => try w.print("{d:.2}", .{synth.osc_b_pulse_width}),
        9 => try w.print("{d:.0} st", .{synth.osc_b_semi}),
        10 => try w.print("{d:.0} ct", .{synth.osc_b_detune_cents}),
        11 => try w.print("{d:.2}", .{synth.osc_b_level}),
        12 => try w.print("{d}", .{synth.osc_b_unison}),
        13 => try w.print("{d:.1} ct", .{synth.osc_b_unison_detune}),
        14 => try w.writeAll(switch (synth.mod_mode) {
            .none => "off",
            .ring => "ring",
            .am_a_to_b => "AM A\u{2192}B",
            .am_b_to_a => "AM B\u{2192}A",
            .fm_a_to_b => "FM A\u{2192}B",
            .fm_b_to_a => "FM B\u{2192}A",
        }),
        15 => switch (synth.mod_mode) {
            .fm_a_to_b, .fm_b_to_a => try w.print("\u{03b2}={d:.2}", .{synth.mod_amount}),
            else => try w.print("{d:.2}", .{synth.mod_amount}),
        },
        16 => try w.print("{d:.3} s", .{synth.attack_s}),
        17 => try w.print("{d:.3} s", .{synth.decay_s}),
        18 => try w.print("{d:.3}", .{synth.sustain}),
        19 => try w.print("{d:.3} s", .{synth.release_s}),
        20 => try w.writeAll(filterTypeName(synth.filter_type)),
        21 => if (synth.filter_cutoff >= 1_000.0)
            try w.print("{d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try w.print("{d:.0} Hz", .{synth.filter_cutoff}),
        22 => try w.print("{d:.3}", .{synth.filter_res}),
        24 => try w.print("{d:.3} s", .{synth.fenv_attack_s}),
        25 => try w.print("{d:.3} s", .{synth.fenv_decay_s}),
        26 => try w.print("{d:.3}", .{synth.fenv_sustain}),
        27 => try w.print("{d:.3} s", .{synth.fenv_release_s}),
        28 => try w.writeAll(lfoShapeName(synth.lfo_shape)),
        29 => try w.print("{d:.2} Hz", .{synth.lfo_rate_hz}),
        32 => try w.writeAll(switch (synth.voice_mode) {
            .poly => "poly",
            .mono => "mono",
            .legato => "legato",
        }),
        33 => if (synth.glide_s == 0.0) try w.writeAll("off") else try w.print("{d:.3} s", .{synth.glide_s}),
        34 => if (synth.sub_level == 0.0) try w.writeAll("off") else try w.print("{d:.2}", .{synth.sub_level}),
        35 => try w.writeAll(switch (synth.sub_shape) {
            .sine => "sine",
            .square => "sqr",
        }),
        36 => if (synth.noise_level == 0.0) try w.writeAll("off") else try w.print("{d:.2}", .{synth.noise_level}),
        37 => try w.print("{d:.2}", .{synth.noise_color}),
        38 => try w.print("{d:.3}", .{synth.gain}),
        39 => try w.writeAll(uniModeName(synth.unison_mode)),
        40 => try w.writeAll(uniModeName(synth.osc_b_unison_mode)),
        41 => try w.writeAll(switch (synth.warp_mode) {
            .none => "none",
            .bend => "bend",
            .mirror => "mirror",
            .sync => "sync",
        }),
        42 => try w.print("{d:.2}", .{synth.warp_amount}),
        43 => try w.writeAll(switch (synth.osc_b_warp_mode) {
            .none => "none",
            .bend => "bend",
            .mirror => "mirror",
            .sync => "sync",
        }),
        44 => try w.print("{d:.2}", .{synth.osc_b_warp_amount}),
        45 => try w.writeAll(if (synth.filter2_on) "on" else "off"),
        46 => try w.writeAll(filterTypeName(synth.filter2_type)),
        47 => if (synth.filter2_cutoff >= 1_000.0)
            try w.print("{d:.2} kHz", .{synth.filter2_cutoff / 1_000.0})
        else
            try w.print("{d:.0} Hz", .{synth.filter2_cutoff}),
        48 => try w.print("{d:.3}", .{synth.filter2_res}),
        49 => try w.writeAll(switch (synth.filter_routing) {
            .series => "series",
            .parallel => "parallel",
        }),
        50 => try w.writeAll(if (synth.osc_c_on) "on" else "off"),
        51 => try w.writeAll(switch (synth.osc_c_waveform) {
            .sine => "sine",
            .saw => "saw",
            .triangle => "tri",
            .square => "sqr",
            .wavetable => "wt",
        }),
        52 => try w.print("{d:.2}", .{synth.osc_c_pulse_width}),
        53 => try w.print("{d:.0} st", .{synth.osc_c_semi}),
        54 => try w.print("{d:.0} ct", .{synth.osc_c_detune_cents}),
        55 => try w.print("{d:.2}", .{synth.osc_c_level}),
        56 => try w.print("{d}", .{synth.osc_c_unison}),
        57 => try w.print("{d:.1} ct", .{synth.osc_c_unison_detune}),
        58 => try w.writeAll(uniModeName(synth.osc_c_unison_mode)),
        59...82 => {
            const row = synth.mod_matrix[(app.synth_cursor - 59) / 3];
            switch ((app.synth_cursor - 59) % 3) {
                // zig fmt: off
                0 => try w.writeAll(mod_src_names[modSrcIdx(row.source)]),
                1 => try w.writeAll(ws.dsp.PolySynth.modDestLabel(row.dest)),
                2 => try w.print("{s}{d:.2}", .{ @as([]const u8, if (row.depth >= 0.0) "+" else ""), row.depth }),
                // zig fmt: on
                else => {},
            }
        },
        // zig fmt: off
        83 => try w.writeAll(if (synth.fx_dist_on) "on" else "off"),
        84 => try w.print("{d:.1} dB",    .{synth.fx_dist_drive_db}),
        85 => try w.print("{d:.2}",       .{synth.fx_dist_mix}),
        86 => try w.writeAll(if (synth.fx_crush_on) "on" else "off"),
        87 => try w.print("{d:.0}",       .{synth.fx_crush_bits}),
        88 => try w.print("1/{d:.0}",     .{synth.fx_crush_rate}),
        89 => try w.print("{d:.2}",       .{synth.fx_crush_mix}),
        90 => try w.writeAll(if (synth.fx_flanger_on) "on" else "off"),
        91 => try w.print("{d:.2} Hz",    .{synth.fx_flanger_rate_hz}),
        92 => try w.print("{d:.2}",       .{synth.fx_flanger_depth}),
        93 => try w.print("{d:.2}",       .{synth.fx_flanger_feedback}),
        94 => try w.print("{d:.2}",       .{synth.fx_flanger_mix}),
        95 => try w.writeAll(lfoShapeName(synth.lfo2_shape)),
        96 => try w.print("{d:.2} Hz",    .{synth.lfo2_rate_hz}),
        97 => try w.writeAll(lfoShapeName(synth.lfo3_shape)),
        98 => try w.print("{d:.2} Hz",    .{synth.lfo3_rate_hz}),
        99  => try w.print("{d:.2}",      .{synth.macro1}),
        100 => try w.print("{d:.2}",      .{synth.macro2}),
        101 => try w.print("{d:.2}",      .{synth.macro3}),
        102 => try w.print("{d:.2}",      .{synth.macro4}),
        103 => try w.writeAll(if (synth.fx_phaser_on) "on" else "off"),
        104 => try w.print("{d:.2} Hz",    .{synth.fx_phaser_rate_hz}),
        105 => try w.print("{d:.2}",       .{synth.fx_phaser_depth}),
        106 => try w.print("{d:.2}",       .{synth.fx_phaser_feedback}),
        107 => try w.print("{d:.2}",       .{synth.fx_phaser_mix}),
        108 => try w.writeAll(if (synth.fx_delay_on) "on" else "off"),
        109 => try w.print("{d:.3} s",     .{synth.fx_delay_time_s}),
        110 => try w.print("{d:.2}",       .{synth.fx_delay_feedback}),
        111 => try w.print("{d:.2}",       .{synth.fx_delay_mix}),
        112 => try w.writeAll(if (synth.fx_reverb_on) "on" else "off"),
        113 => try w.print("{d:.2}",       .{synth.fx_reverb_room}),
        114 => try w.print("{d:.2}",       .{synth.fx_reverb_damp}),
        115 => try w.print("{d:.2}",       .{synth.fx_reverb_mix}),
        116 => try w.writeAll(if (synth.arp_on) "on" else "off"),
        117 => try w.writeAll(arpModeName(synth.arp_mode)),
        118 => try w.print("{d}",          .{synth.arp_octaves}),
        119 => try w.print("{d:.1} Hz",    .{synth.arp_rate_hz}),
        120 => try w.print("{d:.2}",       .{synth.arp_gate}),
        121 => try w.writeAll(if (synth.arp_hold) "on" else "off"),
        122 => try w.print("{d:.3} s",     .{synth.env3_attack_s}),
        123 => try w.print("{d:.3} s",     .{synth.env3_decay_s}),
        124 => try w.print("{d:.3}",       .{synth.env3_sustain}),
        125 => try w.print("{d:.3} s",     .{synth.env3_release_s}),
        132 => try w.writeAll(if (synth.fx_gate_on) "on" else "off"),
        133 => try w.print("{d:.0} dB",    .{synth.fx_gate_threshold_db}),
        134 => try w.print("{d:.1} ms",    .{synth.fx_gate_attack_ms}),
        135 => try w.print("{d:.0} ms",    .{synth.fx_gate_release_ms}),
        137 => try w.writeAll(if (synth.fx_comp_on) "on" else "off"),
        138 => try w.print("{d:.0} dB",    .{synth.fx_comp_threshold_db}),
        139 => try w.print("{d:.1}:1",     .{synth.fx_comp_ratio}),
        140 => try w.print("{d:.1} ms",    .{synth.fx_comp_attack_ms}),
        141 => try w.print("{d:.0} ms",    .{synth.fx_comp_release_ms}),
        142 => try w.print("{d:.1} dB",    .{synth.fx_comp_makeup_db}),
        144 => try w.writeAll(if (synth.fx_mb_on) "on" else "off"),
        145 => try w.print("{d:.0} Hz",    .{synth.fx_mb_xover_lo}),
        146 => try w.print("{d:.0} Hz",    .{synth.fx_mb_xover_hi}),
        147 => try w.print("{d:.1} ms",    .{synth.fx_mb_attack_ms}),
        148 => try w.print("{d:.0} ms",    .{synth.fx_mb_release_ms}),
        149 => try w.writeAll(if (synth.fx_mb_style == .ott) "OTT" else "classic"),
        150 => try w.print("{d:.2}",       .{synth.fx_mb_mix}),
        151 => try w.print("{d:.0} dB",    .{synth.fx_mb_low_threshold_db}),
        152 => try w.print("{d:.1}:1",     .{synth.fx_mb_low_ratio}),
        153 => try w.print("{d:.1} dB",    .{synth.fx_mb_low_makeup_db}),
        154 => try w.print("{d:.0} dB",    .{synth.fx_mb_mid_threshold_db}),
        155 => try w.print("{d:.1}:1",     .{synth.fx_mb_mid_ratio}),
        156 => try w.print("{d:.1} dB",    .{synth.fx_mb_mid_makeup_db}),
        157 => try w.print("{d:.0} dB",    .{synth.fx_mb_high_threshold_db}),
        158 => try w.print("{d:.1}:1",     .{synth.fx_mb_high_ratio}),
        159 => try w.print("{d:.1} dB",    .{synth.fx_mb_high_makeup_db}),
        161 => try w.writeAll(if (synth.fx_ott_on) "on" else "off"),
        162 => try w.print("{d:.2}",       .{synth.fx_ott_depth}),
        163 => try w.print("{d:.2}x",      .{synth.fx_ott_time}),
        164 => try w.print("{d:.1} dB",    .{synth.fx_ott_gain_in_db}),
        165 => try w.print("{d:.1} dB",    .{synth.fx_ott_gain_out_db}),
        167 => try w.writeAll(if (synth.fx_eq_on) "on" else "off"),
        168 => try w.print("{d:.0} Hz",    .{synth.fx_eq_low_freq}),
        169 => try w.print("{d:.1} dB",    .{synth.fx_eq_low_gain_db}),
        170 => try w.print("{d:.0} Hz",    .{synth.fx_eq_mid_freq}),
        171 => try w.print("{d:.1} dB",    .{synth.fx_eq_mid_gain_db}),
        172 => try w.print("{d:.2}",       .{synth.fx_eq_mid_q}),
        173 => try w.print("{d:.0} Hz",    .{synth.fx_eq_high_freq}),
        174 => try w.print("{d:.1} dB",    .{synth.fx_eq_high_gain_db}),
        176 => try w.writeAll(if (synth.fx_chorus_on) "on" else "off"),
        177 => try w.print("{d:.2} Hz",    .{synth.fx_chorus_rate_hz}),
        178 => try w.print("{d:.1} ms",    .{synth.fx_chorus_depth_ms}),
        179 => try w.print("{d:.2}",       .{synth.fx_chorus_mix}),
        181 => try w.writeAll(if (synth.fx_freq_shift_on) "on" else "off"),
        182 => try w.print("{d:.0} Hz",    .{synth.fx_freq_shift_hz}),
        183 => try w.print("{d:.2}",       .{synth.fx_freq_shift_mix}),
        185 => try w.print("{d:.2}",       .{synth.wt_pos}),
        186 => try w.print("{d:.2}",       .{synth.osc_b_wt_pos}),
        187 => try w.print("{d:.2}",       .{synth.osc_c_wt_pos}),
        188 => try w.writeAll(if (synth.fx_tape_on) "on" else "off"),
        189 => try w.print("{d:.2} Hz",    .{synth.fx_tape_wow_rate_hz}),
        190 => try w.print("{d:.2}",       .{synth.fx_tape_wow_depth}),
        191 => try w.print("{d:.2} Hz",    .{synth.fx_tape_flutter_rate_hz}),
        192 => try w.print("{d:.2}",       .{synth.fx_tape_flutter_depth}),
        193 => try w.print("{d:.2}",       .{synth.fx_tape_mix}),
        // zig fmt: on
        else => {},
    }
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

// zig fmt: on

//! Synth editor: title strip, MAIN/MOD/FX tab strip, and the
//! comptime-table-driven parameter sections drawn as a grid of module
//! cards - each card a display (waveform, LFO shape, envelope, filter pad)
//! over a wrapped grid of knob and stepper cells, laid out band by band
//! from synth_layout's placements.

const std = @import("std");
const ws = @import("wstudio");
const synth_ed = @import("../../ui/editors/synth.zig");
const synth_layout = @import("../../ui/synth_layout.zig");
const gui_style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const theme = &gui_style.palette;

pub fn draw(app: anytype) void {
    const track = app.core.synth_track;
    if (track >= app.core.session.racks.items.len) return;
    const synth = switch (app.core.session.racks.items[track].instrument) {
        .poly_synth => |*s| s,
        else => {
            zgui.textDisabled("Select a Synth track.", .{});
            return;
        },
    };
    drawTabs(app);
    zgui.spacing();
    switch (app.core.synth_subview) {
        .main => drawSections(app, synth, &synth_layout.main_sections, synth_layout.mainPlacements, "synth-main"),
        .mod => drawSections(app, synth, &synth_layout.mod_sections, synth_layout.modPlacements, "synth-mod"),
    }
}

/// The editor's one title row: subview tabs, then the track name, then the
/// section-focus badge - the same line, in the same order, that the TUI's
/// `drawSynthTitle` emits. There was a 44px card above this printing
/// "POLYPHONIC SYNTH" over the track name, which said nothing the chrome
/// breadcrumb and this row did not already say, and had no TUI counterpart
/// at all.
fn drawTabs(app: anytype) void {
    for (synth_ed.subviews, 0..) |tab, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 5 });
        const active = app.core.synth_subview == tab.subview;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) theme.focus else theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else theme.fg2 });
        if (zgui.button(tab.label, .{ .w = 125, .h = 30 })) setSubview(app, tab.subview);
        zgui.popStyleColor(.{ .count = 2 });
    }
    const track = app.core.synth_track;
    if (track < app.core.session.project.tracks.items.len) {
        zgui.sameLine(.{ .spacing = 14 });
        zgui.textColored(theme.focus, "\"{s}\"", .{app.core.session.project.tracks.items[track].name});
    }
    if (app.core.synth_section_focus) {
        zgui.sameLine(.{ .spacing = 12 });
        zgui.textColored(theme.audio, "FOCUS", .{});
    }
}

fn setSubview(app: anytype, subview: synth_ed.Subview) void {
    app.core.synth_subview = subview;
    var candidates_buf: [synth_ed.max_search_candidates]synth_ed.SearchCandidate = undefined;
    for (synth_ed.searchCandidates(&candidates_buf)) |candidate| {
        if (candidate.subview == subview) {
            app.core.synth_cursor = candidate.id;
            break;
        }
    }
}

/// Wraps a run of `widgets.knobCell`s into rows that fit the card, the way
/// a synth panel packs a module's knobs into a block instead of a list.
/// Controls that need the full card width (an ADSR plot, a filter pad, a
/// named stepper) call `brk` first so they start on their own line.
const Flow = struct {
    const gap: f32 = 6;

    cell_w: f32,
    avail: f32,
    used: f32 = 0,

    fn init() Flow {
        return .{ .cell_w = widgets.knobCellW(), .avail = zgui.getContentRegionAvail()[0] };
    }

    fn cell(self: *Flow) void {
        const step = self.cell_w + gap;
        if (self.used > 0 and self.used + step <= self.avail) {
            zgui.sameLine(.{ .spacing = gap });
        } else {
            self.used = 0;
        }
        self.used += step;
    }

    fn brk(self: *Flow) void {
        self.used = 0;
    }
};

fn drawSections(
    app: anytype,
    synth: *ws.dsp.PolySynth,
    comptime sections: []const synth_layout.SectionDef,
    comptime placementsFor: fn (usize) []const synth_layout.Placement,
    comptime child_prefix: []const u8,
) void {
    const gap: f32 = 12;
    const available_width = zgui.getContentRegionAvail()[0];
    const columns: usize = if (available_width >= 1500) 4 else if (available_width >= 1080) 3 else if (available_width >= 650) 2 else 1;
    // Keeps j/k/{/}/g/G in sync with the column grid actually on screen -
    // synth_layout.numCols buckets the same way from a terminal-width
    // number, so this just maps GUI's own column count onto that bucketing
    // (see App.last_cols's doc comment: it's read back by handleKey, not
    // fed a parameter, so it has to be kept current here every frame).
    app.core.last_cols = if (columns == 4) 210 else if (columns == 3) 160 else if (columns == 2) 108 else 80;
    const placements = placementsFor(columns);
    const column_w = @max(280, (available_width - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns)));

    // `z` isolates the cursor's section. The TUI has drawn only that card
    // since the key shipped; the GUI ignored the flag entirely, so `z` there
    // toggled a state with no visible effect whatsoever.
    if (app.core.synth_section_focus) {
        if (cursorSection(sections, app.core.synth_cursor)) |index| {
            drawCard(app, synth, sections[index], child_prefix, index, 0);
            return;
        }
    }

    for (0..columns) |col| {
        if (col > 0) zgui.sameLine(.{ .spacing = gap });
        zgui.beginGroup();
        for (sections, placements, 0..) |section, placement, index| {
            if (placement.col == col) drawCard(app, synth, section, child_prefix, index, column_w);
        }
        zgui.endGroup();
    }
}

/// Which section owns `cursor`, for `z`'s isolate-one-card mode.
fn cursorSection(sections: []const synth_layout.SectionDef, cursor: u16) ?usize {
    for (sections, 0..) |section, index| {
        for (section.params) |entry| {
            if (cursor >= entry.id and cursor < entry.id + entry.fields) return index;
        }
    }
    return null;
}

fn drawCard(
    app: anytype,
    synth: *ws.dsp.PolySynth,
    section: synth_layout.SectionDef,
    comptime child_prefix: []const u8,
    index: usize,
    width: f32,
) void {
    var child_buf: [48]u8 = undefined;
    const child_id = std.fmt.bufPrintZ(&child_buf, "{s}-{d}", .{ child_prefix, index }) catch return;
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = theme.bg2 });
    if (zgui.beginChild(child_id, .{
        .w = width,
        .h = 0,
        .child_flags = .{ .border = true, .auto_resize_y = true },
        .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true },
    })) {
        drawSectionCard(app, synth, section);
    }
    zgui.endChild();
    zgui.popStyleColor(.{});
}

/// A section's gate: the leading on/off param every switchable card starts
/// with (OSC B/C, FILTER 2, ARP), hoisted into the header strip.
fn sectionGate(section: synth_layout.SectionDef) ?u16 {
    if (section.params.len == 0) return null;
    const first = section.params[0].id;
    return if (ws.dsp.PolySynth.isToggleParam(first)) first else null;
}

fn drawSectionCard(app: anytype, synth: *ws.dsp.PolySynth, section: synth_layout.SectionDef) void {
    const accent = sectionColor(section.tone);
    const gate = sectionGate(section);
    if (gate) |id| {
        var gate_buf: [32]u8 = undefined;
        const gate_id = std.fmt.bufPrintZ(&gate_buf, "synth-gate-{d}", .{id}) catch "synth-gate";
        const on = (synth.paramValue(id) orelse 0) >= 0.5;
        if (widgets.sectionTitleGate(section.title, accent, .{ .id = gate_id, .on = on, .focused = app.core.synth_cursor == id })) {
            nudgeParam(app, id, 'h');
        }
    } else {
        widgets.sectionTitle(section.title, accent);
    }

    // A gated-off module still shows its settings, greyed - the same
    // "these are here but doing nothing" cue the TUI's dimmed rows give.
    const gated_off = if (gate) |id| (synth.paramValue(id) orelse 1) < 0.5 else false;
    if (gated_off) zgui.pushStyleVar1f(.{ .idx = .alpha, .v = 0.45 });
    defer if (gated_off) zgui.popStyleVar(.{});

    for (section.params) |entry| {
        if (isWaveformParam(entry.id)) drawOscDisplay(synth, entry.id, accent);
        if (lfoShapeSlot(entry.id)) |slot| drawLfoDisplay(synth, slot, accent);
    }

    var flow = Flow.init();
    for (section.params) |entry| {
        if (gate != null and entry.id == gate.?) continue;
        // A mod-matrix slot: source, dest and depth are one row, not three.
        if (entry.fields == 3) {
            flow.brk();
            drawMatrixRow(app, synth, entry.id, accent);
            continue;
        }
        // Polarity toggles are drawn as the last cell of their own matrix
        // row above, not as a standalone param.
        if (isMatrixPolarity(entry.id)) continue;
        // The ADSR plot and the filter pad are the visual cue and the mouse
        // surface - they draw above the params they cover, and then those
        // params still get their own knob cells. A knob is where an exact
        // value is read, where the keyboard cursor lands, and the one
        // control shape every other param in the card already uses.
        if (isEnvelopeBase(entry.id)) {
            flow.brk();
            drawEnvelope(app, synth, entry.id);
            flow.brk();
        }
        if (isFilterCutoff(entry.id)) {
            flow.brk();
            drawFilterPad(app, synth, entry.id);
            flow.brk();
        }
        var label_buf: [48]u8 = undefined;
        drawParam(app, synth, entry.id, synth_ed.paramLabel(entry.id, &label_buf), accent, &flow);
        if (lfoShapeSlot(entry.id)) |slot| {
            flow.brk();
            drawLfoCustomCurve(app, synth, slot);
        }
    }
    zgui.spacing();
}

// AMP ENV (16-19), FILTER ENV (24-27), and ENV 3 (122-125) each pack
// attack/decay/sustain/release at base_id+0..3 - see synth_layout.zig's
// comment on why engine param ids never move. That fixed layout is what
// lets one drawEnvelope cover all three instead of three near-identical
// knob rows.
fn isEnvelopeBase(id: u16) bool {
    return id == 16 or id == 24 or id == 122;
}

fn isFilterCutoff(id: u16) bool {
    return id == 21 or id == 47;
}

fn isMatrixPolarity(id: u16) bool {
    const base = ws.dsp.PolySynth.mod_unipolar_id_base;
    return id >= base and id < base + ws.dsp.PolySynth.max_mod_rows;
}

fn sendParam(app: anytype, id: u16, value: f32) void {
    app.recordSynthEdit();
    _ = app.core.session.engine.setTrackParam(app.core.synth_track, id, value);
    app.core.dirty = true;
}

fn drawEnvelope(app: anytype, synth: *ws.dsp.PolySynth, base_id: u16) void {
    var attack = synth.paramValue(base_id) orelse return;
    var decay = synth.paramValue(base_id + 1) orelse return;
    var sustain = synth.paramValue(base_id + 2) orelse return;
    var release = synth.paramValue(base_id + 3) orelse return;
    const a_range = (ws.dsp.PolySynth.findAutomatableParam(base_id) orelse return).range;
    const d_range = (ws.dsp.PolySynth.findAutomatableParam(base_id + 1) orelse return).range;
    const r_range = (ws.dsp.PolySynth.findAutomatableParam(base_id + 3) orelse return).range;

    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "adsr##gui-synth-{d}", .{base_id}) catch return;
    const cursor = app.core.synth_cursor;
    const focused_stage: ?u2 = if (cursor == base_id) 0 else if (cursor == base_id + 1 or cursor == base_id + 2) 1 else if (cursor == base_id + 3) 2 else null;

    const result = widgets.adsrEditor(label, .{
        .attack = &attack,
        .decay = &decay,
        .sustain = &sustain,
        .release = &release,
        .attack_range = a_range,
        .decay_range = d_range,
        .release_range = r_range,
        .accent = theme.rhythm,
        .focused_stage = focused_stage,
    });
    if (result.changed[0]) sendParam(app, base_id, attack);
    if (result.changed[1]) sendParam(app, base_id + 1, decay);
    if (result.changed[2]) sendParam(app, base_id + 2, sustain);
    if (result.changed[3]) sendParam(app, base_id + 3, release);
    if (result.activated_stage) |stage| app.core.synth_cursor = switch (stage) {
        0 => base_id,
        1 => base_id + 1,
        else => base_id + 3,
    };
    zgui.textDisabled("A {d:.3}s  D {d:.3}s  S {d:.2}  R {d:.3}s", .{ attack, decay, sustain, release });
}

fn drawFilterPad(app: anytype, synth: *ws.dsp.PolySynth, cutoff_id: u16) void {
    const res_id = cutoff_id + 1;
    var cutoff = synth.paramValue(cutoff_id) orelse return;
    var res = synth.paramValue(res_id) orelse return;
    const c_range = (ws.dsp.PolySynth.findAutomatableParam(cutoff_id) orelse return).range;
    const r_range = (ws.dsp.PolySynth.findAutomatableParam(res_id) orelse return).range;

    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "xy##gui-synth-{d}", .{cutoff_id}) catch return;
    const focused = app.core.synth_cursor == cutoff_id or app.core.synth_cursor == res_id;

    zgui.textDisabled("cutoff / res", .{});
    const result = widgets.xyPad(label, .{
        .width = zgui.getContentRegionAvail()[0],
        .size = 104,
        .x = &cutoff,
        .y = &res,
        .x_range = c_range,
        .y_range = r_range,
        .x_cfmt = "%.0f Hz",
        .y_cfmt = "%.2f",
        .x_logarithmic = true,
        .accent = theme.audio,
        .focused = focused,
    });
    if (result.changed) {
        sendParam(app, cutoff_id, cutoff);
        sendParam(app, res_id, res);
    }
    if (result.activated) app.core.synth_cursor = cutoff_id;
}

/// Which `.custom` LFO slot (0/1/2) a MOD section's "shape" entry drives -
/// see `dsp.synth.lfo_custom_id_base`'s id-layout doc comment. `null` for
/// every other id (rate, matrix rows, ...), so the extra draw call below is
/// a no-op for them.
fn lfoShapeSlot(id: u16) ?usize {
    return switch (id) {
        28 => 0,
        95 => 1,
        97 => 2,
        else => null,
    };
}

/// `.custom` LFO shape's breakpoint editor - drawn right under that LFO's
/// shape/rate rows, only while the shape is actually set to `.custom`
/// (picking any other shape via the +/- cycle above just hides it again).
/// Reuses widgets.curveEditor exactly like the automation view does (see
/// that view's own drawCurve for the fuller-chrome version); this one skips
/// the bar-ruler/axis-label chrome since a single LFO cycle doesn't need
/// them, just the plot.
fn drawLfoCustomCurve(app: anytype, synth: *ws.dsp.PolySynth, slot: usize) void {
    const shape = switch (slot) {
        0 => synth.lfo_shape,
        1 => synth.lfo2_shape,
        else => synth.lfo3_shape,
    };
    if (shape != .custom) return;

    const count = synth.lfo_custom_count[slot];
    var curve_buf: [ws.dsp.synth.max_lfo_shape_points]widgets.CurvePoint = undefined;
    for (synth.lfo_custom[slot][0..count], curve_buf[0..count]) |src, *dst| {
        dst.* = .{ .beat = src.phase, .value = src.value };
    }

    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "lfo-custom##gui-synth-{d}", .{slot}) catch return;
    const base: u16 = ws.dsp.synth.lfo_custom_id_base + @as(u16, @intCast(slot)) * ws.dsp.synth.lfo_custom_ids_per_slot;
    const base_usize: usize = base;
    const count_id: u16 = base + ws.dsp.synth.max_lfo_shape_points * 2;
    const focused_index: ?usize = if (app.core.synth_cursor >= base and app.core.synth_cursor < count_id)
        (app.core.synth_cursor - base) / 2
    else
        null;

    const result = widgets.curveEditor(label, .{
        .points = curve_buf[0..count],
        .beat_hi = 1.0,
        .value_lo = -1.0,
        .value_hi = 1.0,
        .snap_beats = 0,
        .accent = theme.modulation,
        .focused_index = focused_index,
        .x_unit_label = "phase",
        .height = 130,
    });

    if (result.moved) |m| {
        const phase_id: u16 = @intCast(base_usize + m.index * 2);
        sendParam(app, phase_id, @floatCast(m.beat));
        sendParam(app, phase_id + 1, m.value);
    }
    if (result.inserted) |ins| {
        if (count < ws.dsp.synth.max_lfo_shape_points) {
            var k: usize = 0;
            while (k < count and curve_buf[k].beat < ins.beat) : (k += 1) {}
            var i: usize = count;
            while (i > k) : (i -= 1) {
                const src = curve_buf[i - 1];
                const dst_phase_id: u16 = @intCast(base_usize + i * 2);
                sendParam(app, dst_phase_id, @floatCast(src.beat));
                sendParam(app, dst_phase_id + 1, src.value);
            }
            const new_phase_id: u16 = @intCast(base_usize + k * 2);
            sendParam(app, new_phase_id, @floatCast(ins.beat));
            sendParam(app, new_phase_id + 1, ins.value);
            sendParam(app, count_id, @floatFromInt(count + 1));
            app.core.synth_cursor = new_phase_id;
        }
    }
    if (result.removed) |beat| {
        var idx: ?usize = null;
        for (curve_buf[0..count], 0..) |p, i| {
            if (@abs(p.beat - beat) < 1e-6) {
                idx = i;
                break;
            }
        }
        if (idx) |ix| {
            var i: usize = ix;
            while (i + 1 < count) : (i += 1) {
                const src = curve_buf[i + 1];
                const dst_phase_id: u16 = @intCast(base_usize + i * 2);
                sendParam(app, dst_phase_id, @floatCast(src.beat));
                sendParam(app, dst_phase_id + 1, src.value);
            }
            sendParam(app, count_id, @floatFromInt(count - 1));
        }
    }
    if (result.activated_index) |i| app.core.synth_cursor = @intCast(base_usize + i * 2);
}

/// The section's palette slot, from what it does to the signal rather than
/// from where it happens to sit in the table (this hashed the section
/// *index* into an accent before, so the same card changed color whenever a
/// section was added ahead of it, and two oscillators could land on two
/// different colors).
fn sectionColor(tone: synth_layout.Tone) [4]f32 {
    return switch (tone) {
        .source => theme.focus,
        .filter => theme.audio,
        .env => theme.rhythm,
        .mod => theme.modulation,
        .util => theme.fg2,
    };
}

/// One mod-matrix slot on one line - slot number, source, destination,
/// depth - instead of three stacked `source`/`dest`/`depth` rows. Every
/// synth's matrix is a table, and for good reason: the routing only means
/// anything read across, and 8 slots stacked three-deep is 24 rows of
/// column-0 real estate.
fn drawMatrixRow(app: anytype, synth: *ws.dsp.PolySynth, base_id: u16, accent: [4]f32) void {
    const slot = (ws.dsp.PolySynth.matrixParamAddr(base_id) orelse return).row;
    if (slot >= synth.mod_matrix.len) return;
    const row = synth.mod_matrix[slot];
    const on = row.source != .none;
    const unit = zgui.getFontSize();
    const start_x = zgui.getCursorPos()[0];
    const src_x = start_x + unit * 1.7;
    const dest_x = src_x + unit * 8.6;
    const depth_x = dest_x + unit * 12.4;

    zgui.textColored(if (on) theme.fg2 else theme.fg3, "{d}", .{slot + 1});
    zgui.sameLine(.{ .spacing = 0 });
    zgui.setCursorPosX(src_x);
    drawSlotStepper(app, base_id, synth_layout.modSourceName(row.source), unit * 7.6, accent);
    zgui.sameLine(.{ .spacing = 0 });
    zgui.setCursorPosX(dest_x);
    drawSlotStepper(app, base_id + 1, ws.dsp.PolySynth.modDestLabel(row.dest), unit * 11.4, accent);
    zgui.sameLine(.{ .spacing = 0 });
    zgui.setCursorPosX(depth_x);

    const depth_id = base_id + 2;
    const param = ws.dsp.PolySynth.findAutomatableParam(depth_id) orelse return;
    var depth = row.depth;
    var id_buf: [32]u8 = undefined;
    const widget_id = std.fmt.bufPrintZ(&id_buf, "##synth-depth-{d}", .{depth_id}) catch return;
    const result = widgets.knob(widget_id, .{
        .v = &depth,
        .min = param.range[0],
        .max = param.range[1],
        .cfmt = "%.2f",
        .accent = if (on) accent else theme.fg3,
        .focused = app.core.synth_cursor == depth_id,
        .diameter = 20,
    });
    if (result.changed) sendParam(app, depth_id, depth);
    if (result.activated) app.core.synth_cursor = depth_id;
    zgui.sameLine(.{ .spacing = 6 });
    const sign: []const u8 = if (row.depth >= 0.0) "+" else "";
    zgui.textColored(if (on) theme.fg2 else theme.fg3, "{s}{d:.2}", .{ sign, row.depth });

    // Polarity: a stepper, not a knob - it's a two-state list param.
    zgui.sameLine(.{ .spacing = 8 });
    const pol_id: u16 = @intCast(ws.dsp.PolySynth.mod_unipolar_id_base + slot);
    drawSlotStepper(app, pol_id, if (row.unipolar) "uni" else "bi", unit * 3.4, if (on and row.source.isBipolar()) accent else theme.fg3);
}

/// A matrix slot's source or destination: the same boxed stepper the param
/// grid uses, at an explicit width so the column lines up however wide the
/// names in it happen to render, and with no caption (the slot number and
/// the column position already say which field this is).
fn drawSlotStepper(app: anytype, id: u16, display: []const u8, width: f32, accent: [4]f32) void {
    var id_buf: [40]u8 = undefined;
    const widget_id = std.fmt.bufPrintZ(&id_buf, "##synth-slot-{d}", .{id}) catch return;
    switch (widgets.stepperCell("", widget_id, display, accent, app.core.synth_cursor == id, width)) {
        -1 => nudgeParam(app, id, 'h'),
        1 => nudgeParam(app, id, 'l'),
        else => {},
    }
}

/// Draws whichever control `id` deserves: a knob cell for a continuous
/// quantity (they flow into a grid), a waveform picker, an on/off button,
/// or a named stepper for a list-valued param. The value text is always
/// `synth_ed.paramValueText`'s - the same unit-aware string the status line
/// prints, so a filter type reads "ladder" and a cutoff reads "1.20 kHz"
/// rather than a raw float.
fn drawParam(app: anytype, synth: *ws.dsp.PolySynth, id: u16, label_text: []const u8, accent: [4]f32, flow: *Flow) void {
    const value = synth.paramValue(id) orelse return;
    var value_buf: [40]u8 = undefined;
    const value_text = synth_ed.paramValueText(synth, id, &value_buf);
    const focused = app.core.synth_cursor == id;

    if (ws.dsp.PolySynth.findAutomatableParam(id)) |param| {
        flow.cell();
        var edited = value;
        var id_buf: [40]u8 = undefined;
        const widget_id = std.fmt.bufPrintZ(&id_buf, "##gui-synth-{d}", .{id}) catch return;
        const result = widgets.knobCell(label_text, widget_id, value_text, .{
            .v = &edited,
            .min = param.range[0],
            .max = param.range[1],
            .cfmt = "%.3f",
            .accent = accent,
            .focused = focused,
            .diameter = 28,
            .logarithmic = logarithmicParam(id),
            .skew = if (zeroSkewParam(id)) 3 else 1,
        });
        if (result.changed) sendParam(app, id, edited);
        if (result.activated) app.core.synth_cursor = id;
        return;
    }

    if (ws.dsp.PolySynth.isToggleParam(id)) {
        flow.brk();
        drawParamToggle(app, id, label_text, value >= 0.5, accent);
        return;
    }
    if (isWaveformParam(id)) {
        flow.brk();
        drawWaveformParam(app, id, label_text, value, accent);
        return;
    }
    // Everything else is a list-valued param, and it flows in the same grid
    // as the knobs rather than breaking the row for a full-width stepper.
    flow.cell();
    var id_buf: [40]u8 = undefined;
    const widget_id = std.fmt.bufPrintZ(&id_buf, "##gui-synth-step-{d}", .{id}) catch return;
    switch (widgets.stepperCell(label_text, widget_id, value_text, accent, focused, 0)) {
        -1 => nudgeParam(app, id, 'h'),
        1 => nudgeParam(app, id, 'l'),
        else => {},
    }
}

/// Parameters spanning orders of magnitude need equal knob travel per ratio,
/// not per raw unit. Stored values and automation stay in their plain units.
fn logarithmicParam(id: u16) bool {
    return switch (id) {
        16, 17, 19, 21, 24, 25, 27, 29, 47, 91, 96, 98, 104, 109, 119, 122, 123, 125, 134, 135, 140, 141, 145, 146, 147, 148, 168, 170, 172, 173, 177, 189, 191 => true,
        else => false,
    };
}

/// Zero is a meaningful off/instant value, so true logarithmic mapping cannot
/// represent it. Cubic travel keeps that endpoint and expands useful low time.
fn zeroSkewParam(id: u16) bool {
    return id == 33 or id == 265 or id == 266 or id == 267;
}

/// A boolean param rendered as a single on/off button - `nudgeParam`'s
/// h-step flips a toggle just like it would any other stepped value, so
/// clicking it reuses the same command path an `h`/`l` keypress would.
fn drawParamToggle(app: anytype, id: u16, label_text: []const u8, active: bool, accent: [4]f32) void {
    const focused = app.core.synth_cursor == id;
    zgui.textColored(if (focused) accent else theme.fg1, "{s}", .{label_text});
    zgui.sameLine(.{ .spacing = 8 });
    var btn_buf: [48]u8 = undefined;
    const btn_id = std.fmt.bufPrintZ(&btn_buf, "{s}##synth-toggle-{d}", .{ if (active) "ON" else "OFF", id }) catch return;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) accent else if (focused) theme.bg4 else theme.bg3 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else if (focused) accent else theme.fg2 });
    if (zgui.smallButton(btn_id)) nudgeParam(app, id, 'h');
    zgui.popStyleColor(.{ .count = 2 });
}

/// OSC A/B/C's waveform param ids - the only `param_specs` cycle rows with
/// an obvious icon per option, so `widgets.waveformPicker` covers just
/// these three rather than every enum-valued param (filter type, LFO
/// shape, ... still fall through to the generic -/+ stepper below).
fn isWaveformParam(id: u16) bool {
    return id == 0 or id == 7 or id == 51;
}

fn drawWaveformParam(app: anytype, id: u16, label_text: []const u8, value: f32, accent: [4]f32) void {
    _ = label_text;
    const focused = app.core.synth_cursor == id;
    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "##synth-wave-{d}", .{id}) catch return;
    const current = ws.dsp.synth.enumFromValue(ws.dsp.synth.Waveform, value);
    if (widgets.waveformPicker(label, current, accent, focused)) |picked| {
        app.core.synth_cursor = id;
        sendParam(app, id, ws.dsp.synth.enumToValue(picked));
    }
}

fn nudgeParam(app: anytype, id: u16, key: u8) void {
    app.core.synth_cursor = id;
    app.core.handleKey(.{ .char = key }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
}

/// The oscillator's own waveform display, at the top of its own card, drawn
/// from that oscillator's waveform and pulse width. Three cards, three
/// displays, each showing what that oscillator is actually doing - the
/// arrangement Serum, Vital and Massive all use, and what a single sketch
/// in a global header cannot express.
fn drawOscDisplay(synth: *const ws.dsp.PolySynth, waveform_id: u16, accent: [4]f32) void {
    const shape: struct { wave: ws.dsp.synth.Waveform, pw: f32 } = switch (waveform_id) {
        0 => .{ .wave = synth.waveform, .pw = synth.pulse_width },
        7 => .{ .wave = synth.osc_b_waveform, .pw = synth.osc_b_pulse_width },
        else => .{ .wave = synth.osc_c_waveform, .pw = synth.osc_c_pulse_width },
    };
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 42;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("##osc-display", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg1), .rounding = gui_style.panel_rounding });
    const mid = origin[1] + height * 0.5;
    draw_list.addLine(.{ .p1 = .{ origin[0], mid }, .p2 = .{ origin[0] + width, mid }, .col = color(theme.bg4), .thickness = 1 });
    drawOscillatorShape(draw_list, .{ origin[0] + 8, origin[1] + 5 }, .{ width - 16, height - 10 }, shape.wave, shape.pw, accent);
    zgui.dummy(.{ .w = 0, .h = 4 });
}

/// One cycle of the LFO's shape, at the top of its own card - the LFO
/// counterpart to `drawOscDisplay`, and the same reason Serum gives each
/// LFO a curve panel: "sine" versus "s&h" is a picture, not a word. Skipped
/// for `.custom`, which already draws its real breakpoint editor below
/// (see `drawLfoCustomCurve`).
fn drawLfoDisplay(synth: *const ws.dsp.PolySynth, slot: usize, accent: [4]f32) void {
    const shape = switch (slot) {
        0 => synth.lfo_shape,
        1 => synth.lfo2_shape,
        else => synth.lfo3_shape,
    };
    if (shape == .custom) return;

    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 56;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("##lfo-display", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg1), .rounding = gui_style.panel_rounding });
    const mid = origin[1] + height * 0.5;
    draw_list.addLine(.{ .p1 = .{ origin[0], mid }, .p2 = .{ origin[0] + width, mid }, .col = color(theme.bg4), .thickness = 1 });

    const steps = 96;
    const plot_x = origin[0] + 8;
    const plot_w = width - 16;
    var prev: [2]f32 = .{ plot_x, mid };
    for (0..steps + 1) |i| {
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, steps);
        const sample: f32 = switch (shape) {
            .sine => @sin(phase * std.math.pi * 2.0),
            .triangle => 1.0 - 4.0 * @abs(phase - 0.5) + 1.0 - 1.0,
            .saw => 1.0 - phase * 2.0,
            .square => if (phase < 0.5) 1.0 else -1.0,
            // Deterministic stand-ins: a real sample-and-hold or chaos run
            // would flicker every frame and read as noise, not as shape.
            .sh => switch (@as(usize, @intFromFloat(phase * 8.0)) % 8) {
                0 => 0.6,
                1 => -0.3,
                2 => 0.9,
                3 => 0.1,
                4 => -0.8,
                5 => 0.4,
                6 => -0.5,
                else => 0.2,
            },
            .chaos => @sin(phase * 11.0) * 0.6 + @sin(phase * 27.0) * 0.35,
            .custom => 0,
        };
        const point = [2]f32{ plot_x + plot_w * phase, mid - (height * 0.5 - 5) * sample };
        if (i > 0) draw_list.addLine(.{ .p1 = prev, .p2 = point, .col = color(accent), .thickness = 1.5 });
        prev = point;
    }
    zgui.dummy(.{ .w = 0, .h = 4 });
}

/// Two cycles of `waveform`, so a duty-cycle change reads as a change in
/// shape rather than only in a number.
fn drawOscillatorShape(draw_list: zgui.DrawList, pos: [2]f32, size: [2]f32, waveform: ws.dsp.synth.Waveform, pulse_width: f32, accent: [4]f32) void {
    const steps = 96;
    var prev = pos;
    for (1..steps + 1) |i| {
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, steps) * 2.0;
        const frac = phase - @floor(phase);
        const sample: f32 = switch (waveform) {
            .sine => @sin(phase * std.math.pi * 2.0),
            .saw, .wavetable => frac * 2.0 - 1.0,
            .triangle => 1.0 - 4.0 * @abs(@round(phase) - phase),
            .square => if (frac < pulse_width) 1.0 else -1.0,
        };
        const point = [2]f32{ pos[0] + size[0] * @as(f32, @floatFromInt(i)) / @as(f32, steps), pos[1] + size[1] * (0.5 - sample * 0.45) };
        if (i > 1) draw_list.addLine(.{ .p1 = prev, .p2 = point, .col = color(accent), .thickness = 1.5 });
        prev = point;
    }
}

test "cursorSection finds the section holding a param, including a multi-field row" {
    const testing = std.testing;
    // Every param the layout lists must resolve, including the interior ids of
    // a multi-field row (a matrix row is one entry covering several ids) - a
    // cursor that lands in a gap used to leave the view with no focused card.
    inline for (.{ &synth_layout.main_sections, &synth_layout.mod_sections }) |sections| {
        for (sections, 0..) |section, index| {
            for (section.params) |entry| {
                for (0..entry.fields) |offset| {
                    const id: u16 = entry.id + @as(u16, @intCast(offset));
                    try testing.expectEqual(@as(?usize, index), cursorSection(sections, id));
                }
            }
        }
    }
    // An id no section claims is null rather than an out-of-bounds index.
    try testing.expectEqual(@as(?usize, null), cursorSection(&synth_layout.main_sections, 60_000));
}

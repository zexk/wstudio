//! Synth editor parameter sections drawn as a grid of module
//! cards - each card a display (waveform, LFO shape, envelope)
//! over a wrapped grid of knob and stepper cells, laid out band by band
//! from synth_layout's placements.

const std = @import("std");
const ws = @import("wstudio");
const synth_ed = @import("../../ui/editors/synth.zig");
const synth_layout = @import("../../ui/synth_layout.zig");
const gui_style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const scroll = @import("../scroll.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const theme = &gui_style.palette;

pub fn draw(app: anytype) void {
    const track = app.core.synth_track;
    if (track >= app.core.session.racks.items.len) return;
    const synth = switch (app.core.session.racks.items[track].instrument) {
        .poly_synth => |*s| s,
        else => {
            zgui.textDisabled("Select a synth track", .{});
            return;
        },
    };
    switch (app.core.synth_subview) {
        .main => drawMain(app, synth),
        .mod => drawSections(app, synth, &synth_layout.mod_sections, synth_layout.modPlacements, "synth-mod"),
    }
}

/// The sections making up one tab group, read off the layout table - the
/// index runs (1..4, 6..9, ...) used to be spelled out at every call site
/// and had to be re-checked by hand whenever a card moved.
fn tabGroup(g: synth_layout.TabGroup) []const synth_layout.SectionDef {
    for (synth_layout.main_sections, 0..) |sec, i| {
        if (sec.tab_group != g) continue;
        const range = synth_layout.tabGroupRange(&synth_layout.main_sections, i).?;
        return synth_layout.main_sections[range.start..range.end];
    }
    unreachable;
}

/// Which card that group is showing. Shared with the TUI (App holds the
/// state), so the two frontends open on the same tab.
fn tabState(app: anytype, g: synth_layout.TabGroup) *u8 {
    return switch (g) {
        .osc => &app.core.synth_osc_tab,
        .lfo => &app.core.synth_lfo_tab,
        .filter => &app.core.synth_filter_tab,
        .env => &app.core.synth_env_tab,
        .none => unreachable,
    };
}

/// Stable ImGui child id per group.
fn tabChildId(g: synth_layout.TabGroup) [:0]const u8 {
    return switch (g) {
        .osc => "synth-osc-tabs",
        .lfo => "synth-lfo-tabs",
        .filter => "synth-filter-tabs",
        .env => "synth-env-tabs",
        .none => unreachable,
    };
}

fn drawMain(app: anytype, synth: *ws.dsp.PolySynth) void {
    const available = zgui.getContentRegionAvail();
    if (available[0] < 1080 or app.core.synth_section_focus) {
        drawSections(app, synth, &synth_layout.main_sections, synth_layout.mainPlacements, "synth-main");
        return;
    }

    synth_ed.syncTabsToCursor(&app.core);
    app.core.last_cols = 160;

    const gap: f32 = 6;
    const origin = zgui.getCursorPos();
    const utility_w: f32 = 240;
    const content_w = available[0] - utility_w - gap;
    const column_w = (content_w - gap) / 2;
    const center_x = origin[0] + utility_w + gap;
    const right_x = origin[0] + utility_w + gap + column_w + gap;

    zgui.setCursorPos(.{ center_x, origin[1] });
    drawTabbedCard(app, synth, .osc, column_w);
    const env_y = zgui.getCursorPosY();
    zgui.setCursorPos(.{ center_x, env_y });
    drawTabbedCard(app, synth, .env, column_w);
    zgui.setCursorPosX(center_x);
    drawCard(app, synth, synth_layout.main_sections[15], "synth-main", 15, column_w);
    const center_bottom = zgui.getCursorPosY();

    zgui.setCursorPos(.{ right_x, origin[1] });
    drawTabbedCard(app, synth, .filter, column_w);
    const pair_y = zgui.getCursorPosY();
    const pair_w = (column_w - gap) / 2;
    zgui.setCursorPos(.{ right_x, pair_y });
    drawCard(app, synth, synth_layout.main_sections[4], "synth-main", 4, pair_w);
    zgui.sameLine(.{ .spacing = gap });
    drawCard(app, synth, synth_layout.main_sections[5], "synth-main", 5, pair_w);
    const lfo_y = zgui.getCursorPosY();
    zgui.setCursorPos(.{ right_x, lfo_y });
    drawTabbedCardSized(app, synth, .lfo, column_w, center_bottom - lfo_y);
    const right_bottom = zgui.getCursorPosY();

    zgui.setCursorPos(origin);
    drawCard(app, synth, synth_layout.main_sections[0], "synth-main", 0, utility_w);
    drawCard(app, synth, synth_layout.main_sections[16], "synth-main", 16, utility_w);
    zgui.setCursorPosX(origin[0]);
    drawCard(app, synth, synth_layout.main_sections[14], "synth-main", 14, utility_w);
    const left_bottom = zgui.getCursorPosY();

    const composition_bottom = @max(left_bottom, @max(center_bottom, right_bottom));
    zgui.setCursorPos(.{ origin[0], composition_bottom });
    zgui.dummy(.{ .w = 0, .h = 0 });
}

/// Wraps a run of `widgets.knobCell`s into rows that fit the card, the way
/// a synth panel packs a module's knobs into a block instead of a list.
/// Controls that need the full card width (an ADSR plot or a
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
    const width_columns: usize = if (available_width >= 1500) 4 else if (available_width >= 1080) 3 else if (available_width >= 650) 2 else 1;
    const columns = @min(width_columns, sections.len);
    // Keeps j/k/{/}/g/G in sync with the column grid actually on screen -
    // synth_layout.numCols buckets the same way from a terminal-width
    // number, so this just maps GUI's own column count onto that bucketing
    // (see App.last_cols's doc comment: it's read back by handleKey, not
    // fed a parameter, so it has to be kept current here every frame).
    app.core.last_cols = if (columns == 4) 210 else if (columns == 3) 160 else if (columns == 2) 108 else 80;
    const placements = placementsFor(columns);
    const column_w = @max(280, (available_width - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns)));
    synth_ed.syncTabsToCursor(&app.core);

    // `z` isolates the cursor's section. The TUI has drawn only that card
    // since the key shipped; the GUI ignored the flag entirely, so `z` there
    // toggled a state with no visible effect whatsoever.
    if (app.core.synth_section_focus) {
        if (cursorSection(sections, app.core.synth_cursor)) |index| {
            if (sections[index].tab_group != .none)
                drawTabbedCard(app, synth, sections[index].tab_group, 0)
            else
                drawCard(app, synth, sections[index], child_prefix, index, 0);
            return;
        }
    }

    for (0..columns) |col| {
        if (col > 0) zgui.sameLine(.{ .spacing = gap });
        zgui.beginGroup();
        for (sections, placements, 0..) |section, placement, index| {
            // A tab group draws one card, at its first member's slot.
            if (synth_layout.tabGroupRange(sections, index)) |range| {
                if (index != range.start) continue;
                if (placement.col == col) drawTabbedCard(app, synth, section.tab_group, column_w);
                continue;
            }
            if (placement.col == col) drawCard(app, synth, section, child_prefix, index, column_w);
        }
        zgui.endGroup();
    }
}

fn drawTabbedCard(app: anytype, synth: *ws.dsp.PolySynth, g: synth_layout.TabGroup, width: f32) void {
    drawTabbedCardSized(app, synth, g, width, 0);
}

fn drawTabbedCardSized(app: anytype, synth: *ws.dsp.PolySynth, g: synth_layout.TabGroup, width: f32, height: f32) void {
    const sections = tabGroup(g);
    const tab = tabState(app, g);
    const child_id = tabChildId(g);
    tab.* = @min(tab.*, @as(u8, @intCast(sections.len - 1)));
    const slot = tab.*;
    const section = sections[slot];
    scroll.noteFocusRow(synth_layout.sectionHasParam(section, app.core.synth_cursor), zgui.getCursorScreenPos()[1], 0);
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = theme.bg2 });
    if (zgui.beginChild(child_id, .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = true, .auto_resize_y = height == 0 },
        .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true },
    })) {
        for (sections, 0..) |tab_section, i| {
            if (i > 0) zgui.sameLine(.{ .spacing = 5 });
            const active = i == slot;
            var label_buf: [32]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s}##{s}-{d}", .{ tab_section.title, child_id, i }) catch continue;
            zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) theme.focus else theme.bg1 });
            zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else theme.fg2 });
            if (zgui.button(label, .{})) {
                tab.* = @intCast(i);
                app.core.synth_cursor = tab_section.params[0].id;
            }
            zgui.popStyleColor(.{ .count = 2 });
        }
        zgui.separator();
        zgui.spacing();
        drawSectionBody(app, synth, section);
    }
    zgui.endChild();
    zgui.popStyleColor(.{});
}

/// Which section owns `cursor`, for `z`'s isolate-one-card mode.
fn cursorSection(sections: []const synth_layout.SectionDef, cursor: u16) ?usize {
    for (sections, 0..) |section, index| {
        if (synth_layout.sectionHasParam(section, cursor)) return index;
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
    drawCardSized(app, synth, section, child_prefix, index, width, 0);
}

fn drawCardSized(
    app: anytype,
    synth: *ws.dsp.PolySynth,
    section: synth_layout.SectionDef,
    comptime child_prefix: []const u8,
    index: usize,
    width: f32,
    height: f32,
) void {
    var child_buf: [48]u8 = undefined;
    const child_id = std.fmt.bufPrintZ(&child_buf, "{s}-{d}", .{ child_prefix, index }) catch return;
    // A card whose child lies entirely outside the scroll viewport is
    // skipped wholesale: `beginChild` returns false and nothing inside it
    // runs, the focused param's own `noteFocusRow` included - which is
    // exactly the case cursor-following exists for. Mark the card itself
    // first so `j` past the fold still has somewhere to scroll to; a card
    // that does draw overwrites this with its focused row's real band.
    scroll.noteFocusRow(synth_layout.sectionHasParam(section, app.core.synth_cursor), zgui.getCursorScreenPos()[1], 0);
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = theme.bg2 });
    if (zgui.beginChild(child_id, .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = true, .auto_resize_y = height == 0 },
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

    drawSectionBody(app, synth, section);
}

fn drawSectionBody(app: anytype, synth: *ws.dsp.PolySynth, section: synth_layout.SectionDef) void {
    const accent = sectionColor(section.tone);
    const gate = sectionGate(section);
    // A gated-off module still shows its settings, greyed - the same
    // "these are here but doing nothing" cue the TUI's dimmed rows give.
    const gated_off = if (gate) |id| (synth.paramValue(id) orelse 1) < 0.5 else false;
    if (gated_off) zgui.pushStyleVar1f(.{ .idx = .alpha, .v = 0.45 });
    defer if (gated_off) zgui.popStyleVar(.{});

    for (section.params) |entry| {
        if (isOscPositionParam(entry.id)) drawOscDisplay(synth, entry.id, accent);
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
        // The ADSR plot is the visual cue and mouse surface above the params
        // it covers. Those params still get their own knob cells.
        if (isEnvelopeBase(entry.id)) {
            flow.brk();
            drawEnvelope(app, synth, entry.id);
            flow.brk();
        }
        var label_buf: [48]u8 = undefined;
        drawParam(app, synth, entry.id, synth_ed.paramLabelFor(synth, entry.id, &label_buf), accent, &flow);
        if (lfoShapeSlot(entry.id)) |slot| {
            flow.brk();
            drawLfoCustomCurve(app, synth, slot);
        }
    }
    zgui.spacing();
}

// ENV 1 (16-19), ENV 2 (24-27), and ENV 3 (122-125) each pack
// attack/decay/sustain/release at base_id+0..3 - see synth_layout.zig's
// comment on why engine param ids never move. That fixed layout is what
// lets one drawEnvelope cover all three instead of three near-identical
// knob rows.
fn isEnvelopeBase(id: u16) bool {
    return id == 16 or id == 24 or id == 122;
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
    const curve_ids: [3]u16 = switch (base_id) {
        16 => .{ 246, 400, 401 },
        24 => .{ 247, 402, 403 },
        else => .{ 248, 404, 405 },
    };
    var curves = [3]f32{
        synth.paramValue(curve_ids[0]) orelse return,
        synth.paramValue(curve_ids[1]) orelse return,
        synth.paramValue(curve_ids[2]) orelse return,
    };
    const a_range = (ws.dsp.PolySynth.findAutomatableParam(base_id) orelse return).range;
    const d_range = (ws.dsp.PolySynth.findAutomatableParam(base_id + 1) orelse return).range;
    const r_range = (ws.dsp.PolySynth.findAutomatableParam(base_id + 3) orelse return).range;

    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "adsr##gui-synth-{d}", .{base_id}) catch return;
    const cursor = app.core.synth_cursor;
    const focused_stage: ?u2 = if (cursor >= base_id and cursor <= base_id + 3) @intCast(cursor - base_id) else null;

    const result = widgets.adsrEditor(label, .{
        .attack = &attack,
        .decay = &decay,
        .sustain = &sustain,
        .release = &release,
        .attack_range = a_range,
        .decay_range = d_range,
        .release_range = r_range,
        .curves = .{ &curves[0], &curves[1], &curves[2] },
        .accent = theme.rhythm,
        .focused_stage = focused_stage,
    });
    if (result.changed[0]) sendParam(app, base_id, attack);
    if (result.changed[1]) sendParam(app, base_id + 1, decay);
    if (result.changed[2]) sendParam(app, base_id + 2, sustain);
    if (result.changed[3]) sendParam(app, base_id + 3, release);
    for (result.curve_changed, curve_ids, curves) |changed, id, curve| if (changed) sendParam(app, id, curve);
    if (result.activated_stage) |stage| app.core.synth_cursor = switch (stage) {
        0 => base_id,
        1 => base_id + 1,
        2 => base_id + 2,
        else => base_id + 3,
    };
    zgui.textDisabled("A {d:.3}s  D {d:.3}s  S {d:.2}  R {d:.3}s", .{ attack, decay, sustain, release });
}

/// Which drawn-LFO slot (0/1/2) a MOD section's "shape" entry drives -
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

/// The drawn LFO shape's breakpoint editor - drawn right under that LFO's
/// shape/rate rows, only while the shape is actually set to `.drawn`
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
    if (shape != .drawn) return;

    const count = synth.lfo_custom_count[slot];
    var curve_buf: [ws.dsp.synth.max_lfo_shape_points]widgets.CurvePoint = undefined;
    var bend_buf: [ws.dsp.synth.max_lfo_shape_points]f32 = undefined;
    for (synth.lfo_custom[slot][0..count], curve_buf[0..count], bend_buf[0..count]) |src, *dst, *bend| {
        dst.* = .{ .beat = src.phase, .value = src.value };
        bend.* = src.curve;
    }

    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "lfo-custom##gui-synth-{d}", .{slot}) catch return;
    const base: u16 = ws.dsp.synth.lfo_custom_id_base + @as(u16, @intCast(slot)) * ws.dsp.synth.lfo_custom_ids_per_slot;
    const base_usize: usize = base;
    const count_id: u16 = base + ws.dsp.synth.max_lfo_shape_points * 2;
    const bend_base: u16 = ws.dsp.synth.lfo_curve_id_base + @as(u16, @intCast(slot)) * ws.dsp.synth.max_lfo_shape_points;
    // A cursor parked on a point's bend focuses that same point, so stepping
    // phase -> value -> bend keeps the ring (and the bend knob below) on it.
    const focused_index: ?usize = if (app.core.synth_cursor >= base and app.core.synth_cursor < count_id)
        (app.core.synth_cursor - base) / 2
    else if (app.core.synth_cursor >= bend_base and app.core.synth_cursor < bend_base + ws.dsp.synth.max_lfo_shape_points)
        app.core.synth_cursor - bend_base
    else
        null;

    const result = widgets.curveEditor(label, .{
        .points = curve_buf[0..count],
        .bends = bend_buf[0..count],
        .beat_hi = 1.0,
        .value_lo = -1.0,
        .value_hi = 1.0,
        .snap_beats = 0,
        .grid_divisions = 4,
        .fill = true,
        .accent = theme.modulation,
        .focused_index = focused_index,
        .x_unit_label = "phase",
        .height = 130,
    });

    // The plot's drag axes are phase and value, so the focused point's
    // segment bend needs a control of its own to be reachable with a mouse.
    if (focused_index) |i| {
        if (i + 1 < count) {
            const bend_id: u16 = @intCast(bend_base + i);
            var bend = synth.lfo_custom[slot][i].curve;
            var id_buf: [40]u8 = undefined;
            const widget_id = std.fmt.bufPrintZ(&id_buf, "##gui-lfo-bend-{d}", .{slot}) catch return;
            var value_buf: [24]u8 = undefined;
            const value_text = std.fmt.bufPrint(&value_buf, "{d:.2}", .{bend}) catch "";
            const bend_result = widgets.knobCell("bend", widget_id, value_text, .{
                .v = &bend,
                .min = -1.0,
                .max = 1.0,
                .cfmt = "%.2f",
                .accent = theme.modulation,
                .focused = app.core.synth_cursor == bend_id,
                .diameter = 28,
            });
            if (bend_result.changed) sendParam(app, bend_id, bend);
            if (bend_result.activated) app.core.synth_cursor = bend_id;
        }
    }

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
                sendParam(app, @intCast(bend_base + i), bend_buf[i - 1]);
            }
            const new_phase_id: u16 = @intCast(base_usize + k * 2);
            sendParam(app, new_phase_id, @floatCast(ins.beat));
            sendParam(app, new_phase_id + 1, ins.value);
            // A point dropped into a bent segment splits it; both halves
            // keeping the old bend is closer to the drawn shape than
            // straightening either one.
            sendParam(app, @intCast(bend_base + k), if (k > 0) bend_buf[k - 1] else 0);
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
                sendParam(app, @intCast(bend_base + i), bend_buf[i + 1]);
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
    var target_buf: [80]u8 = undefined;
    const rack = app.core.session.racks.items[app.core.synth_track];
    drawSlotStepper(app, base_id + 1, synth_ed.modTargetLabel(rack, row, &target_buf), unit * 11.4, accent);
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
    if (result.reset) {
        app.core.synth_cursor = depth_id;
        synth_ed.resetParam(&app.core);
    }
    zgui.sameLine(.{ .spacing = 6 });
    if (on) {
        const sign: []const u8 = if (row.depth >= 0.0) "+" else "";
        zgui.textColored(theme.fg2, "{s}{d:.2}", .{ sign, row.depth });
    } else {
        zgui.textColored(theme.fg3, "off", .{});
    }

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
/// quantity (they flow into a grid), an on/off button,
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
        const curve_id = synth_ed.curveParam(id);
        var curve = if (curve_id) |cid| synth.paramValue(cid) orelse 0 else 0;
        var id_buf: [40]u8 = undefined;
        const widget_id = std.fmt.bufPrintZ(&id_buf, "##gui-synth-{d}", .{id}) catch return;
        const result = widgets.knobCell(label_text, widget_id, value_text, .{
            .v = &edited,
            .modifier_v = if (curve_id != null) &curve else null,
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
        if (result.modifier_changed) sendParam(app, curve_id.?, curve);
        if (result.activated) app.core.synth_cursor = id;
        if (result.reset) {
            app.core.synth_cursor = id;
            synth_ed.resetParam(&app.core);
        }
        return;
    }

    if (ws.dsp.PolySynth.isToggleParam(id)) {
        flow.brk();
        drawParamToggle(app, id, label_text, value >= 0.5, accent);
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
    scroll.noteFocusRow(focused, zgui.getCursorScreenPos()[1], zgui.getFontSize() + 8);
    if (focused) zgui.pushStyleColor4f(.{ .idx = .text, .c = accent });
    defer if (focused) zgui.popStyleColor(.{});
    var value = active;
    var label_buf: [48]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{label_text}) catch return;
    if (widgets.toggle(label, &value)) nudgeParam(app, id, 'h');
}

fn isOscPositionParam(id: u16) bool {
    return id == 185 or id == 186 or id == 187;
}

fn nudgeParam(app: anytype, id: u16, key: u8) void {
    app.core.synth_cursor = id;
    app.core.handleKey(.{ .char = key }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
}

/// The oscillator's own waveform display, at the top of its own card, drawn
/// from that oscillator's table and position. Three cards, three
/// displays, each showing what that oscillator is actually doing - the
/// arrangement Serum, Vital and Massive all use, and what a single sketch
/// in a global header cannot express.
fn drawOscDisplay(synth: *const ws.dsp.PolySynth, position_id: u16, accent: [4]f32) void {
    const shape: struct { wt: ws.dsp.wavetable.Wavetable, wt_pos: f32 } = switch (position_id) {
        185 => .{ .wt = synth.wt, .wt_pos = synth.wt_pos },
        186 => .{ .wt = synth.osc_b_wt, .wt_pos = synth.osc_b_wt_pos },
        else => .{ .wt = synth.osc_c_wt, .wt_pos = synth.osc_c_wt_pos },
    };
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 42;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("##osc-display", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg1), .rounding = gui_style.panel_rounding });
    const mid = origin[1] + height * 0.5;
    draw_list.addLine(.{ .p1 = .{ origin[0], mid }, .p2 = .{ origin[0] + width, mid }, .col = color(theme.bg4), .thickness = 1 });
    drawOscillatorShape(draw_list, .{ origin[0] + 8, origin[1] + 5 }, .{ width - 16, height - 10 }, shape.wt, shape.wt_pos, accent);
    zgui.dummy(.{ .w = 0, .h = 4 });
}

/// One cycle of the LFO's shape, at the top of its own card - the LFO
/// counterpart to `drawOscDisplay`, and the same reason Serum gives each
/// LFO a curve panel: "chaos" versus "s&h" is a picture, not a word. Skipped
/// for `.drawn`, which already draws its real breakpoint editor below
/// (see `drawLfoCustomCurve`).
fn drawLfoDisplay(synth: *const ws.dsp.PolySynth, slot: usize, accent: [4]f32) void {
    const shape = switch (slot) {
        0 => synth.lfo_shape,
        1 => synth.lfo2_shape,
        else => synth.lfo3_shape,
    };
    if (shape == .drawn) return;

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
            .drawn => 0,
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
        };
        const point = [2]f32{ plot_x + plot_w * phase, mid - (height * 0.5 - 5) * sample };
        if (i > 0) draw_list.addLine(.{ .p1 = prev, .p2 = point, .col = color(accent), .thickness = 1.5 });
        prev = point;
    }
    zgui.dummy(.{ .w = 0, .h = 4 });
}

/// Two cycles from oscillator's waveform at current position.
fn drawOscillatorShape(draw_list: zgui.DrawList, pos: [2]f32, size: [2]f32, wt: ws.dsp.wavetable.Wavetable, wt_pos: f32, accent: [4]f32) void {
    // Denser than the classic shapes strictly need, so a bright wavetable
    // frame draws as its own outline instead of an undersampled scribble.
    const steps = 192;
    var prev = pos;
    for (1..steps + 1) |i| {
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, steps) * 2.0;
        const frac = phase - @floor(phase);
        const sample = ws.dsp.wavetable.lookup(wt, wt_pos, frac, 0.0);
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

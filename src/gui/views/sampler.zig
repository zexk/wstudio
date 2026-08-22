const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const icons = @import("../../ui/icons.zig");
const sampler_ed = @import("../../ui/editors/sampler.zig");
const waveform = @import("../../ui/waveform.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const scroll = @import("../scroll.zig");

const theme = &style.palette;

/// Which waveform-overlay handle a drag is currently moving - region
/// start/end trim or a fade-in/out width. Lives on the GUI App so it
/// survives across frames while the mouse button is held.
pub const RegionHandle = enum { start, end, fade_in, fade_out };

/// The waveform pane yields its height to the module panels under it (see
/// scroll.PaneFit): they size to their own content, and a standalone sampler
/// shows one section more than a pad target does. Only one sampler target
/// draws per frame, so one fit is enough - the target is its key.
var pane_fit: scroll.PaneFit = .{};

pub fn draw(app: anytype) void {
    switch (app.core.sampler_target) {
        .sampler => drawStandalone(app),
        .drum => |track| drawPadTarget(app, track, .drum),
        .slice => |track| drawPadTarget(app, track, .slice),
    }
}

const PadTargetKind = enum { drum, slice };

/// The two editable targets this view can point at. Both expose the shared
/// dsp/pad.zig param ids 0-12; they differ in where a value is read from and
/// which engine param id a slider write maps to.
const Target = union(enum) {
    standalone: struct { sampler: *ws.dsp.Sampler, track: u16 },
    pad: struct { pad: *ws.dsp.Pad, track: u16, kind: PadTargetKind, index: u8, sample_rate: u32 },

    fn value(self: Target, id: u8) ?f32 {
        return switch (self) {
            .standalone => |t| t.sampler.paramValue(id),
            .pad => |t| ws.dsp.pad.paramValue(t.pad, id),
        };
    }

    fn track(self: Target) u16 {
        return switch (self) {
            .standalone => |t| t.track,
            .pad => |t| t.track,
        };
    }

    fn sampleRate(self: Target) u32 {
        return switch (self) {
            .standalone => |t| t.sampler.sample_rate,
            .pad => |t| t.sample_rate,
        };
    }

    fn durationSeconds(self: Target) f32 {
        const pad: *const ws.dsp.Pad = switch (self) {
            .standalone => |t| &t.sampler.pad,
            .pad => |t| t.pad,
        };
        return ws.dsp.pad.playDurationSeconds(pad, self.sampleRate());
    }
};

fn drawSharedSections(app: anytype, target: Target) void {
    const available = zgui.getContentRegionAvail()[0];
    const gap: f32 = 10;
    const columns = sectionColumns(available, gap);
    const column_width = (available - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    for (sampler_ed.pad_sections, 0..) |section, index| {
        if (index % columns != 0) zgui.sameLine(.{ .spacing = gap });
        var child_buf: [32]u8 = undefined;
        const child_id = std.fmt.bufPrintZ(&child_buf, "sampler-module-{d}", .{index}) catch continue;
        // Auto-height, not a fixed 205px: a panel shorter than its content
        // grew an inner scrollbar, which turns one module of an instrument
        // into a sublist to scroll through. The panel is a unit; it sizes to
        // what it holds.
        //
        // Marked before `beginChild` because a panel entirely off the fold is
        // skipped wholesale - nothing inside runs, its focused row's own
        // `noteFocusRow` included, which is the one case cursor-following is
        // for. A panel that does draw overwrites this with the real band.
        scroll.noteFocusRow(sectionHasParam(section, app.core.sampler_param), zgui.getCursorScreenPos()[1], 0);
        if (zgui.beginChild(child_id, .{
            .w = column_width,
            .h = 0,
            .child_flags = .{ .border = true, .auto_resize_y = true },
            .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true },
        })) {
            const section_color = switch (section.kind) {
                .envelope => theme.rhythm,
                .output => theme.audio,
                else => theme.focus,
            };
            var title_buf: [48]u8 = undefined;
            const section_title = std.fmt.bufPrint(&title_buf, "{s}  {s}", .{ sampler_ed.sectionIcon(section.kind), section.title }) catch section.title;
            widgets.sectionTitle(section_title, section_color);
            // The ADSR plot is the visual cue and the mouse surface; the four
            // knobs under it stay, same as the synth editor's envelopes -
            // that is where an exact value is read and where j/k land.
            if (section.kind == .envelope) drawAmpEnvelope(app, target);
            for (section.rows) |row| {
                const toggle_accent = if (target == .pad) theme.modulation else theme.focus;
                if (row.id == ws.dsp.pad.reverse_id)
                    drawListParam(app, target, row, &.{ "FORWARD", "REVERSE" }, toggle_accent)
                else if (row.id == ws.dsp.pad.gate_id)
                    drawListParam(app, target, row, &.{ "ONE-SHOT", "GATE", "RETRIGGER" }, toggle_accent)
                else if (row.id == ws.dsp.pad.loop_id)
                    drawListParam(app, target, row, &.{ "OFF", "FORWARD", "PING-PONG" }, toggle_accent)
                else if (row.id == ws.dsp.pad.warp_method_id)
                    drawListParam(app, target, row, &.{ "BEATS", "TONES" }, toggle_accent)
                else if (row.id == ws.dsp.pad.mod_shape_id)
                    drawListParam(app, target, row, &.{ "SINE", "TRIANGLE", "SAW", "SQUARE" }, toggle_accent)
                else if (row.id == ws.dsp.pad.mod_dest_id)
                    drawListParam(app, target, row, &.{ "OFF", "PITCH", "GAIN", "PAN", "FILTER" }, toggle_accent)
                else
                    drawParam(app, target, row.id, row.label, row.gui_format);
            }
        }
        zgui.endChild();
    }
}

fn sectionHasParam(section: sampler_ed.Section, cursor: u8) bool {
    for (section.rows) |row| {
        if (row.id == cursor) return true;
    }
    return false;
}

fn sectionColumns(available: f32, gap: f32) usize {
    return @min(sampler_ed.pad_sections.len, @as(usize, @intFromFloat(@max(1, @floor((available + gap) / (270 + gap))))));
}

test "sampler sections add columns as space becomes available" {
    try std.testing.expectEqual(@as(usize, 1), sectionColumns(539, 10));
    try std.testing.expectEqual(@as(usize, 2), sectionColumns(820, 10));
    try std.testing.expectEqual(@as(usize, 3), sectionColumns(1079, 10));
    try std.testing.expectEqual(@as(usize, 4), sectionColumns(1360, 10));
}

fn drawAmpEnvelope(app: anytype, target: Target) void {
    var attack = target.value(3) orelse return;
    var decay = target.value(4) orelse return;
    var sustain = target.value(5) orelse return;
    var release = target.value(6) orelse return;
    var curve = target.value(ws.dsp.pad.env_curve_id) orelse return;
    const a_range = paramRange(target, 3);
    const d_range = paramRange(target, 4);
    const r_range = paramRange(target, 6);

    const cursor = app.core.sampler_param;
    const focused_stage: ?u2 = if (cursor >= 3 and cursor <= 6) @intCast(cursor - 3) else null;

    const result = widgets.adsrEditor("adsr##sampler-target-env", .{
        .attack = &attack,
        .decay = &decay,
        .sustain = &sustain,
        .release = &release,
        .attack_range = a_range,
        .decay_range = d_range,
        .release_range = r_range,
        .curves = .{ &curve, &curve, &curve },
        .accent = theme.rhythm,
        .focused_stage = focused_stage,
    });
    if (result.changed[0]) setPadParam(app, target, 3, attack);
    if (result.changed[1]) setPadParam(app, target, 4, decay);
    if (result.changed[2]) setPadParam(app, target, 5, sustain);
    if (result.changed[3]) setPadParam(app, target, 6, release);
    if (result.curve_changed[0] or result.curve_changed[1] or result.curve_changed[2]) setPadParam(app, target, ws.dsp.pad.env_curve_id, curve);
    if (result.activated_stage) |stage| app.core.sampler_param = switch (stage) {
        0 => 3,
        1 => 4,
        2 => 5,
        else => 6,
    };
    zgui.textDisabled("A {d:.3}s  D {d:.3}s  S {d:.2}  R {d:.3}s", .{ attack, decay, sustain, release });
}

fn setPadParam(app: anytype, target: Target, id: u8, value: f32) void {
    const index: u8 = switch (target) {
        .standalone => 0,
        .pad => |t| t.index,
    };
    const engine_id = sampler_ed.engineParamId(app.core.sampler_target, index, id);
    app.recordInstrumentEdit(target.track(), engine_id);
    _ = app.core.session.engine.setTrackParam(target.track(), engine_id, value);
    app.core.dirty = true;
}

fn drawStandalone(app: anytype) void {
    const track = app.core.sampler_target.sampler;
    if (track >= app.core.session.racks.items.len) return;
    const sampler = switch (app.core.session.racks.items[track].instrument) {
        .sampler => |*s| s,
        else => {
            zgui.textDisabled("Select a sampler track", .{});
            return;
        },
    };
    const target: Target = .{ .standalone = .{ .sampler = sampler, .track = track } };
    widgets.sectionTitle(icons.sampler ++ "  SAMPLE WAVEFORM", theme.audio);
    while (!sampler.pad_lock.tryLock()) std.atomic.spinLoopHint();
    const has_sample = sampler.pad.samples.len > 0;
    if (has_sample) drawWaveformRegion(app, target, sampler.pad.samples);
    sampler.pad_lock.unlock();
    if (!has_sample) {
        zgui.spacing();
        if (widgets.emptyState(.{
            .id = "sampler-empty-state",
            .title = "NO SAMPLE",
            .explanation = "Choose a WAV file before editing trim, pitch, envelope, or output.",
            .shortcut = ":load",
            .action = "LOAD AUDIO",
            .accent = theme.audio,
        })) widgets.openLoadCommand(app);
        return;
    }
    zgui.spacing();

    const below_top = zgui.getCursorPosY();
    drawSharedSections(app, target);
    widgets.sectionTitle(icons.keys ++ "  " ++ sampler_ed.key_section.title, theme.rhythm);
    drawParam(app, target, sampler_ed.key_section.rows[0].id, sampler_ed.key_section.rows[0].label, sampler_ed.key_section.rows[0].gui_format);
    drawListParam(app, target, sampler_ed.key_section.rows[1], &.{ "POLY", "MONO" }, theme.focus);
    pane_fit.settle(below_top, 0);
}

fn drawPadTarget(app: anytype, track: u16, kind: PadTargetKind) void {
    if (track >= app.core.session.racks.items.len) return;
    const index: u8 = if (kind == .drum) @intCast(app.core.drum_cursor[0]) else @intCast(app.core.slicer_cursor[0]);
    const full_sample = kind == .slice and app.core.session.racks.items[track].instrument.slicer.slice_count == 0;
    if (!full_sample) {
        drawTargetBank(app, track, kind, index);
        zgui.spacing();
    }
    const pad: *ws.dsp.Pad, const sample_rate: u32 = switch (kind) {
        .drum => blk: {
            const drum = switch (app.core.session.racks.items[track].instrument) {
                .drum_machine => |*d| d,
                else => return,
            };
            if (index >= drum.pads.len or drum.pads[index] == null) {
                drawPadEmptyState(app, "NO SAMPLE", "Choose a WAV file for this drum pad.");
                return;
            }
            break :blk .{ &drum.pads[index].?.pad, drum.sample_rate };
        },
        .slice => blk: {
            const slicer = switch (app.core.session.racks.items[track].instrument) {
                .slicer => |*s| s,
                else => return,
            };
            if (index >= slicer.slice_count and !(slicer.slice_count == 0 and slicer.hasAudio())) {
                drawPadEmptyState(app, "NO SLICE SELECTED", "Load and slice audio before editing a slice.");
                return;
            }
            break :blk .{ &slicer.slices[index], slicer.sample_rate };
        },
    };

    const target: Target = .{ .pad = .{ .pad = pad, .track = track, .kind = kind, .index = index, .sample_rate = sample_rate } };
    if (pad.samples.len == 0) {
        drawPadEmptyState(app, if (kind == .drum) "NO SAMPLE" else "NO AUDIO", if (kind == .drum) "Choose a WAV file for this drum pad." else "Choose a WAV file before editing slice playback.");
        return;
    }
    widgets.sectionTitle(if (full_sample) icons.sampler ++ "  FULL SAMPLE" else icons.region ++ "  PLAY REGION", theme.audio);
    drawWaveformRegion(app, target, pad.samples);
    zgui.spacing();

    const below_top = zgui.getCursorPosY();
    drawSharedSections(app, target);
    pane_fit.settle(below_top, 1 + @as(u64, @intFromEnum(kind)));
}

fn drawTargetBank(app: anytype, track: u16, kind: PadTargetKind, selected: u8) void {
    const count: u8 = switch (kind) {
        .drum => ws.dsp.DrumMachine.max_pads,
        .slice => app.core.session.racks.items[track].instrument.slicer.slice_count,
    };
    const bank_count: u8 = @max(1, (count + 7) / 8);
    const bank: u8 = @min(selected / 8, bank_count - 1);
    const bank_start: u8 = bank * 8;
    widgets.sectionTitle(if (kind == .drum) icons.drum ++ "  PAD BANK" else icons.slicer ++ "  SLICE MAP", if (kind == .drum) theme.rhythm else theme.audio);
    zgui.textDisabled("bank {d}/{d}", .{ bank + 1, bank_count });
    zgui.sameLine(.{ .spacing = 8 });
    zgui.beginDisabled(.{ .disabled = bank == 0 });
    if (widgets.iconButton(icons.prev ++ "##target-bank-prev", "Previous bank")) setTargetIndex(app, kind, selected -| 8);
    zgui.endDisabled();
    zgui.sameLine(.{ .spacing = 4 });
    zgui.beginDisabled(.{ .disabled = bank + 1 >= bank_count });
    if (widgets.iconButton(icons.next ++ "##target-bank-next", "Next bank")) setTargetIndex(app, kind, @min(selected +| 8, count -| 1));
    zgui.endDisabled();
    const available = zgui.getContentRegionAvail()[0];
    const width = @max(72, (available - 7 * 6) / 8);
    for (0..8) |offset| {
        if (offset > 0) zgui.sameLine(.{ .spacing = 6 });
        const index: u8 = bank_start + @as(u8, @intCast(offset));
        const exists = index < count and switch (kind) {
            .drum => app.core.session.racks.items[track].instrument.drum_machine.pads[index] != null,
            .slice => true,
        };
        var label_buf: [48]u8 = undefined;
        const label = switch (kind) {
            .drum => if (index < count)
                std.fmt.bufPrintZ(&label_buf, "{d:0>2}\n{s}##target-{d}", .{ index + 1, app.core.session.racks.items[track].instrument.drum_machine.padName(index), index }) catch continue
            else
                std.fmt.bufPrintZ(&label_buf, "--##target-{d}", .{index}) catch continue,
            .slice => if (index < count)
                std.fmt.bufPrintZ(&label_buf, "{d:0>2}\n{d:.0}-{d:.0}%##target-{d}", .{ index + 1, app.core.session.racks.items[track].instrument.slicer.slices[index].start_norm * 100, app.core.session.racks.items[track].instrument.slicer.slices[index].end_norm * 100, index }) catch continue
            else
                std.fmt.bufPrintZ(&label_buf, "--##target-{d}", .{index}) catch continue,
        };
        const active = index == selected;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) (if (kind == .drum) theme.rhythm else theme.audio) else theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else if (exists) theme.fg1 else theme.fg3 });
        zgui.beginDisabled(.{ .disabled = index >= count });
        if (zgui.button(label, .{ .w = width, .h = 46 })) setTargetIndex(app, kind, index);
        zgui.endDisabled();
        zgui.popStyleColor(.{ .count = 2 });
    }
    drawTargetSummary(app, track, kind, selected);
}

fn setTargetIndex(app: anytype, kind: PadTargetKind, index: u8) void {
    switch (kind) {
        .drum => app.core.drum_cursor[0] = index,
        .slice => app.core.slicer_cursor[0] = index,
    }
}

fn drawTargetSummary(app: anytype, track: u16, kind: PadTargetKind, selected: u8) void {
    switch (kind) {
        .drum => {
            const drum = &app.core.session.racks.items[track].instrument.drum_machine;
            const sampler = if (drum.pads[selected]) |*pad| pad else {
                zgui.textDisabled("pad {d}  empty  |  :load adds a sample", .{selected + 1});
                return;
            };
            const seconds = @as(f32, @floatFromInt(sampler.pad.samples.len)) / @as(f32, @floatFromInt(@max(drum.sample_rate, 1)));
            zgui.textDisabled("{d:.2}s  |  choke ", .{seconds});
            zgui.sameLine(.{ .spacing = 0 });
            if (drum.choke_group[selected] == 0)
                zgui.textDisabled("off", .{})
            else
                zgui.textDisabled("group {d}", .{drum.choke_group[selected]});
            zgui.sameLine(.{ .spacing = 0 });
            if (drum.pad_len[selected] == 0)
                zgui.textDisabled("  |  loop follows pattern", .{})
            else
                zgui.textDisabled("  |  loop {d}/{d} steps", .{ drum.pad_len[selected], drum.step_count });
        },
        .slice => {
            const slicer = &app.core.session.racks.items[track].instrument.slicer;
            if (selected >= slicer.slice_count) return;
            const slice = slicer.slices[selected];
            zgui.textDisabled("source {d:.1}-{d:.1}%  |  width {d:.1}%  |  choke ", .{
                slice.start_norm * 100,
                slice.end_norm * 100,
                (slice.end_norm - slice.start_norm) * 100,
            });
            zgui.sameLine(.{ .spacing = 0 });
            if (slicer.choke_group[selected] == 0)
                zgui.textDisabled("off", .{})
            else
                zgui.textDisabled("group {d}", .{slicer.choke_group[selected]});
        },
    }
}

fn drawPadEmptyState(app: anytype, title: []const u8, explanation: []const u8) void {
    widgets.sectionTitle(icons.region ++ "  PLAY REGION", theme.audio);
    zgui.spacing();
    if (widgets.emptyState(.{
        .id = "sampler-pad-empty-state",
        .title = title,
        .explanation = explanation,
        .shortcut = ":load",
        .action = "LOAD SAMPLE",
        .accent = theme.audio,
    })) widgets.openLoadCommand(app);
}

// Slider bounds come from the dsp-side spec table so they can never drift
// from what setParamAbsolute actually clamps to. The shared pad ids are the
// same params the standalone sampler routes to dsp/pad.zig, so one table
// covers both targets; root note is the only continuous id outside it.
fn paramRange(target: Target, id: u8) [2]f32 {
    if (id == 3 or id == 4 or id == 6 or id == 10 or id == 11)
        return .{ 0, @max(target.durationSeconds(), 0.001) };
    if (ws.dsp.Sampler.findAutomatableParam(id)) |param| return param.range;
    if (id == ws.dsp.Sampler.root_note_id) return .{ 0, 127 };
    return .{ 0, 1 };
}

fn drawParam(app: anytype, target: Target, id: u8, label_text: []const u8, format: [:0]const u8) void {
    var value = target.value(id) orelse return;
    const curve_id = sampler_ed.curveParam(id);
    var curve = if (curve_id) |cid| target.value(cid) orelse 0 else 0;
    const range = paramRange(target, id);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##sampler-target-{d}", .{ label_text, id }) catch return;
    const focused = app.core.sampler_param == id;
    const is_time = id == 3 or id == 4 or id == 6 or id == 10 or id == 11;
    const result = widgets.paramKnob(label_text, label, .{
        .v = &value,
        .modifier_v = if (curve_id != null) &curve else null,
        .min = range[0],
        .max = range[1],
        .cfmt = format,
        .accent = theme.focus,
        .focused = focused,
        .logarithmic = is_time and range[0] > 0,
        .skew = if (is_time and range[0] == 0) 3 else 1,
    });
    if (result.changed) setPadParam(app, target, id, value);
    if (result.modifier_changed) setPadParam(app, target, curve_id.?, curve);
    if (result.activated) app.core.sampler_param = id;
}

fn drawListParam(app: anytype, target: Target, row: sampler_ed.ParamRow, labels: []const [:0]const u8, accent: [4]f32) void {
    var value = target.value(row.id) orelse return;
    const idx: usize = @min(@as(usize, @intFromFloat(@max(@round(value), 0))), labels.len - 1);
    var id_buf: [48]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "##sampler-list-{d}", .{row.id}) catch return;
    const result = widgets.listStepper(row.label, id, .{
        .v = &value,
        .min = 0,
        .max = @floatFromInt(labels.len - 1),
        .display = labels[idx],
        .accent = accent,
        .focused = app.core.sampler_param == row.id,
    });
    if (result.changed) {
        app.core.sampler_param = row.id;
        setPadParam(app, target, row.id, value);
    }
}

/// Waveform tint per frequency band, the GUI half of views/slicer.zig's and
/// the TUI's own mapping: modulation (warm) for lows, the audio accent for
/// the body, rhythm for air. Reusing named theme roles rather than raw RGB
/// keeps the pane readable under every shipped theme.
pub fn bandColor(band: waveform.Band) [4]f32 {
    return switch (band) {
        .low => theme.modulation,
        .mid => theme.audio,
        .high => theme.rhythm,
    };
}

// A terminal can only show region bounds as numbers; dragging the trim
// points against the actual waveform shape is GUI-only. Start/end share
// param ids 0/1 across every target the `Target` union covers, so one
// drag implementation serves the standalone sampler and both pad kinds.
fn drawWaveformRegion(app: anytype, target: Target, samples: []const f32) void {
    if (samples.len == 0) {
        zgui.textDisabled("No sample loaded.", .{});
        return;
    }
    const start = target.value(0) orelse 0;
    const end = target.value(1) orelse 1;

    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = pane_fit.height(120, 300);
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("##waveform-region", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = style.color(theme.bg0), .rounding = style.panel_rounding });

    // Pitch and stretch change how long the region plays, so the region is
    // drawn on its warped timeline while the trim markers stay put on the
    // source columns they trim (ui/waveform.zig).
    const scale = waveform.timeScale(target.value(2) orelse 0, target.value(12) orelse 1);
    const played_end = waveform.playedEndNorm(start, end, scale);
    const sample_rate = target.sampleRate();
    const total_f: f32 = @floatFromInt(samples.len);
    const sr_f: f32 = @floatFromInt(@max(sample_rate, 1));
    const fade_in_norm = std.math.clamp((target.value(10) orelse 0) * sr_f / total_f, 0, played_end - start);
    const fade_out_norm = std.math.clamp((target.value(11) orelse 0) * sr_f / total_f, 0, played_end - start);
    const fade_curve = target.value(ws.dsp.pad.fade_curve_id) orelse 0;

    // One bucket per pixel column. A fixed bucket count drew the pane as a
    // comb - 512 one-pixel lines spread over a 1400px pane left two blank
    // pixels between every column, which reads as a dotted sketch of the
    // waveform rather than the waveform.
    var overview: [2048]f32 = undefined;
    var bands: [2048]waveform.Band = undefined;
    const columns: usize = @intFromFloat(@max(width, 1));
    const count = @min(@min(samples.len, overview.len), columns);
    @memset(overview[0..count], 0);
    @memset(bands[0..count], .mid);
    const slicer = slicerForTarget(app, target);
    if (slicer) |sl| {
        for (sl.slices[0..sl.slice_count]) |slice| waveform.fixedRegionBuckets(
            samples,
            overview[0..count],
            bands[0..count],
            sl.sample_rate,
            slice.start_norm,
            slice.end_norm,
            waveform.timeScale(slice.pitch_semitones, slice.stretch_ratio),
        );
        updateSliceGlow(app, sl);
    } else {
        waveform.peakBucketsWarped(samples, overview[0..count], start, end, scale);
        waveform.bandBuckets(samples, bands[0..count], target.sampleRate(), start, end, scale);
    }
    const mid_y = origin[1] + height / 2;
    const start_x = origin[0] + start * width;
    const end_x = origin[0] + end * width;
    const played_end_x = origin[0] + played_end * width;
    for (overview[0..count], 0..) |peak, i| {
        const x = origin[0] + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        const norm = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        var in_region = x >= start_x - 0.5 and x <= played_end_x + 0.5;
        var fade_gain = @min(
            ws.dsp.pad.curvedRamp(@floatCast(norm - start), fade_in_norm, fade_curve),
            ws.dsp.pad.curvedRamp(@floatCast(played_end - norm), fade_out_norm, fade_curve),
        );
        var line_color = if (in_region) bandColor(bands[i]) else [4]f32{ theme.fg3[0], theme.fg3[1], theme.fg3[2], 0.55 };
        if (slicer) |sl| for (sl.slices[0..sl.slice_count], 0..) |slice, slice_index| {
            if (norm < slice.start_norm or norm >= slice.end_norm) continue;
            const slice_scale = waveform.timeScale(slice.pitch_semitones, slice.stretch_ratio);
            const slice_end = @min(slice.end_norm, waveform.playedEndNorm(slice.start_norm, slice.end_norm, slice_scale));
            const slice_fade_in = std.math.clamp(slice.fade_in_s * sr_f / total_f, 0, slice_end - slice.start_norm);
            const slice_fade_out = std.math.clamp(slice.fade_out_s * sr_f / total_f, 0, slice_end - slice.start_norm);
            fade_gain = @min(
                ws.dsp.pad.curvedRamp(@floatCast(norm - slice.start_norm), slice_fade_in, slice.fade_curve),
                ws.dsp.pad.curvedRamp(@floatCast(slice_end - norm), slice_fade_out, slice.fade_curve),
            );
            in_region = norm < slice_end;
            line_color = if (in_region) bandColor(bands[i]) else .{ theme.fg3[0], theme.fg3[1], theme.fg3[2], 0.55 };
            const glow = app.waveform_slice_glow[slice_index];
            for (0..3) |channel| line_color[channel] += (theme.focus[channel] - line_color[channel]) * glow;
            break;
        };
        const h = @max(1, peak * fade_gain * height / 2 * 0.94);
        draw_list.addLine(.{ .p1 = .{ x, mid_y - h }, .p2 = .{ x, mid_y + h }, .col = style.color(line_color), .thickness = 1 });
    }
    draw_list.addLine(.{ .p1 = .{ origin[0], mid_y }, .p2 = .{ origin[0] + width, mid_y }, .col = style.color(theme.line), .thickness = 1 });

    if (slicer == null and start > 0) draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ start_x, origin[1] + height }, .col = style.color(.{ theme.bg0[0], theme.bg0[1], theme.bg0[2], 0.6 }) });
    if (slicer == null and played_end < 1) draw_list.addRectFilled(.{ .pmin = .{ played_end_x, origin[1] }, .pmax = .{ origin[0] + width, origin[1] + height }, .col = style.color(.{ theme.bg0[0], theme.bg0[1], theme.bg0[2], 0.6 }) });
    drawSliceBoundaries(app, target, draw_list, origin, width, height);

    const fade_in_x = origin[0] + (start + fade_in_norm) * width;
    const fade_out_x = origin[0] + (played_end - fade_out_norm) * width;
    drawFadeLine(draw_list, start_x, fade_in_x, origin[1], mid_y, theme.focus, app.waveform_drag == .fade_in, fade_curve);
    drawFadeLine(draw_list, played_end_x, fade_out_x, origin[1], mid_y, theme.focus, app.waveform_drag == .fade_out, fade_curve);

    drawRegionHandle(draw_list, start_x, origin[1], height, theme.focus, app.waveform_drag == .start);
    drawRegionHandle(draw_list, end_x, origin[1], height, theme.rhythm, app.waveform_drag == .end);

    const fade_y = origin[1] + 8;
    const near_fade_in = hovered and sample_rate > 0 and @abs(mouse[0] - fade_in_x) <= 8 and @abs(mouse[1] - fade_y) <= 10;
    const near_fade_out = hovered and sample_rate > 0 and @abs(mouse[0] - fade_out_x) <= 8 and @abs(mouse[1] - fade_y) <= 10;
    const near_trim = hovered and (@abs(mouse[0] - start_x) <= 8 or @abs(mouse[0] - end_x) <= 8);
    const near_handle = near_trim or near_fade_in or near_fade_out;
    if (hovered and zgui.isMouseClicked(.left) and near_handle) {
        app.waveform_drag = if (near_fade_in and (!near_fade_out or @abs(mouse[0] - fade_in_x) <= @abs(mouse[0] - fade_out_x)))
            .fade_in
        else if (near_fade_out)
            .fade_out
        else if (@abs(mouse[0] - start_x) <= @abs(mouse[0] - end_x))
            .start
        else
            .end;
    }
    if (app.waveform_drag) |handle| {
        if (zgui.isMouseDown(.left)) {
            const norm = std.math.clamp((mouse[0] - origin[0]) / width, 0, 1);
            switch (handle) {
                .start, .end => {
                    const id: u8 = if (handle == .start) 0 else 1;
                    setPadParam(app, target, id, norm);
                    app.core.sampler_param = id;
                },
                .fade_in, .fade_out => if (sample_rate > 0 and total_f > 0) {
                    const pos = std.math.clamp(norm, start, played_end);
                    const frac = if (handle == .fade_in) pos - start else played_end - pos;
                    const id: u8 = if (handle == .fade_in) 10 else 11;
                    const seconds = @max(0.0, frac) * total_f / sr_f;
                    setPadParam(app, target, id, seconds);
                    app.core.sampler_param = id;
                },
            }
            app.core.dirty = true;
        } else {
            app.waveform_drag = null;
        }
    } else if (near_handle) {
        zgui.setMouseCursor(.resize_ew);
    }

    zgui.textDisabled("region {d:.1}-{d:.1}% of {d} samples", .{ start * 100, end * 100, samples.len });
    zgui.sameLine(.{});
    widgets.hoverHelp("Drag markers to trim; drag fade dots to shape fades");
}

fn slicerForTarget(app: anytype, target: Target) ?*const ws.dsp.Slicer {
    const pad_target = switch (target) {
        .pad => |pad| pad,
        else => return null,
    };
    if (pad_target.kind != .slice or pad_target.track >= app.core.session.racks.items.len) return null;
    return switch (app.core.session.racks.items[pad_target.track].instrument) {
        .slicer => |*slicer| slicer,
        else => null,
    };
}

fn updateSliceGlow(app: anytype, slicer: *const ws.dsp.Slicer) void {
    const now = std.Io.Timestamp.now(app.core.io, .awake).nanoseconds;
    const elapsed: f32 = if (app.waveform_glow_last_ns == 0) 0 else @floatCast(@as(f64, @floatFromInt(now - app.waveform_glow_last_ns)) / std.time.ns_per_s);
    app.waveform_glow_last_ns = now;
    const dt = std.math.clamp(elapsed, 0, 0.1);
    for (&app.waveform_slice_glow, 0..) |*glow, index| {
        const target: f32 = if (index < slicer.slice_count and slicer.slicePlaying(@intCast(index))) 1 else 0;
        const speed: f32 = if (target > glow.*) 12 else 4;
        glow.* += (target - glow.*) * @min(1, dt * speed);
    }
}

fn drawSliceBoundaries(app: anytype, target: Target, draw_list: zgui.DrawList, origin: [2]f32, width: f32, height: f32) void {
    const pad_target = switch (target) {
        .pad => |pad| pad,
        else => return,
    };
    if (pad_target.kind != .slice or pad_target.track >= app.core.session.racks.items.len) return;
    const slicer = switch (app.core.session.racks.items[pad_target.track].instrument) {
        .slicer => |*instrument| instrument,
        else => return,
    };
    const labels = sliceLabelsFit(width, slicer.slice_count);
    for (slicer.slices[0..slicer.slice_count], 0..) |slice, index| {
        const x = origin[0] + slice.start_norm * width;
        const selected = index == pad_target.index;
        draw_list.addLine(.{
            .p1 = .{ x, origin[1] },
            .p2 = .{ x, origin[1] + height },
            .col = style.color(if (selected) theme.focus else .{ theme.fg2[0], theme.fg2[1], theme.fg2[2], 0.42 }),
            .thickness = if (selected) 2 else 1,
        });
        if (labels) draw_list.addText(.{ x + 4, origin[1] + 4 }, style.color(if (selected) theme.focus else theme.fg2), "{d}", .{index + 1});
    }
}

fn sliceLabelsFit(width: f32, count: u8) bool {
    return count > 0 and width / @as(f32, @floatFromInt(count)) >= 28;
}

test "slice boundary labels hide before they overlap" {
    try std.testing.expect(sliceLabelsFit(800, 8));
    try std.testing.expect(!sliceLabelsFit(800, 32));
    try std.testing.expect(!sliceLabelsFit(800, 0));
}

fn drawRegionHandle(draw_list: zgui.DrawList, x: f32, top: f32, height: f32, accent: [4]f32, active: bool) void {
    const line_color = if (active) accent else [4]f32{ accent[0], accent[1], accent[2], 0.7 };
    draw_list.addLine(.{ .p1 = .{ x, top }, .p2 = .{ x, top + height }, .col = style.color(line_color), .thickness = if (active) 2 else 1.5 });
    draw_list.addTriangleFilled(.{ .p1 = .{ x - 5, top }, .p2 = .{ x + 5, top }, .p3 = .{ x, top + 8 }, .col = style.color(line_color) });
}

fn drawFadeLine(draw_list: zgui.DrawList, silent_x: f32, full_x: f32, top: f32, mid_y: f32, accent: [4]f32, active: bool, curve: f32) void {
    const full_y = top + 8;
    const line_color = if (active) accent else [4]f32{ accent[0], accent[1], accent[2], 0.85 };
    var previous = [2]f32{ silent_x, mid_y };
    for (1..17) |step| {
        const t = @as(f32, @floatFromInt(step)) / 16.0;
        const shaped = ws.dsp.synth_math.bendShape(t, curve);
        const next = [2]f32{ silent_x + (full_x - silent_x) * t, mid_y + (full_y - mid_y) * shaped };
        draw_list.addLine(.{ .p1 = previous, .p2 = next, .col = style.color(line_color), .thickness = if (active) 2 else 1.5 });
        previous = next;
    }
    draw_list.addCircleFilled(.{ .p = .{ full_x, full_y }, .r = if (active) 5 else 4, .col = style.color(line_color) });
}

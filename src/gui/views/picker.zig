const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const spectrum_ed = @import("../../ui/editors/spectrum.zig");
const preset_ed = @import("../../ui/editors/preset_picker.zig");
const synth_ed = @import("../../ui/editors/synth.zig");
const style = @import("../style.zig");

const color = style.color;
const patina = &style.palette;

pub fn drawInstrument(app: anytype) void {
    zgui.textColored(patina.focus, "ADD INSTRUMENT", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("Choose the track's sound source", .{});
    zgui.separator();
    const entries = [_]struct { label: []const u8, desc: []const u8, kind: ws.InstrumentKind, accent: [4]f32 }{
        .{ .label = "POLY SYNTH", .desc = "SYNTHESIS  POLY  MODULATION", .kind = .poly_synth, .accent = patina.focus },
        .{ .label = "SAMPLER", .desc = "AUDIO  KEYMAP  ENVELOPE", .kind = .sampler, .accent = patina.audio },
        .{ .label = "DRUM MACHINE", .desc = "PADS  VELOCITY  SEQUENCER", .kind = .drum_machine, .accent = patina.rhythm },
        .{ .label = "SLICER", .desc = "AUDIO  SLICES  SEQUENCER", .kind = .slicer, .accent = patina.modulation },
    };
    const available = zgui.getContentRegionAvail()[0];
    const gap: f32 = 10;
    const columns: usize = if (available >= 720) 2 else 1;
    const width = (available - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    for (entries, 0..) |entry, i| {
        if (i % columns != 0) zgui.sameLine(.{ .spacing = gap });
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "instrument-card-{d}", .{i}) catch continue;
        if (drawCard(id, entry.label, entry.desc, entry.accent, app.core.picker_cursor == i, width)) {
            app.core.picker_cursor = @intCast(i);
            app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
}

pub fn drawFx(app: anytype) void {
    zgui.textColored(patina.modulation, "ADD EFFECT", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("Inserted after the focused unit", .{});
    zgui.separator();
    var synth_buf: [14]ws.dsp.synth.FxUnitKind = undefined;
    const synth_kinds = if (app.core.view == .synth_fx_picker) synth_ed.filteredSynthFxPickerKinds(&app.core, &synth_buf) else &.{};
    const kinds = spectrum_ed.picker_kinds;
    const available = zgui.getContentRegionAvail()[0];
    const count = if (app.core.view == .synth_fx_picker) synth_kinds.len else kinds.len;
    const gap: f32 = 10;
    const columns: usize = if (app.core.view == .fx_picker and available >= 1120)
        3
    else if (available >= 700)
        2
    else
        1;
    const width = (available - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    for (0..count) |i| {
        if (i % columns != 0) zgui.sameLine(.{ .spacing = gap });
        const kind = if (app.core.view == .synth_fx_picker) synth_ed.asFxKind(synth_kinds[i]) else kinds[i];
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "fx-picker-card-{d}", .{i}) catch continue;
        const selected = if (app.core.view == .synth_fx_picker) app.core.synth_fx_picker_cursor == i else app.core.fx_picker_cursor == i;
        var desc_buf: [96]u8 = undefined;
        const desc = std.fmt.bufPrint(&desc_buf, "{s}  |  {s}", .{ fxCategory(kind), fxDescription(kind) }) catch fxDescription(kind);
        if (drawCard(id, spectrum_ed.unitLabel(kind), desc, fxAccent(kind), selected, width)) {
            if (app.core.view == .synth_fx_picker) {
                app.core.synth_fx_picker_cursor = @intCast(i);
                synth_ed.insertFromSynthFxPicker(&app.core, synth_kinds[i]);
                app.closePicker(.synth_editor);
            } else {
                app.core.fx_picker_cursor = @intCast(i);
                activateFx(app, kind);
            }
        }
    }
}

fn fxCategory(kind: ws.FxKind) []const u8 {
    return switch (kind) {
        .gate, .comp, .mb_comp, .ott => "DYNAMICS",
        .eq => "TONE",
        .sat, .crush, .tape => "CHARACTER",
        .chorus, .flanger, .phaser, .freq_shift => "MODULATION",
        .delay, .reverb => "TIME",
        .clap => "PLUGIN",
    };
}

fn activateFx(app: anytype, kind: ws.FxKind) void {
    switch (app.core.fx_picker_return) {
        .track_spectrum, .master_spectrum, .group_spectrum => {
            spectrum_ed.insertFromPicker(&app.core, kind);
            app.closePicker(app.core.view);
        },
        else => {
            // The cursor can sit on the master row (== tracks.len), which
            // has no rack of its own.
            if (app.core.cursor >= app.core.session.racks.items.len) return;
            const rack = app.core.session.racks.items[app.core.cursor];
            _ = rack.fx.insert(app.core.session.allocator, rack.fx.units.items.len, kind, app.core.session.project.sample_rate) catch return;
            app.core.session.syncTrackChain(@intCast(app.core.cursor), rack);
            app.closePicker(.track_spectrum);
        },
    }
}

fn fxDescription(kind: ws.FxKind) []const u8 {
    return switch (kind) {
        .gate => "Tighten noise and transients",
        .comp => "Control dynamics and sidechain",
        .mb_comp => "Shape dynamics across three bands",
        .ott => "Fast upward and downward compression",
        .eq => "Eight-band parametric tone shaping",
        .sat => "Add harmonic drive and warmth",
        .crush => "Reduce bit depth and sample rate",
        .chorus => "Widen with modulated voices",
        .flanger => "Short swept comb modulation",
        .tape => "Soft saturation and movement",
        .phaser => "Animated phase cancellation",
        .freq_shift => "Shift the full frequency spectrum",
        .delay => "Stereo echoes with feedback",
        .reverb => "Place the sound in a room",
        .clap => "External CLAP audio plugin",
    };
}

const fxAccent = style.fxKindAccent;

fn drawCard(id: [:0]const u8, label: []const u8, desc: []const u8, accent: [4]f32, selected: bool, width: f32) bool {
    const height: f32 = 62;
    const origin = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(if (hovered) patina.bg3 else patina.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 4, origin[1] + height }, .col = color(accent), .rounding = 2 });
    if (selected) draw_list.addRect(.{ .pmin = .{ origin[0] + 1, origin[1] + 1 }, .pmax = .{ origin[0] + width - 1, origin[1] + height - 1 }, .col = color(patina.focus), .rounding = 4, .thickness = 2 });
    draw_list.addText(.{ origin[0] + 14, origin[1] + 10 }, color(patina.fg0), "{s}", .{label});
    draw_list.addText(.{ origin[0] + 14, origin[1] + 35 }, color(patina.fg3), "{s}", .{desc});
    return clicked;
}

pub fn drawPreset(app: anytype) void {
    var rows_buf: [preset_ed.max_display_rows]preset_ed.DisplayRow = undefined;
    const rows = preset_ed.buildDisplayRows(&app.core, &rows_buf);
    const count = preset_ed.entryCountOf(rows);
    const kind_label = if (app.core.preset_picker_kind == .synth) "SYNTH PRESETS" else "DRUM KITS";
    zgui.textColored(if (app.core.preset_picker_kind == .synth) patina.focus else patina.rhythm, "{s}", .{kind_label});
    zgui.sameLine(.{});
    zgui.textDisabled("{d} matches for track {d:0>2}", .{ count, app.core.preset_picker_track + 1 });
    const filter = preset_ed.activeFilter(&app.core);
    if (filter.len > 0) {
        zgui.sameLine(.{ .spacing = 14 });
        zgui.textColored(patina.audio, "filter: {s}", .{filter});
    }
    zgui.separator();
    const available = zgui.getContentRegionAvail()[0];
    const sidebar_width: f32 = if (available >= 820) 230 else 0;
    if (sidebar_width > 0) {
        if (zgui.beginChild("preset-sidebar", .{ .w = sidebar_width, .h = -1, .child_flags = .{ .border = true } })) {
            zgui.textColored(patina.focus, "DISCOVER", .{});
            zgui.separator();
            zgui.textDisabled("/  filter presets", .{});
            zgui.textDisabled("[ ]  change category", .{});
            zgui.textDisabled("a  audition selected", .{});
            zgui.spacing();
            zgui.textColored(if (app.core.preset_audition_active) patina.audio else patina.fg3, "{s}", .{if (app.core.preset_audition_active) "AUDITION ACTIVE" else "AUDITION READY"});
            zgui.spacing();
            var selected_ordinal: usize = 0;
            for (rows) |row| switch (row) {
                .header => {},
                .entry => |entry| {
                    if (selected_ordinal == app.core.preset_picker_cursor) {
                        zgui.separator();
                        zgui.textColored(patina.fg0, "{s}", .{entry.name});
                        zgui.textDisabled("{s}", .{entry.category});
                        zgui.textDisabled("by {s}", .{entry.author});
                        break;
                    }
                    selected_ordinal += 1;
                },
            };
        }
        zgui.endChild();
        zgui.sameLine(.{ .spacing = 10 });
    }
    if (zgui.beginChild("presets", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        var ordinal: usize = 0;
        for (rows, 0..) |row, row_index| switch (row) {
            .header => |header| {
                zgui.spacing();
                zgui.textColored(patina.fg2, "{s}", .{header});
                zgui.separator();
            },
            .entry => |entry| {
                var id_buf: [48]u8 = undefined;
                const id = std.fmt.bufPrintZ(&id_buf, "preset-card-{d}", .{row_index}) catch continue;
                const selected = app.core.preset_picker_cursor == ordinal;
                const accent = if (app.core.preset_picker_kind == .synth) patina.focus else patina.rhythm;
                if (drawCard(id, entry.name, entry.author, accent, selected, zgui.getContentRegionAvail()[0])) {
                    app.core.preset_picker_cursor = ordinal;
                    app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
                }
                ordinal += 1;
            },
        };
    }
    zgui.endChild();
}

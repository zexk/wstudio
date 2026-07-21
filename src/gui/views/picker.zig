const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const spectrum_ed = @import("../../ui/editors/spectrum.zig");
const preset_ed = @import("../../ui/editors/preset_picker.zig");
const synth_ed = @import("../../ui/editors/synth.zig");
const fuzzy = @import("../../ui/fuzzy.zig");
const style = @import("../style.zig");
const app_mod = @import("../../ui/app.zig");

const color = style.color;
const theme = &style.palette;

/// Paint a Telescope-style modal into the existing workspace window: a
/// draw-list backdrop and panel frame, then a real (borderless, transparent)
/// ImGui child sized to the panel's inner area. The child is what makes
/// `drawInstrument`/`drawFx`/`drawPreset`'s entries actual children of the
/// panel - clipped and scrollable to it - instead of raw draw-list content
/// that happily overruns the panel's edges. Pair with `endOverlay`.
pub fn beginOverlay() void {
    const window_pos = zgui.getWindowPos();
    const window_size = zgui.getWindowSize();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{
        .pmin = window_pos,
        .pmax = .{ window_pos[0] + window_size[0], window_pos[1] + window_size[1] },
        .col = color(.{ 0, 0, 0, 0.68 }),
    });

    const panel_w = @min(window_size[0] - 80, 920);
    const panel_h = @min(window_size[1] - 64, 620);
    const panel = .{
        window_pos[0] + (window_size[0] - panel_w) * 0.5,
        window_pos[1] + (window_size[1] - panel_h) * 0.42,
    };
    draw_list.addRectFilled(.{
        .pmin = panel,
        .pmax = .{ panel[0] + panel_w, panel[1] + panel_h },
        .col = color(theme.bg1),
        .rounding = 6,
    });
    draw_list.addRect(.{
        .pmin = panel,
        .pmax = .{ panel[0] + panel_w, panel[1] + panel_h },
        .col = color(theme.focus),
        .rounding = 6,
        .thickness = 1,
    });
    zgui.setCursorScreenPos(.{ panel[0] + 18, panel[1] + 16 });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = .{ 0, 0, 0, 0 } });
    _ = zgui.beginChild("telescope-panel-content", .{ .w = panel_w - 36, .h = panel_h - 32 });
}

pub fn endOverlay() void {
    zgui.endChild();
    zgui.popStyleColor(.{});
}

fn overlayWidth() f32 {
    return @min(zgui.getContentRegionAvail()[0], 884);
}

pub fn drawInstrument(app: anytype) void {
    if (app.core.picker_replace) {
        zgui.textColored(theme.focus, "REPLACE INSTRUMENT", .{});
        zgui.sameLine(.{});
        zgui.textDisabled("Swaps notes over when the old and new kinds are compatible", .{});
    } else {
        zgui.textColored(theme.focus, "ADD INSTRUMENT", .{});
        zgui.sameLine(.{});
        zgui.textDisabled("Choose the track's sound source", .{});
    }
    zgui.separator();
    // Single column: `j`/`k` move the shared picker cursor by a flat +/-1,
    // same as the TUI's list - a multi-column card grid would make "down"
    // jump sideways instead.
    const width = overlayWidth();
    zgui.textColored(theme.fg2, "INTERNAL", .{});
    for (app_mod.instrument_picker_items, 0..) |entry, i| {
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "instrument-card-{d}", .{i}) catch continue;
        const accent = switch (entry.kind) {
            .poly_synth => theme.focus,
            .sampler, .soundfont => theme.audio,
            .drum_machine => theme.rhythm,
            .slicer => theme.modulation,
            else => theme.focus,
        };
        if (drawCard(id, entry.label, entry.description, accent, app.core.picker_cursor == i, width, "")) {
            app.core.picker_cursor = @intCast(i);
            app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
    zgui.spacing();
    zgui.textColored(theme.fg2, "EXTERNAL", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("CLAP", .{});
    const external_count = app.core.external_plugins.count(.instrument);
    for (0..external_count) |external_i| {
        const plugin = app.core.external_plugins.at(.instrument, external_i).?;
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "instrument-plugin-card-{d}", .{external_i}) catch continue;
        var desc_buf: [128]u8 = undefined;
        const desc = std.fmt.bufPrint(&desc_buf, "CLAP  |  {s}", .{plugin.vendor}) catch "CLAP";
        const ordinal = app_mod.instrument_picker_items.len + external_i;
        if (drawCard(id, plugin.name, desc, theme.focus, app.core.picker_cursor == ordinal, width, "")) {
            app.core.picker_cursor = @intCast(ordinal);
            app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
    if (external_count == 0) zgui.textDisabled("No external instruments found", .{});
}

pub fn drawFx(app: anytype) void {
    zgui.textColored(theme.modulation, "ADD EFFECT", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("Inserted after the focused unit", .{});
    zgui.separator();
    var synth_buf: [14]ws.dsp.synth.FxUnitKind = undefined;
    const synth_kinds = if (app.core.view == .synth_fx_picker) synth_ed.filteredSynthFxPickerKinds(&app.core, &synth_buf) else &.{};
    var kinds_buf: [spectrum_ed.picker_kinds.len]ws.FxKind = undefined;
    const kinds = if (app.core.view == .fx_picker) spectrum_ed.filteredPickerKinds(&app.core, &kinds_buf) else &.{};
    const filter = if (app.core.view == .synth_fx_picker) synth_ed.activeFxFilter(&app.core) else spectrum_ed.activeFilter(&app.core);
    const available = overlayWidth();
    const count = if (app.core.view == .synth_fx_picker) synth_kinds.len else kinds.len;
    const total_count = count + if (app.core.view == .fx_picker) spectrum_ed.externalPickerCount(&app.core) else 0;
    if (total_count > 0) {
        if (app.core.view == .synth_fx_picker)
            app.core.synth_fx_picker_cursor = @intCast(@min(app.core.synth_fx_picker_cursor, total_count - 1))
        else
            app.core.fx_picker_cursor = @intCast(@min(app.core.fx_picker_cursor, total_count - 1));
    }
    // Single column, matching the TUI list's flat j/k stepping - see
    // drawInstrument's comment above.
    const width = available;
    if (app.core.view == .fx_picker) zgui.textColored(theme.fg2, "INTERNAL", .{});
    for (0..count) |i| {
        const kind = if (app.core.view == .synth_fx_picker) synth_ed.asFxKind(synth_kinds[i]) else kinds[i];
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "fx-picker-card-{d}", .{i}) catch continue;
        const selected = if (app.core.view == .synth_fx_picker) app.core.synth_fx_picker_cursor == i else app.core.fx_picker_cursor == i;
        var desc_buf: [96]u8 = undefined;
        const desc = std.fmt.bufPrint(&desc_buf, "{s}  |  {s}", .{ spectrum_ed.pickerCategory(kind), spectrum_ed.pickerDescription(kind) }) catch spectrum_ed.pickerDescription(kind);
        if (drawCard(id, spectrum_ed.unitLabel(kind), desc, fxAccent(kind), selected, width, filter)) {
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
    if (app.core.view == .fx_picker) {
        zgui.spacing();
        zgui.textColored(theme.fg2, "EXTERNAL", .{});
        zgui.sameLine(.{});
        zgui.textDisabled("CLAP", .{});
        const external_count = total_count - count;
        for (0..external_count) |external_i| {
            const plugin = spectrum_ed.externalPickerAt(&app.core, external_i).?;
            var id_buf: [48]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "fx-plugin-card-{d}", .{external_i}) catch continue;
            var desc_buf: [128]u8 = undefined;
            const desc = std.fmt.bufPrint(&desc_buf, "CLAP  |  {s}", .{plugin.vendor}) catch "CLAP";
            const ordinal = count + external_i;
            if (drawCard(id, plugin.name, desc, theme.focus, app.core.fx_picker_cursor == ordinal, width, filter)) {
                app.core.fx_picker_cursor = @intCast(ordinal);
                spectrum_ed.insertExternalFromPicker(&app.core, plugin);
            }
        }
        if (external_count == 0) zgui.textDisabled("No external effects found", .{});
    }
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

const fxAccent = style.fxKindAccent;

fn drawCard(id: [:0]const u8, label: []const u8, desc: []const u8, accent: [4]f32, selected: bool, width: f32, filter: []const u8) bool {
    const height: f32 = 62;
    const origin = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    if (selected) zgui.setScrollHereY(.{});
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(if (hovered) theme.bg3 else theme.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 4, origin[1] + height }, .col = color(accent), .rounding = 2 });
    if (selected) draw_list.addRect(.{ .pmin = .{ origin[0] + 1, origin[1] + 1 }, .pmax = .{ origin[0] + width - 1, origin[1] + height - 1 }, .col = color(theme.focus), .rounding = 4, .thickness = 2 });
    drawFuzzyLabel(draw_list, .{ origin[0] + 14, origin[1] + 10 }, label, filter, accent);
    draw_list.addText(.{ origin[0] + 14, origin[1] + 35 }, color(theme.fg3), "{s}", .{desc});
    return clicked;
}

fn drawFuzzyLabel(draw_list: anytype, origin: [2]f32, label: []const u8, filter: []const u8, accent: [4]f32) void {
    if (filter.len == 0 or label.len > 256) {
        draw_list.addText(origin, color(theme.fg0), "{s}", .{label});
        return;
    }
    var positions: [256]bool = undefined;
    fuzzy.matchPositions(filter, label, &positions);
    var x = origin[0];
    var start: usize = 0;
    while (start < label.len) {
        const matched = positions[start];
        var end = start + 1;
        while (end < label.len and positions[end] == matched) : (end += 1) {}
        const run = label[start..end];
        draw_list.addText(.{ x, origin[1] }, color(if (matched) accent else theme.fg0), "{s}", .{run});
        x += zgui.calcTextSize(run, .{})[0];
        start = end;
    }
}

pub fn drawPreset(app: anytype) void {
    var rows_buf: [preset_ed.max_display_rows]preset_ed.DisplayRow = undefined;
    const rows = preset_ed.buildDisplayRows(&app.core, &rows_buf);
    const count = preset_ed.entryCountOf(rows);
    const kind_accent = switch (app.core.preset_picker_kind) {
        .synth => theme.focus,
        .drum => theme.rhythm,
        .soundfont => theme.audio,
    };
    zgui.textColored(kind_accent, "{s}", .{app.core.preset_picker_kind.label()});
    zgui.sameLine(.{});
    zgui.textDisabled("{d} matches for track {d:0>2}", .{ count, app.core.preset_picker_track + 1 });
    const filter = preset_ed.activeFilter(&app.core);
    if (filter.len > 0) {
        zgui.sameLine(.{ .spacing = 14 });
        zgui.textColored(theme.audio, "filter: {s}", .{filter});
    }
    zgui.separator();
    zgui.textDisabled("/ filter   j/k move   enter choose   esc close   [ ] category   a audition", .{});
    zgui.spacing();
    var ordinal: usize = 0;
    for (rows, 0..) |row, row_index| switch (row) {
        .header => |header| {
            zgui.textColored(theme.fg2, "{s}", .{header});
            zgui.separator();
        },
        .entry => |entry| {
            var id_buf: [48]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "preset-card-{d}", .{row_index}) catch continue;
            const selected = app.core.preset_picker_cursor == ordinal;
            // Soundfont entries carry no author text (no user/factory split
            // for presets inside a loaded font) - show the program number
            // in that slot instead, formatted here since it only needs to
            // live for this one draw call.
            var desc_buf: [16]u8 = undefined;
            const desc = if (entry.program) |program|
                std.fmt.bufPrint(&desc_buf, "prog {d}", .{program}) catch entry.author
            else
                entry.author;
            if (drawCard(id, entry.name, desc, kind_accent, selected, overlayWidth(), filter)) {
                app.core.preset_picker_cursor = ordinal;
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
            ordinal += 1;
        },
    };
}

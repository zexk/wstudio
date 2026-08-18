const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const icons = @import("../../ui/icons.zig");
const widgets = @import("../widgets.zig");
const spectrum_ed = @import("../../ui/editors/fx_editor.zig");
const preset_ed = @import("../../ui/editors/preset_picker.zig");
const fuzzy = @import("../../ui/fuzzy.zig");
const style = @import("../style.zig");
const app_mod = @import("../../ui/app.zig");
const scroll = @import("../scroll.zig");

const color = style.color;
const theme = &style.palette;

/// Paint a Telescope-style modal in its own top-level ImGui window so its
/// backdrop, panel, and entries always render above the workspace. A real
/// borderless child sized to the panel's inner area makes
/// `drawInstrument`/`drawFx`/`drawPreset`'s entries actual children of the
/// panel - clipped and scrollable to it - instead of raw draw-list content
/// that happily overruns the panel's edges. Pair with `endOverlay`.
pub fn beginOverlay() void {
    const window_pos = zgui.getWindowPos();
    const window_size = zgui.getWindowSize();
    zgui.setNextWindowPos(.{ .x = window_pos[0], .y = window_pos[1], .cond = .always });
    zgui.setNextWindowSize(.{ .w = window_size[0], .h = window_size[1], .cond = .always });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = .{ 0, 0, 0, 0.68 } });
    _ = zgui.begin("Picker Overlay", .{ .flags = .{
        .no_title_bar = true,
        .no_move = true,
        .no_resize = true,
        .no_collapse = true,
        .no_docking = true,
        .no_saved_settings = true,
        .no_scrollbar = true,
        .no_scroll_with_mouse = true,
    } });
    zgui.popStyleColor(.{});
    const draw_list = zgui.getWindowDrawList();

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
        .rounding = style.panel_rounding,
    });
    draw_list.addRect(.{
        .pmin = panel,
        .pmax = .{ panel[0] + panel_w, panel[1] + panel_h },
        .col = color(theme.focus),
        .rounding = style.panel_rounding,
        .thickness = 1,
    });
    zgui.setCursorScreenPos(.{ panel[0] + 18, panel[1] + 16 });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = .{ 0, 0, 0, 0 } });
    _ = zgui.beginChild("telescope-panel-content", .{ .w = panel_w - 36, .h = panel_h - 32 });
}

pub fn endOverlay() void {
    // Still inside the panel child - the one that scrolls the entry list -
    // so this is where the cursor row has to be brought on screen.
    scroll.scrollFocusIntoView();
    zgui.endChild();
    zgui.popStyleColor(.{});
    zgui.end();
}

/// Row width inside the overlay panel. `pub` so the file browser - a picker
/// in everything but name - lays its entries out on the same measure.
pub fn overlayWidth() f32 {
    return @min(zgui.getContentRegionAvail()[0], 884);
}

/// Every picker overlay opens the same way the TUI's does: what it does,
/// what it acts on, how many rows survived the filter, the filter itself,
/// and a one-line subtitle. `pub` so the file browser heads up the same way.
pub fn header(accent: [4]f32, title: []const u8, target: []const u8, subtitle: []const u8, count: usize, filter: []const u8) void {
    widgets.coloredTitle(accent, "{s}", .{title});
    if (target.len > 0) {
        zgui.sameLine(.{});
        zgui.textColored(theme.audio, "\"{s}\"", .{target});
    }
    zgui.sameLine(.{});
    zgui.textDisabled("{d} match{s}", .{ count, if (count == 1) "" else "es" });
    if (filter.len > 0) {
        zgui.sameLine(.{ .spacing = 14 });
        zgui.textColored(theme.modulation, "filter: {s}", .{filter});
    }
    if (subtitle.len > 0) zgui.textDisabled("{s}", .{subtitle});
    zgui.separator();
}

/// The "nothing here" line the picker overlays share, worded like the TUI's
/// (tui/views/picker.zig): a filter that hid everything explains itself,
/// otherwise the list says what it is missing. `pub` so the param picker and
/// the file browser fall back the same way.
pub fn emptyRow(hidden_by_filter: bool, filter: []const u8, empty_label: []const u8) void {
    if (hidden_by_filter) {
        zgui.textDisabled("no match for /{s}", .{filter});
    } else {
        zgui.textDisabled("{s}", .{empty_label});
    }
}

pub fn selectInstrument(app: anytype, ordinal: usize, now_ns: i96) void {
    app.core.clickInstrumentPickerItem(ordinal, now_ns);
}

pub fn dismiss(app: anytype, now_ns: i96) void {
    app.core.handleKey(.escape, now_ns);
}

pub fn drawInstrument(app: anytype) void {
    var item_buf: [app_mod.instrument_picker_items.len]app_mod.InstrumentPickerItem = undefined;
    const items = app.core.filteredInstrumentPickerItems(&item_buf);
    const filter = app.core.activeInstrumentFilter();
    header(
        theme.focus,
        if (app.core.picker_replace) "REPLACE INSTRUMENT" else "INSERT INSTRUMENT",
        app.core.pickerTargetName(),
        if (app.core.picker_replace) "Keeps notes when instrument types match" else "Choose track sound",
        items.len + app.core.filteredInstrumentPluginCount(),
        filter,
    );
    widgets.hoverHelp("/ filter  j/k move  enter insert  esc cancel");
    zgui.spacing();
    // Single column: `j`/`k` move the shared picker cursor by a flat +/-1,
    // same as the TUI's list - a multi-column card grid would make "down"
    // jump sideways instead.
    const width = overlayWidth();
    zgui.textColored(theme.fg2, "INTERNAL", .{});
    for (items, 0..) |entry, i| {
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "instrument-card-{d}", .{i}) catch continue;
        const accent = switch (entry.kind) {
            .poly_synth => theme.focus,
            .sampler, .soundfont, .acoustic => theme.audio,
            .drum_machine => theme.rhythm,
            .slicer => theme.modulation,
            else => theme.focus,
        };
        if (drawCard(id, entry.label, entry.description, accent, app.core.picker_cursor == i, width, filter)) {
            selectInstrument(app, i, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
    zgui.spacing();
    zgui.textColored(theme.fg2, "EXTERNAL", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("CLAP / VST3", .{});
    drawPluginScanButton(app);
    const external_count = app.core.filteredInstrumentPluginCount();
    var clipper = zgui.ListClipper.init();
    clipper.begin(@intCast(external_count), card_pitch);
    defer clipper.end();
    if (app.core.picker_cursor >= items.len and app.core.picker_cursor < items.len + external_count)
        clipper.includeItemsByIndex(@intCast(app.core.picker_cursor - items.len), @intCast(app.core.picker_cursor - items.len + 1));
    while (clipper.step()) {
        for (@intCast(clipper.DisplayStart)..@intCast(clipper.DisplayEnd)) |external_i| {
            const plugin = app.core.filteredInstrumentPluginAt(external_i).?;
            var id_buf: [48]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "instrument-plugin-card-{d}", .{external_i}) catch continue;
            var desc_buf: [128]u8 = undefined;
            const format = ws.plugin_catalog.formatLabel(plugin.format);
            const desc = std.fmt.bufPrint(&desc_buf, "{s}  |  {s}", .{ format, plugin.vendor }) catch format;
            const ordinal = items.len + external_i;
            const clicked = drawCard(id, plugin.name, desc, theme.focus, app.core.picker_cursor == ordinal, width, filter);
            if (clicked) {
                selectInstrument(app, ordinal, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
                return;
            }
        }
    }
    if (external_count == 0) emptyRow(items.len == 0 and filter.len > 0, filter, "No external instruments found");
}

pub fn drawFx(app: anytype) void {
    var kinds_buf: [spectrum_ed.picker_kinds.len]ws.FxKind = undefined;
    const kinds = spectrum_ed.filteredPickerKinds(&app.core, &kinds_buf);
    const filter = spectrum_ed.activeFilter(&app.core);
    const available = overlayWidth();
    const count = kinds.len;
    const total_count = count + spectrum_ed.externalPickerCount(&app.core);
    if (total_count > 0) {
        app.core.fx_picker_cursor = @intCast(@min(app.core.fx_picker_cursor, total_count - 1));
    }
    header(theme.modulation, "INSERT EFFECT", app.core.pickerTargetName(), "Inserted after the focused unit", total_count, filter);
    widgets.hoverHelp("/ filter  j/k move  enter insert  esc cancel");
    zgui.spacing();
    // Single column, matching the TUI list's flat j/k stepping - see
    // drawInstrument's comment above.
    const width = available;
    zgui.textColored(theme.fg2, "INTERNAL", .{});
    for (0..count) |i| {
        const kind = kinds[i];
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "fx-picker-card-{d}", .{i}) catch continue;
        const selected = app.core.fx_picker_cursor == i;
        var desc_buf: [96]u8 = undefined;
        const desc = std.fmt.bufPrint(&desc_buf, "{s}  |  {s}", .{ spectrum_ed.pickerCategory(kind), spectrum_ed.pickerDescription(kind) }) catch spectrum_ed.pickerDescription(kind);
        if (drawCard(id, spectrum_ed.unitLabel(kind), desc, fxAccent(kind), selected, width, filter)) {
            app.core.clickFxPickerItem(i, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
    zgui.spacing();
    zgui.textColored(theme.fg2, "EXTERNAL", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("CLAP / VST3", .{});
    drawPluginScanButton(app);
    const external_count = total_count - count;
    var clipper = zgui.ListClipper.init();
    clipper.begin(@intCast(external_count), card_pitch);
    defer clipper.end();
    if (app.core.fx_picker_cursor >= count and app.core.fx_picker_cursor < total_count)
        clipper.includeItemsByIndex(@intCast(app.core.fx_picker_cursor - count), @intCast(app.core.fx_picker_cursor - count + 1));
    while (clipper.step()) {
        for (@intCast(clipper.DisplayStart)..@intCast(clipper.DisplayEnd)) |external_i| {
            const plugin = spectrum_ed.externalPickerAt(&app.core, external_i).?;
            var id_buf: [48]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "fx-plugin-card-{d}", .{external_i}) catch continue;
            var desc_buf: [128]u8 = undefined;
            const format = ws.plugin_catalog.formatLabel(plugin.format);
            const desc = std.fmt.bufPrint(&desc_buf, "{s}  |  {s}", .{ format, plugin.vendor }) catch format;
            const ordinal = count + external_i;
            const clicked = drawCard(id, plugin.name, desc, theme.focus, app.core.fx_picker_cursor == ordinal, width, filter);
            if (clicked) {
                app.core.clickFxPickerItem(ordinal, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
                return;
            }
        }
    }
    if (external_count == 0) emptyRow(total_count == 0 and filter.len > 0, filter, "No external effects found");
}

fn drawPluginScanButton(app: anytype) void {
    zgui.sameLine(.{ .spacing = 14 });
    if (app.pluginScanProgress()) |progress| {
        zgui.progressBar(.{ .fraction = progress.fraction, .w = 150, .overlay = progress.label });
    } else if (widgets.iconButton(icons.rescan ++ "##external-plugins", "Rescan external plugins")) {
        app.startPluginScan();
    }
}

const fxAccent = style.fxKindAccent;

/// Width of a card's left accent bar.
const accent_bar_w: f32 = 4;
const card_pitch: f32 = 70;

fn drawCard(id: [:0]const u8, label: []const u8, desc: []const u8, accent: [4]f32, selected: bool, width: f32, filter: []const u8) bool {
    const height: f32 = 62;
    const origin = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    // Every card offers its label to the clipboard, not just the plugin rows
    // that used to ask for it at the call site.
    widgets.copyContext(label);
    // Pager-style, not `setScrollHereY`: re-centring every frame would pin
    // the list to the cursor and leave the wheel with nothing to do.
    scroll.noteFocusRow(selected, origin[1], height);
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(if (hovered) theme.bg3 else theme.bg2), .rounding = style.item_rounding });
    // The accent bar is the card's own rect clipped to its left edge, not a
    // 4px rect of its own: ImGui clamps a corner radius to half the smaller
    // side, so a narrow rect rounds tighter than the card behind it and its
    // square corners poke past the card's rounded ones.
    draw_list.pushClipRect(.{ .pmin = origin, .pmax = .{ origin[0] + accent_bar_w, origin[1] + height }, .intersect_with_current = true });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(accent), .rounding = style.item_rounding });
    draw_list.popClipRect();
    if (selected) draw_list.addRect(.{ .pmin = .{ origin[0] + 1, origin[1] + 1 }, .pmax = .{ origin[0] + width - 1, origin[1] + height - 1 }, .col = color(theme.focus), .rounding = style.item_rounding, .thickness = 2 });
    drawFuzzyLabel(draw_list, .{ origin[0] + 14, origin[1] + 10 }, label, filter, accent, theme.fg0);
    draw_list.addText(.{ origin[0] + 14, origin[1] + 35 }, color(theme.fg3), "{s}", .{desc});
    return clicked;
}

/// Paint `label`, tinting the bytes the `/` filter matched - the GUI's
/// answer to the TUI's reverse-video match highlight (tui/views/browser.zig),
/// off the same `ui/fuzzy.zig` positions. Shared with the file browser.
pub fn drawFuzzyLabel(draw_list: anytype, origin: [2]f32, label: []const u8, filter: []const u8, accent: [4]f32, base: [4]f32) void {
    if (filter.len == 0 or label.len > 256) {
        draw_list.addText(origin, color(base), "{s}", .{label});
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
        draw_list.addText(.{ x, origin[1] }, color(if (matched) accent else base), "{s}", .{run});
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
        .soundfont, .acoustic => theme.audio,
    };
    const filter = preset_ed.activeFilter(&app.core);
    header(kind_accent, app.core.preset_picker_kind.label(), app.core.pickerTargetName(), "", count, filter);
    widgets.hoverHelp(if (app.core.preset_picker_kind == .drum)
        "/ filter  j/k move  enter choose  esc close  [ ] category"
    else
        "/ filter  j/k move  enter choose  esc close  [ ] category  a audition");
    zgui.spacing();
    if (count == 0) {
        emptyRow(filter.len > 0, filter, "No presets");
        return;
    }
    var ordinal: usize = 0;
    for (rows, 0..) |row, row_index| switch (row) {
        .header => |section| {
            zgui.textColored(theme.fg2, "{s}", .{section});
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
            const clicked = drawCard(id, entry.name, desc, kind_accent, selected, overlayWidth(), filter);
            if (clicked) {
                app.core.clickPresetPickerItem(ordinal, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
            ordinal += 1;
        },
    };
}

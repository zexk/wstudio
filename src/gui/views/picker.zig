const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const spectrum_ed = @import("../../ui/editors/spectrum.zig");
const preset_ed = @import("../../ui/editors/preset_picker.zig");
const synth_ed = @import("../../ui/editors/synth.zig");
const style = @import("../style.zig");

const color = style.color;
const patina = &style.palette;

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
        .col = color(patina.bg1),
        .rounding = 6,
    });
    draw_list.addRect(.{
        .pmin = panel,
        .pmax = .{ panel[0] + panel_w, panel[1] + panel_h },
        .col = color(patina.focus),
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
    zgui.textColored(patina.focus, "ADD INSTRUMENT", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("Choose the track's sound source", .{});
    zgui.separator();
    const entries = [_]struct { label: []const u8, desc: []const u8, kind: ws.InstrumentKind, accent: [4]f32 }{
        .{ .label = "POLY SYNTH", .desc = "SYNTHESIS  POLY  MODULATION", .kind = .poly_synth, .accent = patina.focus },
        .{ .label = "SAMPLER", .desc = "AUDIO  KEYMAP  ENVELOPE", .kind = .sampler, .accent = patina.audio },
        .{ .label = "DRUM MACHINE", .desc = "PADS  VELOCITY  SEQUENCER", .kind = .drum_machine, .accent = patina.rhythm },
        .{ .label = "SLICER", .desc = "AUDIO  SLICES  SEQUENCER", .kind = .slicer, .accent = patina.modulation },
        .{ .label = "SOUNDFONT", .desc = "SF2  MULTI-TIMBRAL  PRESETS", .kind = .soundfont, .accent = patina.audio },
    };
    // Single column: `j`/`k` move the shared picker cursor by a flat +/-1,
    // same as the TUI's list - a multi-column card grid would make "down"
    // jump sideways instead.
    const width = overlayWidth();
    zgui.textColored(patina.fg2, "INTERNAL", .{});
    for (entries, 0..) |entry, i| {
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "instrument-card-{d}", .{i}) catch continue;
        if (drawCard(id, entry.label, entry.desc, entry.accent, app.core.picker_cursor == i, width)) {
            app.core.picker_cursor = @intCast(i);
            app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
    zgui.spacing();
    zgui.textColored(patina.fg2, "EXTERNAL", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("CLAP", .{});
    const external_count = app.core.external_plugins.count(.instrument);
    for (0..external_count) |external_i| {
        const plugin = app.core.external_plugins.at(.instrument, external_i).?;
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "instrument-plugin-card-{d}", .{external_i}) catch continue;
        var desc_buf: [128]u8 = undefined;
        const desc = std.fmt.bufPrint(&desc_buf, "CLAP  |  {s}", .{plugin.vendor}) catch "CLAP";
        const ordinal = entries.len + external_i;
        if (drawCard(id, plugin.name, desc, patina.focus, app.core.picker_cursor == ordinal, width)) {
            app.core.picker_cursor = @intCast(ordinal);
            app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
    if (external_count == 0) zgui.textDisabled("No external instruments found", .{});
}

pub fn drawFx(app: anytype) void {
    zgui.textColored(patina.modulation, "ADD EFFECT", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("Inserted after the focused unit", .{});
    zgui.separator();
    var synth_buf: [14]ws.dsp.synth.FxUnitKind = undefined;
    const synth_kinds = if (app.core.view == .synth_fx_picker) synth_ed.filteredSynthFxPickerKinds(&app.core, &synth_buf) else &.{};
    const kinds = spectrum_ed.picker_kinds;
    const available = overlayWidth();
    const count = if (app.core.view == .synth_fx_picker) synth_kinds.len else kinds.len;
    // Single column, matching the TUI list's flat j/k stepping - see
    // drawInstrument's comment above.
    const width = available;
    if (app.core.view == .fx_picker) zgui.textColored(patina.fg2, "INTERNAL", .{});
    for (0..count) |i| {
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
    if (app.core.view == .fx_picker) {
        zgui.spacing();
        zgui.textColored(patina.fg2, "EXTERNAL", .{});
        zgui.sameLine(.{});
        zgui.textDisabled("CLAP", .{});
        const external_count = spectrum_ed.externalPickerCount(&app.core);
        for (0..external_count) |external_i| {
            const plugin = spectrum_ed.externalPickerAt(&app.core, external_i).?;
            var id_buf: [48]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "fx-plugin-card-{d}", .{external_i}) catch continue;
            var desc_buf: [128]u8 = undefined;
            const desc = std.fmt.bufPrint(&desc_buf, "CLAP  |  {s}", .{plugin.vendor}) catch "CLAP";
            const ordinal = count + external_i;
            if (drawCard(id, plugin.name, desc, patina.focus, app.core.fx_picker_cursor == ordinal, width)) {
                app.core.fx_picker_cursor = @intCast(ordinal);
                spectrum_ed.insertExternalFromPicker(&app.core, plugin);
            }
        }
        if (external_count == 0) zgui.textDisabled("No external effects found", .{});
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
    if (selected) zgui.setScrollHereY(.{});
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
    const kind_label = switch (app.core.preset_picker_kind) {
        .synth => "SYNTH PRESETS",
        .drum => "DRUM KITS",
        .soundfont => "SOUNDFONT PRESETS",
    };
    const kind_accent = switch (app.core.preset_picker_kind) {
        .synth => patina.focus,
        .drum => patina.rhythm,
        .soundfont => patina.audio,
    };
    zgui.textColored(kind_accent, "{s}", .{kind_label});
    zgui.sameLine(.{});
    zgui.textDisabled("{d} matches for track {d:0>2}", .{ count, app.core.preset_picker_track + 1 });
    const filter = preset_ed.activeFilter(&app.core);
    if (filter.len > 0) {
        zgui.sameLine(.{ .spacing = 14 });
        zgui.textColored(patina.audio, "filter: {s}", .{filter});
    }
    zgui.separator();
    zgui.textDisabled("/ filter   j/k move   enter choose   esc close   [ ] category   a audition", .{});
    zgui.spacing();
    var ordinal: usize = 0;
    for (rows, 0..) |row, row_index| switch (row) {
        .header => |header| {
            zgui.textColored(patina.fg2, "{s}", .{header});
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
            if (drawCard(id, entry.name, desc, kind_accent, selected, overlayWidth())) {
                app.core.preset_picker_cursor = ordinal;
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
            ordinal += 1;
        },
    };
}

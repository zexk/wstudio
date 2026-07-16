const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const spectrum_ed = @import("../../tui/editors/spectrum.zig");
const synth_ed = @import("../../tui/editors/synth.zig");
const style = @import("../style.zig");

const color = style.color;
const umbra = style.umbra;

pub fn drawInstrument(app: anytype) void {
    zgui.textColored(umbra.iris, "ADD INSTRUMENT", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("Choose the track's sound source", .{});
    zgui.separator();
    const entries = [_]struct { label: []const u8, desc: []const u8, kind: ws.InstrumentKind, accent: [4]f32 }{
        .{ .label = "POLY SYNTH", .desc = "Oscillators, filters, modulation", .kind = .poly_synth, .accent = umbra.iris },
        .{ .label = "SAMPLER", .desc = "Map and shape a single sample", .kind = .sampler, .accent = umbra.cyan },
        .{ .label = "DRUM MACHINE", .desc = "Velocity-aware pad sequencer", .kind = .drum_machine, .accent = umbra.yellow },
        .{ .label = "SLICER", .desc = "Cut audio into playable slices", .kind = .slicer, .accent = umbra.mauve },
    };
    const gap: f32 = 8;
    const width = (zgui.getContentRegionAvail()[0] - gap) / 2;
    for (entries, 0..) |entry, i| {
        if (i % 2 == 1) zgui.sameLine(.{ .spacing = gap });
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "instrument-card-{d}", .{i}) catch continue;
        if (drawCard(id, entry.label, entry.desc, entry.accent, app.core.picker_cursor == i, width)) {
            app.core.picker_cursor = @intCast(i);
            app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
}

pub fn drawFx(app: anytype) void {
    zgui.textColored(umbra.mauve, "ADD EFFECT", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("Inserted after the focused unit", .{});
    zgui.separator();
    var synth_buf: [14]ws.dsp.synth.FxUnitKind = undefined;
    const synth_kinds = if (app.core.view == .synth_fx_picker) synth_ed.filteredSynthFxPickerKinds(&app.core, &synth_buf) else &.{};
    const kinds = spectrum_ed.picker_kinds;
    const gap: f32 = 8;
    const width = (zgui.getContentRegionAvail()[0] - gap) / 2;
    const count = if (app.core.view == .synth_fx_picker) synth_kinds.len else kinds.len;
    for (0..count) |i| {
        const kind = if (app.core.view == .synth_fx_picker) synth_ed.asFxKind(synth_kinds[i]) else kinds[i];
        if (i % 2 == 1) zgui.sameLine(.{ .spacing = gap });
        var id_buf: [48]u8 = undefined;
        const id = std.fmt.bufPrintZ(&id_buf, "fx-picker-card-{d}", .{i}) catch continue;
        const selected = if (app.core.view == .synth_fx_picker) app.core.synth_fx_picker_cursor == i else app.core.fx_picker_cursor == i;
        if (drawCard(id, spectrum_ed.unitLabel(kind), fxDescription(kind), fxAccent(kind), selected, width)) {
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

fn activateFx(app: anytype, kind: ws.FxKind) void {
    const rack = app.core.session.racks.items[app.core.cursor];
    switch (app.core.fx_picker_return) {
        .track_spectrum, .master_spectrum, .group_spectrum => {
            spectrum_ed.insertFromPicker(&app.core, kind);
            app.closePicker(app.core.view);
        },
        else => {
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
    };
}

fn fxAccent(kind: ws.FxKind) [4]f32 {
    return switch (kind) {
        .gate, .comp, .mb_comp, .ott => umbra.red,
        .eq => umbra.yellow,
        .sat, .crush, .tape => umbra.mauve,
        .chorus, .flanger, .phaser, .freq_shift => umbra.iris,
        .delay, .reverb => umbra.cyan,
    };
}

fn drawCard(id: [:0]const u8, label: []const u8, desc: []const u8, accent: [4]f32, selected: bool, width: f32) bool {
    const height: f32 = 62;
    const origin = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(if (selected) umbra.bg4 else if (hovered) umbra.bg3 else umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 4, origin[1] + height }, .col = color(accent), .rounding = 2 });
    draw_list.addText(.{ origin[0] + 14, origin[1] + 10 }, color(if (selected) accent else umbra.fg0), "{s}", .{label});
    draw_list.addText(.{ origin[0] + 14, origin[1] + 35 }, color(umbra.fg3), "{s}", .{desc});
    return clicked;
}

pub fn drawPreset(app: anytype) void {
    zgui.textColored(umbra.iris, "SYNTH PRESETS", .{});
    zgui.sameLine(.{});
    zgui.textDisabled("Load a complete sound", .{});
    zgui.separator();
    const synth = switch (app.core.session.racks.items[app.core.cursor].instrument) {
        .poly_synth => |*s| s,
        else => {
            zgui.textDisabled("Select a Synth track to use presets.", .{});
            return;
        },
    };
    if (zgui.beginChild("presets", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (ws.dsp.synth_presets.presets, 0..) |preset, i| {
            var id_buf: [48]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "preset-card-{d}", .{i}) catch continue;
            const selected = app.core.preset_picker_cursor == i;
            if (drawCard(id, preset.name, preset.category, umbra.iris, selected, zgui.getContentRegionAvail()[0])) {
                app.core.preset_picker_cursor = i;
                _ = app.core.session.engine.send(.stop);
                synth.applyPatch(preset.patch);
                app.closePicker(.synth_editor);
            }
        }
    }
    zgui.endChild();
}

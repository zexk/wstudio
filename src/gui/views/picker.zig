const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const spectrum_ed = @import("../../tui/editors/spectrum.zig");

pub fn drawInstrument(app: anytype) void {
    zgui.textDisabled("INSTRUMENT PICKER", .{});
    const entries = [_]struct { label: [:0]const u8, kind: ws.InstrumentKind }{
        .{ .label = "Synth", .kind = .poly_synth },
        .{ .label = "Sampler", .kind = .sampler },
        .{ .label = "Drum Machine", .kind = .drum_machine },
        .{ .label = "Slicer", .kind = .slicer },
    };
    zgui.textDisabled("j/k move   enter insert   esc cancel", .{});
    for (entries, 0..) |entry, i| {
        if (zgui.selectable(entry.label, .{ .selected = app.core.picker_cursor == i, .w = 240, .h = 42 })) {
            app.core.picker_cursor = @intCast(i);
            app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        }
    }
}

pub fn drawFx(app: anytype) void {
    zgui.textDisabled("FX PICKER", .{});
    const rack = app.core.session.racks.items[app.core.cursor];
    const kinds = std.meta.tags(ws.FxKind);
    for (kinds, 0..) |kind, i| {
        var label_buf: [48]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{s}##fx-{d}", .{ @tagName(kind), i }) catch continue;
        if (zgui.button(label, .{ .w = 180 })) {
            switch (app.core.fx_picker_return) {
                .track_spectrum, .master_spectrum, .group_spectrum => {
                    spectrum_ed.insertFromPicker(&app.core, kind);
                    app.closePicker(app.core.view);
                },
                else => {
                    _ = rack.fx.insert(app.core.session.allocator, rack.fx.units.items.len, kind, app.core.session.project.sample_rate) catch continue;
                    app.core.session.syncTrackChain(@intCast(app.core.cursor), rack);
                    app.closePicker(.track_spectrum);
                },
            }
        }
        zgui.sameLine(.{});
    }
    zgui.newLine();
}

pub fn drawPreset(app: anytype) void {
    zgui.textDisabled("SYNTH PRESET PICKER", .{});
    const synth = switch (app.core.session.racks.items[app.core.cursor].instrument) {
        .poly_synth => |*s| s,
        else => {
            zgui.textDisabled("Select a Synth track to use presets.", .{});
            return;
        },
    };
    if (zgui.beginChild("presets", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (ws.dsp.synth_presets.presets) |preset| {
            var label_buf: [128]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s}  [{s}]", .{ preset.name, preset.category }) catch continue;
            if (zgui.selectable(label, .{})) {
                _ = app.core.session.engine.send(.stop);
                synth.applyPatch(preset.patch);
                app.closePicker(.synth_editor);
            }
        }
    }
    zgui.endChild();
}

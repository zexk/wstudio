//! Drum machine grid: title strip plus the shared step-grid renderer.

const ws = @import("wstudio");
const icons = @import("../../ui/icons.zig");
const gui_style = @import("../style.zig");
const step_grid = @import("step_grid.zig");
const zgui = @import("zgui");

const patina = &gui_style.palette;

pub fn draw(app: anytype) void {
    const track = app.core.drum_track;
    if (track >= app.core.session.racks.items.len) return;
    const rack = app.core.session.racks.items[track];
    const drum = switch (rack.instrument) {
        .drum_machine => |*d| d,
        else => {
            zgui.textDisabled("Select a Drum Machine track.", .{});
            return;
        },
    };
    const snap = app.core.session.engine.uiSnapshot();
    const play_step: ?usize = if (snap.playing) drum.currentStep() else null;
    drawTitle(app, drum);
    zgui.spacing();
    step_grid.draw(
        .drum,
        drum,
        drum.pads.len,
        drum.step_count,
        play_step,
        &app.core.drum_cursor,
        if (app.core.modal.mode == .visual) app.core.drum_visual_anchor else null,
    );
}

fn drawTitle(app: anytype, drum: *const ws.dsp.DrumMachine) void {
    const pads_per_bank = 8;
    const bank_count = (ws.dsp.DrumMachine.max_pads + pads_per_bank - 1) / pads_per_bank;
    zgui.textDisabled(icons.drum ++ "  DRUMS", .{});
    zgui.sameLine(.{});
    zgui.text("\"{s}\"", .{app.core.session.project.tracks.items[app.core.drum_track].name});
    zgui.sameLine(.{});
    zgui.textColored(patina.rhythm, "Pattern {c}", .{'A' + drum.variant});
    zgui.sameLine(.{});
    zgui.textDisabled("Variation {d}/{d}", .{ drum.variant + 1, drum.variant_count });
    zgui.sameLine(.{});
    zgui.textDisabled("Bank {d}/{d}", .{ app.core.drum_cursor[0] / pads_per_bank + 1, bank_count });
}

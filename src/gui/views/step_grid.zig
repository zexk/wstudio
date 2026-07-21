const std = @import("std");
const zgui = @import("zgui");
const style = @import("../style.zig");
const shared_step_grid = @import("../../ui/editors/step_grid.zig");

const color = style.color;
const theme = &style.palette;

pub const Kind = enum { drum, slicer };

pub fn draw(
    comptime kind: Kind,
    instrument: anytype,
    total_rows: usize,
    step_count_raw: anytype,
    play_step: ?usize,
    cursor: anytype,
    visual_anchor: anytype,
    /// Which state a click-and-hold paints every newly-entered cell to
    /// (mirrors the TUI's `app.drum_paint_state`/`slicer_paint_state`, and
    /// is in fact the very same field - both frontends share `ui/app.zig`'s
    /// `App`). Null between drags.
    paint_state: *?bool,
) void {
    const step_count: usize = @max(1, step_count_raw);
    const row_count = @min(@as(usize, 12), total_rows);
    const cursor_row = @min(@as(usize, cursor[0]), total_rows -| 1);
    const row_start = if (row_count == 0) 0 else cursor_row / row_count * row_count;
    const row_end = @min(total_rows, row_start + row_count);
    const gutter_w: f32 = 132;
    const ruler_h: f32 = 27;
    const available = zgui.getContentRegionAvail();
    const row_h: f32 = if (row_count == 0)
        32
    else
        std.math.clamp((available[1] - ruler_h) / @as(f32, @floatFromInt(row_count)), 32, if (kind == .drum) 54 else 44);
    const canvas_w = @max(360, available[0]);
    const canvas_h = ruler_h + row_h * @as(f32, @floatFromInt(row_count));
    const origin = zgui.getCursorScreenPos();
    const id = if (kind == .drum) "drum-grid-canvas" else "slicer-grid-canvas";
    _ = zgui.invisibleButton(id, .{ .w = canvas_w, .h = canvas_h, .flags = .{ .mouse_button_left = true, .mouse_button_right = true } });
    const activated = zgui.isItemActivated();
    const active = zgui.isItemActive();
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    const grid_x = origin[0] + gutter_w;
    const grid_y = origin[1] + ruler_h;
    const grid_w = canvas_w - gutter_w;
    const cell_w = grid_w / @as(f32, @floatFromInt(step_count));
    const steps_per_beat: usize = if (kind == .drum) instrument.steps_per_beat else 4;
    const cursor_step = @min(@as(usize, cursor[1]), step_count - 1);
    const accent = if (kind == .drum) theme.rhythm else theme.audio;
    const vel_full = @TypeOf(instrument.*).vel_full;

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(theme.bg0) });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, grid_y }, .col = color(theme.bg2) });
    draw_list.addRectFilled(.{
        .pmin = .{ grid_x + @as(f32, @floatFromInt(cursor_step)) * cell_w, origin[1] },
        .pmax = .{ grid_x + @as(f32, @floatFromInt(cursor_step + 1)) * cell_w, grid_y },
        .col = color(.{ accent[0], accent[1], accent[2], 0.18 }),
    });
    draw_list.addText(.{ origin[0] + 9, origin[1] + 5 }, color(theme.fg3), "{s} {d}-{d}  /  {d}", .{
        if (kind == .drum) "PADS" else "SLICES",
        if (row_count == 0) 0 else row_start + 1,
        row_end,
        total_rows,
    });
    for (row_start..row_end, 0..) |row, display_row| {
        const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
        const selected = row == cursor_row;
        draw_list.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ grid_x, y + row_h }, .col = color(if (selected) theme.bg4 else if (row % 2 == 0) theme.bg2 else theme.bg1) });
        draw_list.addRectFilled(.{ .pmin = .{ grid_x, y }, .pmax = .{ origin[0] + canvas_w, y + row_h }, .col = color(if (row % 2 == 0) theme.bg1 else theme.bg0) });
        if (selected) draw_list.addRectFilled(.{ .pmin = .{ origin[0], y + 4 }, .pmax = .{ origin[0] + 4, y + row_h - 4 }, .col = color(accent), .rounding = 2 });
        if (kind == .drum) {
            const choke = instrument.choke_group[row];
            if (instrument.pads[row]) |*sample|
                draw_list.addText(.{ origin[0] + 9, y + 8 }, color(if (selected) theme.fg0 else theme.fg1), "{d:0>2}  {s}  C{d}", .{ row + 1, sample.clipName(), choke })
            else
                draw_list.addText(.{ origin[0] + 9, y + 8 }, color(if (selected) theme.fg2 else theme.fg3), "{d:0>2}  empty pad", .{row + 1});
        } else {
            const slice = instrument.slices[row];
            draw_list.addText(.{ origin[0] + 9, y + 8 }, color(if (selected) theme.fg0 else theme.fg1), "{d:0>2}  {d:.0}-{d:.0}% C{d}", .{ row + 1, slice.start_norm * 100, slice.end_norm * 100, instrument.choke_group[row] });
        }
        draw_list.addLine(.{ .p1 = .{ origin[0], y + row_h }, .p2 = .{ origin[0] + canvas_w, y + row_h }, .col = color(theme.line), .thickness = 1 });
    }

    for (0..step_count) |step| {
        const beat = step / steps_per_beat;
        if (beat % 2 == 0) continue;
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        draw_list.addRectFilled(.{
            .pmin = .{ x, grid_y },
            .pmax = .{ x + cell_w, origin[1] + canvas_h },
            .col = color(.{ theme.fg0[0], theme.fg0[1], theme.fg0[2], 0.018 }),
        });
    }

    if (visual_anchor) |anchor_raw| {
        const anchor = @min(@as(usize, anchor_raw), step_count - 1);
        const lo = @min(anchor, cursor_step);
        const hi = @max(anchor, cursor_step);
        const x1 = grid_x + @as(f32, @floatFromInt(lo)) * cell_w;
        const x2 = grid_x + @as(f32, @floatFromInt(hi + 1)) * cell_w;
        draw_list.addRectFilled(.{
            .pmin = .{ x1, grid_y },
            .pmax = .{ x2, origin[1] + canvas_h },
            .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.12 }),
        });
        draw_list.addRect(.{
            .pmin = .{ x1 + 1, grid_y + 1 },
            .pmax = .{ x2 - 1, origin[1] + canvas_h - 1 },
            .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.55 }),
            .thickness = 1,
        });
    }

    for (0..step_count + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        const on_beat = step % steps_per_beat == 0;
        const on_bar = step % (steps_per_beat * 4) == 0;
        draw_list.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) theme.fg3 else if (on_beat) theme.bg5 else theme.line_soft), .thickness = if (on_bar) 2 else if (on_beat) 1.5 else 1 });
        if (on_beat and step < step_count) draw_list.addText(.{ x + 5, origin[1] + 5 }, color(theme.fg2), "{d}", .{step / steps_per_beat + 1});
    }

    if (play_step) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step % step_count)) * cell_w;
        draw_list.addRectFilled(.{ .pmin = .{ x, origin[1] }, .pmax = .{ x + cell_w, grid_y }, .col = color(.{ theme.danger[0], theme.danger[1], theme.danger[2], 0.28 }) });
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(theme.danger), .thickness = 2 });
        draw_list.addTriangleFilled(.{ .p1 = .{ x - 4, grid_y - 7 }, .p2 = .{ x + 4, grid_y - 7 }, .p3 = .{ x, grid_y - 2 }, .col = color(theme.danger) });
    }

    for (row_start..row_end, 0..) |row, display_row| {
        for (0..step_count) |step| {
            if (!instrument.stepActive(@intCast(row), @intCast(step))) continue;
            const velocity = @as(f32, @floatFromInt(instrument.stepVel(@intCast(row), @intCast(step)))) / 127.0;
            const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
            const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
            const inset = @min(3, cell_w * 0.15);
            const height = 8 + velocity * (row_h - 13);
            const accented = velocity >= 0.82;
            const hit_color = if (kind == .drum)
                if (accented) theme.rhythm else theme.focus
            else if (accented)
                theme.modulation
            else
                theme.audio;
            const pmin = [2]f32{ x + inset, y + row_h - height - 3 };
            const pmax = [2]f32{ x + cell_w - inset, y + row_h - 3 };
            draw_list.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = color(.{ hit_color[0], hit_color[1], hit_color[2], 0.62 + velocity * 0.38 }), .rounding = @min(3, cell_w * 0.12) });
            draw_list.addLine(.{ .p1 = .{ pmin[0] + 1, pmin[1] + 1 }, .p2 = .{ pmax[0] - 1, pmin[1] + 1 }, .col = color(.{ theme.fg0[0], theme.fg0[1], theme.fg0[2], 0.38 }), .thickness = 1 });
            if (accented) {
                draw_list.addTriangleFilled(.{
                    .p1 = .{ pmax[0] - 7, pmin[1] + 2 },
                    .p2 = .{ pmax[0] - 2, pmin[1] + 2 },
                    .p3 = .{ pmax[0] - 2, pmin[1] + 7 },
                    .col = color(theme.fg0),
                });
            }
        }
    }

    if (row_count > 0) {
        const display_row = cursor_row - row_start;
        const x = grid_x + @as(f32, @floatFromInt(cursor_step)) * cell_w;
        const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
        draw_list.addRectFilled(.{
            .pmin = .{ x + 1, y + 1 },
            .pmax = .{ x + cell_w - 1, y + row_h - 1 },
            .col = color(.{ theme.focus[0], theme.focus[1], theme.focus[2], 0.18 }),
        });
        draw_list.addRect(.{
            .pmin = .{ x + 1, y + 1 },
            .pmax = .{ x + cell_w - 1, y + row_h - 1 },
            .col = color(accent),
            .thickness = 2,
        });
    }

    if (hovered and mouse[1] >= grid_y and row_count > 0) {
        // Clamp to the rows actually on this page - the last page can be
        // partial, and a click below it must not edit an invisible row.
        const display_row = @min(row_end - row_start - 1, @as(usize, @intFromFloat((mouse[1] - grid_y) / row_h)));
        const row = row_start + display_row;

        if (mouse[0] < grid_x) {
            // Gutter: select the row only, matching the TUI's gutter click
            // (see editors/drum.zig's/slicer.zig's handleMouse).
            if (activated) cursor.* = .{ @intCast(row), cursor[1] };
        } else {
            const step = @min(step_count - 1, @as(usize, @intFromFloat((mouse[0] - grid_x) / cell_w)));
            const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
            const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
            draw_list.addRect(.{ .pmin = .{ x + 1, y + 1 }, .pmax = .{ x + cell_w - 1, y + row_h - 1 }, .col = color(theme.modulation), .thickness = 1.5 });
            // Pre-cast to the exact type DrumMachine/Slicer's step API wants
            // (u16/u8 respectively) - shared_step_grid.setStep's `step`
            // param is `anytype`, so it forwards whatever type it's given
            // straight into `inst.stepActive`/`toggleStep` with no coercion
            // of its own, unlike the `instrument.toggleStep(@intCast(step))`
            // calls elsewhere in this file, which resolve their own target
            // type directly from the concrete (non-generic) method.
            const step_t = if (kind == .drum) @as(u16, @intCast(step)) else @as(u8, @intCast(step));

            // Press starts a paint session: left toggles (remembering the
            // resulting state so a drag repeats it), right always forces the
            // cell off - see editors/drum.zig's handleMouse doc comment for
            // why a right-drag beats a left-drag for erasing a run of steps.
            // Continuing to hold - press or drag - keeps applying that same
            // state to whatever cell the mouse enters next.
            if (activated) {
                cursor.* = .{ @intCast(row), @intCast(step) };
                if (zgui.isMouseClicked(.right)) {
                    shared_step_grid.setStep(instrument, @intCast(row), step_t, false, vel_full);
                } else {
                    instrument.toggleStep(@intCast(row), step_t);
                }
                paint_state.* = instrument.stepActive(@intCast(row), step_t);
            } else if (active) {
                if (paint_state.*) |state| {
                    cursor.* = .{ @intCast(row), @intCast(step) };
                    shared_step_grid.setStep(instrument, @intCast(row), step_t, state, vel_full);
                }
            }
        }
    }
    if (!active) paint_state.* = null;
}

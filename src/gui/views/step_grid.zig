const zgui = @import("zgui");
const style = @import("../style.zig");

const color = style.color;
const umbra = style.umbra;

pub const Kind = enum { drum, slicer };

pub fn draw(
    comptime kind: Kind,
    instrument: anytype,
    total_rows: usize,
    step_count_raw: u8,
    play_step: ?usize,
    cursor: *[2]u8,
    visual_anchor: ?u8,
) void {
    const step_count: usize = @max(1, step_count_raw);
    const row_count = @min(@as(usize, 12), total_rows);
    const cursor_row = @min(@as(usize, cursor[0]), total_rows -| 1);
    const row_start = if (row_count == 0) 0 else cursor_row / row_count * row_count;
    const row_end = @min(total_rows, row_start + row_count);
    const gutter_w: f32 = 132;
    const ruler_h: f32 = 27;
    const row_h: f32 = 32;
    const available = zgui.getContentRegionAvail();
    const canvas_w = @max(360, available[0]);
    const canvas_h = ruler_h + row_h * @as(f32, @floatFromInt(row_count));
    const origin = zgui.getCursorScreenPos();
    const id = if (kind == .drum) "drum-grid-canvas" else "slicer-grid-canvas";
    const clicked = zgui.invisibleButton(id, .{ .w = canvas_w, .h = canvas_h });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    const grid_x = origin[0] + gutter_w;
    const grid_y = origin[1] + ruler_h;
    const grid_w = canvas_w - gutter_w;
    const cell_w = grid_w / @as(f32, @floatFromInt(step_count));
    const steps_per_beat: usize = if (kind == .drum) instrument.steps_per_beat else 4;
    const cursor_step = @min(@as(usize, cursor[1]), step_count - 1);
    const accent = if (kind == .drum) umbra.yellow else umbra.cyan;

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(umbra.bg0) });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, grid_y }, .col = color(umbra.bg2) });
    draw_list.addRectFilled(.{
        .pmin = .{ grid_x + @as(f32, @floatFromInt(cursor_step)) * cell_w, origin[1] },
        .pmax = .{ grid_x + @as(f32, @floatFromInt(cursor_step + 1)) * cell_w, grid_y },
        .col = color(.{ accent[0], accent[1], accent[2], 0.18 }),
    });
    draw_list.addText(.{ origin[0] + 9, origin[1] + 5 }, color(umbra.fg3), "{s} {d}-{d}  /  {d}", .{
        if (kind == .drum) "PADS" else "SLICES",
        if (row_count == 0) 0 else row_start + 1,
        row_end,
        total_rows,
    });
    for (row_start..row_end, 0..) |row, display_row| {
        const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
        const selected = row == cursor_row;
        draw_list.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ grid_x, y + row_h }, .col = color(if (selected) umbra.bg4 else if (row % 2 == 0) umbra.bg2 else umbra.bg1) });
        draw_list.addRectFilled(.{ .pmin = .{ grid_x, y }, .pmax = .{ origin[0] + canvas_w, y + row_h }, .col = color(if (row % 2 == 0) umbra.bg1 else umbra.bg0) });
        if (selected) draw_list.addRectFilled(.{ .pmin = .{ origin[0], y + 4 }, .pmax = .{ origin[0] + 4, y + row_h - 4 }, .col = color(accent), .rounding = 2 });
        if (kind == .drum) {
            if (instrument.pads[row]) |*sample|
                draw_list.addText(.{ origin[0] + 9, y + 8 }, color(if (selected) umbra.fg0 else umbra.fg1), "{d:0>2}  {s}", .{ row + 1, sample.clipName() })
            else
                draw_list.addText(.{ origin[0] + 9, y + 8 }, color(if (selected) umbra.fg0 else umbra.fg2), "{d:0>2}  Pad", .{row + 1});
        } else {
            draw_list.addText(.{ origin[0] + 9, y + 8 }, color(if (selected) umbra.fg0 else umbra.fg1), "{d:0>2}  Slice {d}", .{ row + 1, row + 1 });
        }
        draw_list.addLine(.{ .p1 = .{ origin[0], y + row_h }, .p2 = .{ origin[0] + canvas_w, y + row_h }, .col = color(umbra.line), .thickness = 1 });
    }

    for (0..step_count) |step| {
        const beat = step / steps_per_beat;
        if (beat % 2 == 0) continue;
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        draw_list.addRectFilled(.{
            .pmin = .{ x, grid_y },
            .pmax = .{ x + cell_w, origin[1] + canvas_h },
            .col = color(.{ umbra.fg0[0], umbra.fg0[1], umbra.fg0[2], 0.018 }),
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
            .col = color(.{ umbra.yellow[0], umbra.yellow[1], umbra.yellow[2], 0.12 }),
        });
        draw_list.addRect(.{
            .pmin = .{ x1 + 1, grid_y + 1 },
            .pmax = .{ x2 - 1, origin[1] + canvas_h - 1 },
            .col = color(.{ umbra.yellow[0], umbra.yellow[1], umbra.yellow[2], 0.55 }),
            .thickness = 1,
        });
    }

    for (0..step_count + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        const on_beat = step % steps_per_beat == 0;
        const on_bar = step % (steps_per_beat * 4) == 0;
        draw_list.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) umbra.fg3 else if (on_beat) umbra.bg5 else umbra.line_soft), .thickness = if (on_bar) 2 else if (on_beat) 1.5 else 1 });
        if (on_beat and step < step_count) draw_list.addText(.{ x + 5, origin[1] + 5 }, color(umbra.fg2), "{d}", .{step / steps_per_beat + 1});
    }

    if (play_step) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step % step_count)) * cell_w;
        draw_list.addRectFilled(.{ .pmin = .{ x, origin[1] }, .pmax = .{ x + cell_w, grid_y }, .col = color(.{ umbra.red[0], umbra.red[1], umbra.red[2], 0.28 }) });
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(umbra.red), .thickness = 2 });
        draw_list.addTriangleFilled(.{ .p1 = .{ x - 4, grid_y - 7 }, .p2 = .{ x + 4, grid_y - 7 }, .p3 = .{ x, grid_y - 2 }, .col = color(umbra.red) });
    }

    for (row_start..row_end, 0..) |row, display_row| {
        for (0..step_count) |step| {
            if (!instrument.stepActive(@intCast(row), @intCast(step))) continue;
            const velocity = @as(f32, @floatFromInt(instrument.stepVel(@intCast(row), @intCast(step)))) / 127.0;
            const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
            const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
            const inset = @min(3, cell_w * 0.15);
            const height = 8 + velocity * (row_h - 13);
            const hit_color = if (kind == .drum) umbra.iris else umbra.cyan;
            const pmin = [2]f32{ x + inset, y + row_h - height - 3 };
            const pmax = [2]f32{ x + cell_w - inset, y + row_h - 3 };
            draw_list.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = color(.{ hit_color[0], hit_color[1], hit_color[2], 0.62 + velocity * 0.38 }), .rounding = @min(3, cell_w * 0.12) });
            draw_list.addLine(.{ .p1 = .{ pmin[0] + 1, pmin[1] + 1 }, .p2 = .{ pmax[0] - 1, pmin[1] + 1 }, .col = color(.{ umbra.fg0[0], umbra.fg0[1], umbra.fg0[2], 0.38 }), .thickness = 1 });
        }
    }

    if (row_count > 0) {
        const display_row = cursor_row - row_start;
        const x = grid_x + @as(f32, @floatFromInt(cursor_step)) * cell_w;
        const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
        draw_list.addRectFilled(.{
            .pmin = .{ x + 1, y + 1 },
            .pmax = .{ x + cell_w - 1, y + row_h - 1 },
            .col = color(.{ umbra.iris[0], umbra.iris[1], umbra.iris[2], 0.18 }),
        });
        draw_list.addRect(.{
            .pmin = .{ x + 1, y + 1 },
            .pmax = .{ x + cell_w - 1, y + row_h - 1 },
            .col = color(accent),
            .thickness = 2,
        });
    }

    if (hovered and mouse[0] >= grid_x and mouse[1] >= grid_y and row_count > 0) {
        const step = @min(step_count - 1, @as(usize, @intFromFloat((mouse[0] - grid_x) / cell_w)));
        const display_row = @min(row_count - 1, @as(usize, @intFromFloat((mouse[1] - grid_y) / row_h)));
        const row = row_start + display_row;
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
        draw_list.addRect(.{ .pmin = .{ x + 1, y + 1 }, .pmax = .{ x + cell_w - 1, y + row_h - 1 }, .col = color(umbra.mauve), .thickness = 1.5 });
        if (clicked) {
            cursor.* = .{ @intCast(row), @intCast(step) };
            instrument.toggleStep(@intCast(row), @intCast(step));
        }
    }
}

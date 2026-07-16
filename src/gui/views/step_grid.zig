const zgui = @import("zgui");
const style = @import("../style.zig");

const color = style.color;
const umbra = style.umbra;

pub const Kind = enum { drum, slicer };

pub fn draw(comptime kind: Kind, instrument: anytype, row_count: usize, step_count_raw: u8, play_step: ?usize) void {
    const step_count: usize = @max(1, step_count_raw);
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

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(umbra.bg0) });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, grid_y }, .col = color(umbra.bg2) });
    for (0..row_count) |row| {
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        draw_list.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ grid_x, y + row_h }, .col = color(if (row % 2 == 0) umbra.bg2 else umbra.bg1) });
        draw_list.addRectFilled(.{ .pmin = .{ grid_x, y }, .pmax = .{ origin[0] + canvas_w, y + row_h }, .col = color(if (row % 2 == 0) umbra.bg1 else umbra.bg0) });
        if (kind == .drum) {
            if (instrument.pads[row]) |*sample|
                draw_list.addText(.{ origin[0] + 9, y + 8 }, color(umbra.fg1), "{d:0>2}  {s}", .{ row + 1, sample.clipName() })
            else
                draw_list.addText(.{ origin[0] + 9, y + 8 }, color(umbra.fg2), "{d:0>2}  Pad", .{row + 1});
        } else {
            draw_list.addText(.{ origin[0] + 9, y + 8 }, color(umbra.fg1), "{d:0>2}  Slice {d}", .{ row + 1, row + 1 });
        }
        draw_list.addLine(.{ .p1 = .{ origin[0], y + row_h }, .p2 = .{ origin[0] + canvas_w, y + row_h }, .col = color(umbra.line), .thickness = 1 });
    }

    for (0..step_count + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        const on_beat = step % steps_per_beat == 0;
        draw_list.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_beat) umbra.bg5 else umbra.line_soft), .thickness = if (on_beat) 1.5 else 1 });
        if (on_beat and step < step_count) draw_list.addText(.{ x + 5, origin[1] + 5 }, color(umbra.fg2), "{d}", .{step / steps_per_beat + 1});
    }

    if (play_step) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step % step_count)) * cell_w;
        draw_list.addRectFilled(.{ .pmin = .{ x, origin[1] }, .pmax = .{ x + cell_w, grid_y }, .col = color(.{ umbra.red[0], umbra.red[1], umbra.red[2], 0.28 }) });
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(umbra.red), .thickness = 2 });
        draw_list.addTriangleFilled(.{ .p1 = .{ x - 4, grid_y - 7 }, .p2 = .{ x + 4, grid_y - 7 }, .p3 = .{ x, grid_y - 2 }, .col = color(umbra.red) });
    }

    for (0..row_count) |row| {
        for (0..step_count) |step| {
            if (!instrument.stepActive(@intCast(row), @intCast(step))) continue;
            const velocity = @as(f32, @floatFromInt(instrument.stepVel(@intCast(row), @intCast(step)))) / 127.0;
            const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
            const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
            const inset = @min(3, cell_w * 0.15);
            const height = 8 + velocity * (row_h - 13);
            const hit_color = if (kind == .drum) umbra.iris else umbra.cyan;
            draw_list.addRectFilled(.{ .pmin = .{ x + inset, y + row_h - height - 3 }, .pmax = .{ x + cell_w - inset, y + row_h - 3 }, .col = color(.{ hit_color[0], hit_color[1], hit_color[2], 0.62 + velocity * 0.38 }) });
        }
    }

    if (hovered and mouse[0] >= grid_x and mouse[1] >= grid_y and row_count > 0) {
        const step = @min(step_count - 1, @as(usize, @intFromFloat((mouse[0] - grid_x) / cell_w)));
        const row = @min(row_count - 1, @as(usize, @intFromFloat((mouse[1] - grid_y) / row_h)));
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        draw_list.addRectFilled(.{ .pmin = .{ x + 1, y + 1 }, .pmax = .{ x + cell_w - 1, y + row_h - 1 }, .col = color(.{ umbra.mauve[0], umbra.mauve[1], umbra.mauve[2], 0.22 }) });
        if (clicked) instrument.toggleStep(@intCast(row), @intCast(step));
    }
}

const std = @import("std");
const zgui = @import("zgui");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const shared_step_grid = @import("../../ui/editors/step_grid.zig");
const history = @import("../../ui/history.zig");

const color = style.color;
const theme = &style.palette;

pub const Kind = enum { drum, slicer };

/// Shortest a grid row is allowed to get; also what decides how many banks
/// a panel can show at once (see `draw`'s `banks_fit`).
const min_row_h: f32 = 32;

pub fn draw(
    comptime kind: Kind,
    app: anytype,
    instrument: anytype,
    total_rows: usize,
    step_count_raw: anytype,
    stride_raw: anytype,
    play_step: ?usize,
    cursor: anytype,
    visual_anchor: anytype,
    /// The selection's row anchor - null means linewise (`V`, every row).
    /// See editors/step_grid.zig's rowRange.
    visual_row_anchor: ?u8,
    /// Which state a click-and-hold paints every newly-entered cell to
    /// (mirrors the TUI's `app.drum_paint_state`/`slicer_paint_state`, and
    /// is in fact the very same field - both frontends share `ui/app.zig`'s
    /// `App`). Null between drags.
    paint_state: *?bool,
) void {
    const stride: usize = @max(1, stride_raw);
    const storage_step_count: usize = @max(1, step_count_raw);
    const step_count: usize = @max(1, (storage_step_count + stride - 1) / stride);
    const cursor_row = @min(@as(usize, cursor[0]), total_rows -| 1);
    const gutter_w: f32 = 132;
    const ruler_h: f32 = 27;
    const available = zgui.getContentRegionAvail();
    // Page in whole banks, like the TUI grids (see editors/step_grid.zig's
    // `bankWindow`): how many fit is a pixel budget here rather than a row
    // budget, but the window still starts on a bank boundary so the pads a
    // page shows line up with the banks the rest of the UI names.
    const banks_fit: usize = @intFromFloat(@max(1, @floor((available[1] - ruler_h) / min_row_h)) / @as(f32, @floatFromInt(shared_step_grid.rows_per_bank)));
    const row_start = shared_step_grid.bankWindow(cursor_row, banks_fit);
    const row_end = @min(total_rows, row_start + @max(1, banks_fit) * shared_step_grid.rows_per_bank);
    const row_count = row_end - row_start;
    const row_h: f32 = if (row_count == 0)
        min_row_h
    else
        std.math.clamp((available[1] - ruler_h) / @as(f32, @floatFromInt(row_count)), min_row_h, if (kind == .drum) 54 else 44);
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
    const steps_per_beat: usize = @max(@as(usize, instrument.steps_per_beat) / stride, 1);
    const bar_units = steps_per_beat * @as(usize, @max(app.core.session.project.beats_per_bar, 1)) * 4;
    const meter_denominator: usize = @max(app.core.session.project.meter_denominator, 1);
    const cursor_step = @min(@as(usize, cursor[1]) / stride, step_count - 1);
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
        if (selected) draw_list.addRectFilled(.{ .pmin = .{ origin[0], y + 4 }, .pmax = .{ origin[0] + 4, y + row_h - 4 }, .col = color(accent), .rounding = style.item_rounding });
        // A slice that is sounding right now lights its whole row, so the
        // grid says which chop you are hearing and not only which step the
        // playhead is on (dsp/slicer.zig's `slicePlaying`).
        if (kind == .slicer and instrument.slicePlaying(@intCast(row))) {
            draw_list.addRectFilled(.{
                .pmin = .{ origin[0], y },
                .pmax = .{ origin[0] + canvas_w, y + row_h },
                .col = color(.{ theme.danger[0], theme.danger[1], theme.danger[2], 0.16 }),
            });
        }
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
        const anchor = @min(@as(usize, anchor_raw) / stride, step_count - 1);
        const lo = @min(anchor, cursor_step);
        const hi = @max(anchor, cursor_step);
        const x1 = grid_x + @as(f32, @floatFromInt(lo)) * cell_w;
        const x2 = grid_x + @as(f32, @floatFromInt(hi + 1)) * cell_w;
        // The row axis: `v` (blockwise) bounds it to the anchored band, `V`
        // (linewise) leaves the anchor null and the rectangle spans the whole
        // visible page. Clamped to the paged window so a band scrolled out of
        // view doesn't paint over rows that aren't in it.
        const rows = shared_step_grid.rowRange(u8, visual_row_anchor, @as(u8, @intCast(cursor_row)), total_rows);
        const y1 = grid_y + @as(f32, @floatFromInt(@max(rows.lo, row_start) -| row_start)) * row_h;
        const y2 = grid_y + @as(f32, @floatFromInt(@min(rows.hi + 1, row_end) -| row_start)) * row_h;
        if (y2 > y1) {
            draw_list.addRectFilled(.{
                .pmin = .{ x1, y1 },
                .pmax = .{ x2, y2 },
                .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.12 }),
            });
            draw_list.addRect(.{
                .pmin = .{ x1 + 1, y1 + 1 },
                .pmax = .{ x2 - 1, y2 - 1 },
                .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.55 }),
                .thickness = 1,
            });
        }
    }

    for (0..step_count + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        const on_beat = step % steps_per_beat == 0;
        const position_units = step * meter_denominator;
        const on_bar = position_units % bar_units == 0;
        draw_list.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) theme.fg3 else if (on_beat) theme.bg5 else theme.line_soft), .thickness = if (on_bar) 2 else if (on_beat) 1.5 else 1 });
        if (on_bar and step < step_count) draw_list.addText(.{ x + 5, origin[1] + 5 }, color(theme.fg2), "{d}", .{position_units / bar_units + 1});
    }

    if (play_step) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step / stride % step_count)) * cell_w;
        draw_list.addRectFilled(.{ .pmin = .{ x, origin[1] }, .pmax = .{ x + cell_w, grid_y }, .col = color(.{ theme.danger[0], theme.danger[1], theme.danger[2], 0.28 }) });
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(theme.danger), .thickness = 2 });
        draw_list.addTriangleFilled(.{ .p1 = .{ x - 4, grid_y - 7 }, .p2 = .{ x + 4, grid_y - 7 }, .p3 = .{ x, grid_y - 2 }, .col = color(theme.danger) });
    }

    for (row_start..row_end, 0..) |row, display_row| {
        for (0..storage_step_count) |step| {
            const tick: u16 = @intCast(step);
            if (!instrument.stepActive(@intCast(row), tick)) continue;
            const vel = instrument.stepVel(@intCast(row), tick);
            const velocity = @as(f32, @floatFromInt(vel)) / 127.0;
            const tick_w = cell_w / @as(f32, @floatFromInt(stride));
            const x = grid_x + @as(f32, @floatFromInt(step)) * tick_w;
            const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
            const inset = @min(3, tick_w * 0.15);
            const height = 8 + velocity * (row_h - 13);
            // Top of the same five bands the TUI grids print a glyph for,
            // so an "accented" hit means the same velocity in both.
            const accented = shared_step_grid.velocityBand(vel) == .accent;
            const hit_color = if (kind == .drum)
                if (accented) theme.rhythm else theme.focus
            else if (accented)
                theme.modulation
            else
                theme.audio;
            // A timing shift slides the whole hit within its cell, so the
            // grid shows the feel rather than just flagging it. Capped at
            // half a cell either way, matching setStepMicro's own clamp.
            const micro_px: f32 = tick_w * @as(f32, @floatFromInt(instrument.stepMicro(@intCast(row), tick))) / 100.0;
            const pmin = [2]f32{ x + inset + micro_px, y + row_h - height - 3 };
            const pmax = [2]f32{ x + cell_w - inset + micro_px, y + row_h - 3 };
            draw_list.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = color(.{ hit_color[0], hit_color[1], hit_color[2], 0.62 + velocity * 0.38 }), .rounding = @min(3, tick_w * 0.12) });
            draw_list.addLine(.{ .p1 = .{ pmin[0] + 1, pmin[1] + 1 }, .p2 = .{ pmax[0] - 1, pmin[1] + 1 }, .col = color(.{ theme.fg0[0], theme.fg0[1], theme.fg0[2], 0.38 }), .thickness = 1 });
            if (accented) {
                draw_list.addTriangleFilled(.{
                    .p1 = .{ pmax[0] - 7, pmin[1] + 2 },
                    .p2 = .{ pmax[0] - 2, pmin[1] + 2 },
                    .p3 = .{ pmax[0] - 2, pmin[1] + 7 },
                    .col = color(theme.fg0),
                });
            }
            // A conditional step (chance or a trig condition) gets a dot in
            // its top-left, opposite the accent triangle so a step can show
            // both. Which condition is on the status line.
            if (instrument.stepProb(@intCast(row), tick) != 100 or
                instrument.stepCond(@intCast(row), tick) != .always)
            {
                draw_list.addCircleFilled(.{
                    .p = .{ pmin[0] + 4, pmin[1] + 4 },
                    .r = 2.5,
                    .col = color(theme.danger),
                });
            }
            // A roll draws its hits as ticks along the top edge, so the
            // count reads without selecting the step.
            const hits = instrument.stepRetrig(@intCast(row), tick);
            if (hits >= 2) {
                const span = pmax[0] - pmin[0];
                for (0..@min(hits, 8)) |h| {
                    const tx = pmin[0] + span * (@as(f32, @floatFromInt(h)) + 0.5) / @as(f32, @floatFromInt(@min(hits, 8)));
                    draw_list.addLine(.{
                        .p1 = .{ tx, pmin[1] + 2 },
                        .p2 = .{ tx, pmin[1] + 6 },
                        .col = color(theme.fg0),
                        .thickness = 1,
                    });
                }
            }
            // A tuned step gets a bar along its bottom edge, above or below
            // the hit's own baseline depending on the direction - the TUI's
            // paren brackets can only say "tuned", this says which way.
            const semis = instrument.stepTune(@intCast(row), tick);
            if (semis != 0) {
                const mark_y = if (semis > 0) pmin[1] - 3 else pmax[1] + 1;
                draw_list.addRectFilled(.{
                    .pmin = .{ pmin[0], mark_y },
                    .pmax = .{ pmax[0], mark_y + 2 },
                    .col = color(theme.modulation),
                });
            }
        }
    }

    // Drawn after the hits, not before: a row that loops on its own shorter
    // length keeps its parked steps editable, but they never fire, so the
    // shade has to sit over them (`DrumMachine.pad_len`/`Slicer.slice_len` -
    // each machine names its own accessor for its own row).
    for (row_start..row_end, 0..) |row, display_row| {
        const len = if (kind == .drum)
            instrument.padSteps(@intCast(row), @intCast(step_count * stride)) / stride
        else
            instrument.sliceSteps(@intCast(row), @intCast(step_count * stride)) / stride;
        if (len >= step_count) continue;
        const x = grid_x + @as(f32, @floatFromInt(len)) * cell_w;
        const y = grid_y + @as(f32, @floatFromInt(display_row)) * row_h;
        draw_list.addRectFilled(.{
            .pmin = .{ x, y },
            .pmax = .{ grid_x + @as(f32, @floatFromInt(step_count)) * cell_w, y + row_h },
            .col = color(.{ theme.bg0[0], theme.bg0[1], theme.bg0[2], 0.74 }),
        });
        draw_list.addLine(.{
            .p1 = .{ x, y },
            .p2 = .{ x, y + row_h },
            .col = color(theme.modulation),
            .thickness = 2,
        });
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
        widgets.focusRect(draw_list, .{ x + 1, y + 1 }, .{ x + cell_w - 1, y + row_h - 1 }, 0, theme.focus);
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
            // Pre-cast to the u16 both machines' step API takes -
            // shared_step_grid.setStep's `step` param is `anytype`, so it
            // forwards whatever type it's given straight into
            // `inst.stepActive`/`toggleStep` with no coercion of its own,
            // unlike the `instrument.toggleStep(@intCast(step))` calls
            // elsewhere in this file, which resolve their own target type
            // directly from the concrete (non-generic) method.
            const step_t: u16 = @intCast(step * stride);

            const fine_step: u16 = @intCast(@min(
                storage_step_count - 1,
                @as(usize, @intFromFloat((mouse[0] - grid_x) / (cell_w / @as(f32, @floatFromInt(stride))))),
            ));
            if (style.wheel_delta != 0 and zgui.isKeyDown(.mod_alt) and instrument.stepActive(@intCast(row), fine_step)) {
                style.wheel_consumed = true;
                cursor.* = .{ @intCast(row), fine_step };
                app.core.handleKey(.{ .char = if (style.wheel_delta > 0) ';' else '\'' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }

            // Press starts a paint session: left toggles (remembering the
            // resulting state so a drag repeats it), right always forces the
            // cell off - see editors/drum.zig's handleMouse doc comment for
            // why a right-drag beats a left-drag for erasing a run of steps.
            // Continuing to hold - press or drag - keeps applying that same
            // state to whatever cell the mouse enters next.
            if (activated) {
                cursor.* = .{ @intCast(row), step_t };
                if (kind == .drum)
                    history.recordDrum(&app.core, app.core.drum_track)
                else
                    history.recordSlicer(&app.core, app.core.slicer_track);
                if (zgui.isMouseClicked(.right)) {
                    shared_step_grid.setStep(instrument, @intCast(row), step_t, false, vel_full);
                } else {
                    instrument.toggleStep(@intCast(row), step_t);
                }
                paint_state.* = instrument.stepActive(@intCast(row), step_t);
            } else if (active) {
                if (paint_state.*) |state| {
                    cursor.* = .{ @intCast(row), step_t };
                    shared_step_grid.setStep(instrument, @intCast(row), step_t, state, vel_full);
                }
            }
        }
    }
    if (!active) paint_state.* = null;
}

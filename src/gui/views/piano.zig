//! Piano roll: scale-aware key gutter, note grid with mouse draw/move/resize,
//! ghost notes from other tracks, and the shared cursor/playhead overlays.

const std = @import("std");
const ws = @import("wstudio");
const icons = @import("../../ui/icons.zig");
const piano_ed = @import("../../ui/editors/piano.zig");
const gui_style = @import("../style.zig");
const history = @import("../../ui/history.zig");
const widgets = @import("../widgets.zig");
const zgui = @import("zgui");
const shared_step_grid = @import("../../ui/editors/step_grid.zig");

const color = gui_style.color;
const trackColor = gui_style.trackColor;
const theme = &gui_style.palette;

/// In-flight mouse edit; lives on the GUI App so it survives across frames.
pub const MouseEdit = struct {
    /// `resize` drags the note's right edge (its length), `resize_left` the
    /// left one - the start moves while the end stays put, FL's resize-from-
    /// left. `duration_steps` is the live length under a `resize` drag but
    /// stays at the grabbed length under `resize_left`, where `target_step`
    /// carries the new start instead.
    kind: enum { move, resize, resize_left },
    source_pitch: u7,
    source_step: u16,
    grab_step_offset: u16 = 0,
    target_pitch: u7,
    target_step: u16,
    duration_steps: u16,
    /// This `resize` is the tail of a draw gesture (FL's click-and-drag to
    /// place a note at the length you drag out), not a grab of an existing
    /// note's edge: the length holds at the default until the pointer leaves
    /// the cell it started in, and the committed length becomes the new
    /// default rather than pushing a second undo entry.
    from_draw: bool = false,
    /// Shift was held when the drag started: FL's clone-on-drag leaves a
    /// copy of the note behind at the source.
    clone: bool = false,
};

/// Pitch drawn on `row` of a roll whose top row is `top_pitch`, or null once
/// the rows run off the bottom of the keyboard.
///
/// The view can be taller than the keyboard is deep below `top_pitch`: the
/// scroll position is shared with the TUI and `followPitch` only ever clamps
/// it upward (at 127), so opening a tall GUI window on a roll last scrolled
/// in a short terminal leaves `piano_scroll_pitch` well under the row count.
/// Subtracting straight into a u7 there panicked on integer overflow;
/// views/piano.zig's TUI half has always computed this in a wider type and
/// skipped the rows that don't exist.
fn rowPitch(top_pitch: u7, row: usize) ?u7 {
    const pitch: i32 = @as(i32, top_pitch) - @as(i32, @intCast(@min(row, 1024)));
    if (pitch < 0) return null;
    return @intCast(pitch);
}

test "rowPitch stops at the bottom of the keyboard instead of wrapping" {
    try std.testing.expectEqual(@as(?u7, 60), rowPitch(60, 0));
    try std.testing.expectEqual(@as(?u7, 40), rowPitch(60, 20));
    try std.testing.expectEqual(@as(?u7, 0), rowPitch(60, 60));
    // The crash: a tall view over a low scroll position. Every row past the
    // bottom reports "no pitch" rather than wrapping a u7 round to 127.
    try std.testing.expectEqual(@as(?u7, null), rowPitch(60, 61));
    try std.testing.expectEqual(@as(?u7, null), rowPitch(0, 1));
    try std.testing.expectEqual(@as(?u7, null), rowPitch(19, 36));
    try std.testing.expectEqual(@as(?u7, 0), rowPitch(0, 0));
}

fn previewNote(source: ws.dsp.pattern.Note, edit: ?MouseEdit, steps_per_beat: usize) ws.dsp.pattern.Note {
    const active = edit orelse return source;
    const source_step: u16 = ws.dsp.pattern.clampStep(@round(source.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
    if (source.pitch != active.source_pitch or source_step != active.source_step) return source;
    var note = source;
    switch (active.kind) {
        .move => {
            note.pitch = active.target_pitch;
            note.start_beat = @as(f64, @floatFromInt(active.target_step)) / @as(f64, @floatFromInt(steps_per_beat));
        },
        .resize => note.duration_beat = @as(f64, @floatFromInt(active.duration_steps)) / @as(f64, @floatFromInt(steps_per_beat)),
        .resize_left => {
            const end = active.source_step + active.duration_steps;
            note.start_beat = @as(f64, @floatFromInt(active.target_step)) / @as(f64, @floatFromInt(steps_per_beat));
            note.duration_beat = @as(f64, @floatFromInt(end - active.target_step)) / @as(f64, @floatFromInt(steps_per_beat));
        },
    }
    return note;
}

fn updateMouseEdit(edit: *MouseEdit, pointer_pitch: u7, pointer_step: usize) void {
    // A draw that hasn't left its starting cell keeps the default note
    // length - only an actual drag sizes the note, so a plain click still
    // places one of the length `[`/`]` set.
    if (edit.from_draw and pointer_step == edit.source_step) return;
    switch (edit.kind) {
        .move => {
            edit.target_pitch = pointer_pitch;
            edit.target_step = @intCast(pointer_step -| edit.grab_step_offset);
        },
        .resize => edit.duration_steps = @intCast(@max(1, pointer_step + 1 -| edit.source_step)),
        // The end is fixed, so the start can never reach or pass it.
        .resize_left => edit.target_step = @intCast(@min(pointer_step, @as(usize, edit.source_step + edit.duration_steps) - 1)),
    }
}

test "mouse note edits preview before commit" {
    const note: ws.dsp.pattern.Note = .{ .pitch = 60, .start_beat = 1, .duration_beat = 0.5 };
    const base: MouseEdit = .{ .kind = .move, .source_pitch = 60, .source_step = 4, .target_pitch = 64, .target_step = 8, .duration_steps = 2 };
    const moved = previewNote(note, base, 4);
    try std.testing.expectEqual(@as(u7, 64), moved.pitch);
    try std.testing.expectEqual(@as(f64, 2), moved.start_beat);
    var resize = base;
    resize.kind = .resize;
    resize.duration_steps = 6;
    try std.testing.expectEqual(@as(f64, 1.5), previewNote(note, resize, 4).duration_beat);

    // A left-edge drag moves the start and keeps the end: [4,6) grabbed at
    // 2 steps long, dragged to step 2, previews as [2,6) - 1 beat long.
    var left = base;
    left.kind = .resize_left;
    left.target_step = 2;
    const shrunk = previewNote(note, left, 4);
    try std.testing.expectEqual(@as(f64, 0.5), shrunk.start_beat);
    try std.testing.expectEqual(@as(f64, 1.0), shrunk.duration_beat);

    // The pointer can never push the start onto or past the fixed end.
    var edit = left;
    updateMouseEdit(&edit, 60, 99);
    try std.testing.expectEqual(@as(u16, 5), edit.target_step);
}

test "a pen keeps the default length until the pointer leaves its cell" {
    // Placed at step 4 with a 4-step default: clicking without dragging must
    // commit those 4 steps, not the one step the pointer's own cell spans.
    var pen: MouseEdit = .{
        .kind = .resize,
        .from_draw = true,
        .source_pitch = 60,
        .source_step = 4,
        .target_pitch = 60,
        .target_step = 4,
        .duration_steps = 4,
    };
    updateMouseEdit(&pen, 60, 4);
    try std.testing.expectEqual(@as(u16, 4), pen.duration_steps);
    // Dragging right sizes it to the pointer, inclusive of its cell.
    updateMouseEdit(&pen, 60, 9);
    try std.testing.expectEqual(@as(u16, 6), pen.duration_steps);
    // And back left, down to a single step.
    updateMouseEdit(&pen, 60, 3);
    try std.testing.expectEqual(@as(u16, 1), pen.duration_steps);
}

fn drawToolbar(app: anytype) void {
    var scale_on = app.core.piano_scale != null;
    if (widgets.toggle("SCALE", &scale_on)) {
        app.core.piano_scale = if (scale_on) .{} else null;
    }
    if (app.core.piano_scale) |scale| {
        zgui.sameLine(.{ .spacing = 8 });
        var root: i32 = scale.root;
        zgui.setNextItemWidth(72);
        if (zgui.combo("##piano-scale-root", .{
            .current_item = &root,
            .items_separated_by_zeros = "C\x00C#\x00D\x00D#\x00E\x00F\x00F#\x00G\x00G#\x00A\x00A#\x00B\x00",
        })) app.core.piano_scale.?.root = @intCast(root);

        zgui.sameLine(.{ .spacing = 8 });
        var kind = scale.kind;
        zgui.setNextItemWidth(112);
        if (zgui.comboFromEnum("##piano-scale-kind", &kind)) app.core.piano_scale.?.kind = kind;
    }

    zgui.sameLine(.{ .spacing = 14 });
    _ = widgets.toggle("GHOST NOTES", &app.core.piano_ghost);

    zgui.sameLine(.{ .spacing = 14 });
    var triplet = app.core.piano_grid == .triplet;
    if (widgets.toggle("TRIPLET", &triplet)) {
        app.core.handleKey(.{ .char = 'T' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }

    zgui.sameLine(.{ .spacing = 8 });
    if (zgui.button("- GRID##piano-grid-down", .{ .h = 27 })) {
        app.core.handleKey(.{ .char = 'Z' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
    zgui.sameLine(.{ .spacing = 4 });
    zgui.textColored(theme.audio, "{s}", .{app.core.piano_division.label()});
    zgui.sameLine(.{ .spacing = 4 });
    if (zgui.button("+ GRID##piano-grid-up", .{ .h = 27 })) {
        app.core.handleKey(.{ .char = 'z' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }

    zgui.sameLine(.{ .spacing = 12 });
    if (zgui.button("- LEN##piano-len-down", .{ .h = 27 })) {
        app.core.handleKey(.{ .char = '[' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
    zgui.sameLine(.{ .spacing = 4 });
    if (zgui.button("+ LEN##piano-len-up", .{ .h = 27 })) {
        app.core.handleKey(.{ .char = ']' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
}

pub fn draw(app: anytype) void {
    if (app.core.piano_track >= app.core.session.racks.items.len) return;
    const rack = app.core.session.racks.items[app.core.piano_track];
    const pp = if (rack.pattern_player) |*p| p else {
        zgui.textDisabled("This instrument has no melodic pattern. Choose Synth or Sampler.", .{});
        return;
    };
    const track_name = app.core.session.project.tracks.items[app.core.piano_track].name;
    zgui.textDisabled(icons.synth ++ "  PIANO ROLL", .{});
    zgui.sameLine(.{});
    zgui.text("\"{s}\"", .{track_name});
    if (app.core.piano_clip_link) |link| {
        zgui.sameLine(.{});
        zgui.textColored(theme.focus, "clip@bar {d}", .{link.start_bar + 1});
    } else if (app.core.session.song_mode) {
        zgui.sameLine(.{});
        zgui.textColored(theme.danger, "scratch: not in song until stamped from arrangement", .{});
    }
    if (app.core.piano_scale) |scale| {
        zgui.sameLine(.{});
        zgui.textColored(theme.modulation, "scale {s} {s}", .{ ws.theory.pitchClassName(scale.root), scale.kind.label() });
    }
    if (app.core.piano_grid == .triplet) {
        zgui.sameLine(.{});
        zgui.textColored(theme.rhythm, "triplet", .{});
    }
    zgui.sameLine(.{});
    zgui.textColored(theme.audio, "{s}", .{app.core.piano_division.label()});
    if (app.core.piano_ghost) {
        zgui.sameLine(.{});
        zgui.textDisabled("ghost", .{});
    }
    if (app.core.piano_audition) {
        zgui.sameLine(.{});
        zgui.textDisabled("audition", .{});
    }
    drawToolbar(app);

    const gutter_w: f32 = 58;
    const ruler_h: f32 = 24;
    const row_h: f32 = gui_style.piano_row_height;
    const controller_h: f32 = 96;
    const available = zgui.getContentRegionAvail();
    const row_count: usize = @intFromFloat(std.math.clamp(@floor((available[1] - ruler_h - controller_h - 8) / row_h), 24, 37));
    piano_ed.followPitch(&app.core, @intCast(row_count));
    const top_pitch: u7 = app.core.piano_scroll_pitch;
    const bottom_pitch: u7 = top_pitch -| @as(u7, @intCast(row_count - 1));
    const canvas_w = @max(320, available[0]);
    const canvas_h = ruler_h + row_h * @as(f32, @floatFromInt(row_count));
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("piano-roll-canvas", .{ .w = canvas_w, .h = canvas_h });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    const grid_x = origin[0] + gutter_w;
    const grid_y = origin[1] + ruler_h;
    const grid_w = canvas_w - gutter_w;
    const beats: f32 = @floatCast(@max(1.0, pp.length_beats));
    const beat_w = grid_w / beats;

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(theme.bg0) });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + gutter_w, origin[1] + ruler_h }, .col = color(theme.bg2) });

    for (0..row_count) |row| {
        // Rows past the bottom of the keyboard stay as background - see
        // `rowPitch`, which is where the overflow this used to panic on is
        // documented.
        const pitch = rowPitch(top_pitch, row) orelse break;
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        const black = isBlackKey(pitch);
        const tone = piano_ed.scaleTone(app.core.piano_scale, pitch);
        const row_color = switch (tone) {
            .root => theme.bg3,
            .out_scale => theme.line_soft,
            .in_scale, .unscaled_white => theme.bg2,
            .unscaled_black => theme.bg1,
        };
        draw_list.addRectFilled(.{ .pmin = .{ grid_x, y }, .pmax = .{ origin[0] + canvas_w, y + row_h }, .col = color(row_color) });
        const key_color = if (black) theme.bg1 else theme.fg1;
        draw_list.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ grid_x, y + row_h }, .col = color(key_color) });
        if (black) draw_list.addRectFilled(.{ .pmin = .{ origin[0], y + 1 }, .pmax = .{ origin[0] + 37, y + row_h - 1 }, .col = color(theme.bg0) });
        draw_list.addLine(.{ .p1 = .{ origin[0], y + row_h }, .p2 = .{ origin[0] + canvas_w, y + row_h }, .col = color(theme.line), .thickness = if (@mod(pitch, 12) == 0) 1.5 else 1 });
        var note_buf: [5]u8 = undefined;
        const note_name = ws.midi.noteName(pitch, &note_buf);
        const label_x = grid_x - zgui.calcTextSize(note_name, .{})[0] - 4;
        draw_list.addText(.{ label_x, y + 1 }, color(if (black) theme.fg0 else theme.bg0), "{s}", .{note_name});
    }

    const steps_per_beat: usize = app.core.pianoStepsPerBeat();
    // Capped at what a u16 step index holds: every `pointer_step` below is
    // taken modulo this and then narrowed to u16 (MouseEdit's fields, the
    // cursor), and a loop long enough to overflow that is reachable - see
    // `pattern.clampStep`.
    const steps: usize = @intFromFloat(std.math.clamp(
        @ceil(beats * @as(f32, @floatFromInt(steps_per_beat))),
        1,
        @as(f32, std.math.maxInt(u16)),
    ));
    if (app.core.modal.mode == .visual) {
        const anchor = @min(@as(usize, app.core.piano_visual_anchor orelse app.core.piano_cursor_step), steps - 1);
        const cursor_step = @min(@as(usize, app.core.piano_cursor_step), steps - 1);
        const lo = @min(anchor, cursor_step);
        const hi = @max(anchor, cursor_step);
        const x1 = grid_x + @as(f32, @floatFromInt(lo)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const x2 = grid_x + @as(f32, @floatFromInt(hi + 1)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        // The pitch axis: `v` (blockwise) bounds it to the anchored band,
        // `V` (linewise) leaves the anchor null and the rectangle spans every
        // row. Rows run high-pitch-first, so the band's high pitch is the top
        // edge; clamped to the visible window.
        const band = shared_step_grid.rowRange(u7, app.core.piano_visual_pitch_anchor, app.core.piano_cursor_pitch, 128);
        const y1 = grid_y + @as(f32, @floatFromInt(@as(usize, top_pitch) -| @min(band.hi, top_pitch))) * row_h;
        const y2 = grid_y + @as(f32, @floatFromInt(@min(row_count, @as(usize, top_pitch) -| band.lo + 1))) * row_h;
        if (y2 > y1) {
            draw_list.addRectFilled(.{ .pmin = .{ x1, y1 }, .pmax = .{ x2, y2 }, .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.12 }) });
            draw_list.addRect(.{ .pmin = .{ x1 + 1, y1 + 1 }, .pmax = .{ x2 - 1, y2 - 1 }, .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.55 }), .thickness = 1 });
        }
    }
    for (0..steps + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const on_beat = step % steps_per_beat == 0;
        const on_bar = step % (steps_per_beat * app.core.session.project.beats_per_bar) == 0;
        draw_list.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) theme.bg5 else if (on_beat) theme.bg4 else theme.line), .thickness = if (on_bar) 2 else 1 });
        if (on_beat and step < steps) draw_list.addText(.{ x + 5, origin[1] + 4 }, color(theme.fg2), "{d}.{d}", .{ step / (steps_per_beat * app.core.session.project.beats_per_bar) + 1, step / steps_per_beat % app.core.session.project.beats_per_bar + 1 });
    }

    if (app.core.piano_ghost) {
        for (app.core.session.racks.items, 0..) |other_rack, track_index| {
            if (track_index == app.core.piano_track) continue;
            const ghost_pp = if (other_rack.pattern_player) |*p| p else continue;
            const accent = trackColor(app.core.session.project.tracks.items[track_index].color);
            while (!ghost_pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
            for (ghost_pp.notes[0..ghost_pp.note_count]) |note| {
                if (note.pitch < bottom_pitch or note.pitch > top_pitch) continue;
                const x = grid_x + @as(f32, @floatCast(note.start_beat)) * beat_w;
                const width = @max(3, @as(f32, @floatCast(note.duration_beat)) * beat_w - 2);
                const y = grid_y + @as(f32, @floatFromInt(top_pitch - note.pitch)) * row_h + 3;
                const right = @min(x + width, origin[0] + canvas_w - 1);
                draw_list.addRectFilled(.{ .pmin = .{ x + 1, y }, .pmax = .{ right, y + row_h - 6 }, .col = color(.{ accent[0], accent[1], accent[2], 0.13 }), .rounding = 2 });
                draw_list.addRect(.{ .pmin = .{ x + 1, y }, .pmax = .{ right, y + row_h - 6 }, .col = color(.{ accent[0], accent[1], accent[2], 0.48 }), .rounding = 2, .thickness = 1 });
            }
            ghost_pp.notes_lock.unlock();
        }
    }

    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    for (pp.notes[0..pp.note_count]) |source_note| {
        const note = previewNote(source_note, app.piano_mouse_edit, steps_per_beat);
        if (note.pitch < bottom_pitch or note.pitch > top_pitch) continue;
        const x = grid_x + @as(f32, @floatCast(note.start_beat)) * beat_w;
        const width = @max(3, @as(f32, @floatCast(note.duration_beat)) * beat_w - 2);
        const y = grid_y + @as(f32, @floatFromInt(top_pitch - note.pitch)) * row_h + 2;
        const right = @min(x + width, origin[0] + canvas_w - 1);
        const start_step: u16 = ws.dsp.pattern.clampStep(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
        const selected = app.core.piano_cursor_pitch == note.pitch and app.core.piano_cursor_step == start_step;
        const note_alpha = 0.62 + std.math.clamp(note.velocity, 0, 1) * 0.38;
        draw_list.addRectFilled(.{ .pmin = .{ x + 1, y }, .pmax = .{ right, y + row_h - 4 }, .col = color(.{ theme.audio[0], theme.audio[1], theme.audio[2], note_alpha }), .rounding = 3 });
        draw_list.addLine(.{ .p1 = .{ x + 3, y + 2 }, .p2 = .{ x + 3, y + row_h - 6 }, .col = color(.{ theme.fg0[0], theme.fg0[1], theme.fg0[2], 0.72 }), .thickness = 2 });
        if (selected) {
            draw_list.addRect(.{ .pmin = .{ x, y - 1 }, .pmax = .{ right + 1, y + row_h - 3 }, .col = color(theme.rhythm), .rounding = 3, .thickness = 2 });
            draw_list.addRectFilled(.{ .pmin = .{ @max(x + 2, right - 5), y + 2 }, .pmax = .{ right, y + row_h - 6 }, .col = color(theme.rhythm), .rounding = 1 });
        }
    }
    pp.notes_lock.unlock();

    if (app.core.piano_cursor_pitch >= bottom_pitch and app.core.piano_cursor_pitch <= top_pitch and app.core.piano_cursor_step < steps) {
        const cursor_x = grid_x + @as(f32, @floatFromInt(app.core.piano_cursor_step)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const cursor_y = grid_y + @as(f32, @floatFromInt(top_pitch - app.core.piano_cursor_pitch)) * row_h;
        const cursor_beat = @as(f64, @floatFromInt(app.core.piano_cursor_step)) / @as(f64, @floatFromInt(steps_per_beat));
        const cursor_beats = if (pp.noteAt(app.core.piano_cursor_pitch, cursor_beat)) |note| note.duration_beat else app.core.piano_note_len;
        const cursor_w = @max(2, @as(f32, @floatCast(cursor_beats)) * beat_w);
        const cursor_right = @min(cursor_x + cursor_w - 1, origin[0] + canvas_w - 1);
        draw_list.addRectFilled(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ cursor_right, cursor_y + row_h - 1 },
            .col = color(.{ theme.focus[0], theme.focus[1], theme.focus[2], 0.18 }),
            .rounding = 2,
        });
        draw_list.addRect(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ cursor_right, cursor_y + row_h - 1 },
            .col = color(theme.focus),
            .rounding = 2,
            .thickness = 2,
        });
    }

    const snap = app.core.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = @mod(ws.types.framesToSeconds(snap.position_frames, app.core.session.project.sample_rate) * app.core.session.project.tempo_bpm / 60.0, pp.length_beats);
        const x = grid_x + @as(f32, @floatCast(play_beat)) * beat_w;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(theme.danger), .thickness = 2 });
    }

    const cell_w = beat_w / @as(f32, @floatFromInt(steps_per_beat));
    const pointer_step: usize = @intFromFloat(std.math.clamp(@floor((mouse[0] - grid_x) / cell_w), 0, @as(f32, @floatFromInt(steps - 1))));
    const pointer_row: usize = @intFromFloat(std.math.clamp(@floor((mouse[1] - grid_y) / row_h), 0, @as(f32, @floatFromInt(row_count - 1))));
    // Same guard as the row loop: the pointer can sit on a row below MIDI 0
    // when the roll is scrolled to the bottom of the keyboard. Clamped to 0
    // rather than skipped, since a hover still has to name some pitch.
    const pointer_pitch: u7 = rowPitch(top_pitch, pointer_row) orelse 0;

    // Key gutter: click (or slide down the keys) to hear the pitch, FL's
    // preview keyboard. Selects the row too, matching the drum/slicer
    // gutter-click convention.
    if (hovered and mouse[0] < grid_x and mouse[1] >= grid_y and zgui.isMouseDown(.left)) {
        if (zgui.isMouseClicked(.left) or pointer_pitch != app.core.piano_cursor_pitch) {
            app.core.piano_cursor_pitch = pointer_pitch;
            app.core.playNote(app.core.piano_track, pointer_pitch, app.core.now_ns);
        }
    }

    // Scroll wheel over the roll: pitch by semitone, ctrl for an octave
    // (the GUI's ctrl-is-coarse scroll convention), shift for FL's
    // horizontal scroll. Routed through the keys so audition and the shared
    // cursor-follow scrolling come along.
    if (hovered and gui_style.wheel_delta != 0) {
        gui_style.wheel_consumed = true;
        const up = gui_style.wheel_delta > 0;
        const key: u8 = if (zgui.isKeyDown(.mod_shift))
            (if (up) 'h' else 'l')
        else if (zgui.isKeyDown(.mod_ctrl))
            (if (up) 'K' else 'J')
        else
            (if (up) 'k' else 'j');
        app.core.handleKey(.{ .char = key }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }

    if (hovered and mouse[0] >= grid_x and mouse[1] >= grid_y) {
        const pointer_beat = @as(f64, @floatCast((mouse[0] - grid_x) / beat_w));
        if (zgui.isMouseClicked(.left)) {
            if (pp.noteCovering(pointer_pitch, pointer_beat)) |note| {
                const source_step: u16 = ws.dsp.pattern.clampStep(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
                const start_x = grid_x + @as(f32, @floatCast(note.start_beat)) * beat_w;
                const end_x = grid_x + @as(f32, @floatCast(note.start_beat + note.duration_beat)) * beat_w;
                app.core.piano_cursor_pitch = note.pitch;
                app.core.piano_cursor_step = source_step;
                app.piano_mouse_edit = .{
                    // Either edge resizes, the body moves. The right edge
                    // wins a note too short for both grab zones, since
                    // lengthening it is the way back out of that state.
                    .kind = if (mouse[0] >= end_x - 7) .resize else if (mouse[0] <= start_x + 7) .resize_left else .move,
                    .source_pitch = note.pitch,
                    .source_step = source_step,
                    .grab_step_offset = @intCast(pointer_step -| source_step),
                    .target_pitch = note.pitch,
                    .target_step = source_step,
                    .duration_steps = @max(1, ws.dsp.pattern.clampStep(@round(note.duration_beat * @as(f64, @floatFromInt(steps_per_beat))))),
                    .clone = zgui.isKeyDown(.mod_shift),
                };
            } else if (piano_ed.insertNoteAt(&app.core, pointer_pitch, @intCast(pointer_step))) {
                // FL's draw gesture: the note is placed on press and the
                // drag that follows sizes it, so `resize` picks up where the
                // insert left off (see `from_draw`).
                app.piano_mouse_edit = .{
                    .kind = .resize,
                    .from_draw = true,
                    .source_pitch = pointer_pitch,
                    .source_step = @intCast(pointer_step),
                    .target_pitch = pointer_pitch,
                    .target_step = @intCast(pointer_step),
                    .duration_steps = @max(1, ws.dsp.pattern.clampStep(@round(app.core.piano_note_len * @as(f64, @floatFromInt(steps_per_beat))))),
                };
            }
        } else if (zgui.isMouseDown(.right)) {
            // Right-drag is an erase brush (FL's delete tool): every note
            // swept goes, and the whole sweep is one undo entry - the same
            // record-once-per-gesture split the velocity lane's drag uses.
            if (pp.noteCovering(pointer_pitch, pointer_beat)) |note| {
                if (!app.core.piano_erase_active) {
                    history.recordMelodic(&app.core, app.core.piano_track);
                    app.core.piano_erase_active = true;
                }
                const start_step: u16 = ws.dsp.pattern.clampStep(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
                _ = piano_ed.eraseNoteAt(&app.core, note.pitch, start_step);
            }
        }
    }

    if (zgui.isMouseDown(.left)) {
        if (app.piano_mouse_edit) |*edit| {
            const before = edit.target_pitch;
            updateMouseEdit(edit, pointer_pitch, pointer_step);
            // Dragging a note across rows previews each pitch it lands on,
            // like FL's audible drag.
            if (edit.kind == .move and edit.target_pitch != before) {
                app.core.playNote(app.core.piano_track, edit.target_pitch, app.core.now_ns);
            }
        }
    }

    if (zgui.isMouseReleased(.left)) {
        if (app.piano_mouse_edit) |*active| {
            updateMouseEdit(active, pointer_pitch, pointer_step);
            const edit = active.*;
            switch (edit.kind) {
                .move => {
                    if (piano_ed.moveNoteTo(&app.core, edit.source_pitch, edit.source_step, edit.target_pitch, edit.target_step) and edit.clone) {
                        _ = piano_ed.cloneNoteBack(&app.core, edit.source_pitch, edit.source_step, edit.target_pitch, edit.target_step);
                    }
                },
                // A drawn note's length rides the insert's undo entry and
                // becomes the new default; a grabbed edge is its own edit.
                .resize => {
                    if (edit.from_draw) {
                        piano_ed.setDrawnLength(&app.core, edit.source_pitch, edit.source_step, edit.duration_steps);
                    } else {
                        _ = piano_ed.resizeNoteSteps(&app.core, edit.source_pitch, edit.source_step, edit.duration_steps);
                    }
                },
                .resize_left => _ = piano_ed.resizeNoteFromLeft(&app.core, edit.source_pitch, edit.source_step, edit.target_step),
            }
            app.piano_mouse_edit = null;
        }
    }
    zgui.spacing();
    drawVelocityLane(app, pp, canvas_w, gutter_w, beats, controller_h);
}

fn drawVelocityLane(app: anytype, pp: *ws.dsp.PatternPlayer, width: f32, gutter_w: f32, beats: f32, height: f32) void {
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("piano-velocity-lane", .{ .w = width, .h = height });
    const dragging = zgui.isItemActive();
    const draw_list = zgui.getWindowDrawList();
    const grid_x = origin[0] + gutter_w;
    const grid_w = width - gutter_w;
    const beat_w = grid_w / beats;
    // Before the notes_lock block below: the edit path locks for itself.
    if (dragging) dragVelocity(app, pp, origin, grid_x, beat_w, height);
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg0) });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ grid_x, origin[1] + height }, .col = color(theme.bg2) });
    draw_list.addText(.{ origin[0] + 8, origin[1] + 8 }, color(theme.rhythm), "VELOCITY", .{});
    draw_list.addText(.{ origin[0] + 8, origin[1] + 30 }, color(theme.fg3), "</> or drag", .{});

    const steps_per_beat = app.core.pianoStepsPerBeat();
    for (0..@as(usize, @intFromFloat(@ceil(beats))) + 1) |beat| {
        const x = grid_x + @as(f32, @floatFromInt(beat)) * beat_w;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = color(theme.line), .thickness = 1 });
    }
    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer pp.notes_lock.unlock();
    for (pp.notes[0..pp.note_count]) |note| {
        const x = grid_x + @as(f32, @floatCast(note.start_beat)) * beat_w;
        const bar_width = @max(3, beat_w / @as(f32, @floatFromInt(steps_per_beat)) - 2);
        const bar_height = std.math.clamp(note.velocity, 0.05, 1) * (height - 16);
        const start_step: u16 = ws.dsp.pattern.clampStep(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
        const selected = note.pitch == app.core.piano_cursor_pitch and start_step == app.core.piano_cursor_step;
        draw_list.addRectFilled(.{
            .pmin = .{ x + 1, origin[1] + height - bar_height },
            .pmax = .{ x + bar_width, origin[1] + height - 2 },
            .col = color(if (selected) theme.rhythm else .{ theme.audio[0], theme.audio[1], theme.audio[2], 0.72 }),
            .rounding = 2,
        });
        if (selected) {
            draw_list.addRect(.{
                .pmin = .{ x, origin[1] + height - bar_height - 1 },
                .pmax = .{ x + bar_width + 1, origin[1] + height - 1 },
                .col = color(theme.fg0),
                .rounding = 2,
                .thickness = 2,
            });
            draw_list.addLine(.{
                .p1 = .{ x + bar_width * 0.5, origin[1] },
                .p2 = .{ x + bar_width * 0.5, origin[1] + height },
                .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.42 }),
                .thickness = 1,
            });
        }
    }
}

/// Drag a velocity bar to its new height, one note per frame under the
/// pointer, so sweeping sideways shapes a whole phrase. The bar's top edge
/// tracks the mouse exactly (see `bar_height` above), and the drag is one
/// undo entry: the gesture flag clears in `App.draw` when the button comes
/// up, the same split the automation lane's drag drawing uses.
fn dragVelocity(app: anytype, pp: *ws.dsp.PatternPlayer, origin: [2]f32, grid_x: f32, beat_w: f32, height: f32) void {
    const mouse = zgui.getMousePos();
    if (mouse[0] < grid_x) return;
    const steps_per_beat = app.core.pianoStepsPerBeat();
    const cell_w = beat_w / @as(f32, @floatFromInt(steps_per_beat));
    const step_f = @floor((mouse[0] - grid_x) / cell_w);
    if (step_f >= @as(f32, @floatCast(pp.length_beats)) * @as(f32, @floatFromInt(steps_per_beat))) return;
    const step: u16 = ws.dsp.pattern.clampStep(step_f);
    const note = velocityBarAt(pp, app.core.piano_cursor_pitch, step, steps_per_beat) orelse return;
    const wanted = std.math.clamp((origin[1] + height - mouse[1]) / (height - 16), 0.05, 1.0);
    if (@abs(wanted - note.velocity) < 1e-4) return;
    if (!app.piano_velocity_edit_active) {
        history.recordMelodic(&app.core, app.core.piano_track);
        app.piano_velocity_edit_active = true;
    }
    _ = piano_ed.setVelocity(&app.core, note.pitch, step, wanted);
}

/// The bar under the velocity lane's pointer: the note starting on `step`
/// whose pitch is nearest the cursor's, since a chord stacks every voice's
/// bar into one column.
fn velocityBarAt(pp: *ws.dsp.PatternPlayer, cursor_pitch: u7, step: u16, steps_per_beat: usize) ?ws.dsp.pattern.Note {
    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer pp.notes_lock.unlock();
    var best: ?ws.dsp.pattern.Note = null;
    for (pp.notes[0..pp.note_count]) |note| {
        const start: u16 = ws.dsp.pattern.clampStep(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
        if (start != step) continue;
        const dist = @abs(@as(i32, note.pitch) - @as(i32, cursor_pitch));
        if (best == null or dist < @abs(@as(i32, best.?.pitch) - @as(i32, cursor_pitch))) best = note;
    }
    return best;
}

const isBlackKey = ws.theory.isBlackKey;

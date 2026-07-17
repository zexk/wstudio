//! Piano roll: scale-aware key gutter, note grid with mouse draw/move/resize,
//! ghost notes from other tracks, and the shared cursor/playhead overlays.

const std = @import("std");
const ws = @import("wstudio");
const icons = @import("../../tui/icons.zig");
const piano_ed = @import("../../tui/editors/piano.zig");
const gui_style = @import("../style.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const trackColor = gui_style.trackColor;
const patina = &gui_style.palette;

/// In-flight mouse edit; lives on the GUI App so it survives across frames.
pub const MouseEdit = struct {
    kind: enum { move, resize },
    source_pitch: u7,
    source_step: u16,
    grab_step_offset: u16 = 0,
};

fn drawToolbar(app: anytype) void {
    var scale_on = app.core.piano_scale != null;
    if (zgui.checkbox("SCALE", .{ .v = &scale_on })) {
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
    _ = zgui.checkbox("GHOST NOTES", .{ .v = &app.core.piano_ghost });

    zgui.sameLine(.{ .spacing = 14 });
    var triplet = app.core.piano_grid == .triplet;
    if (zgui.checkbox("TRIPLET", .{ .v = &triplet })) {
        app.core.handleKey(.{ .char = 'T' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }

    zgui.sameLine(.{ .spacing = 8 });
    if (zgui.button("- GRID##piano-grid-down", .{ .h = 27 })) {
        app.core.handleKey(.{ .char = 'Z' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
    zgui.sameLine(.{ .spacing = 4 });
    zgui.textColored(patina.audio, "{s}", .{app.core.piano_division.label()});
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
        zgui.textColored(patina.focus, "clip@bar {d}", .{link.start_bar + 1});
    } else if (app.core.session.song_mode) {
        zgui.sameLine(.{});
        zgui.textColored(patina.danger, "scratch: not in song until stamped from arrangement", .{});
    }
    if (app.core.piano_scale) |scale| {
        zgui.sameLine(.{});
        zgui.textColored(patina.modulation, "scale {s} {s}", .{ ws.theory.pitchClassName(scale.root), scale.kind.label() });
    }
    if (app.core.piano_grid == .triplet) {
        zgui.sameLine(.{});
        zgui.textColored(patina.rhythm, "triplet", .{});
    }
    zgui.sameLine(.{});
    zgui.textColored(patina.audio, "{s}", .{app.core.piano_division.label()});
    if (app.core.piano_ghost) {
        zgui.sameLine(.{});
        zgui.textDisabled("ghost", .{});
    }
    drawToolbar(app);
    zgui.textDisabled("click empty: draw   drag note: move   drag handle: resize   right-click: erase", .{});

    const gutter_w: f32 = 58;
    const ruler_h: f32 = 24;
    const row_h: f32 = 18;
    const row_count: usize = 37;
    const cursor_pitch: usize = app.core.piano_cursor_pitch;
    const current_top: usize = app.piano_top_pitch;
    const current_bottom = current_top -| (row_count - 1);
    if (cursor_pitch > current_top) app.piano_top_pitch = @intCast(cursor_pitch);
    if (cursor_pitch < current_bottom) app.piano_top_pitch = @intCast(@min(127, cursor_pitch + row_count - 1));
    const top_pitch: u7 = app.piano_top_pitch;
    const bottom_pitch: u7 = top_pitch -| @as(u7, @intCast(row_count - 1));
    const available = zgui.getContentRegionAvail();
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

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(patina.bg0) });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + gutter_w, origin[1] + ruler_h }, .col = color(patina.bg2) });

    for (0..row_count) |row| {
        const pitch: u7 = top_pitch - @as(u7, @intCast(row));
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        const black = isBlackKey(pitch);
        const tone = pianoScaleTone(app.core.piano_scale, pitch);
        const row_color = switch (tone) {
            .root => patina.bg3,
            .out_scale => patina.line_soft,
            .in_scale, .unscaled_white => patina.bg2,
            .unscaled_black => patina.bg1,
        };
        draw_list.addRectFilled(.{ .pmin = .{ grid_x, y }, .pmax = .{ origin[0] + canvas_w, y + row_h }, .col = color(row_color) });
        const key_color = if (black) patina.bg1 else patina.fg1;
        draw_list.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ grid_x, y + row_h }, .col = color(key_color) });
        if (black) draw_list.addRectFilled(.{ .pmin = .{ origin[0], y + 1 }, .pmax = .{ origin[0] + 37, y + row_h - 1 }, .col = color(patina.bg0) });
        draw_list.addLine(.{ .p1 = .{ origin[0], y + row_h }, .p2 = .{ origin[0] + canvas_w, y + row_h }, .col = color(patina.line), .thickness = if (@mod(pitch, 12) == 0) 1.5 else 1 });
        var note_buf: [5]u8 = undefined;
        const note_name = ws.midi.noteName(pitch, &note_buf);
        const label_x = grid_x - zgui.calcTextSize(note_name, .{})[0] - 4;
        draw_list.addText(.{ label_x, y + 1 }, color(if (black) patina.fg0 else patina.bg0), "{s}", .{note_name});
    }

    const steps_per_beat: usize = app.core.pianoStepsPerBeat();
    const steps: usize = @intFromFloat(@ceil(beats * @as(f32, @floatFromInt(steps_per_beat))));
    if (app.core.modal.mode == .visual) {
        const anchor = @min(@as(usize, app.core.piano_visual_anchor orelse app.core.piano_cursor_step), steps - 1);
        const cursor_step = @min(@as(usize, app.core.piano_cursor_step), steps - 1);
        const lo = @min(anchor, cursor_step);
        const hi = @max(anchor, cursor_step);
        const x1 = grid_x + @as(f32, @floatFromInt(lo)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const x2 = grid_x + @as(f32, @floatFromInt(hi + 1)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        draw_list.addRectFilled(.{ .pmin = .{ x1, grid_y }, .pmax = .{ x2, origin[1] + canvas_h }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.12 }) });
        draw_list.addRect(.{ .pmin = .{ x1 + 1, grid_y + 1 }, .pmax = .{ x2 - 1, origin[1] + canvas_h - 1 }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.55 }), .thickness = 1 });
    }
    for (0..steps + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const on_beat = step % steps_per_beat == 0;
        const on_bar = step % (steps_per_beat * app.core.session.project.beats_per_bar) == 0;
        draw_list.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) patina.bg5 else if (on_beat) patina.bg4 else patina.line), .thickness = if (on_bar) 2 else 1 });
        if (on_beat and step < steps) draw_list.addText(.{ x + 5, origin[1] + 4 }, color(patina.fg2), "{d}.{d}", .{ step / (steps_per_beat * app.core.session.project.beats_per_bar) + 1, step / steps_per_beat % app.core.session.project.beats_per_bar + 1 });
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
    for (pp.notes[0..pp.note_count]) |note| {
        if (note.pitch < bottom_pitch or note.pitch > top_pitch) continue;
        const x = grid_x + @as(f32, @floatCast(note.start_beat)) * beat_w;
        const width = @max(3, @as(f32, @floatCast(note.duration_beat)) * beat_w - 2);
        const y = grid_y + @as(f32, @floatFromInt(top_pitch - note.pitch)) * row_h + 2;
        const right = @min(x + width, origin[0] + canvas_w - 1);
        const start_step: u16 = @intFromFloat(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
        const selected = app.core.piano_cursor_pitch == note.pitch and app.core.piano_cursor_step == start_step;
        const note_alpha = 0.62 + std.math.clamp(note.velocity, 0, 1) * 0.38;
        draw_list.addRectFilled(.{ .pmin = .{ x + 1, y }, .pmax = .{ right, y + row_h - 4 }, .col = color(.{ patina.audio[0], patina.audio[1], patina.audio[2], note_alpha }), .rounding = 3 });
        draw_list.addLine(.{ .p1 = .{ x + 3, y + 2 }, .p2 = .{ x + 3, y + row_h - 6 }, .col = color(.{ patina.fg0[0], patina.fg0[1], patina.fg0[2], 0.72 }), .thickness = 2 });
        if (selected) {
            draw_list.addRect(.{ .pmin = .{ x, y - 1 }, .pmax = .{ right + 1, y + row_h - 3 }, .col = color(patina.rhythm), .rounding = 3, .thickness = 2 });
            draw_list.addRectFilled(.{ .pmin = .{ @max(x + 2, right - 5), y + 2 }, .pmax = .{ right, y + row_h - 6 }, .col = color(patina.rhythm), .rounding = 1 });
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
            .col = color(.{ patina.focus[0], patina.focus[1], patina.focus[2], 0.18 }),
            .rounding = 2,
        });
        draw_list.addRect(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ cursor_right, cursor_y + row_h - 1 },
            .col = color(patina.focus),
            .rounding = 2,
            .thickness = 2,
        });
    }

    const snap = app.core.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = @mod(ws.types.framesToSeconds(snap.position_frames, app.core.session.project.sample_rate) * app.core.session.project.tempo_bpm / 60.0, pp.length_beats);
        const x = grid_x + @as(f32, @floatCast(play_beat)) * beat_w;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(patina.danger), .thickness = 2 });
    }

    const cell_w = beat_w / @as(f32, @floatFromInt(steps_per_beat));
    const pointer_step: usize = @intFromFloat(std.math.clamp(@floor((mouse[0] - grid_x) / cell_w), 0, @as(f32, @floatFromInt(steps - 1))));
    const pointer_row: usize = @intFromFloat(std.math.clamp(@floor((mouse[1] - grid_y) / row_h), 0, @as(f32, @floatFromInt(row_count - 1))));
    const pointer_pitch: u7 = top_pitch - @as(u7, @intCast(pointer_row));

    if (hovered and mouse[0] >= grid_x and mouse[1] >= grid_y) {
        const pointer_beat = @as(f64, @floatCast((mouse[0] - grid_x) / beat_w));
        if (zgui.isMouseClicked(.left)) {
            if (noteCovering(pp, pointer_pitch, pointer_beat)) |note| {
                const source_step: u16 = @intFromFloat(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
                const end_x = grid_x + @as(f32, @floatCast(note.start_beat + note.duration_beat)) * beat_w;
                app.core.piano_cursor_pitch = note.pitch;
                app.core.piano_cursor_step = source_step;
                app.piano_mouse_edit = .{
                    .kind = if (mouse[0] >= end_x - 7) .resize else .move,
                    .source_pitch = note.pitch,
                    .source_step = source_step,
                    .grab_step_offset = @intCast(pointer_step -| source_step),
                };
            } else {
                app.core.piano_cursor_pitch = pointer_pitch;
                app.core.piano_cursor_step = @intCast(pointer_step);
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
        } else if (zgui.isMouseClicked(.right)) {
            if (noteCovering(pp, pointer_pitch, pointer_beat)) |note| {
                app.core.piano_cursor_pitch = note.pitch;
                app.core.piano_cursor_step = @intFromFloat(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
                app.core.handleKey(.{ .char = 'x' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
        }
    }

    if (zgui.isMouseReleased(.left)) {
        if (app.piano_mouse_edit) |edit| {
            switch (edit.kind) {
                .move => {
                    const target_step: u16 = @intCast(pointer_step -| edit.grab_step_offset);
                    _ = piano_ed.moveNoteTo(&app.core, edit.source_pitch, edit.source_step, pointer_pitch, target_step);
                },
                .resize => {
                    const duration: u16 = @intCast(@max(1, pointer_step + 1 -| edit.source_step));
                    _ = piano_ed.resizeNoteSteps(&app.core, edit.source_pitch, edit.source_step, duration);
                },
            }
            app.piano_mouse_edit = null;
        }
    }
}

fn noteCovering(pp: *ws.dsp.PatternPlayer, pitch: u7, beat: f64) ?ws.dsp.pattern.Note {
    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer pp.notes_lock.unlock();
    for (pp.notes[0..pp.note_count]) |note| {
        if (note.pitch == pitch and beat >= note.start_beat and beat < note.start_beat + note.duration_beat) return note;
    }
    return null;
}

const isBlackKey = ws.theory.isBlackKey;

const PianoScaleTone = enum { root, in_scale, out_scale, unscaled_black, unscaled_white };

fn pianoScaleTone(scale: ?ws.theory.Scale, pitch: u7) PianoScaleTone {
    if (scale) |active| {
        if (pitch % 12 == active.root) return .root;
        return if (active.contains(pitch)) .in_scale else .out_scale;
    }
    return if (isBlackKey(pitch)) .unscaled_black else .unscaled_white;
}

test "GUI piano scale keeps black-key members highlighted" {
    const f_minor: ws.theory.Scale = .{ .root = 5, .kind = .minor };
    try std.testing.expectEqual(PianoScaleTone.root, pianoScaleTone(f_minor, 65));
    try std.testing.expectEqual(PianoScaleTone.in_scale, pianoScaleTone(f_minor, 68));
    try std.testing.expectEqual(PianoScaleTone.out_scale, pianoScaleTone(f_minor, 66));
    try std.testing.expectEqual(PianoScaleTone.unscaled_black, pianoScaleTone(null, 68));
}

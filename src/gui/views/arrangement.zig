//! Song-mode arrangement timeline: lanes per track, clip blocks with note or
//! pattern previews, bar ruler, visual-range highlight, and click-to-place.

const std = @import("std");
const ws = @import("wstudio");
const icons = @import("../../ui/icons.zig");
const gui_style = @import("../style.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const patina = &gui_style.palette;

pub fn draw(app: anytype) void {
    zgui.textDisabled(icons.arrangement ++ "  ARRANGEMENT", .{});
    zgui.sameLine(.{});
    zgui.textColored(if (app.core.session.song_mode) patina.audio else patina.fg3, "{s}", .{if (app.core.session.song_mode) "SONG" else "PATTERN"});
    zgui.sameLine(.{});
    zgui.textColored(patina.audio, "{s}", .{app.core.arr_grid.label()});
    const track_count = app.core.session.project.tracks.items.len;
    const ticks_per_beat = ws.time_grid.ticks_per_beat;
    const beats_per_bar: u32 = app.core.session.project.beats_per_bar;
    const ticks_per_bar = ws.time_grid.barTicks(app.core.session.project.beats_per_bar);
    const content_ticks = app.core.session.arrangement.lengthTicks();
    const cursor_tick = app.core.arr_cursor_bar *| app.core.arr_grid.ticks();
    const cursor_bar_count = cursor_tick / ticks_per_bar + 1;
    const content_bar_count = content_ticks / ticks_per_bar + @intFromBool(content_ticks % ticks_per_bar != 0);
    const bar_count: u32 = @max(8, @max(content_bar_count, cursor_bar_count));
    const gutter_w: f32 = 132;
    const ruler_h: f32 = 30;
    const available = zgui.getContentRegionAvail();
    const inspector_h: f32 = if (app.arrangement_clip != null) 116 else 82;
    const lane_h: f32 = if (track_count == 0)
        58
    else
        std.math.clamp((available[1] - inspector_h - ruler_h - 12) / @as(f32, @floatFromInt(track_count)), 58, 112);
    const canvas_w = @max(420, available[0]);
    const canvas_h = ruler_h + lane_h * @as(f32, @floatFromInt(track_count));
    const origin = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton("arrangement-canvas", .{ .w = canvas_w, .h = canvas_h });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    const timeline_x = origin[0] + gutter_w;
    const timeline_w = canvas_w - gutter_w;
    const total_beats_u64 = @as(u64, bar_count) * beats_per_bar;
    const total_beats: f32 = @floatFromInt(total_beats_u64);
    const beat_w = timeline_w / total_beats;

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(patina.bg0) });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + ruler_h }, .col = color(patina.bg2) });

    for (0..track_count) |ti| {
        const y = origin[1] + ruler_h + @as(f32, @floatFromInt(ti)) * lane_h;
        const selected = ti == app.core.cursor;
        draw_list.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ timeline_x, y + lane_h }, .col = color(if (selected) patina.bg4 else patina.bg2) });
        draw_list.addRectFilled(.{ .pmin = .{ timeline_x, y }, .pmax = .{ origin[0] + canvas_w, y + lane_h }, .col = color(if (selected) patina.bg3 else if (ti % 2 == 0) patina.bg1 else patina.bg0) });
        draw_list.addText(.{ origin[0] + 10, y + 11 }, color(if (selected) patina.fg0 else patina.fg1), "{d:0>2}  {s}", .{ ti + 1, app.core.session.project.tracks.items[ti].name });
        const rack = app.core.session.racks.items[ti];
        const rack_label: []const u8 = if (std.meta.activeTag(rack.instrument) == .empty) "-- empty --" else rack.label;
        draw_list.addText(.{ origin[0] + 34, y + 32 }, color(patina.fg3), "[{s}]", .{rack_label});
        const lane = app.core.session.arrangement.lane(@intCast(ti));
        if (lane == null or lane.?.clips.items.len == 0) {
            draw_list.addText(.{ timeline_x + 12, y + lane_h * 0.5 - 8 }, color(if (selected) patina.fg2 else patina.fg3), "{s}", .{if (selected) "Press s to stamp a clip at the cursor" else "Empty lane"});
        }
        draw_list.addLine(.{ .p1 = .{ origin[0], y + lane_h }, .p2 = .{ origin[0] + canvas_w, y + lane_h }, .col = color(patina.line), .thickness = 1 });
    }

    const max_grid_lines = 4096;
    const total_ticks_u64 = total_beats_u64 * ticks_per_beat;
    const grid_ticks: u64 = app.core.arr_grid.ticks();
    const tick_stride: u64 = @max(grid_ticks, grid_ticks * ((total_ticks_u64 / grid_ticks + max_grid_lines - 1) / max_grid_lines));
    var tick_index: u64 = 0;
    while (tick_index <= total_ticks_u64) : (tick_index += tick_stride) {
        const x = timeline_x + @as(f32, @floatFromInt(tick_index)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const on_bar = tick_index % ticks_per_bar == 0;
        const on_beat = tick_index % ticks_per_beat == 0;
        draw_list.addLine(.{
            .p1 = .{ x, if (on_bar) origin[1] else origin[1] + ruler_h },
            .p2 = .{ x, origin[1] + canvas_h },
            .col = color(if (on_bar) patina.bg5 else if (on_beat) patina.line else .{ patina.line[0], patina.line[1], patina.line[2], patina.line[3] * 0.5 }),
            .thickness = if (on_bar) 1.5 else 1,
        });
        if (on_bar and tick_index < total_ticks_u64) draw_list.addText(.{ x + 7, origin[1] + 7 }, color(patina.fg2), "{d}", .{tick_index / ticks_per_bar + 1});
    }

    if (app.core.modal.mode == .visual and app.core.cursor < track_count) {
        const anchor = (app.core.arr_visual_anchor orelse app.core.arr_cursor_bar) * app.core.arr_grid.ticks();
        const lo = @min(anchor, cursor_tick);
        const hi = @max(anchor, cursor_tick) + app.core.arr_grid.ticks();
        const x1 = timeline_x + @as(f32, @floatFromInt(lo)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const x2 = timeline_x + @as(f32, @floatFromInt(hi)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const y = origin[1] + ruler_h + @as(f32, @floatFromInt(app.core.cursor)) * lane_h;
        draw_list.addRectFilled(.{ .pmin = .{ x1, y }, .pmax = .{ x2, y + lane_h }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.14 }) });
        draw_list.addRect(.{ .pmin = .{ x1 + 1, y + 1 }, .pmax = .{ x2 - 1, y + lane_h - 1 }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.6 }), .thickness = 1 });
    }

    for (app.core.session.arrangement.lanes.items, 0..) |lane, ti| {
        if (ti >= track_count) break;
        const lane_y = origin[1] + ruler_h + @as(f32, @floatFromInt(ti)) * lane_h;
        for (lane.clips.items, 0..) |clip, ci| {
            const x = timeline_x + @as(f32, @floatFromInt(clip.start_tick)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
            const clip_w = @max(8, @as(f32, @floatFromInt(clip.length_ticks)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w - 2);
            const pmin = [2]f32{ x + 1, lane_y + 5 };
            const pmax = [2]f32{ @min(x + clip_w, origin[0] + canvas_w - 1), lane_y + lane_h - 5 };
            const selected = if (app.arrangement_clip) |selection| selection.track == ti and selection.clip == ci else false;
            const clip_color: [4]f32 = switch (clip.content) {
                .melodic => .{ patina.audio[0], patina.audio[1], patina.audio[2], if (selected) 1 else 0.68 },
                .drum => .{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], if (selected) 1 else 0.68 },
            };
            draw_list.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = color(clip_color), .rounding = 4 });
            draw_list.addRectFilled(.{
                .pmin = pmin,
                .pmax = .{ pmax[0], @min(pmax[1], pmin[1] + 22) },
                .col = color(.{ patina.bg0[0], patina.bg0[1], patina.bg0[2], if (selected) 0.58 else 0.38 }),
                .rounding = 4,
            });
            if (selected) {
                draw_list.addRect(.{ .pmin = .{ pmin[0] - 1, pmin[1] - 1 }, .pmax = .{ pmax[0] + 1, pmax[1] + 1 }, .col = color(patina.fg0), .rounding = 5, .thickness = 3 });
                draw_list.addRectFilled(.{ .pmin = .{ pmin[0], pmin[1] }, .pmax = .{ pmin[0] + 5, pmax[1] }, .col = color(patina.focus), .rounding = 3 });
            }
            switch (clip.content) {
                .melodic => |melodic| {
                    draw_list.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(patina.fg0), "MIDI  {d}", .{melodic.notes.len});
                    var min_pitch: u7 = 127;
                    var max_pitch: u7 = 0;
                    for (melodic.notes) |note| {
                        min_pitch = @min(min_pitch, note.pitch);
                        max_pitch = @max(max_pitch, note.pitch);
                    }
                    const pitch_span: f32 = @floatFromInt(@max(12, max_pitch -| min_pitch));
                    for (melodic.notes) |note| {
                        const note_x = pmin[0] + @as(f32, @floatCast(note.start_beat / melodic.length_beats)) * (pmax[0] - pmin[0]);
                        const preview_height = @max(8, pmax[1] - pmin[1] - 29);
                        const note_y = pmin[1] + 26 + @as(f32, @floatFromInt(max_pitch - note.pitch)) / pitch_span * preview_height;
                        const note_w = @max(2, @as(f32, @floatCast(note.duration_beat / melodic.length_beats)) * (pmax[0] - pmin[0]));
                        draw_list.addLine(.{ .p1 = .{ note_x, note_y }, .p2 = .{ @min(note_x + note_w, pmax[0] - 2), note_y }, .col = color(.{ patina.fg0[0], patina.fg0[1], patina.fg0[2], 0.72 }), .thickness = 2 });
                    }
                },
                .drum => |drum| {
                    draw_list.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(patina.bg0), "PATTERN {c}", .{'A' + drum.variant});
                    if (drum.step_count > 0) {
                        for (0..drum.step_count) |step| {
                            if (step % 4 != 0) continue;
                            const grid_x = pmin[0] + (@as(f32, @floatFromInt(step)) + 0.5) / @as(f32, @floatFromInt(drum.step_count)) * (pmax[0] - pmin[0]);
                            draw_list.addLine(.{
                                .p1 = .{ grid_x, pmin[1] + 27 },
                                .p2 = .{ grid_x, pmax[1] - 5 },
                                .col = color(.{ patina.bg0[0], patina.bg0[1], patina.bg0[2], 0.24 }),
                                .thickness = 1,
                            });
                        }
                    }
                    for (0..drum.step_count) |step| {
                        var hits: u8 = 0;
                        for (drum.pattern) |pattern| hits += @intCast((pattern >> @intCast(step)) & 1);
                        if (hits == 0) continue;
                        const hit_x = pmin[0] + (@as(f32, @floatFromInt(step)) + 0.5) / @as(f32, @floatFromInt(drum.step_count)) * (pmax[0] - pmin[0]);
                        const hit_h = @min(15, @as(f32, @floatFromInt(hits)) * 2);
                        draw_list.addLine(.{ .p1 = .{ hit_x, pmax[1] - 6 }, .p2 = .{ hit_x, pmax[1] - 6 - hit_h }, .col = color(.{ patina.bg0[0], patina.bg0[1], patina.bg0[2], 0.72 }), .thickness = 2 });
                    }
                },
            }
            if (clip.automation.gain.len + clip.automation.pan.len + clip.automation.synth_params.items.len > 0) draw_list.addText(.{ pmax[0] - 16, pmin[1] + 4 }, color(patina.modulation), "A", .{});
        }
    }

    if (app.core.cursor < track_count) {
        var cursor_start_tick = cursor_tick;
        var cursor_span_ticks = app.core.session.stampLengthTicks(app.core.cursor);
        if (app.core.session.arrangement.lane(app.core.cursor)) |lane| {
            if (lane.clipAt(cursor_tick)) |clip| {
                cursor_start_tick = clip.start_tick;
                cursor_span_ticks = clip.length_ticks;
            }
        }
        cursor_span_ticks = @max(cursor_span_ticks, app.core.arr_grid.ticks());
        const cursor_x = timeline_x + @as(f32, @floatFromInt(cursor_start_tick)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const cursor_w = @max(2, @as(f32, @floatFromInt(cursor_span_ticks)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w);
        const cursor_y = origin[1] + ruler_h + @as(f32, @floatFromInt(app.core.cursor)) * lane_h;
        draw_list.addRectFilled(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ @min(cursor_x + cursor_w, origin[0] + canvas_w - 1), cursor_y + lane_h - 1 },
            .col = color(.{ patina.focus[0], patina.focus[1], patina.focus[2], 0.16 }),
        });
        draw_list.addRect(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ @min(cursor_x + cursor_w, origin[0] + canvas_w - 1), cursor_y + lane_h - 1 },
            .col = color(patina.focus),
            .thickness = 2,
        });
    }

    const snap = app.core.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = ws.types.framesToSeconds(snap.position_frames, app.core.session.project.sample_rate) * app.core.session.project.tempo_bpm / 60.0;
        const x = timeline_x + @as(f32, @floatCast(play_beat)) * beat_w;
        if (x <= origin[0] + canvas_w) draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(patina.danger), .thickness = 2 });
    }

    if (clicked and hovered and mouse[1] >= origin[1] + ruler_h) {
        const ti = @min(track_count - 1, @as(usize, @intFromFloat((mouse[1] - origin[1] - ruler_h) / lane_h)));
        app.core.cursor = ti;
        app.arrangement_clip = null;
        if (mouse[0] >= timeline_x and ti < app.core.session.arrangement.lanes.items.len) {
            const tick: u32 = @intFromFloat((mouse[0] - timeline_x) / beat_w * @as(f32, @floatFromInt(ticks_per_beat)));
            app.core.arr_cursor_bar = tick / app.core.arr_grid.ticks();
            for (app.core.session.arrangement.lanes.items[ti].clips.items, 0..) |clip, ci| {
                if (clip.covers(tick)) {
                    app.arrangement_clip = .{ .track = ti, .clip = ci };
                    break;
                }
            }
        }
    }
    zgui.spacing();
    drawArrangementInspector(app);
}

fn drawArrangementInspector(app: anytype) void {
    const selection = app.arrangement_clip orelse return;
    if (zgui.beginChild("arrangement-inspector", .{ .w = 0, .h = 108, .child_flags = .{ .border = true } })) {
        const clip = app.core.session.arrangement.lanes.items[selection.track].clips.items[selection.clip];
        zgui.textColored(patina.focus, "SELECTED CLIP", .{});
        zgui.separator();
        zgui.text("Track {d:0>2}", .{selection.track + 1});
        zgui.sameLine(.{ .spacing = 24 });
        zgui.textDisabled("start  {d:.2} beats", .{@as(f32, @floatFromInt(clip.start_tick)) / ws.time_grid.ticks_per_beat});
        zgui.sameLine(.{ .spacing = 24 });
        zgui.textDisabled("length  {d:.2} beats", .{@as(f32, @floatFromInt(clip.length_ticks)) / ws.time_grid.ticks_per_beat});
        zgui.sameLine(.{ .spacing = 24 });
        zgui.textDisabled("{s}", .{switch (clip.content) {
            .melodic => "MIDI",
            .drum => "DRUM PATTERN",
        }});
        zgui.spacing();
        zgui.textDisabled("x delete   h/l move   H/L resize   a automation", .{});
    }
    zgui.endChild();
}

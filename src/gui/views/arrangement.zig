//! Song-mode arrangement timeline: lanes per track, clip blocks with note or
//! pattern previews, bar ruler, visual-range highlight, and click-to-place.

const std = @import("std");
const ws = @import("wstudio");
const icons = @import("../../ui/icons.zig");
const gui_style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const zgui = @import("zgui");
const shared_step_grid = @import("../../ui/editors/step_grid.zig");
const scroll = @import("../scroll.zig");

const color = gui_style.color;
const theme = &gui_style.palette;

pub const ClipSelection = struct { track: usize, clip: usize, start_tick: u32 };
pub const ClipDrag = struct { selection: ClipSelection, target_tick: u32, grab_offset_tick: u32 };

fn clipSelectionValid(arrangement: *const ws.Arrangement, selection: ClipSelection) bool {
    if (selection.track >= arrangement.lanes.items.len) return false;
    const clips = arrangement.lanes.items[selection.track].clips.items;
    return selection.clip < clips.len and clips[selection.clip].start_tick == selection.start_tick;
}

pub fn draw(app: anytype) void {
    if (app.arrangement_clip) |selection| {
        if (!clipSelectionValid(&app.core.session.arrangement, selection)) app.arrangement_clip = null;
    }
    zgui.textDisabled(icons.arrangement ++ "  ARRANGEMENT", .{});
    zgui.sameLine(.{});
    zgui.textColored(if (app.core.session.song_mode) theme.audio else theme.fg3, "{s}", .{if (app.core.session.song_mode) "SONG" else "PATTERN"});
    zgui.sameLine(.{});
    zgui.textColored(theme.audio, "{s}", .{app.core.arr_grid.label()});
    zgui.sameLine(.{ .spacing = 8 });
    if (widgets.iconButton(icons.minus ++ "##arr-grid-down", "Coarser grid  zG")) {
        const now_ns = std.Io.Timestamp.now(app.core.io, .awake).nanoseconds;
        app.core.handleKey(.{ .char = 'z' }, now_ns);
        app.core.handleKey(.{ .char = 'G' }, now_ns);
    }
    zgui.sameLine(.{ .spacing = 4 });
    if (widgets.iconButton(icons.plus ++ "##arr-grid-up", "Finer grid  zg")) {
        const now_ns = std.Io.Timestamp.now(app.core.io, .awake).nanoseconds;
        app.core.handleKey(.{ .char = 'z' }, now_ns);
        app.core.handleKey(.{ .char = 'g' }, now_ns);
    }
    const track_count = app.core.session.project.tracks.items.len;
    const ticks_per_beat = ws.time_grid.ticks_per_beat;
    const beats_per_bar: u32 = app.core.session.project.beats_per_bar;
    const ticks_per_bar = ws.time_grid.barTicks(app.core.session.project.beats_per_bar, app.core.session.project.meter_denominator);
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
        std.math.clamp((available[1] - inspector_h - ruler_h - 12) / @as(f32, @floatFromInt(track_count)), 58, 160);
    const canvas_w = @max(420, available[0]);
    const canvas_h = ruler_h + lane_h * @as(f32, @floatFromInt(track_count));
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("arrangement-canvas", .{ .w = canvas_w, .h = canvas_h });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    const timeline_x = origin[0] + gutter_w;
    const timeline_w = canvas_w - gutter_w;
    const total_beats_u64 = @as(u64, bar_count) * beats_per_bar;
    const total_beats: f32 = @floatFromInt(total_beats_u64);
    const beat_w = timeline_w / total_beats;

    if (app.arrangement_drag) |*drag| {
        if (zgui.isMouseDown(.left)) {
            if (mouse[0] >= timeline_x) {
                const raw_tick: u32 = @intFromFloat(@max(0, (mouse[0] - timeline_x) / beat_w * @as(f32, @floatFromInt(ticks_per_beat))));
                const start_tick = raw_tick -| drag.grab_offset_tick;
                drag.target_tick = start_tick / app.core.arr_grid.ticks() * app.core.arr_grid.ticks();
            }
        } else {
            finishClipDrag(app, drag.*);
            app.arrangement_drag = null;
        }
    }

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(theme.bg0) });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + ruler_h }, .col = color(theme.bg2) });

    for (0..track_count) |ti| {
        const y = origin[1] + ruler_h + @as(f32, @floatFromInt(ti)) * lane_h;
        const selected = ti == app.core.cursor;
        scroll.noteFocusRow(selected, y, lane_h);
        draw_list.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ timeline_x, y + lane_h }, .col = color(if (selected) theme.bg4 else theme.bg2) });
        draw_list.addRectFilled(.{ .pmin = .{ timeline_x, y }, .pmax = .{ origin[0] + canvas_w, y + lane_h }, .col = color(if (selected) theme.bg3 else if (ti % 2 == 0) theme.bg1 else theme.bg0) });
        draw_list.addText(.{ origin[0] + 10, y + 11 }, color(if (selected) theme.fg0 else theme.fg1), "{d:0>2}  {s}", .{ ti + 1, app.core.session.project.tracks.items[ti].name });
        const rack = app.core.session.racks.items[ti];
        const rack_label: []const u8 = if (std.meta.activeTag(rack.instrument) == .empty) "-- empty --" else rack.label;
        draw_list.addText(.{ origin[0] + 34, y + 32 }, color(theme.fg3), "[{s}]", .{rack_label});
        // Only the cursor's lane gets a hint. Labelling every other empty
        // lane "Empty lane" says nothing the blank row didn't already.
        const lane = app.core.session.arrangement.lane(@intCast(ti));
        if (selected and (lane == null or lane.?.clips.items.len == 0)) {
            draw_list.addText(.{ timeline_x + 12, y + lane_h * 0.5 - 8 }, color(theme.fg2), "Press s to stamp a clip at the cursor", .{});
        }
        draw_list.addLine(.{ .p1 = .{ origin[0], y + lane_h }, .p2 = .{ origin[0] + canvas_w, y + lane_h }, .col = color(theme.line), .thickness = 1 });
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
            .col = color(if (on_bar) theme.bg5 else if (on_beat) theme.line else .{ theme.line[0], theme.line[1], theme.line[2], theme.line[3] * 0.5 }),
            .thickness = if (on_bar) 1.5 else 1,
        });
        if (on_bar and tick_index < total_ticks_u64) draw_list.addText(.{ x + 7, origin[1] + 7 }, color(theme.fg2), "{d}", .{tick_index / ticks_per_bar + 1});
    }

    for (app.core.session.project.sections.items) |section| {
        const x = timeline_x + @as(f32, @floatFromInt(section.tick)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        if (x < timeline_x or x > origin[0] + canvas_w) continue;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(theme.focus), .thickness = 2 });
        draw_list.addText(.{ x + 5, origin[1] + 7 }, color(theme.focus), "{s}", .{section.name});
    }

    if (app.core.modal.mode == .visual and app.core.cursor < track_count) {
        const anchor = (app.core.arr_visual_anchor orelse app.core.arr_cursor_bar) *| app.core.arr_grid.ticks();
        const lo = @min(anchor, cursor_tick);
        const hi = @max(anchor, cursor_tick) +| app.core.arr_grid.ticks();
        const x1 = timeline_x + @as(f32, @floatFromInt(lo)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const x2 = timeline_x + @as(f32, @floatFromInt(hi)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        // The lane axis: `v` (blockwise) bounds it to the anchored band,
        // `V` (linewise) leaves the anchor null and the rectangle spans
        // every lane. See editors/step_grid.zig's rowRange.
        const lanes = shared_step_grid.rowRange(usize, app.core.arr_visual_lane_anchor, app.core.cursor, track_count);
        const y = origin[1] + ruler_h + @as(f32, @floatFromInt(lanes.lo)) * lane_h;
        const y2 = origin[1] + ruler_h + @as(f32, @floatFromInt(lanes.hi + 1)) * lane_h;
        draw_list.addRectFilled(.{ .pmin = .{ x1, y }, .pmax = .{ x2, y2 }, .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.14 }) });
        draw_list.addRect(.{ .pmin = .{ x1 + 1, y + 1 }, .pmax = .{ x2 - 1, y2 - 1 }, .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.6 }), .thickness = 1 });
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
            // The lane's own track colour when it has one, else the content
            // accent (audio/rhythm) the clip used before track colours
            // reached this view - same fallback tui/views/arrangement.zig
            // makes with `track_color orelse acc`.
            const track_col = app.core.session.project.tracks.items[ti].color;
            const base: [4]f32 = if (track_col > 0) gui_style.trackColor(track_col) else switch (clip.content) {
                .melodic => theme.audio,
                .drum => theme.rhythm,
                .audio => theme.audio,
            };
            const clip_color: [4]f32 = .{ base[0], base[1], base[2], if (selected) 1 else 0.68 };
            // Labels and previews sit on the darkened header strip / clip
            // body, so their ink follows the fill instead of assuming a
            // bright accent.
            const ink = gui_style.legibleOn(base);
            draw_list.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = color(clip_color), .rounding = 4 });
            draw_list.addRectFilled(.{
                .pmin = pmin,
                .pmax = .{ pmax[0], @min(pmax[1], pmin[1] + 22) },
                .col = color(.{ theme.bg0[0], theme.bg0[1], theme.bg0[2], if (selected) 0.58 else 0.38 }),
                .rounding = 4,
            });
            if (selected) {
                draw_list.addRect(.{ .pmin = .{ pmin[0] - 1, pmin[1] - 1 }, .pmax = .{ pmax[0] + 1, pmax[1] + 1 }, .col = color(theme.fg0), .rounding = 5, .thickness = 3 });
                draw_list.addRectFilled(.{ .pmin = .{ pmin[0], pmin[1] }, .pmax = .{ pmin[0] + 5, pmax[1] }, .col = color(theme.focus), .rounding = 3 });
            }
            switch (clip.content) {
                .melodic => |melodic| {
                    draw_list.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(ink), "MIDI  {d}", .{melodic.notes.len});
                    var min_pitch: u7 = 127;
                    var max_pitch: u7 = 0;
                    for (melodic.notes) |note| {
                        min_pitch = @min(min_pitch, note.pitch);
                        max_pitch = @max(max_pitch, note.pitch);
                    }
                    const pitch_span: f32 = @floatFromInt(@max(12, max_pitch -| min_pitch));
                    const preview_height = @max(8, pmax[1] - pmin[1] - 29);
                    // beat_w is px-per-beat everywhere else in this view, so laying
                    // notes out on it (instead of normalizing to the box width) keeps
                    // the preview at the timeline's real scale. That's what lets it
                    // repeat the pattern to fill a stretched clip or cut it off at a
                    // chopped one, matching rebuildSongData's actual loop/truncate.
                    if (melodic.length_beats > 0) {
                        const pattern_px = @as(f32, @floatCast(melodic.length_beats)) * beat_w;
                        var repeat_x = pmin[0];
                        var reps: u32 = 0;
                        while (repeat_x < pmax[0] and reps < 256) : (repeat_x += pattern_px) {
                            if (reps > 0) {
                                draw_list.addLine(.{ .p1 = .{ repeat_x, pmin[1] + 22 }, .p2 = .{ repeat_x, pmax[1] }, .col = color(.{ ink[0], ink[1], ink[2], 0.3 }), .thickness = 1 });
                            }
                            for (melodic.notes) |note| {
                                const note_x = repeat_x + @as(f32, @floatCast(note.start_beat)) * beat_w;
                                if (note_x >= pmax[0]) continue;
                                const note_y = pmin[1] + 26 + @as(f32, @floatFromInt(max_pitch - note.pitch)) / pitch_span * preview_height;
                                const note_w = @max(2, @as(f32, @floatCast(note.duration_beat)) * beat_w);
                                draw_list.addLine(.{ .p1 = .{ note_x, note_y }, .p2 = .{ @min(note_x + note_w, pmax[0] - 2), note_y }, .col = color(.{ ink[0], ink[1], ink[2], 0.72 }), .thickness = 2 });
                            }
                            reps += 1;
                        }
                    }
                },
                .drum => |drum| {
                    const pattern_bars = @as(f32, @floatFromInt(drum.step_count)) * @as(f32, @floatFromInt(@max(app.core.session.project.meter_denominator, 1))) / (@as(f32, @floatFromInt(@max(drum.steps_per_beat, 1))) * @as(f32, @floatFromInt(@max(app.core.session.project.beats_per_bar, 1))) * 4.0);
                    draw_list.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(ink), "PATTERN {c}  {d:.2} bars", .{ 'A' + drum.variant, pattern_bars });
                    // step_px is fixed by beat_w/steps_per_beat, not the clip's box
                    // width, so a chopped (shortened) clip truncates the pattern
                    // instead of squeezing every step into the smaller box, and a
                    // stretched clip repeats it - same rule fireSongStep applies
                    // with `local % len`.
                    if (drum.step_count > 0 and drum.steps_per_beat > 0) {
                        const step_px = beat_w / @as(f32, @floatFromInt(drum.steps_per_beat));
                        const pattern_px = step_px * @as(f32, @floatFromInt(drum.step_count));
                        var repeat_x = pmin[0];
                        var reps: u32 = 0;
                        while (repeat_x < pmax[0] and reps < 256) : (repeat_x += pattern_px) {
                            if (reps > 0) {
                                draw_list.addLine(.{ .p1 = .{ repeat_x, pmin[1] + 22 }, .p2 = .{ repeat_x, pmax[1] }, .col = color(.{ ink[0], ink[1], ink[2], 0.45 }), .thickness = 1 });
                            }
                            for (0..drum.step_count) |step| {
                                const grid_x = repeat_x + (@as(f32, @floatFromInt(step)) + 0.5) * step_px;
                                if (grid_x >= pmax[0]) break;
                                if (step % @max(drum.steps_per_beat, 1) == 0) {
                                    draw_list.addLine(.{
                                        .p1 = .{ grid_x, pmin[1] + 27 },
                                        .p2 = .{ grid_x, pmax[1] - 5 },
                                        .col = color(.{ ink[0], ink[1], ink[2], 0.24 }),
                                        .thickness = 1,
                                    });
                                }
                                var hits: u8 = 0;
                                for (drum.midi) |row| {
                                    if (step < row.len and row[step] != null) hits +|= 1;
                                }
                                if (hits == 0) continue;
                                const hit_h = @min(15, @as(f32, @floatFromInt(hits)) * 2);
                                draw_list.addLine(.{ .p1 = .{ grid_x, pmax[1] - 6 }, .p2 = .{ grid_x, pmax[1] - 6 - hit_h }, .col = color(.{ ink[0], ink[1], ink[2], 0.72 }), .thickness = 2 });
                            }
                            reps += 1;
                        }
                    }
                },
                .audio => |region| {
                    draw_list.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(ink), "AUDIO  {d}f  {d:.1}dB  {d}T", .{ region.source_length_frames, region.gain_db, region.takeCount() });
                    const mid = (pmin[1] + 22 + pmax[1]) * 0.5;
                    draw_list.addLine(.{ .p1 = .{ pmin[0] + 5, mid }, .p2 = .{ pmax[0] - 5, mid }, .col = color(.{ ink[0], ink[1], ink[2], 0.72 }), .thickness = 2 });
                },
            }
            if (clip.automation.gain.len + clip.automation.pan.len + clip.automation.synth_params.items.len > 0) draw_list.addText(.{ pmax[0] - 16, pmin[1] + 4 }, color(theme.modulation), "A", .{});
        }
    }

    if (app.core.cursor < track_count) {
        // Always one grid cell wide, so the cursor stays readable as a
        // cursor over a clip - a box the size of the clip under it made
        // every edit ambiguous (which of the two is being addressed?).
        // The one exception is a held-enter stamp session, where the box
        // *is* the clip being sized: hold enter and h/l resize it live
        // (see editors/arrangement.zig's arr_stamp block).
        var cursor_start_tick = cursor_tick;
        var cursor_span_ticks = app.core.arr_grid.ticks();
        if (app.core.arr_stamp) {
            if (app.core.session.arrangement.lane(app.core.cursor)) |lane| {
                if (lane.clipAt(cursor_tick)) |clip| {
                    cursor_start_tick = clip.start_tick;
                    cursor_span_ticks = clip.length_ticks;
                }
            }
        }
        cursor_span_ticks = @max(cursor_span_ticks, app.core.arr_grid.ticks());
        const cursor_x = timeline_x + @as(f32, @floatFromInt(cursor_start_tick)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const cursor_w = @max(2, @as(f32, @floatFromInt(cursor_span_ticks)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w);
        const cursor_y = origin[1] + ruler_h + @as(f32, @floatFromInt(app.core.cursor)) * lane_h;
        // A held-enter stamp session tints the cursor so the widened box
        // reads as "adjusting this clip", not just "sitting on it".
        // Otherwise the cursor wears the lane's own track colour (the
        // generic focus tone only for an uncoloured track), matching how
        // tui/views/arrangement.zig colours its lane cells.
        const track_col = app.core.session.project.tracks.items[app.core.cursor].color;
        const cursor_col = if (app.core.arr_stamp)
            theme.rhythm
        else if (track_col > 0)
            gui_style.trackColor(track_col)
        else
            theme.focus;
        draw_list.addRectFilled(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ @min(cursor_x + cursor_w, origin[0] + canvas_w - 1), cursor_y + lane_h - 1 },
            .col = color(.{ cursor_col[0], cursor_col[1], cursor_col[2], 0.16 }),
        });
        draw_list.addRect(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ @min(cursor_x + cursor_w, origin[0] + canvas_w - 1), cursor_y + lane_h - 1 },
            .col = color(cursor_col),
            .thickness = 2,
        });
    }

    const snap = app.core.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = app.core.session.project.beatAtFrames(snap.position_frames);
        const x = timeline_x + @as(f32, @floatCast(play_beat)) * beat_w;
        if (x <= origin[0] + canvas_w) draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(theme.danger), .thickness = 2 });
    }

    if (track_count > 0 and hovered and zgui.isMouseClicked(.left) and mouse[1] >= origin[1] + ruler_h) {
        const ti = @min(track_count - 1, @as(usize, @intFromFloat((mouse[1] - origin[1] - ruler_h) / lane_h)));
        app.core.cursor = ti;
        app.arrangement_clip = null;
        if (mouse[0] >= timeline_x and ti < app.core.session.arrangement.lanes.items.len) {
            const tick: u32 = @intFromFloat((mouse[0] - timeline_x) / beat_w * @as(f32, @floatFromInt(ticks_per_beat)));
            app.core.arr_cursor_bar = tick / app.core.arr_grid.ticks();
            for (app.core.session.arrangement.lanes.items[ti].clips.items, 0..) |clip, ci| {
                if (clip.covers(tick)) {
                    app.arrangement_clip = .{ .track = ti, .clip = ci, .start_tick = clip.start_tick };
                    app.arrangement_drag = .{
                        .selection = app.arrangement_clip.?,
                        .target_tick = clip.start_tick,
                        .grab_offset_tick = tick - clip.start_tick,
                    };
                    break;
                }
            }
        }
    }
    if (track_count > 0 and hovered and zgui.isMouseClicked(.right) and mouse[1] >= origin[1] + ruler_h and mouse[0] >= timeline_x) {
        const ti = @min(track_count - 1, @as(usize, @intFromFloat((mouse[1] - origin[1] - ruler_h) / lane_h)));
        const tick: u32 = @intFromFloat((mouse[0] - timeline_x) / beat_w * @as(f32, @floatFromInt(ticks_per_beat)));
        app.arrangement_clip = null;
        if (ti < app.core.session.arrangement.lanes.items.len) {
            for (app.core.session.arrangement.lanes.items[ti].clips.items, 0..) |clip, ci| {
                if (!clip.covers(tick)) continue;
                app.core.cursor = ti;
                app.core.arr_cursor_bar = tick / app.core.arr_grid.ticks();
                app.arrangement_clip = .{ .track = ti, .clip = ci, .start_tick = clip.start_tick };
                zgui.openPopup("clip-context", .{});
                break;
            }
        }
    }
    if (zgui.beginPopup("clip-context", .{})) {
        const selection = app.arrangement_clip;
        var action: ?u8 = null;
        if (zgui.menuItem("Move left", .{ .shortcut = "<" })) action = '<';
        if (zgui.menuItem("Move right", .{ .shortcut = ">" })) action = '>';
        if (zgui.menuItem("Shorten", .{ .shortcut = "-" })) action = '-';
        if (zgui.menuItem("Lengthen", .{ .shortcut = "+" })) action = '+';
        if (zgui.menuItem("Automation", .{ .shortcut = "a" })) action = 'a';
        if (zgui.menuItem("Delete", .{ .shortcut = "x" })) action = 'x';
        zgui.endPopup();
        if (selection) |selected| if (action) |key| applyInspectorAction(app, selected, key);
    }
    zgui.spacing();
    drawArrangementInspector(app);
}

fn finishClipDrag(app: anytype, drag: ClipDrag) void {
    if (!clipSelectionValid(&app.core.session.arrangement, drag.selection)) return;
    const grid = app.core.arr_grid.ticks();
    const from = drag.selection.start_tick / grid;
    const to = drag.target_tick / grid;
    if (from == to) return;
    app.core.cursor = drag.selection.track;
    app.core.arr_cursor_bar = from;
    app.core.modal.count = if (to > from) to - from else from - to;
    app.core.handleKey(.{ .char = if (to > from) '>' else '<' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    const lane = app.core.session.arrangement.lanes.items[drag.selection.track];
    for (lane.clips.items, 0..) |clip, index| {
        if (clip.start_tick != drag.target_tick) continue;
        app.arrangement_clip = .{ .track = drag.selection.track, .clip = index, .start_tick = clip.start_tick };
        return;
    }
}

test "clip selection rejects deleted or displaced clips" {
    var arrangement: ws.Arrangement = .{};
    defer arrangement.deinit(std.testing.allocator);
    try arrangement.addLane(std.testing.allocator);
    try arrangement.lanes.items[0].place(std.testing.allocator, try ws.Clip.initMelodic(std.testing.allocator, 16, 16, &.{}, 1.0));

    const selection: ClipSelection = .{ .track = 0, .clip = 0, .start_tick = 16 };
    try std.testing.expect(clipSelectionValid(&arrangement, selection));
    try std.testing.expect(arrangement.lanes.items[0].removeAt(std.testing.allocator, 16));
    try std.testing.expect(!clipSelectionValid(&arrangement, selection));

    try arrangement.lanes.items[0].place(std.testing.allocator, try ws.Clip.initMelodic(std.testing.allocator, 32, 16, &.{}, 1.0));
    try std.testing.expect(!clipSelectionValid(&arrangement, selection));
}

fn drawArrangementInspector(app: anytype) void {
    const selection = app.arrangement_clip orelse return;
    var action: ?u8 = null;
    if (zgui.beginChild("arrangement-inspector", .{ .w = 0, .h = 108, .child_flags = .{ .border = true } })) {
        const clip = app.core.session.arrangement.lanes.items[selection.track].clips.items[selection.clip];
        zgui.textColored(theme.focus, icons.arrangement ++ "  CLIP", .{});
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
            .audio => "AUDIO REGION",
        }});
        zgui.spacing();
        if (widgets.iconButton(icons.left ++ "##clip-move-left", "Move left  <")) action = '<';
        zgui.sameLine(.{ .spacing = 6 });
        if (widgets.iconButton(icons.right ++ "##clip-move-right", "Move right  >")) action = '>';
        zgui.sameLine(.{ .spacing = 6 });
        if (widgets.iconButton(icons.minus ++ "##clip-shorter", "Shorten clip  -")) action = '-';
        zgui.sameLine(.{ .spacing = 6 });
        if (widgets.iconButton(icons.plus ++ "##clip-longer", "Lengthen clip  +")) action = '+';
        zgui.sameLine(.{ .spacing = 6 });
        if (widgets.iconButton(icons.arrangement ++ "##clip-automation", "Edit automation  a")) action = 'a';
        zgui.sameLine(.{ .spacing = 6 });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.danger });
        if (widgets.iconButton(icons.close ++ "##clip-delete", "Delete clip  x")) action = 'x';
        zgui.popStyleColor(.{});
    }
    zgui.endChild();
    if (action) |key| applyInspectorAction(app, selection, key);
}

fn applyInspectorAction(app: anytype, selection: ClipSelection, key: u8) void {
    app.core.handleKey(.{ .char = key }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    if (key == 'x') {
        app.arrangement_clip = null;
        return;
    }
    if (app.core.view != .arrangement or selection.track >= app.core.session.arrangement.lanes.items.len) return;
    const cursor_tick = app.core.arr_cursor_bar *| app.core.arr_grid.ticks();
    for (app.core.session.arrangement.lanes.items[selection.track].clips.items, 0..) |clip, index| {
        if (!clip.covers(cursor_tick)) continue;
        app.arrangement_clip = .{ .track = selection.track, .clip = index, .start_tick = clip.start_tick };
        return;
    }
    app.arrangement_clip = null;
}

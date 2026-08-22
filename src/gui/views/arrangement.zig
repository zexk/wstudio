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
const automation_ed = @import("../../ui/editors/automation.zig");
const history = @import("../../ui/history.zig");
const waveform = @import("../../ui/waveform.zig");
const commands = @import("../../ui/commands.zig");

const color = gui_style.color;
const theme = &gui_style.palette;

pub const ClipSelection = struct { track: usize, clip: usize, start_tick: u32 };
/// `copy` is decided when the drag starts, not when it ends: holding the
/// modifier is what turns a move into a duplicate, and releasing it midway
/// through a drag should not silently change what the gesture does.
pub const ClipDrag = struct { selection: ClipSelection, target_tick: u32, grab_offset_tick: u32, copy: bool = false };

/// Whether the selection still points at an audio clip - checked before the
/// layout reserves inspector height, which happens a frame before the
/// inspector itself draws.
fn selectedClipIsAudio(app: anytype, selection: ClipSelection) bool {
    if (!clipSelectionValid(&app.core.session.arrangement, selection)) return false;
    return app.core.session.arrangement.lanes.items[selection.track].clips.items[selection.clip].content == .audio;
}

fn clipSelectionValid(arrangement: *const ws.Arrangement, selection: ClipSelection) bool {
    if (selection.track >= arrangement.lanes.items.len) return false;
    const clips = arrangement.lanes.items[selection.track].clips.items;
    return selection.clip < clips.len and clips[selection.clip].start_tick == selection.start_tick;
}

/// Width of a fade ramp on a clip `clip_w` pixels wide. Fades are counted in
/// timeline frames from the clip's edge (see `audio/engine.zig`'s region
/// mixing), so they scale against the clip's frame span; one longer than the
/// clip itself covers the whole box rather than running past it.
fn fadeWidthPx(fade_frames: u64, clip_frames: u64, clip_w: f32) f32 {
    if (fade_frames == 0 or clip_frames == 0) return 0;
    return @min(clip_w, clip_w * @as(f32, @floatFromInt(fade_frames)) / @as(f32, @floatFromInt(clip_frames)));
}

test "a fade covers its share of the clip and never more than all of it" {
    try std.testing.expectApproxEqAbs(@as(f32, 50), fadeWidthPx(24_000, 48_000, 100), 1e-4);
    try std.testing.expectEqual(@as(f32, 100), fadeWidthPx(96_000, 48_000, 100));
    try std.testing.expectEqual(@as(f32, 0), fadeWidthPx(0, 48_000, 100));
    try std.testing.expectEqual(@as(f32, 0), fadeWidthPx(24_000, 0, 100));
}

/// Peak overview of the region's own slice of its source, drawn across the
/// clip box. Falls back to the flat centre line this view drew before when
/// the source is missing (a project can outlive the file it imported).
fn drawClipWaveform(
    proj: *const ws.Project,
    draw_list: anytype,
    region: anytype,
    x0: f32,
    x1: f32,
    mid_y: f32,
    half_h: f32,
    ink: [4]f32,
) void {
    const line_col = color(.{ ink[0], ink[1], ink[2], 0.72 });
    const width = x1 - x0 - 10;
    const source = proj.audioSource(region.source_id);
    const slice: []const f32 = if (source) |s| blk: {
        const channels = @max(s.channel_count, 1);
        const lo = @min(region.source_start_frame *| channels, s.samples.len);
        const hi = @min(lo +| region.source_length_frames *| channels, s.samples.len);
        break :blk s.samples[@intCast(lo)..@intCast(hi)];
    } else &.{};
    if (width < 2 or slice.len == 0) {
        draw_list.addLine(.{ .p1 = .{ x0 + 5, mid_y }, .p2 = .{ x1 - 5, mid_y }, .col = line_col, .thickness = 2 });
        return;
    }
    var peaks: [512]f32 = undefined;
    const columns = @min(peaks.len, @as(usize, @intFromFloat(width)));
    waveform.peakBucketsSampled(slice, peaks[0..columns], 64);
    // Reversed playback mirrors what is heard, so mirror the overview too.
    if (region.reverse) std.mem.reverse(f32, peaks[0..columns]);
    for (peaks[0..columns], 0..) |peak, i| {
        const x = x0 + 5 + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(columns));
        const h = @max(1, peak * half_h * 0.9);
        draw_list.addLine(.{ .p1 = .{ x, mid_y - h }, .p2 = .{ x, mid_y + h }, .col = line_col, .thickness = 1 });
    }
}

pub fn draw(app: anytype) void {
    if (app.arrangement_clip) |selection| {
        if (!clipSelectionValid(&app.core.session.arrangement, selection)) app.arrangement_clip = null;
    }
    const track_count = app.core.session.project.tracks.items.len;
    const ticks_per_beat = ws.time_grid.ticks_per_beat;
    // The ruler grows a strip for tempo/meter flags only when the project has
    // a map to show - an empty band above every arrangement buys nothing.
    const proj = &app.core.session.project;
    const content_ticks = app.core.session.arrangement.lengthTicks();
    const cursor_tick = app.core.arr_cursor_bar *| app.core.arr_grid.ticks();
    // Bar extent (and the width one bar gets) comes from the meter map, so an
    // odd-meter stretch draws its own bar length instead of the default one.
    const bar_count: u32 = @max(8, proj.barAtTick(@max(content_ticks, cursor_tick)).bar +| 2);
    const gutter_w: f32 = 132;
    const map_strip: f32 = if (proj.tempo_points.items.len > 0 or proj.meter_points.items.len > 0) 16 else 0;
    const ruler_h: f32 = 30 + map_strip;
    const available = zgui.getContentRegionAvail();
    // An audio clip's inspector carries a row of dials the other kinds have
    // nothing to put in, so it reserves the extra height only when selected.
    const inspector_h: f32 = if (app.arrangement_clip) |sel| (if (selectedClipIsAudio(app, sel)) 190 else 116) else 0;
    const lane_h: f32 = if (track_count == 0)
        58
    else
        std.math.clamp((available[1] - inspector_h - ruler_h - 12) / @as(f32, @floatFromInt(track_count)), 58, 180);
    const canvas_w = @max(420, available[0]);
    const canvas_h = ruler_h + lane_h * @as(f32, @floatFromInt(track_count));
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("arrangement-canvas", .{ .w = canvas_w, .h = canvas_h });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    const timeline_x = origin[0] + gutter_w;
    const timeline_w = canvas_w - gutter_w;
    const total_ticks_u64: u64 = @max(ticks_per_beat, proj.tickAtBar(bar_count));
    const total_beats: f32 = @as(f32, @floatFromInt(total_ticks_u64)) / @as(f32, @floatFromInt(ticks_per_beat));
    const beat_w = timeline_w / total_beats;
    const px_per_tick = beat_w / @as(f32, @floatFromInt(ticks_per_beat));

    if (app.arrangement_drag) |*drag| {
        if (zgui.isMouseDown(.left)) {
            if (mouse[0] >= timeline_x) {
                const raw_tick = mouseTickAt(mouse[0], timeline_x, beat_w);
                const start_tick = raw_tick -| drag.grab_offset_tick;
                drag.target_tick = start_tick / app.core.arr_grid.ticks() * app.core.arr_grid.ticks();
            }
        } else {
            if (drag.copy) finishClipCopy(app, drag.*) else finishClipDrag(app, drag.*);
            app.arrangement_drag = null;
        }
    }

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(theme.bg0) });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + ruler_h }, .col = color(theme.bg2) });

    const any_soloed = for (app.core.session.project.tracks.items) |t| {
        if (t.soloed) break true;
    } else false;
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
        // Mute/solo badges, same colours the tracks view gives them - a lane
        // the mix can't hear used to look exactly like one it can.
        const track = app.core.session.project.tracks.items[ti];
        if (track.muted) draw_list.addText(.{ origin[0] + 104, y + 11 }, color(theme.danger), "M", .{});
        if (track.soloed) draw_list.addText(.{ origin[0] + 116, y + 11 }, color(theme.audio), "S", .{});
        // Only the cursor's lane gets a hint. Labelling every other empty
        // lane "Empty lane" says nothing the blank row didn't already.
        const lane = app.core.session.arrangement.lane(@intCast(ti));
        if (selected and (lane == null or lane.?.clips.items.len == 0)) {
            draw_list.addText(.{ timeline_x + 12, y + lane_h * 0.5 - 8 }, color(theme.fg2), "Press s to stamp at cursor", .{});
        }
        draw_list.addLine(.{ .p1 = .{ origin[0], y + lane_h }, .p2 = .{ origin[0] + canvas_w, y + lane_h }, .col = color(theme.line), .thickness = 1 });
    }

    const max_grid_lines = 4096;
    const grid_ticks: u64 = app.core.arr_grid.ticks();
    const tick_stride: u64 = @max(grid_ticks, grid_ticks * ((total_ticks_u64 / grid_ticks + max_grid_lines - 1) / max_grid_lines));
    // Ruler text sits just under the tempo/meter strip, wherever that leaves it.
    const label_y = origin[1] + ruler_h - 23;
    var tick_index: u64 = 0;
    while (tick_index <= total_ticks_u64) : (tick_index += tick_stride) {
        const x = timeline_x + @as(f32, @floatFromInt(tick_index)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const on_beat = tick_index % ticks_per_beat == 0;
        draw_list.addLine(.{
            .p1 = .{ x, origin[1] + ruler_h },
            .p2 = .{ x, origin[1] + canvas_h },
            .col = color(if (on_beat) theme.line else .{ theme.line[0], theme.line[1], theme.line[2], theme.line[3] * 0.5 }),
            .thickness = 1,
        });
    }

    // Bar lines walk the bars themselves rather than filtering the grid loop
    // above: under an odd meter a bar can start between two grid steps (7/8
    // bars are 3.5 quarter notes), and every such bar went unlined and
    // unnumbered while the ruler filtered by tick.
    var bar: u32 = 0;
    while (bar <= bar_count) : (bar += 1) {
        const x = timeline_x + @as(f32, @floatFromInt(proj.tickAtBar(bar))) * px_per_tick;
        if (x > origin[0] + canvas_w) break;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(theme.bg5), .thickness = 1.5 });
        if (bar < bar_count) draw_list.addText(.{ x + 7, label_y }, color(theme.fg2), "{d}", .{bar + 1});
    }

    // Loop region: a solid band across the top of the ruler, a wash over the
    // lanes it covers, and an edge line at each boundary. An armed-but-off
    // region (set with `(`/`)` before `L`) draws the same shape, quieter.
    if (proj.loop_end_bar > proj.loop_start_bar) {
        const alpha: f32 = if (proj.loop_enabled) 1.0 else 0.4;
        const right_edge = origin[0] + canvas_w;
        const x1 = std.math.clamp(timeline_x + @as(f32, @floatFromInt(proj.tickAtBar(proj.loop_start_bar))) * px_per_tick, timeline_x, right_edge);
        const x2 = std.math.clamp(timeline_x + @as(f32, @floatFromInt(proj.tickAtBar(proj.loop_end_bar))) * px_per_tick, timeline_x, right_edge);
        if (x2 > x1) {
            const hue = theme.modulation;
            draw_list.addRectFilled(.{
                .pmin = .{ x1, origin[1] + ruler_h - 5 },
                .pmax = .{ x2, origin[1] + ruler_h },
                .col = color(.{ hue[0], hue[1], hue[2], 0.85 * alpha }),
            });
            draw_list.addRectFilled(.{
                .pmin = .{ x1, origin[1] + ruler_h },
                .pmax = .{ x2, origin[1] + canvas_h },
                .col = color(.{ hue[0], hue[1], hue[2], 0.08 * alpha }),
            });
            for ([2]f32{ x1, x2 }) |x| {
                if (x <= timeline_x or x >= right_edge) continue;
                draw_list.addLine(.{
                    .p1 = .{ x, origin[1] },
                    .p2 = .{ x, origin[1] + canvas_h },
                    .col = color(.{ hue[0], hue[1], hue[2], 0.7 * alpha }),
                    .thickness = 2,
                });
            }
        }
    } else if (app.core.arr_loop_start_pending) {
        const x = timeline_x + @as(f32, @floatFromInt(proj.tickAtBar(proj.loop_start_bar))) * px_per_tick;
        if (x >= timeline_x and x <= origin[0] + canvas_w) draw_list.addLine(.{
            .p1 = .{ x, origin[1] },
            .p2 = .{ x, origin[1] + canvas_h },
            .col = color(.{ theme.modulation[0], theme.modulation[1], theme.modulation[2], 0.7 }),
            .thickness = 2,
        });
    }

    for (app.core.session.project.sections.items) |section| {
        const x = timeline_x + @as(f32, @floatFromInt(section.tick)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        if (x < timeline_x or x > origin[0] + canvas_w) continue;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(theme.focus), .thickness = 2 });
        draw_list.addText(.{ x + 5, label_y }, color(theme.focus), "{s}", .{section.name});
    }

    // Tempo and meter changes, in the strip the ruler grew for them. Both maps
    // are keyed by quarter-note beat, so they share the tick math; the meter
    // label sits left of its line and the tempo right, since a change of both
    // on one beat is the common case.
    if (map_strip > 0) {
        for (proj.tempo_points.items) |point| {
            const x = timeline_x + @as(f32, @floatFromInt(ws.Project.tickAtBeat(point.beat))) * px_per_tick;
            if (x > origin[0] + canvas_w) continue;
            draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(.{ theme.modulation[0], theme.modulation[1], theme.modulation[2], 0.35 }), .thickness = 1 });
            draw_list.addText(.{ x + 4, origin[1] + 2 }, color(theme.modulation), "{d:.0}{s}", .{ point.bpm, if (point.ramp_to_next) " ramp" else "" });
        }
        for (proj.meter_points.items) |point| {
            const x = timeline_x + @as(f32, @floatFromInt(ws.Project.tickAtBeat(point.beat))) * px_per_tick;
            if (x > origin[0] + canvas_w) continue;
            draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.35 }), .thickness = 1 });
            draw_list.addText(.{ @max(timeline_x, x - 32), origin[1] + 2 }, color(theme.rhythm), "{d}/{d}", .{ point.numerator, point.denominator });
        }
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
            // Stacked layers overlap in time by design (`place` only evicts an
            // overlap on the same layer), and the higher one drew over the
            // lower one edge to edge - two clips looked like one. Step each
            // layer down so the stack shows.
            const layer_step = @min(@as(f32, @floatFromInt(clip.layer)), 3) * 7;
            const pmin = [2]f32{ x + 1, lane_y + 5 + layer_step };
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
            // A muted lane (or an unsoloed one while something else is soloed)
            // fades its clips - the badge in the gutter says which it is.
            const track = app.core.session.project.tracks.items[ti];
            const silent = track.muted or (any_soloed and !track.soloed);
            const clip_color: [4]f32 = .{ base[0], base[1], base[2], if (selected) 1 else if (silent) 0.26 else 0.68 };
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
                widgets.focusRect(draw_list, .{ pmin[0] - 1, pmin[1] - 1 }, .{ pmax[0] + 1, pmax[1] + 1 }, 5, theme.focus);
                widgets.accentMark(draw_list, pmin, .{ pmin[0] + 5, pmax[1] }, theme.focus);
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
                    draw_list.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(ink), "PATTERN {c}  {d:.2} bars", .{ ws.dsp.DrumMachine.variantLetter(drum.variant), pattern_bars });
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
                    drawClipWaveform(proj, draw_list, region, pmin[0], pmax[0], mid, (pmax[1] - pmin[1] - 22) * 0.5, ink);
                    // Fade ramps (`:clip-fade`, and the pair `:crossfade` writes)
                    // are counted in timeline frames from each clip edge, so they
                    // scale against the clip's own frame span rather than its
                    // ticks - which keeps them honest across a tempo change.
                    const clip_frames = proj.framesAtBeat(ws.time_grid.tickToBeat(clip.start_tick +| clip.length_ticks)) -|
                        proj.framesAtBeat(ws.time_grid.tickToBeat(clip.start_tick));
                    const body_top = @min(pmax[1], pmin[1] + 22);
                    if (region.fade_in_frames > 0 or region.fade_out_frames > 0) {
                        const fade_col = color(.{ ink[0], ink[1], ink[2], 0.8 });
                        const w_in = fadeWidthPx(region.fade_in_frames, clip_frames, clip_w);
                        const w_out = fadeWidthPx(region.fade_out_frames, clip_frames, clip_w);
                        if (w_in > 0) draw_list.addLine(.{ .p1 = .{ pmin[0], pmax[1] }, .p2 = .{ @min(pmin[0] + w_in, pmax[0]), body_top }, .col = fade_col, .thickness = 2 });
                        if (w_out > 0) draw_list.addLine(.{ .p1 = .{ @max(pmin[0], pmax[0] - w_out), body_top }, .p2 = .{ pmax[0], pmax[1] }, .col = fade_col, .thickness = 2 });
                    }
                },
            }
            drawAutomationPreview(app, draw_list, &clip, pmin, pmax);
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

    if (hovered and zgui.isMouseClicked(.left) and mouse[0] >= timeline_x and mouse[1] < origin[1] + ruler_h) {
        const tick = mouseTickAt(mouse[0], timeline_x, beat_w);
        app.core.arr_cursor_bar = tick / app.core.arr_grid.ticks();
        app.arrangement_clip = null;
        if (zgui.isMouseDoubleClicked(.left)) app.core.handleKey(.{ .char = 's' }, app.core.now_ns);
    }

    if (track_count > 0 and hovered and zgui.isMouseClicked(.left) and mouse[1] >= origin[1] + ruler_h) {
        const ti = @min(track_count - 1, @as(usize, @intFromFloat((mouse[1] - origin[1] - ruler_h) / lane_h)));
        app.core.cursor = ti;
        app.arrangement_clip = null;
        if (mouse[0] >= timeline_x and ti < app.core.session.arrangement.lanes.items.len) {
            const tick = mouseTickAt(mouse[0], timeline_x, beat_w);
            app.core.arr_cursor_bar = tick / app.core.arr_grid.ticks();
            // The topmost clip, the one drawn on top - the first covering
            // clip in list order is the BOTTOM of a stack (see clipIndexAt).
            if (app.core.session.arrangement.lanes.items[ti].clipIndexAt(tick)) |ci| {
                const clip = app.core.session.arrangement.lanes.items[ti].clips.items[ci];
                app.arrangement_clip = .{ .track = ti, .clip = ci, .start_tick = clip.start_tick };
                app.arrangement_drag = .{
                    .selection = app.arrangement_clip.?,
                    .target_tick = clip.start_tick,
                    .grab_offset_tick = tick - clip.start_tick,
                    .copy = zgui.isKeyDown(.mod_shift),
                };
            }
        }
    }
    if (track_count > 0 and hovered and zgui.isMouseClicked(.right) and mouse[1] >= origin[1] + ruler_h and mouse[0] >= timeline_x) {
        const ti = @min(track_count - 1, @as(usize, @intFromFloat((mouse[1] - origin[1] - ruler_h) / lane_h)));
        const tick = mouseTickAt(mouse[0], timeline_x, beat_w);
        app.arrangement_clip = null;
        if (ti < app.core.session.arrangement.lanes.items.len) {
            if (app.core.session.arrangement.lanes.items[ti].clipIndexAt(tick)) |ci| {
                const clip = app.core.session.arrangement.lanes.items[ti].clips.items[ci];
                app.core.cursor = ti;
                app.core.arr_cursor_bar = tick / app.core.arr_grid.ticks();
                app.arrangement_clip = .{ .track = ti, .clip = ci, .start_tick = clip.start_tick };
                zgui.openPopup("clip-context", .{});
            }
        }
    }
    if (zgui.beginPopup("clip-context", .{})) {
        const selection = app.arrangement_clip;
        var action: ?u8 = null;
        var duplicate = false;
        if (zgui.menuItem("Move left", .{ .shortcut = "<" })) action = '<';
        if (zgui.menuItem("Move right", .{ .shortcut = ">" })) action = '>';
        if (zgui.menuItem("Shorten", .{ .shortcut = "-" })) action = '-';
        if (zgui.menuItem("Lengthen", .{ .shortcut = "+" })) action = '+';
        if (zgui.menuItem("Split at cursor", .{ .shortcut = "S" })) action = 'S';
        if (zgui.menuItem("Duplicate", .{})) duplicate = true;
        if (zgui.menuItem("Automation", .{ .shortcut = "a" })) action = 'a';
        if (selection) |selected| {
            if (selectedClipIsAudio(app, selected) and zgui.menuItem("Crossfade overlap", .{ .shortcut = ":crossfade" }))
                commands.run(&app.core, "crossfade");
        }
        if (zgui.menuItem("Delete", .{ .shortcut = "x" })) action = 'x';
        zgui.endPopup();
        if (selection) |selected| {
            if (action) |key| applyInspectorAction(app, selected, key);
            if (duplicate) duplicateClip(app, selected);
        }
    }
    zgui.spacing();
    drawArrangementInspector(app);
}

fn mouseTickAt(mouse_x: f32, timeline_x: f32, beat_w: f32) u32 {
    return @intFromFloat(@max(0, (mouse_x - timeline_x) / beat_w * @as(f32, @floatFromInt(ws.time_grid.ticks_per_beat))));
}

test "arrangement ruler mouse position maps to project ticks" {
    try std.testing.expectEqual(@as(u32, 0), mouseTickAt(80, 100, 40));
    try std.testing.expectEqual(ws.time_grid.ticks_per_beat * 2, mouseTickAt(180, 100, 40));
}

fn drawAutomationPreview(app: anytype, draw_list: anytype, clip: *const ws.Clip, pmin: [2]f32, pmax: [2]f32) void {
    const target: automation_ed.AutomationFocus = if (automation_ed.curvePointsConst(clip, app.core.automation_focus).len > 0)
        app.core.automation_focus
    else if (clip.automation.gain.len > 0)
        .gain
    else if (clip.automation.pan.len > 0)
        .pan
    else if (clip.automation.synth_params.items.len > 0)
        .{ .synth_param = .{
            .instance_id = clip.automation.synth_params.items[0].instance_id,
            .param_id = clip.automation.synth_params.items[0].param_id,
        } }
    else
        return;
    const points = automation_ed.curvePointsConst(clip, target);
    const range = automation_ed.curveRange(&app.core, target);
    const width = pmax[0] - pmin[0];
    const top = pmin[1] + 25;
    const height = @max(4, pmax[1] - top - 4);
    const samples: usize = @max(2, @min(128, @as(usize, @intFromFloat(@max(2, width / 4)))));
    const length_beats = ws.time_grid.tickToBeat(clip.length_ticks);
    var previous: ?[2]f32 = null;
    for (0..samples + 1) |i| {
        const fraction = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples));
        const value = ws.dsp.automation.interpolate(points, @as(f64, fraction * @as(f32, @floatCast(length_beats)))) orelse continue;
        const normalized = std.math.clamp((value - range[0]) / (range[1] - range[0]), 0, 1);
        const point = [2]f32{ pmin[0] + fraction * width, top + (1 - normalized) * height };
        if (previous) |from| draw_list.addLine(.{ .p1 = from, .p2 = point, .col = color(theme.modulation), .thickness = 2 });
        previous = point;
    }
    draw_list.addText(.{ pmax[0] - 16, pmin[1] + 4 }, color(theme.modulation), "A", .{});
}

/// Shift-drag: leave the clip where it is and drop a copy at the target -
/// the same gesture the TUI's mouse path already documents, which terminals
/// tend to swallow for their own text selection. Help has pointed at the GUI
/// as the way to get it since before the GUI had it.
///
/// This is what drum programming by hand is built on: place one kick, then
/// strew it across the bar without going back to the browser for each hit.
fn finishClipCopy(app: anytype, drag: ClipDrag) void {
    if (!clipSelectionValid(&app.core.session.arrangement, drag.selection)) return;
    if (drag.target_tick == drag.selection.start_tick) return;
    const allocator = app.core.allocator;
    const lane = &app.core.session.arrangement.lanes.items[drag.selection.track];
    var copy = lane.clips.items[drag.selection.clip].dupe(allocator) catch {
        app.core.setStatus("copy: out of memory", .{});
        return;
    };
    copy.start_tick = @min(drag.target_tick, std.math.maxInt(u32) - copy.length_ticks);
    // Snapshot before placing: the copy may evict a clip it lands on, and
    // undo has to bring that one back too.
    history.recordLane(&app.core, @intCast(drag.selection.track));
    lane.place(allocator, copy) catch {
        copy.deinit(allocator);
        app.core.setStatus("copy: out of memory", .{});
        return;
    };
    if (app.core.session.song_mode) app.core.session.rebuildSongData();
    app.core.dirty = true;
    app.core.cursor = drag.selection.track;
    app.core.arr_cursor_bar = copy.start_tick / app.core.arr_grid.ticks();
    for (lane.clips.items, 0..) |clip, index| {
        if (clip.start_tick != copy.start_tick) continue;
        app.arrangement_clip = .{ .track = drag.selection.track, .clip = index, .start_tick = clip.start_tick };
        return;
    }
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
    var crossfade = false;
    var duplicate = false;
    const child_h: f32 = if (selectedClipIsAudio(app, selection)) 182 else 108;
    if (zgui.beginChild("arrangement-inspector", .{ .w = 0, .h = child_h, .child_flags = .{ .border = true }, .window_flags = .{ .no_scrollbar = true } })) {
        const clip = app.core.session.arrangement.lanes.items[selection.track].clips.items[selection.clip];
        widgets.coloredTitle(theme.focus, icons.arrangement ++ "  CLIP", .{});
        zgui.separator();
        widgets.valueText("Track {d:0>2}", .{selection.track + 1});
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
        if (widgets.iconButton(icons.slicer ++ "##clip-split", "Split at cursor  S")) action = 'S';
        zgui.sameLine(.{ .spacing = 6 });
        if (widgets.iconButton(icons.redo ++ "##clip-duplicate", "Duplicate after clip")) duplicate = true;
        zgui.sameLine(.{ .spacing = 6 });
        if (widgets.iconButton(icons.automation ++ "##clip-automation", "Edit automation  a")) action = 'a';
        if (clip.content == .audio) {
            zgui.sameLine(.{ .spacing = 6 });
            if (widgets.iconButton(icons.phase ++ "##clip-crossfade", "Crossfade overlapping layer  :crossfade")) crossfade = true;
        }
        zgui.sameLine(.{ .spacing = 6 });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.danger });
        if (widgets.iconButton(icons.close ++ "##clip-delete", "Delete clip  x")) action = 'x';
        zgui.popStyleColor(.{});
        if (clip.content == .audio) drawAudioRegionControls(app, selection, clip.length_ticks);
    }
    zgui.endChild();
    if (action) |key| applyInspectorAction(app, selection, key);
    if (duplicate) duplicateClip(app, selection);
    if (crossfade) commands.run(&app.core, "crossfade");
}

fn duplicateClip(app: anytype, selection: ClipSelection) void {
    if (!clipSelectionValid(&app.core.session.arrangement, selection)) return;
    const clip = app.core.session.arrangement.lanes.items[selection.track].clips.items[selection.clip];
    finishClipCopy(app, .{
        .selection = selection,
        .target_tick = clip.endTick(),
        .grab_offset_tick = 0,
        .copy = true,
    });
}

/// Gain, fades, stretch and reverse for the selected audio region - the
/// same values `:clip-gain`, `:clip-fade`, `:clip-stretch` and
/// `:clip-reverse` set, on the dials that make them findable without
/// knowing the command exists.
///
/// Undo is opened once per drag (on the dial's `activated`, not on every
/// changed frame), so a sweep across a knob collapses into a single lane
/// snapshot the way the mixer's faders already do.
fn drawAudioRegionControls(app: anytype, selection: ClipSelection, length_ticks: u32) void {
    const region = &app.core.session.arrangement.lanes.items[selection.track].clips.items[selection.clip].content.audio;
    const proj = &app.core.session.project;
    const sr: f32 = @floatFromInt(@max(proj.sample_rate, 1));
    // A fade cannot outrun the clip it shapes; the engine clamps it to the
    // region span anyway (see `Session.syncAudioRegions`), so the dial stops
    // where the audible effect does.
    const clip_seconds: f32 = @max(0.01, @as(f32, @floatCast(proj.secondsAtBeat(
        ws.time_grid.tickToBeat(length_ticks),
    ))));

    zgui.spacing();
    var fade_in = @as(f32, @floatFromInt(region.fade_in_frames)) / sr;
    var fade_out = @as(f32, @floatFromInt(region.fade_out_frames)) / sr;
    var buf: [32]u8 = undefined;

    const gain = widgets.knobCell("gain", "##clip-gain", std.fmt.bufPrint(&buf, "{d:.1} dB", .{region.gain_db}) catch "", .{
        .v = &region.gain_db,
        .min = -60,
        .max = 24,
        .accent = theme.audio,
    });
    if (gain.activated) history.recordLane(&app.core, @intCast(selection.track));
    var touched = gain.changed;

    zgui.sameLine(.{ .spacing = 6 });
    var in_buf: [32]u8 = undefined;
    const fin = widgets.knobCell("fade in", "##clip-fade-in", std.fmt.bufPrint(&in_buf, "{d:.2} s", .{fade_in}) catch "", .{
        .v = &fade_in,
        .min = 0,
        .max = clip_seconds,
        .accent = theme.audio,
        .skew = 2,
    });
    if (fin.activated) history.recordLane(&app.core, @intCast(selection.track));
    if (fin.changed) {
        region.fade_in_frames = @intFromFloat(@max(0, fade_in) * sr);
        touched = true;
    }

    zgui.sameLine(.{ .spacing = 6 });
    var out_buf: [32]u8 = undefined;
    const fout = widgets.knobCell("fade out", "##clip-fade-out", std.fmt.bufPrint(&out_buf, "{d:.2} s", .{fade_out}) catch "", .{
        .v = &fade_out,
        .min = 0,
        .max = clip_seconds,
        .accent = theme.audio,
        .skew = 2,
    });
    if (fout.activated) history.recordLane(&app.core, @intCast(selection.track));
    if (fout.changed) {
        region.fade_out_frames = @intFromFloat(@max(0, fade_out) * sr);
        touched = true;
    }

    zgui.sameLine(.{ .spacing = 6 });
    var stretch_buf: [32]u8 = undefined;
    const stretch = widgets.knobCell("stretch", "##clip-stretch", std.fmt.bufPrint(&stretch_buf, "{d:.3}x", .{region.stretch_ratio}) catch "", .{
        .v = &region.stretch_ratio,
        .min = 0.125,
        .max = 8,
        .accent = theme.audio,
        .logarithmic = true,
    });
    if (stretch.activated) history.recordLane(&app.core, @intCast(selection.track));
    if (stretch.changed) touched = true;

    // Reverse and the fade curve are switches, not quantities, so neither
    // gets a dial (see the knob/list-param split the synth panels follow).
    zgui.sameLine(.{ .spacing = 10 });
    zgui.beginGroup();
    if (widgets.activeIconButton(icons.loop ++ "##clip-reverse", "Reverse playback  :clip-reverse", region.reverse, theme.audio)) {
        history.recordLane(&app.core, @intCast(selection.track));
        region.reverse = !region.reverse;
        touched = true;
    }
    const equal_power = region.fade_curve == .equal_power;
    if (widgets.activeIconButton(icons.phase ++ "##clip-fade-curve", "Equal-power fades  :clip-fade", equal_power, theme.audio)) {
        history.recordLane(&app.core, @intCast(selection.track));
        region.fade_curve = if (equal_power) .linear else .equal_power;
        touched = true;
    }
    zgui.endGroup();

    if (touched) {
        if (app.core.session.song_mode) app.core.session.rebuildSongData();
        app.core.dirty = true;
    }
}

fn applyInspectorAction(app: anytype, selection: ClipSelection, key: u8) void {
    app.core.handleKey(.{ .char = key }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    if (key == 'x') {
        app.arrangement_clip = null;
        return;
    }
    if (app.core.view != .arrangement or selection.track >= app.core.session.arrangement.lanes.items.len) return;
    const cursor_tick = app.core.arr_cursor_bar *| app.core.arr_grid.ticks();
    const lane = &app.core.session.arrangement.lanes.items[selection.track];
    if (lane.clipIndexAt(cursor_tick)) |index| {
        app.arrangement_clip = .{ .track = selection.track, .clip = index, .start_tick = lane.clips.items[index].start_tick };
        return;
    }
    app.arrangement_clip = null;
}

//! Fixed window chrome shared by every GUI view: the transport readout strip,
//! the status bar, and the command prompt with its suggestion popup.

const std = @import("std");
const ws = @import("wstudio");
const status = @import("../ui/status.zig");
const tui_cmd = @import("../ui/cmd.zig");
const tui_commands = @import("../ui/commands.zig");
const ansi = @import("../ui/ansi.zig");
const icons = @import("../ui/icons.zig");
const spectrum_ed = @import("../ui/editors/spectrum.zig");
const gui_style = @import("style.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const patina = &gui_style.palette;

pub fn drawTransport(app: anytype, audio_label: []const u8) void {
    const snap = app.core.session.engine.uiSnapshot();
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = zgui.io.getDisplaySize()[0], .h = 64, .cond = .always });
    if (zgui.begin("Transport", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true, .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
        const beat = ws.types.framesToSeconds(snap.position_frames, app.core.session.project.sample_rate) * app.core.session.project.tempo_bpm / 60.0;
        const beat_index: u32 = @intFromFloat(beat);
        var tempo_buf: [32]u8 = undefined;
        const tempo = std.fmt.bufPrint(&tempo_buf, "{d:.1} BPM", .{app.core.session.project.tempo_bpm}) catch "tempo";
        var position_buf: [32]u8 = undefined;
        const position = std.fmt.bufPrint(&position_buf, "{d:0>3}.{d}", .{
            beat_index / app.core.session.project.beats_per_bar + 1,
            beat_index % app.core.session.project.beats_per_bar + 1,
        }) catch "position";
        var meter_buf: [32]u8 = undefined;
        const meter = std.fmt.bufPrint(&meter_buf, "{d}/4", .{app.core.session.project.beats_per_bar}) catch "meter";
        var rate_buf: [32]u8 = undefined;
        const rate = std.fmt.bufPrint(&rate_buf, "{d:.1} kHz", .{@as(f32, @floatFromInt(app.core.session.project.sample_rate)) / 1000.0}) catch "rate";

        drawTransportReadout(icons.tempo ++ "  TEMPO", tempo, true);
        drawTransportReadout("POSITION", position, false);
        drawTransportReadout("METER", meter, false);
        drawTransportReadout("RATE", rate, false);
        drawTransportReadout(icons.save ++ "  PROJECT", app.core.session.project.name, false);
        drawTransportReadout(icons.master ++ "  AUDIO", audio_label, false);
        drawLevelMeters(app, snap.peak);
    }
    zgui.end();
}

// A terminal meter is a handful of colored block cells; a GUI can afford a
// true continuous fill with a per-pixel color gradient and a decaying peak
// hold, so the master bus gets that treatment here instead of reusing the
// TUI's block-cell renderer.
const meter_db_min: f32 = -50.0;
const meter_yellow_db: f32 = -6.0;
const meter_red_db: f32 = -1.0;
const meter_decay_db_per_s: f32 = 24.0;

fn drawLevelMeters(app: anytype, peak: [2]f32) void {
    const now = std.Io.Timestamp.now(app.core.io, .awake).nanoseconds;
    const dt: f32 = if (app.meter_last_ns == 0) 0 else @max(0.0, @as(f32, @floatFromInt(now - app.meter_last_ns)) / 1_000_000_000.0);
    app.meter_last_ns = now;
    for (0..2) |ch| {
        const db = ws.types.gainToDb(peak[ch]);
        app.meter_hold_db[ch] = @max(db, app.meter_hold_db[ch] - meter_decay_db_per_s * dt);
    }

    zgui.sameLine(.{ .spacing = 24 });
    zgui.beginGroup();
    zgui.textColored(patina.fg3, "LEVEL", .{});
    const origin = zgui.getCursorScreenPos();
    const bar_w: f32 = 110;
    const bar_h: f32 = 8;
    const gap: f32 = 3;
    const draw_list = zgui.getWindowDrawList();
    for (0..2) |ch| {
        const y = origin[1] + @as(f32, @floatFromInt(ch)) * (bar_h + gap);
        draw_list.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ origin[0] + bar_w, y + bar_h }, .col = color(patina.bg2), .rounding = 2 });
        const norm = std.math.clamp((app.meter_hold_db[ch] - meter_db_min) / -meter_db_min, 0, 1);
        drawMeterFill(draw_list, origin[0], y, bar_w, bar_h, norm);
    }
    zgui.dummy(.{ .w = bar_w, .h = bar_h * 2 + gap });
    zgui.endGroup();
}

fn drawMeterFill(draw_list: zgui.DrawList, x: f32, y: f32, w: f32, h: f32, norm: f32) void {
    if (norm <= 0) return;
    const yellow_norm = (meter_yellow_db - meter_db_min) / -meter_db_min;
    const red_norm = (meter_red_db - meter_db_min) / -meter_db_min;
    const fill_w = w * norm;
    const green_w = @min(fill_w, w * yellow_norm);
    draw_list.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + green_w, y + h }, .col = color(patina.audio), .rounding = 2 });
    if (fill_w > w * yellow_norm) {
        draw_list.addRectFilled(.{ .pmin = .{ x + w * yellow_norm, y }, .pmax = .{ x + @min(fill_w, w * red_norm), y + h }, .col = color(patina.rhythm) });
    }
    if (fill_w > w * red_norm) {
        draw_list.addRectFilled(.{ .pmin = .{ x + w * red_norm, y }, .pmax = .{ x + fill_w, y + h }, .col = color(patina.danger) });
    }
}

fn drawTransportReadout(label: []const u8, value: []const u8, first: bool) void {
    if (!first) zgui.sameLine(.{ .spacing = 24 });
    zgui.beginGroup();
    zgui.textColored(patina.fg3, "{s}", .{label});
    zgui.textColored(patina.fg0, "{s}", .{value});
    zgui.endGroup();
}

pub fn drawStatus(app: anytype) void {
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = display[1] - 34, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = 34, .cond = .always });
    if (zgui.begin("Status", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true } })) {
        const draw = zgui.getWindowDrawList();
        const pos = zgui.getWindowPos();
        const size = zgui.getWindowSize();
        draw.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + size[0], pos[1] + size[1] }, .col = color(patina.bg1) });

        var left_buf: [2048]u8 = undefined;
        var right_buf: [256]u8 = undefined;
        const text = tuiStatusText(app, &left_buf, &right_buf);
        const mode_label = statusModeLabel(app.core.modal.mode);
        const x = drawStatusSegment(draw, pos[0], pos[1], size[1], statusModeColor(app.core.modal.mode), patina.bg0, mode_label);
        const context = compactStatusContext(std.mem.trim(u8, text.left, " "));
        if (context.len > 0) {
            const text_size = zgui.calcTextSize(context, .{});
            draw.addText(.{ x + 12, pos[1] + (size[1] - text_size[1]) / 2 }, color(patina.fg1), "{s}", .{context});
        }
        if (text.right.len > 0) {
            const right_color = if (app.core.view == .arrangement)
                if (app.core.session.song_mode) patina.audio else patina.rhythm
            else
                statusModeColor(app.core.modal.mode);
            drawStatusSegmentRight(draw, pos[0] + size[0], pos[1], size[1], right_color, patina.bg0, text.right);
        }
    }
    zgui.end();
}

fn compactStatusContext(text: []const u8) []const u8 {
    var search_from: usize = 0;
    var groups: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, "   ")) |separator| {
        groups += 1;
        if (groups == 2) return std.mem.trimRight(u8, text[0..separator], " ");
        search_from = separator + 3;
    }
    return text;
}

test "GUI status keeps selection and one contextual hint" {
    try std.testing.expectEqualStrings("kick  vel 90%   enter toggle", compactStatusContext("kick  vel 90%   enter toggle   x clear   ?: help"));
    try std.testing.expectEqualStrings("short status", compactStatusContext("short status"));
}

const StatusText = struct { left: []const u8, right: []const u8 };

// ui/status.zig's renderers are the canonical footer content for both
// frontends; the GUI strips their SGR codes and supplies its own
// presentation so the two stay in sync.
fn tuiStatusText(app: anytype, left_out: []u8, right_out: []u8) StatusText {
    var left_ansi: [2048]u8 = undefined;
    var right_ansi: [256]u8 = undefined;
    var left_writer = std.Io.Writer.fixed(&left_ansi);
    var right_writer = std.Io.Writer.fixed(&right_ansi);
    const core = &app.core;
    if (core.view == .tracks) core.tracksRowSync();
    (switch (core.view) {
        .tracks => status.drawTracksStatus(core, &left_writer, &right_writer),
        .drum_grid => status.drawDrumStatus(core, &left_writer, &right_writer),
        .synth_editor => status.drawSynthStatus(core, &left_writer, &right_writer),
        .sampler_editor => status.drawSamplerStatus(core, &left_writer, &right_writer),
        .piano_roll => status.drawPianoRollStatus(core, &left_writer, &right_writer),
        .help => status.drawHelpStatus(core, &left_writer, &right_writer),
        .track_spectrum, .master_spectrum, .group_spectrum => status.drawFxStatus(core, &left_writer, &right_writer, spectrum_ed.currentTarget(core)),
        .instrument_picker => status.drawPickerStatus(core, &left_writer, &right_writer, "INSTRUMENT", "insert", false),
        .fx_picker => status.drawPickerStatus(core, &left_writer, &right_writer, "EFFECT", "insert", true),
        .synth_fx_picker => status.drawPickerStatus(core, &left_writer, &right_writer, "SYNTH FX", "insert", true),
        .arrangement => status.drawArrangementStatus(core, &left_writer, &right_writer),
        .file_browser => status.drawFileBrowserStatus(core, &left_writer, &right_writer),
        .automation => status.drawAutomationStatus(core, &left_writer, &right_writer),
        .automation_param_picker => status.drawPickerStatus(core, &left_writer, &right_writer, "PARAM", "pick", true),
        .slicer_grid => status.drawSlicerStatus(core, &left_writer, &right_writer),
        .preset_picker => status.drawPresetPickerStatus(core, &left_writer, &right_writer),
    }) catch return .{ .left = "", .right = "" };

    const plain_left = ansi.stripAnsi(left_writer.buffered(), left_out);
    const without_mode = if (plain_left.len >= 3) plain_left[3..] else plain_left;
    return .{
        .left = without_mode,
        .right = std.mem.trim(u8, ansi.stripAnsi(right_writer.buffered(), right_out), " "),
    };
}

fn statusModeLabel(mode: ws.input.Mode) []const u8 {
    return switch (mode) {
        .normal => "N",
        .insert => "I",
        .visual => "V",
        .command => "C",
        .search => "S",
    };
}

fn statusModeColor(mode: ws.input.Mode) [4]f32 {
    return switch (mode) {
        .normal => patina.audio,
        .insert => patina.rhythm,
        .visual => patina.modulation,
        .command, .search => patina.focus,
    };
}

pub fn drawCommandPrompt(app: anytype) void {
    const mode = app.core.modal.mode;
    if (mode != .command and mode != .search) return;

    const display = zgui.io.getDisplaySize();
    const prompt_h: f32 = 38;
    const prompt_y = display[1] - 34 - prompt_h;
    zgui.setNextWindowPos(.{ .x = 0, .y = prompt_y, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = prompt_h, .cond = .always });
    if (zgui.begin("Command Prompt", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true, .no_saved_settings = true } })) {
        drawCommandBar(app, zgui.getWindowDrawList(), zgui.getWindowPos(), zgui.getWindowSize());
    }
    zgui.end();

    if (mode != .command) return;
    const filter = app.core.suggestionFilterText();
    if (filter.len == 0) return;
    const active = tui_commands.activeScope(&app.core);
    const count = tui_cmd.suggestionCount(app.core.allCmds(), filter, active);
    if (count < 2) return;
    const rows = @min(count, 8);
    const row_h: f32 = 39;
    const popup_w = @min(@as(f32, 620), display[0] - 24);
    const popup_h = 31 + row_h * @as(f32, @floatFromInt(rows));
    zgui.setNextWindowPos(.{ .x = 12, .y = prompt_y - popup_h - 6, .cond = .always });
    zgui.setNextWindowSize(.{ .w = popup_w, .h = popup_h, .cond = .always });
    if (zgui.begin("Command Suggestions", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true, .no_saved_settings = true, .no_mouse_inputs = true, .no_nav_inputs = true, .no_nav_focus = true } })) {
        drawCommandSuggestions(app, active, filter, rows);
    }
    zgui.end();
}

fn drawCommandSuggestions(app: anytype, active: tui_cmd.Scope, filter: []const u8, max_rows: usize) void {
    const draw = zgui.getWindowDrawList();
    const origin = zgui.getWindowPos();
    const size = zgui.getWindowSize();
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + size[0], origin[1] + size[1] }, .col = color(patina.bg1), .rounding = 4 });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 4, origin[1] + size[1] }, .col = color(patina.focus), .rounding = 2 });
    draw.addText(.{ origin[0] + 14, origin[1] + 8 }, color(patina.fg3), "COMMANDS", .{});
    draw.addText(.{ origin[0] + size[0] - 96, origin[1] + 8 }, color(patina.fg3), "TAB TO CYCLE", .{});

    const selected = app.core.suggestionSelected(active);
    var match_index: usize = 0;
    var drawn: usize = 0;
    for (app.core.allCmds()) |command| {
        if (tui_cmd.hiddenFromCompletion(command) or !tui_cmd.visible(command, active)) continue;
        if (!std.mem.startsWith(u8, command.name, filter)) continue;
        if (drawn >= max_rows) break;
        const y = origin[1] + 30 + @as(f32, @floatFromInt(drawn)) * 39;
        const is_selected = match_index == selected;
        if (is_selected) {
            draw.addRectFilled(.{ .pmin = .{ origin[0] + 7, y }, .pmax = .{ origin[0] + size[0] - 7, y + 35 }, .col = color(patina.bg4), .rounding = 3 });
            draw.addRectFilled(.{ .pmin = .{ origin[0] + 7, y }, .pmax = .{ origin[0] + 10, y + 35 }, .col = color(patina.focus), .rounding = 2 });
        }
        draw.addText(.{ origin[0] + 20, y + 4 }, color(if (is_selected) patina.fg0 else patina.fg1), ":{s}", .{command.name});
        draw.addText(.{ origin[0] + 185, y + 4 }, color(if (is_selected) patina.fg2 else patina.fg3), "{s}", .{command.desc});
        match_index += 1;
        drawn += 1;
    }
}

fn drawCommandBar(app: anytype, draw: zgui.DrawList, pos: [2]f32, size: [2]f32) void {
    const prompt: []const u8 = if (app.core.modal.mode == .command) ":" else "/";
    const text_y = pos[1] + (size[1] - zgui.getTextLineHeight()) / 2;
    const prompt_x = pos[0] + 13;
    const input_x = prompt_x + zgui.calcTextSize(prompt, .{})[0] + 4;
    const input = app.core.modal.cmd_buf[0..app.core.modal.cmd_len];

    draw.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + size[0], pos[1] + size[1] },
        .col = color(patina.bg2),
    });
    draw.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + 4, pos[1] + size[1] },
        .col = color(patina.focus),
    });
    draw.addText(.{ prompt_x, text_y }, color(patina.focus), "{s}", .{prompt});
    draw.addText(.{ input_x, text_y }, color(patina.fg0), "{s}", .{input});

    if (app.core.modal.mode == .command) {
        if (std.mem.indexOfScalar(u8, input, ' ')) |space| {
            const name = input[0..space];
            for (app.core.allCmds()) |command| {
                if (!std.mem.eql(u8, command.name, name)) continue;
                const hint_x = input_x + zgui.calcTextSize(input, .{})[0] + 18;
                draw.addText(.{ hint_x, text_y }, color(patina.fg3), "{s}", .{command.desc});
                break;
            }
        }
        draw.addText(.{ pos[0] + size[0] - 150, text_y }, color(patina.fg3), "TAB complete   ESC close", .{});
    } else {
        draw.addText(.{ pos[0] + size[0] - 102, text_y }, color(patina.fg3), "ENTER search", .{});
    }

    const before_cursor = input[0..app.core.modal.cmd_cursor];
    const cursor_x = input_x + zgui.calcTextSize(before_cursor, .{})[0];
    draw.addRectFilled(.{
        .pmin = .{ cursor_x, text_y },
        .pmax = .{ cursor_x + 1, text_y + zgui.getTextLineHeight() },
        .col = color(patina.fg0),
    });
}

fn drawStatusSegment(draw: zgui.DrawList, x: f32, y: f32, height: f32, bg: [4]f32, fg: [4]f32, label: []const u8) f32 {
    const padding: f32 = 13;
    const text_size = zgui.calcTextSize(label, .{});
    const width = text_size[0] + padding * 2;
    draw.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + width, y + height }, .col = color(bg) });
    draw.addText(.{ x + padding, y + (height - text_size[1]) / 2 }, color(fg), "{s}", .{label});
    return x + width;
}

fn drawStatusSegmentRight(draw: zgui.DrawList, right: f32, y: f32, height: f32, bg: [4]f32, fg: [4]f32, label: []const u8) void {
    const padding: f32 = 13;
    const text_size = zgui.calcTextSize(label, .{});
    const width = text_size[0] + padding * 2;
    const x = right - width;
    draw.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ right, y + height }, .col = color(bg) });
    draw.addText(.{ x + padding, y + (height - text_size[1]) / 2 }, color(fg), "{s}", .{label});
}

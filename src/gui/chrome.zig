//! Fixed window chrome shared by every GUI view: the transport readout strip,
//! the status bar, and the command prompt with its suggestion popup.

const std = @import("std");
const ws = @import("wstudio");
const tui = @import("../tui/tui.zig");
const tui_cmd = @import("../ui/cmd.zig");
const tui_commands = @import("../ui/commands.zig");
const tui_style = @import("../tui/style.zig");
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
    }
    zgui.end();
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
        const status = tuiStatusText(app, &left_buf, &right_buf);
        const mode_label = statusModeLabel(app.core.modal.mode);
        const x = drawStatusSegment(draw, pos[0], pos[1], size[1], statusModeColor(app.core.modal.mode), patina.bg0, mode_label);
        const context = std.mem.trim(u8, status.left, " ");
        if (context.len > 0) {
            const text_size = zgui.calcTextSize(context, .{});
            draw.addText(.{ x + 12, pos[1] + (size[1] - text_size[1]) / 2 }, color(patina.fg1), "{s}", .{context});
        }
        if (status.right.len > 0) {
            const right_color = if (app.core.view == .arrangement)
                if (app.core.session.song_mode) patina.audio else patina.rhythm
            else
                statusModeColor(app.core.modal.mode);
            drawStatusSegmentRight(draw, pos[0] + size[0], pos[1], size[1], right_color, patina.bg0, status.right);
        }
    }
    zgui.end();
}

const StatusText = struct { left: []const u8, right: []const u8 };

// TUI status renderers are the canonical footer content; the GUI strips SGR
// codes and supplies its own presentation so both frontends stay in sync.
fn tuiStatusText(app: anytype, left_out: []u8, right_out: []u8) StatusText {
    var left_ansi: [2048]u8 = undefined;
    var right_ansi: [256]u8 = undefined;
    var left_writer = std.Io.Writer.fixed(&left_ansi);
    var right_writer = std.Io.Writer.fixed(&right_ansi);
    const core = &app.core;
    if (core.view == .tracks) core.tracksRowSync();
    (switch (core.view) {
        .tracks => tui.drawTracksStatus(core, &left_writer, &right_writer),
        .drum_grid => tui.drawDrumStatus(core, &left_writer, &right_writer),
        .synth_editor => tui.drawSynthStatus(core, &left_writer, &right_writer),
        .sampler_editor => tui.drawSamplerStatus(core, &left_writer, &right_writer),
        .piano_roll => tui.drawPianoRollStatus(core, &left_writer, &right_writer),
        .help => tui.drawHelpStatus(core, &left_writer, &right_writer),
        .track_spectrum, .master_spectrum, .group_spectrum => tui.drawFxStatus(core, &left_writer, &right_writer, spectrum_ed.currentTarget(core)),
        .instrument_picker => tui.drawPickerStatus(core, &left_writer, &right_writer, "INSTRUMENT", "insert", false),
        .fx_picker => tui.drawPickerStatus(core, &left_writer, &right_writer, "EFFECT", "insert", true),
        .synth_fx_picker => tui.drawPickerStatus(core, &left_writer, &right_writer, "SYNTH FX", "insert", true),
        .arrangement => tui.drawArrangementStatus(core, &left_writer, &right_writer),
        .file_browser => tui.drawFileBrowserStatus(core, &left_writer, &right_writer),
        .automation => tui.drawAutomationStatus(core, &left_writer, &right_writer),
        .automation_param_picker => tui.drawPickerStatus(core, &left_writer, &right_writer, "PARAM", "pick", true),
        .slicer_grid => tui.drawSlicerStatus(core, &left_writer, &right_writer),
        .preset_picker => tui.drawPresetPickerStatus(core, &left_writer, &right_writer),
    }) catch return .{ .left = "", .right = "" };

    const plain_left = tui_style.stripAnsi(left_writer.buffered(), left_out);
    const without_mode = if (plain_left.len >= 3) plain_left[3..] else plain_left;
    return .{
        .left = without_mode,
        .right = std.mem.trim(u8, tui_style.stripAnsi(right_writer.buffered(), right_out), " "),
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

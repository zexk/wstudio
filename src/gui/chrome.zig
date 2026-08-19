//! Fixed window chrome shared by every GUI view: the transport readout strip,
//! the status bar, and the command prompt with its suggestion popup.

const std = @import("std");
const ws = @import("wstudio");
const status = @import("../ui/status.zig");
const tui_cmd = @import("../ui/cmd.zig");
const commands_load = @import("../ui/commands/load.zig");
const ansi = @import("../ui/ansi.zig");
const icons = @import("../ui/icons.zig");
const spectrum_ed = @import("../ui/editors/fx_editor.zig");
const history = @import("../ui/history.zig");
const gui_style = @import("style.zig");
const meters = @import("meters.zig");
const widgets = @import("widgets.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const theme = &gui_style.palette;
pub const transport_height: f32 = 68;

pub fn drawTransport(app: anytype, audio_label: []const u8) void {
    const snap = app.core.session.engine.uiSnapshot();
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = zgui.io.getDisplaySize()[0], .h = transport_height, .cond = .always });
    if (zgui.begin("Transport", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true, .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
        const transport = app.core.displayTransport(snap.position_frames);
        const bar_beat = transport.positionBarBeat();
        const current_meter = transport.currentMeter();
        var tempo_buf: [32]u8 = undefined;
        const tempo = std.fmt.bufPrint(&tempo_buf, "{d:.1} BPM", .{transport.currentTempo()}) catch "tempo";
        var position_buf: [32]u8 = undefined;
        const position = std.fmt.bufPrint(&position_buf, "{d:0>3}.{d}", .{
            bar_beat.bar +| 1,
            bar_beat.beat + 1,
        }) catch "position";
        var meter_buf: [32]u8 = undefined;
        const meter = std.fmt.bufPrint(&meter_buf, "{d}/{d}", .{ current_meter.numerator, current_meter.denominator }) catch "meter";
        var rate_buf: [32]u8 = undefined;
        const rate = std.fmt.bufPrint(&rate_buf, "{d:.1} kHz", .{@as(f32, @floatFromInt(app.core.session.project.sample_rate)) / 1000.0}) catch "rate";

        // Two concerns, two clusters: transport/musical-time readouts stay
        // left, session/system readouts (what project, what audio backend,
        // how loud) pin to the right edge instead of bunching up right next
        // to the transport cluster on a wide window.
        drawTransportControls(app, snap);
        drawTransportReadout(icons.tempo ++ "  BPM", tempo, false);
        drawTransportReadout(icons.position ++ "  POS", position, false);
        drawTransportReadout(icons.meter ++ "  METER", meter, false);
        drawTransportReadout(icons.sample_rate ++ "  RATE", rate, false);

        const project_title: []const u8 = if (app.core.projectPath()) |path|
            std.fs.path.basename(path)
        else
            app.core.session.project.name;
        const right_fixed_w = group_gap + readoutWidth(icons.audio ++ "  AUDIO", audio_label) + group_gap + level_group_w +
            group_gap + phase_group_w + group_gap + loudness_group_w;
        zgui.sameLine(.{ .spacing = 0 });
        const left_end = zgui.getCursorPosX() + group_gap;
        const project_w = @max(readoutWidth(icons.project ++ "  PROJECT", ""), zgui.getWindowSize()[0] - 20 - left_end - right_fixed_w);
        var project_buf: [256]u8 = undefined;
        const fitted_project_title = ellipsizeToWidth(project_title, project_w, &project_buf, measureValue);
        const right_w = readoutWidth(icons.project ++ "  PROJECT", fitted_project_title) + right_fixed_w;
        zgui.setCursorPosX(@max(left_end, zgui.getWindowSize()[0] - right_w - 20));

        drawTransportReadout(icons.project ++ "  PROJECT", fitted_project_title, true);
        drawTransportReadout(icons.audio ++ "  AUDIO", audio_label, false);
        drawLevelMeters(app, snap);
        drawPhaseMeter(snap.correlation);
        drawLoudnessReadout(snap);

        const draw = zgui.getWindowDrawList();
        const size = zgui.getWindowSize();
        draw.addLine(.{
            .p1 = .{ 0, size[1] - 1 },
            .p2 = .{ size[0], size[1] - 1 },
            .col = color(theme.line),
        });
    }
    zgui.end();
}

fn drawTransportControls(app: anytype, snap: ws.engine.UiSnapshot) void {
    zgui.beginGroup();
    readoutLabel(icons.logo ++ "  TRANSPORT");
    // The action, not the key: space is remappable (and is the leader
    // prefix), so synthesizing it here would hand the click to a user
    // keymap - or leave a chord half-typed - instead of the transport.
    if (widgets.activeIconButton(if (snap.playing or snap.pre_rolling) icons.stop ++ "##transport-stop" else icons.play ++ "##transport-play", if (snap.playing or snap.pre_rolling) "Stop  Space" else "Play  Space", snap.playing, theme.audio)) {
        app.core.applyAction(.toggle_play, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
    zgui.sameLine(.{ .spacing = 5 });
    const recording = snap.pre_rolling or app.core.recording_pending_len > 0 or app.core.recording_active_len > 0;
    if (widgets.activeIconButton(icons.record ++ "##transport-record", if (recording) "Recording" else "Record  Space", recording, theme.danger) and !snap.playing and !snap.pre_rolling) {
        if (!hasArmedAudioTarget(&app.core) and app.core.modal.mode == .normal and
            (app.core.view == .piano_roll or app.core.view == .drum_grid or app.core.view == .slicer_grid))
            app.core.handleKey(.{ .char = 'i' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        app.core.applyAction(.toggle_play, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
    zgui.sameLine(.{ .spacing = 5 });
    if (widgets.iconButton(icons.undo ++ "##transport-undo", "Undo  u")) history.doUndo(&app.core);
    zgui.sameLine(.{ .spacing = 5 });
    if (widgets.iconButton(icons.redo ++ "##transport-redo", "Redo  U")) history.doRedo(&app.core);
    zgui.endGroup();
}

fn hasArmedAudioTarget(core: anytype) bool {
    for (0..core.session.racks.items.len) |i| if (core.session.isAudioArmed(i)) return true;
    return false;
}

// A terminal meter is a handful of colored block cells; a GUI can afford a
// true continuous fill with a per-pixel color gradient and a decaying peak
// hold, so the master bus gets that treatment here instead of reusing the
// TUI's block-cell renderer. Draw itself lives in meters.zig, shared with
// the tracks view's master-row meter.
fn drawLevelMeters(app: anytype, snap: ws.engine.UiSnapshot) void {
    const now = std.Io.Timestamp.now(app.core.io, .awake).nanoseconds;
    const dt: f32 = if (app.meter_last_ns == 0) 0 else @max(0.0, @as(f32, @floatFromInt(now - app.meter_last_ns)) / 1_000_000_000.0);
    app.meter_last_ns = now;
    meters.updateMeterHold(&app.meter_hold_db, snap.peak, dt);
    for (&app.track_meter_hold_db, snap.track_peak) |*hold, peak| meters.updateMeterHold(hold, peak, dt);
    for (&app.group_meter_hold_db, snap.group_peak) |*hold, peak| meters.updateMeterHold(hold, peak, dt);

    zgui.sameLine(.{ .spacing = group_gap });
    zgui.beginGroup();
    readoutLabel(icons.level ++ "  LEVEL");
    const bar_w: f32 = 110;
    const bar_h: f32 = 8;
    const gap: f32 = 3;
    const origin = valueRowOrigin(bar_h * 2 + gap);
    meters.meterBar(zgui.getWindowDrawList(), origin, app.meter_hold_db, bar_w, bar_h, gap);
    zgui.dummy(.{ .w = bar_w, .h = valueRowHeight() });
    zgui.endGroup();
}

/// Master-bus phase correlation, -1 (out-of-phase, cancels in mono) .. +1
/// (in phase) - see dsp/meter.zig's `StereoCorrelation`. Shares the same
/// always-on-screen slot next to LEVEL, the way a hardware phase-scope sits
/// beside the meter bridge.
fn drawPhaseMeter(correlation: f32) void {
    zgui.sameLine(.{ .spacing = group_gap });
    zgui.beginGroup();
    readoutLabel(icons.phase ++ "  PHASE");
    // Bar and number side by side, not stacked: a third line hung the
    // readout below every other group's baseline and into the strip's
    // bottom rule.
    const bar_h: f32 = 8;
    meters.correlationBar(zgui.getWindowDrawList(), valueRowOrigin(bar_h), correlation, phase_bar_w, bar_h);
    zgui.dummy(.{ .w = phase_bar_w, .h = valueRowHeight() });
    zgui.sameLine(.{ .spacing = 8 });
    var corr_buf: [8]u8 = undefined;
    const corr_text = std.fmt.bufPrint(&corr_buf, "{s}{d:.2}", .{ if (correlation >= 0.0) "+" else "", correlation }) catch "?";
    widgets.coloredValue(meters.correlationColor(correlation), "{s}", .{corr_text});
    zgui.endGroup();
}

/// Master-bus K-weighted loudness (LUFS): short-term (3s window, the one
/// worth watching live while mixing) and integrated (gated running average
/// since the last `l`-key reset on the MASTER row) - see dsp/meter.zig's
/// `LoudnessMeter`.
fn drawLoudnessReadout(snap: anytype) void {
    zgui.sameLine(.{ .spacing = group_gap });
    zgui.beginGroup();
    readoutLabel(icons.loudness ++ "  LUFS");
    var short_buf: [16]u8 = undefined;
    var int_buf: [16]u8 = undefined;
    readoutLabel("S");
    zgui.sameLine(.{ .spacing = 4 });
    widgets.coloredValue(theme.fg0, "{s}", .{lufsText(snap.lufs_short_term, &short_buf)});
    zgui.sameLine(.{ .spacing = 10 });
    readoutLabel("I");
    zgui.sameLine(.{ .spacing = 4 });
    widgets.coloredValue(theme.fg0, "{s}", .{lufsText(snap.lufs_integrated, &int_buf)});
    zgui.endGroup();
}

fn lufsText(value: f32, scratch: *[16]u8) []const u8 {
    if (value <= ws.dsp.LoudnessMeter.floor_lufs) return "-inf";
    return std.fmt.bufPrint(scratch, "{d:.1}", .{value}) catch "-inf";
}

/// Every group in the strip labels itself the same way: caption-sized and
/// dimmed. The meter groups used to draw theirs in body text, which left
/// LEVEL/PHASE/LUFS a size larger than the readouts beside them and their
/// value rows a few pixels lower.
fn readoutLabel(text: []const u8) void {
    gui_style.pushFont(.caption);
    zgui.textColored(theme.fg3, "{s}", .{text});
    gui_style.popFont();
}

/// Height of a readout's value row: one line of the value font, so a group
/// whose value is a meter bar takes the same vertical space as one whose
/// value is text.
fn valueRowHeight() f32 {
    gui_style.pushFont(.heading);
    defer gui_style.popFont();
    return zgui.getTextLineHeight();
}

/// Where to draw a `height`-tall bar so it sits centered in that value row.
fn valueRowOrigin(height: f32) [2]f32 {
    const origin = zgui.getCursorScreenPos();
    return .{ origin[0], origin[1] + @max(0, valueRowHeight() - height) / 2 };
}

fn drawTransportReadout(label: []const u8, value: []const u8, first: bool) void {
    if (!first) zgui.sameLine(.{ .spacing = group_gap });
    zgui.beginGroup();
    readoutLabel(label);
    gui_style.pushFont(.heading);
    zgui.textColored(theme.fg0, "{s}", .{value});
    gui_style.popFont();
    zgui.endGroup();
}

/// A `drawTransportReadout` group's on-screen width: the wider of its two
/// stacked lines, same as ImGui's own group sizing. Used to right-align
/// the session/system readout cluster ahead of actually drawing it.
fn readoutWidth(label: []const u8, value: []const u8) f32 {
    gui_style.pushFont(.caption);
    const label_width = zgui.calcTextSize(label, .{})[0];
    gui_style.popFont();
    gui_style.pushFont(.heading);
    const value_width = zgui.calcTextSize(value, .{})[0];
    gui_style.popFont();
    return @max(label_width, value_width);
}

/// Trim `text` to what fits in `max_width` pixels, ending in an ellipsis.
///
/// `measure` is a seam, not indirection for its own sake: the real one asks
/// ImGui, which needs a live context, and the test needs to run without one.
fn ellipsizeToWidth(text: []const u8, max_width: f32, scratch: []u8, measure: *const fn ([]const u8) f32) []const u8 {
    if (measure(text) <= max_width) return text;
    const ellipsis = "…";
    if (scratch.len < ellipsis.len) return "";
    const room = max_width - measure(ellipsis);

    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var len: usize = 0;
    while (it.nextCodepointSlice()) |codepoint| {
        if (len + codepoint.len + ellipsis.len > scratch.len) break;
        @memcpy(scratch[len..][0..codepoint.len], codepoint);
        if (measure(scratch[0 .. len + codepoint.len]) > room) break;
        len += codepoint.len;
    }
    @memcpy(scratch[len..][0..ellipsis.len], ellipsis);
    return scratch[0 .. len + ellipsis.len];
}

/// Width of one line of the readout value font, which is what the project
/// title is drawn in.
fn measureValue(text: []const u8) f32 {
    gui_style.pushFont(.heading);
    defer gui_style.popFont();
    return zgui.calcTextSize(text, .{})[0];
}

test "transport ellipsis fits the width it was given" {
    const fake = struct {
        // Every glyph 10 wide except the ellipsis, so the test can tell
        // "what fits" apart from "how many characters".
        fn measure(text: []const u8) f32 {
            var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
            var width: f32 = 0;
            while (it.nextCodepointSlice()) |codepoint| {
                width += if (std.mem.eql(u8, codepoint, "…")) 5 else 10;
            }
            return width;
        }
    }.measure;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("demo.wsj", ellipsizeToWidth("demo.wsj", 80, &buf, fake));
    try std.testing.expectEqualStrings("demo.wsj", ellipsizeToWidth("demo.wsj", 200, &buf, fake));
    // 35px holds three 10px glyphs and the 5px ellipsis exactly.
    try std.testing.expectEqualStrings("dém…", ellipsizeToWidth("démo.wsj", 35, &buf, fake));
    try std.testing.expectEqualStrings("…", ellipsizeToWidth("demo.wsj", 5, &buf, fake));
    // Narrower than the ellipsis alone: it is still the honest answer, and
    // the caller has already reserved the slot.
    try std.testing.expectEqualStrings("…", ellipsizeToWidth("demo.wsj", 1, &buf, fake));
}

/// `drawLevelMeters`'s on-screen width: the fixed meter-bar width
/// dominates its "LEVEL" label.
const level_group_w: f32 = 110;
const group_gap: f32 = 18;
/// `drawPhaseMeter`'s bar width, and its on-screen group width: the bar
/// plus the signed two-decimal correlation value drawn beside it.
const phase_bar_w: f32 = 70;
const phase_group_w: f32 = phase_bar_w + 8 + 48;
/// `drawLoudnessReadout`'s on-screen width: two side-by-side "S"/"I"
/// sub-columns, each wide enough for a signed one-decimal LUFS value.
const loudness_group_w: f32 = 130;

pub fn drawStatus(app: anytype) void {
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = display[1] - 34, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = 34, .cond = .always });
    if (zgui.begin("Status", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true } })) {
        const draw = zgui.getWindowDrawList();
        const pos = zgui.getWindowPos();
        const size = zgui.getWindowSize();
        draw.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + size[0], pos[1] + size[1] }, .col = color(theme.bg3) });

        var left_buf: [2048]u8 = undefined;
        var right_buf: [256]u8 = undefined;
        const text = tuiStatusText(app, &left_buf, &right_buf);
        const mode_label = statusModeLabel(app.core.modal.mode);
        var x = drawStatusSegment(draw, pos[0], pos[1], size[1], statusModeColor(app.core.modal.mode), theme.bg0, mode_label);
        // Persistent chip while a macro recording runs - mirrors the TUI's
        // own `rec @x` chip (state, not a status message that times out).
        if (app.core.macro_recording) |reg| {
            var rec_buf: [16]u8 = undefined;
            const rec_label = std.fmt.bufPrint(&rec_buf, icons.record ++ " REC {c}", .{'a' + reg}) catch "REC";
            x = drawStatusSegment(draw, x, pos[1], size[1], theme.danger, theme.bg0, rec_label);
        }
        if (app.core.punch_enabled) {
            x = drawStatusSegment(draw, x, pos[1], size[1], theme.danger, theme.bg0, icons.punch ++ " PUNCH");
        }
        // vim's 'showcmd': pending operator/count or visual-selection
        // width - same state-not-message treatment as the REC chip.
        var showcmd_buf: [24]u8 = undefined;
        const showcmd = app.core.pendingCmdText(&showcmd_buf);
        if (showcmd.len > 0) {
            x = drawStatusSegment(draw, x, pos[1], size[1], theme.bg3, theme.fg0, showcmd);
        }
        const context = statusContext(std.mem.trim(u8, text.left, " "), widgets.hover_status);
        if (context.len > 0) {
            const text_size = zgui.calcTextSize(context, .{});
            draw.addText(.{ x + 12, pos[1] + (size[1] - text_size[1]) / 2 }, color(theme.fg1), "{s}", .{context});
        }
        if (text.right.len > 0) {
            const right_color = if (app.core.view == .arrangement)
                if (app.core.session.song_mode) theme.audio else theme.rhythm
            else
                statusModeColor(app.core.modal.mode);
            drawStatusSegmentRight(draw, pos[0] + size[0], pos[1], size[1], right_color, theme.bg0, text.right);
        }
    }
    zgui.end();
}

fn compactStatusContext(text: []const u8) []const u8 {
    var search_from: usize = 0;
    var groups: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, "   ")) |separator| {
        groups += 1;
        if (groups == 2) return std.mem.trimEnd(u8, text[0..separator], " ");
        search_from = separator + 3;
    }
    return text;
}

fn statusContext(normal: []const u8, hover: ?[]const u8) []const u8 {
    return hover orelse compactStatusContext(normal);
}

test "GUI status keeps selection and one contextual hint" {
    try std.testing.expectEqualStrings("kick  vel 90%   enter toggle", compactStatusContext("kick  vel 90%   enter toggle   x clear   ?: help"));
    try std.testing.expectEqualStrings("short status", compactStatusContext("short status"));
}

test "GUI status prefers hovered control help" {
    try std.testing.expectEqualStrings("Remove  x", statusContext("unit 1   h/l adjust   ?: help", "Remove  x"));
    try std.testing.expectEqualStrings("unit 1   h/l adjust", statusContext("unit 1   h/l adjust   ?: help", null));
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
        .soundfont_editor => status.drawSoundfontStatus(core, &left_writer, &right_writer),
        .piano_roll => status.drawPianoRollStatus(core, &left_writer, &right_writer),
        .help => status.drawHelpStatus(core, &left_writer, &right_writer),
        .track_spectrum, .master_spectrum, .group_spectrum => status.drawFxStatus(core, &left_writer, &right_writer, spectrum_ed.currentTarget(core)),
        .instrument_picker => status.drawPickerStatus(core, &left_writer, &right_writer, "INSTRUMENT", "insert", true),
        .fx_picker => status.drawPickerStatus(core, &left_writer, &right_writer, "EFFECT", "insert", true),
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
        .normal => theme.audio,
        .insert => theme.rhythm,
        .visual => theme.modulation,
        .command, .search => theme.focus,
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
    const active = commands_load.activeScope(&app.core);
    const count = tui_cmd.suggestionCount(app.core.allCmds(), filter, active);
    if (count < 2) return;
    const rows = @min(count, @as(usize, app.core.completion_popup_rows));
    const row_h: f32 = 39;
    // Full window width, not a 620px card: the description column is the
    // whole point of the popup, and a DAW's command descriptions are long
    // enough that capping the panel truncated them on a window with room
    // to spare.
    const popup_w = display[0] - 24;
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
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + size[0], origin[1] + size[1] }, .col = color(theme.bg1), .rounding = gui_style.panel_rounding });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 4, origin[1] + size[1] }, .col = color(theme.focus), .rounding = gui_style.item_rounding });
    draw.addText(.{ origin[0] + 14, origin[1] + 8 }, color(theme.fg3), "COMMANDS", .{});
    draw.addText(.{ origin[0] + size[0] - 96, origin[1] + 8 }, color(theme.fg3), "TAB TO CYCLE", .{});

    const selected = app.core.suggestionSelected(active);
    var match_index: usize = 0;
    var drawn: usize = 0;
    for (app.core.allCmds()) |command| {
        if (!tui_cmd.suggestionMatch(app.core.allCmds(), command, filter, active)) continue;
        if (drawn >= max_rows) break;
        const y = origin[1] + 30 + @as(f32, @floatFromInt(drawn)) * 39;
        const is_selected = match_index == selected;
        if (is_selected) {
            draw.addRectFilled(.{ .pmin = .{ origin[0] + 7, y }, .pmax = .{ origin[0] + size[0] - 7, y + 35 }, .col = color(theme.bg4), .rounding = gui_style.item_rounding });
            draw.addRectFilled(.{ .pmin = .{ origin[0] + 7, y }, .pmax = .{ origin[0] + 10, y + 35 }, .col = color(theme.focus), .rounding = gui_style.item_rounding });
        }
        draw.addText(.{ origin[0] + 20, y + 4 }, color(if (is_selected) theme.fg0 else theme.fg1), ":{s}", .{command.name});
        draw.addText(.{ origin[0] + 185, y + 4 }, color(if (is_selected) theme.fg2 else theme.fg3), "{s}", .{command.desc});
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
        .col = color(theme.bg3),
    });
    draw.addText(.{ prompt_x, text_y }, color(theme.focus), "{s}", .{prompt});
    draw.addText(.{ input_x, text_y }, color(theme.fg0), "{s}", .{input});

    if (app.core.modal.mode == .command) {
        if (std.mem.indexOfScalar(u8, input, ' ')) |space| {
            const name = input[0..space];
            for (app.core.allCmds()) |command| {
                if (!std.mem.eql(u8, command.name, name)) continue;
                const hint_x = input_x + zgui.calcTextSize(input, .{})[0] + 18;
                draw.addText(.{ hint_x, text_y }, color(theme.fg3), "{s}", .{command.desc});
                break;
            }
        }
        const hint = "TAB complete   ESC close";
        draw.addText(.{ pos[0] + size[0] - zgui.calcTextSize(hint, .{})[0] - 13, text_y }, color(theme.fg3), "{s}", .{hint});
    } else {
        const hint = "ENTER search";
        draw.addText(.{ pos[0] + size[0] - zgui.calcTextSize(hint, .{})[0] - 13, text_y }, color(theme.fg3), "{s}", .{hint});
    }

    const before_cursor = input[0..app.core.modal.cmd_cursor];
    const cursor_x = input_x + zgui.calcTextSize(before_cursor, .{})[0];
    draw.addRectFilled(.{
        .pmin = .{ cursor_x, text_y },
        .pmax = .{ cursor_x + 1, text_y + zgui.getTextLineHeight() },
        .col = color(theme.fg0),
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

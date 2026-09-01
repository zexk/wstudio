//! GUI application shell: wraps the shared core `App`, maps ImGui input to
//! modal keys, and dispatches the current view to its renderer. GLFW/ImGui
//! lifecycle stays in main.zig; per-view rendering lives in views/<name>.zig.

const std = @import("std");
const ws = @import("wstudio");
const config_mod = @import("../config.zig");
const app_mod = @import("../ui/app.zig");
const history = @import("../ui/history.zig");
const chrome = @import("chrome.zig");
const arrangement_view = @import("views/arrangement.zig");
const audio_view = @import("views/audio.zig");
const automation_view = @import("views/automation.zig");
const drum_view = @import("views/drum.zig");
const file_browser_view = @import("views/file_browser.zig");
const fx_view = @import("views/fx.zig");
const help_view = @import("views/help.zig");
const piano_view = @import("views/piano.zig");
const picker_view = @import("views/picker.zig");
const sampler_view = @import("views/sampler.zig");
const soundfont_view = @import("views/soundfont.zig");
const slicer_view = @import("views/slicer.zig");
const synth_view = @import("views/synth.zig");
const tracks_view = @import("views/tracks.zig");
const widgets = @import("widgets.zig");
const scroll = @import("scroll.zig");
const zgui = @import("zgui");

pub const App = struct {
    pub const PluginScanPhase = enum { idle, clap, vst3, finish };
    pub const TrackMixerField = enum { gain, pan };
    const TrackMixerEdit = struct { track: u16, field: TrackMixerField, before: f32 };

    core: app_mod.App,
    arrangement_clip: ?arrangement_view.ClipSelection = null,
    arrangement_drag: ?arrangement_view.ClipDrag = null,
    piano_mouse_edit: ?piano_view.MouseEdit = null,
    eq_drag_band: ?u8 = null,
    eq_analyzer_key: ?struct { source: u32, unit: ?*ws.FxUnit } = null,
    waveform_drag: ?sampler_view.RegionHandle = null,
    waveform_slice_glow: [ws.dsp.Slicer.max_slices]f32 = @splat(0),
    waveform_glow_last_ns: i128 = 0,
    automation_edit_active: bool = false,
    piano_velocity_edit_active: bool = false,
    piano_pitch_bend: bool = false,
    instrument_edit_active: bool = false,
    synth_edit_active: bool = false,
    track_mixer_edit: ?TrackMixerEdit = null,
    group_gain_edit: ?struct { group: u8, before: f32 } = null,
    meter_hold_db: [2]f32 = .{ -100, -100 },
    track_meter_hold_db: [ws.engine.max_tracks][2]f32 = [_][2]f32{.{ -100, -100 }} ** ws.engine.max_tracks,
    group_meter_hold_db: [ws.engine.max_groups][2]f32 = [_][2]f32{.{ -100, -100 }} ** ws.engine.max_groups,
    meter_last_ns: i128 = 0,
    /// Which view the one shared workspace window last drew - see
    /// `drawWorkspace`, which resets the scroll when this changes.
    last_workspace_view: app_mod.AppView = .tracks,
    plugin_scan_phase: PluginScanPhase = .idle,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8, user_config: config_mod.Config) !App {
        return .{ .core = try app_mod.App.initConfigured(allocator, io, init_path, user_config) };
    }

    pub fn deinit(self: *App) void {
        self.core.deinit();
    }

    pub fn resetForNewSession(self: *App) void {
        self.arrangement_clip = null;
        self.arrangement_drag = null;
        self.piano_mouse_edit = null;
        self.eq_drag_band = null;
        self.eq_analyzer_key = null;
        self.waveform_drag = null;
        self.waveform_slice_glow = @splat(0);
        self.waveform_glow_last_ns = 0;
        self.automation_edit_active = false;
        self.piano_velocity_edit_active = false;
        self.instrument_edit_active = false;
        self.synth_edit_active = false;
        self.track_mixer_edit = null;
        self.group_gain_edit = null;
        self.meter_hold_db = .{ -100, -100 };
        self.track_meter_hold_db = [_][2]f32{.{ -100, -100 }} ** ws.engine.max_tracks;
        self.group_meter_hold_db = [_][2]f32{.{ -100, -100 }} ** ws.engine.max_groups;
        self.meter_last_ns = 0;
    }

    pub fn startPluginScan(self: *App) void {
        if (self.plugin_scan_phase != .idle) return;
        const environ = self.core.environ orelse {
            self.core.setStatus("plugin scan unavailable", .{});
            return;
        };
        self.core.beginExternalPluginScan(environ);
        self.plugin_scan_phase = .clap;
    }

    pub fn tickPluginScan(self: *App) void {
        const environ = self.core.environ orelse return;
        self.plugin_scan_phase = switch (self.plugin_scan_phase) {
            .idle => .idle,
            .clap => if (self.core.scanExternalPluginFormat(environ, .clap)) .vst3 else .idle,
            .vst3 => if (self.core.scanExternalPluginFormat(environ, .vst3)) .finish else .idle,
            .finish => blk: {
                self.core.finishExternalPluginScan(true);
                break :blk .idle;
            },
        };
    }

    pub fn pluginScanProgress(self: *const App) ?struct { fraction: f32, label: [:0]const u8 } {
        return switch (self.plugin_scan_phase) {
            .idle => null,
            .clap => .{ .fraction = 0, .label = "CLAP" },
            .vst3 => .{ .fraction = 0.5, .label = "VST3" },
            .finish => .{ .fraction = 0.9, .label = "Finalizing" },
        };
    }

    pub fn draw(self: *App, audio_label: []const u8) void {
        widgets.hover_status = null;
        if (self.core.view != .arrangement) self.arrangement_drag = null;
        if (self.core.view != .piano_roll) self.piano_mouse_edit = null;
        if (self.automation_edit_active and (self.core.view != .automation or !zgui.isMouseDown(.left))) {
            if (self.core.session.song_mode) self.core.session.rebuildSongData();
            self.automation_edit_active = false;
        }
        if (self.core.view != .piano_roll or !zgui.isMouseDown(.left)) self.piano_velocity_edit_active = false;
        if (self.core.view != .piano_roll or !zgui.isMouseDown(.right)) self.core.piano_erase_active = false;
        if (self.core.view != .synth_editor or !zgui.isMouseDown(.left)) self.synth_edit_active = false;
        if (self.instrument_edit_active and (!zgui.isMouseDown(.left) and !zgui.isAnyItemActive() or switch (self.core.view) {
            .sampler_editor, .soundfont_editor => false,
            else => true,
        })) {
            history.flushParamNudge(&self.core);
            self.instrument_edit_active = false;
        }
        chrome.drawTransport(self, audio_label);
        drawWorkspace(self);
        chrome.drawStatus(self);
        chrome.drawCommandPrompt(self);
        if (imgui_metrics_open) zgui.showMetricsWindow(&imgui_metrics_open);
    }

    pub fn recordInstrumentEdit(self: *App, track: u16, id: u16) void {
        history.noteParamNudge(&self.core, track, id, 1);
        self.instrument_edit_active = true;
    }

    pub fn recordSynthEdit(self: *App) void {
        if (self.synth_edit_active) return;
        history.push(&self.core, history.captureTrackKindSwap(&self.core, self.core.synth_track));
        self.synth_edit_active = true;
    }

    pub fn beginTrackMixerEdit(self: *App, track: u16, field: TrackMixerField, before: f32) void {
        self.track_mixer_edit = .{ .track = track, .field = field, .before = before };
    }

    pub fn finishTrackMixerEdit(self: *App) void {
        const edit = self.track_mixer_edit orelse return;
        history.recordTrackMixer(&self.core, edit.track, switch (edit.field) {
            .gain => .gain,
            .pan => .pan,
        }, edit.before);
        self.track_mixer_edit = null;
    }

    /// Group-row fader equivalent of `beginTrackMixerEdit` - one undo entry
    /// per drag, opened on activation and closed on release, matching what
    /// `-`/`+` on a group row records.
    pub fn beginGroupGainEdit(self: *App, group: u8, before: f32) void {
        self.group_gain_edit = .{ .group = group, .before = before };
    }

    pub fn finishGroupGainEdit(self: *App) void {
        const edit = self.group_gain_edit orelse return;
        history.recordGroupGain(&self.core, edit.group, edit.before);
        self.group_gain_edit = null;
    }

    pub fn handleShortcuts(self: *App) void {
        defer queued_char = null;
        if (zgui.isAnyItemActive()) return;
        if (zgui.isKeyPressed(.f1, false)) {
            self.core.handleKey(.{ .char = '?' }, std.Io.Timestamp.now(self.core.io, .awake).nanoseconds);
            return;
        }
        // Enter's key-up drives hold-gestures (the piano/drum stamp session
        // shapes a note only while enter is physically held); everything
        // without hold semantics ignores the variant.
        if (zgui.isKeyReleased(.enter) or zgui.isKeyReleased(.keypad_enter)) {
            self.core.handleKey(.enter_release, std.Io.Timestamp.now(self.core.io, .awake).nanoseconds);
        }
        if (pressedModalKey(self.core.modal.mode)) |key| {
            const now_ns = std.Io.Timestamp.now(self.core.io, .awake).nanoseconds;
            if (key == .escape and isPickerView(self.core.view)) {
                picker_view.dismiss(self, now_ns);
                return;
            }
            self.core.handleKey(key, now_ns);
        }
    }
};

/// ImGui's own metrics/debugger window, opened by running with
/// `WSTUDIO_IMGUI_METRICS=1` in the environment. It lists every window,
/// its rect and its draw commands, which is how a layout question about
/// this frontend gets answered by looking rather than by guessing. Behind
/// an environment variable rather than a command because it is a tool for
/// working on wstudio, not a feature of it.
pub var imgui_metrics_open: bool = false;

fn bodyHeight(prompt_open: bool) f32 {
    return zgui.io.getDisplaySize()[1] - chrome.transport_height - 34 - @as(f32, if (prompt_open) 38 else 0);
}

fn drawWorkspace(app: *App) void {
    if (app.core.view != .track_spectrum and app.core.view != .master_spectrum and app.core.view != .group_spectrum and app.eq_analyzer_key != null) {
        _ = app.core.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
        app.eq_analyzer_key = null;
    }
    const body_h = bodyHeight(app.core.modal.mode == .command or app.core.modal.mode == .search);
    zgui.setNextWindowPos(.{ .x = 0, .y = chrome.transport_height, .cond = .always });
    zgui.setNextWindowSize(.{ .w = zgui.io.getDisplaySize()[0], .h = body_h, .cond = .always });
    if (zgui.begin("Workspace", .{ .flags = .{ .no_title_bar = true, .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true, .no_scrollbar = true } })) {
        const overlay = isPickerView(app.core.view);
        const workspace_view = if (overlay) pickerBaseView(app) else app.core.view;
        // One ImGui window backs every view and ImGui keeps scroll per
        // window, so a view opened after a scrolled one starts at the other
        // one's offset - looking, at worst, like it rendered nothing. Reset
        // on the switch; the cursor-follow below then places it.
        if (workspaceViewChanged(&app.last_workspace_view, workspace_view)) zgui.setScrollY(0);
        drawView(app, workspace_view);
        // The view has finished submitting; this is the window that actually
        // scrolls, so bring whatever row it marked as focused on screen. A
        // picker overlay does its own scrolling inside its own child, and
        // must not drag the base view underneath it around.
        if (!overlay) scroll.scrollFocusIntoView() else scroll.clearFocusRow();
        if (overlay) {
            picker_view.beginOverlay();
            drawPicker(app);
            picker_view.endOverlay();
        }
    }
    zgui.end();
}

fn drawView(app: *App, view: app_mod.AppView) void {
    switch (view) {
        .tracks => tracks_view.draw(app),
        .audio_editor => audio_view.draw(app),
        .arrangement => arrangement_view.draw(app),
        .piano_roll => piano_view.draw(app),
        .drum_grid => drum_view.draw(app),
        .slicer_grid => slicer_view.draw(app),
        .synth_editor => synth_view.draw(app),
        .sampler_editor => sampler_view.draw(app),
        .soundfont_editor => soundfont_view.draw(app),
        .track_spectrum, .master_spectrum, .group_spectrum => fx_view.draw(app),
        .automation => automation_view.draw(app),
        .instrument_picker, .fx_picker, .preset_picker, .automation_param_picker, .file_browser => {},
        .help => help_view.draw(app),
    }
}

fn drawPicker(app: *App) void {
    switch (app.core.view) {
        .instrument_picker => picker_view.drawInstrument(app),
        .fx_picker => picker_view.drawFx(app),
        .preset_picker => picker_view.drawPreset(app),
        .automation_param_picker => automation_view.drawParamPicker(app),
        .file_browser => file_browser_view.draw(app),
        else => unreachable,
    }
}

fn isPickerView(view: app_mod.AppView) bool {
    return switch (view) {
        // The file browser is a picker in everything but name: a modal list
        // over whatever view opened it, dismissed with esc, chosen with
        // enter. It gets the same Telescope overlay rather than a workspace
        // of its own.
        .instrument_picker, .fx_picker, .preset_picker, .automation_param_picker, .file_browser => true,
        else => false,
    };
}

fn pickerBaseView(app: *const App) app_mod.AppView {
    return switch (app.core.view) {
        .instrument_picker => .tracks,
        .fx_picker => app.core.fx_picker_return,
        .preset_picker => app.core.preset_picker_return,
        .automation_param_picker => .automation,
        // `openBrowser` parks the view it was opened from in `prev_view` and
        // restores it on close, so that's what belongs behind the overlay.
        // It is never a picker itself (the browser is only reachable from a
        // workspace view), but fall back rather than recurse if that ever
        // changes.
        .file_browser => if (isPickerView(app.core.prev_view)) .tracks else app.core.prev_view,
        else => app.core.view,
    };
}

fn workspaceViewChanged(previous: *app_mod.AppView, current: app_mod.AppView) bool {
    if (previous.* == current) return false;
    previous.* = current;
    return true;
}

/// The character GLFW's char callback delivered this frame (see
/// `pushChar`/gui.zig's `onChar`). Named `zgui.Key` values identify physical
/// positions; this carries the actual OS-layout-produced character for
/// letters, digits, and punctuation. Cleared every frame in
/// `handleShortcuts` regardless of whether it was consumed.
var queued_char: ?u8 = null;

/// Called from gui.zig's GLFW char callback with the Unicode codepoint the
/// OS produced for the current keyboard layout.
pub fn pushChar(codepoint: u21) void {
    if (codepoint >= 0x20 and codepoint < 0x7f) queued_char = @intCast(codepoint);
}

fn keyRepeats(mode: ws.input.Mode, key: ws.input.Key) bool {
    return switch (mode) {
        .command, .search => switch (key) {
            .char, .backspace, .delete, .arrow_up, .arrow_down, .arrow_left, .arrow_right, .word_left, .word_right, .history_prev, .history_next => true,
            else => false,
        },
        .normal, .visual => switch (key) {
            .arrow_up, .arrow_down, .arrow_left, .arrow_right => true,
            .char => |c| std.mem.indexOfScalar(u8, "hjkl+-=_<>[]{}();'", c) != null,
            else => false,
        },
        .insert => false,
    };
}

fn pressedModalKey(mode: ws.input.Mode) ?ws.input.Key {
    const ctrl = zgui.isKeyDown(.mod_ctrl);
    if (ctrl and zgui.isKeyPressed(.a, false)) return .ctrl_a;
    if (ctrl and zgui.isKeyPressed(.b, false)) return .ctrl_b;
    if (ctrl and zgui.isKeyPressed(.c, false)) return .ctrl_c;
    if (ctrl and zgui.isKeyPressed(.e, false)) return .ctrl_e;
    if (ctrl and zgui.isKeyPressed(.k, false)) return .ctrl_k;
    if (ctrl and zgui.isKeyPressed(.n, false)) return .ctrl_n;
    if (ctrl and zgui.isKeyPressed(.p, false)) return .ctrl_p;
    if (ctrl and zgui.isKeyPressed(.r, false)) return .ctrl_r;
    if (ctrl and zgui.isKeyPressed(.u, false)) return .ctrl_u;
    if (ctrl and zgui.isKeyPressed(.w, false)) return .ctrl_w;
    if (ctrl and zgui.isKeyPressed(.y, false)) return .ctrl_y;
    const shifted = zgui.isKeyDown(.mod_shift);
    if (shifted and mode == .command and zgui.isKeyPressed(.tab, true)) return .backtab;
    if (mode == .command or mode == .search) {
        if (shifted and zgui.isKeyPressed(.up_arrow, true)) return .history_prev;
        if (shifted and zgui.isKeyPressed(.down_arrow, true)) return .history_next;
        if (zgui.isKeyPressed(.page_up, true)) return .history_prev;
        if (zgui.isKeyPressed(.page_down, true)) return .history_next;
    }
    if ((ctrl or shifted) and (mode == .command or mode == .search)) {
        if (zgui.isKeyPressed(.left_arrow, true)) return .word_left;
        if (zgui.isKeyPressed(.right_arrow, true)) return .word_right;
    }
    const special = [_]struct { gui: zgui.Key, modal: ws.input.Key }{
        .{ .gui = .escape, .modal = .escape },
        .{ .gui = .enter, .modal = .enter },
        .{ .gui = .keypad_enter, .modal = .enter },
        .{ .gui = .tab, .modal = .tab },
        .{ .gui = .back_space, .modal = .backspace },
        .{ .gui = .delete, .modal = .delete },
        .{ .gui = .home, .modal = .home },
        .{ .gui = .end, .modal = .end },
        .{ .gui = .up_arrow, .modal = .arrow_up },
        .{ .gui = .down_arrow, .modal = .arrow_down },
        .{ .gui = .left_arrow, .modal = .arrow_left },
        .{ .gui = .right_arrow, .modal = .arrow_right },
    };
    for (special) |entry| if (zgui.isKeyPressed(entry.gui, keyRepeats(mode, entry.modal))) return entry.modal;

    if (zgui.isKeyPressed(.space, false)) return .{ .char = ' ' };
    const letters = "abcdefghijklmnopqrstuvwxyz";
    inline for (letters, 0..) |c, i| {
        const key: zgui.Key = @enumFromInt(@intFromEnum(zgui.Key.a) + i);
        const modal_key: ws.input.Key = .{ .char = queued_char orelse if (shifted) std.ascii.toUpper(c) else c };
        if (zgui.isKeyPressed(key, keyRepeats(mode, modal_key))) return modal_key;
    }
    const digits = "0123456789";
    inline for (digits, 0..) |c, i| {
        const key: zgui.Key = @enumFromInt(@intFromEnum(zgui.Key.zero) + i);
        const modal_key: ws.input.Key = .{ .char = queued_char orelse numberRowChar(c, shifted) };
        if (zgui.isKeyPressed(key, keyRepeats(mode, modal_key))) return modal_key;
    }
    // Resolve the character from `queued_char` rather than a hardcoded
    // US-layout shift table - see the doc comment on `queued_char` above.
    const oem_keys = [_]zgui.Key{
        .apostrophe, .comma,         .minus,        .period,
        .semicolon,  .slash,         .equal,        .left_bracket,
        .back_slash, .right_bracket, .grave_accent,
    };
    for (oem_keys) |key| if (queued_char) |c| {
        if (zgui.isKeyPressed(key, keyRepeats(mode, .{ .char = c }))) return .{ .char = c };
    } else if (zgui.isKeyPressed(key, mode == .command or mode == .search)) {
        return null;
    };
    return null;
}

test "GUI key repeat stays on navigation and prompt editing" {
    try std.testing.expect(keyRepeats(.normal, .{ .char = 'j' }));
    try std.testing.expect(keyRepeats(.visual, .arrow_right));
    try std.testing.expect(keyRepeats(.command, .backspace));
    try std.testing.expect(keyRepeats(.search, .delete));
    try std.testing.expect(keyRepeats(.command, .word_left));
    try std.testing.expect(!keyRepeats(.command, .backtab));
    try std.testing.expect(keyRepeats(.search, .{ .char = 'x' }));
    try std.testing.expect(keyRepeats(.normal, .{ .char = '+' }));
    try std.testing.expect(keyRepeats(.normal, .{ .char = '}' }));
    try std.testing.expect(!keyRepeats(.normal, .{ .char = 'x' }));
    try std.testing.expect(!keyRepeats(.insert, .{ .char = 'j' }));
}

fn numberRowChar(digit: u8, shifted: bool) u8 {
    if (!shifted) return digit;
    return ")!@#$%^&*("[digit - '0'];
}

test "GUI number row respects shift" {
    var plain: [10]u8 = undefined;
    var shifted: [10]u8 = undefined;
    for ("0123456789", 0..) |digit, i| {
        plain[i] = numberRowChar(digit, false);
        shifted[i] = numberRowChar(digit, true);
    }
    try std.testing.expectEqualStrings("0123456789", &plain);
    try std.testing.expectEqualStrings(")!@#$%^&*(", &shifted);
}

test "workspace viewport resets once when view changes" {
    var previous: app_mod.AppView = .tracks;
    try std.testing.expect(!workspaceViewChanged(&previous, .tracks));
    try std.testing.expect(workspaceViewChanged(&previous, .piano_roll));
    try std.testing.expectEqual(app_mod.AppView.piano_roll, previous);
    try std.testing.expect(!workspaceViewChanged(&previous, .piano_roll));
    try std.testing.expect(workspaceViewChanged(&previous, .arrangement));
}

test "GUI drag gestures record one history entry per activation" {
    var app: App = .{ .core = try app_mod.App.init(std.testing.allocator, std.testing.io) };
    defer app.deinit();
    try app.core.session.setInstrument(0, .poly_synth);

    app.recordSynthEdit();
    app.recordSynthEdit();
    try std.testing.expectEqual(@as(usize, 1), app.core.history.undo_stack.items.len);
    app.synth_edit_active = false;
    app.recordSynthEdit();
    try std.testing.expectEqual(@as(usize, 2), app.core.history.undo_stack.items.len);

    automation_view.recordAutomationGesture(&app);
    automation_view.recordAutomationGesture(&app);
    try std.testing.expectEqual(@as(usize, 3), app.core.history.undo_stack.items.len);
    app.automation_edit_active = false;
    automation_view.recordAutomationGesture(&app);
    try std.testing.expectEqual(@as(usize, 4), app.core.history.undo_stack.items.len);

    piano_view.recordVelocityGesture(&app);
    piano_view.recordVelocityGesture(&app);
    try std.testing.expectEqual(@as(usize, 5), app.core.history.undo_stack.items.len);
    app.piano_velocity_edit_active = false;
    piano_view.recordVelocityGesture(&app);
    try std.testing.expectEqual(@as(usize, 6), app.core.history.undo_stack.items.len);

    app.beginTrackMixerEdit(0, .gain, 0);
    app.core.apiSetTrackGainDb(0, -6);
    app.finishTrackMixerEdit();
    app.finishTrackMixerEdit();
    try std.testing.expectEqual(@as(usize, 7), app.core.history.undo_stack.items.len);
    app.beginTrackMixerEdit(0, .pan, 0);
    app.core.apiSetTrackPan(0, 0.5);
    app.finishTrackMixerEdit();
    try std.testing.expectEqual(@as(usize, 8), app.core.history.undo_stack.items.len);
}

test "GUI picker cards select and escape dismisses" {
    var app: App = .{ .core = try app_mod.App.init(std.testing.allocator, std.Io.failing) };
    defer app.deinit();

    app.core.handleKey(.enter, 0);
    picker_view.dismiss(&app, 0);
    try std.testing.expectEqual(app_mod.AppView.tracks, app.core.view);
    try std.testing.expectEqual(ws.InstrumentKind.empty, std.meta.activeTag(app.core.session.racks.items[0].instrument));

    app.core.handleKey(.enter, 0);
    // Card 2: Audio is card 0 and Synth card 1.
    picker_view.selectInstrument(&app, 2, 0);
    try std.testing.expectEqual(ws.InstrumentKind.sampler, std.meta.activeTag(app.core.session.racks.items[0].instrument));
    try std.testing.expectEqual(app_mod.AppView.sampler_editor, app.core.view);
}

test "GUI plugin scan reports real phase progress" {
    var app: App = .{ .core = try app_mod.App.init(std.testing.allocator, std.Io.failing) };
    defer app.deinit();
    try std.testing.expectEqual(@as(?@TypeOf(app.pluginScanProgress().?), null), app.pluginScanProgress());
    app.plugin_scan_phase = .vst3;
    const progress = app.pluginScanProgress().?;
    try std.testing.expectEqual(@as(f32, 0.5), progress.fraction);
    try std.testing.expectEqualStrings("VST3", progress.label);
}

test "GUI analyzer cache distinguishes FX units on one chain" {
    var app: App = .{ .core = try app_mod.App.init(std.testing.allocator, std.Io.failing) };
    defer app.deinit();
    const fx = &app.core.session.racks.items[0].fx;
    const first = try fx.insert(app.core.session.allocator, 0, .filter, app.core.session.project.sample_rate);
    const second = try fx.insert(app.core.session.allocator, 1, .filter, app.core.session.project.sample_rate);
    app.core.view = .track_spectrum;

    const fx_eq = @import("views/fx_eq.zig");
    fx_eq.ensureEqAnalyzer(&app, .track, first);
    var block: [64]ws.types.Sample = undefined;
    app.core.session.engine.process(&block);
    try std.testing.expectEqual(@as(?*anyopaque, first), app.core.session.engine.active_spectrum_target);

    @import("../ui/editors/fx_editor.zig").setFocus(&app.core, .track, 1);
    fx_eq.ensureEqAnalyzer(&app, .track, second);
    app.core.session.engine.process(&block);
    try std.testing.expectEqual(@as(?*anyopaque, second), app.core.session.engine.active_spectrum_target);
}

test "GUI session reset clears old selections and gestures" {
    var app: App = .{ .core = try app_mod.App.init(std.testing.allocator, std.Io.failing) };
    defer app.deinit();
    app.arrangement_clip = .{ .track = 0, .clip = 0, .start_tick = 0, .rack = app.core.session.racks.items[0] };
    app.arrangement_drag = .{ .selection = app.arrangement_clip.?, .target_tick = 4, .grab_offset_tick = 1 };
    app.piano_mouse_edit = .{ .kind = .move, .source_pitch = 60, .source_step = 0, .target_pitch = 61, .target_step = 1, .duration_steps = 1 };
    app.eq_drag_band = 1;
    app.eq_analyzer_key = .{ .source = 1, .unit = null };
    app.waveform_drag = .start;
    app.automation_edit_active = true;
    app.instrument_edit_active = true;
    app.track_mixer_edit = .{ .track = 0, .field = .gain, .before = -6 };
    app.group_gain_edit = .{ .group = 0, .before = -3 };
    app.meter_hold_db = .{ 0, 0 };

    app.resetForNewSession();

    try std.testing.expect(app.arrangement_clip == null);
    try std.testing.expect(app.arrangement_drag == null);
    try std.testing.expect(app.piano_mouse_edit == null);
    try std.testing.expect(app.eq_drag_band == null);
    try std.testing.expect(app.eq_analyzer_key == null);
    try std.testing.expect(app.waveform_drag == null);
    try std.testing.expect(!app.automation_edit_active);
    try std.testing.expect(!app.instrument_edit_active);
    try std.testing.expect(app.track_mixer_edit == null);
    try std.testing.expect(app.group_gain_edit == null);
    try std.testing.expectEqual([2]f32{ -100, -100 }, app.meter_hold_db);
}

// Zig only analyzes tests in files the test root references explicitly, so a
// view's tests are invisible unless it is named here - a whole file's worth
// of them silently stopped running once already (05f01b7). Every GUI file,
// listed, so adding a test anywhere under src/gui is enough to have it run.
test {
    _ = @import("chrome.zig");
    _ = @import("style.zig");
    _ = @import("widgets.zig");
    _ = @import("scroll.zig");
    _ = @import("meters.zig");
    _ = @import("views/arrangement.zig");
    _ = @import("views/automation.zig");
    _ = @import("views/drum.zig");
    _ = @import("views/file_browser.zig");
    _ = @import("views/fx.zig");
    _ = @import("views/fx_eq.zig");
    _ = @import("views/help.zig");
    _ = @import("views/picker.zig");
    _ = @import("views/piano.zig");
    _ = @import("views/sampler.zig");
    _ = @import("views/slicer.zig");
    _ = @import("views/soundfont.zig");
    _ = @import("views/step_grid.zig");
    _ = @import("views/synth.zig");
    _ = @import("views/tracks.zig");
}

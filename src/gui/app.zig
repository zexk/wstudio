//! GUI application shell: wraps the shared core `App`, maps ImGui input to
//! modal keys, and dispatches the current view to its renderer. GLFW/ImGui
//! lifecycle stays in main.zig; per-view rendering lives in views/<name>.zig.

const std = @import("std");
const ws = @import("wstudio");
const config_mod = @import("../config.zig");
const tui_app = @import("../ui/app.zig");
const history = @import("../ui/history.zig");
const chrome = @import("chrome.zig");
const style = @import("style.zig");
const arrangement_view = @import("views/arrangement.zig");
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
const zgui = @import("zgui");

pub const App = struct {
    core: tui_app.App,
    arrangement_clip: ?arrangement_view.ClipSelection = null,
    piano_mouse_edit: ?piano_view.MouseEdit = null,
    eq_drag_band: ?u8 = null,
    eq_analyzer_key: ?u32 = null,
    waveform_drag: ?sampler_view.RegionHandle = null,
    automation_edit_active: bool = false,
    piano_velocity_edit_active: bool = false,
    instrument_edit_active: bool = false,
    synth_edit_active: bool = false,
    meter_hold_db: [2]f32 = .{ -100, -100 },
    meter_last_ns: i128 = 0,
    /// Which view the one shared workspace window last drew - see
    /// `drawWorkspace`, which resets the scroll when this changes.
    last_workspace_view: tui_app.AppView = .tracks,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8, user_config: config_mod.Config) !App {
        var core = try tui_app.App.initWithSampleRate(allocator, io, user_config.default_sample_rate);
        errdefer core.deinit();
        // An unreadable project on the command line reports and starts blank,
        // the same as the TUI. Failing the whole launch over it means a typo'd
        // path gives you no editor at all to fix it in.
        var loaded_path = false;
        if (init_path) |path| {
            if (ws.persist.load(allocator, io, path)) |session| {
                core.session.deinit();
                core.session = session;
                core.setProjectPath(path);
                loaded_path = true;
            } else |err| {
                std.debug.print("wstudio: cannot load '{s}': {s}\n", .{ path, @errorName(err) });
            }
        }
        core.applyUserConfig(user_config, !loaded_path);
        // A crashed session leaves a `<path>~` autosave; without this the GUI
        // silently ignored it and the next save overwrote the recovery file.
        // Pathless starts check `:w`'s default target, where a pathless
        // autosave lands - same two cases the TUI covers.
        if (loaded_path) {
            core.promptIfBackupNewer(core.projectPath().?);
        } else {
            core.promptIfBackupNewer(core.defaultProjectPath());
        }
        return .{ .core = core };
    }

    pub fn deinit(self: *App) void {
        self.core.deinit();
    }

    pub fn draw(self: *App, audio_label: []const u8) void {
        if (self.core.view != .piano_roll) self.piano_mouse_edit = null;
        if (self.core.view != .automation or !zgui.isMouseDown(.left)) self.automation_edit_active = false;
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
            self.core.handleKey(key, std.Io.Timestamp.now(self.core.io, .awake).nanoseconds);
        }
    }
};

fn bodyHeight(prompt_open: bool) f32 {
    return zgui.io.getDisplaySize()[1] - 98 - @as(f32, if (prompt_open) 38 else 0);
}

fn drawWorkspace(app: *App) void {
    if (app.core.view != .track_spectrum and app.core.view != .master_spectrum and app.core.view != .group_spectrum and app.eq_analyzer_key != null) {
        _ = app.core.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
        app.eq_analyzer_key = null;
    }
    const body_h = bodyHeight(app.core.modal.mode == .command or app.core.modal.mode == .search);
    zgui.setNextWindowPos(.{ .x = 0, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = zgui.io.getDisplaySize()[0], .h = body_h, .cond = .always });
    if (zgui.begin("Workspace", .{ .flags = .{ .no_title_bar = true, .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        const overlay = isPickerView(app.core.view);
        const workspace_view = if (overlay) pickerBaseView(app) else app.core.view;
        // One ImGui window backs every view and ImGui keeps scroll per
        // window, so a view opened after a scrolled one starts at the other
        // one's offset - looking, at worst, like it rendered nothing. Reset
        // on the switch; the cursor-follow below then places it.
        if (app.last_workspace_view != workspace_view) {
            app.last_workspace_view = workspace_view;
            zgui.setScrollY(0);
        }
        drawViewHeader(workspace_view);
        drawView(app, workspace_view);
        // The view has finished submitting; this is the window that actually
        // scrolls, so bring whatever row it marked as focused on screen. A
        // picker overlay does its own scrolling inside its own child, and
        // must not drag the base view underneath it around.
        if (!overlay) widgets.scrollFocusIntoView() else widgets.clearFocusRow();
        if (overlay) {
            picker_view.beginOverlay();
            drawPicker(app);
            picker_view.endOverlay();
        }
    }
    zgui.end();
}

fn drawView(app: *App, view: tui_app.AppView) void {
    switch (view) {
        .tracks => tracks_view.draw(app),
        .arrangement => arrangement_view.draw(app),
        .piano_roll => piano_view.draw(app),
        .drum_grid => drum_view.draw(app),
        .slicer_grid => slicer_view.draw(app),
        .synth_editor => synth_view.draw(app),
        .sampler_editor => sampler_view.draw(app),
        .soundfont_editor => soundfont_view.draw(app),
        .track_spectrum, .master_spectrum, .group_spectrum => fx_view.draw(app),
        .automation => automation_view.draw(app),
        .instrument_picker, .fx_picker, .synth_fx_picker, .preset_picker, .automation_param_picker, .file_browser => {},
        .help => help_view.draw(app),
    }
}

fn drawPicker(app: *App) void {
    switch (app.core.view) {
        .instrument_picker => picker_view.drawInstrument(app),
        .fx_picker, .synth_fx_picker => picker_view.drawFx(app),
        .preset_picker => picker_view.drawPreset(app),
        .automation_param_picker => automation_view.drawParamPicker(app),
        .file_browser => file_browser_view.draw(app),
        else => unreachable,
    }
}

fn isPickerView(view: tui_app.AppView) bool {
    return switch (view) {
        // The file browser is a picker in everything but name: a modal list
        // over whatever view opened it, dismissed with esc, chosen with
        // enter. It gets the same Telescope overlay rather than a workspace
        // of its own.
        .instrument_picker, .fx_picker, .synth_fx_picker, .preset_picker, .automation_param_picker, .file_browser => true,
        else => false,
    };
}

fn pickerBaseView(app: *const App) tui_app.AppView {
    return switch (app.core.view) {
        .instrument_picker => .tracks,
        .fx_picker => app.core.fx_picker_return,
        .synth_fx_picker => .synth_editor,
        .preset_picker => switch (app.core.preset_picker_kind) {
            .synth => .synth_editor,
            .drum => .drum_grid,
            .soundfont => .soundfont_editor,
        },
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

fn drawViewHeader(view: tui_app.AppView) void {
    zgui.textDisabled("WSTUDIO", .{});
    zgui.sameLine(.{ .spacing = 10 });
    zgui.textColored(style.palette.focus, "/  {s}", .{viewTitle(view)});
    zgui.separator();
    zgui.spacing();
}

fn viewTitle(view: tui_app.AppView) []const u8 {
    return switch (view) {
        .tracks => "TRACKS",
        .arrangement => "ARRANGEMENT",
        .piano_roll => "PIANO ROLL",
        .drum_grid => "DRUM GRID",
        .slicer_grid => "SLICER",
        .synth_editor => "SYNTH",
        .sampler_editor => "SAMPLER",
        .soundfont_editor => "SOUNDFONT",
        .track_spectrum => "TRACK SPECTRUM + FX",
        .master_spectrum => "MASTER SPECTRUM + FX",
        .group_spectrum => "GROUP SPECTRUM + FX",
        .automation => "AUTOMATION",
        .instrument_picker => "ADD INSTRUMENT",
        .fx_picker => "ADD EFFECT",
        .synth_fx_picker => "ADD SYNTH EFFECT",
        .preset_picker => "PRESETS",
        .automation_param_picker => "ADD AUTOMATION PARAMETER",
        .file_browser => "FILES",
        .help => "HELP",
    };
}

/// The character GLFW's char callback delivered this frame (see
/// `pushChar`/gui.zig's `onChar`), read by the OEM-key fallback below.
/// Unlike the named `zgui.Key` punctuation tokens - which identify a
/// physical key position, not what it types - this reflects the actual
/// OS-layout-produced character, so it stays correct on non-US layouts
/// (e.g. Italian, where `;`/`:` sit where US has `,`/`.`, not `l`'s
/// neighbor). Cleared every frame in `handleShortcuts` regardless of
/// whether it was consumed.
var queued_char: ?u8 = null;

/// Called from gui.zig's GLFW char callback with the Unicode codepoint the
/// OS produced for the current keyboard layout.
pub fn pushChar(codepoint: u21) void {
    if (codepoint >= 0x20 and codepoint < 0x7f) queued_char = @intCast(codepoint);
}

fn pressedModalKey(_: ws.input.Mode) ?ws.input.Key {
    const ctrl = zgui.isKeyDown(.mod_ctrl);
    if (ctrl and zgui.isKeyPressed(.a, false)) return .ctrl_a;
    if (ctrl and zgui.isKeyPressed(.c, false)) return .ctrl_c;
    if (ctrl and zgui.isKeyPressed(.e, false)) return .ctrl_e;
    if (ctrl and zgui.isKeyPressed(.k, false)) return .ctrl_k;
    if (ctrl and zgui.isKeyPressed(.n, false)) return .ctrl_n;
    if (ctrl and zgui.isKeyPressed(.p, false)) return .ctrl_p;
    if (ctrl and zgui.isKeyPressed(.r, false)) return .ctrl_r;
    if (ctrl and zgui.isKeyPressed(.u, false)) return .ctrl_u;
    if (ctrl and zgui.isKeyPressed(.w, false)) return .ctrl_w;
    const special = [_]struct { gui: zgui.Key, modal: ws.input.Key }{
        .{ .gui = .escape, .modal = .escape },
        .{ .gui = .enter, .modal = .enter },
        .{ .gui = .tab, .modal = .tab },
        .{ .gui = .back_space, .modal = .backspace },
        .{ .gui = .home, .modal = .home },
        .{ .gui = .end, .modal = .end },
        .{ .gui = .up_arrow, .modal = .arrow_up },
        .{ .gui = .down_arrow, .modal = .arrow_down },
        .{ .gui = .left_arrow, .modal = .arrow_left },
        .{ .gui = .right_arrow, .modal = .arrow_right },
    };
    for (special) |entry| if (zgui.isKeyPressed(entry.gui, false)) return entry.modal;

    if (zgui.isKeyPressed(.space, false)) return .{ .char = ' ' };
    const shifted = zgui.isKeyDown(.mod_shift);
    const letters = "abcdefghijklmnopqrstuvwxyz";
    inline for (letters, 0..) |c, i| {
        const key: zgui.Key = @enumFromInt(@intFromEnum(zgui.Key.a) + i);
        if (zgui.isKeyPressed(key, false)) return .{ .char = if (shifted) std.ascii.toUpper(c) else c };
    }
    const digits = "0123456789";
    inline for (digits, 0..) |c, i| {
        const key: zgui.Key = @enumFromInt(@intFromEnum(zgui.Key.zero) + i);
        if (zgui.isKeyPressed(key, false)) return .{ .char = numberRowChar(c, shifted) };
    }
    // Edge-detect on the named OEM key (so holding it doesn't repeat-fire,
    // matching every other normal-mode binding), but resolve the character
    // from `queued_char` rather than a hardcoded US-layout shift table -
    // see the doc comment on `queued_char` above.
    const oem_keys = [_]zgui.Key{
        .apostrophe, .comma,         .minus,        .period,
        .semicolon,  .slash,         .equal,        .left_bracket,
        .back_slash, .right_bracket, .grave_accent,
    };
    for (oem_keys) |key| if (zgui.isKeyPressed(key, false)) {
        if (queued_char) |c| return .{ .char = c };
        return null;
    };
    return null;
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

test {
    _ = @import("views/piano.zig");
}

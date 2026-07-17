//! GUI application shell: wraps the shared core `App`, maps ImGui input to
//! modal keys, and dispatches the current view to its renderer. GLFW/ImGui
//! lifecycle stays in main.zig; per-view rendering lives in views/<name>.zig.

const std = @import("std");
const ws = @import("wstudio");
const config_mod = @import("../config.zig");
const tui_app = @import("../ui/app.zig");
const chrome = @import("chrome.zig");
const arrangement_view = @import("views/arrangement.zig");
const automation_view = @import("views/automation.zig");
const drum_view = @import("views/drum.zig");
const file_browser_view = @import("views/file_browser.zig");
const fx_view = @import("views/fx.zig");
const help_view = @import("views/help.zig");
const piano_view = @import("views/piano.zig");
const picker_view = @import("views/picker.zig");
const sampler_view = @import("views/sampler.zig");
const slicer_view = @import("views/slicer.zig");
const synth_view = @import("views/synth.zig");
const tracks_view = @import("views/tracks.zig");
const zgui = @import("zgui");

pub const App = struct {
    core: tui_app.App,
    picker_return_view: tui_app.AppView = .tracks,
    arrangement_clip: ?struct { track: usize, clip: usize } = null,
    piano_top_pitch: u7 = 84,
    piano_mouse_edit: ?piano_view.MouseEdit = null,
    eq_drag_band: ?u8 = null,
    eq_analyzer_key: ?u32 = null,
    waveform_drag: ?sampler_view.RegionHandle = null,
    meter_hold_db: [2]f32 = .{ -100, -100 },
    meter_last_ns: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8, user_config: config_mod.Config) !App {
        var core = try tui_app.App.initWithSampleRate(allocator, io, user_config.default_sample_rate);
        errdefer core.deinit();
        if (init_path) |path| {
            const session = try ws.persist.load(allocator, io, path);
            core.session.deinit();
            core.session = session;
            core.setProjectPath(path);
        }
        core.applyUserConfig(user_config, init_path == null);
        return .{ .core = core };
    }

    pub fn deinit(self: *App) void {
        self.core.deinit();
    }

    pub fn draw(self: *App, audio_label: []const u8) void {
        if (self.core.view != .piano_roll) self.piano_mouse_edit = null;
        chrome.drawTransport(self, audio_label);
        drawWorkspace(self);
        chrome.drawStatus(self);
        chrome.drawCommandPrompt(self);
    }

    pub fn handleShortcuts(self: *App) void {
        defer queued_char = null;
        if (zgui.isAnyItemActive()) return;
        if (zgui.isKeyPressed(.f1, false)) {
            self.core.handleKey(.{ .char = '?' }, std.Io.Timestamp.now(self.core.io, .awake).nanoseconds);
            return;
        }
        if (pressedModalKey(self.core.modal.mode)) |key| {
            self.core.handleKey(key, std.Io.Timestamp.now(self.core.io, .awake).nanoseconds);
        }
    }

    pub fn openPicker(self: *App, picker: tui_app.AppView) void {
        if (!isPicker(picker)) return;
        if (!isPicker(self.core.view)) self.picker_return_view = self.core.view;
        if (picker == .fx_picker) self.core.fx_picker_return = self.picker_return_view;
        self.core.view = picker;
    }

    pub fn closePicker(self: *App, destination: ?tui_app.AppView) void {
        self.core.view = destination orelse self.picker_return_view;
    }
};

fn isPicker(view: tui_app.AppView) bool {
    return view == .instrument_picker or view == .fx_picker or view == .preset_picker;
}

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
    if (zgui.begin("Workspace", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        switch (app.core.view) {
            .tracks => tracks_view.draw(app),
            .arrangement => arrangement_view.draw(app),
            .piano_roll => piano_view.draw(app),
            .drum_grid => drum_view.draw(app),
            .slicer_grid => slicer_view.draw(app),
            .synth_editor => synth_view.draw(app),
            .sampler_editor => sampler_view.draw(app),
            .track_spectrum, .master_spectrum, .group_spectrum => fx_view.draw(app),
            .automation => automation_view.draw(app),
            .instrument_picker => picker_view.drawInstrument(app),
            .fx_picker, .synth_fx_picker => picker_view.drawFx(app),
            .preset_picker => picker_view.drawPreset(app),
            .automation_param_picker => automation_view.drawParamPicker(app),
            .file_browser => file_browser_view.draw(app),
            .help => help_view.draw(app),
        }
    }
    zgui.end();
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
    if (ctrl and zgui.isKeyPressed(.c, false)) return .ctrl_c;
    if (ctrl and zgui.isKeyPressed(.r, false)) return .ctrl_r;
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

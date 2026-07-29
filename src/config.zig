//! Lua-backed user configuration and scripting runtime.
//!
//! See docs/lua-api.md for the API design this implements. The runtime is
//! created in main.zig before a frontend starts, runs `init.lua`, and then
//! outlives startup so the frontend can attach host hooks (`attachHost`)
//! that route `wstudio.notify`/`wstudio.cmd` into the live App.

const std = @import("std");
const builtin = @import("builtin");
const init_lua_template = @import("init_template").source;
const ws_input = @import("wstudio").input;
const theme_identity = @import("wstudio").theme_identity;
const pattern_mod = @import("wstudio").dsp.pattern;
const DrumMachine = @import("wstudio").dsp.DrumMachine;
const ws_root = @import("wstudio");
const cmd_mod = @import("ui/cmd.zig");
const tui_app = @import("ui/app.zig");
const undo_mod = @import("ui/undo.zig");
const spectrum_ed = @import("ui/editors/spectrum.zig");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

const system_config_path = "/etc/xdg/wstudio/init.lua";
pub const api_level = 1;
pub const version = ws_root.version;

const ApiFunction = struct { name: [:0]const u8, func: c.lua_CFunction };

/// The registration table is also the source for `get_api_info().functions`.
/// A callable API entry cannot ship without appearing in plugin metadata.
const api_functions = [_]ApiFunction{
    .{ .name = "exec", .func = exec },
    .{ .name = "create_user_command", .func = createUserCommand },
    .{ .name = "del_user_command", .func = delUserCommand },
    .{ .name = "create_autocmd", .func = createAutocmd },
    .{ .name = "del_autocmd", .func = delAutocmd },
    .{ .name = "notify", .func = notify },
    .{ .name = "has", .func = apiHas },
    .{ .name = "get_api_info", .func = apiGetInfo },
    .{ .name = "get_context", .func = apiGetContext },
    .{ .name = "get_mode", .func = apiGetMode },
    .{ .name = "get_current_view", .func = apiGetCurrentView },
    .{ .name = "get_current_track", .func = apiGetCurrentTrack },
    .{ .name = "set_hl", .func = apiSetHl },
    .{ .name = "get_hl", .func = apiGetHl },
    .{ .name = "transport_get", .func = apiTransportGet },
    .{ .name = "transport_set", .func = apiTransportSet },
    .{ .name = "play", .func = apiPlay },
    .{ .name = "stop", .func = apiStop },
    .{ .name = "is_playing", .func = apiIsPlaying },
    .{ .name = "get_tempo", .func = apiGetTempo },
    .{ .name = "set_tempo", .func = apiSetTempo },
    .{ .name = "track_count", .func = apiTrackCount },
    .{ .name = "track_get", .func = apiTrackGet },
    .{ .name = "track_set", .func = apiTrackSet },
    .{ .name = "track_add", .func = apiTrackAdd },
    .{ .name = "track_del", .func = apiTrackDel },
    .{ .name = "track_duplicate", .func = apiTrackDuplicate },
    .{ .name = "track_move", .func = apiTrackMove },
    .{ .name = "set_current_track", .func = apiSetCurrentTrack },
    .{ .name = "pattern_get", .func = apiPatternGet },
    .{ .name = "pattern_set", .func = apiPatternSet },
    .{ .name = "notes_get", .func = apiNotesGet },
    .{ .name = "notes_set", .func = apiNotesSet },
    .{ .name = "steps_get", .func = apiStepsGet },
    .{ .name = "steps_set", .func = apiStepsSet },
    .{ .name = "fx_list", .func = apiFxList },
    .{ .name = "fx_add", .func = apiFxAdd },
    .{ .name = "fx_del", .func = apiFxDel },
    .{ .name = "fx_move", .func = apiFxMove },
    .{ .name = "fx_set", .func = apiFxSet },
    .{ .name = "fx_params", .func = apiFxParams },
    .{ .name = "fx_param_set", .func = apiFxParamSet },
    .{ .name = "clip_list", .func = apiClipList },
    .{ .name = "clip_add", .func = apiClipAdd },
    .{ .name = "clip_del", .func = apiClipDel },
    .{ .name = "clip_clear", .func = apiClipClear },
    .{ .name = "section_list", .func = apiSectionList },
    .{ .name = "section_set", .func = apiSectionSet },
    .{ .name = "section_del", .func = apiSectionDel },
    .{ .name = "project_get", .func = apiProjectGet },
    .{ .name = "project_save", .func = apiProjectSave },
    .{ .name = "project_open", .func = apiProjectOpen },
    .{ .name = "project_new", .func = apiProjectNew },
};

comptime {
    @setEvalBranchQuota(10_000);
    for (api_functions, 0..) |a, i| {
        for (api_functions[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) @compileError("duplicate Lua API function: " ++ a.name);
        }
    }
}

/// One name, one hex table (src/theme_identity.zig) - the GUI's panel skin
/// and the TUI's OSC palette theming (tui/theme.zig) both read it.
pub const GuiTheme = theme_identity.Name;

/// `.none` (the default) never touches the terminal: OSC 4/10/11 palette
/// reprogramming is global to the physical terminal, not scoped to
/// wstudio's alternate screen, so under tmux/screen it would recolor other
/// panes sharing that terminal too. Opting into a name is a deliberate
/// choice, not something a first run should spring on someone who picked
/// their terminal colors on purpose - see tui/theme.zig.
pub const TuiTheme = enum {
    none,
    patina,
    patina_light,
    graphite,
    graphite_light,
    umbra,
    catppuccin_mocha,
    catppuccin_latte,
    dracula,
    gruvbox_dark,
    gruvbox_light,
    nord,
    solarized_dark,
    solarized_light,
    tokyonight,
};

/// GUI corner style, covering both ImGui's own chrome (windows, child
/// panels, popups, buttons) and the hand-drawn chrome that reads
/// `gui/style.zig`'s `panel_rounding`/`item_rounding`: track rows, badges,
/// FX slots, meters, canvases. `square` means 0 everywhere. Only musical
/// content blocks (piano-roll notes, step-grid hits, arrangement clips) and
/// knobs keep an explicit radius, so they're untouched either way.
pub const PanelBorder = enum { square, rounded };

/// A config-owned path buffer for string-typed `wstudio.o` options.
/// `Config` is copied by value and reset
/// wholesale on `:reload-config` (`resetForReload`'s `self.config = .{}`),
/// so this owns its bytes rather than holding a Lua-owned slice that
/// wouldn't outlive the assignment.
pub const PathBuf = struct {
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: u16 = 0,

    pub fn init(comptime value: []const u8) PathBuf {
        if (value.len > std.fs.max_path_bytes) @compileError("default path is too long");
        var result: PathBuf = .{};
        @memcpy(result.buf[0..value.len], value);
        result.len = value.len;
        return result;
    }

    pub fn slice(self: *const PathBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Config = struct {
    preferred_frontend: Frontend = .tui,
    default_tempo: f64 = 120.0,
    default_sample_rate: u32 = 48_000,
    default_beats_per_bar: u8 = 4,
    default_octave: u8 = 4,
    default_velocity: f32 = 0.85,
    default_master_gain_db: f32 = 0.0,
    autosave_interval_s: u16 = 30,
    frame_poll_ms: u16 = 30,
    audio_block_frames: u32 = 256,
    audio_backend: @import("wstudio").audio_host.Choice = .auto,
    audio_output_device: PathBuf = .{},
    audio_input_device: PathBuf = .{},
    midi_input_device: PathBuf = .{},
    tap_timeout_ms: u32 = 2000,
    note_preview_ms: u16 = 220,
    cmd_history_lines: u16 = 50,
    status_message_ms: u16 = 3000,
    default_browse_dir: PathBuf = .{},
    clap_plugin_path: PathBuf = .{},
    vst3_plugin_path: PathBuf = .{},
    default_project_path: PathBuf = PathBuf.init("project.wsj"),
    file_browser_show_hidden: bool = false,
    default_drum_grid: @import("wstudio").time_grid.Division = .sixteenth,
    default_piano_grid: @import("wstudio").time_grid.Division = .sixteenth,
    default_piano_triplet_grid: bool = false,
    default_piano_note_length_steps: u8 = 1,
    default_piano_pitch: u7 = 60,
    default_arrangement_grid: @import("wstudio").time_grid.Division = .quarter,
    piano_ghost_notes: bool = false,
    piano_audition: bool = false,
    tui_mouse: bool = true,
    tui_theme: TuiTheme = .none,
    has_nerdfonts: bool = false,
    gui_font_size: f32 = 15.0,
    gui_vsync: bool = true,
    gui_theme: GuiTheme = .patina,
    gui_panel_border: PanelBorder = .square,
    gui_window_width: u16 = 1440,
    gui_window_height: u16 = 900,
    undo_history_entries: u16 = 64,
    default_metronome_enabled: bool = false,
    default_song_mode: bool = false,
    metronome_click_gain: f32 = 1.0,
    count_in_bars: u8 = 1,
    default_midi_velocity_curve: @import("wstudio").midi_velocity.VelocityCurve = .linear,
    default_automation_gain_step_db: f32 = 1.0,
    default_automation_pan_step: f32 = 0.05,
    gui_knob_drag_pixels: f32 = 180.0,
    gui_envelope_drag_pixels: f32 = 140.0,
    gui_meter_decay_db_s: f32 = 24.0,
    bounce_tail_seconds: f32 = 2.0,
    bounce_bit_depth: @import("wstudio").wav.BitDepth = .pcm16,
    default_bounce_path: PathBuf = PathBuf.init("bounce.wav"),
    default_stems_dir: PathBuf = PathBuf.init("stems"),
    master_limiter_ceiling_db: f32 = -0.4,
    master_limiter_release_ms: f32 = 80.0,
    default_drum_steps: u16 = 32,
    default_slicer_steps: u8 = 16,
    default_pattern_length_beats: f64 = 4.0,
    default_swing: f32 = 50.0,
    completion_popup_rows: u8 = 10,
    waveform_low_hz: f32 = 200.0,
    waveform_high_hz: f32 = 4000.0,
    tui_piano_cell_width: u8 = 3,
    tui_drum_cell_width: u8 = 3,
    tui_arrangement_cell_width: u8 = 4,
    tui_spectrum_db_range: f32 = 70.0,
    gui_piano_row_height: f32 = 18.0,
};

pub const Frontend = enum { tui, gui };

/// Which frontend an option affects. Documentation and naming discipline
/// (the tui_/gui_ prefixes), not access control: a TUI session may set
/// `gui_*` options, they just have no effect there.
pub const Scope = enum { core, tui, gui };

const OptionSpec = struct {
    name: [:0]const u8,
    /// Valid range, ignored for bool, enum, and path (`PathBuf`) fields.
    /// All current bounds are whole numbers, so comptime_int keeps them
    /// comparable against both the integer and float values Lua hands over.
    min: comptime_int = 0,
    max: comptime_int = 0,
    scope: Scope = .core,
    allow_empty: bool = true,
};

/// One row per `wstudio.o` option. The Lua getter, setter, and range
/// validation all derive from this table; adding an option is one row here
/// plus its `Config` field.
const option_specs = [_]OptionSpec{
    .{ .name = "preferred_frontend" },
    .{ .name = "default_tempo", .min = 20, .max = 999 },
    .{ .name = "default_sample_rate", .min = 8000, .max = 192000 },
    .{ .name = "default_beats_per_bar", .min = 1, .max = 16 },
    .{ .name = "default_octave", .min = 0, .max = 8 },
    .{ .name = "default_velocity", .min = 0, .max = 1 },
    .{ .name = "default_master_gain_db", .min = -40, .max = 6 },
    .{ .name = "autosave_interval_s", .min = 0, .max = 600 },
    .{ .name = "frame_poll_ms", .min = 5, .max = 1000, .scope = .tui },
    .{ .name = "audio_block_frames", .min = 16, .max = 4096 },
    .{ .name = "audio_backend" },
    .{ .name = "audio_output_device" },
    .{ .name = "audio_input_device" },
    .{ .name = "midi_input_device" },
    .{ .name = "tap_timeout_ms", .min = 100, .max = 10000 },
    .{ .name = "note_preview_ms", .min = 20, .max = 2000 },
    .{ .name = "cmd_history_lines", .min = 10, .max = 500 },
    .{ .name = "status_message_ms", .min = 200, .max = 10000 },
    .{ .name = "default_browse_dir" },
    .{ .name = "clap_plugin_path" },
    .{ .name = "vst3_plugin_path" },
    .{ .name = "default_project_path", .allow_empty = false },
    .{ .name = "file_browser_show_hidden" },
    .{ .name = "default_drum_grid" },
    .{ .name = "default_piano_grid" },
    .{ .name = "default_piano_triplet_grid" },
    .{ .name = "default_piano_note_length_steps", .min = 1, .max = 16 },
    .{ .name = "default_piano_pitch", .min = 0, .max = 127 },
    .{ .name = "default_arrangement_grid" },
    .{ .name = "piano_ghost_notes" },
    .{ .name = "piano_audition" },
    .{ .name = "tui_mouse", .scope = .tui },
    .{ .name = "tui_theme", .scope = .tui },
    .{ .name = "has_nerdfonts", .scope = .tui },
    .{ .name = "gui_font_size", .min = 8, .max = 40, .scope = .gui },
    .{ .name = "gui_vsync", .scope = .gui },
    .{ .name = "gui_theme", .scope = .gui },
    .{ .name = "gui_panel_border", .scope = .gui },
    .{ .name = "gui_window_width", .min = 960, .max = 7680, .scope = .gui },
    .{ .name = "gui_window_height", .min = 600, .max = 4320, .scope = .gui },
    .{ .name = "undo_history_entries", .min = 8, .max = 512 },
    .{ .name = "default_metronome_enabled" },
    .{ .name = "default_song_mode" },
    .{ .name = "metronome_click_gain", .min = 0, .max = 1 },
    .{ .name = "count_in_bars", .min = 0, .max = 4 },
    .{ .name = "default_midi_velocity_curve" },
    .{ .name = "default_automation_gain_step_db", .min = 0, .max = 12 },
    .{ .name = "default_automation_pan_step", .min = 0, .max = 1 },
    .{ .name = "gui_knob_drag_pixels", .min = 40, .max = 600, .scope = .gui },
    .{ .name = "gui_envelope_drag_pixels", .min = 40, .max = 600, .scope = .gui },
    .{ .name = "gui_meter_decay_db_s", .min = 1, .max = 200, .scope = .gui },
    .{ .name = "bounce_tail_seconds", .min = 0, .max = 30 },
    .{ .name = "bounce_bit_depth" },
    .{ .name = "default_bounce_path", .allow_empty = false },
    .{ .name = "default_stems_dir", .allow_empty = false },
    .{ .name = "master_limiter_ceiling_db", .min = -12, .max = 0 },
    .{ .name = "master_limiter_release_ms", .min = 1, .max = 1000 },
    .{ .name = "default_drum_steps", .min = 1, .max = 256 },
    .{ .name = "default_slicer_steps", .min = 1, .max = 64 },
    .{ .name = "default_pattern_length_beats", .min = 1, .max = 64 },
    .{ .name = "default_swing", .min = 50, .max = 75 },
    .{ .name = "completion_popup_rows", .min = 1, .max = 20 },
    .{ .name = "waveform_low_hz", .min = 20, .max = 2000 },
    .{ .name = "waveform_high_hz", .min = 1000, .max = 16000 },
    .{ .name = "tui_piano_cell_width", .min = 1, .max = 7, .scope = .tui },
    .{ .name = "tui_drum_cell_width", .min = 1, .max = 7, .scope = .tui },
    .{ .name = "tui_arrangement_cell_width", .min = 2, .max = 12, .scope = .tui },
    .{ .name = "tui_spectrum_db_range", .min = 20, .max = 120, .scope = .tui },
    .{ .name = "gui_piano_row_height", .min = 8, .max = 48, .scope = .gui },
};

comptime {
    for (option_specs) |spec| {
        if (!@hasField(Config, spec.name)) @compileError("option spec without a Config field: " ++ spec.name);
    }
    if (option_specs.len != @typeInfo(Config).@"struct".fields.len) {
        @compileError("Config field without an option_specs row");
    }
}

// Three surfaces outside this file list every option by hand: the Nix
// modules' typed settings schema, the init.lua template a first run writes
// out, and the docs table. All three drifted in round 5 - `piano_audition`
// shipped reachable only from Lua, missing from all of them - so a test now
// walks the spec table against each. A test rather than a `comptime` block
// so a gap names the option instead of failing every build target; and the
// files are read rather than `@embedFile`d because two of them live outside
// the source package. `zig build test` runs from the repo root, the same
// assumption the project-save tests already make.
//
// Only presence is checked. Ranges and prose stay hand-written: a wrong
// range in the Nix schema rejects a valid value loudly, whereas a missing
// row fails silently, and silent is the case worth guarding.
test "every wstudio.o option appears in the Nix schema, template, and docs" {
    const surfaces = [_]struct { path: []const u8, prefix: []const u8, suffix: []const u8 }{
        .{ .path = "nix/settings.nix", .prefix = "\n    ", .suffix = " =" },
        .{ .path = "examples/init.lua", .prefix = "\n-- wstudio.o.", .suffix = " =" },
        .{ .path = "docs/lua-api.md", .prefix = "`", .suffix = "`" },
    };
    for (surfaces) |surface| {
        const text = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            surface.path,
            std.testing.allocator,
            .limited(1024 * 1024),
        ) catch |err| {
            std.debug.print("cannot read {s} ({s}) - run from the repo root\n", .{ surface.path, @errorName(err) });
            return err;
        };
        defer std.testing.allocator.free(text);
        inline for (option_specs) |spec| {
            var needle_buf: [128]u8 = undefined;
            const needle = try std.fmt.bufPrint(&needle_buf, "{s}{s}{s}", .{ surface.prefix, spec.name, surface.suffix });
            if (std.mem.indexOf(u8, text, needle) == null) {
                std.debug.print("{s} does not document '{s}'\n", .{ surface.path, spec.name });
                return error.OptionSurfaceOutOfDate;
            }
        }
    }
}

test "Nix theme enums match Lua" {
    const text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "nix/settings.nix",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(text);
    inline for (@typeInfo(GuiTheme).@"enum".fields) |field| {
        const quoted = "\"" ++ field.name ++ "\"";
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, quoted));
    }
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\"none\""));
}

pub const max_keymaps = 128;
pub const max_keymap_lhs = 4;
const keymap_cmd_cap = 64;
const keymap_desc_cap = 64;

/// Which `ModalInput` modes a keymap fires in. Command and search modes are
/// deliberately not mappable, so `:` (and with it :help and recovery from a
/// broken config) can never be shadowed.
pub const ModeMask = packed struct(u3) {
    normal: bool = false,
    insert: bool = false,
    visual: bool = false,
};

/// One Lua-registered keymap. Like `UserCmd`, the handler lives in the Lua
/// registry (`ref`, function rhs only) and slices point into embedded
/// buffers - take them through a pointer into `Runtime.keymaps`.
pub const Keymap = struct {
    lhs_buf: [max_keymap_lhs]ws_input.Key,
    lhs_len: u8,
    modes: ModeMask,
    /// Restricts the map to one view; null applies everywhere.
    view: ?tui_app.AppView,
    rhs: enum { lua_fn, command },
    ref: c_int,
    cmd_buf: [keymap_cmd_cap]u8,
    cmd_len: u8,
    desc_buf: [keymap_desc_cap]u8,
    desc_len: u8,

    pub fn lhs(self: *const Keymap) []const ws_input.Key {
        return self.lhs_buf[0..self.lhs_len];
    }

    pub fn cmd(self: *const Keymap) []const u8 {
        return self.cmd_buf[0..self.cmd_len];
    }

    pub fn desc(self: *const Keymap) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }

    pub fn appliesTo(self: *const Keymap, mode: ws_input.Mode, view: tui_app.AppView) bool {
        const mode_ok = switch (mode) {
            .normal => self.modes.normal,
            .insert => self.modes.insert,
            .visual => self.modes.visual,
            else => false,
        };
        if (!mode_ok) return false;
        return self.view == null or self.view.? == view;
    }

    /// "n", "nv", ... - for the :help listing.
    pub fn modeText(self: *const Keymap, buf: *[3]u8) []const u8 {
        var n: usize = 0;
        if (self.modes.normal) {
            buf[n] = 'n';
            n += 1;
        }
        if (self.modes.insert) {
            buf[n] = 'i';
            n += 1;
        }
        if (self.modes.visual) {
            buf[n] = 'v';
            n += 1;
        }
        return buf[0..n];
    }

    /// Renders the lhs back to key notation ("g<c-r>") for the :help listing.
    pub fn lhsText(self: *const Keymap, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        for (self.lhs()) |k| writeKeyText(&w, k) catch break;
        return w.buffered();
    }
};

fn writeKeyText(w: *std.Io.Writer, key: ws_input.Key) !void {
    switch (key) {
        .char => |ch| if (ch == ' ') try w.writeAll("<space>") else try w.writeByte(ch),
        .escape => try w.writeAll("<esc>"),
        .enter => try w.writeAll("<cr>"),
        .tab => try w.writeAll("<tab>"),
        .backspace => try w.writeAll("<bs>"),
        .arrow_up => try w.writeAll("<up>"),
        .arrow_down => try w.writeAll("<down>"),
        .arrow_left => try w.writeAll("<left>"),
        .arrow_right => try w.writeAll("<right>"),
        .home => try w.writeAll("<home>"),
        .end => try w.writeAll("<end>"),
        .ctrl_r => try w.writeAll("<c-r>"),
        .ctrl_w => try w.writeAll("<c-w>"),
        .ctrl_a => try w.writeAll("<c-a>"),
        .ctrl_e => try w.writeAll("<c-e>"),
        .ctrl_u => try w.writeAll("<c-u>"),
        .ctrl_k => try w.writeAll("<c-k>"),
        .ctrl_p => try w.writeAll("<c-p>"),
        .ctrl_n => try w.writeAll("<c-n>"),
        else => try w.writeAll("?"),
    }
}

pub fn keysEqual(a: []const ws_input.Key, b: []const ws_input.Key) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

const LhsError = error{ Empty, TooLong, Invalid };

/// Neovim key notation -> modal keys: plain printable ASCII chars, plus
/// `<...>` specials (see `parseKeyName`). No modifier combinators beyond
/// the ctrl keys the terminal layer actually decodes.
fn parseLhs(text: []const u8, out: *[max_keymap_lhs]ws_input.Key) LhsError!u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (n == max_keymap_lhs) return error.TooLong;
        if (text[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, text, i, '>') orelse return error.Invalid;
            out[n] = try parseKeyName(text[i + 1 .. end]);
            i = end + 1;
        } else {
            if (text[i] < 0x20 or text[i] > 0x7e) return error.Invalid;
            out[n] = .{ .char = text[i] };
            i += 1;
        }
        n += 1;
    }
    if (n == 0) return error.Empty;
    return n;
}

fn parseKeyName(name: []const u8) LhsError!ws_input.Key {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "cr") or eq(name, "enter") or eq(name, "return")) return .enter;
    if (eq(name, "esc")) return .escape;
    if (eq(name, "tab")) return .tab;
    if (eq(name, "bs") or eq(name, "backspace")) return .backspace;
    if (eq(name, "space")) return .{ .char = ' ' };
    if (eq(name, "lt")) return .{ .char = '<' };
    if (eq(name, "up")) return .arrow_up;
    if (eq(name, "down")) return .arrow_down;
    if (eq(name, "left")) return .arrow_left;
    if (eq(name, "right")) return .arrow_right;
    if (eq(name, "home")) return .home;
    if (eq(name, "end")) return .end;
    if (eq(name, "c-r")) return .ctrl_r;
    if (eq(name, "c-w")) return .ctrl_w;
    if (eq(name, "c-a")) return .ctrl_a;
    if (eq(name, "c-e")) return .ctrl_e;
    if (eq(name, "c-u")) return .ctrl_u;
    if (eq(name, "c-k")) return .ctrl_k;
    if (eq(name, "c-p")) return .ctrl_p;
    if (eq(name, "c-n")) return .ctrl_n;
    return error.Invalid;
}

/// Frontend callbacks the Lua runtime routes `wstudio.notify` and
/// `wstudio.cmd` through once a frontend is live. Until `attachHost`,
/// notify prints to stderr and cmd lines queue in the Lua registry.
pub const Host = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque, msg: []const u8) void,
    exec: *const fn (ctx: *anyopaque, line: []const u8) void,
};

/// Registry slot holding `wstudio.cmd` lines issued before a host attaches.
const pending_cmds_key = "wstudio.pending_cmds";

/// Same "small fixed bank" convention as drum banks/Fx.max_units: a config
/// registering more than this many `:` commands is not a real config.
pub const max_user_cmds = 64;
const user_cmd_name_cap = 32;
const user_cmd_desc_cap = 64;

/// One Lua-registered `:` command. The handler lives in the Lua registry
/// (`ref`); Zig owns only the metadata the command table needs. Slices from
/// `name`/`desc` point into the embedded buffers, so take them through a
/// pointer into `Runtime.user_cmds`, never through a copied entry.
pub const UserCmd = struct {
    name_buf: [user_cmd_name_cap]u8,
    name_len: u8,
    desc_buf: [user_cmd_desc_cap]u8,
    desc_len: u8,
    scope: cmd_mod.Scope,
    ref: c_int,

    pub fn name(self: *const UserCmd) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn desc(self: *const UserCmd) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }
};

pub const Runtime = struct {
    state: *c.lua_State,
    frontend: Frontend,
    config: Config = .{},
    host: ?Host = null,
    /// The live App the `wstudio.api` project functions act on. Set by the
    /// frontends alongside `attachHost`; null while init.lua runs, where
    /// those functions raise (startup scripting belongs in a ConfigDone
    /// autocmd or queued `wstudio.cmd` lines).
    app: ?*tui_app.App = null,
    /// `-u {path}` (main.zig), stolen straight from Neovim's own flag: loads
    /// this file instead of the usual `userConfigPath`/`system_config_path`
    /// search, or - the literal value `"NONE"`, also Neovim's convention -
    /// skips loading any config file at all. Set once before the first
    /// `loadUserConfig` call; `:reload-config` re-reads whichever path was
    /// active at startup since `reload` just calls `loadUserConfig` again.
    init_override: ?[]const u8 = null,
    user_cmds: [max_user_cmds]UserCmd = undefined,
    user_cmds_len: usize = 0,
    keymaps: [max_keymaps]Keymap = undefined,
    keymaps_len: usize = 0,
    autocmds: [max_autocmds]Autocmd = undefined,
    autocmds_len: usize = 0,
    next_autocmd_id: u32 = 1,
    highlight_overrides: theme_identity.Overrides = .{},

    pub fn init(frontend: Frontend) !Runtime {
        const state = c.luaL_newstate() orelse return error.OutOfMemory;
        c.luaL_openlibs(state);
        prependUserLuaPath(state);
        return .{ .state = state, .frontend = frontend };
    }

    pub fn deinit(self: *Runtime) void {
        c.lua_close(self.state);
    }

    /// Launching without a frontend flag resolves the frontend from
    /// `wstudio.o.preferred_frontend` *after* init.lua ran, so the runtime
    /// starts provisional and is corrected here. Updates `wstudio.frontend`
    /// too, so ConfigDone autocmds and later callbacks see the truth;
    /// init.lua itself sees the provisional value (documented).
    pub fn setFrontend(self: *Runtime, frontend: Frontend) void {
        self.frontend = frontend;
        const l = self.state;
        if (c.lua_getglobal(l, "wstudio") == c.LUA_TTABLE) {
            _ = c.lua_pushstring(l, @tagName(frontend));
            c.lua_setfield(l, -2, "frontend");
        }
        c.lua_settop(l, -2);
    }

    /// Point the Lua hooks at a live frontend and flush any `wstudio.cmd`
    /// lines queued while init.lua ran, in issue order.
    pub fn attachHost(self: *Runtime, host: Host) void {
        self.host = host;
        const l = self.state;
        if (c.lua_getfield(l, c.LUA_REGISTRYINDEX, pending_cmds_key) == c.LUA_TTABLE) {
            const n: c.lua_Integer = @intCast(c.lua_rawlen(l, -1));
            var i: c.lua_Integer = 1;
            while (i <= n) : (i += 1) {
                _ = c.lua_rawgeti(l, -1, i);
                var len: usize = 0;
                const line = c.lua_tolstring(l, -1, &len);
                if (line != null) host.exec(host.ctx, line[0..len]);
                c.lua_settop(l, -2);
            }
        }
        c.lua_settop(l, -2);
        c.lua_pushnil(l);
        c.lua_setfield(l, c.LUA_REGISTRYINDEX, pending_cmds_key);
        self.emit(.ConfigDone);
    }

    pub fn userCommands(self: *const Runtime) []const UserCmd {
        return self.user_cmds[0..self.user_cmds_len];
    }

    pub fn resolvedTheme(self: *const Runtime, name: theme_identity.Name) theme_identity.Identity {
        return self.highlight_overrides.apply(theme_identity.get(name).*);
    }

    /// Call user command `index`'s Lua handler with the Neovim-shaped opts
    /// table (`opts.args` = the raw argument tail). Handler errors report
    /// once (status line via the host, else stderr) and never propagate -
    /// a failing command must not take the session down.
    pub fn runUserCommand(self: *Runtime, index: usize, args: []const u8) void {
        if (index >= self.user_cmds_len) return;
        const l = self.state;
        _ = c.lua_rawgeti(l, c.LUA_REGISTRYINDEX, self.user_cmds[index].ref);
        c.lua_createtable(l, 0, 1); // opts
        _ = c.lua_pushlstring(l, args.ptr, args.len);
        c.lua_setfield(l, -2, "args");
        if (c.lua_pcallk(l, 1, 0, 0, 0, null) != c.LUA_OK) self.reportCallbackError();
    }

    pub fn userKeymaps(self: *const Runtime) []const Keymap {
        return self.keymaps[0..self.keymaps_len];
    }

    /// Fire keymap `index`: a `:` command line goes through the host's
    /// dispatcher, a Lua handler is pcalled with no arguments. Same error
    /// containment as user commands.
    pub fn runKeymap(self: *Runtime, index: usize) void {
        if (index >= self.keymaps_len) return;
        const km = &self.keymaps[index];
        switch (km.rhs) {
            .command => if (self.host) |h| h.exec(h.ctx, km.cmd()),
            .lua_fn => {
                const l = self.state;
                _ = c.lua_rawgeti(l, c.LUA_REGISTRYINDEX, km.ref);
                if (c.lua_pcallk(l, 0, 0, 0, 0, null) != c.LUA_OK) self.reportCallbackError();
            },
        }
    }

    /// Fire `data`'s event on every subscribed autocmd, in registration
    /// order. Ids are snapshotted first: callbacks may create or delete
    /// autocmds mid-emit, and ones created during an emit must not fire
    /// for it. A callback returning a truthy value (or registered with
    /// `once`) is removed; an erroring callback reports and the rest still
    /// run.
    pub fn emit(self: *Runtime, data: EventData) void {
        var ids: [max_autocmds]u32 = undefined;
        var n: usize = 0;
        for (self.autocmds[0..self.autocmds_len]) |*ac| {
            if (ac.events.contains(std.meta.activeTag(data))) {
                ids[n] = ac.id;
                n += 1;
            }
        }
        for (ids[0..n]) |id| {
            const idx = self.findAutocmd(id) orelse continue; // deleted mid-emit
            const ref = self.autocmds[idx].ref;
            const once = self.autocmds[idx].once;
            const asked_removal = self.fireAutocmd(ref, data);
            if (asked_removal or once) {
                if (self.findAutocmd(id)) |live| self.removeAutocmd(live);
            }
        }
    }

    fn findAutocmd(self: *const Runtime, id: u32) ?usize {
        for (self.autocmds[0..self.autocmds_len], 0..) |*ac, i| {
            if (ac.id == id) return i;
        }
        return null;
    }

    fn removeAutocmd(self: *Runtime, idx: usize) void {
        c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.autocmds[idx].ref);
        std.mem.copyForwards(Autocmd, self.autocmds[idx .. self.autocmds_len - 1], self.autocmds[idx + 1 .. self.autocmds_len]);
        self.autocmds_len -= 1;
    }

    /// Returns whether the callback asked for its own removal (returned a
    /// truthy value, Neovim's convention).
    fn fireAutocmd(self: *Runtime, ref: c_int, data: EventData) bool {
        const l = self.state;
        _ = c.lua_rawgeti(l, c.LUA_REGISTRYINDEX, ref);
        c.lua_createtable(l, 0, 3); // ev
        _ = c.lua_pushstring(l, @tagName(data));
        c.lua_setfield(l, -2, "event");
        switch (data) {
            .ConfigDone, .QuitPre => {},
            .ProjectLoadPost, .ProjectSavePre, .ProjectSavePost => |p| {
                _ = c.lua_pushlstring(l, p.path.ptr, p.path.len);
                c.lua_setfield(l, -2, "path");
            },
            .PlaybackStart, .PlaybackStop => |t| {
                c.lua_pushnumber(l, t.tempo);
                c.lua_setfield(l, -2, "tempo");
            },
            .TrackAdd, .TrackDel => |t| {
                c.lua_pushinteger(l, @intCast(t.track));
                c.lua_setfield(l, -2, "track");
            },
            .TrackMove => |t| {
                c.lua_pushinteger(l, @intCast(t.from));
                c.lua_setfield(l, -2, "from");
                c.lua_pushinteger(l, @intCast(t.to));
                c.lua_setfield(l, -2, "to");
            },
            .ViewEnter => |v| {
                _ = c.lua_pushlstring(l, v.view.ptr, v.view.len);
                c.lua_setfield(l, -2, "view");
                _ = c.lua_pushlstring(l, v.prev.ptr, v.prev.len);
                c.lua_setfield(l, -2, "prev");
            },
            .ColorScheme => |cs| {
                _ = c.lua_pushlstring(l, cs.name.ptr, cs.name.len);
                c.lua_setfield(l, -2, "name");
            },
        }
        if (c.lua_pcallk(l, 1, 1, 0, 0, null) != c.LUA_OK) {
            self.reportCallbackError();
            return false;
        }
        const asked = c.lua_toboolean(l, -1) != 0;
        c.lua_settop(l, -2);
        return asked;
    }

    /// Pop and report a handler error left on the stack by a failed pcall:
    /// once, on the status line via the host (stderr before one attaches),
    /// never propagated - a failing callback must not take the session down.
    fn reportCallbackError(self: *Runtime) void {
        const l = self.state;
        const err = c.lua_tolstring(l, -1, null);
        const text = if (err != null) std.mem.span(err) else "unknown error";
        if (self.host) |h| {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Lua: {s}", .{text[0..@min(text.len, msg_buf.len - 8)]}) catch "Lua error";
            h.notify(h.ctx, msg);
        } else {
            std.debug.print("wstudio: Lua error: {s}\n", .{text});
        }
        c.lua_settop(l, -2);
    }

    pub fn loadFile(self: *Runtime, path: []const u8) !void {
        self.registerApi();
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        if (c.luaL_loadfilex(self.state, &path_buf, null) != c.LUA_OK) return self.luaError();
        if (c.lua_pcallk(self.state, 0, 0, 0, 0, null) != c.LUA_OK) return self.luaError();
    }

    pub fn loadString(self: *Runtime, source: [:0]const u8) !void {
        self.registerApi();
        if (c.luaL_loadstring(self.state, source.ptr) != c.LUA_OK) return self.luaError();
        if (c.lua_pcallk(self.state, 0, 0, 0, 0, null) != c.LUA_OK) return self.luaError();
    }

    pub fn loadUserConfig(self: *Runtime, io: std.Io) !bool {
        if (self.init_override) |p| {
            if (std.mem.eql(u8, p, "NONE")) return false;
            return loadIfPresent(self, io, p);
        }
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (userConfigPath(&path_buf)) |path| {
            return self.loadOrGenerateUserConfig(io, path, system_config_path);
        }
        return loadIfPresent(self, io, system_config_path);
    }

    /// Re-run the user's Lua config from scratch: drop every keymap, user
    /// command, and autocmd it registered so far (unref'ing their Lua
    /// callbacks) and reset `config` to build defaults, then load exactly
    /// like startup did. Without the reset first, re-sourcing would only
    /// ever append to those lists - Neovim's `:source $MYVIMRC` has the same
    /// gap in principle, but leaves it to user configs to guard their own
    /// state (augroups with `clear = true`); there's no equivalent unit here
    /// to ask users to manage, so the runtime clears everything itself. The
    /// `:reload-config` command (ui/commands.zig) is the only caller; the
    /// frontend still has to rebuild its command table and re-apply the
    /// (possibly changed) config afterwards - see `App.afterConfigReload`.
    pub fn reload(self: *Runtime, io: std.Io) !bool {
        self.resetForReload();
        return self.loadUserConfig(io);
    }

    /// The no-I/O half of `reload`, split out so it's testable without
    /// touching the real filesystem (`loadUserConfig` reads `$XDG_CONFIG_HOME`
    /// et al., which a unit test shouldn't depend on).
    fn resetForReload(self: *Runtime) void {
        for (self.user_cmds[0..self.user_cmds_len]) |*uc| c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, uc.ref);
        self.user_cmds_len = 0;
        for (self.keymaps[0..self.keymaps_len]) |*km| {
            if (km.rhs == .lua_fn) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, km.ref);
        }
        self.keymaps_len = 0;
        for (self.autocmds[0..self.autocmds_len]) |*ac| c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ac.ref);
        self.autocmds_len = 0;
        self.highlight_overrides = .{};
        self.config = .{};
    }

    fn loadOrGenerateUserConfig(self: *Runtime, io: std.Io, user_path: []const u8, fallback_path: []const u8) !bool {
        if (try loadIfPresent(self, io, user_path)) return true;
        if (try loadIfPresent(self, io, fallback_path)) return true;
        _ = try generateUserConfig(io, user_path);
        return loadIfPresent(self, io, user_path);
    }

    fn registerApi(self: *Runtime) void {
        // `wstudio.o` is a proxy table. Its metamethods keep option access close
        // to Neovim's Lua API while retaining native validation in Zig.
        c.lua_createtable(self.state, 0, 6); // wstudio
        c.lua_createtable(self.state, 0, 0); // wstudio.o
        c.lua_createtable(self.state, 0, 2); // option proxy metatable
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, setOption, 1);
        c.lua_setfield(self.state, -2, "__newindex");
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, getOption, 1);
        c.lua_setfield(self.state, -2, "__index");
        _ = c.lua_setmetatable(self.state, -2); // metatable -> wstudio.o
        c.lua_setfield(self.state, -2, "o"); // wstudio.o -> wstudio
        _ = c.lua_pushstring(self.state, version);
        c.lua_setfield(self.state, -2, "version"); // wstudio.version
        _ = c.lua_pushstring(self.state, @tagName(self.frontend));
        c.lua_setfield(self.state, -2, "frontend"); // wstudio.frontend
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, notify, 1);
        c.lua_setfield(self.state, -2, "notify"); // wstudio.notify
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, exec, 1);
        c.lua_setfield(self.state, -2, "cmd"); // wstudio.cmd
        c.lua_createtable(self.state, 0, 2); // wstudio.keymap
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, keymapSet, 1);
        c.lua_setfield(self.state, -2, "set"); // wstudio.keymap.set
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, keymapDel, 1);
        c.lua_setfield(self.state, -2, "del"); // wstudio.keymap.del
        c.lua_setfield(self.state, -2, "keymap");
        c.lua_createtable(self.state, 0, api_functions.len); // wstudio.api
        for (api_functions) |f| {
            c.lua_pushlightuserdata(self.state, self);
            c.lua_pushcclosure(self.state, f.func, 1);
            c.lua_setfield(self.state, -2, f.name);
        }
        c.lua_setfield(self.state, -2, "api");
        c.lua_setglobal(self.state, "wstudio");
    }

    fn luaError(self: *Runtime) error{LuaError} {
        const msg = c.lua_tolstring(self.state, -1, null);
        if (msg != null) std.debug.print("wstudio: Lua error: {s}\n", .{std.mem.span(msg)});
        c.lua_settop(self.state, -2);
        return error.LuaError;
    }
};

/// Make `require "foo"` find `~/.config/wstudio/lua/foo.lua` (or
/// `foo/init.lua`), mirroring Neovim's runtime `lua/` directory.
fn prependUserLuaPath(state: *c.lua_State) void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = userConfigDir(&dir_buf) orelse return;
    var prefix_buf: [2 * std.fs.max_path_bytes + 32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s}/lua/?.lua;{s}/lua/?/init.lua;", .{ dir, dir }) catch return;
    _ = c.lua_getglobal(state, "package");
    _ = c.lua_pushlstring(state, prefix.ptr, prefix.len);
    _ = c.lua_getfield(state, -2, "path");
    c.lua_concat(state, 2);
    c.lua_setfield(state, -2, "path");
    c.lua_settop(state, -2);
}

fn loadIfPresent(self: *Runtime, io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    try self.loadFile(path);
    return true;
}

fn generateUserConfig(io: std.Io, path: []const u8) !bool {
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    defer file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(init_lua_template);
    try writer.interface.flush();
    return true;
}

pub fn userConfigDir(buf: []u8) ?[]const u8 {
    return configDirFromEnv(
        buf,
        builtin.os.tag,
        envValue("XDG_CONFIG_HOME"),
        envValue("APPDATA"),
        envValue("HOME"),
    );
}

fn envValue(name: [*:0]const u8) ?[]const u8 {
    const value = std.mem.sliceTo(std.c.getenv(name) orelse return null, 0);
    return if (value.len == 0) null else value;
}

fn configDirFromEnv(buf: []u8, os: std.Target.Os.Tag, xdg: ?[]const u8, appdata: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    const sep: u8 = if (os == .windows) '\\' else '/';
    if (xdg) |dir| return std.fmt.bufPrint(buf, "{s}{c}wstudio", .{ dir, sep }) catch null;
    if (os == .windows) {
        if (appdata) |dir| return std.fmt.bufPrint(buf, "{s}{c}wstudio", .{ dir, sep }) catch null;
    }
    if (home) |dir| return std.fmt.bufPrint(buf, "{s}{c}.config{c}wstudio", .{ dir, sep, sep }) catch null;
    return null;
}

pub fn userConfigPath(buf: []u8) ?[]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = userConfigDir(&dir_buf) orelse return null;
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.bufPrint(buf, "{s}{c}init.lua", .{ dir, sep }) catch null;
}

test "config directory follows platform conventions" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\Users\\Ada\\AppData\\Roaming\\wstudio", configDirFromEnv(&buf, .windows, null, "C:\\Users\\Ada\\AppData\\Roaming", null).?);
    try std.testing.expectEqualStrings("D:\\xdg\\wstudio", configDirFromEnv(&buf, .windows, "D:\\xdg", "C:\\AppData", "C:\\Users\\Ada").?);
    try std.testing.expectEqualStrings("/home/ada/.config/wstudio", configDirFromEnv(&buf, .linux, null, null, "/home/ada").?);
}

fn runtime(state: *c.lua_State) *Runtime {
    return @ptrCast(@alignCast(c.lua_touserdata(state, c.lua_upvalueindex(1))));
}

fn setOption(state: ?*c.lua_State) callconv(.c) c_int {
    // One comptimePrint per spec row for the range message; the default
    // quota runs out around 40 options.
    @setEvalBranchQuota(100_000);
    const l = state.?;
    const name = std.mem.span(c.luaL_checklstring(l, 2, null));
    inline for (option_specs) |spec| {
        if (std.mem.eql(u8, name, spec.name)) {
            const range_msg = std.fmt.comptimePrint("{s} must be between {d} and {d}", .{ spec.name, spec.min, spec.max });
            @field(runtime(l).config, spec.name) = switch (@typeInfo(@FieldType(Config, spec.name))) {
                .bool => blk: {
                    c.luaL_checktype(l, 3, c.LUA_TBOOLEAN);
                    break :blk c.lua_toboolean(l, 3) != 0;
                },
                .float => blk: {
                    const value = c.luaL_checknumber(l, 3);
                    if (value < spec.min or value > spec.max) return c.luaL_error(l, range_msg);
                    break :blk @floatCast(value);
                },
                .int => blk: {
                    const value = c.luaL_checkinteger(l, 3);
                    if (value < spec.min or value > spec.max) return c.luaL_error(l, range_msg);
                    break :blk @intCast(value);
                },
                .@"enum" => |info| blk: {
                    const names = comptime names: {
                        var s: []const u8 = "";
                        for (info.fields, 0..) |f, i| s = s ++ (if (i == 0) "" else ", ") ++ f.name;
                        break :names s;
                    };
                    const enum_msg = std.fmt.comptimePrint("{s} must be one of: {s}", .{ spec.name, names });
                    var slen: usize = 0;
                    const s = c.luaL_checklstring(l, 3, &slen);
                    break :blk std.meta.stringToEnum(@FieldType(Config, spec.name), s[0..slen]) orelse
                        return c.luaL_error(l, enum_msg);
                },
                // Only config-owned path buffers reach here.
                .@"struct" => blk: {
                    var slen: usize = 0;
                    const s = c.luaL_checklstring(l, 3, &slen);
                    if (!spec.allow_empty and slen == 0) return c.luaL_error(l, spec.name ++ " cannot be empty");
                    var pb: PathBuf = .{};
                    if (slen > pb.buf.len) return c.luaL_error(l, spec.name ++ " path is too long");
                    @memcpy(pb.buf[0..slen], s[0..slen]);
                    pb.len = @intCast(slen);
                    break :blk pb;
                },
                else => comptime unreachable,
            };
            return 0;
        }
    }
    return c.luaL_error(l, "unknown option");
}

fn getOption(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const name = std.mem.span(c.luaL_checklstring(l, 2, null));
    inline for (option_specs) |spec| {
        if (std.mem.eql(u8, name, spec.name)) {
            const value = @field(runtime(l).config, spec.name);
            switch (@typeInfo(@TypeOf(value))) {
                .bool => c.lua_pushboolean(l, @intFromBool(value)),
                .float => c.lua_pushnumber(l, value),
                .int => c.lua_pushinteger(l, value),
                .@"enum" => _ = c.lua_pushstring(l, @tagName(value)),
                .@"struct" => _ = c.lua_pushlstring(l, &value.buf, value.len),
                else => comptime unreachable,
            }
            return 1;
        }
    }
    return c.luaL_error(l, "unknown option");
}

fn notify(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    var len: usize = 0;
    const msg = c.luaL_checklstring(l, 1, &len);
    const rt = runtime(l);
    if (rt.host) |h| {
        h.notify(h.ctx, msg[0..len]);
    } else {
        std.debug.print("wstudio: {s}\n", .{msg[0..len]});
    }
    return 0;
}

fn exec(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    var len: usize = 0;
    const line = c.luaL_checklstring(l, 1, &len);
    const rt = runtime(l);
    if (rt.host) |h| {
        h.exec(h.ctx, line[0..len]);
        return 0;
    }
    // No frontend yet (init.lua is still running): queue the line in the
    // Lua registry so attachHost can drain it. Storing it Lua-side avoids
    // threading an allocator into the runtime just for this.
    if (c.lua_getfield(l, c.LUA_REGISTRYINDEX, pending_cmds_key) != c.LUA_TTABLE) {
        c.lua_settop(l, -2);
        c.lua_createtable(l, 1, 0);
        c.lua_pushvalue(l, -1);
        c.lua_setfield(l, c.LUA_REGISTRYINDEX, pending_cmds_key);
    }
    const n: c.lua_Integer = @intCast(c.lua_rawlen(l, -1));
    c.lua_pushvalue(l, 1);
    c.lua_rawseti(l, -2, n + 1);
    c.lua_settop(l, -2);
    return 0;
}

/// `wstudio.api.create_user_command(name, handler, opts?)` - opts takes
/// `desc` (shown by :help and the completion popup) and `scope` (a
/// `cmd.Scope` name gating completion visibility). Re-registering a name
/// replaces its handler, so a config can be re-run idempotently. Built-in
/// commands always win at dispatch (they come first in the combined
/// table), so a clashing name here is shadowed, not an error.
fn createUserCommand(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    var name_len: usize = 0;
    const name_c = c.luaL_checklstring(l, 1, &name_len);
    c.luaL_checktype(l, 2, c.LUA_TFUNCTION);
    const cmd_name = name_c[0..name_len];
    if (cmd_name.len == 0) return c.luaL_error(l, "command name is empty");
    if (cmd_name.len > user_cmd_name_cap) return c.luaL_error(l, "command name is longer than 32 bytes");
    if (std.mem.indexOfScalar(u8, cmd_name, ' ') != null) return c.luaL_error(l, "command name cannot contain spaces");

    var scope: cmd_mod.Scope = .any;
    var desc_buf: [user_cmd_desc_cap]u8 = undefined;
    var desc: []const u8 = "";
    if (c.lua_gettop(l) >= 3 and c.lua_type(l, 3) != c.LUA_TNIL) {
        c.luaL_checktype(l, 3, c.LUA_TTABLE);
        switch (c.lua_getfield(l, 3, "scope")) {
            c.LUA_TNIL => {},
            c.LUA_TSTRING => {
                const s = std.mem.span(c.lua_tolstring(l, -1, null));
                scope = std.meta.stringToEnum(cmd_mod.Scope, s) orelse
                    return c.luaL_error(l, "invalid scope (any, drum, sampler, synth, slicer, soundfont)");
            },
            else => return c.luaL_error(l, "scope must be a string"),
        }
        c.lua_settop(l, -2);
        switch (c.lua_getfield(l, 3, "desc")) {
            c.LUA_TNIL => {},
            c.LUA_TSTRING => {
                var dlen: usize = 0;
                const d = c.lua_tolstring(l, -1, &dlen);
                const kept = @min(dlen, desc_buf.len);
                @memcpy(desc_buf[0..kept], d[0..kept]);
                desc = desc_buf[0..kept];
            },
            else => return c.luaL_error(l, "desc must be a string"),
        }
        c.lua_settop(l, -2);
    }

    const rt = runtime(l);
    const slot: *UserCmd = blk: {
        for (rt.user_cmds[0..rt.user_cmds_len]) |*uc| {
            if (std.mem.eql(u8, uc.name(), cmd_name)) {
                c.luaL_unref(l, c.LUA_REGISTRYINDEX, uc.ref);
                break :blk uc;
            }
        }
        if (rt.user_cmds_len == max_user_cmds) return c.luaL_error(l, "too many user commands");
        rt.user_cmds_len += 1;
        break :blk &rt.user_cmds[rt.user_cmds_len - 1];
    };
    c.lua_pushvalue(l, 2);
    slot.* = .{
        .name_buf = undefined,
        .name_len = @intCast(cmd_name.len),
        .desc_buf = undefined,
        .desc_len = @intCast(desc.len),
        .scope = scope,
        .ref = c.luaL_ref(l, c.LUA_REGISTRYINDEX),
    };
    @memcpy(slot.name_buf[0..cmd_name.len], cmd_name);
    @memcpy(slot.desc_buf[0..desc.len], desc);
    // Registered at runtime (autocmd/keymap handler, not init.lua): the
    // App's combined command table holds slices into `user_cmds` and its
    // trampoline indices must match entry order, so rebuild it now. Null
    // before attachHost, where the frontends rebuild themselves.
    if (rt.app) |app| app.rebuildCmdTable();
    return 0;
}

fn delUserCommand(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    var name_len: usize = 0;
    const name_c = c.luaL_checklstring(l, 1, &name_len);
    const cmd_name = name_c[0..name_len];
    const rt = runtime(l);
    for (rt.user_cmds[0..rt.user_cmds_len], 0..) |*uc, i| {
        if (!std.mem.eql(u8, uc.name(), cmd_name)) continue;
        c.luaL_unref(l, c.LUA_REGISTRYINDEX, uc.ref);
        std.mem.copyForwards(UserCmd, rt.user_cmds[i .. rt.user_cmds_len - 1], rt.user_cmds[i + 1 .. rt.user_cmds_len]);
        rt.user_cmds_len -= 1;
        // Deleting shifts the array the App's table points into - see
        // createUserCommand's matching rebuild.
        if (rt.app) |app| app.rebuildCmdTable();
        return 0;
    }
    return c.luaL_error(l, "no such user command");
}

pub const max_autocmds = 128;

/// The autocmd event set (docs/lua-api.md phase 5). Lua-facing names are
/// these exact tags.
pub const Event = enum {
    ConfigDone,
    ProjectLoadPost,
    ProjectSavePre,
    ProjectSavePost,
    PlaybackStart,
    PlaybackStop,
    TrackAdd,
    TrackDel,
    TrackMove,
    ViewEnter,
    ColorScheme,
    QuitPre,
};

pub const PathEvent = struct { path: []const u8 };
pub const TempoEvent = struct { tempo: f64 };
/// 1-based, matching the API's track indexing.
pub const TrackEvent = struct { track: usize };
pub const TrackMoveEvent = struct { from: usize, to: usize };
pub const ViewEvent = struct { view: []const u8, prev: []const u8 };
/// Neovim's `ColorScheme` autocmd payload, minus `pattern` (there's no glob
/// matching here yet - see create_autocmd's docs/lua-api.md note).
pub const ColorSchemeEvent = struct { name: []const u8 };

/// A typed event emission - the payload becomes fields on the Lua `ev`
/// table (plus `ev.event`, the tag name). Slices only need to live for the
/// duration of the emit call; Lua copies them.
pub const EventData = union(Event) {
    ConfigDone: void,
    ProjectLoadPost: PathEvent,
    ProjectSavePre: PathEvent,
    ProjectSavePost: PathEvent,
    PlaybackStart: TempoEvent,
    PlaybackStop: TempoEvent,
    TrackAdd: TrackEvent,
    TrackDel: TrackEvent,
    TrackMove: TrackMoveEvent,
    ViewEnter: ViewEvent,
    ColorScheme: ColorSchemeEvent,
    QuitPre: void,
};

pub const Autocmd = struct {
    id: u32,
    events: std.EnumSet(Event),
    ref: c_int,
    once: bool,
};

/// Raises a Lua error (longjmp) on anything but "n"/"i"/"v" or a list
/// thereof. Only called from C callbacks with no cleanup pending.
fn checkModes(l: *c.lua_State, idx: c_int) ModeMask {
    switch (c.lua_type(l, idx)) {
        c.LUA_TSTRING => return modeFromString(l, idx),
        c.LUA_TTABLE => {
            const n: c.lua_Integer = @intCast(c.lua_rawlen(l, idx));
            if (n == 0) _ = c.luaL_error(l, "modes list is empty");
            var modes: ModeMask = .{};
            var i: c.lua_Integer = 1;
            while (i <= n) : (i += 1) {
                _ = c.lua_rawgeti(l, idx, i);
                const m = modeFromString(l, -1);
                c.lua_settop(l, -2);
                modes = @bitCast(@as(u3, @bitCast(modes)) | @as(u3, @bitCast(m)));
            }
            return modes;
        },
        else => {
            _ = c.luaL_error(l, "modes must be a string or a list of strings");
            unreachable;
        },
    }
}

fn modeFromString(l: *c.lua_State, idx: c_int) ModeMask {
    if (c.lua_type(l, idx) == c.LUA_TSTRING) {
        const s = std.mem.span(c.lua_tolstring(l, idx, null));
        if (std.mem.eql(u8, s, "n")) return .{ .normal = true };
        if (std.mem.eql(u8, s, "i")) return .{ .insert = true };
        if (std.mem.eql(u8, s, "v")) return .{ .visual = true };
    }
    _ = c.luaL_error(l, "invalid mode (n, i, v)");
    unreachable;
}

fn checkLhs(l: *c.lua_State, idx: c_int, out: *[max_keymap_lhs]ws_input.Key) u8 {
    var len: usize = 0;
    const text = c.luaL_checklstring(l, idx, &len);
    return parseLhs(text[0..len], out) catch |e| {
        _ = switch (e) {
            error.Empty => c.luaL_error(l, "lhs is empty"),
            error.TooLong => c.luaL_error(l, "lhs is longer than 4 keys"),
            error.Invalid => c.luaL_error(l, "invalid key notation in lhs"),
        };
        unreachable;
    };
}

/// Reads opts.view from the (optional) opts table at `opts_idx`.
fn checkViewField(l: *c.lua_State, opts_idx: c_int) ?tui_app.AppView {
    if (c.lua_gettop(l) < opts_idx or c.lua_type(l, opts_idx) == c.LUA_TNIL) return null;
    c.luaL_checktype(l, opts_idx, c.LUA_TTABLE);
    switch (c.lua_getfield(l, opts_idx, "view")) {
        c.LUA_TNIL => {
            c.lua_settop(l, -2);
            return null;
        },
        c.LUA_TSTRING => {
            const s = std.mem.span(c.lua_tolstring(l, -1, null));
            const v = std.meta.stringToEnum(tui_app.AppView, s) orelse {
                _ = c.luaL_error(l, "unknown view");
                unreachable;
            };
            c.lua_settop(l, -2);
            return v;
        },
        else => {
            _ = c.luaL_error(l, "view must be a string");
            unreachable;
        },
    }
}

/// Clear `modes` bits from every map matching (lhs, view); drop entries
/// left with no modes. Returns whether anything changed (del's existence
/// check).
fn removeKeymapModes(l: *c.lua_State, rt: *Runtime, modes: ModeMask, lhs_seq: []const ws_input.Key, view: ?tui_app.AppView) bool {
    var found = false;
    var i: usize = 0;
    while (i < rt.keymaps_len) {
        const km = &rt.keymaps[i];
        if (std.meta.eql(km.view, view) and keysEqual(km.lhs(), lhs_seq)) {
            const before: u3 = @bitCast(km.modes);
            const after = before & ~@as(u3, @bitCast(modes));
            if (after != before) {
                found = true;
                km.modes = @bitCast(after);
                if (after == 0) {
                    if (km.rhs == .lua_fn) c.luaL_unref(l, c.LUA_REGISTRYINDEX, km.ref);
                    std.mem.copyForwards(Keymap, rt.keymaps[i .. rt.keymaps_len - 1], rt.keymaps[i + 1 .. rt.keymaps_len]);
                    rt.keymaps_len -= 1;
                    continue;
                }
            }
        }
        i += 1;
    }
    return found;
}

/// `wstudio.keymap.set(modes, lhs, rhs, opts?)` - rhs is a Lua function or
/// a ':' command string; opts takes `view` and `desc`. Replaces existing
/// maps per (mode, lhs, view), Neovim-style, so configs re-run
/// idempotently. The registry ref is taken last: luaL_error longjmps, and
/// an early validation error must not leak a ref.
fn keymapSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const modes = checkModes(l, 1);
    var lhs_keys: [max_keymap_lhs]ws_input.Key = undefined;
    const lhs_len = checkLhs(l, 2, &lhs_keys);
    const rhs_type = c.lua_type(l, 3);
    var cmd_text: []const u8 = "";
    if (rhs_type == c.LUA_TSTRING) {
        var n: usize = 0;
        const s = c.lua_tolstring(l, 3, &n);
        if (n == 0 or s[0] != ':') return c.luaL_error(l, "string rhs must be a ':' command");
        if (n - 1 > keymap_cmd_cap) return c.luaL_error(l, "rhs command is longer than 64 bytes");
        cmd_text = s[1..n];
    } else if (rhs_type != c.LUA_TFUNCTION) {
        return c.luaL_error(l, "rhs must be a function or a ':' command string");
    }
    const view = checkViewField(l, 4);
    var desc_store: [keymap_desc_cap]u8 = undefined;
    var desc: []const u8 = "";
    if (c.lua_gettop(l) >= 4 and c.lua_type(l, 4) == c.LUA_TTABLE) {
        switch (c.lua_getfield(l, 4, "desc")) {
            c.LUA_TNIL => {},
            c.LUA_TSTRING => {
                var dlen: usize = 0;
                const d = c.lua_tolstring(l, -1, &dlen);
                const kept = @min(dlen, desc_store.len);
                @memcpy(desc_store[0..kept], d[0..kept]);
                desc = desc_store[0..kept];
            },
            else => return c.luaL_error(l, "desc must be a string"),
        }
        c.lua_settop(l, -2);
    }

    const rt = runtime(l);
    _ = removeKeymapModes(l, rt, modes, lhs_keys[0..lhs_len], view);
    if (rt.keymaps_len == max_keymaps) return c.luaL_error(l, "too many keymaps");

    var entry: Keymap = .{
        .lhs_buf = lhs_keys,
        .lhs_len = lhs_len,
        .modes = modes,
        .view = view,
        .rhs = if (rhs_type == c.LUA_TFUNCTION) .lua_fn else .command,
        .ref = c.LUA_NOREF,
        .cmd_buf = undefined,
        .cmd_len = @intCast(cmd_text.len),
        .desc_buf = undefined,
        .desc_len = @intCast(desc.len),
    };
    @memcpy(entry.cmd_buf[0..cmd_text.len], cmd_text);
    @memcpy(entry.desc_buf[0..desc.len], desc);
    if (rhs_type == c.LUA_TFUNCTION) {
        c.lua_pushvalue(l, 3);
        entry.ref = c.luaL_ref(l, c.LUA_REGISTRYINDEX);
    }
    rt.keymaps[rt.keymaps_len] = entry;
    rt.keymaps_len += 1;
    return 0;
}

/// `wstudio.keymap.del(modes, lhs, opts?)` - opts takes `view`, which must
/// match how the map was set.
fn keymapDel(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const modes = checkModes(l, 1);
    var lhs_keys: [max_keymap_lhs]ws_input.Key = undefined;
    const lhs_len = checkLhs(l, 2, &lhs_keys);
    const view = checkViewField(l, 3);
    if (!removeKeymapModes(l, runtime(l), modes, lhs_keys[0..lhs_len], view)) {
        return c.luaL_error(l, "no such keymap");
    }
    return 0;
}

fn requireApp(l: *c.lua_State) *tui_app.App {
    if (runtime(l).app) |app| return app;
    _ = c.luaL_error(l, "no session yet - init.lua runs before the app starts; use a ConfigDone autocmd or wstudio.cmd");
    unreachable;
}

/// 1-based Lua track index -> 0-based internal index; 0 means the track
/// under the cursor (the API's "current" convention).
fn checkTrackIndex(l: *c.lua_State, arg: c_int, app: *tui_app.App) usize {
    const n = c.luaL_checkinteger(l, arg);
    const count = app.session.project.tracks.items.len;
    if (n == 0) {
        if (app.cursor < count) return app.cursor;
        _ = c.luaL_error(l, "the cursor is not on a track");
        unreachable;
    }
    if (n < 1 or n > count) {
        _ = c.luaL_error(l, "track index out of range (1-%d)", @as(c_int, @intCast(count)));
        unreachable;
    }
    return @intCast(n - 1);
}

/// Feature detection for plugins. Looking the name up on the live API table
/// keeps this additive and prevents a second hand-maintained capability list.
fn apiHas(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const name = c.luaL_checklstring(l, 1, null);
    _ = c.lua_getglobal(l, "wstudio");
    _ = c.lua_getfield(l, -1, "api");
    const found = c.lua_getfield(l, -1, name) == c.LUA_TFUNCTION;
    c.lua_pushboolean(l, @intFromBool(found));
    return 1;
}

fn pushEnumNames(l: *c.lua_State, comptime E: type) void {
    const fields = @typeInfo(E).@"enum".fields;
    c.lua_createtable(l, fields.len, 0);
    inline for (fields, 1..) |field, i| {
        _ = c.lua_pushstring(l, field.name);
        c.lua_rawseti(l, -2, i);
    }
}

fn apiGetInfo(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const rt = runtime(l);
    c.lua_createtable(l, 0, 10);
    _ = c.lua_pushstring(l, version);
    c.lua_setfield(l, -2, "version");
    c.lua_pushinteger(l, api_level);
    c.lua_setfield(l, -2, "api_level");
    _ = c.lua_pushstring(l, @tagName(rt.frontend));
    c.lua_setfield(l, -2, "frontend");

    c.lua_createtable(l, api_functions.len, 0);
    for (api_functions, 1..) |f, i| {
        _ = c.lua_pushstring(l, f.name);
        c.lua_rawseti(l, -2, @intCast(i));
    }
    c.lua_setfield(l, -2, "functions");
    pushEnumNames(l, Event);
    c.lua_setfield(l, -2, "events");
    pushEnumNames(l, theme_identity.Highlight);
    c.lua_setfield(l, -2, "highlight_groups");
    pushEnumNames(l, tui_app.AppView);
    c.lua_setfield(l, -2, "views");
    pushEnumNames(l, ws_input.Mode);
    c.lua_setfield(l, -2, "modes");

    c.lua_createtable(l, option_specs.len, 0);
    inline for (option_specs, 1..) |spec, i| {
        c.lua_createtable(l, 0, 5);
        _ = c.lua_pushstring(l, spec.name);
        c.lua_setfield(l, -2, "name");
        _ = c.lua_pushstring(l, @tagName(spec.scope));
        c.lua_setfield(l, -2, "scope");
        const kind = switch (@typeInfo(@FieldType(Config, spec.name))) {
            .bool => "boolean",
            .float, .int => "number",
            .@"enum", .@"struct" => "string",
            else => comptime unreachable,
        };
        _ = c.lua_pushstring(l, kind);
        c.lua_setfield(l, -2, "type");
        if (spec.min != 0 or spec.max != 0) {
            c.lua_pushnumber(l, spec.min);
            c.lua_setfield(l, -2, "min");
            c.lua_pushnumber(l, spec.max);
            c.lua_setfield(l, -2, "max");
        }
        c.lua_rawseti(l, -2, i);
    }
    c.lua_setfield(l, -2, "options");

    c.lua_createtable(l, 0, 10);
    c.lua_pushinteger(l, @import("wstudio").engine.max_tracks);
    c.lua_setfield(l, -2, "tracks");
    c.lua_pushinteger(l, @import("wstudio").engine.max_groups);
    c.lua_setfield(l, -2, "groups");
    c.lua_pushinteger(l, max_keymaps);
    c.lua_setfield(l, -2, "keymaps");
    c.lua_pushinteger(l, max_keymap_lhs);
    c.lua_setfield(l, -2, "keymap_lhs_keys");
    c.lua_pushinteger(l, max_user_cmds);
    c.lua_setfield(l, -2, "user_commands");
    c.lua_pushinteger(l, max_autocmds);
    c.lua_setfield(l, -2, "autocmds");
    c.lua_pushinteger(l, pattern_mod.max_notes);
    c.lua_setfield(l, -2, "pattern_notes");
    c.lua_pushinteger(l, DrumMachine.max_pads);
    c.lua_setfield(l, -2, "drum_pads");
    c.lua_pushinteger(l, DrumMachine.max_steps);
    c.lua_setfield(l, -2, "drum_steps");
    c.lua_pushinteger(l, ws_root.Fx.max_units);
    c.lua_setfield(l, -2, "fx_units");
    c.lua_setfield(l, -2, "limits");
    return 1;
}

fn pushCurrentTrack(l: *c.lua_State, app: *tui_app.App) void {
    if (app.apiCurrentTrack()) |idx|
        c.lua_pushinteger(l, @intCast(idx + 1))
    else
        c.lua_pushnil(l);
}

fn apiGetMode(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    _ = c.lua_pushstring(l, @tagName(requireApp(l).modal.mode));
    return 1;
}

fn apiGetCurrentView(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    _ = c.lua_pushstring(l, @tagName(requireApp(l).view));
    return 1;
}

fn apiGetCurrentTrack(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    pushCurrentTrack(l, requireApp(l));
    return 1;
}

fn apiGetContext(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const rt = runtime(l);
    const app = requireApp(l);
    c.lua_createtable(l, 0, 4);
    _ = c.lua_pushstring(l, @tagName(rt.frontend));
    c.lua_setfield(l, -2, "frontend");
    _ = c.lua_pushstring(l, @tagName(app.view));
    c.lua_setfield(l, -2, "view");
    _ = c.lua_pushstring(l, @tagName(app.modal.mode));
    c.lua_setfield(l, -2, "mode");
    pushCurrentTrack(l, app);
    c.lua_setfield(l, -2, "track");
    return 1;
}

fn checkHighlight(l: *c.lua_State, arg: c_int) theme_identity.Highlight {
    const name = std.mem.span(c.luaL_checklstring(l, arg, null));
    return std.meta.stringToEnum(theme_identity.Highlight, name) orelse {
        _ = c.luaL_error(l, "unknown highlight group");
        unreachable;
    };
}

fn parseHexColor(l: *c.lua_State, arg: c_int) u24 {
    var len: usize = 0;
    const raw = c.luaL_checklstring(l, arg, &len);
    const text = raw[0..len];
    if (text.len != 7 or text[0] != '#') {
        _ = c.luaL_error(l, "highlight fg must be #rrggbb");
        unreachable;
    }
    return std.fmt.parseInt(u24, text[1..], 16) catch {
        _ = c.luaL_error(l, "highlight fg must be #rrggbb");
        unreachable;
    };
}

/// Sparse semantic color override, shaped after nvim_set_hl. An empty spec
/// clears the override and reveals the selected built-in theme underneath.
fn apiSetHl(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const hl = checkHighlight(l, 1);
    c.luaL_checktype(l, 2, c.LUA_TTABLE);
    c.lua_pushnil(l);
    while (c.lua_next(l, 2) != 0) {
        if (c.lua_type(l, -2) != c.LUA_TSTRING or !std.mem.eql(u8, std.mem.span(c.lua_tolstring(l, -2, null)), "fg"))
            return c.luaL_error(l, "highlight spec only supports fg");
        c.lua_settop(l, -2);
    }
    const rt = runtime(l);
    switch (c.lua_getfield(l, 2, "fg")) {
        c.LUA_TNIL => rt.highlight_overrides.set(hl, null),
        c.LUA_TSTRING => rt.highlight_overrides.set(hl, parseHexColor(l, -1)),
        else => return c.luaL_error(l, "highlight fg must be #rrggbb"),
    }
    c.lua_settop(l, -2);
    if (rt.app) |app| app.pending_colorscheme = true;
    return 0;
}

fn apiGetHl(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const color = runtime(l).highlight_overrides.get(checkHighlight(l, 1));
    c.lua_createtable(l, 0, 1);
    if (color) |hex| {
        var buf: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "#{x:0>6}", .{hex}) catch unreachable;
        _ = c.lua_pushlstring(l, text.ptr, text.len);
        c.lua_setfield(l, -2, "fg");
    }
    return 1;
}

fn apiPlay(state: ?*c.lua_State) callconv(.c) c_int {
    requireApp(state.?).apiPlay();
    return 0;
}

fn apiTransportGet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const info = requireApp(l).apiTransportInfo();
    c.lua_createtable(l, 0, 10);
    c.lua_pushboolean(l, @intFromBool(info.playing));
    c.lua_setfield(l, -2, "playing");
    c.lua_pushnumber(l, info.tempo);
    c.lua_setfield(l, -2, "tempo");
    c.lua_pushnumber(l, info.position_beats);
    c.lua_setfield(l, -2, "position_beats");
    c.lua_pushnumber(l, info.position_seconds);
    c.lua_setfield(l, -2, "position_seconds");
    c.lua_pushnumber(l, @floatFromInt(info.position_frames));
    c.lua_setfield(l, -2, "position_frames");
    c.lua_pushinteger(l, info.sample_rate);
    c.lua_setfield(l, -2, "sample_rate");
    c.lua_pushinteger(l, info.beats_per_bar);
    c.lua_setfield(l, -2, "beats_per_bar");
    c.lua_pushboolean(l, @intFromBool(info.song_mode));
    c.lua_setfield(l, -2, "song_mode");
    c.lua_pushboolean(l, @intFromBool(info.metronome));
    c.lua_setfield(l, -2, "metronome");
    c.lua_createtable(l, 0, 3);
    c.lua_pushboolean(l, @intFromBool(info.loop_enabled));
    c.lua_setfield(l, -2, "enabled");
    if (info.loop_end_bar > info.loop_start_bar) {
        c.lua_pushinteger(l, @intCast(info.loop_start_bar + 1));
        c.lua_setfield(l, -2, "start_bar");
        c.lua_pushinteger(l, @intCast(info.loop_end_bar));
        c.lua_setfield(l, -2, "end_bar");
    }
    c.lua_setfield(l, -2, "loop");
    return 1;
}

const LoopUpdate = struct { enabled: bool, start_bar: u32, end_bar: u32 };

const TransportUpdate = struct {
    playing: ?bool = null,
    tempo: ?f64 = null,
    position_beats: ?f64 = null,
    song_mode: ?bool = null,
    metronome: ?bool = null,
    loop: ?LoopUpdate = null,
};

fn optionalBoolField(l: *c.lua_State, table: c_int, name: [*:0]const u8) ?bool {
    return switch (c.lua_getfield(l, table, name)) {
        c.LUA_TNIL => null,
        c.LUA_TBOOLEAN => c.lua_toboolean(l, -1) != 0,
        else => {
            _ = c.luaL_error(l, "%s must be a boolean", name);
            unreachable;
        },
    };
}

fn apiTransportSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    c.luaL_checktype(l, 1, c.LUA_TTABLE);
    c.lua_pushnil(l);
    while (c.lua_next(l, 1) != 0) {
        if (c.lua_type(l, -2) != c.LUA_TSTRING) return c.luaL_error(l, "transport_set keys must be strings");
        const key = std.mem.span(c.lua_tolstring(l, -2, null));
        if (!std.mem.eql(u8, key, "playing") and !std.mem.eql(u8, key, "tempo") and
            !std.mem.eql(u8, key, "position_beats") and !std.mem.eql(u8, key, "song_mode") and
            !std.mem.eql(u8, key, "metronome") and !std.mem.eql(u8, key, "loop"))
            return c.luaL_error(l, "unknown transport field");
        c.lua_settop(l, -2);
    }

    var update: TransportUpdate = .{};
    update.playing = optionalBoolField(l, 1, "playing");
    c.lua_settop(l, -2);
    update.song_mode = optionalBoolField(l, 1, "song_mode");
    c.lua_settop(l, -2);
    update.metronome = optionalBoolField(l, 1, "metronome");
    c.lua_settop(l, -2);
    switch (c.lua_getfield(l, 1, "tempo")) {
        c.LUA_TNIL => {},
        c.LUA_TNUMBER => {
            const value = c.lua_tonumberx(l, -1, null);
            if (!std.math.isFinite(value) or value < 20 or value > 400) return c.luaL_error(l, "tempo must be between 20 and 400");
            update.tempo = value;
        },
        else => return c.luaL_error(l, "tempo must be a number"),
    }
    c.lua_settop(l, -2);
    switch (c.lua_getfield(l, 1, "position_beats")) {
        c.LUA_TNIL => {},
        c.LUA_TNUMBER => {
            const value = c.lua_tonumberx(l, -1, null);
            if (!std.math.isFinite(value) or value < 0) return c.luaL_error(l, "position_beats must be a non-negative number");
            update.position_beats = value;
        },
        else => return c.luaL_error(l, "position_beats must be a number"),
    }
    c.lua_settop(l, -2);
    switch (c.lua_getfield(l, 1, "loop")) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => {
            const loop_idx = c.lua_gettop(l);
            c.lua_pushnil(l);
            while (c.lua_next(l, loop_idx) != 0) {
                if (c.lua_type(l, -2) != c.LUA_TSTRING) return c.luaL_error(l, "loop keys must be strings");
                const key = std.mem.span(c.lua_tolstring(l, -2, null));
                if (!std.mem.eql(u8, key, "enabled") and !std.mem.eql(u8, key, "start_bar") and !std.mem.eql(u8, key, "end_bar"))
                    return c.luaL_error(l, "unknown loop field");
                c.lua_settop(l, -2);
            }
            var loop: LoopUpdate = .{
                .enabled = app.session.project.loop_enabled,
                .start_bar = app.session.project.loop_start_bar,
                .end_bar = app.session.project.loop_end_bar,
            };
            var region_changed = false;
            if (optionalBoolField(l, loop_idx, "enabled")) |value| loop.enabled = value;
            c.lua_settop(l, -2);
            switch (c.lua_getfield(l, loop_idx, "start_bar")) {
                c.LUA_TNIL => {},
                c.LUA_TNUMBER => {
                    const value = c.luaL_checkinteger(l, -1);
                    if (value < 1 or value > std.math.maxInt(u32)) return c.luaL_error(l, "loop start_bar is out of range");
                    loop.start_bar = @intCast(value - 1);
                    region_changed = true;
                },
                else => return c.luaL_error(l, "loop start_bar must be an integer"),
            }
            c.lua_settop(l, -2);
            switch (c.lua_getfield(l, loop_idx, "end_bar")) {
                c.LUA_TNIL => {},
                c.LUA_TNUMBER => {
                    const value = c.luaL_checkinteger(l, -1);
                    if (value < 1 or value > std.math.maxInt(u32)) return c.luaL_error(l, "loop end_bar is out of range");
                    loop.end_bar = @intCast(value);
                    region_changed = true;
                },
                else => return c.luaL_error(l, "loop end_bar must be an integer"),
            }
            c.lua_settop(l, -2);
            if ((loop.enabled or region_changed) and loop.end_bar <= loop.start_bar) return c.luaL_error(l, "loop end_bar must not precede start_bar");
            update.loop = loop;
        },
        else => return c.luaL_error(l, "loop must be a table"),
    }
    c.lua_settop(l, -2);

    if (update.position_beats) |beats| {
        const tempo = update.tempo orelse app.session.project.tempo_bpm;
        const frames = beats * @as(f64, @floatFromInt(app.session.project.sample_rate)) * 60.0 / tempo;
        if (frames > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return c.luaL_error(l, "position_beats is too large");
    }
    if (update.tempo) |value| _ = app.apiSetTempo(value);
    if (update.position_beats) |value| if (!app.apiSeekBeats(value)) return c.luaL_error(l, "position_beats is too large");
    if (update.song_mode) |value| app.apiSetSongMode(value);
    if (update.metronome) |value| app.apiSetMetronome(value);
    if (update.loop) |value| app.apiSetLoop(value.enabled, value.start_bar, value.end_bar);
    if (update.playing) |value| if (value) app.apiPlay() else app.apiStop();
    return 0;
}

fn apiStop(state: ?*c.lua_State) callconv(.c) c_int {
    requireApp(state.?).apiStop();
    return 0;
}

fn apiIsPlaying(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    c.lua_pushboolean(l, @intFromBool(requireApp(l).apiIsPlaying()));
    return 1;
}

fn apiGetTempo(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    c.lua_pushnumber(l, requireApp(l).apiGetTempo());
    return 1;
}

fn apiSetTempo(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const bpm = c.luaL_checknumber(l, 1);
    if (!app.apiSetTempo(bpm)) return c.luaL_error(l, "tempo must be between 20 and 400");
    return 0;
}

fn apiTrackCount(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    c.lua_pushinteger(l, @intCast(requireApp(l).session.project.tracks.items.len));
    return 1;
}

fn apiTrackGet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    const info = app.apiTrackInfo(idx);
    c.lua_createtable(l, 0, 8);
    _ = c.lua_pushlstring(l, info.name.ptr, info.name.len);
    c.lua_setfield(l, -2, "name");
    _ = c.lua_pushlstring(l, info.kind.ptr, info.kind.len);
    c.lua_setfield(l, -2, "kind");
    c.lua_pushnumber(l, info.gain_db);
    c.lua_setfield(l, -2, "gain_db");
    c.lua_pushnumber(l, info.pan);
    c.lua_setfield(l, -2, "pan");
    c.lua_pushboolean(l, @intFromBool(info.muted));
    c.lua_setfield(l, -2, "muted");
    c.lua_pushboolean(l, @intFromBool(info.soloed));
    c.lua_setfield(l, -2, "soloed");
    c.lua_pushboolean(l, @intFromBool(info.armed));
    c.lua_setfield(l, -2, "armed");
    if (info.group) |g| {
        c.lua_pushinteger(l, g);
        c.lua_setfield(l, -2, "group");
    }
    return 1;
}

/// `wstudio.api.track_set(i, { gain_db = -3, muted = true, ... })` - each
/// named field applies through the same path the equivalent UI gesture
/// takes; unknown fields are a loud error (docs/lua-api.md).
fn apiTrackSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    c.luaL_checktype(l, 2, c.LUA_TTABLE);
    const Update = struct {
        gain_db: ?f32 = null,
        pan: ?f32 = null,
        muted: ?bool = null,
        soloed: ?bool = null,
        armed: ?bool = null,
        name: ?[]const u8 = null,
    };
    var update: Update = .{};
    c.lua_pushnil(l);
    while (c.lua_next(l, 2) != 0) {
        if (c.lua_type(l, -2) != c.LUA_TSTRING) return c.luaL_error(l, "track_set keys must be strings");
        const key = std.mem.span(c.lua_tolstring(l, -2, null));
        if (std.mem.eql(u8, key, "gain_db")) {
            if (c.lua_isnumber(l, -1) == 0) return c.luaL_error(l, "gain_db must be a number");
            const value = c.lua_tonumberx(l, -1, null);
            if (!std.math.isFinite(value)) return c.luaL_error(l, "gain_db must be finite");
            update.gain_db = @floatCast(value);
        } else if (std.mem.eql(u8, key, "pan")) {
            if (c.lua_isnumber(l, -1) == 0) return c.luaL_error(l, "pan must be a number");
            const value = c.lua_tonumberx(l, -1, null);
            if (!std.math.isFinite(value)) return c.luaL_error(l, "pan must be finite");
            update.pan = @floatCast(value);
        } else if (std.mem.eql(u8, key, "muted")) {
            if (c.lua_type(l, -1) != c.LUA_TBOOLEAN) return c.luaL_error(l, "muted must be a boolean");
            update.muted = c.lua_toboolean(l, -1) != 0;
        } else if (std.mem.eql(u8, key, "soloed")) {
            if (c.lua_type(l, -1) != c.LUA_TBOOLEAN) return c.luaL_error(l, "soloed must be a boolean");
            update.soloed = c.lua_toboolean(l, -1) != 0;
        } else if (std.mem.eql(u8, key, "armed")) {
            if (c.lua_type(l, -1) != c.LUA_TBOOLEAN) return c.luaL_error(l, "armed must be a boolean");
            update.armed = c.lua_toboolean(l, -1) != 0;
        } else if (std.mem.eql(u8, key, "name")) {
            if (c.lua_type(l, -1) != c.LUA_TSTRING) return c.luaL_error(l, "name must be a string");
            var len: usize = 0;
            const s = c.lua_tolstring(l, -1, &len);
            if (len == 0) return c.luaL_error(l, "name cannot be empty");
            update.name = s[0..len];
        } else {
            return c.luaL_error(l, "unknown track field '%s'", c.lua_tolstring(l, -2, null));
        }
        c.lua_settop(l, -2); // pop the value, keep the key for lua_next
    }
    if (update.name) |value| if (!app.apiRenameTrack(idx, value)) return c.luaL_error(l, "rename failed");
    if (update.gain_db) |value| app.apiSetTrackGainDb(idx, value);
    if (update.pan) |value| app.apiSetTrackPan(idx, value);
    if (update.muted) |value| app.apiSetTrackMuted(idx, value);
    if (update.soloed) |value| app.apiSetTrackSoloed(idx, value);
    if (update.armed) |value| app.apiSetTrackArmed(idx, value);
    return 0;
}

fn apiTrackAdd(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    var kind: @import("wstudio").InstrumentKind = .poly_synth;
    var name: ?[]const u8 = null;
    if (c.lua_gettop(l) >= 1 and c.lua_type(l, 1) != c.LUA_TNIL) {
        c.luaL_checktype(l, 1, c.LUA_TTABLE);
        switch (c.lua_getfield(l, 1, "kind")) {
            c.LUA_TNIL => {},
            c.LUA_TSTRING => {
                const s = std.mem.span(c.lua_tolstring(l, -1, null));
                kind = tui_app.apiKindFromName(s) orelse
                    return c.luaL_error(l, "unknown kind (synth, drum, sampler, slicer, soundfont)");
            },
            else => return c.luaL_error(l, "kind must be a string"),
        }
        c.lua_settop(l, -2);
        // The name string stays on the Lua stack until the call below so
        // the slice can't be collected out from under it.
        switch (c.lua_getfield(l, 1, "name")) {
            c.LUA_TNIL => {},
            c.LUA_TSTRING => {
                var len: usize = 0;
                const s = c.lua_tolstring(l, -1, &len);
                name = s[0..len];
            },
            else => return c.luaL_error(l, "name must be a string"),
        }
    }
    const idx = app.apiTrackAdd(kind, name) orelse return c.luaL_error(l, "track limit reached");
    c.lua_pushinteger(l, @intCast(idx + 1));
    return 1;
}

fn apiTrackDel(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    if (!app.apiTrackDel(idx)) return c.luaL_error(l, "cannot delete the last track");
    return 0;
}

fn apiTrackDuplicate(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    const duplicate = app.apiTrackDuplicate(idx) orelse return c.luaL_error(l, "track limit reached");
    c.lua_pushinteger(l, @intCast(duplicate + 1));
    return 1;
}

fn apiTrackMove(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    const target = checkTrackIndex(l, 2, app);
    c.lua_pushinteger(l, @intCast(app.apiTrackMove(idx, target) + 1));
    return 1;
}

fn apiSetCurrentTrack(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    app.apiSelectTrack(checkTrackIndex(l, 1, app));
    return 0;
}

// ---------------------------------------------------------------------------
// Pattern content: notes and drum steps (docs/lua-api.md phase 8).

fn patternError(l: *c.lua_State, err: tui_app.App.ApiPatternError) c_int {
    return switch (err) {
        error.NoInstrument => c.luaL_error(l, "the track has no instrument"),
        error.NotMelodic => c.luaL_error(l, "not a melodic track - use steps_get/steps_set on a drum track"),
        error.NotDrum => c.luaL_error(l, "not a drum track - use notes_get/notes_set on a melodic track"),
        error.TooManyNotes => c.luaL_error(l, "too many notes (max %d)", @as(c_int, pattern_mod.max_notes)),
    };
}

/// One number field of a Lua table, with a range check. Returns `fallback`
/// when the key is absent - the whole notes/steps surface takes partial
/// entries and fills the rest with the same defaults a UI edit would.
fn tableNumber(l: *c.lua_State, table: c_int, key: [*:0]const u8, fallback: f64, min: f64, max: f64) f64 {
    defer c.lua_settop(l, -2);
    if (c.lua_getfield(l, table, key) == c.LUA_TNIL) return fallback;
    if (c.lua_isnumber(l, -1) == 0) {
        _ = c.luaL_error(l, "%s must be a number", key);
        unreachable;
    }
    const value = c.lua_tonumberx(l, -1, null);
    if (!std.math.isFinite(value) or value < min or value > max) {
        _ = c.luaL_error(l, "%s is out of range (%f to %f)", key, min, max);
        unreachable;
    }
    return value;
}

fn apiPatternGet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const info = app.apiPatternInfo(checkTrackIndex(l, 1, app));
    c.lua_createtable(l, 0, 4);
    _ = c.lua_pushlstring(l, info.kind.ptr, info.kind.len);
    c.lua_setfield(l, -2, "kind");
    c.lua_pushnumber(l, info.length_beats);
    c.lua_setfield(l, -2, "length_beats");
    if (info.steps_per_beat) |spb| {
        c.lua_pushinteger(l, spb);
        c.lua_setfield(l, -2, "steps_per_beat");
    }
    if (info.step_count) |n| {
        c.lua_pushinteger(l, n);
        c.lua_setfield(l, -2, "step_count");
    }
    return 1;
}

fn apiPatternSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    c.luaL_checktype(l, 2, c.LUA_TTABLE);
    var update: tui_app.App.ApiPatternUpdate = .{};
    c.lua_pushnil(l);
    while (c.lua_next(l, 2) != 0) {
        if (c.lua_type(l, -2) != c.LUA_TSTRING) return c.luaL_error(l, "pattern_set keys must be strings");
        const key = std.mem.span(c.lua_tolstring(l, -2, null));
        if (c.lua_isnumber(l, -1) == 0) return c.luaL_error(l, "%s must be a number", key.ptr);
        const value = c.lua_tonumberx(l, -1, null);
        if (!std.math.isFinite(value)) return c.luaL_error(l, "%s must be finite", key.ptr);
        if (std.mem.eql(u8, key, "length_beats")) {
            if (value < 0.25 or value > 4096.0) return c.luaL_error(l, "length_beats is out of range (0.25 to 4096)");
            update.length_beats = value;
        } else if (std.mem.eql(u8, key, "step_count")) {
            if (value < 1 or value > @as(f64, DrumMachine.max_steps)) return c.luaL_error(l, "step_count is out of range");
            update.step_count = @intFromFloat(value);
        } else if (std.mem.eql(u8, key, "steps_per_beat")) {
            if (value < 1 or value > 32) return c.luaL_error(l, "steps_per_beat is out of range (1 to 32)");
            update.steps_per_beat = @intFromFloat(value);
        } else {
            return c.luaL_error(l, "unknown pattern field '%s'", c.lua_tolstring(l, -2, null));
        }
        c.lua_settop(l, -2);
    }
    app.apiSetPattern(idx, update) catch |err| return patternError(l, err);
    return 0;
}

fn apiNotesGet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    const pp = app.apiPatternPlayer(idx) catch |err| return patternError(l, err);
    var buf: [pattern_mod.max_notes]pattern_mod.Note = undefined;
    const count = pp.copyNotes(&buf);
    c.lua_createtable(l, @intCast(count), 0);
    for (buf[0..count], 1..) |note, i| {
        c.lua_createtable(l, 0, 4);
        c.lua_pushinteger(l, note.pitch);
        c.lua_setfield(l, -2, "pitch");
        c.lua_pushnumber(l, note.start_beat);
        c.lua_setfield(l, -2, "start_beat");
        c.lua_pushnumber(l, note.duration_beat);
        c.lua_setfield(l, -2, "duration_beat");
        c.lua_pushnumber(l, note.velocity);
        c.lua_setfield(l, -2, "velocity");
        c.lua_rawseti(l, -2, @intCast(i));
    }
    return 1;
}

/// `notes_set(track, notes)` replaces the whole pattern in one undo entry -
/// scripts build the list in Lua and write it once, so there is no
/// per-note add/remove surface to keep consistent.
fn apiNotesSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    c.luaL_checktype(l, 2, c.LUA_TTABLE);
    const n = c.lua_rawlen(l, 2);
    if (n > pattern_mod.max_notes) return c.luaL_error(l, "too many notes (max %d)", @as(c_int, pattern_mod.max_notes));
    var buf: [pattern_mod.max_notes]pattern_mod.Note = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (c.lua_rawgeti(l, 2, @intCast(i + 1)) != c.LUA_TTABLE) return c.luaL_error(l, "note %d is not a table", @as(c_int, @intCast(i + 1)));
        buf[i] = .{
            .pitch = @intFromFloat(tableNumber(l, -1, "pitch", 60, 0, 127)),
            .start_beat = tableNumber(l, -1, "start_beat", 0, 0, 1_000_000),
            .duration_beat = tableNumber(l, -1, "duration_beat", 1, 0, 1_000_000),
            .velocity = @floatCast(tableNumber(l, -1, "velocity", pattern_mod.default_velocity, 0, 1)),
        };
        c.lua_settop(l, -2);
    }
    app.apiSetNotes(idx, buf[0..n]) catch |err| return patternError(l, err);
    return 0;
}

/// Every hit on a drum grid, as a flat list. Pads and steps are 1-based
/// like every other index the API hands out.
fn apiStepsGet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    const dm = app.apiDrumMachine(idx) catch |err| return patternError(l, err);
    c.lua_createtable(l, 0, 0);
    var count: c.lua_Integer = 0;
    for (0..DrumMachine.max_pads) |pad| {
        const p: u8 = @intCast(pad);
        for (0..dm.step_count) |step| {
            const s: u16 = @intCast(step);
            if (!dm.stepActive(p, s)) continue;
            count += 1;
            c.lua_createtable(l, 0, 8);
            c.lua_pushinteger(l, @intCast(pad + 1));
            c.lua_setfield(l, -2, "pad");
            c.lua_pushinteger(l, @intCast(step + 1));
            c.lua_setfield(l, -2, "step");
            c.lua_pushnumber(l, DrumMachine.velGain(dm.stepVel(p, s)));
            c.lua_setfield(l, -2, "velocity");
            c.lua_pushinteger(l, dm.stepProb(p, s));
            c.lua_setfield(l, -2, "prob");
            c.lua_pushinteger(l, dm.stepMicro(p, s));
            c.lua_setfield(l, -2, "micro");
            c.lua_pushinteger(l, dm.stepRetrig(p, s));
            c.lua_setfield(l, -2, "retrig");
            c.lua_pushinteger(l, dm.stepTune(p, s));
            c.lua_setfield(l, -2, "tune");
            const cond = @tagName(dm.stepCond(p, s));
            _ = c.lua_pushlstring(l, cond.ptr, cond.len);
            c.lua_setfield(l, -2, "cond");
            c.lua_rawseti(l, -2, count);
        }
    }
    return 1;
}

/// The trig condition names, derived from the enum so the valid list in the
/// error message can never drift from what `stringToEnum` accepts.
const cond_names: [:0]const u8 = blk: {
    var out: [:0]const u8 = "";
    for (@typeInfo(DrumMachine.Cond).@"enum".fields, 0..) |f, i| {
        out = out ++ (if (i == 0) "" else ", ") ++ f.name;
    }
    break :blk out;
};

fn checkCond(l: *c.lua_State, table: c_int) DrumMachine.Cond {
    defer c.lua_settop(l, -2);
    if (c.lua_getfield(l, table, "cond") == c.LUA_TNIL) return .always;
    if (c.lua_type(l, -1) != c.LUA_TSTRING) {
        _ = c.luaL_error(l, "cond must be a string");
        unreachable;
    }
    const name = std.mem.span(c.lua_tolstring(l, -1, null));
    return std.meta.stringToEnum(DrumMachine.Cond, name) orelse {
        _ = c.luaL_error(l, "unknown cond (%s)", cond_names.ptr);
        unreachable;
    };
}

/// `steps_set(track, steps)` replaces the whole grid. Two passes: the first
/// validates every entry so a bad one at the end can't leave a half-written
/// pattern behind, matching what track_set and transport_set promise.
fn apiStepsSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    c.luaL_checktype(l, 2, c.LUA_TTABLE);
    var dm = app.apiDrumMachine(idx) catch |err| return patternError(l, err);
    const step_count = dm.step_count;
    const n = c.lua_rawlen(l, 2);

    for (0..2) |pass| {
        if (pass == 1) {
            dm = app.apiDrumEdit(idx) catch |err| return patternError(l, err);
            for (0..DrumMachine.max_pads) |pad| dm.clearPad(@intCast(pad));
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (c.lua_rawgeti(l, 2, @intCast(i + 1)) != c.LUA_TTABLE) return c.luaL_error(l, "step %d is not a table", @as(c_int, @intCast(i + 1)));
            const pad: u8 = @intFromFloat(tableNumber(l, -1, "pad", 1, 1, DrumMachine.max_pads) - 1);
            const step: u16 = @intFromFloat(tableNumber(l, -1, "step", 1, 1, @floatFromInt(step_count)) - 1);
            const velocity = tableNumber(l, -1, "velocity", 1.0, 0, 1);
            const prob = tableNumber(l, -1, "prob", 100, 0, 100);
            const micro = tableNumber(l, -1, "micro", 0, -50, 50);
            const retrig = tableNumber(l, -1, "retrig", 0, 0, 8);
            const tune = tableNumber(l, -1, "tune", 0, -24, 24);
            const cond = checkCond(l, -1);
            if (pass == 1) {
                if (!dm.stepActive(pad, step)) dm.toggleStep(pad, step);
                dm.setStepVel(pad, step, @intFromFloat(@round(velocity * 127.0)));
                dm.setStepProb(pad, step, @intFromFloat(prob));
                dm.setStepMicro(pad, step, @intFromFloat(micro));
                dm.setStepRetrig(pad, step, @intFromFloat(retrig));
                dm.setStepTune(pad, step, @intFromFloat(tune));
                dm.setStepCond(pad, step, cond);
            }
            c.lua_settop(l, -2);
        }
    }
    app.apiPatternChanged();
    return 0;
}

// ---------------------------------------------------------------------------
// FX chains and parameters (docs/lua-api.md phase 9).

fn fxError(l: *c.lua_State, err: tui_app.App.ApiFxError) c_int {
    return switch (err) {
        error.NoChain => c.luaL_error(l, "no such FX chain"),
        error.SlotOutOfRange => c.luaL_error(l, "FX slot out of range"),
        error.ChainFull => c.luaL_error(l, "chain full (max %d units)", @as(c_int, ws_root.Fx.max_units)),
        error.ClapNeedsPath => c.luaL_error(l, "CLAP plugins load from the plugin picker, not by kind name"),
        error.OutOfMemory => c.luaL_error(l, "out of memory"),
    };
}

const fx_kind_names: [:0]const u8 = blk: {
    var out: [:0]const u8 = "";
    for (@typeInfo(ws_root.FxKind).@"enum".fields, 0..) |f, i| {
        out = out ++ (if (i == 0) "" else ", ") ++ f.name;
    }
    break :blk out;
};

/// A chain target: a track index (1-based, 0 = cursor track) for the common
/// case, or `{ track = i }` / `{ master = true }` / `{ group = i }` for the
/// buses. Resolved to the index-explicit form undo/redo already uses.
fn checkFxTarget(l: *c.lua_State, arg: c_int, app: *tui_app.App) undo_mod.FxTarget {
    if (c.lua_type(l, arg) != c.LUA_TTABLE) return .{ .track = @intCast(checkTrackIndex(l, arg, app)) };
    var out: ?undo_mod.FxTarget = null;
    c.lua_pushnil(l);
    while (c.lua_next(l, arg) != 0) {
        if (c.lua_type(l, -2) != c.LUA_TSTRING) {
            _ = c.luaL_error(l, "target keys must be strings");
            unreachable;
        }
        const key = std.mem.span(c.lua_tolstring(l, -2, null));
        if (out != null) {
            _ = c.luaL_error(l, "name exactly one of track, master, group");
            unreachable;
        }
        if (std.mem.eql(u8, key, "master")) {
            if (c.lua_toboolean(l, -1) != 0) out = .master;
        } else if (std.mem.eql(u8, key, "track")) {
            const n = c.luaL_checkinteger(l, -1);
            if (n < 1 or n > app.session.project.tracks.items.len) {
                _ = c.luaL_error(l, "track index out of range");
                unreachable;
            }
            out = .{ .track = @intCast(n - 1) };
        } else if (std.mem.eql(u8, key, "group")) {
            const n = c.luaL_checkinteger(l, -1);
            if (n < 1 or n > ws_root.engine.max_groups) {
                _ = c.luaL_error(l, "group index out of range (1-%d)", @as(c_int, ws_root.engine.max_groups));
                unreachable;
            }
            out = .{ .group = @intCast(n - 1) };
        } else {
            _ = c.luaL_error(l, "unknown target field '%s'", c.lua_tolstring(l, -2, null));
            unreachable;
        }
        c.lua_settop(l, -2);
    }
    return out orelse {
        _ = c.luaL_error(l, "target needs one of track, master, group");
        unreachable;
    };
}

/// 1-based Lua slot -> 0-based chain index. Bounds are the App's job, so
/// that "which chain" and "which slot" report one consistent error.
fn checkFxSlot(l: *c.lua_State, arg: c_int) usize {
    const n = c.luaL_checkinteger(l, arg);
    if (n < 1) {
        _ = c.luaL_error(l, "FX slot out of range");
        unreachable;
    }
    return @intCast(n - 1);
}

fn apiFxList(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const target = checkFxTarget(l, 1, app);
    const fx = app.apiFxChain(target) catch |err| return fxError(l, err);
    c.lua_createtable(l, @intCast(fx.units.items.len), 0);
    for (fx.units.items, 1..) |unit, i| {
        c.lua_createtable(l, 0, 4);
        const kind = @tagName(unit.kind());
        _ = c.lua_pushlstring(l, kind.ptr, kind.len);
        c.lua_setfield(l, -2, "kind");
        c.lua_pushboolean(l, @intFromBool(unit.bypassed));
        c.lua_setfield(l, -2, "bypassed");
        c.lua_pushinteger(l, unit.instance_id);
        c.lua_setfield(l, -2, "instance_id");
        c.lua_pushinteger(l, @intCast(spectrum_ed.visibleParamCount(app, unit.kind(), &unit.payload)));
        c.lua_setfield(l, -2, "param_count");
        c.lua_rawseti(l, -2, @intCast(i));
    }
    return 1;
}

fn apiFxAdd(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const target = checkFxTarget(l, 1, app);
    const name = std.mem.span(c.luaL_checklstring(l, 2, null));
    const kind = std.meta.stringToEnum(ws_root.FxKind, name) orelse
        return c.luaL_error(l, "unknown FX kind (%s)", fx_kind_names.ptr);
    var pos: usize = std.math.maxInt(usize); // clamped to the chain end
    if (c.lua_gettop(l) >= 3 and c.lua_type(l, 3) != c.LUA_TNIL) {
        c.luaL_checktype(l, 3, c.LUA_TTABLE);
        switch (c.lua_getfield(l, 3, "pos")) {
            c.LUA_TNIL => {},
            c.LUA_TNUMBER => {
                const n = c.lua_tointegerx(l, -1, null);
                if (n < 1) return c.luaL_error(l, "pos must be 1 or more");
                pos = @intCast(n - 1);
            },
            else => return c.luaL_error(l, "pos must be a number"),
        }
        c.lua_settop(l, -2);
    }
    const at = app.apiFxAdd(target, kind, pos) catch |err| return fxError(l, err);
    c.lua_pushinteger(l, @intCast(at + 1));
    return 1;
}

fn apiFxDel(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const target = checkFxTarget(l, 1, app);
    app.apiFxDel(target, checkFxSlot(l, 2)) catch |err| return fxError(l, err);
    return 0;
}

fn apiFxMove(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const target = checkFxTarget(l, 1, app);
    const slot = checkFxSlot(l, 2);
    const to = checkFxSlot(l, 3);
    const at = app.apiFxMove(target, slot, to) catch |err| return fxError(l, err);
    c.lua_pushinteger(l, @intCast(at + 1));
    return 1;
}

fn apiFxSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const target = checkFxTarget(l, 1, app);
    const slot = checkFxSlot(l, 2);
    c.luaL_checktype(l, 3, c.LUA_TTABLE);
    var bypassed: ?bool = null;
    c.lua_pushnil(l);
    while (c.lua_next(l, 3) != 0) {
        if (c.lua_type(l, -2) != c.LUA_TSTRING) return c.luaL_error(l, "fx_set keys must be strings");
        const key = std.mem.span(c.lua_tolstring(l, -2, null));
        if (!std.mem.eql(u8, key, "bypassed")) return c.luaL_error(l, "unknown FX field '%s'", c.lua_tolstring(l, -2, null));
        if (c.lua_type(l, -1) != c.LUA_TBOOLEAN) return c.luaL_error(l, "bypassed must be a boolean");
        bypassed = c.lua_toboolean(l, -1) != 0;
        c.lua_settop(l, -2);
    }
    if (bypassed) |on| app.apiFxBypass(target, slot, on) catch |err| return fxError(l, err);
    return 0;
}

/// Every param of one unit, in the order the editor lays them out. Names
/// repeat on `eq` and `mb_comp` (one set per band) and CLAP reports its own,
/// so `fx_param_set` takes an index too - see docs/lua-api.md.
fn apiFxParams(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const target = checkFxTarget(l, 1, app);
    const slot = checkFxSlot(l, 2);
    const fx = app.apiFxChain(target) catch |err| return fxError(l, err);
    if (slot >= fx.units.items.len) return c.luaL_error(l, "FX slot out of range");
    const unit = fx.units.items[slot];
    const count = spectrum_ed.visibleParamCount(app, unit.kind(), &unit.payload);
    c.lua_createtable(l, @intCast(count), 0);
    var name_buf: [128]u8 = undefined;
    for (0..count) |i| {
        const range = spectrum_ed.paramRange(app, &unit.payload, i);
        c.lua_createtable(l, 0, 5);
        const name = spectrum_ed.formatParamName(&name_buf, &unit.payload, i);
        _ = c.lua_pushlstring(l, name.ptr, name.len);
        c.lua_setfield(l, -2, "name");
        c.lua_pushnumber(l, spectrum_ed.getParam(&unit.payload, i));
        c.lua_setfield(l, -2, "value");
        c.lua_pushnumber(l, range[0]);
        c.lua_setfield(l, -2, "min");
        c.lua_pushnumber(l, range[1]);
        c.lua_setfield(l, -2, "max");
        c.lua_pushboolean(l, @intFromBool(spectrum_ed.isListParam(unit.kind(), i)));
        c.lua_setfield(l, -2, "list");
        c.lua_rawseti(l, -2, @intCast(i + 1));
    }
    return 1;
}

fn apiFxParamSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const target = checkFxTarget(l, 1, app);
    const slot = checkFxSlot(l, 2);
    const fx = app.apiFxChain(target) catch |err| return fxError(l, err);
    if (slot >= fx.units.items.len) return c.luaL_error(l, "FX slot out of range");
    const unit = fx.units.items[slot];
    const count = spectrum_ed.visibleParamCount(app, unit.kind(), &unit.payload);

    var param: usize = undefined;
    if (c.lua_type(l, 3) == c.LUA_TSTRING) {
        const wanted = std.mem.span(c.lua_tolstring(l, 3, null));
        var name_buf: [128]u8 = undefined;
        param = for (0..count) |i| {
            if (std.mem.eql(u8, spectrum_ed.formatParamName(&name_buf, &unit.payload, i), wanted)) break i;
        } else return c.luaL_error(l, "unknown param '%s'", c.lua_tolstring(l, 3, null));
    } else {
        param = checkFxSlot(l, 3);
    }
    const value = c.luaL_checknumber(l, 4);
    if (!std.math.isFinite(value)) return c.luaL_error(l, "value must be finite");
    app.apiFxParamSet(target, slot, param, @floatCast(value)) catch |err| return fxError(l, err);
    return 0;
}

// ---------------------------------------------------------------------------
// Arrangement clips and sections (docs/lua-api.md phase 10).

fn clipError(l: *c.lua_State, err: tui_app.App.ApiClipError) c_int {
    return switch (err) {
        error.NoLane => c.luaL_error(l, "the track has no arrangement lane"),
        error.NoClip => c.luaL_error(l, "no clip at that bar"),
        error.NothingToStamp => c.luaL_error(l, "the track has no pattern to stamp"),
        error.OutOfMemory => c.luaL_error(l, "out of memory"),
    };
}

/// Bars are the 1-based labels the arrangement view draws, like loop bars.
fn checkBar(l: *c.lua_State, arg: c_int) u32 {
    const n = c.luaL_checkinteger(l, arg);
    if (n < 1 or n > std.math.maxInt(u32)) {
        _ = c.luaL_error(l, "bar must be 1 or more");
        unreachable;
    }
    return @intCast(n - 1);
}

fn apiClipList(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    const lane = app.apiLane(idx) catch |err| return clipError(l, err);
    const bar_ticks = ws_root.time_grid.barTicks(app.session.project.beats_per_bar);
    c.lua_createtable(l, @intCast(lane.clips.items.len), 0);
    for (lane.clips.items, 1..) |clip, i| {
        c.lua_createtable(l, 0, 5);
        c.lua_pushinteger(l, clip.start_tick / bar_ticks + 1);
        c.lua_setfield(l, -2, "start_bar");
        c.lua_pushinteger(l, @max(clip.length_ticks / bar_ticks, 1));
        c.lua_setfield(l, -2, "length_bars");
        c.lua_pushinteger(l, clip.start_tick);
        c.lua_setfield(l, -2, "start_tick");
        c.lua_pushinteger(l, clip.length_ticks);
        c.lua_setfield(l, -2, "length_ticks");
        const kind = @tagName(std.meta.activeTag(clip.content));
        _ = c.lua_pushlstring(l, kind.ptr, kind.len);
        c.lua_setfield(l, -2, "kind");
        c.lua_rawseti(l, -2, @intCast(i));
    }
    return 1;
}

fn apiClipAdd(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    app.apiClipAdd(idx, checkBar(l, 2)) catch |err| return clipError(l, err);
    return 0;
}

fn apiClipDel(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    app.apiClipDel(idx, checkBar(l, 2)) catch |err| return clipError(l, err);
    return 0;
}

fn apiClipClear(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    app.apiClipClear(idx) catch |err| return clipError(l, err);
    return 0;
}

/// Sections sit on the arrangement's own tick grid, not on bar boundaries
/// (`:section` places one wherever the grid cursor is), so they are
/// addressed in beats - the same zero-based unit `transport_get` reports.
fn checkSectionTick(l: *c.lua_State, arg: c_int) u32 {
    const beats = c.luaL_checknumber(l, arg);
    const ticks = beats * @as(f64, @floatFromInt(ws_root.time_grid.ticks_per_beat));
    if (!std.math.isFinite(beats) or beats < 0 or ticks > @as(f64, std.math.maxInt(u32))) {
        _ = c.luaL_error(l, "beat is out of range");
        unreachable;
    }
    return @intFromFloat(@round(ticks));
}

fn apiSectionList(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const sections = app.session.project.sections.items;
    c.lua_createtable(l, @intCast(sections.len), 0);
    for (sections, 1..) |section, i| {
        c.lua_createtable(l, 0, 3);
        _ = c.lua_pushlstring(l, section.name.ptr, section.name.len);
        c.lua_setfield(l, -2, "name");
        c.lua_pushnumber(l, ws_root.time_grid.tickToBeat(section.tick));
        c.lua_setfield(l, -2, "beat");
        c.lua_pushinteger(l, section.tick);
        c.lua_setfield(l, -2, "tick");
        c.lua_rawseti(l, -2, @intCast(i));
    }
    return 1;
}

fn apiSectionSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const tick = checkSectionTick(l, 1);
    var len: usize = 0;
    const name = c.luaL_checklstring(l, 2, &len);
    if (len == 0) return c.luaL_error(l, "section name cannot be empty");
    app.apiSectionSet(tick, name[0..len]) catch return c.luaL_error(l, "out of memory");
    return 0;
}

fn apiSectionDel(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    if (!app.apiSectionDel(checkSectionTick(l, 1))) return c.luaL_error(l, "no section at that beat");
    return 0;
}

fn apiProjectGet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    c.lua_createtable(l, 0, 7);
    if (app.projectPath()) |path| {
        _ = c.lua_pushlstring(l, path.ptr, path.len);
        c.lua_setfield(l, -2, "path");
    }
    c.lua_pushboolean(l, @intFromBool(app.dirty));
    c.lua_setfield(l, -2, "dirty");
    c.lua_pushinteger(l, @intCast(app.session.project.tracks.items.len));
    c.lua_setfield(l, -2, "track_count");
    c.lua_pushinteger(l, app.session.project.sample_rate);
    c.lua_setfield(l, -2, "sample_rate");
    c.lua_pushinteger(l, app.session.project.beats_per_bar);
    c.lua_setfield(l, -2, "beats_per_bar");
    c.lua_pushnumber(l, app.session.project.tempo_bpm);
    c.lua_setfield(l, -2, "tempo");
    c.lua_pushboolean(l, @intFromBool(app.session.song_mode));
    c.lua_setfield(l, -2, "song_mode");
    return 1;
}

fn apiProjectSave(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    var requested: []const u8 = "";
    if (c.lua_gettop(l) >= 1 and c.lua_type(l, 1) != c.LUA_TNIL) {
        var len: usize = 0;
        const path = c.luaL_checklstring(l, 1, &len);
        if (len == 0) return c.luaL_error(l, "project path cannot be empty");
        requested = path[0..len];
    }
    const chosen = if (requested.len > 0) requested else app.projectPath() orelse app.defaultProjectPath();
    app.apiProjectSave(requested) catch |err| return c.luaL_error(l, "project_save failed: %s", @errorName(err).ptr);
    _ = c.lua_pushlstring(l, chosen.ptr, chosen.len);
    return 1;
}

fn forceOption(l: *c.lua_State, arg: c_int) bool {
    if (c.lua_gettop(l) < arg or c.lua_type(l, arg) == c.LUA_TNIL) return false;
    c.luaL_checktype(l, arg, c.LUA_TTABLE);
    c.lua_pushnil(l);
    while (c.lua_next(l, arg) != 0) {
        if (c.lua_type(l, -2) != c.LUA_TSTRING or !std.mem.eql(u8, std.mem.span(c.lua_tolstring(l, -2, null)), "force"))
            _ = c.luaL_error(l, "project opts only supports force");
        c.lua_settop(l, -2);
    }
    return switch (c.lua_getfield(l, arg, "force")) {
        c.LUA_TNIL => false,
        c.LUA_TBOOLEAN => c.lua_toboolean(l, -1) != 0,
        else => {
            _ = c.luaL_error(l, "force must be a boolean");
            unreachable;
        },
    };
}

fn apiProjectOpen(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    var len: usize = 0;
    const raw = c.luaL_checklstring(l, 1, &len);
    if (len == 0) return c.luaL_error(l, "project path cannot be empty");
    if (len > 1024) return c.luaL_error(l, "project path is too long");
    const force = forceOption(l, 2);
    if (!app.apiProjectOpen(raw[0..len], force)) return c.luaL_error(l, "unsaved changes; pass { force = true } to discard them");
    return 0;
}

fn apiProjectNew(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    if (!requireApp(l).apiProjectNew(forceOption(l, 1))) return c.luaL_error(l, "unsaved changes; pass { force = true } to discard them");
    return 0;
}

/// `wstudio.api.create_autocmd(event|{events}, { callback, once? })` ->
/// integer id for del_autocmd. Neovim's shape minus patterns and groups.
/// The registry ref is taken last so a validation longjmp can't leak it.
fn createAutocmd(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    var events = std.EnumSet(Event).initEmpty();
    switch (c.lua_type(l, 1)) {
        c.LUA_TSTRING => events.insert(eventFromString(l, 1)),
        c.LUA_TTABLE => {
            const n: c.lua_Integer = @intCast(c.lua_rawlen(l, 1));
            if (n == 0) return c.luaL_error(l, "events list is empty");
            var i: c.lua_Integer = 1;
            while (i <= n) : (i += 1) {
                _ = c.lua_rawgeti(l, 1, i);
                events.insert(eventFromString(l, -1));
                c.lua_settop(l, -2);
            }
        },
        else => return c.luaL_error(l, "events must be a string or a list of strings"),
    }
    c.luaL_checktype(l, 2, c.LUA_TTABLE);
    var once = false;
    switch (c.lua_getfield(l, 2, "once")) {
        c.LUA_TNIL => {},
        c.LUA_TBOOLEAN => once = c.lua_toboolean(l, -1) != 0,
        else => return c.luaL_error(l, "once must be a boolean"),
    }
    c.lua_settop(l, -2);
    const rt = runtime(l);
    if (rt.autocmds_len == max_autocmds) return c.luaL_error(l, "too many autocmds");
    if (c.lua_getfield(l, 2, "callback") != c.LUA_TFUNCTION) return c.luaL_error(l, "callback must be a function");
    const id = rt.next_autocmd_id;
    rt.next_autocmd_id += 1;
    rt.autocmds[rt.autocmds_len] = .{
        .id = id,
        .events = events,
        .ref = c.luaL_ref(l, c.LUA_REGISTRYINDEX),
        .once = once,
    };
    rt.autocmds_len += 1;
    c.lua_pushinteger(l, id);
    return 1;
}

fn eventFromString(l: *c.lua_State, idx: c_int) Event {
    if (c.lua_type(l, idx) == c.LUA_TSTRING) {
        const s = std.mem.span(c.lua_tolstring(l, idx, null));
        if (std.meta.stringToEnum(Event, s)) |e| return e;
    }
    _ = c.luaL_error(l, "unknown event");
    unreachable;
}

fn delAutocmd(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const id = c.luaL_checkinteger(l, 1);
    const rt = runtime(l);
    for (rt.autocmds[0..rt.autocmds_len], 0..) |*ac, i| {
        if (ac.id == id) {
            rt.removeAutocmd(i);
            return 0;
        }
    }
    return c.luaL_error(l, "no such autocmd");
}

test "missing user config is generated from the embedded template" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var user_buf: [256]u8 = undefined;
    const user_path = try std.fmt.bufPrint(&user_buf, ".zig-cache/tmp/{s}/user/wstudio/init.lua", .{&tmp.sub_path});
    var fallback_buf: [256]u8 = undefined;
    const fallback_path = try std.fmt.bufPrint(&fallback_buf, ".zig-cache/tmp/{s}/system/init.lua", .{&tmp.sub_path});

    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try testing.expect(try rt.loadOrGenerateUserConfig(testing.io, user_path, fallback_path));

    const generated = try std.Io.Dir.cwd().readFileAlloc(testing.io, user_path, testing.allocator, .limited(init_lua_template.len + 1));
    defer testing.allocator.free(generated);
    try testing.expectEqualStrings(init_lua_template, generated);
}

test "existing user config is loaded without being overwritten" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var user_buf: [256]u8 = undefined;
    const user_path = try std.fmt.bufPrint(&user_buf, ".zig-cache/tmp/{s}/user/wstudio/init.lua", .{&tmp.sub_path});
    var fallback_buf: [256]u8 = undefined;
    const fallback_path = try std.fmt.bufPrint(&fallback_buf, ".zig-cache/tmp/{s}/system/init.lua", .{&tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(testing.io, std.fs.path.dirname(user_path).?);
    const source = "wstudio.o.default_tempo = 133\n";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, user_path, .{});
        defer file.close(testing.io);
        var buffer: [64]u8 = undefined;
        var writer = file.writer(testing.io, &buffer);
        try writer.interface.writeAll(source);
        try writer.interface.flush();
    }

    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try testing.expect(try rt.loadOrGenerateUserConfig(testing.io, user_path, fallback_path));
    try testing.expectEqual(@as(f64, 133), rt.config.default_tempo);
    try testing.expect(!try generateUserConfig(testing.io, user_path));
    const preserved = try std.Io.Dir.cwd().readFileAlloc(testing.io, user_path, testing.allocator, .limited(64));
    defer testing.allocator.free(preserved);
    try testing.expectEqualStrings(source, preserved);
}

test "system config prevents user template generation" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var user_buf: [256]u8 = undefined;
    const user_path = try std.fmt.bufPrint(&user_buf, ".zig-cache/tmp/{s}/user/wstudio/init.lua", .{&tmp.sub_path});
    var fallback_buf: [256]u8 = undefined;
    const fallback_path = try std.fmt.bufPrint(&fallback_buf, ".zig-cache/tmp/{s}/system/init.lua", .{&tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(testing.io, std.fs.path.dirname(fallback_path).?);
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, fallback_path, .{});
        defer file.close(testing.io);
        var buffer: [64]u8 = undefined;
        var writer = file.writer(testing.io, &buffer);
        try writer.interface.writeAll("wstudio.o.default_tempo = 144\n");
        try writer.interface.flush();
    }

    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try testing.expect(try rt.loadOrGenerateUserConfig(testing.io, user_path, fallback_path));
    try testing.expectEqual(@as(f64, 144), rt.config.default_tempo);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, user_path, .{}));
}

test "Lua API sets and reads options" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.o.default_tempo = 132; wstudio.o.default_sample_rate = 44100; wstudio.o.default_beats_per_bar = 7; wstudio.o.frame_poll_ms = 45; wstudio.o.audio_block_frames = 512; wstudio.o.tap_timeout_ms = 1500; assert(wstudio.o.default_tempo == 132)");
    try std.testing.expectEqual(@as(f64, 132), rt.config.default_tempo);
    try std.testing.expectEqual(@as(u32, 44100), rt.config.default_sample_rate);
    try std.testing.expectEqual(@as(u8, 7), rt.config.default_beats_per_bar);
    try std.testing.expectEqual(@as(u16, 45), rt.config.frame_poll_ms);
    try std.testing.expectEqual(@as(u32, 512), rt.config.audio_block_frames);
    try std.testing.expectEqual(@as(u32, 1500), rt.config.tap_timeout_ms);
}

test "Lua API rejects invalid option values" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_tempo = 2"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.gui_font_size = 4"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.no_such_option = 1"));
}

test "Lua API handles bool and float GUI options" {
    var rt = try Runtime.init(.gui);
    defer rt.deinit();
    try rt.loadString("wstudio.o.gui_vsync = false; wstudio.o.gui_font_size = 18; assert(wstudio.o.gui_vsync == false); assert(wstudio.o.gui_font_size == 18)");
    try std.testing.expectEqual(false, rt.config.gui_vsync);
    try std.testing.expectEqual(@as(f32, 18), rt.config.gui_font_size);
}

test "Lua API handles enum options as strings" {
    var rt = try Runtime.init(.gui);
    defer rt.deinit();
    try rt.loadString("assert(wstudio.o.gui_theme == 'patina'); wstudio.o.gui_theme = 'graphite'; assert(wstudio.o.gui_theme == 'graphite')");
    try std.testing.expectEqual(GuiTheme.graphite, rt.config.gui_theme);
    try rt.loadString("wstudio.o.gui_theme = 'patina_light'; assert(wstudio.o.gui_theme == 'patina_light'); wstudio.o.gui_theme = 'umbra'");
    try std.testing.expectEqual(GuiTheme.umbra, rt.config.gui_theme);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.gui_theme = 'neon'"));
    try rt.loadString("local ok, err = pcall(function() wstudio.o.gui_theme = 'neon' end); assert(err:find('patina, patina_light, graphite, graphite_light, umbra') ~= nil)");
}

test "Lua API handles gui_panel_border as an enum string" {
    var rt = try Runtime.init(.gui);
    defer rt.deinit();
    try rt.loadString("assert(wstudio.o.gui_panel_border == 'square'); wstudio.o.gui_panel_border = 'rounded'; assert(wstudio.o.gui_panel_border == 'rounded')");
    try std.testing.expectEqual(PanelBorder.rounded, rt.config.gui_panel_border);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.gui_panel_border = 'circular'"));
}

test "Lua API round 2 options set and read" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.o.default_octave = 2; wstudio.o.autosave_interval_s = 0; wstudio.o.tui_mouse = false;" ++
        "wstudio.o.gui_window_width = 1920; wstudio.o.gui_window_height = 1080");
    try std.testing.expectEqual(@as(u8, 2), rt.config.default_octave);
    try std.testing.expectEqual(@as(u16, 0), rt.config.autosave_interval_s);
    try std.testing.expectEqual(false, rt.config.tui_mouse);
    try std.testing.expectEqual(@as(u16, 1920), rt.config.gui_window_width);
    try std.testing.expectEqual(@as(u16, 1080), rt.config.gui_window_height);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_octave = 9"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.gui_window_width = 100"));
}

test "Lua API has_nerdfonts defaults false and is settable" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try std.testing.expectEqual(false, rt.config.has_nerdfonts);
    try rt.loadString("wstudio.o.has_nerdfonts = true");
    try std.testing.expectEqual(true, rt.config.has_nerdfonts);
}

test "Lua API round 3 options set and read" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.o.default_velocity = 0.5; wstudio.o.note_preview_ms = 500;" ++
        "wstudio.o.cmd_history_lines = 200; wstudio.o.status_message_ms = 1500");
    try std.testing.expectEqual(@as(f32, 0.5), rt.config.default_velocity);
    try std.testing.expectEqual(@as(u16, 500), rt.config.note_preview_ms);
    try std.testing.expectEqual(@as(u16, 200), rt.config.cmd_history_lines);
    try std.testing.expectEqual(@as(u16, 1500), rt.config.status_message_ms);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_velocity = 1.5"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.note_preview_ms = 3"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.cmd_history_lines = 1000"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.status_message_ms = 100"));
}

test "Lua API round 4 editor options set and read" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.o.default_drum_grid = 'eighth';" ++
        "wstudio.o.default_piano_grid = 'thirty_second';" ++
        "wstudio.o.default_arrangement_grid = 'sixteenth';" ++
        "wstudio.o.piano_ghost_notes = true");
    try std.testing.expectEqual(@import("wstudio").time_grid.Division.eighth, rt.config.default_drum_grid);
    try std.testing.expectEqual(@import("wstudio").time_grid.Division.thirty_second, rt.config.default_piano_grid);
    try std.testing.expectEqual(@import("wstudio").time_grid.Division.sixteenth, rt.config.default_arrangement_grid);
    try std.testing.expect(rt.config.piano_ghost_notes);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_piano_grid = 'third'"));
}

test "Lua API round 5 workflow options set and read" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.o.default_project_path = '~/Music/untitled.wsj';" ++
        "wstudio.o.file_browser_show_hidden = true;" ++
        "wstudio.o.default_piano_triplet_grid = true;" ++
        "wstudio.o.default_piano_note_length_steps = 3");
    try std.testing.expectEqualStrings("~/Music/untitled.wsj", rt.config.default_project_path.slice());
    try std.testing.expect(rt.config.file_browser_show_hidden);
    try std.testing.expect(rt.config.default_piano_triplet_grid);
    try std.testing.expectEqual(@as(u8, 3), rt.config.default_piano_note_length_steps);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_project_path = ''"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_piano_note_length_steps = 0"));
}

test "Lua API round 6 options set and read" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString(
        \\wstudio.o.bounce_tail_seconds = 8.5
        \\wstudio.o.bounce_bit_depth = "pcm24"
        \\wstudio.o.default_bounce_path = "~/Music/mix.wav"
        \\wstudio.o.default_stems_dir = "~/Music/stems"
        \\wstudio.o.master_limiter_ceiling_db = -1.5
        \\wstudio.o.master_limiter_release_ms = 250
        \\wstudio.o.default_drum_steps = 64
        \\wstudio.o.default_slicer_steps = 32
        \\wstudio.o.default_pattern_length_beats = 8
        \\wstudio.o.default_swing = 62
        \\wstudio.o.completion_popup_rows = 4
        \\wstudio.o.waveform_low_hz = 120
        \\wstudio.o.waveform_high_hz = 6000
        \\wstudio.o.tui_piano_cell_width = 5
        \\wstudio.o.tui_drum_cell_width = 1
        \\wstudio.o.tui_arrangement_cell_width = 6
        \\wstudio.o.tui_spectrum_db_range = 96
        \\wstudio.o.gui_piano_row_height = 28
        \\assert(wstudio.o.bounce_bit_depth == "pcm24" and wstudio.o.default_swing == 62)
    );
    try std.testing.expectApproxEqAbs(@as(f32, 8.5), rt.config.bounce_tail_seconds, 1e-6);
    try std.testing.expectEqual(@import("wstudio").wav.BitDepth.pcm24, rt.config.bounce_bit_depth);
    try std.testing.expectEqualStrings("~/Music/mix.wav", rt.config.default_bounce_path.slice());
    try std.testing.expectEqualStrings("~/Music/stems", rt.config.default_stems_dir.slice());
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), rt.config.master_limiter_ceiling_db, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 250), rt.config.master_limiter_release_ms, 1e-6);
    try std.testing.expectEqual(@as(u16, 64), rt.config.default_drum_steps);
    try std.testing.expectEqual(@as(u8, 32), rt.config.default_slicer_steps);
    try std.testing.expectEqual(@as(f64, 8), rt.config.default_pattern_length_beats);
    try std.testing.expectApproxEqAbs(@as(f32, 62), rt.config.default_swing, 1e-6);
    try std.testing.expectEqual(@as(u8, 4), rt.config.completion_popup_rows);
    try std.testing.expectApproxEqAbs(@as(f32, 120), rt.config.waveform_low_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6000), rt.config.waveform_high_hz, 1e-6);
    try std.testing.expectEqual(@as(u8, 5), rt.config.tui_piano_cell_width);
    try std.testing.expectEqual(@as(u8, 1), rt.config.tui_drum_cell_width);
    try std.testing.expectEqual(@as(u8, 6), rt.config.tui_arrangement_cell_width);
    try std.testing.expectApproxEqAbs(@as(f32, 96), rt.config.tui_spectrum_db_range, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 28), rt.config.gui_piano_row_height, 1e-6);

    // Each range is enforced at its own edge, and the empty-path rule
    // covers the two new path options too.
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.bounce_tail_seconds = 31"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.bounce_bit_depth = 'pcm32'"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_bounce_path = ''"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_stems_dir = ''"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.master_limiter_ceiling_db = 1"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_swing = 49"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.completion_popup_rows = 0"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.tui_piano_cell_width = 8"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.gui_piano_row_height = 4"));
}

test "Lua API session default options set and read" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString(
        "wstudio.o.default_master_gain_db = -6.5;" ++
            "wstudio.o.default_piano_pitch = 73;" ++
            "wstudio.o.default_song_mode = true;" ++
            "assert(wstudio.o.default_master_gain_db == -6.5);" ++
            "assert(wstudio.o.default_piano_pitch == 73);" ++
            "assert(wstudio.o.default_song_mode == true)",
    );
    try std.testing.expectEqual(@as(f32, -6.5), rt.config.default_master_gain_db);
    try std.testing.expectEqual(@as(u7, 73), rt.config.default_piano_pitch);
    try std.testing.expect(rt.config.default_song_mode);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_master_gain_db = -41"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_piano_pitch = 128"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_song_mode = 1"));
}

test "path options read and write as strings, rejecting oversized paths" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("assert(wstudio.o.default_browse_dir == '')");
    try rt.loadString("wstudio.o.default_browse_dir = '~/Music/Samples'; assert(wstudio.o.default_browse_dir == '~/Music/Samples')");
    try std.testing.expectEqualStrings("~/Music/Samples", rt.config.default_browse_dir.slice());
    try rt.loadString("wstudio.o.clap_plugin_path = '/opt/clap'; assert(wstudio.o.clap_plugin_path == '/opt/clap')");
    try std.testing.expectEqualStrings("/opt/clap", rt.config.clap_plugin_path.slice());
    try rt.loadString("wstudio.o.vst3_plugin_path = '/opt/vst3'; assert(wstudio.o.vst3_plugin_path == '/opt/vst3')");
    try std.testing.expectEqualStrings("/opt/vst3", rt.config.vst3_plugin_path.slice());
    try rt.loadString("wstudio.o.audio_output_device = 'hw:2,0'; wstudio.o.audio_input_device = 'plughw:1,0'");
    try std.testing.expectEqualStrings("hw:2,0", rt.config.audio_output_device.slice());
    try std.testing.expectEqualStrings("plughw:1,0", rt.config.audio_input_device.slice());
    try rt.loadString("wstudio.o.midi_input_device = '24:0'");
    try std.testing.expectEqualStrings("24:0", rt.config.midi_input_device.slice());
    const prefix = "wstudio.o.default_browse_dir = '";
    var src_buf: [prefix.len + std.fs.max_path_bytes + 1 + 2:0]u8 = undefined;
    @memcpy(src_buf[0..prefix.len], prefix);
    @memset(src_buf[prefix.len .. prefix.len + std.fs.max_path_bytes + 1], 'a');
    src_buf[prefix.len + std.fs.max_path_bytes + 1] = '\'';
    src_buf[prefix.len + std.fs.max_path_bytes + 2] = 0;
    try std.testing.expectError(error.LuaError, rt.loadString(src_buf[0 .. prefix.len + std.fs.max_path_bytes + 2 :0]));
}

test "wstudio.frontend reports the active frontend" {
    var rt = try Runtime.init(.gui);
    defer rt.deinit();
    try rt.loadString("assert(wstudio.frontend == 'gui')");
}

test "audio_backend option accepts backend names and rejects unknowns" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("assert(wstudio.o.audio_backend == 'auto'); wstudio.o.audio_backend = 'jack'");
    try std.testing.expectEqual(@import("wstudio").audio_host.Choice.jack, rt.config.audio_backend);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.audio_backend = 'pulse'"));
}

test "preferred_frontend option and setFrontend correction" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("assert(wstudio.o.preferred_frontend == 'tui'); wstudio.o.preferred_frontend = 'gui'");
    try std.testing.expectEqual(Frontend.gui, rt.config.preferred_frontend);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.preferred_frontend = 'web'"));
    rt.setFrontend(rt.config.preferred_frontend);
    try std.testing.expectEqual(Frontend.gui, rt.frontend);
    try rt.loadString("assert(wstudio.frontend == 'gui')");
}

test "require path includes the user lua dir" {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (userConfigDir(&dir_buf) == null) return; // no platform config directory in env
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("assert(package.path:find('wstudio/lua/?.lua', 1, true) ~= nil)");
}

const TestHost = struct {
    log: [512]u8 = undefined,
    len: usize = 0,

    fn append(self: *TestHost, tag: []const u8, text: []const u8) void {
        for (tag) |b| {
            if (self.len == self.log.len) return;
            self.log[self.len] = b;
            self.len += 1;
        }
        for (text) |b| {
            if (self.len == self.log.len) return;
            self.log[self.len] = b;
            self.len += 1;
        }
        if (self.len == self.log.len) return;
        self.log[self.len] = '\n';
        self.len += 1;
    }

    fn notifyFn(ctx: *anyopaque, msg: []const u8) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.append("notify:", msg);
    }

    fn execFn(ctx: *anyopaque, line: []const u8) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.append("exec:", line);
    }

    fn host(self: *TestHost) Host {
        return .{ .ctx = self, .notify = notifyFn, .exec = execFn };
    }
};

test "wstudio.cmd queues until a host attaches, then runs live" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.cmd('bpm 140'); wstudio.api.exec('play')");
    var th: TestHost = .{};
    rt.attachHost(th.host());
    try std.testing.expectEqualStrings("exec:bpm 140\nexec:play\n", th.log[0..th.len]);
    // With the host attached, cmd dispatches immediately and the queue
    // stays empty (a second attach drains nothing).
    try rt.loadString("wstudio.cmd('stop')");
    try std.testing.expectEqualStrings("exec:bpm 140\nexec:play\nexec:stop\n", th.log[0..th.len]);
    rt.attachHost(th.host());
    try std.testing.expectEqualStrings("exec:bpm 140\nexec:play\nexec:stop\n", th.log[0..th.len]);
}

test "user commands register, run with opts.args, and delete" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.api.create_user_command('swing', function(o) hit = o.args end, { desc = '<amount>  set swing feel', scope = 'drum' })");
    try std.testing.expectEqual(@as(usize, 1), rt.userCommands().len);
    try std.testing.expectEqualStrings("swing", rt.userCommands()[0].name());
    try std.testing.expectEqualStrings("<amount>  set swing feel", rt.userCommands()[0].desc());
    try std.testing.expectEqual(cmd_mod.Scope.drum, rt.userCommands()[0].scope);
    rt.runUserCommand(0, "42");
    try rt.loadString("assert(hit == '42')");
    try rt.loadString("wstudio.api.del_user_command('swing')");
    try std.testing.expectEqual(@as(usize, 0), rt.userCommands().len);
}

test "re-registering a user command replaces its handler" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.api.create_user_command('x', function() hit = 'old' end)");
    try rt.loadString("wstudio.api.create_user_command('x', function() hit = 'new' end)");
    try std.testing.expectEqual(@as(usize, 1), rt.userCommands().len);
    rt.runUserCommand(0, "");
    try rt.loadString("assert(hit == 'new')");
}

test "user command registration rejects bad input" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.create_user_command('a b', function() end)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.create_user_command('', function() end)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.create_user_command('x', function() end, { scope = 'nope' })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.del_user_command('nope')"));
    try std.testing.expectEqual(@as(usize, 0), rt.userCommands().len);
}

test "user command handler errors report to the host" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.api.create_user_command('boom', function() error('kaboom') end)");
    var th: TestHost = .{};
    rt.attachHost(th.host());
    rt.runUserCommand(0, "");
    try std.testing.expect(std.mem.indexOf(u8, th.log[0..th.len], "notify:Lua:") != null);
    try std.testing.expect(std.mem.indexOf(u8, th.log[0..th.len], "kaboom") != null);
}

test "keymap.set parses notation and stores entries" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.keymap.set('n', 'gp', function() hit = true end, { desc = 'play', view = 'tracks' })");
    try rt.loadString("wstudio.keymap.set({'n','v'}, '<esc>x<c-r><space>', ':q')");
    try std.testing.expectEqual(@as(usize, 2), rt.userKeymaps().len);

    const first = &rt.userKeymaps()[0];
    try std.testing.expect(keysEqual(first.lhs(), &.{ .{ .char = 'g' }, .{ .char = 'p' } }));
    try std.testing.expectEqual(ModeMask{ .normal = true }, first.modes);
    try std.testing.expectEqual(tui_app.AppView.tracks, first.view.?);
    try std.testing.expectEqualStrings("play", first.desc());

    const second = &rt.userKeymaps()[1];
    try std.testing.expect(keysEqual(second.lhs(), &.{ .escape, .{ .char = 'x' }, .ctrl_r, .{ .char = ' ' } }));
    try std.testing.expectEqual(ModeMask{ .normal = true, .visual = true }, second.modes);
    try std.testing.expectEqualStrings("q", second.cmd());

    rt.runKeymap(0);
    try rt.loadString("assert(hit == true)");

    var lhs_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("<esc>x<c-r><space>", second.lhsText(&lhs_buf));
}

test "keymap.set replaces per (mode, lhs, view) and del removes" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.keymap.set('n', 'j', function() hit = 'old' end)");
    try rt.loadString("wstudio.keymap.set({'n','v'}, 'j', function() hit = 'new' end)");
    try std.testing.expectEqual(@as(usize, 1), rt.userKeymaps().len);
    rt.runKeymap(0);
    try rt.loadString("assert(hit == 'new')");

    try rt.loadString("wstudio.keymap.del('n', 'j')");
    try std.testing.expectEqual(@as(usize, 1), rt.userKeymaps().len);
    try std.testing.expectEqual(ModeMask{ .visual = true }, rt.userKeymaps()[0].modes);
    try rt.loadString("wstudio.keymap.del('v', 'j')");
    try std.testing.expectEqual(@as(usize, 0), rt.userKeymaps().len);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.keymap.del('n', 'j')"));
}

test "keymap.set rejects bad input" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.keymap.set('x', 'j', function() end)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.keymap.set('n', '', function() end)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.keymap.set('n', '<bogus>', function() end)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.keymap.set('n', 'abcde', function() end)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.keymap.set('n', 'j', 'q')"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.keymap.set('n', 'j', 5)"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.keymap.set('n', 'j', function() end, { view = 'nope' })"));
    try std.testing.expectEqual(@as(usize, 0), rt.userKeymaps().len);
}

test "keymap command rhs runs through the host" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.keymap.set('n', 'Q', ':q')");
    var th: TestHost = .{};
    rt.attachHost(th.host());
    rt.runKeymap(0);
    try std.testing.expectEqualStrings("exec:q\n", th.log[0..th.len]);
}

test "autocmds fire in registration order with payload fields" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("log = {};" ++
        "wstudio.api.create_autocmd('ProjectSavePost', { callback = function(ev) log[#log+1] = 'a:' .. ev.event .. ':' .. ev.path end });" ++
        "wstudio.api.create_autocmd({'ProjectSavePost','PlaybackStart'}, { callback = function(ev) log[#log+1] = 'b:' .. (ev.path or ev.tempo) end })");
    rt.emit(.{ .ProjectSavePost = .{ .path = "song.wsj" } });
    rt.emit(.{ .PlaybackStart = .{ .tempo = 141 } });
    rt.emit(.{ .TrackAdd = .{ .track = 2 } }); // no subscriber, must be a no-op
    try rt.loadString("assert(table.concat(log, ' ') == 'a:ProjectSavePost:song.wsj b:song.wsj b:141.0')");
}

test "autocmds remove via once, truthy return, and del_autocmd" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("n = 0; m = 0;" ++
        "wstudio.api.create_autocmd('PlaybackStop', { callback = function() n = n + 1 end, once = true });" ++
        "wstudio.api.create_autocmd('PlaybackStop', { callback = function() m = m + 1; return m >= 2 end });" ++
        "keep_id = wstudio.api.create_autocmd('PlaybackStop', { callback = function() end })");
    try std.testing.expectEqual(@as(usize, 3), rt.autocmds_len);
    rt.emit(.{ .PlaybackStop = .{ .tempo = 120 } });
    try std.testing.expectEqual(@as(usize, 2), rt.autocmds_len); // once dropped
    rt.emit(.{ .PlaybackStop = .{ .tempo = 120 } });
    try std.testing.expectEqual(@as(usize, 1), rt.autocmds_len); // truthy return dropped
    try rt.loadString("assert(n == 1 and m == 2); wstudio.api.del_autocmd(keep_id)");
    try std.testing.expectEqual(@as(usize, 0), rt.autocmds_len);
    try rt.loadString("ok = pcall(wstudio.api.del_autocmd, keep_id); assert(ok == false)");
}

test "an erroring autocmd reports and the rest still run" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.api.create_autocmd('QuitPre', { callback = function() error('boom') end });" ++
        "wstudio.api.create_autocmd('QuitPre', { callback = function() survived = true end })");
    var th: TestHost = .{};
    rt.attachHost(th.host());
    rt.emit(.QuitPre);
    try rt.loadString("assert(survived == true)");
    try std.testing.expect(std.mem.indexOf(u8, th.log[0..th.len], "notify:Lua:") != null);
    try std.testing.expect(std.mem.indexOf(u8, th.log[0..th.len], "boom") != null);
}

test "create_autocmd rejects bad input" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.create_autocmd('NoSuchEvent', { callback = function() end })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.create_autocmd('QuitPre', {})"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.create_autocmd('QuitPre', { callback = 'nope' })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.create_autocmd({}, { callback = function() end })"));
    try std.testing.expectEqual(@as(usize, 0), rt.autocmds_len);
}

test "attachHost emits ConfigDone after the queued cmds drain" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("wstudio.cmd('bpm 100');" ++
        "wstudio.api.create_autocmd('ConfigDone', { callback = function() wstudio.notify('ready') end })");
    var th: TestHost = .{};
    rt.attachHost(th.host());
    try std.testing.expectEqualStrings("exec:bpm 100\nnotify:ready\n", th.log[0..th.len]);
}

test "wstudio.notify reaches the attached host" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    var th: TestHost = .{};
    rt.attachHost(th.host());
    try rt.loadString("wstudio.notify('hello')");
    try std.testing.expectEqualStrings("notify:hello\n", th.log[0..th.len]);
}

test "api project functions raise before a session attaches" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("assert(wstudio.api.has('get_context')); assert(not wstudio.api.has('future_api'))");
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.play()"));
    try rt.loadString("local ok, err = pcall(wstudio.api.track_count); assert(ok == false and err:find('no session') ~= nil)");
    // The content surface needs a session just as much as the rest.
    try rt.loadString(
        \\for _, name in ipairs({ 'pattern_get', 'notes_get', 'steps_get', 'fx_list', 'clip_list', 'section_list' }) do
        \\  local ok, err = pcall(wstudio.api[name], 1)
        \\  assert(ok == false and err:find('no session') ~= nil, name)
        \\end
    );
}

test "API metadata is derived from live registries" {
    var rt = try Runtime.init(.gui);
    defer rt.deinit();
    try rt.loadString(
        \\info = wstudio.api.get_api_info()
        \\assert(info.version == wstudio.version and info.api_level == 1 and info.frontend == "gui")
        \\assert(#info.functions > 20 and #info.events > 10 and #info.highlight_groups == 27)
        \\for _, name in ipairs(info.functions) do assert(type(wstudio.api[name]) == "function", name) end
        \\local function contains(xs, value) for _, x in ipairs(xs) do if x == value then return true end end return false end
        \\assert(contains(info.functions, "get_api_info") and contains(info.functions, "transport_set"))
        \\assert(contains(info.events, "TrackMove") and contains(info.highlight_groups, "focus"))
        \\assert(contains(info.views, "piano_roll") and contains(info.modes, "command"))
        \\assert(info.limits.tracks == 8192 and info.limits.groups == 8 and info.limits.keymap_lhs_keys == 4)
        \\local found = false
        \\for _, o in ipairs(info.options) do if o.name == "gui_font_size" then found = o.scope == "gui" and o.type == "number" and o.min == 8 and o.max == 40 end end
        \\assert(found)
    );
    rt.setFrontend(.tui);
    try rt.loadString("assert(wstudio.api.get_api_info().frontend == 'tui')");
}

test "Lua highlight API layers sparse colors over built-in themes" {
    var rt = try Runtime.init(.gui);
    defer rt.deinit();

    try rt.loadString("wstudio.api.set_hl('focus', { fg = '#123aBc' }); wstudio.api.set_hl('track3', { fg = '#010203' })");
    try rt.loadString("assert(wstudio.api.get_hl('focus').fg == '#123abc'); assert(wstudio.api.get_hl('track3').fg == '#010203')");
    const resolved = rt.resolvedTheme(.graphite);
    try std.testing.expectEqual(@as(u24, 0x123abc), resolved.focus);
    try std.testing.expectEqual(@as(u24, 0x010203), resolved.tracks[2]);
    try std.testing.expectEqual(theme_identity.graphite.bg0, resolved.bg0);

    try rt.loadString("wstudio.api.set_hl('focus', {})");
    try rt.loadString("assert(wstudio.api.get_hl('focus').fg == nil)");
    try std.testing.expectEqual(theme_identity.graphite.focus, rt.resolvedTheme(.graphite).focus);
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.set_hl('nope', { fg = '#ffffff' })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.set_hl('focus', { fg = 'red' })"));
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.set_hl('focus', { bg = '#ffffff' })"));
}

test "resetForReload clears keymaps, user commands, autocmds, and options" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString(
        \\wstudio.o.default_tempo = 140
        \\wstudio.keymap.set("n", "gp", function() end)
        \\wstudio.api.create_user_command("swing", function() end)
        \\wstudio.api.create_autocmd("QuitPre", { callback = function() end })
        \\wstudio.api.set_hl("focus", { fg = "#123456" })
    );
    try std.testing.expectEqual(@as(f64, 140.0), rt.config.default_tempo);
    try std.testing.expectEqual(@as(usize, 1), rt.userKeymaps().len);
    try std.testing.expectEqual(@as(usize, 1), rt.userCommands().len);
    try std.testing.expectEqual(@as(usize, 1), rt.autocmds_len);
    try std.testing.expectEqual(@as(?u24, 0x123456), rt.highlight_overrides.get(.focus));

    rt.resetForReload();

    try std.testing.expectEqual(@as(f64, 120.0), rt.config.default_tempo);
    try std.testing.expectEqual(@as(usize, 0), rt.userKeymaps().len);
    try std.testing.expectEqual(@as(usize, 0), rt.userCommands().len);
    try std.testing.expectEqual(@as(usize, 0), rt.autocmds_len);
    try std.testing.expectEqual(@as(?u24, null), rt.highlight_overrides.get(.focus));

    // The Lua state itself survives (unlike a fresh Runtime.init) - a
    // subsequent load still works and its global state persists.
    try rt.loadString("wstudio.o.default_tempo = 90");
    try std.testing.expectEqual(@as(f64, 90.0), rt.config.default_tempo);
}

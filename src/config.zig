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
const spectrum_ed = @import("ui/editors/fx_editor.zig");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

const config_keymap = @import("config_keymap.zig");
const config_lua_api = @import("config_lua_api.zig");

// Re-exported so api_functions below (which still lists every Lua API
// function by bare name) and Runtime's own keymap-table registration
// keep resolving unchanged after the handler bodies moved out.
pub const max_keymaps = config_keymap.max_keymaps;
pub const Keymap = config_keymap.Keymap;
pub const ModeMask = config_keymap.ModeMask;
pub const keysEqual = config_keymap.keysEqual;
pub const max_keymap_lhs = config_keymap.max_keymap_lhs;
pub const keymapSet = config_keymap.keymapSet;
pub const keymapDel = config_keymap.keymapDel;
pub const notify = config_lua_api.notify;
pub const exec = config_lua_api.exec;
pub const createUserCommand = config_lua_api.createUserCommand;
pub const delUserCommand = config_lua_api.delUserCommand;
pub const apiHas = config_lua_api.apiHas;
pub const apiGetInfo = config_lua_api.apiGetInfo;
pub const apiGetMode = config_lua_api.apiGetMode;
pub const apiGetCurrentView = config_lua_api.apiGetCurrentView;
pub const apiGetCurrentTrack = config_lua_api.apiGetCurrentTrack;
pub const apiGetContext = config_lua_api.apiGetContext;
pub const apiSetHl = config_lua_api.apiSetHl;
pub const apiGetHl = config_lua_api.apiGetHl;
pub const apiPlay = config_lua_api.apiPlay;
pub const apiTransportGet = config_lua_api.apiTransportGet;
pub const apiTransportSet = config_lua_api.apiTransportSet;
pub const apiStop = config_lua_api.apiStop;
pub const apiIsPlaying = config_lua_api.apiIsPlaying;
pub const apiGetTempo = config_lua_api.apiGetTempo;
pub const apiSetTempo = config_lua_api.apiSetTempo;
pub const apiTrackCount = config_lua_api.apiTrackCount;
pub const apiTrackGet = config_lua_api.apiTrackGet;
pub const apiTrackSet = config_lua_api.apiTrackSet;
pub const apiTrackAdd = config_lua_api.apiTrackAdd;
pub const apiTrackDel = config_lua_api.apiTrackDel;
pub const apiTrackDuplicate = config_lua_api.apiTrackDuplicate;
pub const apiTrackMove = config_lua_api.apiTrackMove;
pub const apiSetCurrentTrack = config_lua_api.apiSetCurrentTrack;
pub const apiPatternGet = config_lua_api.apiPatternGet;
pub const apiPatternSet = config_lua_api.apiPatternSet;
pub const apiNotesGet = config_lua_api.apiNotesGet;
pub const apiNotesSet = config_lua_api.apiNotesSet;
pub const apiStepsGet = config_lua_api.apiStepsGet;
pub const apiStepsSet = config_lua_api.apiStepsSet;
pub const apiFxList = config_lua_api.apiFxList;
pub const apiFxAdd = config_lua_api.apiFxAdd;
pub const apiFxDel = config_lua_api.apiFxDel;
pub const apiFxMove = config_lua_api.apiFxMove;
pub const apiFxSet = config_lua_api.apiFxSet;
pub const apiFxParams = config_lua_api.apiFxParams;
pub const apiFxParamSet = config_lua_api.apiFxParamSet;
pub const apiClipList = config_lua_api.apiClipList;
pub const apiClipAdd = config_lua_api.apiClipAdd;
pub const apiClipDel = config_lua_api.apiClipDel;
pub const apiClipClear = config_lua_api.apiClipClear;
pub const apiSectionList = config_lua_api.apiSectionList;
pub const apiSectionSet = config_lua_api.apiSectionSet;
pub const apiSectionDel = config_lua_api.apiSectionDel;
pub const apiProjectGet = config_lua_api.apiProjectGet;
pub const apiProjectSave = config_lua_api.apiProjectSave;
pub const apiProjectOpen = config_lua_api.apiProjectOpen;
pub const apiProjectNew = config_lua_api.apiProjectNew;
pub const createAutocmd = config_lua_api.createAutocmd;
pub const delAutocmd = config_lua_api.delAutocmd;

const system_config_path = "/etc/xdg/wstudio/init.lua";
pub const api_level = 1;
pub const version = ws_root.version;

const ApiFunction = struct { name: [:0]const u8, func: c.lua_CFunction };

/// The registration table is also the source for `get_api_info().functions`.
/// A callable API entry cannot ship without appearing in plugin metadata.
pub const api_functions = [_]ApiFunction{
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
pub const option_specs = [_]OptionSpec{
    .{ .name = "preferred_frontend" },
    .{ .name = "default_tempo", .min = 20, .max = 400 },
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

/// Frontend callbacks the Lua runtime routes `wstudio.notify` and
/// `wstudio.cmd` through once a frontend is live. Until `attachHost`,
/// notify prints to stderr and cmd lines queue in the Lua registry.
pub const Host = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque, msg: []const u8) void,
    exec: *const fn (ctx: *anyopaque, line: []const u8) void,
};

/// Registry slot holding `wstudio.cmd` lines issued before a host attaches.
pub const pending_cmds_key = "wstudio.pending_cmds";

/// Same "small fixed bank" convention as drum banks/Fx.max_units: a config
/// registering more than this many `:` commands is not a real config.
pub const max_user_cmds = 64;
pub const user_cmd_name_cap = 32;
pub const user_cmd_desc_cap = 64;

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

    pub fn removeAutocmd(self: *Runtime, idx: usize) void {
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
            if (builtin.os.tag == .macos) {
                if (try loadIfPresent(self, io, path)) return true;
                var legacy_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (legacyMacConfigPath(&legacy_buf)) |legacy| {
                    if (try loadIfPresent(self, io, legacy)) return true;
                }
            }
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

/// Make `require "foo"` find `lua/foo.lua` (or `foo/init.lua`) below
/// `userConfigDir`, mirroring Neovim's runtime `lua/` directory.
fn prependUserLuaPath(state: *c.lua_State) void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = userConfigDir(&dir_buf) orelse return;
    var prefix_buf: [4 * std.fs.max_path_bytes + 64]u8 = undefined;
    const prefix = if (builtin.os.tag == .macos) blk: {
        var legacy_buf: [std.fs.max_path_bytes]u8 = undefined;
        const legacy_path = legacyMacConfigPath(&legacy_buf) orelse break :blk std.fmt.bufPrint(
            &prefix_buf,
            "{s}/lua/?.lua;{s}/lua/?/init.lua;",
            .{ dir, dir },
        ) catch return;
        const legacy_dir = std.fs.path.dirname(legacy_path).?;
        break :blk std.fmt.bufPrint(
            &prefix_buf,
            "{s}/lua/?.lua;{s}/lua/?/init.lua;{s}/lua/?.lua;{s}/lua/?/init.lua;",
            .{ dir, dir, legacy_dir, legacy_dir },
        ) catch return;
    } else std.fmt.bufPrint(
        &prefix_buf,
        "{s}/lua/?.lua;{s}/lua/?/init.lua;",
        .{ dir, dir },
    ) catch return;
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
    if (os == .macos) {
        if (home) |dir| return std.fmt.bufPrint(buf, "{s}/Library/Application Support/wstudio", .{dir}) catch null;
    }
    if (home) |dir| return std.fmt.bufPrint(buf, "{s}{c}.config{c}wstudio", .{ dir, sep, sep }) catch null;
    return null;
}

fn legacyMacConfigPath(buf: []u8) ?[]const u8 {
    const home = envValue("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/wstudio/init.lua", .{home}) catch null;
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
    try std.testing.expectEqualStrings("/Users/ada/Library/Application Support/wstudio", configDirFromEnv(&buf, .macos, null, null, "/Users/ada").?);
    try std.testing.expectEqualStrings("/tmp/xdg/wstudio", configDirFromEnv(&buf, .macos, "/tmp/xdg", null, "/Users/ada").?);
}

pub fn runtime(state: *c.lua_State) *Runtime {
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
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.o.default_tempo = 401"));
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
        \\assert(#info.functions > 20 and #info.events > 10 and #info.highlight_groups == 36)
        \\for _, name in ipairs(info.functions) do assert(type(wstudio.api[name]) == "function", name) end
        \\local function contains(xs, value) for _, x in ipairs(xs) do if x == value then return true end end return false end
        \\assert(contains(info.functions, "get_api_info") and contains(info.functions, "transport_set"))
        \\assert(contains(info.events, "TrackMove") and contains(info.highlight_groups, "focus"))
        \\assert(contains(info.views, "piano_roll") and contains(info.modes, "command"))
        \\assert(info.limits.tracks == 8192 and info.limits.groups == 16 and info.limits.keymap_lhs_keys == 4)
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

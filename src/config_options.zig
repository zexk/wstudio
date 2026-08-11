//! The `wstudio.o` option surface - split out of config.zig. Owns the
//! `Config` value every frontend reads, the `option_specs` table that is the
//! single source for the Lua getter/setter and range validation, and the
//! user-facing enums those options are typed with. Adding an option is one
//! `Config` field plus one `option_specs` row, both here.

const std = @import("std");
const theme_identity = @import("wstudio").theme_identity;

const config = @import("config.zig");
const c = config.c;
const runtime = config.runtime;

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
    umbra_light,
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
    /// Whether hosted CLAP/VST3 plugins run in their own sandboxed child
    /// process (Linux only - see src/plugin_host/) so a crashing or
    /// hanging plugin can't take the whole DAW down with it. Escape hatch
    /// for troubleshooting; the fallback (or non-Linux platforms) is
    /// today's in-process hosting.
    sandbox_plugins: bool = true,
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
    .{ .name = "sandbox_plugins" },
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
pub fn setOption(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn getOption(state: ?*c.lua_State) callconv(.c) c_int {
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

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
const cmd_mod = @import("ui/cmd.zig");
const tui_app = @import("ui/app.zig");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

const system_config_path = "/etc/xdg/wstudio/init.lua";

/// One name, one hex table (src/theme_identity.zig) - the GUI's panel skin
/// and the TUI's OSC palette theming (tui/theme.zig) both read it.
pub const GuiTheme = theme_identity.Name;

/// `.none` (the default) never touches the terminal: OSC 4/10/11 palette
/// reprogramming is global to the physical terminal, not scoped to
/// wstudio's alternate screen, so under tmux/screen it would recolor other
/// panes sharing that terminal too. Opting into a name is a deliberate
/// choice, not something a first run should spring on someone who picked
/// their terminal colors on purpose - see tui/theme.zig.
pub const TuiTheme = enum { none, patina, patina_light, graphite, graphite_light, umbra };

/// GUI panel/window corner style. Scoped to ImGui's own chrome (windows,
/// child panels, popups, buttons) via the global style vars this drives -
/// elements that are rounded by their own nature rather than as GUI theming
/// (piano-roll/step-grid note blocks, knobs) draw their own explicit
/// `.rounding` per call and never read these, so they're untouched either way.
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
    autosave_interval_s: u16 = 30,
    frame_poll_ms: u16 = 30,
    audio_block_frames: u32 = 256,
    audio_backend: @import("wstudio").audio_host.Choice = .auto,
    tap_timeout_ms: u32 = 2000,
    note_preview_ms: u16 = 220,
    cmd_history_lines: u16 = 50,
    status_message_ms: u16 = 3000,
    default_browse_dir: PathBuf = .{},
    clap_plugin_path: PathBuf = .{},
    default_project_path: PathBuf = PathBuf.init("project.wsj"),
    file_browser_show_hidden: bool = false,
    default_drum_grid: @import("wstudio").time_grid.Division = .sixteenth,
    default_piano_grid: @import("wstudio").time_grid.Division = .sixteenth,
    default_piano_triplet_grid: bool = false,
    default_piano_note_length_steps: u8 = 1,
    default_arrangement_grid: @import("wstudio").time_grid.Division = .quarter,
    piano_ghost_notes: bool = false,
    tui_mouse: bool = true,
    tui_theme: TuiTheme = .none,
    gui_font_size: f32 = 15.0,
    gui_vsync: bool = true,
    gui_theme: GuiTheme = .patina,
    gui_panel_border: PanelBorder = .square,
    gui_window_width: u16 = 1440,
    gui_window_height: u16 = 900,
    undo_history_entries: u16 = 64,
    default_metronome_enabled: bool = false,
    metronome_click_gain: f32 = 1.0,
    count_in_bars: u8 = 1,
    default_midi_velocity_curve: @import("wstudio").midi_velocity.VelocityCurve = .linear,
    default_automation_gain_step_db: f32 = 1.0,
    default_automation_pan_step: f32 = 0.05,
    gui_knob_drag_pixels: f32 = 180.0,
    gui_envelope_drag_pixels: f32 = 140.0,
    gui_meter_decay_db_s: f32 = 24.0,
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
    .{ .name = "autosave_interval_s", .min = 0, .max = 600 },
    .{ .name = "frame_poll_ms", .min = 5, .max = 1000, .scope = .tui },
    .{ .name = "audio_block_frames", .min = 16, .max = 4096 },
    .{ .name = "audio_backend" },
    .{ .name = "tap_timeout_ms", .min = 100, .max = 10000 },
    .{ .name = "note_preview_ms", .min = 20, .max = 2000 },
    .{ .name = "cmd_history_lines", .min = 10, .max = 500 },
    .{ .name = "status_message_ms", .min = 200, .max = 10000 },
    .{ .name = "default_browse_dir" },
    .{ .name = "clap_plugin_path" },
    .{ .name = "default_project_path", .allow_empty = false },
    .{ .name = "file_browser_show_hidden" },
    .{ .name = "default_drum_grid" },
    .{ .name = "default_piano_grid" },
    .{ .name = "default_piano_triplet_grid" },
    .{ .name = "default_piano_note_length_steps", .min = 1, .max = 16 },
    .{ .name = "default_arrangement_grid" },
    .{ .name = "piano_ghost_notes" },
    .{ .name = "tui_mouse", .scope = .tui },
    .{ .name = "tui_theme", .scope = .tui },
    .{ .name = "gui_font_size", .min = 8, .max = 40, .scope = .gui },
    .{ .name = "gui_vsync", .scope = .gui },
    .{ .name = "gui_theme", .scope = .gui },
    .{ .name = "gui_panel_border", .scope = .gui },
    .{ .name = "gui_window_width", .min = 960, .max = 7680, .scope = .gui },
    .{ .name = "gui_window_height", .min = 600, .max = 4320, .scope = .gui },
    .{ .name = "undo_history_entries", .min = 8, .max = 512 },
    .{ .name = "default_metronome_enabled" },
    .{ .name = "metronome_click_gain", .min = 0, .max = 1 },
    .{ .name = "count_in_bars", .min = 0, .max = 4 },
    .{ .name = "default_midi_velocity_curve" },
    .{ .name = "default_automation_gain_step_db", .min = 0, .max = 12 },
    .{ .name = "default_automation_pan_step", .min = 0, .max = 1 },
    .{ .name = "gui_knob_drag_pixels", .min = 40, .max = 600, .scope = .gui },
    .{ .name = "gui_envelope_drag_pixels", .min = 40, .max = 600, .scope = .gui },
    .{ .name = "gui_meter_decay_db_s", .min = 1, .max = 200, .scope = .gui },
};

comptime {
    for (option_specs) |spec| {
        if (!@hasField(Config, spec.name)) @compileError("option spec without a Config field: " ++ spec.name);
    }
    if (option_specs.len != @typeInfo(Config).@"struct".fields.len) {
        @compileError("Config field without an option_specs row");
    }
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
/// the two ctrl keys the terminal layer actually decodes.
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
        _ = c.lua_pushstring(self.state, "1.0.0-beta.2");
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
        c.lua_createtable(self.state, 0, 3); // wstudio.api
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, exec, 1);
        c.lua_setfield(self.state, -2, "exec"); // wstudio.api.exec
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, createUserCommand, 1);
        c.lua_setfield(self.state, -2, "create_user_command");
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, delUserCommand, 1);
        c.lua_setfield(self.state, -2, "del_user_command");
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, createAutocmd, 1);
        c.lua_setfield(self.state, -2, "create_autocmd");
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, delAutocmd, 1);
        c.lua_setfield(self.state, -2, "del_autocmd");
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, notify, 1);
        c.lua_setfield(self.state, -2, "notify"); // wstudio.notify's core twin
        const api_fns = [_]struct { name: [:0]const u8, func: c.lua_CFunction }{
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
        };
        for (api_fns) |f| {
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
                    return c.luaL_error(l, "invalid scope (any, drum, sampler, synth, slicer)");
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
    ViewEnter,
    ColorScheme,
    QuitPre,
};

pub const PathEvent = struct { path: []const u8 };
pub const TempoEvent = struct { tempo: f64 };
/// 1-based, matching the API's track indexing.
pub const TrackEvent = struct { track: usize };
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

fn apiPlay(state: ?*c.lua_State) callconv(.c) c_int {
    requireApp(state.?).apiPlay();
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
    c.lua_createtable(l, 0, 7);
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
    c.lua_pushnil(l);
    while (c.lua_next(l, 2) != 0) {
        if (c.lua_type(l, -2) != c.LUA_TSTRING) return c.luaL_error(l, "track_set keys must be strings");
        const key = std.mem.span(c.lua_tolstring(l, -2, null));
        if (std.mem.eql(u8, key, "gain_db")) {
            if (c.lua_isnumber(l, -1) == 0) return c.luaL_error(l, "gain_db must be a number");
            app.apiSetTrackGainDb(idx, @floatCast(c.lua_tonumberx(l, -1, null)));
        } else if (std.mem.eql(u8, key, "pan")) {
            if (c.lua_isnumber(l, -1) == 0) return c.luaL_error(l, "pan must be a number");
            app.apiSetTrackPan(idx, @floatCast(c.lua_tonumberx(l, -1, null)));
        } else if (std.mem.eql(u8, key, "muted")) {
            if (c.lua_type(l, -1) != c.LUA_TBOOLEAN) return c.luaL_error(l, "muted must be a boolean");
            app.apiSetTrackMuted(idx, c.lua_toboolean(l, -1) != 0);
        } else if (std.mem.eql(u8, key, "soloed")) {
            if (c.lua_type(l, -1) != c.LUA_TBOOLEAN) return c.luaL_error(l, "soloed must be a boolean");
            app.apiSetTrackSoloed(idx, c.lua_toboolean(l, -1) != 0);
        } else if (std.mem.eql(u8, key, "name")) {
            if (c.lua_type(l, -1) != c.LUA_TSTRING) return c.luaL_error(l, "name must be a string");
            var len: usize = 0;
            const s = c.lua_tolstring(l, -1, &len);
            if (!app.apiRenameTrack(idx, s[0..len])) return c.luaL_error(l, "rename failed");
        } else {
            return c.luaL_error(l, "unknown track field '%s'", c.lua_tolstring(l, -2, null));
        }
        c.lua_settop(l, -2); // pop the value, keep the key for lua_next
    }
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

test "path options read and write as strings, rejecting oversized paths" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString("assert(wstudio.o.default_browse_dir == '')");
    try rt.loadString("wstudio.o.default_browse_dir = '~/Music/Samples'; assert(wstudio.o.default_browse_dir == '~/Music/Samples')");
    try std.testing.expectEqualStrings("~/Music/Samples", rt.config.default_browse_dir.slice());
    try rt.loadString("wstudio.o.clap_plugin_path = '/opt/clap'; assert(wstudio.o.clap_plugin_path == '/opt/clap')");
    try std.testing.expectEqualStrings("/opt/clap", rt.config.clap_plugin_path.slice());
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
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.api.play()"));
    try rt.loadString("local ok, err = pcall(wstudio.api.track_count); assert(ok == false and err:find('no session') ~= nil)");
}

test "resetForReload clears keymaps, user commands, autocmds, and options" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    try rt.loadString(
        \\wstudio.o.default_tempo = 140
        \\wstudio.keymap.set("n", "gp", function() end)
        \\wstudio.api.create_user_command("swing", function() end)
        \\wstudio.api.create_autocmd("QuitPre", { callback = function() end })
    );
    try std.testing.expectEqual(@as(f64, 140.0), rt.config.default_tempo);
    try std.testing.expectEqual(@as(usize, 1), rt.userKeymaps().len);
    try std.testing.expectEqual(@as(usize, 1), rt.userCommands().len);
    try std.testing.expectEqual(@as(usize, 1), rt.autocmds_len);

    rt.resetForReload();

    try std.testing.expectEqual(@as(f64, 120.0), rt.config.default_tempo);
    try std.testing.expectEqual(@as(usize, 0), rt.userKeymaps().len);
    try std.testing.expectEqual(@as(usize, 0), rt.userCommands().len);
    try std.testing.expectEqual(@as(usize, 0), rt.autocmds_len);

    // The Lua state itself survives (unlike a fresh Runtime.init) - a
    // subsequent load still works and its global state persists.
    try rt.loadString("wstudio.o.default_tempo = 90");
    try std.testing.expectEqual(@as(f64, 90.0), rt.config.default_tempo);
}

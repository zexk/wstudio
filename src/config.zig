//! Lua-backed user configuration and scripting runtime.
//!
//! See docs/lua-api.md for the API design this implements. The runtime is
//! created in main.zig before a frontend starts, runs `init.lua`, and then
//! outlives startup so the frontend can attach host hooks (`attachHost`)
//! that route `wstudio.notify`/`wstudio.cmd` into the live App.

const std = @import("std");
const ws_input = @import("wstudio").input;
const cmd_mod = @import("tui/cmd.zig");
const tui_app = @import("tui/app.zig");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

pub const Config = struct {
    default_tempo: f64 = 120.0,
    default_sample_rate: u32 = 48_000,
    default_beats_per_bar: u8 = 4,
    frame_poll_ms: u16 = 30,
    audio_block_frames: u32 = 256,
    tap_timeout_ms: u32 = 2000,
    gui_font_size: f32 = 15.0,
    gui_vsync: bool = true,
};

pub const Frontend = enum { tui, gui };

/// Which frontend an option affects. Documentation and naming discipline
/// (the tui_/gui_ prefixes), not access control: a TUI session may set
/// `gui_*` options, they just have no effect there.
pub const Scope = enum { core, tui, gui };

const OptionSpec = struct {
    name: [:0]const u8,
    /// Valid range, ignored for bool fields. All current bounds are whole
    /// numbers, so comptime_int keeps them comparable against both the
    /// integer and float values Lua hands over.
    min: comptime_int = 0,
    max: comptime_int = 0,
    scope: Scope = .core,
};

/// One row per `wstudio.o` option. The Lua getter, setter, and range
/// validation all derive from this table; adding an option is one row here
/// plus its `Config` field.
const option_specs = [_]OptionSpec{
    .{ .name = "default_tempo", .min = 20, .max = 999 },
    .{ .name = "default_sample_rate", .min = 8000, .max = 192000 },
    .{ .name = "default_beats_per_bar", .min = 1, .max = 16 },
    .{ .name = "frame_poll_ms", .min = 5, .max = 1000, .scope = .tui },
    .{ .name = "audio_block_frames", .min = 16, .max = 4096 },
    .{ .name = "tap_timeout_ms", .min = 100, .max = 10000 },
    .{ .name = "gui_font_size", .min = 8, .max = 40, .scope = .gui },
    .{ .name = "gui_vsync", .scope = .gui },
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
    user_cmds: [max_user_cmds]UserCmd = undefined,
    user_cmds_len: usize = 0,
    keymaps: [max_keymaps]Keymap = undefined,
    keymaps_len: usize = 0,

    pub fn init(frontend: Frontend) !Runtime {
        const state = c.luaL_newstate() orelse return error.OutOfMemory;
        c.luaL_openlibs(state);
        prependUserLuaPath(state);
        return .{ .state = state, .frontend = frontend };
    }

    pub fn deinit(self: *Runtime) void {
        c.lua_close(self.state);
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
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (userConfigPath(&path_buf)) |path| {
            if (loadIfPresent(self, io, path)) |loaded| {
                if (loaded) return true;
            } else |err| return err;
        }
        return loadIfPresent(self, io, "/etc/xdg/wstudio/init.lua");
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
        _ = c.lua_pushstring(self.state, "1.0.0-beta.1");
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

pub fn userConfigDir(buf: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| return std.fmt.bufPrint(buf, "{s}/wstudio", .{std.mem.sliceTo(xdg, 0)}) catch null;
    if (std.c.getenv("HOME")) |home| return std.fmt.bufPrint(buf, "{s}/.config/wstudio", .{std.mem.sliceTo(home, 0)}) catch null;
    return null;
}

pub fn userConfigPath(buf: []u8) ?[]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = userConfigDir(&dir_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/init.lua", .{dir}) catch null;
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
        return 0;
    }
    return c.luaL_error(l, "no such user command");
}

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

test "wstudio.frontend reports the active frontend" {
    var rt = try Runtime.init(.gui);
    defer rt.deinit();
    try rt.loadString("assert(wstudio.frontend == 'gui')");
}

test "require path includes the user lua dir" {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (userConfigDir(&dir_buf) == null) return; // no HOME/XDG in env
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

test "wstudio.notify reaches the attached host" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    var th: TestHost = .{};
    rt.attachHost(th.host());
    try rt.loadString("wstudio.notify('hello')");
    try std.testing.expectEqualStrings("notify:hello\n", th.log[0..th.len]);
}

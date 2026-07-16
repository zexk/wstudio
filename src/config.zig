//! Lua-backed user configuration and scripting runtime.
//!
//! See docs/lua-api.md for the API design this implements. The runtime is
//! created in main.zig before a frontend starts, runs `init.lua`, and then
//! outlives startup so the frontend can attach host hooks (`attachHost`)
//! that route `wstudio.notify`/`wstudio.cmd` into the live App.

const std = @import("std");

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

pub const Runtime = struct {
    state: *c.lua_State,
    frontend: Frontend,
    config: Config = .{},
    host: ?Host = null,

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
        c.lua_createtable(self.state, 0, 1); // wstudio.api
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, exec, 1);
        c.lua_setfield(self.state, -2, "exec"); // wstudio.api.exec
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
    log: [128]u8 = undefined,
    len: usize = 0,

    fn append(self: *TestHost, tag: []const u8, text: []const u8) void {
        for (tag) |b| {
            self.log[self.len] = b;
            self.len += 1;
        }
        for (text) |b| {
            self.log[self.len] = b;
            self.len += 1;
        }
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

test "wstudio.notify reaches the attached host" {
    var rt = try Runtime.init(.tui);
    defer rt.deinit();
    var th: TestHost = .{};
    rt.attachHost(th.host());
    try rt.loadString("wstudio.notify('hello')");
    try std.testing.expectEqualStrings("notify:hello\n", th.log[0..th.len]);
}

//! Lua-backed user configuration and scripting runtime.

const std = @import("std");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

pub const Config = struct {
    default_tempo: f64 = 120.0,
};

pub const Runtime = struct {
    state: *c.lua_State,
    config: Config = .{},

    pub fn init() !Runtime {
        const state = c.luaL_newstate() orelse return error.OutOfMemory;
        c.luaL_openlibs(state);
        return .{ .state = state };
    }

    pub fn deinit(self: *Runtime) void {
        c.lua_close(self.state);
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
        c.lua_createtable(self.state, 0, 3);
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, setOption, 1);
        c.lua_setfield(self.state, -2, "set_option");
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, getOption, 1);
        c.lua_setfield(self.state, -2, "get_option");
        _ = c.lua_pushstring(self.state, "1.0.0-beta.1");
        c.lua_setfield(self.state, -2, "version");
        c.lua_setglobal(self.state, "wstudio");
    }

    fn luaError(self: *Runtime) error{LuaError} {
        const msg = c.lua_tolstring(self.state, -1, null);
        if (msg != null) std.debug.print("wstudio: Lua error: {s}\n", .{std.mem.span(msg)});
        c.lua_settop(self.state, -2);
        return error.LuaError;
    }
};

fn loadIfPresent(self: *Runtime, io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    try self.loadFile(path);
    return true;
}

pub fn userConfigPath(buf: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| return std.fmt.bufPrint(buf, "{s}/wstudio/init.lua", .{std.mem.sliceTo(xdg, 0)}) catch null;
    if (std.c.getenv("HOME")) |home| return std.fmt.bufPrint(buf, "{s}/.config/wstudio/init.lua", .{std.mem.sliceTo(home, 0)}) catch null;
    return null;
}

fn runtime(state: *c.lua_State) *Runtime {
    return @ptrCast(@alignCast(c.lua_touserdata(state, c.lua_upvalueindex(1))));
}

fn setOption(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const name = std.mem.span(c.luaL_checklstring(l, 1, null));
    if (std.mem.eql(u8, name, "default_tempo")) {
        const value = c.luaL_checknumber(l, 2);
        if (value < 20 or value > 999) return c.luaL_error(l, "default_tempo must be between 20 and 999");
        runtime(l).config.default_tempo = value;
        return 0;
    }
    return c.luaL_error(l, "unknown option");
}

fn getOption(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const name = std.mem.span(c.luaL_checklstring(l, 1, null));
    if (std.mem.eql(u8, name, "default_tempo")) {
        c.lua_pushnumber(l, runtime(l).config.default_tempo);
        return 1;
    }
    return c.luaL_error(l, "unknown option");
}

test "Lua API sets and reads options" {
    var rt = try Runtime.init();
    defer rt.deinit();
    try rt.loadString("wstudio.set_option('default_tempo', 132); assert(wstudio.get_option('default_tempo') == 132)");
    try std.testing.expectEqual(@as(f64, 132), rt.config.default_tempo);
}

test "Lua API rejects invalid option values" {
    var rt = try Runtime.init();
    defer rt.deinit();
    try std.testing.expectError(error.LuaError, rt.loadString("wstudio.set_option('default_tempo', 2)"));
}

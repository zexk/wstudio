//! The `wstudio.api.*` Lua binding surface - split out of config.zig.
//! Every function here shares the uniform `fn(?*c.lua_State) callconv(.c)
//! c_int` signature and is dispatched purely through config.zig's
//! `api_functions` table (which stays there, alongside `ApiFunction`,
//! since Runtime's own init also walks it to register the table).

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

const config = @import("config.zig");
const c = config.c;
const runtime = config.runtime;
const pending_cmds_key = config.pending_cmds_key;
const Config = config.Config;
const UserCmd = config.UserCmd;
const user_cmd_name_cap = config.user_cmd_name_cap;
const version = config.version;
const api_level = config.api_level;
const user_cmd_desc_cap = config.user_cmd_desc_cap;
const max_user_cmds = config.max_user_cmds;
const api_functions = config.api_functions;
const option_specs = config.option_specs;
const max_keymaps = config.max_keymaps;
const max_keymap_lhs = config.max_keymap_lhs;
const Event = config.Event;
const EventData = config.EventData;
const Autocmd = config.Autocmd;
const max_autocmds = config.max_autocmds;

pub fn notify(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn exec(state: ?*c.lua_State) callconv(.c) c_int {
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
pub fn createUserCommand(state: ?*c.lua_State) callconv(.c) c_int {
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
                    return c.luaL_error(l, "invalid scope (any, drum, sampler, synth, slicer, soundfont, acoustic)");
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

pub fn delUserCommand(state: ?*c.lua_State) callconv(.c) c_int {
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
pub fn apiHas(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiGetInfo(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiGetMode(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    _ = c.lua_pushstring(l, @tagName(requireApp(l).modal.mode));
    return 1;
}

pub fn apiGetCurrentView(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    _ = c.lua_pushstring(l, @tagName(requireApp(l).view));
    return 1;
}

pub fn apiGetCurrentTrack(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    pushCurrentTrack(l, requireApp(l));
    return 1;
}

pub fn apiGetContext(state: ?*c.lua_State) callconv(.c) c_int {
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
pub fn apiSetHl(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiGetHl(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiPlay(state: ?*c.lua_State) callconv(.c) c_int {
    requireApp(state.?).apiPlay();
    return 0;
}

pub fn apiTransportGet(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiTransportSet(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiStop(state: ?*c.lua_State) callconv(.c) c_int {
    requireApp(state.?).apiStop();
    return 0;
}

pub fn apiIsPlaying(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    c.lua_pushboolean(l, @intFromBool(requireApp(l).apiIsPlaying()));
    return 1;
}

pub fn apiGetTempo(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    c.lua_pushnumber(l, requireApp(l).apiGetTempo());
    return 1;
}

pub fn apiSetTempo(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const bpm = c.luaL_checknumber(l, 1);
    if (!app.apiSetTempo(bpm)) return c.luaL_error(l, "tempo must be between 20 and 400");
    return 0;
}

pub fn apiTrackCount(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    c.lua_pushinteger(l, @intCast(requireApp(l).session.project.tracks.items.len));
    return 1;
}

pub fn apiTrackGet(state: ?*c.lua_State) callconv(.c) c_int {
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
pub fn apiTrackSet(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiTrackAdd(state: ?*c.lua_State) callconv(.c) c_int {
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
                    return c.luaL_error(l, "unknown kind (synth, drum, sampler, slicer, soundfont, acoustic)");
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

pub fn apiTrackDel(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    if (!app.apiTrackDel(idx)) return c.luaL_error(l, "cannot delete the last track");
    return 0;
}

pub fn apiTrackDuplicate(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    const duplicate = app.apiTrackDuplicate(idx) orelse return c.luaL_error(l, "track limit reached");
    c.lua_pushinteger(l, @intCast(duplicate + 1));
    return 1;
}

pub fn apiTrackMove(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    const target = checkTrackIndex(l, 2, app);
    c.lua_pushinteger(l, @intCast(app.apiTrackMove(idx, target) + 1));
    return 1;
}

pub fn apiSetCurrentTrack(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiPatternGet(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiPatternSet(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiNotesGet(state: ?*c.lua_State) callconv(.c) c_int {
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
pub fn apiNotesSet(state: ?*c.lua_State) callconv(.c) c_int {
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
pub fn apiStepsGet(state: ?*c.lua_State) callconv(.c) c_int {
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
pub fn apiStepsSet(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiFxList(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiFxAdd(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiFxDel(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const target = checkFxTarget(l, 1, app);
    app.apiFxDel(target, checkFxSlot(l, 2)) catch |err| return fxError(l, err);
    return 0;
}

pub fn apiFxMove(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const target = checkFxTarget(l, 1, app);
    const slot = checkFxSlot(l, 2);
    const to = checkFxSlot(l, 3);
    const at = app.apiFxMove(target, slot, to) catch |err| return fxError(l, err);
    c.lua_pushinteger(l, @intCast(at + 1));
    return 1;
}

pub fn apiFxSet(state: ?*c.lua_State) callconv(.c) c_int {
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
pub fn apiFxParams(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiFxParamSet(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiClipList(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiClipAdd(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    app.apiClipAdd(idx, checkBar(l, 2)) catch |err| return clipError(l, err);
    return 0;
}

pub fn apiClipDel(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const idx = checkTrackIndex(l, 1, app);
    app.apiClipDel(idx, checkBar(l, 2)) catch |err| return clipError(l, err);
    return 0;
}

pub fn apiClipClear(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiSectionList(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiSectionSet(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    const tick = checkSectionTick(l, 1);
    var len: usize = 0;
    const name = c.luaL_checklstring(l, 2, &len);
    if (len == 0) return c.luaL_error(l, "section name cannot be empty");
    app.apiSectionSet(tick, name[0..len]) catch return c.luaL_error(l, "out of memory");
    return 0;
}

pub fn apiSectionDel(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    const app = requireApp(l);
    if (!app.apiSectionDel(checkSectionTick(l, 1))) return c.luaL_error(l, "no section at that beat");
    return 0;
}

pub fn apiProjectGet(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiProjectSave(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiProjectOpen(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn apiProjectNew(state: ?*c.lua_State) callconv(.c) c_int {
    const l = state.?;
    if (!requireApp(l).apiProjectNew(forceOption(l, 1))) return c.luaL_error(l, "unsaved changes; pass { force = true } to discard them");
    return 0;
}

/// `wstudio.api.create_autocmd(event|{events}, { callback, once? })` ->
/// integer id for del_autocmd. Neovim's shape minus patterns and groups.
/// The registry ref is taken last so a validation longjmp can't leak it.
pub fn createAutocmd(state: ?*c.lua_State) callconv(.c) c_int {
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

pub fn delAutocmd(state: ?*c.lua_State) callconv(.c) c_int {
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

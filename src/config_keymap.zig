//! Keymap parsing and the `wstudio.keymap.set/del` Lua binding - split out
//! of config.zig. `ModeMask`/`Keymap` are the data; `parseLhs`/
//! `parseKeyName` build a `Keymap` from a Lua-side key-notation string;
//! `keymapSet`/`keymapDel` are the C-callable entry points config.zig's
//! Runtime registers directly.

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
const Config = config.Config;
const Runtime = config.Runtime;

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
pub fn keymapSet(state: ?*c.lua_State) callconv(.c) c_int {
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
pub fn keymapDel(state: ?*c.lua_State) callconv(.c) c_int {
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

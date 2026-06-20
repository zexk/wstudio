//! Command registry — table-driven ex-style command dispatch.
//!
//! Each Def holds a name, a one-line description (shown by :help), and an
//! opaque callback. Callers wrap their typed callbacks with the comptime
//! helper in their own file rather than importing App here, which keeps
//! this module free of circular dependencies.

const std = @import("std");

pub const Def = struct {
    name: []const u8,
    /// Short usage + description shown by :help, e.g. "[<value>]  set tempo"
    desc: []const u8,
    run: *const fn (ctx: *anyopaque, args: []const u8) void,
};

/// Walk `cmds` and run the first entry whose name matches `text`.
/// Matches exactly (`:quit`) or with a trailing space (`:bpm 140`).
/// Returns false when nothing matched so the caller can emit an error.
pub fn dispatch(cmds: []const Def, ctx: *anyopaque, text: []const u8) bool {
    for (cmds) |c| {
        if (std.mem.eql(u8, text, c.name)) {
            c.run(ctx, "");
            return true;
        }
        if (text.len > c.name.len and
            std.mem.eql(u8, text[0..c.name.len], c.name) and
            text[c.name.len] == ' ')
        {
            c.run(ctx, text[c.name.len + 1 ..]);
            return true;
        }
    }
    return false;
}

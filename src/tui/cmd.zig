//! Command registry — table-driven ex-style command dispatch.
//!
//! Each Def holds a name, a one-line description (shown by :help), and an
//! opaque callback. Callers wrap their typed callbacks with the comptime
//! helper in their own file rather than importing App here, which keeps
//! this module free of circular dependencies.

const std = @import("std");
const style = @import("style.zig");

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

/// Renders the `:` prompt (typed buffer + cursor block) shared by every
/// view's status line. Before the first space, appends a dimmed,
/// space-separated list of every command name still matching what's been
/// typed so far — a single match already gets spelled out in full by Tab's
/// completion, so the list only kicks in at 2+ matches (otherwise it'd just
/// echo back the buffer). Once a space is typed and the name before it is
/// an exact command, appends that command's usage `desc` instead (a
/// reminder of argument order/shape while you type args). Both are capped
/// at `max_chars` so they can't overflow the line.
pub fn writePrompt(w: *std.Io.Writer, cmds: []const Def, buf: []const u8, max_chars: usize) !void {
    try w.writeAll(style.dim ++ " :" ++ style.rst);
    try w.print("{s}_", .{buf});

    if (buf.len == 0) return;
    if (std.mem.indexOfScalar(u8, buf, ' ')) |sp| {
        const name = buf[0..sp];
        for (cmds) |c| {
            if (!std.mem.eql(u8, c.name, name)) continue;
            try w.writeAll(style.dim ++ "  ");
            try w.writeAll(c.desc[0..@min(c.desc.len, max_chars)]);
            try w.writeAll(style.rst);
            return;
        }
        return;
    }

    var match_count: usize = 0;
    for (cmds) |c| {
        if (std.mem.startsWith(u8, c.name, buf)) match_count += 1;
    }
    if (match_count < 2) return;

    try w.writeAll(style.dim ++ "  ");
    var written: usize = 0;
    for (cmds) |c| {
        if (!std.mem.startsWith(u8, c.name, buf)) continue;
        const sep_len: usize = if (written == 0) 0 else 2;
        if (written + sep_len + c.name.len > max_chars) break;
        if (written != 0) try w.writeAll("  ");
        try w.writeAll(c.name);
        written += sep_len + c.name.len;
    }
    try w.writeAll(style.rst);
}

const test_cmds: []const Def = &.{
    .{ .name = "q", .desc = "", .run = undefined },
    .{ .name = "qa", .desc = "", .run = undefined },
    .{ .name = "qa!", .desc = "", .run = undefined },
    .{ .name = "bpm", .desc = "[<value>]  tempo in BPM (20-400)", .run = undefined },
};

fn promptText(buf: []const u8, max_chars: usize, out: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    writePrompt(&w, test_cmds, buf, max_chars) catch unreachable;
    return w.buffered();
}

test "writePrompt lists 2+ matches but not a single match" {
    var out: [128]u8 = undefined;
    // "bpm" matches only itself — no list, just the echoed buffer.
    try std.testing.expect(std.mem.indexOf(u8, promptText("bpm", 60, &out), "  bpm") == null);
    // "q" matches q / qa / qa! — all three should appear.
    const text = promptText("q", 60, &out);
    try std.testing.expect(std.mem.indexOf(u8, text, "qa!") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "qa") != null);
}

test "writePrompt skips completion once a space is typed" {
    var out: [128]u8 = undefined;
    const text = promptText("q ", 60, &out);
    try std.testing.expect(std.mem.indexOf(u8, text, "qa") == null);
}

test "writePrompt truncates to max_chars" {
    var out: [128]u8 = undefined;
    const text = promptText("q", 5, &out);
    try std.testing.expect(std.mem.indexOf(u8, text, "qa!") == null);
}

test "writePrompt shows the usage hint once a space follows an exact command name" {
    var out: [128]u8 = undefined;
    const text = promptText("bpm ", 60, &out);
    try std.testing.expect(std.mem.indexOf(u8, text, "tempo in BPM") != null);
}

test "writePrompt shows no hint for an unrecognized command name" {
    var out: [128]u8 = undefined;
    const text = promptText("nope ", 60, &out);
    try std.testing.expectEqualStrings(style.dim ++ " :" ++ style.rst ++ "nope _", text);
}

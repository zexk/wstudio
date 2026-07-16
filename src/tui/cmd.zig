//! Command registry - table-driven ex-style command dispatch.
//!
//! Each Def holds a name, a one-line description (shown by :help), and an
//! opaque callback. Callers wrap their typed callbacks with the comptime
//! helper in their own file rather than importing App here, which keeps
//! this module free of circular dependencies.

const std = @import("std");
const style = @import("style.zig");

/// Which instrument kind a command only makes sense for - `.any` (the
/// default) means every track/view. Gates the Tab-completion popup only
/// (see `visible`/`writeSuggestionBox`); `dispatch` never checks this, so a
/// fully-typed command out of scope still runs and gets that command's own
/// (usually more specific) error, e.g. "select a drum-machine track first".
pub const Scope = enum { any, drum, sampler, synth, slicer };

pub const Def = struct {
    name: []const u8,
    /// Short usage + description shown by :help, e.g. "[<value>]  set tempo"
    desc: []const u8,
    run: *const fn (ctx: *anyopaque, args: []const u8) void,
    scope: Scope = .any,
};

/// True if `c` should be offered under `active` - either it works anywhere,
/// or `active` matches the one instrument kind it's scoped to.
pub fn visible(c: Def, active: Scope) bool {
    return c.scope == .any or c.scope == active;
}

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

/// The line-editing part shared by the `:` and `/` prompts: the typed
/// buffer with a reverse-video block at `cursor` (mid-line when the user's
/// moved it there with left/right/Home/End, otherwise a trailing blank cell
/// like a real line cursor at the end).
fn writeCursor(w: *std.Io.Writer, buf: []const u8, cursor: usize) !void {
    try w.writeAll(buf[0..cursor]);
    if (cursor < buf.len) {
        try w.writeAll(style.sel);
        try w.writeByte(buf[cursor]);
        try w.writeAll(style.rst);
        try w.writeAll(buf[cursor + 1 ..]);
    } else {
        try w.writeAll(style.sel ++ " " ++ style.rst);
    }
}

/// Renders the `:` prompt shared by every view's status line - see
/// `writeCursor` for the typed-buffer/cursor part. Once a space is typed and
/// the name before it is an exact command, appends that command's usage
/// `desc` (a reminder of argument order/shape while you type args), capped
/// at `max_chars`. The command-name match list lives in `writeSuggestionBox`
/// instead of on this line - see that doc comment.
pub fn writePrompt(w: *std.Io.Writer, cmds: []const Def, buf: []const u8, cursor: usize, max_chars: usize) !void {
    try w.writeAll(style.dim ++ " :" ++ style.rst);
    try writeCursor(w, buf, cursor);

    if (buf.len == 0) return;
    const sp = std.mem.indexOfScalar(u8, buf, ' ') orelse return;
    const name = buf[0..sp];
    for (cmds) |c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        try w.writeAll(style.dim ++ "  ");
        try w.writeAll(c.desc[0..@min(c.desc.len, max_chars)]);
        try w.writeAll(style.rst);
        return;
    }
}

/// Renders the `/` fuzzy-search prompt - same line-editing as `writePrompt`
/// (see `writeCursor`), no command-suggestion box since there's no fixed
/// candidate list to search against.
pub fn writeSearchPrompt(w: *std.Io.Writer, buf: []const u8, cursor: usize) !void {
    try w.writeAll(style.dim ++ " /" ++ style.rst);
    try writeCursor(w, buf, cursor);
}

/// True for entries whose `desc` marks them as an alias of another command
/// (e.g. "quit (alias for :q)") - these carry no information beyond the
/// canonical name they duplicate, so the suggestion popup skips them.
pub fn isAlias(c: Def) bool {
    return std.mem.indexOf(u8, c.desc, "alias for") != null;
}

/// True for compatibility names the mnemonic command surface should omit.
/// Force variants with a mnemonic base, such as `edit!`, remain visible.
pub fn hiddenFromCompletion(c: Def) bool {
    return isAlias(c);
}

/// Number of command names starting with `buf` under `active` scope - 0
/// once a space has been typed (there's no fixed name list for arguments
/// here). Below 2, Tab already spells the single match out in full, so no
/// popup is needed. Skips non-candidate entries (see `hiddenFromCompletion`)
/// and out-of-scope entries (see `visible`) so shorthand forms and
/// other-instrument commands don't pad out the list.
pub fn suggestionCount(cmds: []const Def, buf: []const u8, active: Scope) usize {
    if (std.mem.indexOfScalar(u8, buf, ' ') != null) return 0;
    var n: usize = 0;
    for (cmds) |c| {
        if (hiddenFromCompletion(c) or !visible(c, active)) continue;
        if (std.mem.startsWith(u8, c.name, buf)) n += 1;
    }
    return n;
}

/// Rows `writeSuggestionBox` will actually draw for this `buf`, capped at
/// `max_rows` - callers carve exactly this many rows out of the content
/// area's budget before drawing it, so the popup never pushes the frame
/// taller than the terminal.
pub fn suggestionRows(cmds: []const Def, buf: []const u8, active: Scope, max_rows: usize) usize {
    const n = suggestionCount(cmds, buf, active);
    if (n < 2) return 0;
    return @min(n, max_rows);
}

/// Neovim-wildmenu-style popup: every in-scope, real-candidate command name
/// starting with `buf` (see `hiddenFromCompletion`/`visible`), one per line,
/// `selected` drawn as a solid reverse-video bar (index into the match
/// list, not `cmds` - clamp/compare against `suggestionCount`).
/// Truncates silently past `max_rows` (matching what `suggestionRows`
/// reserved) rather than showing a "N more" line - narrowing the typed
/// prefix is how the rest becomes reachable, same as Tab-cycling already
/// requires for large match sets.
pub fn writeSuggestionBox(w: *std.Io.Writer, cmds: []const Def, buf: []const u8, active: Scope, selected: usize, max_rows: usize) !void {
    var idx: usize = 0;
    for (cmds) |c| {
        if (hiddenFromCompletion(c) or !visible(c, active)) continue;
        if (!std.mem.startsWith(u8, c.name, buf)) continue;
        if (idx >= max_rows) break;
        const is_sel = idx == selected;
        if (is_sel) try w.writeAll(style.sel);
        try w.print("  {s: <16}", .{c.name});
        if (is_sel) try w.writeAll(style.rst);
        try style.endLine(w);
        idx += 1;
    }
}

const test_cmds: []const Def = &.{
    .{ .name = "q", .desc = "", .run = undefined },
    .{ .name = "qa", .desc = "", .run = undefined },
    .{ .name = "qa!", .desc = "", .run = undefined },
    .{ .name = "bpm", .desc = "[<value>]  tempo in BPM (20-400)", .run = undefined },
};

fn promptText(buf: []const u8, max_chars: usize, out: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    writePrompt(&w, test_cmds, buf, buf.len, max_chars) catch unreachable;
    return w.buffered();
}

test "suggestionCount/suggestionRows gate on 2+ matches and a space" {
    // "bpm" matches only itself - no popup.
    try std.testing.expectEqual(@as(usize, 1), suggestionCount(test_cmds, "bpm", .any));
    try std.testing.expectEqual(@as(usize, 0), suggestionRows(test_cmds, "bpm", .any, 10));
    // All three entries in this low-level fixture are visible candidates.
    try std.testing.expectEqual(@as(usize, 3), suggestionCount(test_cmds, "q", .any));
    try std.testing.expectEqual(@as(usize, 3), suggestionRows(test_cmds, "q", .any, 10));
    // Capped by max_rows.
    try std.testing.expectEqual(@as(usize, 1), suggestionRows(test_cmds, "q", .any, 1));
    // A space means we're past the command name - no popup at all.
    try std.testing.expectEqual(@as(usize, 0), suggestionCount(test_cmds, "q ", .any));
}

test "writeSuggestionBox lists every match, one per line, highlighting `selected`" {
    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeSuggestionBox(&w, test_cmds, "q", .any, 1, 10);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "q") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "qa") != null);
    // Exactly one selected row (the reverse-video style appears once).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, style.sel));
    // Selected row (index 1 = "qa") comes right after the reverse-video code.
    const sel_at = std.mem.indexOf(u8, text, style.sel).?;
    try std.testing.expect(std.mem.startsWith(u8, text[sel_at + style.sel.len ..], "  qa "));
}

test "writeSuggestionBox truncates at max_rows" {
    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeSuggestionBox(&w, test_cmds, "q", .any, 0, 1);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "qa") == null);
}

test "suggestionCount/writeSuggestionBox include force variants" {
    try std.testing.expectEqual(@as(usize, 3), suggestionCount(test_cmds, "q", .any));
    try std.testing.expectEqual(@as(usize, 0), suggestionRows(test_cmds, "qa!", .any, 10));

    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeSuggestionBox(&w, test_cmds, "q", .any, 0, 10);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "qa!") != null);
}

const alias_test_cmds: []const Def = &.{
    .{ .name = "q", .desc = "quit", .run = undefined },
    .{ .name = "quit", .desc = "quit (alias for :q)", .run = undefined },
    .{ .name = "qa", .desc = "quit (alias for :q)", .run = undefined },
};

test "suggestionCount/writeSuggestionBox skip alias entries" {
    // "quit" and "qa" are aliases of "q" - only "q" itself should count/show.
    try std.testing.expectEqual(@as(usize, 1), suggestionCount(alias_test_cmds, "q", .any));
    try std.testing.expectEqual(@as(usize, 0), suggestionRows(alias_test_cmds, "q", .any, 10));

    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeSuggestionBox(&w, alias_test_cmds, "q", .any, 0, 10);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "quit") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "qa") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "q") != null);
}

const scoped_test_cmds: []const Def = &.{
    // zig fmt: off
    .{ .name = "bpm",       .desc = "tempo",    .run = undefined },
    .{ .name = "load-pad",  .desc = "load pad", .run = undefined, .scope = .drum },
    // zig fmt: on
    .{ .name = "load-sample", .desc = "load sample", .run = undefined, .scope = .sampler },
};

test "suggestionCount/writeSuggestionBox hide out-of-scope commands" {
    // "bpm" is unscoped - visible under any active scope, including .any
    // (e.g. the cursor sitting on an empty track).
    try std.testing.expectEqual(@as(usize, 1), suggestionCount(scoped_test_cmds, "b", .any));
    // Under .any, both load-* commands are scoped out entirely.
    try std.testing.expectEqual(@as(usize, 0), suggestionCount(scoped_test_cmds, "l", .any));
    // Under .drum, the drum-scoped one joins; the sampler-scoped one stays hidden.
    try std.testing.expectEqual(@as(usize, 1), suggestionCount(scoped_test_cmds, "l", .drum));

    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeSuggestionBox(&w, scoped_test_cmds, "l", .drum, 0, 10);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "load-pad") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load-sample") == null);
}

test "writePrompt shows the usage hint once a space follows an exact command name" {
    var out: [128]u8 = undefined;
    const text = promptText("bpm ", 60, &out);
    try std.testing.expect(std.mem.indexOf(u8, text, "tempo in BPM") != null);
}

test "writePrompt shows no hint for an unrecognized command name" {
    var out: [128]u8 = undefined;
    const text = promptText("nope ", 60, &out);
    try std.testing.expectEqualStrings(
        style.dim ++ " :" ++ style.rst ++ "nope " ++ style.sel ++ " " ++ style.rst,
        text,
    );
}

test "writePrompt draws the cursor mid-line over the character it sits on" {
    var out: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    // Cursor at index 1 of "bpm " sits on the 'p'.
    try writePrompt(&w, test_cmds, "bpm ", 1, 60);
    try std.testing.expectEqualStrings(
        style.dim ++ " :" ++ style.rst ++ "b" ++ style.sel ++ "p" ++ style.rst ++ "m " ++ style.dim ++ "  " ++ "[<value>]  tempo in BPM (20-400)" ++ style.rst,
        w.buffered(),
    );
}

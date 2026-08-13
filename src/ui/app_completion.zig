//! Command-line history recall and `:`-prompt tab completion - split out
//! of ui/app.zig. `TabCycle` (the completion-in-progress state) stays a
//! type on `App` itself, since it's also an `App` field
//! (`tab_cycle: ?TabCycle`); everything here re-exports under its
//! original name so self.pushCommandHistory(...)-style call sites
//! elsewhere in App keep compiling unchanged.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const cmd_mod = @import("cmd.zig");
const commands = @import("commands.zig");
const commands_load = @import("commands/load.zig");
const fuzzy = @import("fuzzy.zig");
const cmd_history_store = @import("store/command_history.zig");
const config_mod = @import("../config.zig");

const app_mod = @import("app.zig");
const App = app_mod.App;
const TabCycle = App.TabCycle;
const copyTruncated = app_mod.copyTruncated;
const cmds_cap = App.cmds_cap;

/// Record a submitted `:` command for later up/down recall. Skips blanks
/// and immediate repeats (shell-history convention); drops the oldest
/// entry once at capacity. Persists the updated list to disk (best-
/// effort - see `cmd_history_store.save`) so it survives across runs.
pub fn pushCommandHistory(self: *App, text: []const u8) void {
    if (text.len == 0) return;
    if (self.cmd_history.items.len > 0 and
        std.mem.eql(u8, self.cmd_history.items[self.cmd_history.items.len - 1], text))
    {
        self.cmd_history_pos = self.cmd_history.items.len;
        return;
    }
    const owned = self.allocator.dupe(u8, text) catch return;
    if (self.cmd_history.items.len >= self.cmd_history_cap) {
        self.allocator.free(self.cmd_history.orderedRemove(0));
    }
    self.cmd_history.append(self.allocator, owned) catch {
        self.allocator.free(owned);
        return;
    };
    self.cmd_history_pos = self.cmd_history.items.len;
    cmd_history_store.save(self.allocator, self.io, self.cmd_history.items) catch {};
}

/// Step back to the previous history entry.
pub fn commandHistoryPrev(self: *App) void {
    if (self.cmd_history.items.len == 0 or self.cmd_history_pos == 0) return;
    self.cmd_history_pos -= 1;
    self.loadCommandHistory();
}

/// Step forward through history; past the newest entry, blank the
/// prompt (mirrors shell history - you're back to a fresh line).
pub fn commandHistoryNext(self: *App) void {
    if (self.cmd_history_pos >= self.cmd_history.items.len) return;
    self.cmd_history_pos += 1;
    if (self.cmd_history_pos == self.cmd_history.items.len) {
        self.modal.cmd_len = 0;
        self.modal.cmd_cursor = 0;
    } else {
        self.loadCommandHistory();
    }
}

pub fn loadCommandHistory(self: *App) void {
    const text = self.cmd_history.items[self.cmd_history_pos];
    const len = copyTruncated(&self.modal.cmd_buf, text);
    self.modal.cmd_len = len;
    self.modal.cmd_cursor = len;
}

/// Tab-completes the command name (before the first space), or - for a
/// handful of commands whose values come from a small fixed set - the
/// first argument token after it. Requires the cursor to be at the end
/// of the buffer: completing a token with more already typed after it
/// has no obvious insertion point, so mid-line Tab is a no-op.
pub fn completeCommand(self: *App) void {
    const buf = self.modal.cmd_buf[0..self.modal.cmd_len];
    if (buf.len == 0 or self.modal.cmd_cursor != self.modal.cmd_len) return;

    if (std.mem.indexOfScalar(u8, buf, ' ')) |sp| {
        self.completeArgument(buf, sp);
        return;
    }

    self.suggest_popup_open = true;
    // Offer the same in-scope, mnemonic names as the popup. Compatibility
    // aliases and force variants remain dispatchable when typed in full.
    const active = commands_load.activeScope(self);
    var name_buf: [cmds_cap][]const u8 = undefined;
    var n: usize = 0;
    for (self.allCmds()) |c| {
        if (cmd_mod.hiddenFromCompletion(c) or !cmd_mod.visible(c, active)) continue;
        name_buf[n] = c.name;
        n += 1;
    }
    self.cycleCompletion(0, buf, .command_name, name_buf[0..n]);
}

/// Tab-completes the argument after `buf[0..name_end]` against a small
/// fixed value set - drum-kit/synth-preset names, and metronome's
/// on/off keywords. Only fires for the
/// *first* argument token (a trailing space means a second argument is
/// being typed, which has no fixed candidate list here); every other
/// command's arguments (track numbers, dB values, paths, ...) aren't
/// completable from a fixed list, so this is a no-op for those.
pub fn completeArgument(self: *App, buf: []const u8, name_end: usize) void {
    const name = buf[0..name_end];
    const arg = buf[name_end + 1 ..];
    if (std.mem.indexOfScalar(u8, arg, ' ') != null) return;

    var name_buf: [96][]const u8 = undefined;
    if (std.mem.eql(u8, name, "drum-kit")) {
        var n: usize = 0;
        for (ws.dsp.drum_kit.variants) |v| {
            name_buf[n] = v.name;
            n += 1;
        }
        self.cycleCompletion(name_end + 1, arg, .drum_kit, name_buf[0..n]);
    } else if (std.mem.eql(u8, name, "synth-preset")) {
        var n: usize = 0;
        for (self.user_synth_presets.items) |p| {
            if (n >= name_buf.len) break;
            name_buf[n] = p.name;
            n += 1;
        }
        for (ws.dsp.synth_presets.presets) |p| {
            if (n >= name_buf.len) break;
            name_buf[n] = p.name;
            n += 1;
        }
        self.cycleCompletion(name_end + 1, arg, .synth_preset, name_buf[0..n]);
    } else if (std.mem.eql(u8, name, "euclid")) {
        var n: usize = 0;
        for (commands.euclid_presets) |preset| {
            name_buf[n] = preset.name;
            n += 1;
        }
        self.cycleCompletion(name_end + 1, arg, .euclid, name_buf[0..n]);
    } else if (std.mem.eql(u8, name, "metronome")) {
        self.cycleCompletion(name_end + 1, arg, .metronome, &.{ "on", "off" });
    } else if (std.mem.eql(u8, name, "scale") or std.mem.eql(u8, name, "snap-scale")) {
        // First token can be "off", a root pitch class, or a scale-type
        // name (cmdScale accepts either order) - offer all three sets.
        // `:snap-scale` parses its args through cmdScale, so it completes
        // the same way, minus "off" (there's nothing to snap to).
        var n: usize = 0;
        if (std.mem.eql(u8, name, "scale")) {
            name_buf[n] = "off";
            n += 1;
        }
        for (0..12) |pc| {
            name_buf[n] = ws.theory.pitchClassName(@intCast(pc));
            n += 1;
        }
        for (std.meta.tags(ws.theory.ScaleType)) |t| {
            name_buf[n] = t.label();
            n += 1;
        }
        self.cycleCompletion(name_end + 1, arg, .scale, name_buf[0..n]);
    } else if (std.mem.eql(u8, name, "colorscheme") or std.mem.eql(u8, name, "colo")) {
        // TUI also offers "none" (turns the terminal-palette theme back
        // off); the GUI panel skin has no such state.
        const frontend: config_mod.Frontend = if (self.lua_runtime) |rt| rt.frontend else .tui;
        var n: usize = 0;
        if (frontend == .tui) {
            name_buf[n] = "none";
            n += 1;
        }
        for (std.meta.tags(ws.theme_identity.Name)) |t| {
            name_buf[n] = @tagName(t);
            n += 1;
        }
        self.cycleCompletion(name_end + 1, arg, .colorscheme, name_buf[0..n]);
    }
}

/// Sort context for the fuzzy fallback below: ranks candidate indices by how
/// well the value they point at scores against the stem.
const Ranker = struct {
    stem: []const u8,
    values: []const []const u8,

    fn before(self: Ranker, a: usize, b: usize) bool {
        const sa = fuzzy.score(self.stem, self.values[a]) orelse std.math.minInt(i32);
        const sb = fuzzy.score(self.stem, self.values[b]) orelse std.math.minInt(i32);
        return sa > sb;
    }
};

/// Shared by `completeCommand`/`completeArgument`. `current_text` is
/// whatever `values`-completable text is in cmd_buf right now (may
/// already be a candidate from a previous cycle step, not necessarily
/// what the user typed). If it matches an in-progress cycle's
/// `last_written` exactly, we're continuing that cycle: keep filtering
/// on its original `stem` and advance to the next candidate. Otherwise
/// `current_text` itself is treated as a fresh stem (typing, deleting,
/// or switching commands all fail that check, so the next Tab starts
/// over - no separate reset wiring needed). A single match always
/// completes in full plus a trailing space, cycle or not.
pub fn cycleCompletion(self: *App, insert_at: usize, current_text: []const u8, source: TabCycle.Source, values: []const []const u8) void {
    var stem_buf: [modal_mod.ModalInput.max_cmd_len]u8 = undefined;
    var stem: []const u8 = undefined;
    var prev_index: ?usize = null;

    if (self.tab_cycle) |tc| {
        if (tc.insert_at == insert_at and tc.source == source and std.mem.eql(u8, tc.last_written, current_text)) {
            prev_index = tc.index;
            @memcpy(stem_buf[0..tc.stem_len], tc.stem());
            stem = stem_buf[0..tc.stem_len];
        }
    }
    if (prev_index == null) {
        // Fresh stem - snapshot `current_text` before cmd_buf gets
        // overwritten below (it may alias cmd_buf directly).
        const len = copyTruncated(&stem_buf, current_text);
        stem = stem_buf[0..len];
    }

    var match_idx: [cmds_cap]usize = undefined;
    var match_count: usize = 0;
    var has_prefix = false;
    if (source == .command_name) for (values) |v| {
        if (std.mem.startsWith(u8, v, stem)) {
            has_prefix = true;
            break;
        }
    };
    for (values, 0..) |v, i| {
        if (source == .command_name) {
            if (has_prefix) {
                if (!std.mem.startsWith(u8, v, stem)) continue;
            } else if (!fuzzy.matches(stem, v)) continue;
        } else if (!std.mem.startsWith(u8, v, stem)) continue;
        if (match_count < match_idx.len) match_idx[match_count] = i;
        match_count += 1;
    }
    if (match_count == 0) return;

    // The prefix path is already ordered by the command table; the fuzzy
    // fallback is not, so tab would otherwise walk table order and hand back
    // the loosest match first. Deterministic for a given stem, so cycling
    // with repeated tabs still visits each candidate once.
    if (source == .command_name and !has_prefix) {
        std.sort.insertion(usize, match_idx[0..@min(match_count, match_idx.len)], Ranker{ .stem = stem, .values = values }, Ranker.before);
    }

    if (match_count == 1) {
        self.tab_cycle = null;
        const candidate = values[match_idx[0]];
        const new_end = insert_at + candidate.len;
        if (new_end > self.modal.cmd_buf.len) return;
        @memcpy(self.modal.cmd_buf[insert_at..new_end], candidate);
        self.modal.cmd_len = new_end;
        self.modal.cmd_cursor = new_end;
        if (self.modal.cmd_len < self.modal.cmd_buf.len) {
            self.modal.cmd_buf[self.modal.cmd_len] = ' ';
            self.modal.cmd_len += 1;
            self.modal.cmd_cursor += 1;
        }
        return;
    }

    const index = if (prev_index) |pi| (pi + 1) % match_count else 0;
    const candidate = values[match_idx[index]];
    const new_end = insert_at + candidate.len;
    if (new_end > self.modal.cmd_buf.len) return;
    @memcpy(self.modal.cmd_buf[insert_at..new_end], candidate);
    self.modal.cmd_len = new_end;
    self.modal.cmd_cursor = new_end;

    var tc: TabCycle = .{ .insert_at = insert_at, .stem_len = stem.len, .source = source, .index = index, .last_written = candidate };
    @memcpy(tc.stem_buf[0..stem.len], stem);
    self.tab_cycle = tc;
}

/// The in-progress command-name Tab-cycle, but only if `cmd_buf` still
/// holds exactly what that cycle last wrote there (same check
/// `cycleCompletion` uses to decide whether to continue a cycle vs.
/// start fresh) - shared by `suggestionSelected`/`suggestionFilterText`.
/// Returns a pointer into `self.tab_cycle` (not a copy) since
/// `suggestionFilterText` hands back a slice borrowed from `stem_buf`
/// that needs to outlive this call.
pub fn activeCommandCycle(self: *const App) ?*const TabCycle {
    if (self.tab_cycle) |*tc| {
        if (tc.insert_at == 0 and tc.source == .command_name and
            std.mem.eql(u8, tc.last_written, self.modal.cmd_buf[0..self.modal.cmd_len]))
        {
            return tc;
        }
    }
    return null;
}

/// Which match `draw`'s command-name suggestion popup should highlight:
/// otherwise 0 - the top match, matching Neovim's wildmenu highlighting
/// the first candidate before Tab has ever been pressed.
///
/// Re-derive the position from the popup's filtered enumeration rather
/// than coupling rendering to the completion cycle's internal index.
pub fn suggestionSelected(self: *const App, active: cmd_mod.Scope) usize {
    const tc = self.activeCommandCycle() orelse return 0;
    var idx: usize = 0;
    for (self.allCmds()) |c| {
        if (cmd_mod.hiddenFromCompletion(c) or !cmd_mod.visible(c, active)) continue;
        if (!cmd_mod.suggestionMatch(self.allCmds(), c, tc.stem(), active)) continue;
        if (std.mem.eql(u8, c.name, tc.last_written)) return idx;
        idx += 1;
    }
    // The completed candidate is itself hidden from the popup (an
    // alias or bang variant) - nothing in the visible list corresponds
    // to it, so fall back to the top row rather than an index that
    // would highlight an unrelated candidate.
    return 0;
}

/// Text `draw`'s suggestion popup filters candidates against. Tab
/// completion overwrites `cmd_buf` with the candidate name itself (so
/// the buffer is always a valid, submittable command) - filtering the
/// popup on that literal text would collapse it to a single match the
/// instant Tab landed on any candidate, hiding the very list Tab was
/// supposed to reveal. While a cycle is active, filter on its
/// `stem` (what was actually typed) instead; only fall back to the
/// live buffer when there's no cycle to track (plain typing).
pub fn suggestionFilterText(self: *const App) []const u8 {
    if (self.activeCommandCycle()) |tc| return tc.stem();
    return self.modal.cmd_buf[0..self.modal.cmd_len];
}

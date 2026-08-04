//! File browser + recent-projects + bookmarks: open/list/navigate the
//! browser overlay, load whatever it resolves to via commands.zig, and the
//! two smaller pickers (recent projects, bookmarks) that share its key
//! handling shape. Split out of ui/app.zig - App re-exports every method
//! here under its original name so self.openBrowser(...)-style call sites
//! elsewhere in App (and every external app.openBrowser(...) caller) keep
//! compiling unchanged.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const commands = @import("commands.zig");
const bookmark_store = @import("bookmark_store.zig");
const recent_project_store = @import("recent_project_store.zig");

const app_mod = @import("app.zig");
const App = app_mod.App;
const BrowserPurpose = app_mod.BrowserPurpose;
const BrowserEntry = app_mod.BrowserEntry;
const reload_path_buf_len = app_mod.reload_path_buf_len;

pub fn openBrowser(self: *App, purpose: BrowserPurpose) void {
    self.browser_purpose = purpose;
    var expand_buf: [reload_path_buf_len]u8 = undefined;
    const remembers = switch (purpose) {
        .open_project => false,
        else => true,
    };
    const start: []const u8 = if (remembers and self.last_load_dir.len > 0)
        self.last_load_dir.slice()
    else if (self.projectPath()) |p|
        (std.fs.path.dirname(p) orelse ".")
    else if (self.default_browse_dir.len > 0)
        commands.expandHome(&expand_buf, self.default_browse_dir.slice())
    else
        ".";
    self.setBrowserDir(start) catch |e| {
        self.setStatus("browse: cannot open '{s}': {s}", .{ start, @errorName(e) });
        return;
    };
    self.prev_view = self.view;
    self.view = .file_browser;
}

/// Free the current entry list's owned names (keeps the list's capacity).
pub fn freeBrowserEntries(self: *App) void {
    for (self.browser_entries.items) |e| self.allocator.free(e.name);
    self.browser_entries.clearRetainingCapacity();
}

/// Resolve `path` to a canonical absolute directory and (re)list it into
/// `browser_entries`. Builds the new listing before touching any existing
/// state, so a bad path (deleted dir, permission error, …) leaves the
/// browser exactly where it was.
pub fn setBrowserDir(self: *App, path: []const u8) !void {
    const canon = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
    errdefer self.allocator.free(canon);

    var dir = try std.Io.Dir.cwd().openDir(self.io, canon, .{ .iterate = true });
    defer dir.close(self.io);

    var new_entries: std.ArrayListUnmanaged(BrowserEntry) = .empty;
    errdefer {
        for (new_entries.items) |e| self.allocator.free(e.name);
        new_entries.deinit(self.allocator);
    }
    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.name.len == 0 or (!self.file_browser_show_hidden and entry.name[0] == '.')) continue;
        const is_dir = entry.kind == .directory;
        if (!is_dir and !std.ascii.endsWithIgnoreCase(entry.name, self.browser_purpose.ext())) continue;
        const name = try self.allocator.dupe(u8, entry.name);
        errdefer self.allocator.free(name);
        try new_entries.append(self.allocator, .{ .name = name, .is_dir = is_dir });
    }
    std.mem.sort(BrowserEntry, new_entries.items, {}, browserEntryLess);

    self.freeBrowserEntries();
    self.browser_entries.deinit(self.allocator);
    if (self.browser_dir.len > 0) self.allocator.free(self.browser_dir);
    self.browser_dir = canon;
    self.browser_entries = new_entries;
    self.browser_cursor = 0;
    self.browser_scroll = 0;
    self.clearBrowserVisual();
}

/// Directories first, then alphabetical (case-insensitive) within each
/// group - matches `ls`/netrw ordering.
pub fn browserEntryLess(_: void, a: BrowserEntry, b: BrowserEntry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

// zig fmt: off
    /// j/k move, enter/l/space descend into a dir or pick a file, h/backspace
    /// go to the parent dir, g/G jump to the list ends, `~` jumps home,
    /// `v` starts a multi-file selection (pad loads only), esc/q cancel back
    /// to the view that opened the browser.
    pub fn handleBrowserKey(self: *App, key: modal_mod.Key) void {
        if (self.browser_recent_mode) {
            self.handleRecentProjectKey(key);
            return;
        }
        if (self.browser_bookmark_mode) {
            self.handleBookmarkListKey(key);
            return;
        }
        switch (key) {
            // Like every other visual view: the first esc drops the
            // selection, the second leaves.
            .escape => if (self.browser_visual_anchor != null) self.clearBrowserVisual() else self.closeBrowser(),
            .enter => self.browserActivate(),
            .backspace => self.browserGoUp(),
            .char => |c| switch (c) {
                'j' => { if (self.browser_cursor + 1 < self.browser_entries.items.len) self.browser_cursor += 1; },
                'k' => { if (self.browser_cursor > 0) self.browser_cursor -= 1; },
                'g' => self.browser_cursor = 0,
                'G' => self.browser_cursor = self.browser_entries.items.len -| 1,
                'l', ' ' => self.browserActivate(),
                'h' => self.browserGoUp(),
                '~' => {
                    const home_z = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return;
                    const home = std.mem.sliceTo(home_z, 0);
                    self.setBrowserDir(home) catch |e| self.setStatus("browse: {s}", .{@errorName(e)});
                },
                '/' => {
                    self.modal.mode = .search;
                    self.modal.cmd_len = 0;
                    self.modal.cmd_cursor = 0;
                },
                'n' => self.searchBrowser(1),
                'N' => self.searchBrowser(-1),
                'v' => {
                    if (self.browser_purpose != .load_pad) {
                        self.setStatus("visual: only when loading drum pads", .{});
                        return;
                    }
                    if (self.browser_entries.items.len == 0) return;
                    self.browser_visual_anchor = self.browser_cursor;
                    self.modal.mode = .visual;
                    self.setStatus("visual: j/k extend, enter loads into pads", .{});
                },
                'a' => self.auditionBrowserEntry(),
                'b' => self.toggleBookmark(),
                'B' => {
                    if (self.bookmarks.items.len == 0) {
                        self.setStatus("no bookmarks yet - b marks the entry under the cursor", .{});
                        return;
                    }
                    self.browser_bookmark_mode = true;
                    self.bookmark_cursor = @min(self.bookmark_cursor, self.bookmarks.items.len - 1);
                },
                'q' => self.closeBrowser(),
                else => {},
            },
            else => {},
        }
    }

    pub fn openRecentProjects(self: *App) void {
        if (self.recent_projects.items.len == 0) {
            self.setStatus("no recent projects", .{});
            return;
        }
        self.prev_view = self.view;
        self.browser_purpose = .open_project;
        self.browser_recent_mode = true;
        self.recent_project_cursor = 0;
        self.view = .file_browser;
    }

    pub fn handleRecentProjectKey(self: *App, key: modal_mod.Key) void {
        switch (key) {
            .escape => self.closeBrowser(),
            .enter => self.openRecentProject(),
            .char => |c| switch (c) {
                'j' => if (self.recent_project_cursor + 1 < self.recent_projects.items.len) { self.recent_project_cursor += 1; },
                'k' => if (self.recent_project_cursor > 0) { self.recent_project_cursor -= 1; },
                'g' => self.recent_project_cursor = 0,
                'G' => self.recent_project_cursor = self.recent_projects.items.len -| 1,
                'l', ' ' => self.openRecentProject(),
                'q' => self.closeBrowser(),
                else => {},
            },
            else => {},
        }
    }

    pub fn openRecentProject(self: *App) void {
        if (self.recent_project_cursor >= self.recent_projects.items.len) return;
        if (self.dirty) {
            self.setStatus("unsaved changes - :write to save, :edit! to discard", .{});
            return;
        }
        self.requestReload(self.recent_projects.items[self.recent_project_cursor]);
        self.closeBrowser();
    }
    // zig fmt: on

/// `b`: toggle the entry under the browser cursor in/out of `bookmarks`,
/// keyed by absolute path so the same file/dir reached two different ways
/// still dedupes.
pub fn toggleBookmark(self: *App) void {
    if (self.browser_cursor >= self.browser_entries.items.len) return;
    const entry = self.browser_entries.items[self.browser_cursor];
    const joined = std.fs.path.join(self.allocator, &.{ self.browser_dir, entry.name }) catch return;
    defer self.allocator.free(joined);

    for (self.bookmarks.items, 0..) |b, i| {
        if (std.mem.eql(u8, b.path, joined)) {
            self.allocator.free(b.path);
            _ = self.bookmarks.orderedRemove(i);
            self.setStatus("unbookmarked: {s}", .{entry.name});
            bookmark_store.save(self.allocator, self.io, self.bookmarks.items) catch {};
            return;
        }
    }
    const owned = self.allocator.dupe(u8, joined) catch return;
    self.bookmarks.append(self.allocator, .{ .path = owned, .is_dir = entry.is_dir }) catch {
        self.allocator.free(owned);
        return;
    };
    self.setStatus("bookmarked: {s}", .{entry.name});
    bookmark_store.save(self.allocator, self.io, self.bookmarks.items) catch {};
}

// zig fmt: off
    /// Key handling while `browser_bookmark_mode` is showing the bookmark
    /// list instead of the current directory.
    pub fn handleBookmarkListKey(self: *App, key: modal_mod.Key) void {
        switch (key) {
            .escape => self.browser_bookmark_mode = false,
            .enter => self.jumpToBookmark(),
            .char => |c| switch (c) {
                'j' => { if (self.bookmark_cursor + 1 < self.bookmarks.items.len) self.bookmark_cursor += 1; },
                'k' => { if (self.bookmark_cursor > 0) self.bookmark_cursor -= 1; },
                'g' => self.bookmark_cursor = 0,
                'G' => self.bookmark_cursor = self.bookmarks.items.len -| 1,
                'l', ' ' => self.jumpToBookmark(),
                'd' => {
                    if (self.bookmark_cursor >= self.bookmarks.items.len) return;
                    self.allocator.free(self.bookmarks.items[self.bookmark_cursor].path);
                    _ = self.bookmarks.orderedRemove(self.bookmark_cursor);
                    if (self.bookmarks.items.len == 0) self.browser_bookmark_mode = false
                    else self.bookmark_cursor = @min(self.bookmark_cursor, self.bookmarks.items.len - 1);
                    bookmark_store.save(self.allocator, self.io, self.bookmarks.items) catch {};
                },
                'q' => self.browser_bookmark_mode = false,
                else => {},
            },
            else => {},
        }
    }

    /// enter/l/space on a bookmark: directories are opened directly; a
    /// bookmarked file opens its parent directory with the cursor on it if
    /// the current browser purpose's extension filter still shows it (see
    /// setBrowserDir), otherwise the parent directory listing is still a
    /// reasonable landing spot.
    pub fn jumpToBookmark(self: *App) void {
        if (self.bookmark_cursor >= self.bookmarks.items.len) return;
        const bm = self.bookmarks.items[self.bookmark_cursor];
        const dir = if (bm.is_dir) bm.path else (std.fs.path.dirname(bm.path) orelse bm.path);
        self.setBrowserDir(dir) catch |e| {
            self.setStatus("browse: {s}", .{@errorName(e)});
            return;
        };
        if (!bm.is_dir) {
            const base = std.fs.path.basename(bm.path);
            for (self.browser_entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.name, base)) { self.browser_cursor = i; break; }
            }
        }
        self.browser_bookmark_mode = false;
    }
    // zig fmt: on

/// Parent of `browser_dir` (root's parent is itself - nothing to go up to).
pub fn browserGoUp(self: *App) void {
    const parent = std.fs.path.dirname(self.browser_dir) orelse return;
    self.setBrowserDir(parent) catch |e| self.setStatus("browse: {s}", .{@errorName(e)});
}

/// Enter/l/space on the highlighted entry: descend into a directory, or
/// resolve a file against the browser's purpose and close.
pub fn browserActivate(self: *App) void {
    if (self.browser_cursor >= self.browser_entries.items.len) return;
    // A live multi-file selection wins over the single-entry paths
    // below, including descending into a directory the range happens to
    // end on - directories inside the span are skipped, not entered.
    if (self.browser_visual_anchor) |anchor| {
        const lo = @min(anchor, self.browser_cursor);
        const hi = @min(@max(anchor, self.browser_cursor), self.browser_entries.items.len - 1);
        commands.loadPadsFromEntries(self, self.browser_entries.items[lo .. hi + 1]);
        self.closeBrowser();
        return;
    }
    const entry = self.browser_entries.items[self.browser_cursor];
    const joined = std.fs.path.join(self.allocator, &.{ self.browser_dir, entry.name }) catch return;
    defer self.allocator.free(joined);

    if (entry.is_dir) {
        self.setBrowserDir(joined) catch |e| self.setStatus("browse: {s}", .{@errorName(e)});
        return;
    }
    switch (self.browser_purpose) {
        // Only reachable via a non-forced `:e` (openBrowser's sole
        // .open_project caller, commands.editOrRevert) - the dirty
        // refusal that skips there for a given path belongs here
        // instead, since browsing itself was allowed through regardless.
        .open_project => if (self.dirty) {
            self.setStatus("unsaved changes - :write to save, :edit! to discard", .{});
        } else {
            self.requestReload(joined);
        },
        .load_sample => commands.loadSampleFromPath(self, joined),
        .load_pad => |pad| commands.loadPadFromPath(self, pad, joined),
        .load_clip => commands.loadClipFromPath(self, joined),
        .load_slice => commands.loadSliceFromPath(self, joined),
        .load_wavetable => |slot| commands.loadWavetableFromPath(self, slot, joined),
        .load_soundfont => commands.loadSoundfontFromPath(self, joined),
    }
    self.closeBrowser();
}

/// `a`: audition the file under the cursor - the same audition key the
/// pad, slice, preset, and soundfont views use (directories have nothing to
/// play). Retriggering while one is still ringing is fine - the preview
/// Sampler steals its own voice.
pub fn auditionBrowserEntry(self: *App) void {
    if (!self.browser_purpose.canAudition()) {
        self.setStatus("audition unavailable for {s}", .{self.browser_purpose.ext()});
        return;
    }
    if (self.browser_cursor >= self.browser_entries.items.len) return;
    const entry = self.browser_entries.items[self.browser_cursor];
    if (entry.is_dir) return;
    const joined = std.fs.path.join(self.allocator, &.{ self.browser_dir, entry.name }) catch return;
    defer self.allocator.free(joined);
    commands.auditionPath(self, joined);
}

pub fn closeBrowser(self: *App) void {
    _ = self.session.engine.send(.preview_stop);
    self.freeBrowserEntries();
    self.browser_bookmark_mode = false;
    self.browser_recent_mode = false;
    self.clearBrowserVisual();
    self.view = self.prev_view;
}

/// Drop the multi-file selection and the `.visual` mode it put the modal
/// in. Called on esc, on close, and whenever the listing is replaced -
/// the anchor is an index into `browser_entries`, so a new directory
/// makes it meaningless.
pub fn clearBrowserVisual(self: *App) void {
    if (self.browser_visual_anchor == null) return;
    self.browser_visual_anchor = null;
    self.modal.mode = .normal;
}

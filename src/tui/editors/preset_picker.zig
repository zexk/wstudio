//! Preset-picker input + list building. One view serves both preset systems:
//! synth patches (factory dsp/synth_presets.zig + user tui/user_presets.zig,
//! opened with `f` in the synth editor) and drum kits (factory
//! dsp/drum_kit.zig, which carries its own audio, + user
//! tui/user_drum_kits.zig, pad tuning only — see that file's own doc
//! comment; `f` in the drum grid). The render half lives in
//! views/preset_picker.zig; both layers share `buildDisplayRows` so cursor,
//! mouse hit-testing and drawing can't drift — same convention the
//! automation param picker set with buildParamDisplayRows.
//!
//! `/` narrows the list live with the same fuzzy rule `/` search uses
//! everywhere else, matched against a preset's name, category, any genre
//! tag, and its author ("wstudio" for factory content, "user" for saved
//! presets) — so `/trance` filters to a genre and `/user` to your own saves.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const App = @import("../app.zig").App;
const fuzzy = @import("../fuzzy.zig");
const user_presets = @import("../user_presets.zig");
const user_drum_kits = @import("../user_drum_kits.zig");

pub const Kind = enum { synth, drum };

const factory_author = "wstudio";
const user_author = "user";

/// One selectable list entry, unified across the three backing tables
/// (user presets / factory presets / kit variants) so the render, key and
/// mouse layers never re-branch on where a row came from.
pub const Entry = struct {
    name: []const u8,
    category: []const u8,
    /// Factory tables carry "wstudio" at index 0 + genre tags after it
    /// (display skips index 0, matching commands.zig's writeGenres); user
    /// presets have none.
    tags: []const []const u8,
    author: []const u8,
    source: union(enum) { user: usize, factory: usize, kit: usize },
};

pub const DisplayRow = union(enum) {
    header: []const u8,
    entry: Entry,
};

/// Fixed row-buffer cap: every factory preset (~70) plus one header per
/// category plus a generous allowance for user-saved presets. Saves past
/// the cap simply don't list (the `:synth-preset <name>` path still reaches
/// them) rather than growing an allocation per frame.
pub const max_display_rows = 224;

/// The `/` filter narrowing the list right now: the modal search buffer
/// while it's being typed (live narrowing), else the last submitted
/// pattern. Mirrors how the tracks view treats the search register, minus
/// the global n/N repeat, which makes no sense for a filter.
pub fn activeFilter(app: *App) []const u8 {
    if (app.modal.mode == .search and app.view == .preset_picker)
        return app.modal.cmd_buf[0..app.modal.cmd_len];
    return app.preset_filter_buf[0..app.preset_filter_len];
}

fn entryMatches(e: Entry, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (fuzzy.matches(filter, e.name)) return true;
    if (fuzzy.matches(filter, e.category)) return true;
    if (fuzzy.matches(filter, e.author)) return true;
    for (e.tags) |t| {
        if (fuzzy.matches(filter, t)) return true;
    }
    return false;
}

/// The filtered list as printed: synth presets grouped under category
/// headers ("saved" first for user presets, then each factory category in
/// first-appearance order); drum kits the same "saved" header for user
/// kits, then factory variants flat (each variant is already its own
/// category, so a header there would just double every row).
pub fn buildDisplayRows(app: *App, buf: *[max_display_rows]DisplayRow) []DisplayRow {
    const filter = activeFilter(app);
    var n: usize = 0;
    switch (app.preset_picker_kind) {
        .synth => {
            var wrote_header = false;
            for (app.user_synth_presets.items, 0..) |p, i| {
                const e: Entry = .{
                    .name = p.name, .category = "saved", .tags = &.{},
                    .author = user_author, .source = .{ .user = i },
                };
                if (!entryMatches(e, filter)) continue;
                if (!wrote_header) {
                    if (n >= buf.len) return buf[0..n];
                    buf[n] = .{ .header = "saved" };
                    n += 1;
                    wrote_header = true;
                }
                if (n >= buf.len) return buf[0..n];
                buf[n] = .{ .entry = e };
                n += 1;
            }
            // Distinct factory categories in first-appearance order; the
            // table itself interleaves them (presets were appended by
            // genre round, not by role).
            var cats: [16][]const u8 = undefined;
            var cat_count: usize = 0;
            outer: for (ws.dsp.synth_presets.presets) |p| {
                for (cats[0..cat_count]) |c| {
                    if (std.mem.eql(u8, c, p.category)) continue :outer;
                }
                if (cat_count >= cats.len) break;
                cats[cat_count] = p.category;
                cat_count += 1;
            }
            for (cats[0..cat_count]) |cat| {
                wrote_header = false;
                for (ws.dsp.synth_presets.presets, 0..) |p, i| {
                    if (!std.mem.eql(u8, p.category, cat)) continue;
                    const e: Entry = .{
                        .name = p.name, .category = p.category, .tags = p.tags,
                        .author = factory_author, .source = .{ .factory = i },
                    };
                    if (!entryMatches(e, filter)) continue;
                    if (!wrote_header) {
                        if (n >= buf.len) return buf[0..n];
                        buf[n] = .{ .header = cat };
                        n += 1;
                        wrote_header = true;
                    }
                    if (n >= buf.len) return buf[0..n];
                    buf[n] = .{ .entry = e };
                    n += 1;
                }
            }
        },
        .drum => {
            var wrote_header = false;
            for (app.user_drum_kits.items, 0..) |k, i| {
                const e: Entry = .{
                    .name = k.name, .category = "saved", .tags = &.{},
                    .author = user_author, .source = .{ .user = i },
                };
                if (!entryMatches(e, filter)) continue;
                if (!wrote_header) {
                    if (n >= buf.len) return buf[0..n];
                    buf[n] = .{ .header = "saved" };
                    n += 1;
                    wrote_header = true;
                }
                if (n >= buf.len) return buf[0..n];
                buf[n] = .{ .entry = e };
                n += 1;
            }
            for (ws.dsp.drum_kit.variants, 0..) |v, i| {
                const e: Entry = .{
                    .name = v.name, .category = v.category, .tags = v.tags,
                    .author = factory_author, .source = .{ .kit = i },
                };
                if (!entryMatches(e, filter)) continue;
                if (n >= buf.len) return buf[0..n];
                buf[n] = .{ .entry = e };
                n += 1;
            }
        },
    }
    return buf[0..n];
}

pub fn entryCountOf(rows: []const DisplayRow) usize {
    var n: usize = 0;
    for (rows) |r| {
        if (r == .entry) n += 1;
    }
    return n;
}

fn entryCount(app: *App) usize {
    var buf: [max_display_rows]DisplayRow = undefined;
    return entryCountOf(buildDisplayRows(app, &buf));
}

/// Open the picker over `track`'s presets. The filter starts clean each
/// time (a stale narrowing from the last visit would look like missing
/// presets); escape returns to whichever view opened it.
pub fn open(app: *App, kind: Kind, track: u16) void {
    app.preset_picker_kind = kind;
    app.preset_picker_track = track;
    app.preset_picker_return = app.view;
    app.preset_picker_cursor = 0;
    app.preset_picker_scroll = 0;
    app.preset_filter_len = 0;
    app.view = .preset_picker;
}

pub fn close(app: *App) void {
    app.view = app.preset_picker_return;
}

fn moveCursor(app: *App, delta: i32) void {
    const count = entryCount(app);
    if (count == 0) return;
    const cur: i64 = @intCast(@min(app.preset_picker_cursor, count - 1));
    app.preset_picker_cursor = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(count - 1))));
}

/// j/k move, g/G jump, enter/space apply, `/` is routed to the modal search
/// prompt by App.handleKey before this runs. Esc/q close without applying.
pub fn handleKey(app: *App, key: modal_mod.Key) void {
    switch (key) {
        .escape => close(app),
        .enter => applySelected(app),
        .char => |c| switch (c) {
            'q' => close(app),
            'j' => moveCursor(app, 1),
            'k' => moveCursor(app, -1),
            'g' => app.preset_picker_cursor = 0,
            'G' => app.preset_picker_cursor = entryCount(app) -| 1,
            'd' => deleteSelected(app),
            ' ' => applySelected(app),
            else => {},
        },
        else => {},
    }
}

/// Click an entry row to select + apply it (headers ignore the click);
/// scroll moves the selection — same shape as the other pickers' mouse
/// handlers. Row math mirrors views/preset_picker.zig's layout: title(1) +
/// blank(1) preamble, then the display rows offset by the scroll.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize) void {
    switch (ev.kind) {
        .press => {
            if (row < 2) return;
            var buf: [max_display_rows]DisplayRow = undefined;
            const rows_list = buildDisplayRows(app, &buf);
            const idx = app.preset_picker_scroll + (row - 2);
            if (idx >= rows_list.len) return;
            var n: usize = 0;
            for (rows_list, 0..) |r, ri| switch (r) {
                .entry => {
                    if (ri == idx) {
                        app.preset_picker_cursor = n;
                        applySelected(app);
                        return;
                    }
                    n += 1;
                },
                .header => if (ri == idx) return,
            };
        },
        .scroll_up => moveCursor(app, -1),
        .scroll_down => moveCursor(app, 1),
        else => {},
    }
}

fn targetSynth(app: *App) ?*ws.dsp.PolySynth {
    if (app.preset_picker_track >= app.session.racks.items.len) return null;
    return switch (app.session.racks.items[app.preset_picker_track].instrument) {
        .poly_synth => |*s| s,
        else => null,
    };
}

fn targetDrum(app: *App) ?*ws.dsp.DrumMachine {
    if (app.preset_picker_track >= app.session.racks.items.len) return null;
    return switch (app.session.racks.items[app.preset_picker_track].instrument) {
        .drum_machine => |*dm| dm,
        else => null,
    };
}

/// The entry the cursor sits on within the filtered rows, if any.
fn selectedEntry(rows_list: []const DisplayRow, cursor: usize) ?Entry {
    var n: usize = 0;
    for (rows_list) |r| switch (r) {
        .entry => |e| {
            if (n == cursor) return e;
            n += 1;
        },
        .header => {},
    };
    return null;
}

/// d: delete the highlighted user-saved preset/kit, from the list and from
/// its config file (same key the file browser's bookmark list uses).
/// Factory content refuses. The picker stays open so several stale saves
/// can go in one visit.
fn deleteSelected(app: *App) void {
    var buf: [max_display_rows]DisplayRow = undefined;
    const rows_list = buildDisplayRows(app, &buf);
    const chosen = selectedEntry(rows_list, app.preset_picker_cursor) orelse return;
    if (chosen.source != .user) {
        app.setStatus("only saved presets/kits can be deleted", .{});
        return;
    }
    // The status line needs the name after remove() has freed it.
    var name_buf: [64]u8 = undefined;
    const shown_len = @min(chosen.name.len, name_buf.len);
    @memcpy(name_buf[0..shown_len], chosen.name[0..shown_len]);
    switch (app.preset_picker_kind) {
        .synth => _ = user_presets.remove(app.allocator, app.io, &app.user_synth_presets, chosen.name) catch |e| {
            app.setStatus("delete: {s}", .{@errorName(e)});
            return;
        },
        .drum => _ = user_drum_kits.remove(app.allocator, app.io, &app.user_drum_kits, chosen.name) catch |e| {
            app.setStatus("delete: {s}", .{@errorName(e)});
            return;
        },
    }
    app.preset_picker_cursor = @min(app.preset_picker_cursor, entryCount(app) -| 1);
    app.setStatus("deleted preset: {s}", .{name_buf[0..shown_len]});
}

/// Apply the highlighted entry to the picker's target track — the same
/// paths `:synth-preset`/`:drum-kit` take (PolySynth.applyPatch /
/// DrumMachine.loadKitVariant/applyPadTune), then bounce back to the
/// opening view. An apply error keeps the picker open with the error in the
/// status row.
pub fn applySelected(app: *App) void {
    var buf: [max_display_rows]DisplayRow = undefined;
    const rows_list = buildDisplayRows(app, &buf);
    const chosen = selectedEntry(rows_list, app.preset_picker_cursor) orelse return;

    switch (chosen.source) {
        .user => |i| switch (app.preset_picker_kind) {
            .synth => {
                const s = targetSynth(app) orelse return;
                s.applyPatch(app.user_synth_presets.items[i].patch);
                app.setStatus("synth preset: {s} (saved)", .{chosen.name});
            },
            .drum => {
                const dm = targetDrum(app) orelse return;
                dm.applyPadTune(&app.user_drum_kits.items[i].pads);
                app.setStatus("drum kit: {s} (saved)", .{chosen.name});
            },
        },
        .factory => |i| {
            const s = targetSynth(app) orelse return;
            s.applyPatch(ws.dsp.synth_presets.presets[i].patch);
            app.setStatus("synth preset: {s}", .{chosen.name});
        },
        .kit => |i| {
            const dm = targetDrum(app) orelse return;
            dm.loadKitVariant(&ws.dsp.drum_kit.variants[i]) catch |e| {
                app.setStatus("drum-kit: {s}", .{@errorName(e)});
                return;
            };
            app.setStatus("drum kit: {s}", .{chosen.name});
        },
    }
    app.dirty = true;
    close(app);
}

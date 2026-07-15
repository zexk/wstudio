//! Comptime-static section/param layout for the synth editor's MAIN and MOD
//! subviews: single source of truth for which engine param ids belong to
//! which on-screen card, what order those cards appear in, and how they
//! pack into 1/2/3 columns by terminal width. Column packing, cursor
//! traversal order, and mouse hit-testing are all *derived* from this data
//! at comptime, replacing the old hand-synced trio (paramColRow/paramRow/
//! sectionStarts in editors/synth.zig) that had no compiler check keeping
//! them in agreement.
//!
//! Engine param ids never move (persistence + automation reference them —
//! see dsp/synth.zig's param_specs), so this file is free to regroup them
//! however reads best; only the *labels and grouping* are UI concerns.
//!
//! FX intentionally has no table here: its section set depends on runtime
//! state (fx_order + each unit's on/off flag), so it keeps its existing
//! dynamic machinery in editors/synth.zig (fxFirstId/fxIdCount/fxOn) rather
//! than forcing a runtime-shaped subview through a comptime-static one.

const std = @import("std");
const style = @import("style.zig");

pub const ParamEntry = struct {
    id: u8,
    label: []const u8,
    /// Consecutive ids folded into one on-screen row — 1 for every normal
    /// param, 3 for a mod-matrix slot (source/dest/depth). `w`/`b` move the
    /// cursor within `[id, id+fields)`; `j`/`k` treat the whole entry as one
    /// stop, preserving the in-entry offset (which field was focused) when
    /// landing on the next entry.
    fields: u8 = 1,
};

pub const SectionDef = struct {
    title: []const u8,
    color: []const u8,
    params: []const ParamEntry,
};

// zig fmt: off
pub const main_sections = [_]SectionDef{
    .{ .title = "OSC A", .color = style.acc, .params = &.{
        .{ .id = 0,  .label = "waveform" },  .{ .id = 1,  .label = "pls.width" },
        .{ .id = 2,  .label = "detune" },    .{ .id = 3,  .label = "unison" },
        .{ .id = 4,  .label = "uni.det" },   .{ .id = 5,  .label = "spread" },
        .{ .id = 39, .label = "uni.mode" },  .{ .id = 41, .label = "warp" },
        .{ .id = 42, .label = "warp amt" },  .{ .id = 185, .label = "wt.pos" },
    } },
    .{ .title = "OSC B", .color = style.acc, .params = &.{
        .{ .id = 6,  .label = "on/off" },    .{ .id = 7,  .label = "waveform" },
        .{ .id = 8,  .label = "pls.width" }, .{ .id = 9,  .label = "semi" },
        .{ .id = 10, .label = "detune" },    .{ .id = 11, .label = "level" },
        .{ .id = 12, .label = "unison" },    .{ .id = 13, .label = "uni.det" },
        .{ .id = 40, .label = "uni.mode" },  .{ .id = 43, .label = "warp" },
        .{ .id = 44, .label = "warp amt" },  .{ .id = 186, .label = "wt.pos" },
    } },
    .{ .title = "OSC C", .color = style.acc, .params = &.{
        .{ .id = 50, .label = "on/off" },    .{ .id = 51, .label = "waveform" },
        .{ .id = 52, .label = "pls.width" }, .{ .id = 53, .label = "semi" },
        .{ .id = 54, .label = "detune" },    .{ .id = 55, .label = "level" },
        .{ .id = 56, .label = "unison" },    .{ .id = 57, .label = "uni.det" },
        .{ .id = 58, .label = "uni.mode" },  .{ .id = 187, .label = "wt.pos" },
    } },
    .{ .title = "SUB", .color = style.acc, .params = &.{
        .{ .id = 34, .label = "level" }, .{ .id = 35, .label = "shape" },
    } },
    .{ .title = "NOISE", .color = style.acc, .params = &.{
        .{ .id = 36, .label = "level" }, .{ .id = 37, .label = "color" },
    } },
    .{ .title = "MOD  (A \u{2194} B)", .color = style.mag, .params = &.{
        .{ .id = 14, .label = "mode" }, .{ .id = 15, .label = "amount" },
    } },
    .{ .title = "FILTER 1", .color = style.yel, .params = &.{
        .{ .id = 20, .label = "type" }, .{ .id = 21, .label = "cutoff" }, .{ .id = 22, .label = "res" },
    } },
    .{ .title = "FILTER 2", .color = style.yel, .params = &.{
        .{ .id = 45, .label = "on/off" }, .{ .id = 46, .label = "type" },
        .{ .id = 47, .label = "cutoff" }, .{ .id = 48, .label = "res" }, .{ .id = 49, .label = "routing" },
    } },
    .{ .title = "AMP ENV", .color = style.grn, .params = &.{
        .{ .id = 16, .label = "attack" }, .{ .id = 17, .label = "decay" },
        .{ .id = 18, .label = "sustain" }, .{ .id = 19, .label = "release" },
    } },
    .{ .title = "FILTER ENV", .color = style.grn, .params = &.{
        .{ .id = 24, .label = "f.attack" }, .{ .id = 25, .label = "f.decay" },
        .{ .id = 26, .label = "f.sustain" }, .{ .id = 27, .label = "f.release" },
    } },
    .{ .title = "VOICE", .color = style.blu, .params = &.{
        .{ .id = 32, .label = "mode" }, .{ .id = 33, .label = "glide" },
    } },
    .{ .title = "ARP", .color = style.bcyn, .params = &.{
        .{ .id = 116, .label = "on/off" }, .{ .id = 117, .label = "mode" },
        .{ .id = 118, .label = "octaves" }, .{ .id = 119, .label = "rate" },
        .{ .id = 120, .label = "gate" }, .{ .id = 121, .label = "hold" },
    } },
    .{ .title = "OUT", .color = style.bcyn, .params = &.{
        .{ .id = 38, .label = "gain" },
    } },
};

pub const mod_sections = [_]SectionDef{
    .{ .title = "MATRIX", .color = style.mag, .params = &.{
        .{ .id = 59, .label = "1", .fields = 3 }, .{ .id = 62, .label = "2", .fields = 3 },
        .{ .id = 65, .label = "3", .fields = 3 }, .{ .id = 68, .label = "4", .fields = 3 },
        .{ .id = 71, .label = "5", .fields = 3 }, .{ .id = 74, .label = "6", .fields = 3 },
        .{ .id = 77, .label = "7", .fields = 3 }, .{ .id = 80, .label = "8", .fields = 3 },
    } },
    .{ .title = "LFO 1", .color = style.mag, .params = &.{
        .{ .id = 28, .label = "shape" }, .{ .id = 29, .label = "rate" },
    } },
    .{ .title = "LFO 2", .color = style.mag, .params = &.{
        .{ .id = 95, .label = "shape" }, .{ .id = 96, .label = "rate" },
    } },
    .{ .title = "LFO 3", .color = style.mag, .params = &.{
        .{ .id = 97, .label = "shape" }, .{ .id = 98, .label = "rate" },
    } },
    .{ .title = "ENV 3", .color = style.grn, .params = &.{
        .{ .id = 122, .label = "attack" }, .{ .id = 123, .label = "decay" },
        .{ .id = 124, .label = "sustain" }, .{ .id = 125, .label = "release" },
    } },
    .{ .title = "MACROS", .color = style.bcyn, .params = &.{
        .{ .id = 99, .label = "macro 1" }, .{ .id = 100, .label = "macro 2" },
        .{ .id = 101, .label = "macro 3" }, .{ .id = 102, .label = "macro 4" },
    } },
};
// zig fmt: on

// ---------------------------------------------------------------------------
// Comptime column packing
// ---------------------------------------------------------------------------

pub const Placement = struct { col: usize, row0: usize };

/// Greedy shortest-column-first packing, evaluated at comptime (both
/// `sections` and `num_cols` are always compile-time known — see
/// `main_order_*`/`mod_order_*` below). `row0` is the row within its column
/// (0-based) where the section's own header lands; each section occupies a
/// header, its params, and one blank row that separates adjacent cards.
fn packColumns(comptime sections: []const SectionDef, comptime num_cols: usize) [sections.len]Placement {
    var col_h = [_]usize{0} ** num_cols;
    var out: [sections.len]Placement = undefined;
    for (sections, 0..) |sec, i| {
        var best: usize = 0;
        for (1..num_cols) |c| {
            if (col_h[c] < col_h[best]) best = c;
        }
        out[i] = .{ .col = best, .row0 = col_h[best] };
        col_h[best] += sec.params.len + 2;
    }
    return out;
}

fn columnHeights(comptime sections: []const SectionDef, comptime placements: [sections.len]Placement, comptime num_cols: usize) [num_cols]usize {
    var h = [_]usize{0} ** num_cols;
    for (sections, 0..) |sec, i| {
        const end = placements[i].row0 + sec.params.len + 2;
        if (end > h[placements[i].col]) h[placements[i].col] = end;
    }
    return h;
}

fn totalEntries(comptime sections: []const SectionDef) usize {
    var n: usize = 0;
    for (sections) |s| n += s.params.len;
    return n;
}

/// One param entry, resolved to its on-screen position. `col`/`row` are
/// used both by the renderer (which column's temp buffer to write into, and
/// at which line) and by mouse hit-testing (reverse col/row -> id lookup);
/// `section` is the index into the owning `SectionDef` array, used for
/// `{`/`}` section jumps and for looking up the section's title/color.
pub const PositionedEntry = struct {
    id: u8,
    label: []const u8,
    fields: u8,
    col: usize,
    row: usize,
    section: usize,
};

/// Column-major traversal order: every column's sections in placement order
/// (which is already row0-increasing within a column, since `packColumns`
/// only ever appends to the currently-shortest column), then every entry
/// within a section in declared order. This is the array `j`/`k`/`g`/`G`/
/// `{`/`}` and the renderer all walk — there is no separate "wide" vs
/// "narrow" order, the 1-column bucket's order *is* today's narrow-mode
/// order.
fn computeOrder(comptime sections: []const SectionDef, comptime placements: [sections.len]Placement, comptime num_cols: usize) [totalEntries(sections)]PositionedEntry {
    var out: [totalEntries(sections)]PositionedEntry = undefined;
    var n: usize = 0;
    for (0..num_cols) |col| {
        for (sections, 0..) |sec, si| {
            if (placements[si].col != col) continue;
            for (sec.params, 0..) |p, j| {
                out[n] = .{
                    .id = p.id,
                    .label = p.label,
                    .fields = p.fields,
                    .col = col,
                    .row = placements[si].row0 + 1 + j,
                    .section = si,
                };
                n += 1;
            }
        }
    }
    return out;
}

const main_placements_1 = packColumns(&main_sections, 1);
const main_placements_2 = packColumns(&main_sections, 2);
const main_placements_3 = packColumns(&main_sections, 3);
pub const main_order_1 = computeOrder(&main_sections, main_placements_1, 1);
pub const main_order_2 = computeOrder(&main_sections, main_placements_2, 2);
pub const main_order_3 = computeOrder(&main_sections, main_placements_3, 3);
pub const main_heights_1 = columnHeights(&main_sections, main_placements_1, 1);
pub const main_heights_2 = columnHeights(&main_sections, main_placements_2, 2);
pub const main_heights_3 = columnHeights(&main_sections, main_placements_3, 3);

const mod_placements_1 = packColumns(&mod_sections, 1);
const mod_placements_2 = packColumns(&mod_sections, 2);
const mod_placements_3 = packColumns(&mod_sections, 3);
pub const mod_order_1 = computeOrder(&mod_sections, mod_placements_1, 1);
pub const mod_order_2 = computeOrder(&mod_sections, mod_placements_2, 2);
pub const mod_order_3 = computeOrder(&mod_sections, mod_placements_3, 3);
pub const mod_heights_1 = columnHeights(&mod_sections, mod_placements_1, 1);
pub const mod_heights_2 = columnHeights(&mod_sections, mod_placements_2, 2);
pub const mod_heights_3 = columnHeights(&mod_sections, mod_placements_3, 3);

/// Column-count bucket for a given terminal width. 108/160 mirror the old
/// `two_col_min_cols` threshold (kept) plus a new 3-column tier for very
/// wide terminals.
pub fn numCols(cols: usize) usize {
    if (cols >= 160) return 3;
    if (cols >= 108) return 2;
    return 1;
}

pub fn colWidth(cols: usize, n: usize) usize {
    return cols / n;
}

pub fn mainOrder(n: usize) []const PositionedEntry {
    return switch (n) {
        1 => &main_order_1,
        2 => &main_order_2,
        else => &main_order_3,
    };
}

pub fn mainHeights(n: usize) []const usize {
    return switch (n) {
        1 => &main_heights_1,
        2 => &main_heights_2,
        else => &main_heights_3,
    };
}

pub fn modOrder(n: usize) []const PositionedEntry {
    return switch (n) {
        1 => &mod_order_1,
        2 => &mod_order_2,
        else => &mod_order_3,
    };
}

pub fn modHeights(n: usize) []const usize {
    return switch (n) {
        1 => &mod_heights_1,
        2 => &mod_heights_2,
        else => &mod_heights_3,
    };
}

// ---------------------------------------------------------------------------
// Navigation primitives — shared by MAIN and MOD (FX keeps its own
// fx_order-aware walk in editors/synth.zig; these operate on whichever
// `[]const PositionedEntry` the caller resolved via mainOrder/modOrder).
// ---------------------------------------------------------------------------

pub fn indexContaining(order: []const PositionedEntry, id: u8) ?usize {
    for (order, 0..) |pe, i| {
        if (id >= pe.id and id < pe.id + pe.fields) return i;
    }
    return null;
}

/// `j`/`k`/`g`/`G`: move by whole entries (rows), preserving which field of
/// a multi-field entry (a mod-matrix slot) was focused when possible.
pub fn moveEntry(order: []const PositionedEntry, cursor: u8, delta: i32) u8 {
    if (order.len == 0) return cursor;
    const idx = indexContaining(order, cursor) orelse 0;
    const offset = cursor - order[idx].id;
    const next: usize = @intCast(std.math.clamp(@as(i32, @intCast(idx)) + delta, 0, @as(i32, @intCast(order.len - 1))));
    const e = order[next];
    return e.id + @min(offset, e.fields - 1);
}

/// `w`/`b`: move within the current entry's `[id, id+fields)` span. A no-op
/// for every `fields == 1` entry, so it's safe to bind unconditionally
/// rather than only "when in the matrix".
pub fn moveField(order: []const PositionedEntry, cursor: u8, delta: i32) u8 {
    const idx = indexContaining(order, cursor) orelse return cursor;
    const e = order[idx];
    const off = std.math.clamp(@as(i32, cursor) - @as(i32, e.id) + delta, 0, @as(i32, e.fields) - 1);
    return e.id + @as(u8, @intCast(off));
}

/// `{`/`}`: jump to the next/previous section's first entry. No wrap past
/// either end (matches the old sectionStarts-based behavior) — pressing
/// backward while already on a section's first entry goes to the *previous*
/// section's first entry instead of no-op'ing, exactly like vim's `{`.
pub fn jumpSection(order: []const PositionedEntry, cursor: u8, forward: bool) u8 {
    if (order.len == 0) return cursor;
    const idx = indexContaining(order, cursor) orelse 0;
    const cur_section = order[idx].section;
    if (forward) {
        var i = idx;
        while (i < order.len and order[i].section == cur_section) : (i += 1) {}
        return if (i < order.len) order[i].id else cursor;
    }
    var start = idx;
    while (start > 0 and order[start - 1].section == cur_section) : (start -= 1) {}
    if (idx != start) return order[start].id;
    if (start == 0) return order[0].id;
    const prev_section = order[start - 1].section;
    var pstart = start - 1;
    while (pstart > 0 and order[pstart - 1].section == prev_section) : (pstart -= 1) {}
    return order[pstart].id;
}

pub fn firstEntry(order: []const PositionedEntry) u8 {
    return if (order.len > 0) order[0].id else 0;
}

pub fn lastEntry(order: []const PositionedEntry) u8 {
    return if (order.len > 0) order[order.len - 1].id else 0;
}

// ---------------------------------------------------------------------------
// Completeness check — every id MAIN/MOD are supposed to own appears
// exactly once between them, and none collide with an id owned by FX, a
// dead (retired) id, or an FX reorder-handle id. A bad regroup (dropped id,
// duplicated id, accidental overlap with FX's range) fails the *build*,
// not just a test run.
// ---------------------------------------------------------------------------

comptime {
    @setEvalBranchQuota(4000);
    var seen = [_]bool{false} ** 195;
    for (main_sections) |sec| {
        for (sec.params) |p| {
            var f: u8 = 0;
            while (f < p.fields) : (f += 1) {
                if (seen[p.id + f]) @compileError("synth_layout: duplicate id in main_sections");
                seen[p.id + f] = true;
            }
        }
    }
    for (mod_sections) |sec| {
        for (sec.params) |p| {
            var f: u8 = 0;
            while (f < p.fields) : (f += 1) {
                if (seen[p.id + f]) @compileError("synth_layout: id claimed by both main_sections and mod_sections");
                seen[p.id + f] = true;
            }
        }
    }
    // Ids owned elsewhere: dead/retired (23, 30-31), FX unit params +
    // their reorder handles (mirrors editors/synth.zig's deadParam/
    // inSubview(.fx)/reorderIdFor — verified against that file's ranges).
    const excluded = [_][2]u16{
        .{ 23, 23 },   .{ 30, 31 },   .{ 83, 94 },   .{ 103, 115 },
        .{ 126, 136 }, .{ 137, 143 }, .{ 144, 160 }, .{ 161, 166 },
        .{ 167, 175 }, .{ 176, 180 }, .{ 181, 184 }, .{ 188, 194 },
    };
    for (excluded) |range| {
        var id = range[0];
        while (id <= range[1]) : (id += 1) {
            if (seen[id]) @compileError("synth_layout: id claimed by main/mod but is FX/dead/reorder-owned");
            seen[id] = true;
        }
    }
    for (seen, 0..) |s, id| {
        if (!s) @compileError(std.fmt.comptimePrint(
            "synth_layout: id {d} not covered by main_sections, mod_sections, or the FX/dead/reorder exclusion list",
            .{id},
        ));
    }
}

//! Comptime-static section/param layout for the synth editor's MAIN and MOD
//! subviews: single source of truth for which engine param ids belong to
//! which on-screen card, what order those cards appear in, and how they
//! pack into 1/2/3 columns by terminal width. Column packing, cursor
//! traversal order, and mouse hit-testing are all *derived* from this data
//! at comptime, replacing the old hand-synced trio (paramColRow/paramRow/
//! sectionStarts in editors/synth.zig) that had no compiler check keeping
//! them in agreement.
//!
//! Engine param ids never move (persistence + automation reference them -
//! see dsp/synth.zig's param_specs), so this file is free to regroup them
//! however reads best; only the *labels and grouping* are UI concerns.
//!
//! FX intentionally has no table here: its section set depends on runtime
//! state (fx_order + each unit's on/off flag), so it keeps its existing
//! dynamic machinery in editors/synth.zig (fxFirstId/fxIdCount/fxOn) rather
//! than forcing a runtime-shaped subview through a comptime-static one.

const std = @import("std");
const ws = @import("wstudio");

const mod_source_names = [_][]const u8{ "off", "lfo", "fenv", "aenv", "vel", "key", "whl", "lfo2", "lfo3", "mc1", "mc2", "mc3", "mc4", "env3" };

pub fn modSourceName(source: anytype) []const u8 {
    return mod_source_names[@intFromEnum(source)];
}

pub const ParamEntry = struct {
    id: u16,
    label: []const u8,
    /// Consecutive ids folded into one on-screen row - 1 for every normal
    /// param, 3 for a mod-matrix slot (source/dest/depth). `w`/`b` move the
    /// cursor within `[id, id+fields)`; `j`/`k` treat the whole entry as one
    /// stop, preserving the in-entry offset (which field was focused) when
    /// landing on the next entry.
    fields: u8 = 1,
};

/// What the section does to the signal, not what color to paint it - each
/// frontend maps this onto its own palette (the GUI's `sectionColor`).
/// Replaces a `color: []const u8` field holding raw ANSI escapes that no
/// renderer ever actually read (the TUI's `sec*` functions hand-write their
/// own), so the GUI was left hashing the section *index* into an accent.
pub const Tone = enum { source, filter, env, mod, util };

pub const SectionDef = struct {
    title: []const u8,
    tone: Tone,
    /// Related section group. Bands must be declared in ascending order.
    band: u8,
    params: []const ParamEntry,
};

/// One slot entry (source/dest/depth) plus one polarity toggle per matrix
/// row. Ids come from `PolySynth` itself rather than being re-derived here:
/// the row count and both id bases live there, and a layout that guessed
/// them would silently disagree the next time the matrix grows.
const max_mod_rows = ws.dsp.PolySynth.max_mod_rows;
const matrix_params = blk: {
    @setEvalBranchQuota(30_000);
    var out: [max_mod_rows * 2]ParamEntry = undefined;
    for (0..max_mod_rows) |row| {
        const label = std.fmt.comptimePrint("{d}", .{row + 1});
        out[row * 2] = .{ .id = ws.dsp.PolySynth.matrixParamId(row, 0), .label = label, .fields = 3 };
        out[row * 2 + 1] = .{
            .id = @intCast(ws.dsp.PolySynth.mod_unipolar_id_base + row),
            .label = std.fmt.comptimePrint("{s} pol", .{label}),
        };
    }
    break :blk out;
};

// zig fmt: off
pub const main_sections = [_]SectionDef{
    .{ .title = "OSC A", .tone = .source, .band = 0, .params = &.{
        .{ .id = 0,  .label = "waveform" },  .{ .id = 1,  .label = "pls.width" },
        .{ .id = 2,  .label = "detune" },    .{ .id = 3,  .label = "unison" },
        .{ .id = 4,  .label = "uni.det" },   .{ .id = 5,  .label = "spread" },
        .{ .id = 39, .label = "uni.mode" },  .{ .id = 41, .label = "warp" },
        .{ .id = 42, .label = "warp amt" },  .{ .id = 185, .label = "wt.pos" },
    } },
    .{ .title = "OSC B", .tone = .source, .band = 0, .params = &.{
        .{ .id = 6,  .label = "on/off" },    .{ .id = 7,  .label = "waveform" },
        .{ .id = 8,  .label = "pls.width" }, .{ .id = 9,  .label = "semi" },
        .{ .id = 10, .label = "detune" },    .{ .id = 11, .label = "level" },
        .{ .id = 12, .label = "unison" },    .{ .id = 13, .label = "uni.det" },
        .{ .id = 40, .label = "uni.mode" },  .{ .id = 43, .label = "warp" },
        .{ .id = 44, .label = "warp amt" },  .{ .id = 186, .label = "wt.pos" },
    } },
    .{ .title = "OSC C", .tone = .source, .band = 0, .params = &.{
        .{ .id = 50, .label = "on/off" },    .{ .id = 51, .label = "waveform" },
        .{ .id = 52, .label = "pls.width" }, .{ .id = 53, .label = "semi" },
        .{ .id = 54, .label = "detune" },    .{ .id = 55, .label = "level" },
        .{ .id = 56, .label = "unison" },    .{ .id = 57, .label = "uni.det" },
        .{ .id = 58, .label = "uni.mode" },  .{ .id = 187, .label = "wt.pos" },
    } },
    .{ .title = "SUB", .tone = .source, .band = 1, .params = &.{
        .{ .id = 34, .label = "level" }, .{ .id = 35, .label = "shape" },
    } },
    .{ .title = "NOISE", .tone = .source, .band = 1, .params = &.{
        .{ .id = 36, .label = "level" }, .{ .id = 37, .label = "color" },
    } },
    .{ .title = "MOD  (A \u{2194} B)", .tone = .mod, .band = 1, .params = &.{
        .{ .id = 14, .label = "mode" }, .{ .id = 15, .label = "amount" },
    } },
    .{ .title = "FILTER 1", .tone = .filter, .band = 2, .params = &.{
        .{ .id = 20, .label = "type" }, .{ .id = 21, .label = "cutoff" }, .{ .id = 22, .label = "res" },
    } },
    .{ .title = "FILTER 2", .tone = .filter, .band = 2, .params = &.{
        .{ .id = 45, .label = "on/off" }, .{ .id = 46, .label = "type" },
        .{ .id = 47, .label = "cutoff" }, .{ .id = 48, .label = "res" }, .{ .id = 49, .label = "routing" },
    } },
    .{ .title = "AMP ENV", .tone = .env, .band = 3, .params = &.{
        .{ .id = 16, .label = "attack" }, .{ .id = 17, .label = "decay" },
        .{ .id = 18, .label = "sustain" }, .{ .id = 19, .label = "release" },
    } },
    .{ .title = "FILTER ENV", .tone = .env, .band = 3, .params = &.{
        .{ .id = 24, .label = "f.attack" }, .{ .id = 25, .label = "f.decay" },
        .{ .id = 26, .label = "f.sustain" }, .{ .id = 27, .label = "f.release" },
    } },
    .{ .title = "VOICE", .tone = .util, .band = 4, .params = &.{
        .{ .id = 32, .label = "mode" }, .{ .id = 33, .label = "glide" },
    } },
    .{ .title = "ARP", .tone = .util, .band = 4, .params = &.{
        .{ .id = 116, .label = "on/off" }, .{ .id = 117, .label = "mode" },
        .{ .id = 118, .label = "octaves" }, .{ .id = 119, .label = "rate" },
        .{ .id = 268, .label = "sync" },
        .{ .id = 120, .label = "gate" }, .{ .id = 121, .label = "hold" },
    } },
    .{ .title = "OUT", .tone = .util, .band = 4, .params = &.{
        .{ .id = 38, .label = "gain" },
    } },
};

pub const mod_sections = [_]SectionDef{
    .{ .title = "LFO 1", .tone = .mod, .band = 0, .params = &.{
        .{ .id = 28, .label = "shape" }, .{ .id = 29, .label = "rate" },
        .{ .id = 256, .label = "sync" }, .{ .id = 259, .label = "retrig" },
        .{ .id = 262, .label = "phase" }, .{ .id = 265, .label = "slew" },
    } },
    .{ .title = "LFO 2", .tone = .mod, .band = 0, .params = &.{
        .{ .id = 95, .label = "shape" }, .{ .id = 96, .label = "rate" },
        .{ .id = 257, .label = "sync" }, .{ .id = 260, .label = "retrig" },
        .{ .id = 263, .label = "phase" }, .{ .id = 266, .label = "slew" },
    } },
    .{ .title = "LFO 3", .tone = .mod, .band = 0, .params = &.{
        .{ .id = 97, .label = "shape" }, .{ .id = 98, .label = "rate" },
        .{ .id = 258, .label = "sync" }, .{ .id = 261, .label = "retrig" },
        .{ .id = 264, .label = "phase" }, .{ .id = 267, .label = "slew" },
    } },
    .{ .title = "ENV 3", .tone = .env, .band = 1, .params = &.{
        .{ .id = 122, .label = "attack" }, .{ .id = 123, .label = "decay" },
        .{ .id = 124, .label = "sustain" }, .{ .id = 125, .label = "release" },
    } },
    .{ .title = "MACROS", .tone = .util, .band = 1, .params = &.{
        .{ .id = 99, .label = "macro 1" }, .{ .id = 100, .label = "macro 2" },
        .{ .id = 101, .label = "macro 3" }, .{ .id = 102, .label = "macro 4" },
    } },
    // Last: the matrix is by far the tallest card here, and at the top of
    // column 0 it pushed LFO 1 below the fold while LFO 2 and LFO 3 sat at
    // the top of their own columns. The sources come first, what routes
    // them comes after - and being third in its band puts it in the column
    // the other two leave empty.
    // Each row is two entries: the packed source/dest/depth triplet, then
    // its polarity toggle. The toggle can't be a fourth field of the
    // triplet - entry fields must be contiguous ids, and 59-82 is packed
    // 3-per-row - so it gets its own entry, placed right after so j/k
    // still walks a row's controls together.
    .{ .title = "MATRIX", .tone = .mod, .band = 1, .params = &matrix_params },
};
// zig fmt: on

// ---------------------------------------------------------------------------
// Comptime column packing
// ---------------------------------------------------------------------------

pub const Placement = struct { col: usize, row0: usize };

/// Height-balanced placement. Fixed band rows left most of a wide 16:9
/// viewport empty while pushing later cards below it. Declaration order
/// still keeps related sections adjacent in keyboard traversal.
fn packColumns(comptime sections: []const SectionDef, comptime num_cols: usize) [sections.len]Placement {
    var out: [sections.len]Placement = undefined;
    var col_h = [_]usize{0} ** num_cols;
    for (sections, 0..) |sec, i| {
        var col: usize = 0;
        for (col_h[1..], 1..) |height, candidate| {
            if (height < col_h[col]) col = candidate;
        }
        out[i] = .{ .col = col, .row0 = col_h[col] };
        col_h[col] += sec.params.len + 2;
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
    id: u16,
    label: []const u8,
    fields: u8,
    col: usize,
    row: usize,
    section: usize,
};

/// Traversal follows declaration order and stays identical in every column
/// bucket, so resizing does not change keyboard order.
fn computeOrder(comptime sections: []const SectionDef, comptime placements: [sections.len]Placement, comptime num_cols: usize) [totalEntries(sections)]PositionedEntry {
    _ = num_cols;
    var out: [totalEntries(sections)]PositionedEntry = undefined;
    var n: usize = 0;
    for (sections, 0..) |sec, si| {
        for (sec.params, 0..) |p, j| {
            out[n] = .{
                .id = p.id,
                .label = p.label,
                .fields = p.fields,
                .col = placements[si].col,
                .row = placements[si].row0 + 1 + j,
                .section = si,
            };
            n += 1;
        }
    }
    return out;
}

const main_placements_1 = packColumns(&main_sections, 1);
const main_placements_2 = packColumns(&main_sections, 2);
const main_placements_3 = packColumns(&main_sections, 3);
const main_placements_4 = packColumns(&main_sections, 4);
pub const main_order_1 = computeOrder(&main_sections, main_placements_1, 1);
pub const main_order_2 = computeOrder(&main_sections, main_placements_2, 2);
pub const main_order_3 = computeOrder(&main_sections, main_placements_3, 3);
pub const main_order_4 = computeOrder(&main_sections, main_placements_4, 4);
pub const main_heights_1 = columnHeights(&main_sections, main_placements_1, 1);
pub const main_heights_2 = columnHeights(&main_sections, main_placements_2, 2);
pub const main_heights_3 = columnHeights(&main_sections, main_placements_3, 3);
pub const main_heights_4 = columnHeights(&main_sections, main_placements_4, 4);

const mod_placements_1 = packColumns(&mod_sections, 1);
const mod_placements_2 = packColumns(&mod_sections, 2);
const mod_placements_3 = packColumns(&mod_sections, 3);
const mod_placements_4 = packColumns(&mod_sections, 4);
pub const mod_order_1 = computeOrder(&mod_sections, mod_placements_1, 1);
pub const mod_order_2 = computeOrder(&mod_sections, mod_placements_2, 2);
pub const mod_order_3 = computeOrder(&mod_sections, mod_placements_3, 3);
pub const mod_order_4 = computeOrder(&mod_sections, mod_placements_4, 4);
pub const mod_heights_1 = columnHeights(&mod_sections, mod_placements_1, 1);
pub const mod_heights_2 = columnHeights(&mod_sections, mod_placements_2, 2);
pub const mod_heights_3 = columnHeights(&mod_sections, mod_placements_3, 3);
pub const mod_heights_4 = columnHeights(&mod_sections, mod_placements_4, 4);

/// Column-count bucket for a given terminal width.
pub fn numCols(cols: usize) usize {
    if (cols >= 210) return 4;
    if (cols >= 160) return 3;
    if (cols >= 108) return 2;
    return 1;
}

pub fn colWidth(cols: usize, n: usize) usize {
    return cols / n;
}

/// Which column each section landed in, for renderers that draw whole
/// cards rather than walking entries (the GUI builds one child window per
/// column and fills it section by section). Reading this instead of
/// re-deriving a column split is what keeps the on-screen grid and the
/// `j`/`k` order the same grid.
pub fn mainPlacements(n: usize) []const Placement {
    return switch (n) {
        1 => &main_placements_1,
        2 => &main_placements_2,
        3 => &main_placements_3,
        else => &main_placements_4,
    };
}

pub fn modPlacements(n: usize) []const Placement {
    return switch (n) {
        1 => &mod_placements_1,
        2 => &mod_placements_2,
        3 => &mod_placements_3,
        else => &mod_placements_4,
    };
}

pub fn mainOrder(n: usize) []const PositionedEntry {
    return switch (n) {
        1 => &main_order_1,
        2 => &main_order_2,
        3 => &main_order_3,
        else => &main_order_4,
    };
}

pub fn mainHeights(n: usize) []const usize {
    return switch (n) {
        1 => &main_heights_1,
        2 => &main_heights_2,
        3 => &main_heights_3,
        else => &main_heights_4,
    };
}

pub fn modOrder(n: usize) []const PositionedEntry {
    return switch (n) {
        1 => &mod_order_1,
        2 => &mod_order_2,
        3 => &mod_order_3,
        else => &mod_order_4,
    };
}

pub fn modHeights(n: usize) []const usize {
    return switch (n) {
        1 => &mod_heights_1,
        2 => &mod_heights_2,
        3 => &mod_heights_3,
        else => &mod_heights_4,
    };
}

// ---------------------------------------------------------------------------
// Navigation primitives - shared by MAIN and MOD (FX keeps its own
// fx_order-aware walk in editors/synth.zig; these operate on whichever
// `[]const PositionedEntry` the caller resolved via mainOrder/modOrder).
// ---------------------------------------------------------------------------

pub fn indexContaining(order: []const PositionedEntry, id: u16) ?usize {
    for (order, 0..) |pe, i| {
        if (id >= pe.id and id < pe.id + pe.fields) return i;
    }
    return null;
}

/// `j`/`k`/`g`/`G`: move by whole entries (rows), preserving which field of
/// a multi-field entry (a mod-matrix slot) was focused when possible.
pub fn moveEntry(order: []const PositionedEntry, cursor: u16, delta: i32) u16 {
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
pub fn moveField(order: []const PositionedEntry, cursor: u16, delta: i32) u16 {
    const idx = indexContaining(order, cursor) orelse return cursor;
    const e = order[idx];
    const off = std.math.clamp(@as(i32, cursor) - @as(i32, e.id) + delta, 0, @as(i32, e.fields) - 1);
    return e.id + @as(u8, @intCast(off));
}

/// `{`/`}`: jump to the next/previous section's first entry. No wrap past
/// either end (matches the old sectionStarts-based behavior) - pressing
/// backward while already on a section's first entry goes to the *previous*
/// section's first entry instead of no-op'ing, exactly like vim's `{`.
pub fn jumpSection(order: []const PositionedEntry, cursor: u16, forward: bool) u16 {
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

pub fn firstEntry(order: []const PositionedEntry) u16 {
    return if (order.len > 0) order[0].id else 0;
}

pub fn lastEntry(order: []const PositionedEntry) u16 {
    return if (order.len > 0) order[order.len - 1].id else 0;
}

test "wide synth layout adds a shorter fourth column" {
    var three_max: usize = 0;
    var four_max: usize = 0;
    for (main_heights_3) |height| three_max = @max(three_max, height);
    for (main_heights_4) |height| four_max = @max(four_max, height);
    try std.testing.expect(four_max < three_max);
}

// ---------------------------------------------------------------------------
// Completeness check - every id MAIN/MOD are supposed to own appears
// exactly once between them, and none collide with an id owned by FX, a
// dead (retired) id, or an FX reorder-handle id. A bad regroup (dropped id,
// duplicated id, accidental overlap with FX's range) fails the *build*,
// not just a test run.
// ---------------------------------------------------------------------------

comptime {
    @setEvalBranchQuota(4000);
    for ([_][]const SectionDef{ &main_sections, &mod_sections }) |sections| {
        for (sections[1..], 1..) |sec, i| {
            if (sec.band < sections[i - 1].band) @compileError("synth_layout: bands must be declared in ascending order");
        }
    }
    var seen = [_]bool{false} ** 373;
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
    // inSubview(.fx)/reorderIdFor - verified against that file's ranges),
    // and 195-255, the custom-LFO breakpoint block (drawn by its own
    // curve editor under the shape row, never a cursor-walkable param row)
    // plus the gap above it left free when param ids widened to u16.
    const excluded = [_][2]u16{
        .{ 23, 23 },   .{ 30, 31 },   .{ 83, 94 },   .{ 103, 115 },
        .{ 126, 136 }, .{ 137, 143 }, .{ 144, 160 }, .{ 161, 166 },
        .{ 167, 175 }, .{ 176, 180 }, .{ 181, 184 }, .{ 188, 194 },
        .{ 195, 255 },
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

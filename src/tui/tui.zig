//! TUI rendering. Every function is pure output — no state mutation.
//!
//! Functions that need App fields take `app: anytype` so this module
//! never imports app.zig, avoiding a circular dependency. The compiler
//! instantiates each function with *App at the call site and type-checks
//! the field accesses there.

const std = @import("std");
const types = @import("../core/types.zig");
const Project = @import("../project.zig").Project;
const Transport = @import("../transport.zig").Transport;
const DrumMachine = @import("../dsp/drum_sampler.zig").DrumMachine;
const eq_mod = @import("../dsp/eq.zig");
const cmd_mod = @import("cmd.zig");
const engine_mod = @import("../audio/engine.zig");

pub const spectrum_rows: usize = 18;
pub const spectrum_band_count: usize = 80;

// ---------------------------------------------------------------------------
// Primitive helpers
// ---------------------------------------------------------------------------

pub fn endLine(w: *std.Io.Writer) !void {
    try w.writeAll("\x1b[K\r\n");
}

pub fn hr(w: *std.Io.Writer, cols: u16) !void {
    for (0..@min(cols, 100)) |_| try w.writeByte('-');
    try endLine(w);
}

pub fn meter(w: *std.Io.Writer, peak: f32) !void {
    const cells = 10;
    const db = types.gainToDb(peak);
    const norm = std.math.clamp((db + 50.0) / 50.0, 0.0, 1.0);
    const filled: usize = @intFromFloat(norm * cells);
    try w.writeByte('[');
    for (0..cells) |i| try w.writeByte(if (i < filled) '#' else '-');
    try w.writeByte(']');
}

fn brailleBar(rem: usize) u21 {
    const bits: u8 = switch (rem) {
        0 => 0b00000000,
        1 => 0b11000000,
        2 => 0b11100100,
        3 => 0b11110110,
        else => 0b11111111,
    };
    return @as(u21, 0x2800) | @as(u21, bits);
}

// ---------------------------------------------------------------------------
// Header / footer
// ---------------------------------------------------------------------------

pub fn drawHeader(
    w: *std.Io.Writer,
    project: *const Project,
    transport: *const Transport,
    audio_label: []const u8,
    master_gain_db: f32,
) !void {
    const vol_sign: []const u8 = if (master_gain_db >= 0) "+" else "";
    try w.print(" wstudio - {s}", .{project.name});
    try w.print("   bpm {d:.0}  {d}/{d}   vol: {s}{d:.0}dB   audio: {s}", .{
        transport.tempo_bpm,
        transport.time_signature.beats_per_bar,
        transport.time_signature.beat_unit,
        vol_sign,
        master_gain_db,
        audio_label,
    });
    try endLine(w);
}

// ---------------------------------------------------------------------------
// Main views
// ---------------------------------------------------------------------------

pub fn drawTracks(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    try w.writeAll(" TRACKS   [s:spectrum  m:master  enter:drum-grid]\r\n");
    for (app.project.tracks.items, 0..) |track, i| {
        const is_drum = (i == app.drum_track);
        const label: []const u8 = if (is_drum) "drum machine" else app.racks.items[i].label;
        const has_eq: []const u8 = if (i < app.racks.items.len and app.racks.items[i].eq != null) " EQ" else "   ";
        const hint: []const u8 = if (is_drum) " [enter:open grid]" else "";
        const marker: []const u8 = if (i == app.cursor) ">" else " ";
        const inv: []const u8 = if (i == app.cursor) "\x1b[7m" else "";
        const mute: []const u8 = if (track.muted) "M" else " ";
        try w.print(" {s}{s} {d} {s: <8} {s}[{s}]{s}{s}\x1b[0m", .{
            inv, marker, i + 1, track.name, mute, label, has_eq, hint,
        });
        try endLine(w);
    }
    const used = 3 + app.project.tracks.items.len;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawDrumGrid(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    const playing_step = app.drum.currentStep();
    const is_playing = app.engine.uiSnapshot().playing;
    const cur_pad = app.drum_cursor[0];
    const cur_step = app.drum_cursor[1];

    const track_name = app.project.tracks.items[app.drum_track].name;
    try w.print(" DRUMS \"{s}\"  [hjkl:move  spc:toggle  p:preview  esc:back]\r\n", .{track_name});

    try w.writeAll("      ");
    for (0..DrumMachine.max_steps) |s| {
        if (s % 4 == 0) try w.writeByte('|');
        try w.print("{d:>2} ", .{s + 1});
    }
    try endLine(w);

    for (0..DrumMachine.max_pads) |p| {
        const name = app.drum.padName(@intCast(p));
        try w.print(" {s: <4} ", .{name[0..@min(name.len, 4)]});
        for (0..DrumMachine.max_steps) |s| {
            if (s % 4 == 0) try w.writeByte('|');
            const active = app.drum.stepActive(@intCast(p), @intCast(s));
            const is_cursor = (p == cur_pad and s == cur_step);
            const is_play = is_playing and (s == playing_step);

            if (is_cursor) try w.writeAll("\x1b[7m");
            if (is_play and !is_cursor) try w.writeAll("\x1b[1m");

            try w.writeAll(if (active) "[X]" else "[ ]");

            if (is_cursor or is_play) try w.writeAll("\x1b[0m");
        }
        try endLine(w);
    }

    const used = 4 + DrumMachine.max_pads;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawHelp(w: *std.Io.Writer, rows: usize, cmds: []const cmd_mod.Def) !void {
    try w.writeAll(" COMMANDS\r\n\r\n");
    for (cmds) |c| {
        try w.print("  :{s: <10}  {s}\r\n", .{ c.name, c.desc });
    }
    const used = 2 + cmds.len + 2;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawSpectrumView(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    snap: engine_mod.UiSnapshot,
    is_track: bool,
) !void {
    _ = snap;

    const title: []const u8 = if (is_track) blk: {
        const name = if (app.eq_track < app.project.tracks.items.len)
            app.project.tracks.items[app.eq_track].name
        else
            "?";
        break :blk name;
    } else "MASTER";

    const spectrum_snap = if (is_track)
        app.engine.trackSpectrumSnapshot(app.eq_track)
    else
        app.engine.masterSpectrumSnapshot();

    try w.print(" SPECTRUM \"{s}\"  [jk:gain  hl:select  b:bypass  esc:back]\r\n", .{title});

    const visual_rows = @min(spectrum_rows, rows -| 5);
    const db_range: f32 = 70.0;
    const db_offset: f32 = -60.0;

    for (0..visual_rows) |visual_row_inv| {
        const visual_row = visual_rows - 1 - visual_row_inv;

        try w.writeAll("   ");

        if (visual_row == visual_rows - 1) {
            try w.writeAll(" 0dB\r\n");
            continue;
        }
        if (visual_row == visual_rows - 2) {
            try w.writeAll(" -6dB\r\n");
            continue;
        }
        if (visual_row == visual_rows - 3) {
            try w.writeAll("-12dB\r\n");
            continue;
        }

        if (spectrum_snap) |ssnap| {
            for (0..spectrum_band_count) |band| {
                const db_val = ssnap.bins[band];
                const raw = (db_val - db_offset) / db_range;
                const norm = if (std.math.isNan(raw)) 0.0 else std.math.clamp(raw, 0.0, 1.0);
                const total_pixels = @as(u32, @intCast(visual_rows)) * 4;
                const pixel_height = @as(usize, @intFromFloat(norm * @as(f32, @floatFromInt(total_pixels))));

                const pixel_start = (visual_rows - 1 - visual_row) * 4;
                const rem = if (pixel_height > pixel_start)
                    @min(pixel_height - pixel_start, 4)
                else
                    0;

                const ch = brailleBar(rem);
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(ch, &utf8_buf) catch unreachable;
                try w.writeAll(utf8_buf[0..utf8_len]);
            }
        } else {
            for (0..spectrum_band_count) |_| {
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(brailleBar(0), &utf8_buf) catch unreachable;
                try w.writeAll(utf8_buf[0..utf8_len]);
            }
        }
        try endLine(w);
    }

    try w.writeAll("Hz   ");
    const freq_labels = [_]struct { idx: usize, label: []const u8 }{
        .{ .idx = 0, .label = "20" },
        .{ .idx = 12, .label = "40" },
        .{ .idx = 24, .label = "80" },
        .{ .idx = 36, .label = "160" },
        .{ .idx = 48, .label = "320" },
        .{ .idx = 55, .label = "640" },
        .{ .idx = 61, .label = "1.2k" },
        .{ .idx = 67, .label = "2.5k" },
        .{ .idx = 72, .label = "5k" },
        .{ .idx = 76, .label = "10k" },
        .{ .idx = 78, .label = "20k" },
    };

    var fi: usize = 0;
    for (0..spectrum_band_count) |band| {
        if (fi < freq_labels.len and band == freq_labels[fi].idx) {
            const label = freq_labels[fi].label;
            if (band + label.len < spectrum_band_count) {
                try w.writeAll(label);
                fi += 1;
            } else {
                try w.writeAll(" ");
            }
        } else {
            try w.writeAll(" ");
        }
    }
    try endLine(w);

    if (is_track and app.eq_track < app.racks.items.len) {
        if (app.racks.items[app.eq_track].eq) |*e| {
            const bypass_str: []const u8 = if (e.bypass) " [BYPASS]" else "";
            try w.print(" EQ{s}  ", .{bypass_str});
            for (0..eq_mod.num_eq_bands) |b| {
                const marker: []const u8 = if (b == app.eq_cursor) ">" else " ";
                const val = e.bands[b].gain_db;
                try w.print("{s}{d: <4.0}", .{ marker, val });
            }
            try endLine(w);
        }
    }
}

// ---------------------------------------------------------------------------
// Status bars
// ---------------------------------------------------------------------------

pub fn drawTracksStatus(app: anytype, w: *std.Io.Writer) !void {
    switch (app.modal.mode) {
        .command => try w.print(" :{s}_", .{app.modal.cmd_buf[0..app.modal.cmd_len]}),
        else => {
            const mode_name = switch (app.modal.mode) {
                .normal => "NORMAL",
                .insert => "INSERT",
                .visual => "VISUAL",
                .command => unreachable,
            };
            try w.print(" \x1b[7m {s} \x1b[0m oct {d}", .{ mode_name, app.modal.octave });
            if (app.modal.count > 0) try w.print("  {d}", .{app.modal.count});
            if (app.status_len > 0) try w.print("  {s}", .{app.status_buf[0..app.status_len]});
        },
    }
}

pub fn drawDrumStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.modal.mode == .command) {
        try w.print(" :{s}_", .{app.modal.cmd_buf[0..app.modal.cmd_len]});
        return;
    }
    const p = app.drum_cursor[0];
    const s = app.drum_cursor[1];
    try w.print(" \x1b[7m DRUM \x1b[0m  pad {d}/8  step {d}/16  {s}", .{
        p + 1,
        s + 1,
        app.drum.padName(p),
    });
    if (app.status_len > 0) try w.print("  {s}", .{app.status_buf[0..app.status_len]});
}

pub fn drawSpectrumStatus(app: anytype, w: *std.Io.Writer, is_track: bool) !void {
    if (is_track and app.eq_track < app.racks.items.len) {
        if (app.racks.items[app.eq_track].eq) |*e| {
            const freq = eq_mod.iso_frequencies[app.eq_cursor];
            const gain = e.bands[app.eq_cursor].gain_db;
            const sign: []const u8 = if (gain >= 0) "+" else "";
            try w.print(" \x1b[7m EQ \x1b[0m  {d:.0}Hz  {s}{d:.1}dB  [{d}/{d}]", .{
                freq, sign, gain, app.eq_cursor + 1, eq_mod.num_eq_bands,
            });
            if (e.bypass) try w.print("  BYPASS", .{});
            if (app.status_len > 0) try w.print("  {s}", .{app.status_buf[0..app.status_len]});
            return;
        }
    }
    if (app.status_len > 0) {
        try w.print(" {s}", .{app.status_buf[0..app.status_len]});
    }
}

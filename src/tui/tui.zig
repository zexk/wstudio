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
/// Number of editable synth parameters (waveform, detune, unison, ADSR, filter, gain).
pub const synth_param_count: u8 = 11;

// ---------------------------------------------------------------------------
// Palette — all colour codes go here; never raw \x1b sequences elsewhere
// ---------------------------------------------------------------------------

const rst  = "\x1b[0m";
const bold = "\x1b[1m";
const dim  = "\x1b[2m";
const acc  = "\x1b[36m";   // cyan  – interactive / instrument labels
const grn  = "\x1b[32m";   // green – playing / active steps
const yel  = "\x1b[33m";   // yellow – INSERT mode / muted
const red  = "\x1b[31m";   // red   – clip / error
const sel  = "\x1b[7m";    // reverse-video – selected row / cursor

// ---------------------------------------------------------------------------
// Primitive helpers
// ---------------------------------------------------------------------------

pub fn endLine(w: *std.Io.Writer) !void {
    // Reset before erasing so background colour never bleeds to the right edge.
    try w.writeAll(rst ++ "\x1b[K\r\n");
}

pub fn hr(w: *std.Io.Writer, cols: u16) !void {
    try w.writeAll(dim);
    for (0..@min(cols, 200)) |_| try w.writeAll("─");
    try endLine(w);
}

pub fn meter(w: *std.Io.Writer, peak: f32) !void {
    const cells = 10;
    const db = types.gainToDb(peak);
    const norm = std.math.clamp((db + 50.0) / 50.0, 0.0, 1.0);
    const filled: usize = @intFromFloat(norm * cells);
    const colour: []const u8 = if (db >= 0.0) red else if (db >= -6.0) yel else grn;
    try w.writeAll(colour);
    try w.writeByte('[');
    for (0..cells) |i| try w.writeAll(if (i < filled) "█" else "░");
    try w.writeByte(']');
    try w.writeAll(rst);
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

fn brailleBarInv(rem: usize) u21 {
    const bits: u8 = switch (rem) {
        0 => 0b11111111,
        1 => 0b00111111,
        2 => 0b00011011,
        3 => 0b00001001,
        else => 0b00000000,
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
    try w.writeAll(bold ++ " wstudio" ++ rst);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(project.name);
    try w.writeAll(dim ++ "   bpm " ++ rst);
    try w.print("{d:.0}", .{transport.tempo_bpm});
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("{d}/{d}", .{
        transport.time_signature.beats_per_bar,
        transport.time_signature.beat_unit,
    });
    try w.writeAll(dim ++ "   vol " ++ rst);
    try w.print("{s}{d:.0}dB", .{ vol_sign, master_gain_db });
    try w.writeAll(dim ++ "   " ++ rst);
    try w.writeAll(acc);
    try w.writeAll(audio_label);
    try endLine(w);
}

// ---------------------------------------------------------------------------
// Main views
// ---------------------------------------------------------------------------

pub fn drawTracks(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    try w.writeAll(bold ++ " TRACKS" ++ rst);
    try w.writeAll(dim ++ "   [enter:edit  s:spectrum  m:mute  M:master  a:add  D:del  ?:help]");
    try endLine(w);

    for (app.project.tracks.items, 0..) |track, i| {
        const is_drum = (i == app.drum_track);
        const label: []const u8 = if (is_drum) "drum machine" else app.racks.items[i].label;
        const has_eq = (i < app.racks.items.len and app.racks.items[i].fx.eq != null);
        const hint: []const u8 = if (is_drum) " [enter:grid]" else " [enter:edit]";
        const is_sel = (i == app.cursor);
        // muted-but-not-selected rows get a dim wash over everything
        const faded = track.muted and !is_sel;
        const marker: []const u8 = if (is_sel) ">" else " ";

        if (is_sel) try w.writeAll(sel);
        if (faded) try w.writeAll(dim);
        try w.writeByte(' ');
        try w.writeAll(marker);
        try w.writeByte(' ');
        try w.print("{d} ", .{i + 1});
        // name padded — no escape codes inside the padded field
        try w.print("{s: <8}", .{track.name});
        try w.writeByte(' ');
        // muted indicator: yellow only when row isn't already faded
        if (track.muted) {
            if (!faded) try w.writeAll(yel);
            try w.writeByte('M');
            if (!faded) try w.writeAll(rst);
            if (is_sel) try w.writeAll(sel);
        } else {
            try w.writeByte(' ');
        }
        // instrument / rack label — accent only on active, unselected rows
        if (!is_sel and !faded) try w.writeAll(acc);
        try w.print(" [{s}]", .{label});
        if (!is_sel and !faded) try w.writeAll(rst);
        // EQ badge
        if (has_eq) {
            if (!is_sel and !faded) try w.writeAll(acc);
            try w.writeAll(" EQ");
            if (!is_sel and !faded) try w.writeAll(rst);
        } else {
            try w.writeAll("   ");
        }
        // keybind hint — dim only when not already faded/selected
        if (!is_sel and !faded) try w.writeAll(dim);
        try w.writeAll(hint);
        try endLine(w);
    }

    const used = 2 + app.project.tracks.items.len;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawDrumGrid(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    const playing_step = app.drumMachine().currentStep();
    const is_playing = app.engine.uiSnapshot().playing;
    const cur_pad = app.drum_cursor[0];
    const cur_step = app.drum_cursor[1];

    const dm = app.drumMachine();
    const step_count = dm.step_count;
    const track_name = app.project.tracks.items[app.drum_track].name;
    try w.writeAll(bold ++ " DRUMS" ++ rst);
    try w.print(" \"{s}\"", .{track_name});
    try w.writeAll(dim ++ "  [hjkl:move  spc:toggle  p:preview  <>:length  esc:back]");
    try endLine(w);

    // step header — active range normal, inactive range dim
    try w.writeAll(dim ++ "      ");
    for (0..DrumMachine.max_steps) |s| {
        if (s % 4 == 0) try w.writeAll("│");
        if (s == step_count) try w.writeAll("\x1b[2m"); // already dim; mark boundary
        try w.print("{d:>2} ", .{s + 1});
    }
    try endLine(w);

    for (0..DrumMachine.max_pads) |p| {
        const name = dm.padName(@intCast(p));
        try w.writeAll(dim);
        try w.print(" {s: <4} ", .{name[0..@min(name.len, 4)]});
        try w.writeAll(rst);
        for (0..DrumMachine.max_steps) |s| {
            if (s % 4 == 0) {
                try w.writeAll(dim ++ "│" ++ rst);
            }
            const beyond = (s >= step_count);
            const active = dm.stepActive(@intCast(p), @intCast(s));
            const is_cursor = (p == cur_pad and s == cur_step);
            const is_play = is_playing and (s == playing_step);

            if (beyond) {
                // steps outside the loop — always dim, cursor still shown
                if (is_cursor) try w.writeAll(sel) else try w.writeAll(dim);
            } else if (is_cursor) {
                try w.writeAll(sel);
            } else if (is_play) {
                try w.writeAll(grn ++ bold);
            } else if (active) {
                try w.writeAll(acc);
            } else {
                try w.writeAll(dim);
            }

            try w.writeAll(if (active) "[X]" else "[ ]");
            try w.writeAll(rst);
        }
        try endLine(w);
    }

    const used = 4 + DrumMachine.max_pads;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

fn helpKey(w: *std.Io.Writer, keys: []const u8, desc: []const u8) !void {
    try w.writeAll(acc);
    try w.print("  {s: <16}", .{keys});
    try w.writeAll(rst ++ dim);
    try w.writeAll(desc);
    try endLine(w);
}

fn helpSection(w: *std.Io.Writer, title: []const u8) !void {
    try endLine(w);
    try w.writeAll(bold);
    try w.writeAll("  ");
    try w.writeAll(title);
    try endLine(w);
}

pub fn drawHelp(w: *std.Io.Writer, rows: usize, cmds: []const cmd_mod.Def) !void {
    try w.writeAll(bold ++ " HELP" ++ rst);
    try w.writeAll(dim ++ "   esc: close");
    try endLine(w);

    // ── Commands ─────────────────────────────────
    try helpSection(w, "COMMANDS");
    try endLine(w);
    for (cmds) |c| {
        try w.writeAll(acc);
        try w.print("  :{s: <14}", .{c.name});
        try w.writeAll(rst ++ dim);
        try w.writeAll(c.desc);
        try endLine(w);
    }

    // ── Keyboard reference ────────────────────────
    try helpSection(w, "ALL VIEWS");
    try helpKey(w, "[ / ]",        "master volume down / up");
    try helpKey(w, "space",        "play / pause");
    try helpKey(w, "gg",           "rewind to start");
    try helpKey(w, "i",            "enter INSERT mode (play notes)");
    try helpKey(w, "esc",          "back / return to NORMAL mode");
    try helpKey(w, ":",            "open command prompt");
    try helpKey(w, "ctrl-c",       "quit");

    try helpSection(w, "TRACKS");
    try helpKey(w, "j / k",        "move cursor down / up");
    try helpKey(w, "enter",        "edit track (synth or drum grid)");
    try helpKey(w, "s",            "spectrum + EQ for selected track");
    try helpKey(w, "m",            "mute / unmute selected track");
    try helpKey(w, "M",            "master spectrum");
    try helpKey(w, "a",            "add synth track");
    try helpKey(w, "D",            "delete selected track");
    try helpKey(w, "? / :help",    "this help");

    try helpSection(w, "INSERT MODE  (piano keyboard)");
    try helpKey(w, "z s x d c v g b h n j m",  "white keys, lower octave");
    try helpKey(w, "q 2 w 3 e r 5 t 6 y 7 u",  "white+black keys, upper octave");
    try helpKey(w, "z< / x>",      "octave down / up");

    try helpSection(w, "DRUM GRID");
    try helpKey(w, "h / j / k / l","move cursor left/down/up/right");
    try helpKey(w, "space",        "toggle step on/off");
    try helpKey(w, "p",            "preview pad sound");
    try helpKey(w, "< / >",        "shorten / lengthen loop (1–16 steps)");

    try helpSection(w, "SYNTH EDITOR");
    try helpKey(w, "j / k",        "select parameter");
    try helpKey(w, "h / l",        "adjust value (fine)");
    try helpKey(w, "H / L",        "adjust value (coarse ×10)");

    try helpSection(w, "SPECTRUM / EQ");
    try helpKey(w, "h / l",        "select EQ band");
    try helpKey(w, "j / k",        "decrease / increase band gain (1 dB)");
    try helpKey(w, "J / K",        "decrease / increase band gain (6 dB)");
    try helpKey(w, "b",            "bypass EQ toggle");

    // content comfortably exceeds one screen; padding loop handles short terminals
    const used = 60;
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

    try w.writeAll(bold ++ " SPECTRUM" ++ rst);
    try w.print(" \"{s}\"", .{title});
    try w.writeAll(dim ++ "  [jk:gain  hl:select  b:bypass  esc:back]");
    try endLine(w);

    const visual_rows = @min(spectrum_rows, rows -| 5);
    const db_range: f32 = 70.0;
    const db_offset: f32 = -60.0;

    for (0..visual_rows) |visual_row_inv| {
        const visual_row = visual_rows - 1 - visual_row_inv;

        try w.writeAll(dim ++ "   " ++ rst);

        if (visual_row == visual_rows - 1) {
            try w.writeAll(dim ++ " 0dB");
            try endLine(w);
            continue;
        }
        if (visual_row == visual_rows - 2) {
            try w.writeAll(dim ++ " -6dB");
            try endLine(w);
            continue;
        }
        if (visual_row == visual_rows - 3) {
            try w.writeAll(dim ++ "-12dB");
            try endLine(w);
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

                // colour by level: top rows are louder
                const row_norm: f32 = @as(f32, @floatFromInt(visual_rows - 1 - visual_row)) /
                    @as(f32, @floatFromInt(visual_rows));
                const colour: []const u8 = if (row_norm > 0.85) red
                    else if (row_norm > 0.65) yel
                    else grn;
                try w.writeAll(if (rem > 0) colour else dim);

                const ch = brailleBarInv(rem);
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(ch, &utf8_buf) catch unreachable;
                try w.writeAll(utf8_buf[0..utf8_len]);
                try w.writeAll(rst);
            }
        } else {
            try w.writeAll(dim);
            for (0..spectrum_band_count) |_| {
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(brailleBarInv(0), &utf8_buf) catch unreachable;
                try w.writeAll(utf8_buf[0..utf8_len]);
            }
        }
        try endLine(w);
    }

    try w.writeAll(dim ++ "Hz   ");
    const freq_labels = [_]struct { idx: usize, label: []const u8 }{
        .{ .idx = 0,  .label = "20"  },
        .{ .idx = 12, .label = "40"  },
        .{ .idx = 24, .label = "80"  },
        .{ .idx = 36, .label = "160" },
        .{ .idx = 48, .label = "320" },
        .{ .idx = 55, .label = "640" },
        .{ .idx = 61, .label = "1.2k"},
        .{ .idx = 67, .label = "2.5k"},
        .{ .idx = 72, .label = "5k"  },
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
                try w.writeByte(' ');
            }
        } else {
            try w.writeByte(' ');
        }
    }
    try endLine(w);

    if (is_track and app.eq_track < app.racks.items.len) {
        if (app.racks.items[app.eq_track].fx.eq) |*e| {
            const bypass_str: []const u8 = if (e.bypass) " [BYPASS]" else "";
            try w.writeAll(bold ++ " EQ" ++ rst);
            try w.writeAll(red);
            try w.writeAll(bypass_str);
            try w.writeAll(rst ++ "  ");
            for (0..eq_mod.num_eq_bands) |b| {
                const is_cur = (b == app.eq_cursor);
                const val = e.bands[b].gain_db;
                if (is_cur) try w.writeAll(acc ++ bold);
                const marker: []const u8 = if (is_cur) ">" else " ";
                try w.print("{s}{d: <4.0}", .{ marker, val });
                if (is_cur) try w.writeAll(rst);
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
        .command => {
            try w.writeAll(dim ++ " :" ++ rst);
            try w.print("{s}_", .{app.modal.cmd_buf[0..app.modal.cmd_len]});
        },
        else => {
            const mode_colour: []const u8 = switch (app.modal.mode) {
                .insert => yel,
                else    => grn,
            };
            const mode_name = switch (app.modal.mode) {
                .normal  => "NORMAL",
                .insert  => "INSERT",
                .visual  => "VISUAL",
                .command => unreachable,
            };
            try w.writeAll(mode_colour);
            try w.writeAll(sel);
            try w.print(" {s} ", .{mode_name});
            try w.writeAll(rst);
            // track position
            try w.writeAll(dim ++ "  " ++ rst);
            try w.print("{d}/{d}", .{ app.cursor + 1, app.project.tracks.items.len });
            try w.writeAll(dim ++ "  oct " ++ rst);
            try w.print("{d}", .{app.modal.octave});
            if (app.modal.count > 0) try w.print("  {d}", .{app.modal.count});
            if (app.status_len > 0) {
                try w.writeAll(dim ++ "  " ++ rst);
                try w.writeAll(app.status_buf[0..app.status_len]);
            }
        },
    }
}

pub fn drawDrumStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.modal.mode == .command) {
        try w.writeAll(dim ++ " :" ++ rst);
        try w.print("{s}_", .{app.modal.cmd_buf[0..app.modal.cmd_len]});
        return;
    }
    const p = app.drum_cursor[0];
    const s = app.drum_cursor[1];
    const dm = app.drumMachine();
    try w.writeAll(acc ++ sel ++ " DRUM " ++ rst);
    try w.writeAll(dim ++ "  pad " ++ rst);
    try w.print("{d}/{d}", .{ p + 1, DrumMachine.max_pads });
    try w.writeAll(dim ++ "  step " ++ rst);
    try w.print("{d}/{d}", .{ s + 1, dm.step_count });
    try w.writeAll(dim ++ "  len " ++ rst);
    try w.print("{d}", .{dm.step_count});
    try w.writeAll(dim ++ "/" ++ rst);
    try w.print("{d}", .{DrumMachine.max_steps});
    try w.writeAll("  ");
    try w.writeAll(bold);
    try w.writeAll(dm.padName(p));
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

pub fn drawSpectrumStatus(app: anytype, w: *std.Io.Writer, is_track: bool) !void {
    if (is_track and app.eq_track < app.racks.items.len) {
        if (app.racks.items[app.eq_track].fx.eq) |*e| {
            const freq = eq_mod.iso_frequencies[app.eq_cursor];
            const gain = e.bands[app.eq_cursor].gain_db;
            const sign: []const u8 = if (gain >= 0) "+" else "";
            try w.writeAll(acc ++ sel ++ " EQ " ++ rst);
            try w.writeAll(dim ++ "  " ++ rst);
            try w.print("{d:.0}Hz", .{freq});
            try w.writeAll("  ");
            try w.print("{s}{d:.1}dB", .{ sign, gain });
            try w.writeAll(dim ++ "  [" ++ rst);
            try w.print("{d}/{d}", .{app.eq_cursor + 1, eq_mod.num_eq_bands});
            try w.writeAll(dim ++ "]" ++ rst);
            if (e.bypass) {
                try w.writeAll("  " ++ red ++ "BYPASS" ++ rst);
            }
            if (app.status_len > 0) {
                try w.writeAll(dim ++ "  " ++ rst);
                try w.writeAll(app.status_buf[0..app.status_len]);
            }
            return;
        }
    }
    if (app.status_len > 0) {
        try w.print(" {s}", .{app.status_buf[0..app.status_len]});
    }
}

// ---------------------------------------------------------------------------
// Synth editor
// ---------------------------------------------------------------------------

fn synthBar(w: *std.Io.Writer, value: f32, max_val: f32) !void {
    const bar_w: usize = 20;
    const n: usize = @intFromFloat(std.math.clamp(value / max_val, 0.0, 1.0) * @as(f32, @floatFromInt(bar_w)));
    try w.writeAll(acc);
    try w.writeByte('[');
    for (0..bar_w) |i| try w.writeAll(if (i < n) "█" else "░");
    try w.writeByte(']');
    try w.writeAll(rst);
}

fn synthSection(w: *std.Io.Writer, label: []const u8) !void {
    try w.writeAll(dim ++ "  ─ ");
    try w.writeAll(label);
    try endLine(w);
}

pub fn drawSynthEditor(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    if (app.synth_track >= app.racks.items.len) return;
    const rack = app.racks.items[app.synth_track];
    switch (rack.instrument) { .poly_synth => {}, else => return }
    const synth = &rack.instrument.poly_synth;

    const name = if (app.synth_track < app.project.tracks.items.len)
        app.project.tracks.items[app.synth_track].name
    else "?";

    try w.writeAll(bold ++ " SYNTH" ++ rst);
    try w.print(" \"{s}\"", .{name});
    try w.writeAll(dim ++ "  [jk:move  hl:adjust  HL:coarse  esc:back]");
    try endLine(w);

    // ── OSC ──────────────────────────────────────
    try synthSection(w, "OSC");

    // Waveform row (param 0)
    {
        const is_sel = (app.synth_cursor == 0);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  waveform   ");
        const wf_names = [_][]const u8{ "sine", "saw", "tri", "sqr" };
        const wf_idx: usize = switch (synth.waveform) {
            .sine => 0, .saw => 1, .triangle => 2, .square => 3,
        };
        for (wf_names, 0..) |nm, i| {
            if (i == wf_idx) {
                if (!is_sel) try w.writeAll(acc ++ bold);
                try w.print("[{s: <5}]", .{nm});
                if (!is_sel) try w.writeAll(rst);
            } else {
                if (!is_sel) try w.writeAll(dim);
                try w.print(" {s: <5} ", .{nm});
                if (!is_sel) try w.writeAll(rst);
            }
        }
        try endLine(w);
    }

    // Detune + unison rows (params 1–3)
    const osc_rows = [_]struct { label: []const u8, idx: u8, bar: f32, bar_max: f32, disp: f32 }{
        .{ .label = "detune",  .idx = 1, .bar = synth.detune_cents + 100.0, .bar_max = 200.0,  .disp = synth.detune_cents  },
        .{ .label = "unison",  .idx = 2, .bar = @floatFromInt(synth.unison),.bar_max = 8.0,    .disp = @floatFromInt(synth.unison) },
        .{ .label = "uni.det", .idx = 3, .bar = synth.unison_detune,        .bar_max = 100.0,  .disp = synth.unison_detune },
    };
    for (osc_rows, 0..) |p, ri| {
        const is_sel = (app.synth_cursor == p.idx);
        if (is_sel) try w.writeAll(sel);
        try w.print("  {s: <9}", .{p.label});
        try synthBar(w, p.bar, p.bar_max);
        switch (ri) {
            0 => try w.print("  {d:.0} ct", .{p.disp}),
            1 => try w.print("  {d:.0}",    .{p.disp}),
            2 => try w.print("  {d:.1} ct", .{p.disp}),
            else => {},
        }
        try endLine(w);
    }

    // ── ENV ──────────────────────────────────────
    try synthSection(w, "ENV");

    const env_rows = [_]struct { label: []const u8, idx: u8, bar: f32, bar_max: f32, disp: f32 }{
        .{ .label = "attack",  .idx = 4, .bar = synth.attack_s,  .bar_max = 5.0,  .disp = synth.attack_s  },
        .{ .label = "decay",   .idx = 5, .bar = synth.decay_s,   .bar_max = 5.0,  .disp = synth.decay_s   },
        .{ .label = "sustain", .idx = 6, .bar = synth.sustain,   .bar_max = 1.0,  .disp = synth.sustain   },
        .{ .label = "release", .idx = 7, .bar = synth.release_s, .bar_max = 10.0, .disp = synth.release_s },
    };
    for (env_rows, 0..) |p, ri| {
        const is_sel = (app.synth_cursor == p.idx);
        if (is_sel) try w.writeAll(sel);
        try w.print("  {s: <9}", .{p.label});
        try synthBar(w, p.bar, p.bar_max);
        switch (ri) {
            2 => try w.print("  {d:.3}", .{p.disp}),
            else => try w.print("  {d:.3} s", .{p.disp}),
        }
        try endLine(w);
    }

    // ── FILTER ───────────────────────────────────
    try synthSection(w, "FILTER");

    const flt_rows = [_]struct { label: []const u8, idx: u8, bar: f32, bar_max: f32, disp: f32 }{
        .{ .label = "cutoff", .idx = 8, .bar = synth.filter_cutoff, .bar_max = 20_000.0, .disp = synth.filter_cutoff },
        .{ .label = "res",    .idx = 9, .bar = synth.filter_res,    .bar_max = 1.0,      .disp = synth.filter_res    },
    };
    for (flt_rows, 0..) |p, ri| {
        const is_sel = (app.synth_cursor == p.idx);
        if (is_sel) try w.writeAll(sel);
        try w.print("  {s: <9}", .{p.label});
        try synthBar(w, p.bar, p.bar_max);
        switch (ri) {
            0 => try w.print("  {d:.0} Hz", .{p.disp}),
            else => try w.print("  {d:.3}", .{p.disp}),
        }
        try endLine(w);
    }

    // ── OUT ──────────────────────────────────────
    try synthSection(w, "OUT");

    {
        const is_sel = (app.synth_cursor == 10);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  gain     ");
        try synthBar(w, synth.gain, 1.0);
        try w.print("  {d:.3}", .{synth.gain});
        try endLine(w);
    }

    // 1 title + 4 sections + 11 params = 16 content rows
    const used: usize = 16;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawSynthStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.synth_track >= app.racks.items.len) return;
    const rack = app.racks.items[app.synth_track];
    switch (rack.instrument) { .poly_synth => {}, else => return }
    const synth = &rack.instrument.poly_synth;

    const labels = [_][]const u8{
        "waveform", "detune", "unison", "uni.det",
        "attack", "decay", "sustain", "release",
        "cutoff", "res", "gain",
    };
    const cur = @min(@as(usize, app.synth_cursor), labels.len - 1);
    try w.writeAll(grn ++ sel ++ " SYNTH " ++ rst);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(labels[cur]);
    try w.writeAll(dim ++ ": " ++ rst);
    try w.writeAll(acc);
    switch (app.synth_cursor) {
        0  => try w.writeAll(switch (synth.waveform) {
            .sine => "sine", .saw => "saw", .triangle => "tri", .square => "sqr",
        }),
        1  => try w.print("{d:.0} ct",  .{synth.detune_cents}),
        2  => try w.print("{d}",         .{synth.unison}),
        3  => try w.print("{d:.1} ct",  .{synth.unison_detune}),
        4  => try w.print("{d:.3} s",   .{synth.attack_s}),
        5  => try w.print("{d:.3} s",   .{synth.decay_s}),
        6  => try w.print("{d:.3}",     .{synth.sustain}),
        7  => try w.print("{d:.3} s",   .{synth.release_s}),
        8  => try w.print("{d:.0} Hz",  .{synth.filter_cutoff}),
        9  => try w.print("{d:.3}",     .{synth.filter_res}),
        10 => try w.print("{d:.3}",     .{synth.gain}),
        else => {},
    }
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}
